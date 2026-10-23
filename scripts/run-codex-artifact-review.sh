#!/usr/bin/env bash
# Codex reverse-review for the Adoption gate, used when REVIEWER=Codex
# (typically because PRIMARY=Claude is the user-facing session and wants
# Codex as the independent gate).
#
# Mirror of run-claude-artifact-review.sh in role: independent REVIEWER that
# must reach `Verdict: approve` before the artifact may be marked `Reviewed`.
# Routes the artifact through the canonical Codex wrapper using the
# adversarial-plan channel, which knows how to review a Markdown plan file
# without polluting the prompt with working-tree git diffs.
#
# Usage:
#   scripts/run-codex-artifact-review.sh <artifact-path> [--focus "text"] [--output <path>] [--require-approve] [--confirm-closure] [--profile <name>] [--skip-preflight "<reason>"]
#
# Intended scope:
#   Same as the Claude-side counterpart — high-risk artifacts only (formal
#   plans, QA verdict / publish packages, external publish boundaries, test
#   skip / baseline changes, AI-agent output adoption).
#
# Output:
#   Markdown report under worklog/codex-reviews/<timestamp>-<slug>.md and a
#   row in .codex-hook-log.tsv with hook=codex-artifact-review. The review-complete
#   row carries sha256= of the artifact bytes hashed right before Codex reads the
#   path (Codex reads the file itself, so an edit during the review is not caught).
#
# Preflight: scripts/gate-preflight.py runs before the round guard (mode
#   GATE_PREFLIGHT_MODE=warn|enforce, default warn). Enforce-mode findings exit 4
#   without spending a round; an internal preflight error is logged and the review
#   continues. --skip-preflight logs a `gate-preflight skipped` row with the reason.
#   GATE_PREFLIGHT_BIN replaces the preflight script path.
#
# Exit codes: 0 ok; 1 malformed/require-approve miss; 2 usage; 3 round-guard;
#   4 preflight blocked (enforce mode); otherwise the reviewer's exit code.

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
WRAPPER="$WORKSPACE/scripts/run-codex-with-context.sh"

usage() {
  sed -n '2,33p' "$0" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

ARTIFACT="$1"
shift

FOCUS="Review this artifact as the independent REVIEWER (Adoption gate, reverse-review side). Prioritize false-pass paths, missing evidence, publish/readiness claims, and whether the declared gate status is justified."
OUTPUT=""
REQUIRE_APPROVE=0
CONFIRM_CLOSURE=0
SKIP_PREFLIGHT=""
PROFILE="${CODEX_REVIEW_PROFILE:-default}"

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
    --profile)
      [[ $# -ge 2 ]] || { echo "ERROR: --profile requires a value" >&2; exit 2; }
      PROFILE="$2"
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

if [[ ! -x "$WRAPPER" ]]; then
  echo "ERROR: Codex wrapper not executable: $WRAPPER" >&2
  exit 2
fi

ARTIFACT_ABS="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"
SLUG="$(basename "$ARTIFACT_ABS" | sed 's/\.[^.]*$//' | tr -cs '[:alnum:]_-' '-' | sed 's/^-//; s/-$//')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# Deterministic preflight. Runs BEFORE the round guard so a blocked preflight never
# spends a review round. Fail-open on an internal error (logged as `error`): it is an
# author aid, not a safety boundary. Same block in run-claude-self-adversarial.sh.
if [[ -n "$SKIP_PREFLIGHT" ]]; then
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" gate-preflight "$ARTIFACT_ABS" skipped "gate=adoption reason=$SKIP_PREFLIGHT" || true
  echo "preflight skipped: $SKIP_PREFLIGHT" >&2
else
  python3 "${GATE_PREFLIGHT_BIN:-$WORKSPACE/scripts/gate-preflight.py}" "$ARTIFACT_ABS" --gate adoption --workspace "$WORKSPACE" >&2
  _pfrc=$?
  if [[ $_pfrc -eq 4 ]]; then
    echo "ERROR: gate preflight blocked this review (no round spent). Fix the findings, or pass --skip-preflight \"<reason>\"." >&2
    exit 4
  elif [[ $_pfrc -ne 0 ]]; then
    [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" gate-preflight "$ARTIFACT_ABS" error "gate=adoption exit=$_pfrc" || true
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
  OUTPUT="$WORKSPACE/worklog/codex-reviews/${STAMP}-${SLUG}.md"
fi

mkdir -p "$(dirname "$OUTPUT")"

log() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" codex-artifact-review "$@" || true
}

log "$ARTIFACT_ABS" queued "output=$OUTPUT profile=$PROFILE"

REVIEW_FOCUS=$(cat <<EOF
$FOCUS

Artifact review output contract:
- Start with: Artifact: $ARTIFACT_ABS
- Then: Focus: <one concise sentence describing the review focus>
- Include sections named exactly: Evidence, Gaps, Risks — each section header MUST be on its own line formatted as either "Evidence:" (trailing colon) or "**Evidence**" (bold); a bare unformatted word fails the report validator
- Evidence must cite source opened in this turn using file:line, command output, log line, screenshot, API response, or database row. If no material issue exists, cite the source evidence that justifies approval. At least one citation MUST use the exact colon format "path/to/file.ext:NN" (e.g. src/config.ts:42) — prose like "lines 28-60" alone fails the report validator.
- Gaps must list anything not checked and why.
- Risks must call out false PASS / false FAIL / environment drift / deploy mismatch / data cleanup or external publish risk where relevant.
- End with exactly one standalone verdict line: Verdict: approve OR Verdict: needs-attention OR Verdict: block
- Keep the report under 220 lines.
EOF
)

# Use the wrapper's adversarial-plan channel: it composes the prompt from
# .claude/templates/codex-adversarial-plan.md, points Codex at the artifact
# path, and avoids the working-tree git-diff injection that would otherwise
# leak unrelated prior-session noise into the review.
#
# AGENT_ROLE=tool tells the wrapper NOT to overwrite .active-binding.md.
# This is a sub-tool spawn from the parent agent's session (Claude calling
# Codex as REVIEWER), not a new Codex session entry.
REVIEWED_SHA="$(shasum -a 256 "$ARTIFACT_ABS" | awk '{print $1}')"
set +e
AGENT_ROLE=tool "$WRAPPER" --profile "$PROFILE" adversarial-plan "$ARTIFACT_ABS" --wait "$REVIEW_FOCUS" > "$OUTPUT" 2>&1
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  REASON="process-exit"
  if grep -Eiq 'usage limit|quota|rate limit|try again|too many requests' "$OUTPUT"; then
    REASON="quota"
  fi
  log "$ARTIFACT_ABS" failed "reason=$REASON exit=$STATUS output=$OUTPUT"
  echo "ERROR: Codex reverse review failed (exit=$STATUS); see $OUTPUT" >&2
  exit "$STATUS"
fi

LINE_COUNT="$(wc -l < "$OUTPUT" | tr -d '[:space:]')"
if [[ "$LINE_COUNT" -lt 10 ]]; then
  log "$ARTIFACT_ABS" malformed "reason=too-short line_count=$LINE_COUNT output=$OUTPUT"
  echo "ERROR: Codex review output is too short to be a valid review report: $OUTPUT" >&2
  exit 1
fi

if [[ "$LINE_COUNT" -gt 220 ]]; then
  log "$ARTIFACT_ABS" malformed "reason=too-long line_count=$LINE_COUNT output=$OUTPUT"
  echo "ERROR: Codex review output is too long for the artifact-review contract: $OUTPUT" >&2
  exit 1
fi

VERDICT="$(grep -E '^Verdict: (approve|needs-attention|block)$' "$OUTPUT" | tail -1 | sed 's/^Verdict: //' || true)"
if [[ -z "$VERDICT" ]]; then
  log "$ARTIFACT_ABS" malformed "reason=missing-verdict output=$OUTPUT"
  echo "ERROR: Codex review did not produce a valid verdict line: $OUTPUT" >&2
  exit 1
fi

if ! grep -Fq "Artifact: $ARTIFACT_ABS" "$OUTPUT"; then
  log "$ARTIFACT_ABS" malformed "reason=missing-artifact-path output=$OUTPUT"
  echo "ERROR: Codex review did not identify the artifact path: $OUTPUT" >&2
  exit 1
fi

for section in Evidence Gaps Risks; do
  if ! grep -Eq "^${section}:$|^\\*\\*${section}\\*\\*" "$OUTPUT"; then
    log "$ARTIFACT_ABS" malformed "reason=missing-section section=$section output=$OUTPUT"
    echo "ERROR: Codex review is missing required section '$section': $OUTPUT" >&2
    exit 1
  fi
done

if ! grep -Eq '(^|[^[:alnum:]_./-])([[:alnum:]_.@/+:-]+:[0-9]+|command output|log line|screenshot|API response|database row)' "$OUTPUT"; then
  log "$ARTIFACT_ABS" malformed "reason=missing-source-evidence output=$OUTPUT"
  echo "ERROR: Codex review does not include source evidence: $OUTPUT" >&2
  exit 1
fi

log "$ARTIFACT_ABS" review-complete "verdict=$VERDICT output=$OUTPUT sha256=$REVIEWED_SHA"

echo "Codex review written: $OUTPUT"
echo "Verdict: $VERDICT"

if [[ "$REQUIRE_APPROVE" -eq 1 && "$VERDICT" != "approve" ]]; then
  exit 1
fi
