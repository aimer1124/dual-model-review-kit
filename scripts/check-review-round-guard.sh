#!/usr/bin/env bash
# check-review-round-guard.sh — code-level enforcement of the review-loop
# stop-counter rule: a review loop is hard-capped at R1 baseline + 1 rerun.
#
# Hard-blocks (exit 3) the 3rd non-approve round per key unless --confirm-closure
# is passed. The behavioral rule stays authoritative; this guard makes it
# non-bypassable by inattention.
#
# It counts ONLY its own structured rows:
#   <ts> | round-guard | <key> | allowed-<n> | <mode>
# never wrapper-invoked / review-complete rows (the adversarial-review path
# carries no per-key column, so those rows cannot be counted per key).
#
# Usage:
#   check-review-round-guard.sh --key <key> --mode <verdict-reset|time-window> \
#       [--confirm-closure] [--window-seconds N]
#
# Modes:
#   verdict-reset  count allowed-* rows AFTER this key's most recent
#                  `review-complete ... verdict=approve` row (approve resets the
#                  loop). Use for callers that emit a verdict row: the
#                  artifact-review and self-adversarial scripts.
#   time-window    count allowed-* rows within --window-seconds (default 7200=2h).
#                  Use for verdict-blind callers (the Codex adversarial-review path).
#
# Exit: 0 allow, 3 block, 0 on fail-open. Prints `round=<n>`.
# Env:  REVIEW_GUARD_LOG      (default <workspace>/.codex-hook-log.tsv)
#       REVIEW_GUARD_DISABLE=1  global bypass (fail-open)
#
# Fail-open invariant: a guard bug must never block ALL reviews. Missing/unreadable
# log, awk error, or bad input -> exit 0 (allow).
#
# Portability: macOS awk (BSD nawk) has no mktime, so the time-window check uses
# numeric YYYYMMDDHHMMSS comparison against a precomputed cutoff, not mktime.

set -uo pipefail   # deliberately NOT -e: we control exit codes for fail-open

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
LOG="${REVIEW_GUARD_LOG:-$WORKSPACE/.codex-hook-log.tsv}"

KEY=""
MODE=""
CONFIRM=0
WINDOW=7200

usage() { sed -n '2,30p' "$0" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)            KEY="${2:-}"; shift 2 ;;
    --mode)           MODE="${2:-}"; shift 2 ;;
    --confirm-closure) CONFIRM=1; shift ;;
    --window-seconds) WINDOW="${2:-7200}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "guard: ignoring unknown arg '$1'" >&2; shift ;;
  esac
done

clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }

append_row() {
  # $1 action, $2 note
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "round-guard" "$(clean "$KEY")" "$(clean "$1")" "$(clean "$2")" \
    >> "$LOG" 2>/dev/null || true
}

# Fail open on bad input rather than block.
if [[ -z "$KEY" || -z "$MODE" ]]; then
  echo "guard: missing --key/--mode; fail-open allow" >&2
  exit 0
fi
if [[ "$MODE" != "verdict-reset" && "$MODE" != "time-window" ]]; then
  echo "guard: bad --mode '$MODE'; fail-open allow" >&2
  exit 0
fi

# Global bypass.
if [[ "${REVIEW_GUARD_DISABLE:-0}" == "1" ]]; then
  append_row "guard-skip" "disabled"
  echo "round=skip (REVIEW_GUARD_DISABLE=1)"
  exit 0
fi

# Count prior allowed rounds for this key.
N=0
if [[ -f "$LOG" ]]; then
  if [[ "$MODE" == "verdict-reset" ]]; then
    N=$(awk -F'\t' -v key="$KEY" '
      $3==key && $4=="review-complete" && $5 ~ /(^| )verdict=approve( |$)/ { reset=NR }
      $3==key && $2=="round-guard" && $4 ~ /^allowed-/ { line[NR]=1 }
      END { n=0; for (ln in line) if (ln+0 > reset+0) n++; print n+0 }
    ' "$LOG" 2>/dev/null) || N=""
  else
    # time-window mode. macOS awk (BSD nawk) lacks mktime, so compare numeric
    # YYYYMMDDHHMMSS timestamps against a precomputed cutoff instead of using mktime.
    _now_epoch="$(date +%s)"
    _cutoff_epoch=$(( _now_epoch - WINDOW ))
    _cutoff="$(date -u -r "$_cutoff_epoch" +%Y%m%d%H%M%S 2>/dev/null \
      || date -u -d "@$_cutoff_epoch" +%Y%m%d%H%M%S 2>/dev/null)"
    if [[ "$_cutoff" =~ ^[0-9]{14}$ ]]; then
      N=$(awk -F'\t' -v key="$KEY" -v cutoff="$_cutoff" '
        $3==key && $2=="round-guard" && $4 ~ /^allowed-/ {
          t=$1; gsub(/[-T:Z]/, "", t);
          if (t+0 >= cutoff+0) n++
        }
        END { print n+0 }
      ' "$LOG" 2>/dev/null) || N=""
    else
      N=""   # cutoff unavailable -> fail open below
    fi
  fi
fi

# Fail open if awk produced no clean integer.
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
  append_row "guard-skip" "count-error mode=$MODE"
  echo "round=unknown (guard fail-open)" >&2
  exit 0
fi

ROUND=$((N + 1))

if [[ "$ROUND" -ge 3 && "$CONFIRM" -ne 1 ]]; then
  append_row "blocked-$ROUND" "$MODE"
  echo "round=$ROUND BLOCKED" >&2
  echo "review-round-guard: round $ROUND for key '$KEY' (mode=$MODE) without reaching approve." >&2
  echo "Per the review-loop stop-counter rule: stop and escalate, or pass --confirm-closure for a closure round after a material change. Bypass: REVIEW_GUARD_DISABLE=1." >&2
  exit 3
fi

append_row "allowed-$ROUND" "$MODE"
if [[ "$ROUND" -ge 3 ]]; then
  echo "round=$ROUND (confirm-closure)"
else
  echo "round=$ROUND"
fi
exit 0
