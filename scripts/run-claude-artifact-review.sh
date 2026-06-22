#!/usr/bin/env bash
# Non-interactive Claude gate review for Codex-authored high-risk artifacts.

set -euo pipefail

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
  sed -n '2,14p' "$0" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

ARTIFACT="$1"
shift

FOCUS="Review this artifact as the independent REVIEWER (Adoption gate). Prioritize false-pass paths, missing evidence, publish/readiness claims, and whether the declared gate status is justified."
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
  OUTPUT="$WORKSPACE/worklog/claude-reviews/${STAMP}-${SLUG}.md"
fi

mkdir -p "$(dirname "$OUTPUT")"

log() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" claude-artifact-review "$@" || true
}

PROMPT="$(mktemp "${TMPDIR:-/tmp}/claude-artifact-review.XXXXXX.md")"
trap 'rm -f "$PROMPT"' EXIT

{
  cat <<EOF
You are acting as the REVIEWER for the Adoption gate, performing an independent review of an artifact authored by the PRIMARY agent (the user-facing session that produced this draft). You and PRIMARY may run different runtimes; assume PRIMARY's reasoning is not visible to you and judge only the artifact.

Target artifact:
$ARTIFACT_ABS

Focus:
$FOCUS

Review rules:
- Treat the artifact as Draft unless it contains current review evidence or an explicit owner Override.
- Do not approve if the artifact can still allow a QA verdict, external publish, test skip/baseline change, or AI-agent output adoption without current evidence.
- Verify concrete repo claims when possible using local context.
- Do not rewrite the artifact. Produce review findings only.
- Findings must be actionable and classified as H, M, or L.
- If there are no material findings, approve.

Required output:
1. Gate status assessment.
2. Findings, ordered by severity.
3. Required deltas before execution or publish.
4. Evidence checked.
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
# overwrite .active-binding.md — this is a sub-tool spawn (reverse review),
# not a new top-level Claude session. Without the env var, when invoked from
# a Codex session, the child Claude would flip the binding to PRIMARY=Claude
# for the rest of the parent Codex session.
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
  echo "ERROR: Claude review output is too short to be a valid review report: $OUTPUT" >&2
  exit 1
fi

VERDICT="$(grep -E '^Verdict: (approve|needs-attention|block)$' "$OUTPUT" | tail -1 | sed 's/^Verdict: //' || true)"
if [[ -z "$VERDICT" ]]; then
  log "$ARTIFACT_ABS" malformed "output=$OUTPUT"
  echo "ERROR: Claude review did not produce a valid verdict line: $OUTPUT" >&2
  exit 1
fi

log "$ARTIFACT_ABS" review-complete "verdict=$VERDICT output=$OUTPUT"

echo "Claude review written: $OUTPUT"
echo "Verdict: $VERDICT"

if [[ "$REQUIRE_APPROVE" -eq 1 && "$VERDICT" != "approve" ]]; then
  exit 1
fi

