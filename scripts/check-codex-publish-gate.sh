#!/usr/bin/env bash
# Verify that an external publish flow has a recent Codex audit and receipt.

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
LOG="${CODEX_GATE_LOG_PATH:-$WORKSPACE/.codex-hook-log.tsv}"
RECEIPTS="${CODEX_AUDIT_RECEIPTS_PATH:-$WORKSPACE/.codex-audit-receipts.tsv}"
MAX_AGE_SECONDS="${CODEX_GATE_MAX_AGE_SECONDS:-86400}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/check-codex-publish-gate.sh <regression|bug-triage> [target] [--log-only]

Checks:
  1. A recent wrapper-routed Codex task exists for the matching prompt type.
  2. Unless --log-only is passed, a recent approved/revise-handled receipt exists.
  3. If target is provided, the receipt target must match it exactly.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

CONTEXT="$1"
shift

TARGET=""
LOG_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --log-only) LOG_ONLY=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$arg"
      else
        echo "Unexpected argument: $arg" >&2
        usage
        exit 2
      fi
      ;;
  esac
done

case "$CONTEXT" in
  regression) REQUIRED_PATTERN="codex-regression" ;;
  bug-triage) REQUIRED_PATTERN="codex-bug-triage" ;;
  *) echo "BLOCK: invalid context '$CONTEXT'. Use regression or bug-triage." >&2; exit 2 ;;
esac

if [[ ! -f "$LOG" ]]; then
  echo "BLOCK: Codex hook log not found: $LOG" >&2
  exit 1
fi

if ! LOG_MATCH=$(
  python3 - "$LOG" "$MAX_AGE_SECONDS" "$REQUIRED_PATTERN" <<'PY'
import datetime as dt
import sys

path = sys.argv[1]
max_age = int(sys.argv[2])
pattern = sys.argv[3]
now = dt.datetime.now(dt.timezone.utc)

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for raw in reversed(fh.readlines()):
        parts = raw.rstrip("\n").split("\t")
        if len(parts) < 5:
            continue
        ts, hook, target, action, note = parts[:5]
        if hook != "wrapper" or target != "task" or action != "wrapper-invoked":
            continue
        if pattern not in note:
            continue
        try:
            when = dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
        if (now - when).total_seconds() <= max_age:
            print(raw.rstrip("\n"))
            sys.exit(0)

sys.exit(1)
PY
); then
  echo "BLOCK: no recent wrapper-routed Codex task found for '$REQUIRED_PATTERN' in $LOG." >&2
  echo "Run: scripts/run-codex-with-context.sh task --background --prompt-file /tmp/${REQUIRED_PATTERN}-<target>.md" >&2
  exit 1
fi

if (( LOG_ONLY )); then
  echo "OK: recent Codex audit task found for context=$CONTEXT"
  echo "$LOG_MATCH"
  exit 0
fi

if [[ ! -f "$RECEIPTS" ]]; then
  echo "BLOCK: Codex audit receipt file not found: $RECEIPTS" >&2
  echo "After reading the Codex result and source-verifying decisive findings, run scripts/record-codex-audit-receipt.sh." >&2
  exit 1
fi

if ! RECEIPT_MATCH=$(
  python3 - "$RECEIPTS" "$MAX_AGE_SECONDS" "$CONTEXT" "$TARGET" <<'PY'
import datetime as dt
import sys

path = sys.argv[1]
max_age = int(sys.argv[2])
context = sys.argv[3]
target_filter = sys.argv[4]
allowed = {"approve", "revise-handled"}
now = dt.datetime.now(dt.timezone.utc)

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for raw in reversed(fh.readlines()):
        parts = raw.rstrip("\n").split("\t")
        if len(parts) < 5:
            continue
        ts, row_context, target, job_id, verdict = parts[:5]
        if row_context != context or verdict not in allowed:
            continue
        if target_filter and target != target_filter:
            continue
        try:
            when = dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
        if (now - when).total_seconds() <= max_age:
            print(raw.rstrip("\n"))
            sys.exit(0)

sys.exit(1)
PY
); then
  echo "BLOCK: no recent approved Codex audit receipt for context=$CONTEXT${TARGET:+ target=$TARGET}." >&2
  echo "After source-verifying the Codex result, run: scripts/record-codex-audit-receipt.sh $CONTEXT <target> <job-id> approve" >&2
  exit 1
fi

echo "OK: Codex publish gate satisfied for context=$CONTEXT${TARGET:+ target=$TARGET}"
echo "Audit task: $LOG_MATCH"
echo "Receipt: $RECEIPT_MATCH"

