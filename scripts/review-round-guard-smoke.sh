#!/usr/bin/env bash
# review-round-guard-smoke.sh — offline smoke test for check-review-round-guard.sh.
# Uses an isolated REVIEW_GUARD_LOG temp file per case so no real log is read or
# written. Exits non-zero if any assertion fails.

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
GUARD="$WORKSPACE/scripts/check-review-round-guard.sh"
PASS=0
FAIL=0

assert_exit() {
  # $1 expected, $2 actual, $3 label
  if [[ "$2" == "$1" ]]; then
    echo "  PASS: $3 (exit $2)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $3 (expected $1, got $2)"; FAIL=$((FAIL + 1))
  fi
}

inject() {
  # $1 log, $2 ts, $3 hook, $4 target, $5 action, $6 note
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" >> "$1"
}

if [[ ! -x "$GUARD" ]]; then
  echo "FATAL: guard not executable: $GUARD" >&2
  exit 2
fi

echo "[verdict-reset]"
L="$(mktemp)"; export REVIEW_GUARD_LOG="$L"; KEY="/tmp/art-vr.md"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 0 $? "round 1 allow"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 0 $? "round 2 allow"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 3 $? "round 3 block"
"$GUARD" --key "$KEY" --mode verdict-reset --confirm-closure >/dev/null 2>&1; assert_exit 0 $? "round 3 --confirm-closure allow"
inject "$L" "2030-01-01T00:00:00Z" "claude-artifact-review" "$KEY" "review-complete" "verdict=approve output=/x"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 0 $? "post-approve reset -> round 1 allow"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 0 $? "post-approve round 2 allow"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 3 $? "post-approve round 3 block"
rm -f "$L"

echo "[verdict-reset: substring false-reset guard]"
L="$(mktemp)"; export REVIEW_GUARD_LOG="$L"; KEY="/tmp/art-vr2.md"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1
# An output path that merely CONTAINS the literal must NOT count as a reset (token-bounded match).
inject "$L" "2030-01-01T00:00:00Z" "claude-artifact-review" "$KEY" "review-complete" "verdict=needs-attention output=/tmp/verdict=approve-trap.md"
"$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 3 $? "fake verdict=approve in path does NOT reset -> round 3 block"
rm -f "$L"

echo "[time-window]"
L="$(mktemp)"; export REVIEW_GUARD_LOG="$L"; KEY="adversarial-review:branch"
"$GUARD" --key "$KEY" --mode time-window >/dev/null 2>&1; assert_exit 0 $? "tw round 1 allow"
"$GUARD" --key "$KEY" --mode time-window >/dev/null 2>&1; assert_exit 0 $? "tw round 2 allow"
"$GUARD" --key "$KEY" --mode time-window >/dev/null 2>&1; assert_exit 3 $? "tw round 3 block"
"$GUARD" --key "$KEY" --mode time-window --confirm-closure >/dev/null 2>&1; assert_exit 0 $? "tw round 3 --confirm-closure allow"
rm -f "$L"

echo "[time-window: rows outside window not counted]"
L="$(mktemp)"; export REVIEW_GUARD_LOG="$L"; KEY="adversarial-review:branch"
inject "$L" "2020-01-01T00:00:00Z" "round-guard" "$KEY" "allowed-1" "time-window"
inject "$L" "2020-01-01T00:00:01Z" "round-guard" "$KEY" "allowed-2" "time-window"
"$GUARD" --key "$KEY" --mode time-window >/dev/null 2>&1; assert_exit 0 $? "2020 rows outside 2h window ignored -> round 1 allow"
rm -f "$L"

echo "[fail-open]"
L="$(mktemp)"; export REVIEW_GUARD_LOG="$L"; KEY="k"
inject "$L" "2030-01-01T00:00:00Z" "round-guard" "$KEY" "allowed-1" "verdict-reset"
inject "$L" "2030-01-01T00:00:01Z" "round-guard" "$KEY" "allowed-2" "verdict-reset"
REVIEW_GUARD_DISABLE=1 "$GUARD" --key "$KEY" --mode verdict-reset >/dev/null 2>&1; assert_exit 0 $? "REVIEW_GUARD_DISABLE=1 bypass allow at round 3"
rm -f "$L"
unset REVIEW_GUARD_LOG
"$GUARD" --mode verdict-reset >/dev/null 2>&1; assert_exit 0 $? "missing --key fail-open allow"
"$GUARD" --key "k" --mode bogus >/dev/null 2>&1; assert_exit 0 $? "bad --mode fail-open allow"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
