# Dual Model Review Kit

This kit packages a practical Codex + Claude review workflow that can be copied into another repository.

## Operating Model

Roles are decoupled from agent names so the binding can flip without rewriting governance or scripts:

- **PRIMARY** — the user-facing session. Drafts artifacts, runs source reading and local implementation, and owns the Exit gate via its own adversarial self-review.
- **REVIEWER** — the independent gate reviewer. Runs the Adoption gate for high-risk artifacts (formal plans, QA verdict packages, external publish packages, test skip/baseline changes, AI-finding adoption).
- **PUBLISHER** — the agent that finalizes external writes (task trackers, chat systems, final verdicts, publish boundaries). Always the last step after an Adoption-gate approve.

Default binding when both agents are available: `PRIMARY=Codex`, `REVIEWER=Claude`, `PUBLISHER=Claude`. The kit also supports the inverted binding `PRIMARY=Claude`, `REVIEWER=Codex` and ships symmetric scripts for both directions. The current binding is written to `.active-binding.md` at the repo root by whichever top-level entry point launched the session.

Two stage-gates govern artifact state:

- **Exit gate** unlocks "may start implementing / may deliver first pass". Owned by `PRIMARY`. The draft stays `Draft` even after Exit.
- **Adoption gate** unlocks "may publish externally / mark `Reviewed`". Owned by `REVIEWER`. Required before any external write or before citing the artifact as adopted.

Findings from either side are not accepted from summaries alone. Source evidence must be opened and verified before adoption.

## Contents

```text
dual-model-review-kit/
  install.sh
  scripts/
    enter-codex-session.sh               # Codex API / in-app session entry marker
    run-codex-with-context.sh             # Codex wrapper + Exit gate for PRIMARY=Codex
    run-claude-artifact-review.sh         # Adoption gate when REVIEWER=Claude
    run-codex-artifact-review.sh          # Adoption gate when REVIEWER=Codex
    run-claude-self-adversarial.sh        # Exit gate for PRIMARY=Claude
    run-codex-chat-plan-review.sh         # chat-plan Adoption gate when REVIEWER=Codex
    codex-hook-log.sh
    check-codex-publish-gate.sh
    record-codex-audit-receipt.sh
  claude-hooks/
    set-active-binding.sh                 # SessionStart: writes .active-binding.md
    codex-auto-review.sh
    codex-preflight.sh
  claude-templates/
    codex-adversarial-plan.md
  examples/
    gate-artifact-template.md
  LICENSE
  PUBLIC_RELEASE_CHECKLIST.md
```

## Prerequisites

- A git repository.
- `node` available on `PATH`.
- Claude CLI available as `claude`.
- Codex companion script available through the Claude Code Codex plugin, or set `CX_SCRIPT=/absolute/path/to/codex-companion.mjs`.
- Optional: a repository-specific `.codex-context.md` and `scripts/export-codex-context.sh`. The Codex entry scripts work without them, but context refresh is skipped.

## Before Publishing This Kit

If you publish this kit in a personal or public repository, run:

```bash
PROJECT_TERMS="<project-name>|<local-username>|<absolute-local-path>|<integration-name>|<cloud-provider>|<credential-label>"
rg -n "$PROJECT_TERMS" dual-model-review-kit
find dual-model-review-kit -name ".DS_Store" -o -name "._*"
git add -n dual-model-review-kit
```

Do not publish local archives created by default `tar` on macOS if you care about owner/group metadata. Prefer the source folder itself, or create release archives with metadata stripped.

## Install

From this kit directory:

```bash
./install.sh /path/to/target/repo
```

If run from the target repo, the argument can be omitted:

```bash
./install.sh
```

The installer copies:

- scripts into `<repo>/scripts/`
- hooks into `<repo>/.claude/hooks/`
- templates into `<repo>/.claude/templates/`

Existing target files are backed up as `*.bak.<timestamp>` before being replaced.

Hook scripts are copied into `.claude/hooks/`, but they are not guaranteed to be active in every Claude Code setup. Register them in your local Claude Code hook settings if your environment does not auto-discover hooks. In particular, register `set-active-binding.sh` in the SessionStart chain so `PRIMARY=Claude` is declared whenever you enter a Claude session.

Also add to your project `.gitignore`:

```text
.active-binding.md
.codex-hook-log.tsv
.codex-audit-receipts.tsv
worklog/claude-reviews/
worklog/codex-reviews/
worklog/claude-self-adversarial/
```

## Active Binding

`.active-binding.md` at the repo root holds the live binding:

```text
PRIMARY=Codex
REVIEWER=Claude
PUBLISHER=Claude
BOUND_AT=...
BOUND_BY=codex-wrapper | claude-session-start-hook
```

Two entry points write this file:

- `scripts/enter-codex-session.sh` writes it for Codex API / in-app sessions that bypass the companion wrapper.
- `scripts/run-codex-with-context.sh` calls `enter-codex-session.sh` on every top-level wrapper invocation (so a Codex task sees `PRIMARY=Codex`).
- `.claude/hooks/set-active-binding.sh` writes it on Claude SessionStart (so a Claude session sees `PRIMARY=Claude`).

The file is gitignored and per-machine. Read it programmatically when deciding which gate tool to call.

If a Codex entry point does not run through the wrapper, run this before making gate decisions:

```bash
scripts/enter-codex-session.sh codex-api
```

The helper also refreshes `.codex-context.md` when `scripts/export-codex-context.sh` exists and the context is missing or older than 24h.

## Sub-Tool Invocation Contract

Any script that spawns the *other* agent as a sub-tool (reverse review, Exit-gate self-adversarial, health check, PostToolUse review queue) MUST export `AGENT_ROLE=tool` before launching the child. The binding writers (`set-active-binding.sh`, `enter-codex-session.sh`, and the Codex wrapper) skip writing `.active-binding.md` when this env var is set, preserving the parent session's binding.

Forgetting `AGENT_ROLE=tool` is a real bug: a sub-tool spawn silently flips the binding mid-session, and every downstream gate-tool lookup in the parent session resolves to the wrong script. All scripts in this kit set the variable; new sub-tool callers must follow the same convention.

## Model Configuration

The Codex wrapper has four profiles. Defaults can be overridden without editing the script:

```bash
CODEX_MODEL_DEFAULT=gpt-5.5
CODEX_EFFORT_DEFAULT=medium
CODEX_MODEL_DEEP=gpt-5.5
CODEX_EFFORT_DEEP=high
CODEX_MODEL_XDEEP=gpt-5.5
CODEX_EFFORT_XDEEP=xhigh
CODEX_MODEL_CHEAP_REVIEW=gpt-5.4-mini
CODEX_EFFORT_CHEAP_REVIEW=medium
```

Claude-side scripts honor:

```bash
CLAUDE_REVIEW_MODEL=sonnet
CLAUDE_REVIEW_BUDGET_USD=1.00
```

## Core Commands

Run a normal Codex task:

```bash
scripts/run-codex-with-context.sh --profile default task --background --write "Implement the requested change and verify it."
```

Mark a Codex API / in-app session as the top-level PRIMARY before gate selection:

```bash
scripts/enter-codex-session.sh codex-api
```

Run a deeper Codex task:

```bash
scripts/run-codex-with-context.sh --profile deep task --background --write "Investigate this cross-module issue and propose a bounded fix."
```

Exit-gate self-review for the current working tree (when `PRIMARY=Codex`):

```bash
scripts/run-codex-with-context.sh adversarial-review --background --scope working-tree \
  "Focus on regressions, missing tests, and false-pass paths."
```

Exit-gate self-review for a plan file:

```bash
scripts/run-codex-with-context.sh adversarial-plan docs/plans/example.md --background \
  "Treat the author as confident-but-wrong. Focus on missing evidence, false-pass paths, and silent assumptions."
```

Exit-gate self-review when `PRIMARY=Claude`:

```bash
scripts/run-claude-self-adversarial.sh docs/plans/example.md --require-approve
```

Adoption gate when `REVIEWER=Claude` (default):

```bash
scripts/run-claude-artifact-review.sh docs/plans/example.md --require-approve
```

Adoption gate when `REVIEWER=Codex` (inverted binding):

```bash
scripts/run-codex-artifact-review.sh docs/plans/example.md --require-approve
```

Adoption gate for a chat plan when `REVIEWER=Codex`:

```bash
echo "<plan markdown body>" | scripts/run-codex-chat-plan-review.sh --require-approve
# or
scripts/run-codex-chat-plan-review.sh path/to/plan.md --require-approve
```

All four review entry points emit a final line of the form:

```text
Verdict: approve | needs-attention | block
```

## Gate Tool Selection

Resolve the right tool from the binding, not from hard-coded model names:

| Gate                          | `PRIMARY=Codex`                                              | `PRIMARY=Claude`                          |
| ----------------------------- | ------------------------------------------------------------ | ----------------------------------------- |
| Exit gate                     | `run-codex-with-context.sh adversarial-review` (or `adversarial-plan` for plan files) | `run-claude-self-adversarial.sh`          |
| Adoption gate — saved file    | `run-claude-artifact-review.sh`                              | `run-codex-artifact-review.sh`            |
| Adoption gate — chat plan     | Claude session-side review skill / repeat through saved file | `run-codex-chat-plan-review.sh`           |

## Gate Artifact Status

Every high-risk artifact should include:

```text
Gate status: Draft | Reviewed | Needs attention | Override
Owner:
Timestamp:
Reviewer:
Verdict:
Evidence checked:
Adopted findings:
Rejected findings:
Remaining risks:
```

State transitions:

- `Draft` → `Draft` after Exit gate approves (implementation may start, artifact is not yet adopted).
- `Draft` → `Reviewed` after Adoption gate approves.
- `Draft` → `Needs attention` after Adoption gate returns findings; back to `Draft` after revisions; rerun the Adoption gate.
- `Override` records an explicit owner decision to bypass a gate. The artifact must name the override owner and reason.

## Standard Workflow

1. `PRIMARY` creates or updates the artifact.
2. Run the Exit-gate tool for the current binding. Address findings in source.
3. Once Exit gate returns `approve`, `PRIMARY` may start implementing and may deliver a first pass.
4. Run the Adoption-gate tool for the current binding (`--require-approve`).
5. Source-verify every material finding before adoption. Update the artifact with evidence, deltas, and the new gate status.
6. If the Adoption gate returns `needs-attention`, fix only source-verified H/M findings, then rerun. A third round is allowed only to confirm closure after material changes.
7. Mark the artifact `Reviewed` only after `Verdict: approve`, or record an explicit owner override with a written reason.
8. PUBLISHER finalizes external writes (only after `Reviewed`).

## Logs And Receipts

Wrapper, hook, and gate events are logged to:

```text
.codex-hook-log.tsv
```

Hook tags emitted by this kit:

- `wrapper` — `run-codex-with-context.sh` invocations.
- `claude-artifact-review` — Adoption gate, REVIEWER=Claude.
- `codex-artifact-review` — Adoption gate, REVIEWER=Codex.
- `claude-self-adversarial` — Exit gate, PRIMARY=Claude.

For external publish flows that need an extra receipt:

```bash
scripts/record-codex-audit-receipt.sh regression <target> <job-id> approve "Reviewed and source-verified."
scripts/check-codex-publish-gate.sh regression <target>
```

## Safety Boundary

This kit can cause AI agents to read repository files and run local review commands. Keep the boundary explicit:

- Do not run it in repositories containing production secrets unless you understand what the agents can read.
- Keep external writes, deploys, migrations, destructive commands, and final QA verdicts behind human approval or a gate review.
- Treat AI findings as hypotheses until source evidence has been opened and checked.
- Keep generated logs such as `.codex-hook-log.tsv` and `.codex-audit-receipts.tsv` out of public commits unless you intentionally want to publish them.

## Portability Notes

The scripts resolve the repository root in this order:

1. `WORKSPACE` environment variable
2. `git rev-parse --show-toplevel`
3. current directory

The Codex companion script is resolved in this order:

1. `CX_SCRIPT` environment variable
2. latest `~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs`

## License

MIT. See `LICENSE`.
