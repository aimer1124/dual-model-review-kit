#!/usr/bin/env bash
# scope-inventory.sh — full-tree enumeration across the repository root and any nested
# repos, written as durable evidence an artifact can cite for "only N / all N" claims.
#
# Why: an incomplete enumeration ("15 call sites, the plan found 4") is a common gate
# rejection, and a workspace whose root .gitignore hides nested repos makes a Grep/Glob
# or `rg` rooted at the top silently miss them. This runs `git -C <repo> grep` per repo
# so nothing is skipped, and records the exact commands, each repo's HEAD, per-repo hit
# counts and every hit line.
#
# Usage:
#   scripts/scope-inventory.sh --pattern <ERE> --slug <slug> [--fixed] [--untracked]
#                              [--exclude <pathspec>]... [--no-subrepos]
#                              [--out <file> | --stdout]
#
#   --fixed        treat the pattern as a fixed string (git grep -F) instead of ERE
#   --untracked    also search untracked, non-ignored files (git grep --untracked)
#   --exclude      pathspec to leave out, e.g. '*.md' or 'worklog' (repeatable)
#   --no-subrepos  search the root repo only (default: root + every <root>/*/.git)
#   --out          default <root>/${GATE_EVIDENCE_DIR:-worklog/evidence}/<YYYY-MM>/scope-inventory/<YYYY-MM-DD>-<slug>.tsv
#
# Cite the output path next to the count in the artifact; scripts/gate-preflight.py
# PF-08 accepts a count only in a section that cites an evidence file.
#
# Read-only against every repo (git grep / rev-parse only; never fetches). The working
# tree is searched as it is: run `git fetch` + compare with the remote yourself when the
# claim is about a remote ref. The root is resolved like the other kit scripts
# (WORKSPACE, else git toplevel, else cwd).
#
# Exit: 0 = written (zero hits is a valid result), 2 = usage error.
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
EVIDENCE_DIR="${GATE_EVIDENCE_DIR:-worklog/evidence}"

usage() { sed -n '2,30p' "$0" >&2; }

PATTERN=""; SLUG=""; FIXED=0; UNTRACKED=0; SUBREPOS=1; OUT=""; TO_STDOUT=0; EXCLUDES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern) [[ $# -ge 2 ]] || { usage; exit 2; }; PATTERN="$2"; shift 2 ;;
    --slug) [[ $# -ge 2 ]] || { usage; exit 2; }; SLUG="$2"; shift 2 ;;
    --fixed) FIXED=1; shift ;;
    --untracked) UNTRACKED=1; shift ;;
    --exclude) [[ $# -ge 2 ]] || { usage; exit 2; }; EXCLUDES+=("$2"); shift 2 ;;
    --no-subrepos) SUBREPOS=0; shift ;;
    --out) [[ $# -ge 2 ]] || { usage; exit 2; }; OUT="$2"; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$PATTERN" ]] || { echo "ERROR: --pattern is required" >&2; exit 2; }
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{0,59}$ ]] || { echo "ERROR: --slug must match [a-z0-9-], max 60 chars" >&2; exit 2; }

GREP_ARGS=(grep -n -I)
(( FIXED )) && GREP_ARGS+=(-F) || GREP_ARGS+=(-E)
(( UNTRACKED )) && GREP_ARGS+=(--untracked)
GREP_ARGS+=(-e "$PATTERN" --)
SPECS=(.)
for x in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do SPECS+=(":(exclude)$x"); done

quote() { local a out=""; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s' "${out% }"; }
CMD_SHOWN="git -C <repo> $(quote "${GREP_ARGS[@]}" "${SPECS[@]}")"

REPOS=(.)
if (( SUBREPOS )); then
  while IFS= read -r d; do REPOS+=("${d#"$WORKSPACE"/}"); done < <(find "$WORKSPACE" -mindepth 2 -maxdepth 2 -name .git -exec dirname {} \; | sort)
fi

TABLE=""; HITS=""; TOTAL=0
for r in "${REPOS[@]}"; do
  dir="$WORKSPACE/$r"; [[ "$r" == "." ]] && dir="$WORKSPACE"
  sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "-")"
  out="$(git -C "$dir" "${GREP_ARGS[@]}" "${SPECS[@]}" 2>/dev/null)"
  n=0; [[ -n "$out" ]] && n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  TOTAL=$((TOTAL + n))
  TABLE+="$r"$'\t'"$sha"$'\t'"$n"$'\n'
  if [[ -n "$out" ]]; then
    prefix=""; [[ "$r" != "." ]] && prefix="$r/"
    HITS+="$(printf '%s\n' "$out" | sed "s|^|# $prefix|")"$'\n'
  fi
done

SCOPE_DESC="root only"
(( SUBREPOS )) && SCOPE_DESC="root + every <root>/*/.git"
REPORT="# scope inventory: $SLUG
# generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/scope-inventory.sh
# pattern: $PATTERN
# command per repo: $CMD_SHOWN
# repos: $SCOPE_DESC (${#REPOS[@]} total)
repo	head_sha	hits
${TABLE}TOTAL	-	$TOTAL
# hits:
${HITS}"

if (( TO_STDOUT )); then
  printf '%s' "$REPORT"
  exit 0
fi
if [[ -z "$OUT" ]]; then
  OUT="$WORKSPACE/$EVIDENCE_DIR/$(date +%Y-%m)/scope-inventory/$(date +%Y-%m-%d)-$SLUG.tsv"
fi
mkdir -p "$(dirname "$OUT")"
printf '%s' "$REPORT" > "$OUT"
echo "scope inventory: total=$TOTAL across ${#REPOS[@]} repos -> ${OUT#"$WORKSPACE"/}"
