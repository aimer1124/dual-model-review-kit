#!/usr/bin/env python3
"""gate-trajectory.py — derive an artifact's gate history from the hook log.

Authors tend to hand-type the "Gate status" line and the Gate / Round / Verdict /
Report table, and those copies drift from .codex-hook-log.tsv. This script prints
both from the log so the author pastes them before requesting a gate;
scripts/gate-preflight.py (PF-06) compares the pasted copy with the same output.

It never rewrites the artifact (an approve is bound to exact bytes).

Usage:
  scripts/gate-trajectory.py <artifact> [--format html|md|tsv] [--log <hook-log>]
                             [--before <ISO-ts>] [--workspace <dir>]

  --workspace  default: $WORKSPACE, else `git rev-parse --show-toplevel`, else cwd
               (same order as the kit's shell scripts).
  --log        default: <workspace>/.codex-hook-log.tsv; a rotation archive next to
               it (<log>-archive.tsv) is read first when present.
  --before     only rows strictly earlier than this UTC timestamp (PF-06 uses the time
               the current gate invocation started, so its own rows are excluded).

Rows are matched by workspace-relative path. When the checkout has moved, list the
old absolute roots in $GATE_PATH_ROOTS (colon-separated) so their rows still match.
Malformed rows are skipped and counted on stderr.

Hook names: Exit = claude-self-adversarial (+ $GATE_EXIT_HOOKS, comma-separated);
Adoption = claude-artifact-review, codex-artifact-review (+ $GATE_ADOPTION_HOOKS).

Exit: 0 = printed (an empty history prints "pending" rows), 2 = usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


def _env_set(name: str) -> set[str]:
    return {h.strip() for h in os.environ.get(name, "").split(",") if h.strip()}


EXIT_HOOKS = {"claude-self-adversarial"} | _env_set("GATE_EXIT_HOOKS")
ADOPTION_HOOKS = {"claude-artifact-review", "codex-artifact-review"} | _env_set("GATE_ADOPTION_HOOKS")

WORKSPACE = Path.cwd()
ROOTS: tuple[str, ...] = ()


def resolve_workspace(explicit: str | None = None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    if os.environ.get("WORKSPACE"):
        return Path(os.environ["WORKSPACE"]).resolve()
    proc = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        return Path(proc.stdout.strip()).resolve()
    return Path.cwd().resolve()


def set_workspace(path: Path) -> None:
    """Bind the module to one workspace root (gate-preflight.py calls this too)."""
    global WORKSPACE, ROOTS
    WORKSPACE = path
    roots = [str(path)] + [r for r in os.environ.get("GATE_PATH_ROOTS", "").split(":") if r]
    ROOTS = tuple(r.rstrip("/") + "/" for r in roots)


def note_value(note: str, key: str) -> str:
    match = re.search(rf"(?:^| ){re.escape(key)}=([^ ]+)", note)
    return match.group(1) if match else ""


def read_rows(path: Path) -> list[tuple[str, list[str]]]:
    if not path.exists():
        return []
    rows: list[tuple[str, list[str]]] = []
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if raw:
                rows.append((raw, raw.split("\t")))
    return rows


def rel_path(path: str) -> str:
    """Workspace-relative form of an absolute path under any known root.
    macOS /var and /tmp are symlinks into /private, so that prefix is dropped too."""
    if path.startswith("/"):
        path = os.path.normpath(path)  # string-only: collapses "//" from a trailing-slash TMPDIR
    if path.startswith(("/private/var/", "/private/tmp/")):
        path = path[len("/private"):]
    for root in ROOTS:
        r = root[len("/private"):] if root.startswith(("/private/var/", "/private/tmp/")) else root
        if path.startswith(r):
            return path[len(r):]
    return path


def sha_of(note: str) -> str:
    """sha256= value; hand-written override notes may end it with punctuation."""
    return note_value(note, "sha256").rstrip(";,.")


@dataclass
class Event:
    ts: str
    gate: str  # "Exit" | "Adoption"
    kind: str  # "review" | "override"
    verdict: str
    report: str
    sha: str
    closure: bool = False


def default_log() -> Path:
    return WORKSPACE / ".codex-hook-log.tsv"


def load_rows(log: Path) -> tuple[list[list[str]], int]:
    archive = log.with_name(log.stem + "-archive" + log.suffix)
    rows: list[list[str]] = []
    bad = 0
    for path in (archive, log):
        for _raw, cols in read_rows(path):
            if len(cols) < 4 or not cols[0][:4].isdigit():
                bad += 1
                continue
            rows.append(cols + [""] * (5 - len(cols)))
    rows.sort(key=lambda c: c[0])
    return rows, bad


def collect(rows: list[list[str]], plan_rel: str, before: str | None) -> list[Event]:
    events: list[Event] = []
    # check-review-round-guard.sh only allows round >= 3 under --confirm-closure. Its key
    # is the bare artifact path (shared by both gates) or gate=<exit|adoption>:<path>.
    closure_pending: dict[str, bool] = {"Exit": False, "Adoption": False, "any": False}
    for ts, hook, target, action, note in (r[:5] for r in rows):
        if before and ts >= before:
            break
        key_gate = "any"
        if target.startswith("gate="):
            gate_name, _, target = target[len("gate="):].partition(":")
            key_gate = "Exit" if gate_name == "exit" else "Adoption"
        if rel_path(target) != plan_rel:
            continue
        if hook == "round-guard":
            if action.startswith("allowed-"):
                n = action[len("allowed-"):]
                closure_pending[key_gate] = n.isdigit() and int(n) >= 3
            continue
        if action == "user-override":
            gate = key_gate if key_gate != "any" else ("Exit" if hook in EXIT_HOOKS else "Adoption")
            events.append(Event(ts, gate, "override", "Override", "", sha_of(note)))
            continue
        if action != "review-complete":
            continue
        if hook in EXIT_HOOKS:
            gate = "Exit"
        elif hook in ADOPTION_HOOKS:
            gate = "Adoption"
        else:
            continue
        closure = closure_pending[gate] or closure_pending["any"]
        events.append(
            Event(ts, gate, "review", note_value(note, "verdict"), rel_path(note_value(note, "output")), sha_of(note), closure)
        )
        closure_pending[gate] = closure_pending["any"] = False
    return events


def numbered(events: list[Event]) -> list[tuple[Event, str]]:
    counters = {"Exit": 0, "Adoption": 0}
    out: list[tuple[Event, str]] = []
    for ev in events:
        if ev.kind == "review":
            counters[ev.gate] += 1
            label = f"R{counters[ev.gate]}" + (" (closure)" if ev.closure else "")
        else:
            label = f"Override (after R{counters[ev.gate]})"
        out.append((ev, label))
    return out


def gate_state(events: list[Event], gate: str, current_sha: str) -> str:
    mine = [e for e in events if e.gate == gate]
    if not mine:
        return "pending"
    last = mine[-1]
    if last.kind == "override":
        return "owner Override"
    bound = ""
    if last.sha:
        bound = " (current bytes)" if last.sha == current_sha else " (bytes changed)"
    return f"R{sum(1 for e in mine if e.kind == 'review')} {last.verdict}{bound}"


def overall(events: list[Event], current_sha: str) -> str:
    exit_ok = False
    adoption_ok = False
    for ev in events:
        if ev.gate == "Exit":
            exit_ok = ev.kind == "override" or ev.verdict == "approve"
        else:
            # An Adoption row without sha256= cannot prove it saw these bytes.
            adoption_ok = ev.kind == "review" and ev.verdict == "approve" and ev.sha == current_sha
    return "Reviewed" if exit_ok and adoption_ok else "Draft"


def render_html(events: list[Event], current_sha: str) -> str:
    esc = html.escape
    status = overall(events, current_sha)
    lines = [
        f'<div><b>Gate status</b> <b>{status}</b> (Exit: {esc(gate_state(events, "Exit", current_sha))}; '
        f'Adoption: {esc(gate_state(events, "Adoption", current_sha))}; generated by <code>scripts/gate-trajectory.py</code>)</div>',
        "",
        "<table>",
        "<tr><th>Gate</th><th>Round</th><th>Verdict</th><th>Report</th></tr>",
    ]
    for ev, label in numbered(events):
        verdict = "Override" if ev.kind == "override" else f"<code>{esc(ev.verdict)}</code>"
        sha = f"; sha256 <code>{esc(ev.sha)}</code>" if ev.sha else ""
        report = f"<code>{esc(ev.report)}</code>" if ev.report else "—"
        lines.append(f"<tr><td>{ev.gate}</td><td>{esc(label)}{sha}</td><td>{verdict}</td><td>{report}</td></tr>")
    for gate in ("Exit", "Adoption"):
        if not any(e.gate == gate for e in events):
            lines.append(f"<tr><td>{gate}</td><td>—</td><td>pending</td><td>—</td></tr>")
    lines.append("</table>")
    return "\n".join(lines)


def render_md(events: list[Event], current_sha: str) -> str:
    status = overall(events, current_sha)
    lines = [
        f"Gate status: {status} (Exit: {gate_state(events, 'Exit', current_sha)}; "
        f"Adoption: {gate_state(events, 'Adoption', current_sha)}; generated by `scripts/gate-trajectory.py`)",
        "",
        "| Gate | Round | Verdict | Report |",
        "|---|---|---|---|",
    ]
    for ev, label in numbered(events):
        verdict = "Override" if ev.kind == "override" else f"`{ev.verdict}`"
        sha = f"; sha256 `{ev.sha}`" if ev.sha else ""
        report = f"`{ev.report}`" if ev.report else "—"
        lines.append(f"| {ev.gate} | {label}{sha} | {verdict} | {report} |")
    for gate in ("Exit", "Adoption"):
        if not any(e.gate == gate for e in events):
            lines.append(f"| {gate} | — | pending | — |")
    return "\n".join(lines)


def render_tsv(events: list[Event]) -> str:
    out = ["ts\tgate\tround\tverdict\tsha256\treport"]
    for ev, label in numbered(events):
        out.append(f"{ev.ts}\t{ev.gate}\t{label}\t{ev.verdict}\t{ev.sha}\t{ev.report}")
    return "\n".join(out)


def trajectory(plan: Path, log: Path, before: str | None = None) -> tuple[list[Event], str, int]:
    """Public entry for gate-preflight.py: (events, current sha256, malformed-row count)."""
    plan_abs = plan.resolve()
    rows, bad = load_rows(log)
    events = collect(rows, rel_path(str(plan_abs)), before)
    current_sha = hashlib.sha256(plan_abs.read_bytes()).hexdigest()
    return events, current_sha, bad


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("plan")
    ap.add_argument("--format", choices=("html", "md", "tsv"), default=None)
    ap.add_argument("--log", type=Path, default=None)
    ap.add_argument("--before", default=None)
    ap.add_argument("--workspace", default=None)
    args = ap.parse_args(argv)
    set_workspace(resolve_workspace(args.workspace))
    plan = Path(args.plan)
    if not plan.is_file():
        print(f"ERROR: plan not found: {plan}", file=sys.stderr)
        return 2
    events, current_sha, bad = trajectory(plan, args.log or default_log(), args.before)
    if bad:
        print(f"note: skipped {bad} malformed hook-log row(s)", file=sys.stderr)
    fmt = args.format or ("html" if plan.suffix.lower() in (".html", ".htm") else "md")
    if fmt == "html":
        print(render_html(events, current_sha))
    elif fmt == "md":
        print(render_md(events, current_sha))
    else:
        print(render_tsv(events))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
