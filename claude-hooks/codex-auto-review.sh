#!/usr/bin/env bash
# Claude Code PostToolUse hook: queue file-focused Codex review for plans/specs/docs/skills.

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

hooklog() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" codex-auto-review "$@" || true
}

INPUT="$(cat)"
FILE="$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // ""')"

if [[ -z "$FILE" ]]; then
  echo '{"continue":true}'
  exit 0
fi

case "$FILE" in
  */worklog/*|*/OUTSTANDING_ITEMS.md|*/.codex-context.md|*/.codex-hook-log.tsv)
    echo '{"continue":true}'
    exit 0
    ;;
esac

MATCH=""
case "$FILE" in
  */.claude/plans/*.md) MATCH="plan" ;;
  */specs/*.md|*/specs/**/*.md) MATCH="spec" ;;
  */docs/*.md|*/docs/**/*.md) MATCH="docs" ;;
  */.claude/skills/*/SKILL.md) MATCH="skill" ;;
esac

if [[ -z "$MATCH" ]]; then
  echo '{"continue":true}'
  exit 0
fi

THROTTLE_DIR="/tmp/codex-auto-review-throttle"
mkdir -p "$THROTTLE_DIR"
HASH="$(printf '%s' "$FILE" | shasum | awk '{print $1}')"
MARKER="$THROTTLE_DIR/$HASH"

if [[ -f "$MARKER" ]]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER") ))
  if (( AGE < 1800 )); then
    hooklog "$FILE" "skipped-throttle" "age=${AGE}s"
    echo '{"continue":true}'
    exit 0
  fi
fi
touch "$MARKER"

if [[ ! -x "$WRAPPER" ]]; then
  hooklog "$FILE" "plugin-missing" "$MATCH"
  echo '{"continue":true}'
  exit 0
fi

SHORT="${FILE#"$WORKSPACE"/}"
FOCUS_PROMPT=$(cat <<EOF
Review the $MATCH file just edited: $SHORT

Scope: only this file. Do not expand to unrelated working-tree changes.

Checks:
1. Logic or content errors specific to this file.
2. Missing scenarios or edge cases for this file type.
3. Conflicts with project rules.
4. For plans: phase boundaries, evidence quality, and false-pass paths.
5. For specs: locator verification and workflow coverage.
6. For docs: claims traceable to source.
7. For skills: claims traceable to actual scripts/hooks.

Return concise pass items, issues, and ambiguities. If healthy, say so briefly.
EOF
)

# AGENT_ROLE=tool prevents the wrapper from flipping .active-binding.md —
# this is a Claude-session PostToolUse spawning Codex as REVIEWER, not a new
# top-level Codex session.
( nohup env AGENT_ROLE=tool "$WRAPPER" --profile cheap-review task --background "$FOCUS_PROMPT" >/dev/null 2>&1 & ) &
hooklog "$FILE" "queued" "$MATCH"

MSG="Codex file-focused review queued for $MATCH edit ($SHORT). Poll status and retrieve result through the Codex wrapper."
MSG_ESC="$(printf '%s' "$MSG" | sed 's/"/\\"/g')"
echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"'"$MSG_ESC"'"}}'

