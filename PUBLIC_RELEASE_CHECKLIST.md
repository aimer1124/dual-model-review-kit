# Public Release Checklist

Run this checklist before pushing the kit to a personal or public repository.

## Content Scan

```bash
PROJECT_TERMS="<project-name>|<local-username>|<absolute-local-path>|<integration-name>|<cloud-provider>|<credential-label>"
rg -n "$PROJECT_TERMS" dual-model-review-kit
find dual-model-review-kit -name ".DS_Store" -o -name "._*"
git add -n dual-model-review-kit
```

Expected result:

- No project names.
- No usernames or local absolute paths.
- No credentials, tokens, API keys, or private keys.
- No macOS sidecar files.
- Only the intended kit files are staged.

## Script Check

```bash
bash -n dual-model-review-kit/install.sh dual-model-review-kit/scripts/*.sh dual-model-review-kit/claude-hooks/*.sh
```

## Archive Guidance

Prefer committing the source folder directly.

If you need a shareable zip:

```bash
zip -X -r dual-model-review-kit-sanitized.zip dual-model-review-kit
zipinfo -1 dual-model-review-kit-sanitized.zip | rg '^__MACOSX|/\.DS_Store|/\._|<project-name>|<local-username>'
```

The second command should produce no matches.

Avoid publishing default macOS `tar` archives unless owner/group and extended metadata are stripped.

## Repo Hygiene

- Include `LICENSE`.
- Keep generated logs out of commits unless intentionally publishing them.
- Document required local tools: `node`, `claude`, Codex companion, `git`, `rg`, `python3`, `jq`, `zip`.
- Make model names configurable through environment variables rather than hard requirements.
