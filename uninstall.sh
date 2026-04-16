#!/usr/bin/env bash
set -euo pipefail

MARKETPLACE_NAME="peer-collab-marketplace"
PLUGIN_NAME="peer-opinion@peer-collab-marketplace"
MCP_NAME="ia-bridge-mcp"
MCP_NODE_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mcp/node_modules"
BRIDGE_CONFIG="${HOME}/.bridge-ai/config.json"

unregister_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    return 0
  fi
  claude plugin disable "${PLUGIN_NAME}" >/dev/null 2>&1 || true
  claude plugin uninstall "${PLUGIN_NAME}" >/dev/null 2>&1 || true
  claude plugin marketplace remove "${MARKETPLACE_NAME}" >/dev/null 2>&1 || true
  claude mcp remove -s user "${MCP_NAME}" >/dev/null 2>&1 || true
}

unregister_agent_mcp() {
  local agent="$1"
  if [[ "$agent" == "claude" ]]; then
    unregister_claude
    return 0
  fi
  if ! command -v "$agent" >/dev/null 2>&1; then
    return 0
  fi
  case "$agent" in
    codex)
      codex mcp remove "${MCP_NAME}" >/dev/null 2>&1 || true
      ;;
    hermes)
      # Hermes does not support MCP registration yet
      ;;
    *)
      # Best-effort: try <agent> mcp remove
      "$agent" mcp remove "${MCP_NAME}" >/dev/null 2>&1 || true
      ;;
  esac
}

agents_to_unregister=()
if [[ -f "$BRIDGE_CONFIG" ]]; then
  mapfile -t agents_to_unregister < <(jq -r '
    .agents // {} | to_entries |
    map(select(.value.enabled == true and (.value.supports_mcp_registration // false) == true) | .key) |
    .[]
  ' "$BRIDGE_CONFIG" 2>/dev/null || true)
fi

# Fallback: always attempt Claude and Codex if config unreadable
if [[ ${#agents_to_unregister[@]} -eq 0 ]]; then
  agents_to_unregister=("claude" "codex")
fi

for agent in "${agents_to_unregister[@]}"; do
  if [[ -z "$agent" ]]; then continue; fi
  unregister_agent_mcp "$agent"
done

rm -f "${HOME}/.local/bin/second-opinion"
rm -f "${HOME}/.local/bin/forum"
rm -rf "${MCP_NODE_MODULES_DIR}"

echo "Removed plugin, marketplace registration, MCP server registration, global executables, and SDK runtime."
echo "Logs at ~/.bridge-ai were preserved."
