#!/usr/bin/env bash
# Claude Code PreToolUse:Bash hook: refresh Codex context and log wrapper bypasses.

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

hooklog() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" codex-preflight "$@" || true
}

INPUT="$(cat)"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // ""')"

if [[ -z "$CMD" ]]; then
  echo '{"continue":true}'
  exit 0
fi

if ! echo "$CMD" | grep -qE 'node[[:space:]]+[^"'"'"']*codex-companion\.mjs[[:space:]]+(task|review|adversarial-review)'; then
  echo '{"continue":true}'
  exit 0
fi

SUBCMD="$(echo "$CMD" | grep -oE 'node[[:space:]]+[^"'"'"']*codex-companion\.mjs[[:space:]]+(task|review|adversarial-review)' | grep -oE '(task|review|adversarial-review)[[:space:]]*$' | awk '{print $1}')"

if [[ "$SUBCMD" == "task" || "$SUBCMD" == "adversarial-review" ]]; then
  if ! echo "$CMD" | grep -q 'run-codex-with-context\.sh'; then
    CMD_SHORT="$(echo "$CMD" | cut -c1-120)"
    hooklog "$SUBCMD" "direct-invocation-detected" "bypasses wrapper; cmd=${CMD_SHORT}"
  fi
fi

CTX_FILE="$WORKSPACE/.codex-context.md"
EXPORT_SCRIPT="$WORKSPACE/scripts/export-codex-context.sh"

STATUS=""
if [[ ! -f "$CTX_FILE" ]]; then
  STATUS="missing"
elif [[ $(find "$CTX_FILE" -mtime +1 -print 2>/dev/null) ]]; then
  STATUS="stale"
fi

if [[ -z "$STATUS" ]]; then
  hooklog "$SUBCMD" "refresh-ok" "already fresh"
  echo '{"continue":true}'
  exit 0
fi

if [[ ! -x "$EXPORT_SCRIPT" ]]; then
  hooklog "$SUBCMD" "refresh-skipped" "export script unavailable"
  echo '{"continue":true}'
  exit 0
fi

if OUTPUT="$("$EXPORT_SCRIPT" 2>&1)"; then
  LINES="$(wc -l < "$CTX_FILE" 2>/dev/null | tr -d ' ')"
  hooklog "$SUBCMD" "refresh-stale-to-fresh" "lines=${LINES}"
else
  hooklog "$SUBCMD" "refresh-failed" "export error: $OUTPUT"
fi

echo '{"continue":true}'

