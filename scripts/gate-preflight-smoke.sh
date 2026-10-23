#!/usr/bin/env bash
# gate-preflight-smoke.sh — offline smoke for gate-preflight.py, gate-trajectory.py,
# scope-inventory.sh, the Exit-gate D7 prompt and the preflight wiring in the three
# artifact gate scripts.
#
#   P*  each preflight check fires on a bad fixture and stays quiet on its good twin
#   H*  replays of two real first-round rejections: an owner authorization quoted only
#       from the chat session (PF-07), and a trajectory table that omitted a completed
#       closure round (PF-06)
#   S*  scope-inventory.sh counts root + nested-repo hits and its output satisfies PF-08
#   E*  Exit gate: review-complete row binds sha256 + rule=d7-v1; the prompt carries the
#       D7 materiality threshold, keeps the implementation-evidence hard block, asks for
#       Fix-at-execution and embeds the artifact snapshot
#   G*  gate wiring: enforce blocks with exit 4 and spends no round; warn continues; an
#       internal preflight error fails open with an `error` row; --skip-preflight writes
#       a `skipped` row and runs no preflight; both Adoption scripts block in enforce
#   T*  end to end: Exit approve + Adoption approve on the same bytes -> trajectory says
#       Reviewed and PF-06 accepts a declared "Gate status: Reviewed"
#
# Hermetic: the kit is installed with install.sh into a temp git repo (WORKSPACE points
# there, so the hook log, round-guard rows and preflight reports stay inside it), and a
# stub `claude` on PATH stands in for the reviewer. No network, no real reviewer.
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-preflight-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
mkdir -p "$WS"
git -C "$WS" init -q
"$KIT/install.sh" "$WS" >/dev/null || { echo "FATAL: install.sh failed" >&2; exit 2; }

export WORKSPACE="$WS"
unset GATE_PREFLIGHT_MODE GATE_PREFLIGHT_REPORT_DIR GATE_PREFLIGHT_BIN GATE_PREFLIGHT_PLAN_LINT \
  GATE_RECORD_DIR GATE_EVIDENCE_DIR GATE_PREFLIGHT_SUBREPOS GATE_PREFLIGHT_LINECHECK_SUBREPOS \
  GATE_PATH_ROOTS REVIEW_GUARD_LOG REVIEW_GUARD_DISABLE CX_SCRIPT
LOG="$WS/.codex-hook-log.tsv"; : > "$LOG"
PF="$WS/scripts/gate-preflight.py"
TRAJ="$WS/scripts/gate-trajectory.py"
EXIT_GATE="$WS/scripts/run-claude-self-adversarial.sh"
CLAUDE_ADOPT="$WS/scripts/run-claude-artifact-review.sh"
CODEX_ADOPT="$WS/scripts/run-codex-artifact-review.sh"

# Stub reviewer: keeps the last prompt, answers with a valid 12-line approve report.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<EOS
#!/usr/bin/env bash
cat > "$TMP/last-prompt.txt"
for i in 1 2 3 4 5 6 7 8 9 10 11; do echo "line \$i"; done
echo "Verdict: approve"
EOS
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# Fixture tree: a nested repo, an ambiguous README.md, one tracked file to cite.
mkdir -p "$WS/docs/plans" "$WS/nested"
git -C "$WS/nested" init -q
mkdir -p "$WS/nested/src"
printf 'nested_marker_call()\n' > "$WS/nested/lib.py"
printf 'x = 1\n' > "$WS/nested/src/mod.py"
git -C "$WS/nested" add lib.py src/mod.py
printf 'root readme\n' > "$WS/README.md"
printf 'plans readme\n' > "$WS/docs/plans/README.md"
printf 'nested_marker_call()\nnested_marker_call()\n' > "$WS/scripts/caller.sh"
git -C "$WS" add README.md docs scripts

plan() {  # plan <name> <body-html>  -> path of a minimal html plan
  local p="$WS/docs/plans/$1.html"
  printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n<title>t</title>\n</head>\n<body>\n<main>\n<h2>1. Section</h2>\n%s\n</main>\n</body>\n</html>\n' "$2" > "$p"
  echo "$p"
}
mdplan() {  # mdplan <name> <body-md>
  local p="$WS/docs/plans/$1.md"
  printf '# Plan\n\n%s\n' "$2" > "$p"
  echo "$p"
}
run_pf() {  # run_pf <artifact> [args...] -> stdout in $TMP/pf.out, rc echoed
  python3 "$PF" "$@" --no-log > "$TMP/pf.out" 2>&1; echo $?
}
fires()  { run_pf "$2" >/dev/null; grep -q "  $1 " "$TMP/pf.out" && ok "$3" || bad "$3: $(cat "$TMP/pf.out")"; }
quiet()  { run_pf "$2" >/dev/null; grep -q "  $1 " "$TMP/pf.out" && bad "$3: $(cat "$TMP/pf.out")" || ok "$3"; }

echo "P: checks"
CLEAN="$(plan clean '<p>Uses <code>scripts/gate-trajectory.py</code> and <code>scripts/gate-trajectory.py:1</code>.</p>')"
rc=$(run_pf "$CLEAN"); [[ "$rc" == 0 ]] && grep -q 'preflight pass' "$TMP/pf.out" && ok "P0 clean html plan passes" || bad "P0 rc=$rc $(cat "$TMP/pf.out")"
MDCLEAN="$(mdplan mdclean 'Uses `scripts/gate-trajectory.py:1`, `nested/lib.py` and `src/mod.py` (nested-repo relative).')"
rc=$(run_pf "$MDCLEAN"); [[ "$rc" == 0 ]] && grep -q 'preflight pass' "$TMP/pf.out" && ok "P0 clean markdown plan passes (nested repo path resolves)" || bad "P0md rc=$rc $(cat "$TMP/pf.out")"

fires PF-01 "$(plan p01 '<p>See <code>scripts/does-not-exist-xyz.sh</code>.</p>')" "PF-01 missing path fires"
quiet PF-01 "$(plan p01n '<p>New file <code>scripts/does-not-exist-xyz.sh</code>.</p>')" "PF-01 quiet for a path the block creates"
quiet PF-01 "$(plan p01v '<p>Guard at <code>$WORKSPACE/scripts/does-not-exist-xyz.sh</code> and route <code>GET /reports/x/y.json</code>.</p>')" "PF-01 quiet for \$VAR paths and URL routes"
fires PF-01 "$(mdplan p01m 'See `scripts/does-not-exist-xyz.sh`.')" "PF-01 fires in markdown code spans"
rc=$(GATE_PREFLIGHT_SUBREPOS=off run_pf "$MDCLEAN"); grep -q "  PF-01 " "$TMP/pf.out" && ok "PF-01 GATE_PREFLIGHT_SUBREPOS=off stops nested-repo resolution" || bad "PF-01 subrepos=off: $(cat "$TMP/pf.out")"

fires PF-02 "$(plan p02 '<p>See <code>scripts/gate-trajectory.py:99999</code>.</p>')" "PF-02 anchor past the end fires"
quiet PF-02 "$(plan p02n '<p>See <code>scripts/gate-trajectory.py:1-3</code> and <code>README.md:99999</code>.</p>')" "PF-02 quiet in range and for an ambiguous bare name"
quiet PF-02 "$(plan p02s '<p>See <code>nested/lib.py:99</code>.</p>')" "PF-02 quiet for a nested-repo anchor by default"
P02T="$(plan p02t '<p>See <code>nested/lib.py:99</code>.</p>')"
GATE_PREFLIGHT_LINECHECK_SUBREPOS=nested run_pf "$P02T" >/dev/null; grep -q "  PF-02 " "$TMP/pf.out" && ok "PF-02 checks a nested repo listed in GATE_PREFLIGHT_LINECHECK_SUBREPOS" || bad "PF-02 linecheck: $(cat "$TMP/pf.out")"

fires PF-03 "$(plan p03 '<p>Evidence in <code>/tmp/evidence-run.txt</code>.</p>')" "PF-03 temp evidence path fires"
quiet PF-03 "$(plan p03n '<p>Scratch via <code>mktemp "${TMPDIR:-/tmp}/x.XXXX"</code>.</p>')" "PF-03 quiet for mktemp/TMPDIR idioms"

TSHA="$(shasum -a 256 "$TRAJ" | awk '{print $1}')"
fires PF-04 "$(plan p04 '<p>Bytes sha256 <code>0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef</code>.</p>')" "PF-04 untraceable sha fires"
quiet PF-04 "$(plan p04n "<p><code>scripts/gate-trajectory.py</code> sha256 <code>$TSHA</code>.</p>")" "PF-04 quiet for the sha of a cited file"
mkdir -p "$WS/worklog/notes"; printf 'reviewed bytes fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n' > "$WS/worklog/notes/shas.md"
quiet PF-04 "$(plan p04r '<p>Bytes <code>fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210</code>.</p>')" "PF-04 quiet for a sha written in a record file"

fires PF-05 "$(plan p05 '<p>Anchor <code>origin/main:src/api/never-materialized.ts:12</code>.</p>')" "PF-05 unmaterialized remote anchor fires"
mkdir -p "$WS/worklog/evidence/anchors"; printf 'origin/main src/api/materialized.ts\n12: code\n' > "$WS/worklog/evidence/anchors/a.txt"
quiet PF-05 "$(plan p05n '<p>Anchor <code>origin/main:src/api/materialized.ts:12</code> (<code>worklog/evidence/anchors/a.txt</code>).</p>')" "PF-05 quiet when an evidence file cites the path"

fires PF-08 "$(plan p08 '<p>Only 2 scripts call it.</p>')" "PF-08 uncited count fires"
fires PF-08 "$(plan p08z '<p>工作区里只有 2 个脚本调用它。</p>')" "PF-08 uncited count fires (Chinese phrasing)"

LINT="$TMP/lint.sh"; printf '#!/usr/bin/env bash\n! grep -q LINT-BAD "$1"\n' > "$LINT"; chmod +x "$LINT"
P09="$(plan p09 '<p>LINT-BAD</p>')"
quiet PF-09 "$P09" "PF-09 skipped when GATE_PREFLIGHT_PLAN_LINT is unset"
GATE_PREFLIGHT_PLAN_LINT="$LINT" run_pf "$P09" >/dev/null; grep -q "  PF-09 " "$TMP/pf.out" && ok "PF-09 plan lint failure fires" || bad "PF-09: $(cat "$TMP/pf.out")"
GATE_PREFLIGHT_PLAN_LINT="$LINT" run_pf "$CLEAN" >/dev/null; grep -q "  PF-09 " "$TMP/pf.out" && bad "PF-09 clean: $(cat "$TMP/pf.out")" || ok "PF-09 quiet when the lint passes"

echo "H: history replays"
fires PF-07 "$(plan h1 '<div><b>Gate status</b> <b>Draft</b> (owner decided in chat on 2026-10-08: "retire it")</div>')" "H1 PF-07 catches a session-only authorization"
fires PF-07 "$(plan h1z '<div><b>Gate status</b> <b>Draft</b>（用户决定（2026-10-08，会话内））</div>')" "H1 PF-07 catches a session-only authorization (Chinese phrasing)"
quiet PF-07 "$(plan h1n '<p>Commit once the owner agrees; push requires a separate approval.</p>')" "H1 PF-07 quiet for conditional consent"
mkdir -p "$WS/worklog/decisions"; printf 'owner: retire it\n' > "$WS/worklog/decisions/retire.md"
quiet PF-07 "$(plan h1d '<p>The owner approved in chat on 2026-10-22; record: <code>worklog/decisions/retire.md</code>.</p>')" "H1 PF-07 quiet when a record file is cited"

H2="$(mdplan h2 'Gate status: Draft

| Gate | Round | Verdict | Report |
|---|---|---|---|
| Exit | R1 | `needs-attention` | r1 |
| Exit | R2 | `block` | r2 |
| Adoption | — | pending | — |')"
H2LOG="$TMP/h2-log.tsv"
printf '2026-10-22T13:06:08Z\tclaude-self-adversarial\t%s\treview-complete\tverdict=needs-attention output=r1\n' "$H2" > "$H2LOG"
printf '2026-10-22T13:11:56Z\tclaude-self-adversarial\t%s\treview-complete\tverdict=block output=r2\n' "$H2" >> "$H2LOG"
printf '2026-10-22T13:49:02Z\tround-guard\t%s\tallowed-3\tverdict-reset\n' "$H2" >> "$H2LOG"
printf '2026-10-22T13:54:38Z\tclaude-self-adversarial\t%s\treview-complete\tverdict=approve output=r3\n' "$H2" >> "$H2LOG"
run_pf "$H2" --log "$H2LOG" >/dev/null
grep -q 'omits it' "$TMP/pf.out" && grep -q 'Exit R3' "$TMP/pf.out" && ok "H2 PF-06 catches the omitted completed Exit R3" || bad "H2: $(cat "$TMP/pf.out")"
run_pf "$H2" --log "$H2LOG" --before 2026-10-22T13:50:00Z >/dev/null
grep -q 'PF-06' "$TMP/pf.out" && bad "H2 --before must hide the later round: $(cat "$TMP/pf.out")" || ok "H2 PF-06 quiet when the round is after --before"
python3 "$TRAJ" "$H2" --log "$H2LOG" --format tsv > "$TMP/traj.tsv"
grep -q $'\tExit\tR3 (closure)\tapprove\t' "$TMP/traj.tsv" && ok "H2 trajectory marks the allowed-3 round as a closure round" || bad "H2 traj: $(cat "$TMP/traj.tsv")"
fires PF-06 "$(plan h2r '<div><b>Gate status</b> <b>Reviewed</b></div>')" "PF-06 Reviewed claim without approvals fires"

echo "S: scope inventory"
SOUT="$WS/worklog/evidence/scope/callers.tsv"
"$WS/scripts/scope-inventory.sh" --pattern 'nested_marker_call' --slug callers --fixed --out "$SOUT" >/dev/null
grep -q $'^TOTAL\t-\t3$' "$SOUT" && ok "S1 total counts root + nested repo hits (3)" || bad "S1: $(cat "$SOUT")"
grep -q $'^nested\t' "$SOUT" && ok "S1 nested repo listed" || bad "S1 nested row missing"
"$WS/scripts/scope-inventory.sh" --pattern 'nested_marker_call' --slug callers --fixed --no-subrepos --stdout > "$TMP/s2.tsv"
grep -q $'^TOTAL\t-\t2$' "$TMP/s2.tsv" && ok "S2 --no-subrepos searches the root only (2)" || bad "S2: $(cat "$TMP/s2.tsv")"
quiet PF-08 "$(plan s3 '<p>Only 3 callers exist (<code>worklog/evidence/scope/callers.tsv</code>).</p>')" "S3 PF-08 quiet when the section cites the inventory"
"$WS/scripts/scope-inventory.sh" --pattern x --slug 'Bad Slug' >/dev/null 2>&1; [[ $? == 2 ]] && ok "S4 bad slug exits 2" || bad "S4 bad slug accepted"

echo "E: Exit gate D7 + byte binding"
XPLAN="$WS/docs/plans/exit-plan.md"; printf 'exit plan bytes\n' > "$XPLAN"
want_sha="$(shasum -a 256 "$XPLAN" | awk '{print $1}')"
: > "$LOG"
"$EXIT_GATE" "$XPLAN" --output "$TMP/exit-review.md" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 0 ]] && ok "E1 Exit review runs (exit 0)" || bad "E1 exit=$rc err=$(cat "$TMP/err")"
row="$(grep $'\tclaude-self-adversarial\t.*\treview-complete\t' "$LOG" | tail -1)"
[[ "$row" == *"sha256=$want_sha"* ]] && ok "E1 review-complete row carries the reviewed sha256" || bad "E1 row: $row"
[[ "$row" == *"rule=d7-v1"* ]] && ok "E1 review-complete row carries rule=d7-v1" || bad "E1 row: $row"
P="$TMP/last-prompt.txt"
grep -q 'Verdict threshold: return needs-attention or block only if at least one finding is H' "$P" && ok "E2 prompt has the D7 threshold" || bad "E2 D7 threshold missing"
grep -q 'If the artifact requires implementation evidence' "$P" && ok "E2 prompt keeps the implementation-evidence hard block" || bad "E2 implementation-evidence rule missing"
grep -q 'Fix-at-execution' "$P" && ok "E2 prompt asks for a Fix-at-execution section" || bad "E2 Fix-at-execution missing"
grep -q 'Do not approve unless you actively cannot find' "$P" && bad "E2 old no-threshold rule still present" || ok "E2 old no-threshold rule removed"
grep -q 'exit plan bytes' "$P" && ok "E2 prompt embeds the artifact snapshot" || bad "E2 artifact body missing"

echo "G: gate wiring"
BADPLAN="$(plan gbad '<p>See <code>scripts/does-not-exist-xyz.sh</code>.</p>')"
guard_rows() { grep -c $'\tround-guard\t' "$LOG" || true; }

: > "$LOG"
GATE_PREFLIGHT_MODE=enforce "$EXIT_GATE" "$BADPLAN" --output "$TMP/r1.md" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 4 ]] && ok "G1 enforce: Exit gate exits 4" || bad "G1 rc=$rc $(cat "$TMP/err")"
[[ "$(guard_rows)" == 0 ]] && ok "G1 enforce: no round-guard row (no round spent)" || bad "G1 round-guard rows=$(guard_rows)"
grep -q $'\tgate-preflight\t.*\tblocked\tgate=exit mode=enforce' "$LOG" && ok "G1 enforce: gate-preflight blocked row" || bad "G1 no blocked row: $(cat "$LOG")"
grep -q 'review-complete' "$LOG" && bad "G1 a verdict row was written" || ok "G1 enforce: no review-complete row"
ls "$WS/worklog/preflight/"*gbad*.txt >/dev/null 2>&1 && ok "G1 report written under the workspace record dir" || bad "G1 no report in $WS/worklog/preflight"

: > "$LOG"
"$EXIT_GATE" "$BADPLAN" --output "$TMP/r2.md" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 0 ]] && ok "G2 warn (default): Exit gate continues" || bad "G2 rc=$rc $(cat "$TMP/err")"
grep -q $'\tgate-preflight\t.*\twarn\t' "$LOG" && ok "G2 warn: gate-preflight warn row" || bad "G2 no warn row"
[[ "$(guard_rows)" == 1 ]] && ok "G2 warn: exactly one round-guard row" || bad "G2 round-guard rows=$(guard_rows)"

: > "$LOG"
ERRPF="$TMP/stub-preflight.py"; printf 'import sys\nsys.exit(2)\n' > "$ERRPF"
GATE_PREFLIGHT_BIN="$ERRPF" GATE_PREFLIGHT_MODE=enforce "$EXIT_GATE" "$BADPLAN" --output "$TMP/r3.md" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 0 ]] && ok "G3 fail-open: gate continues after a preflight internal error" || bad "G3 rc=$rc $(cat "$TMP/err")"
grep -q $'\tgate-preflight\t.*\terror\tgate=exit exit=2' "$LOG" && ok "G3 fail-open: error row" || bad "G3 no error row: $(cat "$LOG")"
grep -q $'\tround-guard\t.*\tallowed-1\t' "$LOG" && ok "G3 fail-open: round guard ran (allowed-1)" || bad "G3 no allowed-1 row"

: > "$LOG"
GATE_PREFLIGHT_MODE=enforce "$EXIT_GATE" "$BADPLAN" --output "$TMP/r4.md" --skip-preflight "owner accepted the missing path" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 0 ]] && ok "G4 skip: gate continues" || bad "G4 rc=$rc $(cat "$TMP/err")"
grep -q $'\tgate-preflight\t.*\tskipped\tgate=exit reason=owner accepted the missing path' "$LOG" && ok "G4 skip: skipped row carries the reason" || bad "G4 no skipped row: $(cat "$LOG")"
grep -qE $'\tgate-preflight\t.*\t(warn|blocked|pass)\t' "$LOG" && bad "G4 preflight still ran" || ok "G4 skip: preflight not run"
"$EXIT_GATE" "$BADPLAN" --skip-preflight >/dev/null 2>&1; [[ $? == 2 ]] && ok "G4 --skip-preflight without a reason exits 2" || bad "G4 empty reason accepted"

: > "$LOG"
GATE_PREFLIGHT_MODE=enforce "$CLAUDE_ADOPT" "$BADPLAN" --output "$TMP/r5.md" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 4 && "$(guard_rows)" == 0 ]] && ok "G5 enforce: Claude Adoption gate exits 4 with no round spent" || bad "G5 rc=$rc rows=$(guard_rows) $(cat "$TMP/err")"
grep -q $'\tgate-preflight\t.*\tblocked\tgate=adoption' "$LOG" && ok "G5 blocked row says gate=adoption" || bad "G5 no adoption row: $(cat "$LOG")"

: > "$LOG"
GATE_PREFLIGHT_MODE=enforce "$CODEX_ADOPT" "$BADPLAN" --output "$TMP/r6.md" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 4 && "$(guard_rows)" == 0 ]] && ok "G6 enforce: Codex Adoption gate exits 4 with no round spent" || bad "G6 rc=$rc rows=$(guard_rows) $(cat "$TMP/err")"

: > "$LOG"
"$CLAUDE_ADOPT" "$BADPLAN" --output "$TMP/r7.md" --skip-preflight "known gap" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" == 0 ]] && grep -q $'\tgate-preflight\t.*\tskipped\tgate=adoption reason=known gap' "$LOG" && ok "G7 Adoption --skip-preflight logs and continues" || bad "G7 rc=$rc $(cat "$LOG")"

echo "T: end to end"
: > "$LOG"
TPLAN="$WS/docs/plans/e2e-plan.md"
printf '# Plan\n\nGate status: Reviewed\n\nUses `scripts/gate-trajectory.py`.\n' > "$TPLAN"
tsha="$(shasum -a 256 "$TPLAN" | awk '{print $1}')"
run_pf "$TPLAN" >/dev/null; grep -q "  PF-06 " "$TMP/pf.out" && ok "T1 PF-06 fires before any approval" || bad "T1: $(cat "$TMP/pf.out")"
"$EXIT_GATE" "$TPLAN" --output "$TMP/t-exit.md" >/dev/null 2>"$TMP/err" || bad "T2 Exit gate rc=$? $(cat "$TMP/err")"
"$CLAUDE_ADOPT" "$TPLAN" --output "$TMP/t-adopt.md" >/dev/null 2>"$TMP/err" || bad "T2 Adoption gate rc=$? $(cat "$TMP/err")"
grep $'\tclaude-artifact-review\t.*\treview-complete\t' "$LOG" | grep -q "sha256=$tsha" && ok "T2 Adoption review-complete row carries the reviewed sha256" || bad "T2 adoption row: $(grep review-complete "$LOG")"
python3 "$TRAJ" "$TPLAN" > "$TMP/traj.md"
grep -q '^Gate status: Reviewed (Exit: R1 approve (current bytes); Adoption: R1 approve (current bytes)' "$TMP/traj.md" && ok "T3 trajectory derives Reviewed on the current bytes" || bad "T3: $(cat "$TMP/traj.md")"
run_pf "$TPLAN" >/dev/null; grep -q "  PF-06 " "$TMP/pf.out" && bad "T4 PF-06 still fires: $(cat "$TMP/pf.out")" || ok "T4 PF-06 accepts the declared Reviewed status"
printf 'edit\n' >> "$TPLAN"
python3 "$TRAJ" "$TPLAN" | grep -q '^Gate status: Draft .*bytes changed' && ok "T5 an edit after approval drops back to Draft (bytes changed)" || bad "T5: $(python3 "$TRAJ" "$TPLAN")"
python3 "$TRAJ" "$TPLAN" --format html | grep -q '<tr><td>Exit</td><td>R1; sha256 <code>' && ok "T6 html format renders the trajectory table" || bad "T6 html"

echo; echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
