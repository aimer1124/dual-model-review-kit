#!/usr/bin/env bash
# Codex Adoption gate for chat plans, used when REVIEWER=Codex.
#
# Why it exists:
#   When PRIMARY=Claude and REVIEWER=Codex, a chat plan that needs the
#   Adoption gate cannot use a Claude-side slash-command equivalent of
#   `/plan-review`. This script bridges the gap: accept the chat plan body
#   via stdin or a file path, materialize it to a tmp file so the wrapper
#   has a stable path, then forward to run-codex-artifact-review.sh.
#
# Usage:
#   echo "<plan markdown>" | scripts/run-codex-chat-plan-review.sh [--focus "text"] [--require-approve]
#   scripts/run-codex-chat-plan-review.sh <file> [--focus "text"] [--require-approve]
#
# Output:
#   Pass-through of run-codex-artifact-review.sh — report under
#   worklog/codex-reviews/, log row tagged codex-artifact-review.

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
REVIEW_SCRIPT="$WORKSPACE/scripts/run-codex-artifact-review.sh"

usage() {
  sed -n '2,17p' "$0" >&2
}

if [[ ! -x "$REVIEW_SCRIPT" ]]; then
  echo "ERROR: missing $REVIEW_SCRIPT" >&2
  exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP_PLAN="${TMPDIR:-/tmp}/chat-plan-${STAMP}.md"

if [[ $# -ge 1 && -f "$1" ]]; then
  SOURCE="$1"
  cp "$SOURCE" "$TMP_PLAN"
  shift
else
  if [[ -t 0 ]]; then
    echo "ERROR: no plan content. Pipe via stdin or pass a file path." >&2
    usage
    exit 2
  fi
  cat > "$TMP_PLAN"
fi

if [[ ! -s "$TMP_PLAN" ]]; then
  echo "ERROR: plan content is empty: $TMP_PLAN" >&2
  exit 2
fi

echo "Chat plan materialized: $TMP_PLAN" >&2

exec "$REVIEW_SCRIPT" "$TMP_PLAN" "$@"
