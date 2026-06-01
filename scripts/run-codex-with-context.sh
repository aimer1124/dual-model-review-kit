#!/usr/bin/env bash
# Canonical wrapper around Codex companion with project-rule prefix injection.

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

find_codex_companion() {
  if [[ -n "${CX_SCRIPT:-}" ]]; then
    printf '%s\n' "$CX_SCRIPT"
    return
  fi

  local root latest candidate
  root="$HOME/.claude/plugins/cache/openai-codex/codex"
  latest="$(ls -1 "$root" 2>/dev/null | sort -V | tail -1 || true)"
  candidate="$root/$latest/scripts/codex-companion.mjs"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
  else
    printf '%s\n' ""
  fi
}

if ! command -v node >/dev/null 2>&1; then
  for candidate in "$HOME"/.asdf/installs/nodejs/[0-9]*/bin "$HOME/.nvm/current/bin" /opt/homebrew/bin /usr/local/bin; do
    if [[ -x "$candidate/node" ]]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi

WORKSPACE="$(resolve_workspace)"
LOG_HELPER="$WORKSPACE/scripts/codex-hook-log.sh"
EXPORT_SCRIPT="$WORKSPACE/scripts/export-codex-context.sh"
CTX_FILE="$WORKSPACE/.codex-context.md"
SESSION_SCRIPT="$WORKSPACE/scripts/enter-codex-session.sh"
CX_SCRIPT_RESOLVED="$(find_codex_companion)"

# Declare PRIMARY=Codex for top-level wrapper invocations and keep Codex
# context fresh. Sub-tool callers set AGENT_ROLE=tool, so the helper preserves
# the parent session's binding.
if [[ -x "$SESSION_SCRIPT" ]]; then
  "$SESSION_SCRIPT" codex-wrapper >/dev/null 2>&1 || true
fi

log() {
  [[ -x "$LOG_HELPER" ]] && "$LOG_HELPER" wrapper "$@" || true
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--profile default|deep|xdeep|cheap-review] <subcommand> [args...]" >&2
  log "-" "error" "no subcommand"
  exit 2
fi

PROFILE=""
case "${1:-}" in
  --profile)
    if [[ $# -lt 3 ]]; then
      echo "ERROR: --profile requires a value and subcommand" >&2
      log "-" "error" "missing profile value"
      exit 2
    fi
    PROFILE="$2"
    shift 2
    ;;
  --profile=*)
    PROFILE="${1#--profile=}"
    shift
    ;;
esac

SUBCMD="$1"
shift

PROFILE_MODEL=""
PROFILE_EFFORT=""
if [[ -n "$PROFILE" ]]; then
  case "$PROFILE" in
    default) PROFILE_MODEL="${CODEX_MODEL_DEFAULT:-gpt-5.5}"; PROFILE_EFFORT="${CODEX_EFFORT_DEFAULT:-medium}" ;;
    deep) PROFILE_MODEL="${CODEX_MODEL_DEEP:-gpt-5.5}"; PROFILE_EFFORT="${CODEX_EFFORT_DEEP:-high}" ;;
    xdeep) PROFILE_MODEL="${CODEX_MODEL_XDEEP:-gpt-5.5}"; PROFILE_EFFORT="${CODEX_EFFORT_XDEEP:-xhigh}" ;;
    cheap-review) PROFILE_MODEL="${CODEX_MODEL_CHEAP_REVIEW:-gpt-5.4-mini}"; PROFILE_EFFORT="${CODEX_EFFORT_CHEAP_REVIEW:-medium}" ;;
    *)
      echo "ERROR: unknown profile: $PROFILE" >&2
      log "$SUBCMD" "error" "unknown profile=$PROFILE"
      exit 2
      ;;
  esac
fi

has_flag_value() {
  local flag="$1"
  shift
  local arg
  for arg in "$@"; do
    [[ "$arg" == "$flag" || "$arg" == "$flag="* ]] && return 0
  done
  return 1
}

needs_ctx=0
case "$SUBCMD" in
  task|review|adversarial-review|adversarial-plan) needs_ctx=1 ;;
esac

if (( needs_ctx )); then
  if [[ -x "$EXPORT_SCRIPT" ]]; then
    if [[ ! -f "$CTX_FILE" ]] || [[ $(find "$CTX_FILE" -mtime +1 -print 2>/dev/null) ]]; then
      "$EXPORT_SCRIPT" >/dev/null 2>&1 && log "$SUBCMD" "refresh-stale-to-fresh" "" \
        || log "$SUBCMD" "refresh-failed" ""
    else
      log "$SUBCMD" "refresh-ok" "already fresh"
    fi
  else
    log "$SUBCMD" "refresh-skipped" "export script missing"
  fi
fi

if [[ -z "$CX_SCRIPT_RESOLVED" || ! -f "$CX_SCRIPT_RESOLVED" ]]; then
  echo "ERROR: codex-companion.mjs not found. Set CX_SCRIPT=/absolute/path/to/codex-companion.mjs." >&2
  log "$SUBCMD" "plugin-missing" ""
  exit 127
fi

ALWAYS_ON_PREFIX=$(cat <<'EOF'
PROJECT RULES - apply before doing anything below:

1. Verify before delivery: factual claims must trace to source reads or command output from this turn.
2. Read implementation, not summaries, before tracing flows or debugging behavior.
3. Codex may do local reversible work: reads, bounded edits, focused tests/lint/typecheck/build checks, local browser checks, and non-destructive git inspection.
4. Stop for approval or gate review before external writes, final QA verdicts, git push/merge/rebase/tag/release, deploys, migrations, destructive data commands, file deletions, test coverage reductions, secrets, production data, or shared-environment mutation.
5. Claude owns high-risk gate review for formal plans, QA verdict packages, external publish packages, test skip/baseline changes, and AI-finding adoption.
6. Findings from either model must be source-verified before adoption when they affect code, tests, external publish, verdicts, or plan exits.
7. Mark high-risk artifacts Draft until current review evidence shows Verdict: approve or an explicit owner override.
8. Prefer narrow, evidence-grounded findings over broad speculation.
9. Top-level Codex sessions must mark the binding before gate decisions: use this wrapper for companion work, or `scripts/enter-codex-session.sh codex-api` for API / in-app sessions. Sub-tool spawns must set `AGENT_ROLE=tool` so they preserve the parent binding.

---

EOF
)

inject_prompt_args() {
  local subcmd="$1"
  shift

  local profiled_args=("$@")
  if [[ -n "$PROFILE_MODEL" ]] && ! has_flag_value "--model" "${profiled_args[@]}"; then
    profiled_args=(--model "$PROFILE_MODEL" "${profiled_args[@]}")
  fi
  if [[ "$subcmd" == "task" && -n "$PROFILE_EFFORT" ]] && ! has_flag_value "--effort" "${profiled_args[@]}"; then
    profiled_args=(--effort "$PROFILE_EFFORT" "${profiled_args[@]}")
  fi

  local prompt_file_arg="" prompt_file_mode="" expecting_prompt_file=0
  local args=() arg
  for arg in "${profiled_args[@]}"; do
    if (( expecting_prompt_file )); then
      prompt_file_arg="$arg"
      args+=("__PROMPT_FILE_VALUE__")
      expecting_prompt_file=0
      continue
    fi
    case "$arg" in
      --prompt-file)
        prompt_file_mode="separate"
        args+=("$arg")
        expecting_prompt_file=1
        ;;
      --prompt-file=*)
        prompt_file_mode="equals"
        prompt_file_arg="${arg#--prompt-file=}"
        args+=("__PROMPT_FILE_EQUALS__")
        ;;
      *)
        args+=("$arg")
        ;;
    esac
  done

  if [[ -n "$prompt_file_arg" ]]; then
    local prompt_abs prefixed_prompt_file final_args=()
    if [[ "$prompt_file_arg" == ~* ]]; then
      prompt_abs="${prompt_file_arg/#\~/$HOME}"
    elif [[ "$prompt_file_arg" == /* ]]; then
      prompt_abs="$prompt_file_arg"
    else
      prompt_abs="$(pwd)/$prompt_file_arg"
    fi
    if [[ ! -f "$prompt_abs" ]]; then
      echo "ERROR: prompt file not found: $prompt_abs" >&2
      log "$subcmd" "error" "prompt file not found"
      exit 2
    fi
    prefixed_prompt_file="$(mktemp -t cx-prompt.XXXXXX)"
    {
      printf '%s\n' "$ALWAYS_ON_PREFIX"
      cat "$prompt_abs"
    } > "$prefixed_prompt_file"
    for arg in "${args[@]}"; do
      case "$arg" in
        __PROMPT_FILE_VALUE__) final_args+=("$prefixed_prompt_file") ;;
        __PROMPT_FILE_EQUALS__) final_args+=("--prompt-file=$prefixed_prompt_file") ;;
        *) final_args+=("$arg") ;;
      esac
    done
    log "$subcmd" "wrapper-invoked" "profile=${PROFILE:-none} prefix-injected-prompt-file source=$prompt_abs prompt-file=$prefixed_prompt_file"
    exec node "$CX_SCRIPT_RESOLVED" "$subcmd" "${final_args[@]}"
  fi

  if [[ ${#profiled_args[@]} -eq 0 ]]; then
    log "$subcmd" "wrapper-invoked" "profile=${PROFILE:-none} no user prompt"
    exec node "$CX_SCRIPT_RESOLVED" "$subcmd" "$ALWAYS_ON_PREFIX"
  fi

  local last_idx user_prompt final_prompt
  last_idx=$((${#profiled_args[@]} - 1))
  user_prompt="${profiled_args[$last_idx]}"
  unset 'profiled_args[$last_idx]'
  final_prompt="${ALWAYS_ON_PREFIX}${user_prompt}"
  log "$subcmd" "wrapper-invoked" "profile=${PROFILE:-none} prefix-injected"
  exec node "$CX_SCRIPT_RESOLVED" "$subcmd" "${profiled_args[@]}" "$final_prompt"
}

case "$SUBCMD" in
  task|adversarial-review)
    inject_prompt_args "$SUBCMD" "$@"
    ;;
  review|setup|status|result|cancel)
    log "$SUBCMD" "wrapper-invoked" "passthrough"
    exec node "$CX_SCRIPT_RESOLVED" "$SUBCMD" "$@"
    ;;
  adversarial-plan)
    profiled_args=("$@")
    if [[ -n "$PROFILE_MODEL" ]] && ! has_flag_value "--model" "${profiled_args[@]}"; then
      profiled_args=(--model "$PROFILE_MODEL" "${profiled_args[@]}")
    fi
    if [[ -n "$PROFILE_EFFORT" ]] && ! has_flag_value "--effort" "${profiled_args[@]}"; then
      profiled_args=(--effort "$PROFILE_EFFORT" "${profiled_args[@]}")
    fi

    if [[ ${#profiled_args[@]} -eq 0 ]]; then
      echo "ERROR: adversarial-plan requires a plan file path" >&2
      exit 2
    fi

    TEMPLATE_FILE="$WORKSPACE/.claude/templates/codex-adversarial-plan.md"
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
      echo "ERROR: adversarial-plan template missing: $TEMPLATE_FILE" >&2
      exit 2
    fi

    plan_path=""
    passthrough_args=()
    focus_parts=()
    expecting_value=0
    value_flags="model|effort|cwd|prompt-file|base|scope"

    for arg in "${profiled_args[@]}"; do
      if (( expecting_value )); then
        passthrough_args+=("$arg")
        expecting_value=0
        continue
      fi
      case "$arg" in
        --wait)
          ;;
        --background|--json|--write|--resume|--resume-last|--fresh)
          passthrough_args+=("$arg")
          ;;
        --*=*)
          passthrough_args+=("$arg")
          ;;
        --*)
          passthrough_args+=("$arg")
          key="${arg#--}"
          if [[ "$key" =~ ^($value_flags)$ ]]; then
            expecting_value=1
          fi
          ;;
        *)
          if [[ -z "$plan_path" ]]; then
            plan_path="$arg"
          else
            focus_parts+=("$arg")
          fi
          ;;
      esac
    done

    if [[ -z "$plan_path" ]]; then
      echo "ERROR: first positional argument must be the plan path" >&2
      exit 2
    fi

    if [[ "$plan_path" == ~* ]]; then
      plan_abs="${plan_path/#\~/$HOME}"
    elif [[ "$plan_path" == /* ]]; then
      plan_abs="$plan_path"
    else
      plan_abs="$(pwd)/$plan_path"
    fi
    if [[ ! -f "$plan_abs" ]]; then
      echo "ERROR: plan file not found: $plan_abs" >&2
      exit 2
    fi

    focus_text="${focus_parts[*]:-No extra focus provided.}"
    plan_body="$(cat "$plan_abs")"
    template="$(cat "$TEMPLATE_FILE")"
    composed="$(printf '%s' "$template" | awk -v plan_path="$plan_abs" -v focus="$focus_text" '
      { gsub(/\{\{PLAN_PATH\}\}/, plan_path); gsub(/\{\{USER_FOCUS\}\}/, focus); print }
    ')"
    prompt_file="$(mktemp -t cx-adv-plan.XXXXXX)"
    {
      printf '%s\n' "$ALWAYS_ON_PREFIX"
      printf '%s\n' "$composed" | sed "/{{PLAN_BODY}}/,\$d"
      printf '%s\n' "$plan_body"
      printf '%s\n' "$composed" | awk '/\{\{PLAN_BODY\}\}/{flag=1;next} flag'
    } > "$prompt_file"

    log "$SUBCMD" "wrapper-invoked" "profile=${PROFILE:-none} plan=$plan_abs prompt-file=$prompt_file"
    if (( ${#passthrough_args[@]} )); then
      exec node "$CX_SCRIPT_RESOLVED" task --prompt-file "$prompt_file" "${passthrough_args[@]}"
    else
      exec node "$CX_SCRIPT_RESOLVED" task --prompt-file "$prompt_file"
    fi
    ;;
  *)
    echo "ERROR: unknown Codex subcommand: $SUBCMD" >&2
    log "$SUBCMD" "error" "unknown subcommand"
    exit 2
    ;;
esac
