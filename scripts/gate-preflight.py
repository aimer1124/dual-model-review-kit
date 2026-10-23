#!/usr/bin/env python3
"""gate-preflight.py — deterministic checks a gate artifact must pass before review.

Many first-round gate rejections are mechanical (stale file:line, untraceable sha,
hand-typed gate status, unrecorded owner authorization, uncited "only N" counts).
This script runs those checks as code, so a mechanical miss is caught before a
review round is spent. The gate scripts run it before their round guard.

Usage:
  scripts/gate-preflight.py <artifact> [--gate exit|adoption] [--mode warn|enforce]
                            [--log <hook-log>] [--before <ISO-ts>] [--report-dir <dir>]
                            [--workspace <dir>] [--no-log]

  --workspace   default: $WORKSPACE, else `git rev-parse --show-toplevel`, else cwd.
  --log         default: <workspace>/.codex-hook-log.tsv (plus <log>-archive.tsv).
  --report-dir  default: $GATE_PREFLIGHT_REPORT_DIR, else next to a --log outside the
                workspace default (keeps test harnesses hermetic), else
                <workspace>/<record dir>/preflight/.
  --mode        default $GATE_PREFLIGHT_MODE, else "warn". warn: findings are reported
                and logged as `warn`, exit 0. enforce: findings exit 4.

Configuration (environment):
  GATE_RECORD_DIR      durable record root, workspace-relative (default "worklog"):
                       evidence files, authorization records, reviewed-sha notes.
  GATE_EVIDENCE_DIR    evidence dir a count claim must cite (default "worklog/evidence").
  GATE_PREFLIGHT_SUBREPOS=auto|off
                       auto (default): <workspace>/*/.git checkouts are searched too,
                       for workspaces whose root .gitignore hides nested repos.
  GATE_PREFLIGHT_LINECHECK_SUBREPOS
                       comma-separated nested repos whose file:line anchors PF-02 checks
                       (default none: a nested checkout may lag its remote, so only
                       root-repo anchors are range-checked; PF-05 owns remote anchors).
  GATE_PREFLIGHT_PLAN_LINT
                       optional command run as `<cmd> <artifact>` for PF-09; a non-zero
                       exit is a finding. Unset: PF-09 is skipped.
  GATE_PATH_ROOTS, GATE_EXIT_HOOKS, GATE_ADOPTION_HOOKS: see gate-trajectory.py.

Checks:
  PF-01  cited local paths exist
  PF-02  path:N / path:N-M is within the file's line count
  PF-03  no evidence path under /tmp or /private/tmp
  PF-04  every full sha256 traces to a cited file, a hook-log row or a record file
  PF-05  remote-ref anchors (origin/<ref>:<path>:<n>) cite a materialized evidence
         file under the record dir
  PF-06  declared gate status and trajectory rows match the hook log
         (scripts/gate-trajectory.py)
  PF-07  owner Override / approval claims cite a durable record file or a
         user-override hook-log row
  PF-08  "only N / all N / 共 N" counts sit in a section that cites an evidence file
         (scripts/scope-inventory.sh writes one)
  PF-09  optional plan lint command ($GATE_PREFLIGHT_PLAN_LINT) passes

Paths and line anchors are read from code spans only (<code> in html, `backticks`
in Markdown) to keep prose out. Text inside <blockquote>, <del>, any element with
class="historical", and Markdown "> " quotes is skipped. A path whose block says
new file / proposed / create / delete (or the Chinese equivalents) is treated as
not claiming the path exists now.

Hook-log row (hook `gate-preflight`; never `round-guard`, never `verdict=approve`,
so the round guard's counting is untouched): status pass | warn | blocked, note
`gate= mode= findings= checks= sha256= report=`. The calling gate script writes the
`skipped` and `error` rows.

Exit: 0 = pass (or warn mode), 4 = blocked (enforce mode), 2 = usage or internal error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html as htmllib
import importlib.util
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HOOK = "gate-preflight"
RECORD_DIR = os.environ.get("GATE_RECORD_DIR", "worklog").strip("/")
EVIDENCE_DIR = os.environ.get("GATE_EVIDENCE_DIR", "worklog/evidence").strip("/")
SUBREPO_MODE = os.environ.get("GATE_PREFLIGHT_SUBREPOS", "auto")
LINECHECK_REPOS = {""} | {r.strip() for r in os.environ.get("GATE_PREFLIGHT_LINECHECK_SUBREPOS", "").split(",") if r.strip()}

PATH_TOKEN = re.compile(r"(?:[A-Za-z0-9_.@+-]+/)+[A-Za-z0-9_.@+-]+/?")
LINE_ANCHOR = re.compile(r"((?:[A-Za-z0-9_.@+-]+/)*[A-Za-z0-9_.@+-]+\.[A-Za-z0-9]+):(\d+)(?:-(\d+))?((?:,\s*:?\d+(?:-\d+)?)*)")
SHA256 = re.compile(r"(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])")
TMP_PATH = re.compile(r"(?:/private)?/tmp/[A-Za-z0-9_.-]+")
REMOTE_ANCHOR = re.compile(r"\b(origin/[A-Za-z0-9_./-]+):((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.[A-Za-z0-9]+):\d+")
# A block that creates, outputs or deletes a path does not claim the path exists now.
NEW_MARK = re.compile(
    r"新(?:建|增|单测|文件|脚本|测试)|输出|写入|写到|记录在|生成|写一份|比如|例如|删除|git rm|移除|退役"
    r"|proposed|new file|to be created|will create|creates?\b|e\.g\.|delete|remove",
    re.I,
)
PLACEHOLDER = re.compile(r"[<>{}*$…\[\]]|\.\.\.|YYYY|<slug>")
LOCAL_ABS = ("/Users/", "/home/", "/private/", "/opt/", "/etc/", "/tmp/", "/var/")
# Past-tense authorization statements only; conditional ones ("once the owner agrees",
# "经 owner 同意后") describe a future gate, not a claim to verify.
AUTH_CLAIM = re.compile(
    r"(owner|用户|user)[^。；;\n]{0,30}?(在\s*chat\s*中|chat\s*里|in\s+chat|已经?|already|于?\s*\d{4}-\d{2}-\d{2})[^。；;\n]{0,20}?"
    r"(同意|授权|批准|决定|确认|Override|approved|authori[sz]ed|agreed|decided|confirmed)"
    r"|(owner|用户|user)\s*(同意|授权|批准|决定|确认|approved|authori[sz]ed|agreed|decided)\s*[（(][^）)]{0,30}?\d{4}-\d{2}-\d{2}"
    r"|(owner|user)\s+(approved|authori[sz]ed|agreed|decided|confirmed)\b[^.;\n]{0,30}?(in\s+chat|on\s+\d{4}-\d{2}-\d{2})"
    r"|(owner|用户)\s*(同意|授权|Override)\s*[）)]"
    r"|Override\s*[（(]\s*owner",
    re.I,
)
CONDITIONAL = re.compile(r"后|时[，,）)]|需|征得|征求|等\s*owner|待|如果|若|是否|另行|if\b|once\b|requires?\b|until\b|before\b", re.I)
COUNT_CLAIM = re.compile(
    r"(?:共有|共|只有|仅有|仅|全部|总共|一共)\s*\d+\s*(?:处|个|份|条|行|项|files?\b)"
    r"|\b(?:only|all|exactly)\s+\d+\s+(?:files?|places|call ?sites|hits|callers|scripts)\b",
    re.I,
)
STATUS_WORD = re.compile(r"Gate status(?:\s|:|\*|</?b>)*(Draft|Reviewed|Needs attention|Override)", re.I)
VERDICT_WORD = re.compile(r"\b(approve|needs-attention|block)\b")

SKIP_BLOCKS = re.compile(
    r"<(blockquote|del|style|script|head)\b.*?</\1>"
    r"|<(\w+)\b[^>]*class=\"[^\"]*\bhistorical\b[^\"]*\"[^>]*>.*?</\2>",
    re.S | re.I,
)
BLOCK_SPLIT = re.compile(r"</(?:p|li|td|th|tr|div|h[1-6]|pre|ul|ol|table)>", re.I)
HEADING = re.compile(r"<h[1-6][^>]*>(.*?)</h[1-6]>", re.S | re.I)


def _load(name: str, filename: str):
    sys.dont_write_bytecode = True  # no __pycache__/ left in the target repo's scripts/
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


_TRAJ = _load("gate_trajectory", "gate-trajectory.py")
WORKSPACE = Path.cwd()


@dataclass
class Block:
    section: str
    text: str  # plain text, entities unescaped
    code: list[str] = field(default_factory=list)  # code-span contents, unescaped
    raw: str = ""


@dataclass
class Finding:
    check: str
    message: str
    excerpt: str


def strip_tags(s: str) -> str:
    return htmllib.unescape(re.sub(r"<[^>]+>", " ", s))


def blocks_from_html(src: str) -> list[Block]:
    src = SKIP_BLOCKS.sub(" ", src)
    out: list[Block] = []
    section = ""
    for raw in BLOCK_SPLIT.split(src):
        h = HEADING.search(raw)
        if h:
            section = strip_tags(h.group(1)).strip()
        code = [htmllib.unescape(re.sub(r"<[^>]+>", "", c)) for c in re.findall(r"<code\b[^>]*>(.*?)</code>", raw, re.S | re.I)]
        text = re.sub(r"\s+", " ", strip_tags(raw)).strip()
        if text:
            out.append(Block(section, text, code, raw))
    return out


def blocks_from_markdown(src: str) -> list[Block]:
    out: list[Block] = []
    section = ""
    in_fence = False
    buf: list[str] = []

    def flush():
        if buf:
            text = " ".join(buf).strip()
            out.append(Block(section, text, re.findall(r"`([^`]+)`", text), text))
            buf.clear()

    for line in src.splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            buf.append(f"`{line}`")
            continue
        if line.startswith("#"):
            flush()
            section = line.lstrip("#").strip()
            continue
        if line.startswith(">"):
            continue
        if not line.strip():
            flush()
            continue
        buf.append(line)
    flush()
    return out


_SUBREPOS: list[Path] | None = None
_TRACKED: list[str] | None = None


def subrepos() -> list[Path]:
    global _SUBREPOS
    if _SUBREPOS is None:
        _SUBREPOS = [] if SUBREPO_MODE == "off" else sorted(p.parent for p in WORKSPACE.glob("*/.git"))
    return _SUBREPOS


def tracked_paths() -> list[str]:
    """Workspace-relative paths of every tracked file, root and nested repos (for suffix matches)."""
    global _TRACKED
    if _TRACKED is None:
        _TRACKED = []
        for repo in [WORKSPACE, *subrepos()]:
            prefix = "" if repo == WORKSPACE else repo.name + "/"
            proc = subprocess.run(["git", "-C", str(repo), "ls-files"], capture_output=True, text=True)
            _TRACKED += [prefix + line for line in proc.stdout.splitlines()]
    return _TRACKED


def candidates(token: str, artifact: Path) -> list[Path]:
    token = token.rstrip("/.,;:)")
    if token.startswith("/"):
        p = Path(token)
        return [p] if p.exists() else []
    return [p for p in (base / token for base in [WORKSPACE, artifact.parent, *subrepos()]) if p.exists()]


def resolve(token: str, artifact: Path) -> Path | None:
    found = candidates(token, artifact)
    return found[0] if found else None


def exists_anywhere(token: str, artifact: Path) -> bool:
    """Exact path, or an abbreviated suffix of a tracked path (e.g. apps/x/route.ts)."""
    if resolve(token, artifact) is not None:
        return True
    tok = token.rstrip("/.,;:)")
    if token.endswith("/"):
        return any(("/" + tok + "/") in ("/" + p) for p in tracked_paths())
    return any(p == tok or p.endswith("/" + tok) for p in tracked_paths())


def repo_of(path: Path) -> str:
    rel = _TRAJ.rel_path(str(path.resolve()))
    head = rel.split("/", 1)[0]
    return head if "/" in rel and (WORKSPACE / head / ".git").exists() else ""


def under(tok: str, prefix: str) -> bool:
    return tok == prefix or tok.startswith(prefix + "/")


def path_tokens(code: str):
    """Path-like tokens in a code span, skipping $VAR/…/ prefixes and URL routes."""
    for m in PATH_TOKEN.finditer(code):
        tok = m.group(0)
        before = code[max(0, m.start() - 1):m.start()]
        if before in ("$", "{", "…", "<", "[", "@"):
            continue
        if before == "/":
            if code[max(0, m.start() - 2):m.start()] == "…/":
                continue  # elided prefix such as …/x/route.ts
            tok = "/" + tok
            if not tok.startswith(LOCAL_ABS):
                continue  # API route such as /reports/x/detail
        yield tok


def is_candidate_path(token: str) -> bool:
    if "://" in token or PLACEHOLDER.search(token) or token.startswith(("origin/", "refs/", "upstream/")):
        return False
    tail = token.rstrip("/").rsplit("/", 1)[-1]
    return token.endswith("/") or bool(re.search(r"\.[A-Za-z0-9]{1,8}$", tail))


def check_paths(blocks: list[Block], artifact: Path) -> list[Finding]:
    found: list[Finding] = []
    seen: set[str] = set()
    for b in blocks:
        new_block = bool(NEW_MARK.search(b.text))
        for code in b.code:
            for tok in path_tokens(code):
                if tok in seen or not is_candidate_path(tok):
                    continue
                seen.add(tok)
                if not new_block and not exists_anywhere(tok, artifact):
                    found.append(Finding("PF-01", f"cited path does not exist: {tok}", b.text[:160]))
    return found


def check_line_anchors(blocks: list[Block], artifact: Path) -> list[Finding]:
    found: list[Finding] = []
    for b in blocks:
        for code in b.code:
            for m in LINE_ANCHOR.finditer(code):
                path, start, end, more = m.group(1), int(m.group(2)), m.group(3), m.group(4) or ""
                if REMOTE_ANCHOR.search(code) or PLACEHOLDER.search(path):
                    continue
                found_paths = {c.resolve() for c in candidates(path, artifact) if c.is_file()}
                if len(found_paths) != 1:
                    continue  # missing (PF-01 reports it) or ambiguous, e.g. a bare README.md
                p = found_paths.pop()
                if repo_of(p) not in LINECHECK_REPOS:
                    continue  # nested checkouts may lag their remotes; PF-05 owns those anchors
                try:
                    n = sum(1 for _ in p.open("rb"))
                except OSError:
                    continue
                lines = [int(end or start)] + [int(x) for x in re.findall(r"(\d+)(?:-\d+)?", more)]
                lines += [int(x) for x in re.findall(r"\d+-(\d+)", more)]
                if max(lines) > n:
                    found.append(Finding("PF-02", f"{m.group(0)} is past the end of {path} ({n} lines)", b.text[:160]))
    return found


def check_tmp(blocks: list[Block]) -> list[Finding]:
    found: list[Finding] = []
    for b in blocks:
        for code in b.code:
            if "${" in code or "mktemp" in code or "TMPDIR" in code:
                continue
            for m in TMP_PATH.finditer(code):
                found.append(Finding("PF-03", f"evidence path under a temp dir: {m.group(0)}", b.text[:160]))
    return found


_RECORD_HITS: dict[str, bool] = {}


def in_records(sha: str) -> bool:
    """A sha written in any durable record file counts as traceable (e.g. reviewed bytes
    noted in a log entry before the gate rows carried sha256=)."""
    if sha not in _RECORD_HITS:
        root = WORKSPACE / RECORD_DIR
        hit = False
        if root.is_dir():
            proc = subprocess.run(
                ["grep", "-rlF", "-m1", "--include=*.md", "--include=*.tsv", "--include=*.txt", "--include=*.json",
                 sha, str(root)],
                capture_output=True, text=True,
            )
            hit = bool(proc.stdout.strip())
        _RECORD_HITS[sha] = hit
    return _RECORD_HITS[sha]


def check_shas(blocks: list[Block], artifact: Path, log_text: str) -> list[Finding]:
    cited_shas: set[str] = set()
    for b in blocks:
        for code in b.code:
            for tok in path_tokens(code):
                p = resolve(tok, artifact)
                if p is not None and p.is_file() and p.stat().st_size < 50_000_000:
                    cited_shas.add(hashlib.sha256(p.read_bytes()).hexdigest())
    found: list[Finding] = []
    seen: set[str] = set()
    for b in blocks:
        for m in SHA256.finditer(b.text):
            sha = m.group(0)
            if sha in seen:
                continue
            seen.add(sha)
            if sha not in cited_shas and sha not in log_text and not in_records(sha):
                found.append(Finding("PF-04", f"sha256 {sha[:12]}… matches no cited file, hook-log row or {RECORD_DIR}/ record", b.text[:160]))
    return found


def check_remote_anchors(blocks: list[Block], artifact: Path) -> list[Finding]:
    evidence_text = ""
    for b in blocks:
        for code in b.code:
            for tok in path_tokens(code):
                if under(tok, RECORD_DIR):
                    p = resolve(tok, artifact)
                    if p is not None and p.is_file() and p.stat().st_size < 5_000_000:
                        evidence_text += p.read_text(errors="replace")
    found: list[Finding] = []
    for b in blocks:
        for code in b.code:
            for m in REMOTE_ANCHOR.finditer(code):
                if m.group(2) not in evidence_text:
                    found.append(Finding("PF-05", f"remote anchor {m.group(0)} has no materialized {RECORD_DIR}/ evidence file citing {m.group(2)}", b.text[:160]))
    return found


def declared_rows(src: str) -> list[tuple[str, int, str]]:
    rows: list[tuple[str, int, str]] = []
    for tr in re.findall(r"<tr\b[^>]*>(.*?)</tr>", src, re.S | re.I):
        cells = [strip_tags(c).strip() for c in re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", tr, re.S | re.I)]
        if len(cells) < 3 or cells[0] not in ("Exit", "Adoption"):
            continue
        rnd = re.match(r"R(\d+)", cells[1])
        verdict = VERDICT_WORD.search(cells[2])
        if rnd and verdict:
            rows.append((cells[0], int(rnd.group(1)), verdict.group(1)))
    for line in src.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.lstrip().startswith("|") else []
        if len(cells) >= 3 and cells[0] in ("Exit", "Adoption"):
            rnd = re.match(r"R(\d+)", cells[1])
            verdict = VERDICT_WORD.search(cells[2])
            if rnd and verdict:
                rows.append((cells[0], int(rnd.group(1)), verdict.group(1)))
    return rows


def check_gate_status(src: str, artifact: Path, log: Path, before: str | None) -> list[Finding]:
    events, current_sha, _bad = _TRAJ.trajectory(artifact, log, before)
    found: list[Finding] = []
    status = STATUS_WORD.search(src)
    if status and status.group(1).lower() == "reviewed" and _TRAJ.overall(events, current_sha) != "Reviewed":
        found.append(Finding("PF-06", "declares Gate status Reviewed, but the hook log has no Exit approve/Override plus an Adoption approve on these bytes", status.group(0)))
    logged: dict[tuple[str, int], str] = {}
    counters = {"Exit": 0, "Adoption": 0}
    for ev in events:
        if ev.kind == "review":
            counters[ev.gate] += 1
            logged[(ev.gate, counters[ev.gate])] = ev.verdict
    declared = declared_rows(src)
    for gate, rnd, verdict in declared:
        actual = logged.get((gate, rnd))
        if actual is None:
            found.append(Finding("PF-06", f"trajectory row {gate} R{rnd} ({verdict}) has no matching review-complete row in the hook log", f"{gate} R{rnd}"))
        elif actual != verdict:
            found.append(Finding("PF-06", f"trajectory row {gate} R{rnd} says {verdict}, hook log says {actual}", f"{gate} R{rnd}"))
    if declared:
        listed = {(g, r) for g, r, _ in declared}
        for key, verdict in logged.items():
            if key not in listed:
                found.append(Finding("PF-06", f"hook log has {key[0]} R{key[1]} ({verdict}) but the trajectory table omits it", f"{key[0]} R{key[1]}"))
    return found


def override_target(target: str) -> str:
    return target.partition(":")[2] if target.startswith("gate=") else target


def check_authorizations(blocks: list[Block], artifact: Path, log_text: str) -> list[Finding]:
    rel = _TRAJ.rel_path(str(artifact))
    has_override_row = any(
        "\tuser-override\t" in line and _TRAJ.rel_path(override_target(line.split("\t")[2])) == rel
        for line in log_text.splitlines()
        if line.count("\t") >= 3
    )
    found: list[Finding] = []
    for b in blocks:
        m = AUTH_CLAIM.search(b.text)
        if not m or CONDITIONAL.search(b.text[max(0, m.start() - 8):m.end()]):
            continue
        durable = any(
            under(t, RECORD_DIR) and resolve(t, artifact) is not None
            for code in b.code
            for t in path_tokens(code)
        )
        if durable or ("Override" in m.group(0) and has_override_row):
            continue
        found.append(Finding("PF-07", f"owner authorization / Override claim without a durable {RECORD_DIR}/ file or user-override row", b.text[:160]))
    return found


def check_counts(blocks: list[Block], artifact: Path) -> list[Finding]:
    cited_sections: set[str] = set()
    for b in blocks:
        for code in b.code:
            for tok in path_tokens(code):
                if under(tok, EVIDENCE_DIR) and resolve(tok, artifact) is not None:
                    cited_sections.add(b.section)
    found: list[Finding] = []
    for b in blocks:
        m = COUNT_CLAIM.search(b.text)
        if m and b.section not in cited_sections:
            found.append(Finding("PF-08", f"count claim \"{m.group(0)}\" in a section that cites no {EVIDENCE_DIR}/ file", b.text[:160]))
    return found


def check_plan_lint(artifact: Path) -> list[Finding]:
    cmd = os.environ.get("GATE_PREFLIGHT_PLAN_LINT", "").strip()
    if not cmd:
        return []
    proc = subprocess.run([*shlex.split(cmd), str(artifact)], capture_output=True, text=True, cwd=WORKSPACE)
    if proc.returncode != 0:
        return [Finding("PF-09", f"plan lint failed: {cmd}", (proc.stdout + proc.stderr).strip()[:300])]
    return []


def run_checks(artifact: Path, log: Path, before: str | None) -> list[Finding]:
    src = artifact.read_text(encoding="utf-8", errors="replace")
    blocks = blocks_from_html(src) if artifact.suffix.lower() in (".html", ".htm") else blocks_from_markdown(src)
    archive = log.with_name(log.stem + "-archive" + log.suffix)
    log_text = "".join(p.read_text(errors="replace") for p in (archive, log) if p.exists())
    findings: list[Finding] = []
    findings += check_paths(blocks, artifact)
    findings += check_line_anchors(blocks, artifact)
    findings += check_tmp(blocks)
    findings += check_shas(blocks, artifact, log_text)
    findings += check_remote_anchors(blocks, artifact)
    findings += check_gate_status(src, artifact, log, before)
    findings += check_authorizations(blocks, artifact, log_text)
    findings += check_counts(blocks, artifact)
    findings += check_plan_lint(artifact)
    return findings


def write_report(report_dir: Path, artifact: Path, findings: list[Finding], mode: str, sha: str) -> Path:
    report_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", artifact.stem).strip("-")
    path = report_dir / f"{stamp}-{slug}.txt"
    lines = [f"artifact: {artifact}", f"sha256: {sha}", f"mode: {mode}", f"findings: {len(findings)}", ""]
    for f in findings:
        lines.append(f"{f.check}  {f.message}")
        if f.excerpt:
            lines.append(f"       in: {f.excerpt}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def default_report_dir(log: Path) -> Path:
    """<record dir>/preflight/, unless the hook log is redirected (test harnesses pass a
    temp --log): then next to that log, so smokes stay hermetic."""
    env = os.environ.get("GATE_PREFLIGHT_REPORT_DIR")
    if env:
        return Path(env)
    if log.resolve() != _TRAJ.default_log().resolve():
        return log.parent / "preflight-reports"
    return WORKSPACE / RECORD_DIR / "preflight"


def log_row(log: Path, artifact: Path, status: str, note: str) -> None:
    """Same row format as scripts/codex-hook-log.sh, appended to the log being checked."""
    clean = lambda s: re.sub(r"[\t\r\n]", " ", s)  # noqa: E731
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with log.open("a", encoding="utf-8") as fh:
            fh.write("\t".join([ts, HOOK, clean(str(artifact)), status, clean(note)]) + "\n")
    except OSError as exc:
        print(f"WARN: could not append preflight row to {log}: {exc}", file=sys.stderr)


def main(argv: list[str]) -> int:
    global WORKSPACE
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("artifact")
    ap.add_argument("--gate", choices=("exit", "adoption"), default="exit")
    ap.add_argument("--mode", default=os.environ.get("GATE_PREFLIGHT_MODE", "warn"))
    ap.add_argument("--log", type=Path, default=None)
    ap.add_argument("--before", default=None)
    ap.add_argument("--report-dir", type=Path, default=None)
    ap.add_argument("--workspace", default=None)
    ap.add_argument("--no-log", action="store_true")
    args = ap.parse_args(argv)
    if args.mode not in ("warn", "enforce"):
        print(f"ERROR: --mode must be warn or enforce (got {args.mode})", file=sys.stderr)
        return 2
    WORKSPACE = _TRAJ.resolve_workspace(args.workspace)
    _TRAJ.set_workspace(WORKSPACE)
    artifact = Path(args.artifact).resolve()
    if not artifact.is_file():
        print(f"ERROR: artifact not found: {artifact}", file=sys.stderr)
        return 2
    log = args.log or _TRAJ.default_log()
    report_dir = args.report_dir or default_report_dir(log)
    sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
    findings = run_checks(artifact, log, args.before)
    report = write_report(report_dir, artifact, findings, args.mode, sha)
    checks = ",".join(sorted({f.check for f in findings})) or "none"
    if not findings:
        status = "pass"
    else:
        status = "blocked" if args.mode == "enforce" else "warn"
    if not args.no_log:
        log_row(log, artifact, status, f"gate={args.gate} mode={args.mode} findings={len(findings)} checks={checks} sha256={sha} report={report}")
    print(f"preflight {status}: {len(findings)} finding(s) [{checks}] report={report}")
    for f in findings[:20]:
        print(f"  {f.check}  {f.message}")
    if len(findings) > 20:
        print(f"  … {len(findings) - 20} more in the report")
    return 4 if status == "blocked" else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # fail-open contract: the gate script logs an `error` row
        print(f"ERROR: gate-preflight internal error: {exc!r}", file=sys.stderr)
        sys.exit(2)
