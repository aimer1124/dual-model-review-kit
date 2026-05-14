# Dual Model Review Kit

This kit packages a practical Codex + Claude review workflow that can be copied into another repository.

The operating model is:

- Codex is the primary execution agent for source reading, local implementation, tests, draft artifacts, and first-pass adversarial review.
- Claude is the independent gate reviewer for high-risk artifacts such as formal plans, QA verdict packages, external publish packages, test skip/baseline changes, and AI-finding adoption.
- Findings from either model are not accepted from summaries alone. Source evidence must be opened and verified before adoption.
- High-risk artifacts remain `Draft` or `Needs attention` until a gate review returns `Verdict: approve` or the owner records an explicit override.

## Contents

```text
dual-model-review-kit/
  install.sh
  scripts/
    run-codex-with-context.sh
    run-claude-artifact-review.sh
    codex-hook-log.sh
    check-codex-publish-gate.sh
    record-codex-audit-receipt.sh
  claude-hooks/
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
- Optional: a repository-specific `.codex-context.md` and `scripts/export-codex-context.sh`. The wrapper works without them, but context refresh is skipped.

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

Hook scripts are copied into `.claude/hooks/`, but they are not guaranteed to be active in every Claude Code setup. Register them in your local Claude Code hook settings if your environment does not auto-discover hooks.

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

Example:

```bash
CODEX_MODEL_DEFAULT=<your-model> scripts/run-codex-with-context.sh --profile default task --background "Review this change."
```

## Core Commands

Run a normal Codex task:

```bash
scripts/run-codex-with-context.sh --profile default task --background --write "Implement the requested change and verify it."
```

Run a deeper Codex task:

```bash
scripts/run-codex-with-context.sh --profile deep task --background --write "Investigate this cross-module issue and propose a bounded fix."
```

Review the current working tree:

```bash
scripts/run-codex-with-context.sh adversarial-review --background --scope working-tree "Focus on regressions, missing tests, and false-pass paths."
```

Review a branch against `origin/main`:

```bash
scripts/run-codex-with-context.sh adversarial-review --background --scope branch --base origin/main "Focus on behavior changes and release risk."
```

Review a plan file:

```bash
scripts/run-codex-with-context.sh adversarial-plan docs/plans/example.md --background \
  "Treat the author as confident-but-wrong. Focus on missing evidence, false-pass paths, and silent assumptions."
```

Do not use `adversarial-review` for plan files. Use `adversarial-plan`; it isolates the plan body from unrelated working-tree state.

Run Claude gate review on a high-risk artifact:

```bash
scripts/run-claude-artifact-review.sh docs/plans/example.md --require-approve
```

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

## Standard Workflow

1. Codex creates or updates the artifact.
2. Run Codex adversarial review.
3. Read the Codex result.
4. Source-verify every material finding before adoption.
5. Update the artifact with evidence, deltas, and gate status.
6. Run Claude artifact review with `--require-approve`.
7. If Claude returns `needs-attention`, fix only source-verified H/M findings, then rerun.
8. Mark the artifact `Reviewed` only after `Verdict: approve`, or record an explicit owner override.

## Logs And Receipts

Wrapper and gate events are logged to:

```text
.codex-hook-log.tsv
```

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
