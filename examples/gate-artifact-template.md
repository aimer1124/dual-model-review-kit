# Gate Artifact Template

Gate status: Draft
Owner:
Timestamp:
Binding: PRIMARY= / REVIEWER= / PUBLISHER=
Exit-gate verdict:
Adoption-gate verdict:

## Scope

- Target:
- Change or decision:
- External impact:

## Evidence Checked

- Source files (cite file:line):
- Commands run (and outputs):
- Logs / screenshots / API responses / DB rows:

## Exit Gate (PRIMARY self-adversarial)

- Tool: (run-codex-with-context.sh adversarial-review | run-claude-self-adversarial.sh)
- Job / report:
- Verdict:
- Material findings:

Exit gate `approve` unlocks "may start implementing / may deliver first pass". The artifact remains `Draft` even after Exit-gate approval.

## Adoption Delta

- Adopted findings (with source file:line cited):
- Rejected findings (with reason):
- Source verification notes:

## Adoption Gate (REVIEWER reverse review)

- Tool: (run-claude-artifact-review.sh | run-codex-artifact-review.sh | run-codex-chat-plan-review.sh)
- Report path:
- Verdict:
- Required deltas:

Adoption gate `approve` unlocks "may publish externally / mark `Reviewed`". External writes (task tracker comments, chat-system posts, customer-visible artifacts, any other publish boundary) must wait until this stage clears or an explicit `Override` is recorded below.

## Remaining Risks

- Risk:
- Mitigation or owner decision:

## Override (only if applicable)

- Reason a gate was skipped:
- Owner accepting the risk:
- Compensating control (manual review, follow-up ticket, etc.):
