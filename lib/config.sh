#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034
BRIDGE_CONFIG_FILE="${HOME}/.bridge-ai/config.json"

_BRIDGE_V2_DEFAULTS='{
  "version": 2,
  "agents": {
    "claude": {
      "enabled": true,
      "name": "Claude Code",
      "command": "claude",
      "args": ["-p", "--output-format", "text", "--model", "{{model}}"],
      "prompt_transport": "stdin",
      "output_mode": "stdout",
      "default_model": "opus",
      "max_prompt_bytes": null,
      "supports_mcp_registration": true,
      "capabilities": {
        "env_unset": ["CLAUDECODE"]
      }
    },
    "codex": {
      "enabled": true,
      "name": "Codex",
      "command": "codex",
      "args": ["exec", "-m", "{{model}}", "-C", "{{cwd}}", "--skip-git-repo-check", "--output-last-message", "{{output_file}}", "-"],
      "prompt_transport": "stdin",
      "output_mode": "file",
      "default_model": "o3",
      "max_prompt_bytes": null,
      "supports_mcp_registration": true,
      "capabilities": {}
    },
    "hermes": {
      "enabled": true,
      "name": "Hermes Agent",
      "command": "hermes",
      "args": ["chat", "-q", "{{prompt}}", "--quiet", "-m", "{{model}}", "--source", "tool"],
      "prompt_transport": "arg",
      "output_mode": "stdout",
      "default_model": "anthropic/claude-sonnet-4",
      "max_prompt_bytes": 120000,
      "supports_mcp_registration": false,
      "capabilities": {}
    }
  },
  "forum": {
    "agent_a": "claude",
    "agent_b": "codex",
    "synthesizer": "codex"
  },
  "mcp": {
    "registered_clients": ["claude", "codex"]
  },
  "runtime": {
    "timeout_seconds": 300
  }
}'

bridge_config_path() {
  echo "$BRIDGE_CONFIG_FILE"
}

bridge__load_raw_config() {
  local file="$1"
  if [[ -f "$file" ]]; then
    jq -c '.' "$file" 2>/dev/null || {
      echo "Invalid config at $file: malformed JSON" >&2
      return 1
    }
  else
    echo "null"
  fi
}

bridge__deep_merge() {
  local user="$1"
  local defaults="$2"
  jq -s '
    def merge($u; $d):
      if $u | type == "object" and $d | type == "object" then
        $u + reduce ($d | keys_unsorted[]) as $k ({};
          if ($u | has($k)) then . + { ($k): merge($u[$k]; $d[$k]) }
          else . + { ($k): $d[$k] }
          end
        )
      elif $u | type == "array" then $u
      else $u
      end;
    merge(.[0]; .[1])
  ' <<<"[$user $defaults]"
}

bridge_load_config() {
  local raw
  raw=$(bridge__load_raw_config "$BRIDGE_CONFIG_FILE") || return 1
  local version
  version=$(jq -r '.version // 0' <<<"$raw")
  if [[ "$version" -lt 2 ]]; then
    if [[ "$raw" != "null" ]]; then
      echo "Warning: legacy config detected at $BRIDGE_CONFIG_FILE; merging with v2 defaults." >&2
      raw=$(bridge__deep_merge "$raw" "$_BRIDGE_V2_DEFAULTS")
    else
      echo "Warning: config missing at $BRIDGE_CONFIG_FILE; using built-in v2 defaults." >&2
      raw="$_BRIDGE_V2_DEFAULTS"
    fi
  fi
  echo "$raw"
}

bridge_agent_ids() {
  local config
  config=$(bridge_load_config)
  jq -r '.agents | to_entries[] | select(.value.enabled == true) | .key' <<<"$config"
}

bridge_agent_field() {
  local id="$1"
  local field="$2"
  local config
  config=$(bridge_load_config)
  jq -r --arg id "$id" --arg field "$field" '.agents[$id][$field] // empty' <<<"$config"
}

bridge_forum_default() {
  local role="$1"
  local config
  config=$(bridge_load_config)
  jq -r --arg role "$role" '.forum[$role] // empty' <<<"$config"
}

bridge_mcp_registered_clients() {
  local config
  config=$(bridge_load_config)
  jq -r '.mcp.registered_clients // [] | .[]' <<<"$config"
}

bridge_runtime_timeout() {
  local config
  config=$(bridge_load_config)
  jq -r '.runtime.timeout_seconds // 300' <<<"$config"
}
