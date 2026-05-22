#!/usr/bin/env bash
# Install the portable dual-model review kit into a target repository.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$(pwd)}"
TARGET="$(cd "$TARGET" && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

copy_with_backup() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" ]]; then
    cp "$dst" "$dst.bak.$STAMP"
  fi
  cp "$src" "$dst"
}

copy_exec() {
  copy_with_backup "$1" "$2"
  chmod +x "$2"
}

copy_exec "$KIT_DIR/scripts/run-codex-with-context.sh" "$TARGET/scripts/run-codex-with-context.sh"
copy_exec "$KIT_DIR/scripts/run-claude-artifact-review.sh" "$TARGET/scripts/run-claude-artifact-review.sh"
copy_exec "$KIT_DIR/scripts/run-codex-artifact-review.sh" "$TARGET/scripts/run-codex-artifact-review.sh"
copy_exec "$KIT_DIR/scripts/run-claude-self-adversarial.sh" "$TARGET/scripts/run-claude-self-adversarial.sh"
copy_exec "$KIT_DIR/scripts/run-codex-chat-plan-review.sh" "$TARGET/scripts/run-codex-chat-plan-review.sh"
copy_exec "$KIT_DIR/scripts/codex-hook-log.sh" "$TARGET/scripts/codex-hook-log.sh"
copy_exec "$KIT_DIR/scripts/check-codex-publish-gate.sh" "$TARGET/scripts/check-codex-publish-gate.sh"
copy_exec "$KIT_DIR/scripts/record-codex-audit-receipt.sh" "$TARGET/scripts/record-codex-audit-receipt.sh"

copy_exec "$KIT_DIR/claude-hooks/codex-auto-review.sh" "$TARGET/.claude/hooks/codex-auto-review.sh"
copy_exec "$KIT_DIR/claude-hooks/codex-preflight.sh" "$TARGET/.claude/hooks/codex-preflight.sh"
copy_exec "$KIT_DIR/claude-hooks/set-active-binding.sh" "$TARGET/.claude/hooks/set-active-binding.sh"
copy_with_backup "$KIT_DIR/claude-templates/codex-adversarial-plan.md" "$TARGET/.claude/templates/codex-adversarial-plan.md"

echo "Installed dual-model review kit into: $TARGET"
echo "Backups, if any, use suffix: .bak.$STAMP"
echo
echo "Next checks:"
echo "  scripts/run-codex-with-context.sh status"
echo "  scripts/run-claude-artifact-review.sh <artifact> --require-approve"
echo "  scripts/run-codex-artifact-review.sh <artifact> --require-approve"
echo "  scripts/run-claude-self-adversarial.sh <draft> --require-approve"
echo
echo "Register .claude/hooks/set-active-binding.sh in your Claude Code SessionStart"
echo "hook chain so PRIMARY=Claude is declared on session entry."

