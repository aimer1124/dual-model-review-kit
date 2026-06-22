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
#   scripts/run-claude-self-adversarial.sh <artifact-path> [--focus "text"] [--output <path>] [--require-approve] [--budget <usd>] [--model <name>]
#
# Output:
#   Markdown report under worklog/claude-self-adversarial/<timestamp>-<slug>.md
#   plus a row in .codex-hook-log.tsv with hook=claude-self-adversarial.
#   Verdict line contract matches the Codex adversarial-review side.
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
  sed -n '2,22p' "$0" >&2
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
trap 'rm -f "$PROMPT"' EXIT

{
  cat <<EOF
You are acting as the Exit-gate adversarial reviewer against a draft authored by the PRIMARY agent (a sibling session that shares your runtime but no conversation context). Your job is to attack the draft, not validate it.

Target artifact:
$ARTIFACT_ABS

Focus:
$FOCUS

Review rules:
- Do not approve unless you actively cannot find a scope miss, fabricated infrastructure, missing evidence, or unjustified claim.
- Cite file:line for every concrete claim you make; if you cannot, downgrade the finding to L.
- Classify each finding H / M / L.
- If the artifact requires implementation evidence (commands run, files modified, tests passed) and that evidence is absent or unverifiable, do not approve.
- Do not rewrite the artifact. Findings only.

Required output:
1. Scope read (what you understood the artifact is trying to do).
2. Findings, ordered by severity (H first).
3. Required deltas before the author may ExitPlanMode.
4. Evidence you actually checked (with file:line).
5. End with exactly one line:
   Verdict: approve
   OR
   Verdict: needs-attention
   OR
   Verdict: block

Artifact body:
EOF
  cat "$ARTIFACT_ABS"
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

log "$ARTIFACT_ABS" review-complete "verdict=$VERDICT output=$OUTPUT"

echo "Claude self-adversarial written: $OUTPUT"
echo "Verdict: $VERDICT"

if [[ "$REQUIRE_APPROVE" -eq 1 && "$VERDICT" != "approve" ]]; then
  exit 1
fi
