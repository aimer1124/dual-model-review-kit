#!/usr/bin/env bash
# Record that a human/Claude reviewer read and handled a Codex audit result.

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
LOG="$WORKSPACE/.codex-audit-receipts.tsv"

usage() {
  echo "Usage: $0 <regression|bug-triage> <target> <job-id> <approve|revise-handled|block|override> [note]" >&2
}

if [[ $# -lt 4 ]]; then
  usage
  exit 2
fi

CONTEXT="$1"
TARGET="$2"
JOB_ID="$3"
VERDICT="$4"
NOTE="${5:-}"

case "$CONTEXT" in
  regression|bug-triage) ;;
  *) echo "Invalid context: $CONTEXT" >&2; usage; exit 2 ;;
esac

case "$VERDICT" in
  approve|revise-handled|block|override) ;;
  *) echo "Invalid verdict: $VERDICT" >&2; usage; exit 2 ;;
esac

clean() {
  printf '%s' "$1" | tr '\t\n\r' '   '
}

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$TS" \
  "$(clean "$CONTEXT")" \
  "$(clean "$TARGET")" \
  "$(clean "$JOB_ID")" \
  "$(clean "$VERDICT")" \
  "$(clean "$NOTE")" \
  >> "$LOG"

echo "Recorded Codex audit receipt: context=$CONTEXT target=$TARGET job=$JOB_ID verdict=$VERDICT"

