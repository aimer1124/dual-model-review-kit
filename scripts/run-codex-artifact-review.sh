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
#   scripts/run-codex-artifact-review.sh <artifact-path> [--focus "text"] [--output <path>] [--require-approve] [--profile <name>]
#
# Intended scope:
#   Same as the Claude-side counterpart — high-risk artifacts only (formal
#   plans, QA verdict / publish packages, external publish boundaries, test
#   skip / baseline changes, AI-agent output adoption).
#
# Output:
#   Markdown report under worklog/codex-reviews/<timestamp>-<slug>.md and a
#   row in .codex-hook-log.tsv with hook=codex-artifact-review.

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
  sed -n '2,21p' "$0" >&2
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
    --profile)
      [[ $# -ge 2 ]] || { echo "ERROR: --profile requires a value" >&2; exit 2; }
      PROFILE="$2"
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

if [[ ! -x "$WRAPPER" ]]; then
  echo "ERROR: Codex wrapper not executable: $WRAPPER" >&2
  exit 2
fi

ARTIFACT_ABS="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"
SLUG="$(basename "$ARTIFACT_ABS" | sed 's/\.[^.]*$//' | tr -cs '[:alnum:]_-' '-' | sed 's/^-//; s/-$//')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$WORKSPACE/worklog/codex-reviews/${STAMP}-${SLUG}.md"
fi

mkdir -p "$(dirname "$OUTPUT")"

log() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" codex-artifact-review "$@" || true
}

log "$ARTIFACT_ABS" queued "output=$OUTPUT profile=$PROFILE"

# AGENT_ROLE=tool tells the wrapper NOT to overwrite .active-binding.md.
# This is a sub-tool spawn from the parent agent's session (Claude calling
# Codex as REVIEWER), not a new Codex session entry.
set +e
AGENT_ROLE=tool "$WRAPPER" --profile "$PROFILE" adversarial-plan "$ARTIFACT_ABS" --wait "$FOCUS" > "$OUTPUT" 2>&1
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  log "$ARTIFACT_ABS" failed "exit=$STATUS output=$OUTPUT"
  echo "ERROR: Codex reverse review failed (exit=$STATUS); see $OUTPUT" >&2
  exit "$STATUS"
fi

LINE_COUNT="$(wc -l < "$OUTPUT" | tr -d '[:space:]')"
if [[ "$LINE_COUNT" -lt 10 ]]; then
  log "$ARTIFACT_ABS" malformed "line_count=$LINE_COUNT output=$OUTPUT"
  echo "ERROR: Codex review output is too short to be a valid review report: $OUTPUT" >&2
  exit 1
fi

VERDICT="$(grep -E '^Verdict: (approve|needs-attention|block)$' "$OUTPUT" | tail -1 | sed 's/^Verdict: //' || true)"
if [[ -z "$VERDICT" ]]; then
  log "$ARTIFACT_ABS" malformed "output=$OUTPUT"
  echo "ERROR: Codex review did not produce a valid verdict line: $OUTPUT" >&2
  exit 1
fi

log "$ARTIFACT_ABS" review-complete "verdict=$VERDICT output=$OUTPUT"

echo "Codex review written: $OUTPUT"
echo "Verdict: $VERDICT"

if [[ "$REQUIRE_APPROVE" -eq 1 && "$VERDICT" != "approve" ]]; then
  exit 1
fi
