# Author Preflight Checklist (run BEFORE requesting an Exit or Adoption gate)

Most first-round `needs-attention` verdicts come from a small set of recurring, author-preventable patterns. Run
this checklist against your draft (plan, verdict package, publish package) before invoking any gate tool. Every
item is a yes/no check you can settle with one command or one read. If any answer is "no", fix the draft first —
a gate round costs far more than the check.

Items tagged `[PF-xx]` are also checked by `scripts/gate-preflight.py`, which the three artifact gate scripts
run before their round guard (warn mode by default; `GATE_PREFLIGHT_MODE=enforce` makes findings exit 4 without
spending a round). Run `python3 scripts/gate-preflight.py <artifact>` yourself first. The tag covers only the
mechanical half — existence, range, citation; whether the cited content supports the claim stays your check.

## 1. Every citation is real and says what you claim
- [ ] `[PF-01, PF-02: existence + line range only]` For every `file:line` cited, `sed -n '<line>p' <file>`
      returns text that supports the claim — not just "the file exists".
- [ ] `[PF-01: paths only]` Every script, tool or gate you cite as existing infrastructure was confirmed with
      `ls` / `rg` in this session, never from memory or a previous plan.
- [ ] External behavior claims (CI action outputs, library line numbers) are locally verifiable or explicitly
      marked "unverified external claim".

## 2. The premise is current against HEAD
- [ ] Each source file the draft describes as "missing X" or "needs change Y" was re-read this turn
      (`git log --oneline -5 -- <file>` plus the current lines).
- [ ] Status sections inside the draft match current reality, not the state when drafting started.

## 3. Verification paths cannot false-pass
- [ ] Every guard you rely on actually fails on the bad case: exit codes propagate, output is asserted
      non-empty, values derived from subcommands are validated before use.
- [ ] Nothing described as a "gate" is really warn-only / exit 0 — read the script's exit behavior first.
- [ ] You ran the negative channel at least once: break it, run, see red, restore.

## 4. Evidence is durable and byte-exact
- [ ] `[PF-03: no temp paths]` Every decisive artifact (API responses, query output, run logs) is saved under
      the record dir (`worklog/` by default, `GATE_RECORD_DIR`) — not `/tmp`, not chat-only.
- [ ] `[PF-01, PF-04]` Evidence files are cited by path; every full sha256 in the draft traces to a cited file,
      a hook-log row or a record file.
- [ ] `[PF-05]` A `file:line` anchored to a remote ref (`origin/<branch>:<path>:<n>`) cites an evidence file
      under the record dir that contains that path, so the reviewer can open what you saw.
- [ ] Verification runs are reproducible: exact command line, environment and timestamp are in the draft.

## 5. Gate status is honest and self-consistent
- [ ] `[PF-06]` The gate-status line and the trajectory table are pasted from
      `python3 scripts/gate-trajectory.py <artifact>`, not typed. `Reviewed` requires an Exit approve or an owner
      Override, plus an Adoption approve whose `sha256=` matches the current bytes.
- [ ] `[PF-06]` No section contradicts the header (e.g. a history table still claiming an old approve after edits).
- [ ] `[PF-07]` Every past-tense owner authorization or Override names a durable record file or has a
      `user-override` row in `.codex-hook-log.tsv`.
- [ ] The draft does not declare PASS or publish movement before the gate it is requesting.

## 6. Coverage claims match what you observed
- [ ] `[PF-08: citation only]` Every "only N / all N" count sits in a section that cites an evidence file.
      Enumerate with `scripts/scope-inventory.sh --pattern <ERE> --slug <slug>` (it searches nested repos that a
      root `.gitignore` hides) and cite its output path next to the count.
- [ ] "This proves X" claims are scoped to exactly what the probes covered; unchecked consumers are named.

## 7. Internal consistency
- [ ] Counts and percentages cross-foot (table rows vs headline numbers).
- [ ] No two sections describe conflicting mechanics.

## 8. Change-set disclosure
- [ ] `git status --short` + `git diff --stat` reconcile 1:1 with the draft's list of changed files.
- [ ] Rollback for each risky step is a concrete command, and its automation level is stated truthfully.

## 9. Project lint (optional)
- [ ] `[PF-09]` If the repository has a plan/document linter, it is wired as `GATE_PREFLIGHT_PLAN_LINT` and
      exits 0 on the draft.
