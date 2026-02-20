#!/usr/bin/env bash
set -euo pipefail

MARKETPLACE_NAME="peer-collab-marketplace"
PLUGIN_NAME="peer-opinion@peer-collab-marketplace"
MCP_NAME="ia-bridge-mcp"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE_DIR="${SCRIPT_DIR}/marketplace"
MCP_DIR="${SCRIPT_DIR}/mcp"
MCP_SERVER_SCRIPT="${MCP_DIR}/ia_bridge_mcp_server.mjs"
MCP_CLIENT_SCRIPT="${MCP_DIR}/mcp_tool_call.py"
MCP_PACKAGE_JSON="${MCP_DIR}/package.json"
MCP_NODE_MODULE="${MCP_DIR}/node_modules/@modelcontextprotocol/sdk/package.json"
SECOND_OPINION_WRAPPER="${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/claude-second-opinion-via-mcp.sh"
IA_BRIDGE_WRAPPER="${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/ia-bridge-via-mcp.sh"
USER_BIN_DIR="${HOME}/.local/bin"
SECOND_OPINION_LINK="${USER_BIN_DIR}/claude-second-opinion"
IA_BRIDGE_LINK="${USER_BIN_DIR}/ia-bridge"

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude CLI not found in PATH." >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex CLI not found in PATH." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Error: node not found in PATH." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "Error: npm not found in PATH." >&2
  exit 1
fi

if [[ ! -f "${MARKETPLACE_DIR}/.claude-plugin/marketplace.json" ]]; then
  echo "Error: marketplace.json not found at ${MARKETPLACE_DIR}" >&2
  exit 1
fi

if [[ ! -f "${MCP_PACKAGE_JSON}" ]]; then
  echo "Error: MCP package.json not found at ${MCP_PACKAGE_JSON}" >&2
  exit 1
fi

chmod +x "${MCP_SERVER_SCRIPT}" "${MCP_CLIENT_SCRIPT}" "${SECOND_OPINION_WRAPPER}" "${IA_BRIDGE_WRAPPER}" \
  "${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/claude-second-opinion.sh" \
  "${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/ia-bridge.sh"

echo "[1/9] Bootstrapping MCP SDK runtime..."
if ! (cd "${MCP_DIR}" && npm install --no-fund --no-audit >/dev/null); then
  cat >&2 <<ERR
Error: failed to install MCP SDK dependencies.

Ensure this machine can reach npm package indexes, then rerun:
  cd ${SCRIPT_DIR}
  ./install.sh
ERR
  exit 1
fi
if [[ ! -f "${MCP_NODE_MODULE}" ]]; then
  echo "Error: MCP SDK install did not produce expected module at ${MCP_NODE_MODULE}" >&2
  exit 1
fi

echo "[2/9] Registering local marketplace..."
if claude plugin marketplace list 2>/dev/null | rg -q "${MARKETPLACE_NAME}"; then
  claude plugin marketplace update "${MARKETPLACE_NAME}" >/dev/null
else
  claude plugin marketplace add "${MARKETPLACE_DIR}" >/dev/null
fi

echo "[3/9] Installing user plugin ${PLUGIN_NAME}..."
if claude plugin list 2>/dev/null | rg -q "${PLUGIN_NAME}"; then
  :
else
  claude plugin install "${PLUGIN_NAME}" --scope user >/dev/null
fi
claude plugin enable "${PLUGIN_NAME}" >/dev/null 2>&1 || true

echo "[4/9] Configuring Claude MCP server (${MCP_NAME})..."
claude mcp remove -s user "${MCP_NAME}" >/dev/null 2>&1 || true
claude mcp add -s user "${MCP_NAME}" -- node "${MCP_SERVER_SCRIPT}" >/dev/null

echo "[5/9] Configuring Codex MCP server (${MCP_NAME})..."
codex mcp remove "${MCP_NAME}" >/dev/null 2>&1 || true
codex mcp add "${MCP_NAME}" -- node "${MCP_SERVER_SCRIPT}" >/dev/null

echo "[6/9] Installing global executables..."
mkdir -p "${USER_BIN_DIR}"
ln -sf "${SECOND_OPINION_WRAPPER}" "${SECOND_OPINION_LINK}"
ln -sf "${IA_BRIDGE_WRAPPER}" "${IA_BRIDGE_LINK}"

echo "[7/9] Preparing user log directories..."
mkdir -p "${HOME}/.claude/opinions"
mkdir -p "${HOME}/.claude/ia-bridge/sessions"

echo "[8/9] Verifying scripts..."
"${SECOND_OPINION_LINK}" --help >/dev/null
"${IA_BRIDGE_LINK}" --help >/dev/null

echo "[9/9] Done"
cat <<'DONE'
Installed successfully.

SDK-backed MCP backend configured in both CLIs:
  Claude MCP: ia-bridge-mcp
  Codex MCP:  ia-bridge-mcp

Global commands (MCP-backed):
  claude-second-opinion --task "<task>" --constraints "<optional>" [--reviewer claude|codex]
  ia-bridge --task "<task>" --constraints "<optional>"

Logs:
  ~/.claude/opinions/
  ~/.claude/ia-bridge/sessions/

Interactive Claude plugin commands:
  /second-opinion <task>
  /ia-bridge <task>
DONE
