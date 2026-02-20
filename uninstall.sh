#!/usr/bin/env bash
set -euo pipefail

MARKETPLACE_NAME="peer-collab-marketplace"
PLUGIN_NAME="peer-opinion@peer-collab-marketplace"
MCP_NAME="ia-bridge-mcp"
MCP_NODE_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mcp/node_modules"

if command -v claude >/dev/null 2>&1; then
  claude plugin disable "${PLUGIN_NAME}" >/dev/null 2>&1 || true
  claude plugin uninstall "${PLUGIN_NAME}" >/dev/null 2>&1 || true
  claude plugin marketplace remove "${MARKETPLACE_NAME}" >/dev/null 2>&1 || true
  claude mcp remove -s user "${MCP_NAME}" >/dev/null 2>&1 || true
fi

if command -v codex >/dev/null 2>&1; then
  codex mcp remove "${MCP_NAME}" >/dev/null 2>&1 || true
fi

rm -f "${HOME}/.local/bin/claude-second-opinion"
rm -f "${HOME}/.local/bin/ia-bridge"
rm -rf "${MCP_NODE_MODULES_DIR}"

echo "Removed plugin, marketplace registration, MCP server registration, global executables, and SDK runtime."
echo "Logs at ~/.claude/opinions and ~/.claude/ia-bridge/sessions were preserved."
