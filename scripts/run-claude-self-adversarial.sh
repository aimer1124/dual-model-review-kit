#!/usr/bin/env bash
# Claude self-adversarial review for the Exit gate, used when PRIMARY=Claude.
#
# Mirror in role of Codex's `adversarial-review` subcommand: spawn an
# isolated reviewer process that attacks the draft and returns a final
# `Verdict:` line, so the Exit gate is symmetric across bindings. Uses a
# fresh `claude -p` subprocess so the reviewer shares no context with the
# author session.
#
# Usage:
#   scripts/run-claude-self-adversarial.sh <artifact-path> [--focus "text"] [--output <path>] [--require-approve] [--confirm-closure] [--budget <usd>] [--model <name>] [--skip-preflight "<reason>"]
#
# Output:
#   Markdown report under worklog/claude-self-adversarial/<timestamp>-<slug>.md
#   plus a row in .codex-hook-log.tsv with hook=claude-self-adversarial.
#   Verdict line contract matches the Codex adversarial-review side.
#   The review-complete row carries sha256=<bytes the reviewer was given> and
#   rule=<EXIT_RULE_VERSION>, so an approve is bound to exact bytes and approve-rate
#   metrics can be split at a rule change.
#
# Verdict threshold (EXIT_RULE_VERSION=d7-v1):
#   needs-attention/block only for an H finding, or an M that affects correctness or a
#   stated requirement; other M/L go under "Fix-at-execution" and the verdict is approve.
#   The implementation-evidence rule stays a separate hard block outside the threshold.
#   The Adoption-gate prompts are unchanged.
#
# Preflight: scripts/gate-preflight.py runs before the round guard (mode
#   GATE_PREFLIGHT_MODE=warn|enforce, default warn). Enforce-mode findings exit 4
#   without spending a round; an internal preflight error is logged and the gate
#   continues. --skip-preflight logs a `gate-preflight skipped` row with the reason.
#   GATE_PREFLIGHT_BIN replaces the preflight script path.
#
# Exit codes: 0 ok; 1 malformed/require-approve miss; 2 usage; 3 round-guard;
#   4 preflight blocked (enforce mode); otherwise the reviewer's exit code.
#
# Notes:
#   Single-turn, headless. Token budget capped via --max-budget-usd.
#   Synchronous — there is no `--background` flag here. Budget parallel
#   work in the caller, or run the reviewer on a smaller scope to bound
#   latency.

set -uo pipefail

resolve_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
  elif git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

WORKSPACE="$(resolve_workspace)"
LOG_HELPER="$WORKSPACE/scripts/codex-hook-log.sh"

usage() {
  sed -n '2,40p' "$0" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

ARTIFACT="$1"
shift

FOCUS="You are acting as the Exit-gate adversarial reviewer for a draft produced by the PRIMARY agent (a sibling session sharing your runtime but no conversation context). Find scope misses, fabricated infrastructure, missing evidence, false-pass paths, and gate-status overclaim. Do not validate; attack."
OUTPUT=""
REQUIRE_APPROVE=0
CONFIRM_CLOSURE=0
BUDGET="${CLAUDE_REVIEW_BUDGET_USD:-1.00}"
MODEL="${CLAUDE_REVIEW_MODEL:-sonnet}"
SKIP_PREFLIGHT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus)
      [[ $# -ge 2 ]] || { echo "ERROR: --focus requires a value" >&2; exit 2; }
      FOCUS="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "ERROR: --output requires a value" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --require-approve)
      REQUIRE_APPROVE=1
      shift
      ;;
    --confirm-closure)
      CONFIRM_CLOSURE=1
      shift
      ;;
    --budget)
      [[ $# -ge 2 ]] || { echo "ERROR: --budget requires a value" >&2; exit 2; }
      BUDGET="$2"
      shift 2
      ;;
    --model)
      [[ $# -ge 2 ]] || { echo "ERROR: --model requires a value" >&2; exit 2; }
      MODEL="$2"
      shift 2
      ;;
    --skip-preflight)
      [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --skip-preflight requires a reason" >&2; exit 2; }
      SKIP_PREFLIGHT="$2"
      shift 2
      ;;
    --skip-preflight=*)
      SKIP_PREFLIGHT="${1#*=}"
      [[ -n "$SKIP_PREFLIGHT" ]] || { echo "ERROR: --skip-preflight requires a reason" >&2; exit 2; }
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$ARTIFACT" ]]; then
  echo "ERROR: artifact not found: $ARTIFACT" >&2
  exit 2
fi

ARTIFACT_ABS="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"
SLUG="$(basename "$ARTIFACT_ABS" | sed 's/\.[^.]*$//' | tr -cs '[:alnum:]_-' '-' | sed 's/^-//; s/-$//')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# Deterministic preflight. Runs BEFORE the round guard so a blocked preflight never
# spends a review round. Fail-open on an internal error (logged as `error`): it is an
# author aid, not a safety boundary. Same block in the two artifact-review scripts.
if [[ -n "$SKIP_PREFLIGHT" ]]; then
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" gate-preflight "$ARTIFACT_ABS" skipped "gate=exit reason=$SKIP_PREFLIGHT" || true
  echo "preflight skipped: $SKIP_PREFLIGHT" >&2
else
  python3 "${GATE_PREFLIGHT_BIN:-$WORKSPACE/scripts/gate-preflight.py}" "$ARTIFACT_ABS" --gate exit --workspace "$WORKSPACE" >&2
  _pfrc=$?
  if [[ $_pfrc -eq 4 ]]; then
    echo "ERROR: gate preflight blocked this review (no round spent). Fix the findings, or pass --skip-preflight \"<reason>\"." >&2
    exit 4
  elif [[ $_pfrc -ne 0 ]]; then
    [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" gate-preflight "$ARTIFACT_ABS" error "gate=exit exit=$_pfrc" || true
    echo "WARN: gate preflight failed internally (exit $_pfrc); continuing (fail-open)." >&2
  fi
fi

# Review-loop round guard (verdict-reset on this artifact) — hard-blocks the 3rd
# non-approve round per the review-loop stop-counter rule.
_guard="$WORKSPACE/scripts/check-review-round-guard.sh"
if [[ -x "$_guard" ]]; then
  _gargs=(--key "$ARTIFACT_ABS" --mode verdict-reset)
  if (( CONFIRM_CLOSURE )); then _gargs+=(--confirm-closure); fi
  if ! "$_guard" "${_gargs[@]}"; then
    echo "ERROR: review-round-guard blocked this round. Pass --confirm-closure for a closure round after a material change, or REVIEW_GUARD_DISABLE=1 to bypass." >&2
    exit 3
  fi
fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$WORKSPACE/worklog/claude-self-adversarial/${STAMP}-${SLUG}.md"
fi

mkdir -p "$(dirname "$OUTPUT")"

log() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" claude-self-adversarial "$@" || true
}

PROMPT="$(mktemp "${TMPDIR:-/tmp}/claude-self-adversarial.XXXXXX.md")"
# Snapshot the artifact once: the prompt embeds these bytes and the review-complete
# row records their sha256, so the logged hash is what the reviewer actually saw even
# if the file is edited while the review runs.
SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/claude-self-adversarial-artifact.XXXXXX")"
trap 'rm -f "$PROMPT" "$SNAPSHOT"' EXIT
cp "$ARTIFACT_ABS" "$SNAPSHOT"
REVIEWED_SHA="$(shasum -a 256 "$SNAPSHOT" | awk '{print $1}')"
EXIT_RULE_VERSION="d7-v1"

{
  cat <<EOF
You are acting as the Exit-gate adversarial reviewer against a draft authored by the PRIMARY agent (a sibling session that shares your runtime but no conversation context). Your job is to attack the draft, not validate it.

Target artifact:
$ARTIFACT_ABS

Focus:
$FOCUS

Review rules:
- Actively look for scope misses, fabricated infrastructure, missing evidence, and unjustified claims, and report every one you find.
- Verdict threshold: return needs-attention or block only if at least one finding is H, or an M that affects correctness or a stated requirement of the artifact. Every other M/L finding goes under "Fix-at-execution" and the verdict is approve. Say in each M finding whether it affects correctness or a stated requirement, and why. The implementation-evidence rule below is separate and is not subject to this threshold.
- Cite file:line for every concrete claim you make; if you cannot, downgrade the finding to L.
- Classify each finding H / M / L.
- If the artifact requires implementation evidence (commands run, files modified, tests passed) and that evidence is absent or unverifiable, do not approve.
- Do not rewrite the artifact. Findings only.

Required output:
1. Scope read (what you understood the artifact is trying to do).
2. Findings, ordered by severity (H first).
3. Required deltas before the author may ExitPlanMode (only the findings that set a non-approve verdict).
4. Fix-at-execution (M/L findings below the verdict threshold; write "none" if empty).
5. Evidence you actually checked (with file:line).
6. End with exactly one line:
   Verdict: approve
   OR
   Verdict: needs-attention
   OR
   Verdict: block

Artifact body:
EOF
  cat "$SNAPSHOT"
} > "$PROMPT"

log "$ARTIFACT_ABS" queued "output=$OUTPUT model=$MODEL"

# AGENT_ROLE=tool tells the spawned `claude -p`'s SessionStart hooks NOT to
# overwrite .active-binding.md — this is a sub-tool spawn (Exit-gate
# self-adversarial), not a new top-level Claude session.
set +e
AGENT_ROLE=tool claude -p \
  --output-format text \
  --model "$MODEL" \
  --max-budget-usd "$BUDGET" \
  --permission-mode dontAsk \
  --allowedTools "Read,Bash(rg *),Bash(sed *),Bash(git status --short),Bash(git diff --check),Bash(cat *)" \
  < "$PROMPT" > "$OUTPUT"
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  [[ -s "$OUTPUT" ]] || rm -f "$OUTPUT"
  log "$ARTIFACT_ABS" failed "exit=$STATUS output=$OUTPUT"
  exit "$STATUS"
fi

LINE_COUNT="$(wc -l < "$OUTPUT" | tr -d '[:space:]')"
if [[ "$LINE_COUNT" -lt 10 ]]; then
  [[ -s "$OUTPUT" ]] || rm -f "$OUTPUT"
  log "$ARTIFACT_ABS" malformed "line_count=$LINE_COUNT output=$OUTPUT"
  echo "ERROR: Claude self-adversarial output too short to be a valid review: $OUTPUT" >&2
  exit 1
fi

VERDICT="$(grep -E '^Verdict: (approve|needs-attention|block)$' "$OUTPUT" | tail -1 | sed 's/^Verdict: //' || true)"
if [[ -z "$VERDICT" ]]; then
  log "$ARTIFACT_ABS" malformed "output=$OUTPUT"
  echo "ERROR: Claude self-adversarial did not produce a valid verdict line: $OUTPUT" >&2
  exit 1
fi

log "$ARTIFACT_ABS" review-complete "verdict=$VERDICT output=$OUTPUT sha256=$REVIEWED_SHA rule=$EXIT_RULE_VERSION"

echo "Claude self-adversarial written: $OUTPUT"
echo "Verdict: $VERDICT"

if [[ "$REQUIRE_APPROVE" -eq 1 && "$VERDICT" != "approve" ]]; then
  exit 1
fi
