#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

bridge__is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

bridge_run_agent() {
  local agent_id="$1"
  local prompt_file="$2"
  local output_file="$3"
  local cwd="${4:-$(pwd)}"
  local model_override="${5:-}"
  local effort="${6:-}"
  local max_turns="${7:-}"

  if [[ -z "$agent_id" ]]; then
    echo "Error: bridge_run_agent requires agent_id." >&2
    return 1
  fi

  local config
  config=$(bridge_load_config)

  local enabled
  enabled=$(jq -r --arg id "$agent_id" '.agents[$id].enabled // false' <<<"$config")
  if [[ "$enabled" != "true" ]]; then
    echo "Error: agent '$agent_id' is not enabled in config." >&2
    return 1
  fi

  local model
  model="${model_override:-}"
  if [[ -z "$model" ]]; then
    model=$(jq -r --arg id "$agent_id" '.agents[$id].default_model // empty' <<<"$config")
  fi
  if [[ -z "$model" ]]; then
    echo "Error: no default_model for agent '$agent_id'." >&2
    return 1
  fi

  local command_name
  command_name=$(jq -r --arg id "$agent_id" '.agents[$id].command // empty' <<<"$config")
  if [[ -z "$command_name" ]] || ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: command '$command_name' for agent '$agent_id' not found in PATH." >&2
    return 1
  fi

  local prompt_transport
  prompt_transport=$(jq -r --arg id "$agent_id" '.agents[$id].prompt_transport // "stdin"' <<<"$config")

  local output_mode
  output_mode=$(jq -r --arg id "$agent_id" '.agents[$id].output_mode // "stdout"' <<<"$config")

  local max_bytes
  max_bytes=$(jq -r --arg id "$agent_id" '.agents[$id].max_prompt_bytes // empty' <<<"$config")

  local capabilities_env_unset
  capabilities_env_unset=$(jq -r --arg id "$agent_id" '
    (.agents[$id].capabilities.env_unset // []) | join("\n")
  ' <<<"$config")

  local prompt_text=""
  if [[ "$prompt_transport" == "arg" ]]; then
    if [[ -n "$max_bytes" ]] && bridge__is_positive_int "$max_bytes"; then
      prompt_text=$(head -c "$max_bytes" "$prompt_file")
    else
      prompt_text=$(cat "$prompt_file")
    fi
  fi

  local -a args=()
  while IFS= read -r -d '' line; do
    args+=("$line")
  done < <(jq -rj --arg id "$agent_id" --arg model "$model" --arg cwd "$cwd" --arg output_file "$output_file" --arg prompt_text "$prompt_text" '
    .agents[$id].args // [] |
    map(
      gsub("\\{\\{model\\}\\}"; $model) |
      gsub("\\{\\{cwd\\}\\}"; $cwd) |
      gsub("\\{\\{output_file\\}\\}"; $output_file) |
      gsub("\\{\\{prompt\\}\\}"; $prompt_text)
    ) |
    .[] + "\u0000"
  ' <<<"$config")

  # Inject effort / max-turns overrides into the agent's args.
  # These come from build.sh --effort / --max-turns; empty means "keep config defaults".
  if [[ -n "$effort" || -n "$max_turns" ]]; then
    local -a fixed=()
    local i=0
    local seen_mt=0 seen_eff=0 seen_ce=0
    case "$agent_id" in
      claude|grok)
        while [[ $i -lt ${#args[@]} ]]; do
          local a="${args[$i]}"
          if [[ "$a" == "--max-turns" && -n "$max_turns" ]]; then
            fixed+=("$a" "$max_turns"); i=$((i+2)); seen_mt=1; continue
          fi
          if [[ "$a" == "--effort" && -n "$effort" ]]; then
            fixed+=("$a" "$effort"); i=$((i+2)); seen_eff=1; continue
          fi
          fixed+=("$a"); i=$((i+1))
        done
        [[ -n "$max_turns" && $seen_mt -eq 0 ]] && fixed+=("--max-turns" "$max_turns")
        [[ -n "$effort" && $seen_eff -eq 0 ]] && fixed+=("--effort" "$effort")
        args=("${fixed[@]}")
        ;;
      codex)
        while [[ $i -lt ${#args[@]} ]]; do
          local a="${args[$i]}"
          if [[ "$a" == "-c" && $((i+1)) -lt ${#args[@]} && "${args[$((i+1))]}" == model_reasoning_effort=* && -n "$effort" ]]; then
            fixed+=("-c" "model_reasoning_effort=${effort}"); i=$((i+2)); seen_ce=1; continue
          fi
          fixed+=("$a"); i=$((i+1))
        done
        [[ -n "$effort" && $seen_ce -eq 0 ]] && fixed+=("-c" "model_reasoning_effort=${effort}")
        args=("${fixed[@]}")
        ;;
      *)
        # kimi / hermes / gemini: no known effort/max-turns flags; leave args untouched.
        ;;
    esac
  fi

  local -a cmd_prefix=()
  if [[ -n "$capabilities_env_unset" ]]; then
    local -a unset_args=()
    while IFS= read -r var; do
      [[ -z "$var" ]] && continue
      unset_args+=("-u" "$var")
    done <<<"$capabilities_env_unset"
    if [[ ${#unset_args[@]} -gt 0 ]]; then
      cmd_prefix=("env" "${unset_args[@]}")
    fi
  fi

  if [[ "$prompt_transport" == "stdin" ]]; then
    if [[ ${#cmd_prefix[@]} -gt 0 ]]; then
      "${cmd_prefix[@]}" "$command_name" "${args[@]}" < "$prompt_file" > "$output_file"
    else
      "$command_name" "${args[@]}" < "$prompt_file" > "$output_file"
    fi
  else
    if [[ ${#cmd_prefix[@]} -gt 0 ]]; then
      "${cmd_prefix[@]}" "$command_name" "${args[@]}" > "$output_file"
    else
      "$command_name" "${args[@]}" > "$output_file"
    fi
  fi

  if [[ "$output_mode" == "file" ]]; then
    if [[ ! -f "$output_file" ]]; then
      echo "Error: agent '$agent_id' did not produce expected output file at $output_file" >&2
      return 1
    fi
  fi

  return 0
}
