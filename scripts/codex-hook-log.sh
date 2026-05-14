#!/usr/bin/env bash
# Append one event row to .codex-hook-log.tsv at the repository root.

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
LOG="$WORKSPACE/.codex-hook-log.tsv"

HOOK="${1:-unknown}"
TARGET="${2:-}"
ACTION="${3:-unknown}"
NOTE="${4:-}"

clean() {
  printf '%s' "$1" | tr '\t\n\r' '   '
}

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$TS" \
  "$(clean "$HOOK")" \
  "$(clean "$TARGET")" \
  "$(clean "$ACTION")" \
  "$(clean "$NOTE")" \
  >> "$LOG"

