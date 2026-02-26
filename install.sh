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
SECOND_OPINION_WRAPPER="${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/second-opinion-via-mcp.sh"
IA_BRIDGE_WRAPPER="${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/ia-bridge-via-mcp.sh"
USER_BIN_DIR="${HOME}/.local/bin"
SECOND_OPINION_LINK="${USER_BIN_DIR}/second-opinion"
IA_BRIDGE_LINK="${USER_BIN_DIR}/ia-bridge"
BRIDGE_AI_DIR="${HOME}/.bridge-ai"
BRIDGE_OPINIONS_DIR="${BRIDGE_AI_DIR}/opinions"
BRIDGE_SESSIONS_DIR="${BRIDGE_AI_DIR}/sessions"
BRIDGE_JOBS_DIR="${BRIDGE_AI_DIR}/jobs"
LEGACY_OPINIONS_DIR="${HOME}/.claude/opinions"
LEGACY_SESSIONS_DIR="${HOME}/.claude/ia-bridge/sessions"
LEGACY_JOBS_DIR="${HOME}/.claude/ia-bridge/jobs"

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

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found in PATH." >&2
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

has_marketplace() {
  if command -v rg >/dev/null 2>&1; then
    claude plugin marketplace list --json 2>/dev/null | rg -q "\"name\"\\s*:\\s*\"${MARKETPLACE_NAME}\""
  else
    claude plugin marketplace list --json 2>/dev/null | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${MARKETPLACE_NAME}\""
  fi
}

has_plugin() {
  if command -v rg >/dev/null 2>&1; then
    claude plugin list --json 2>/dev/null | rg -q "\"id\"\\s*:\\s*\"${PLUGIN_NAME}\""
  else
    claude plugin list --json 2>/dev/null | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"${PLUGIN_NAME}\""
  fi
}

merge_legacy_dir() {
  local src="$1"
  local dst="$2"

  if [[ ! -d "$src" ]]; then
    return 0
  fi

  mkdir -p "$dst"
  shopt -s dotglob nullglob
  local entries=("$src"/*)
  shopt -u dotglob nullglob
  if [[ ${#entries[@]} -gt 0 ]]; then
    cp -a "${entries[@]}" "$dst"/ 2>/dev/null || true
  fi
}

chmod +x "${MCP_SERVER_SCRIPT}" "${MCP_CLIENT_SCRIPT}" "${SECOND_OPINION_WRAPPER}" "${IA_BRIDGE_WRAPPER}" \
  "${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/second-opinion.sh" \
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
if has_marketplace; then
  claude plugin marketplace update "${MARKETPLACE_NAME}" >/dev/null
else
  claude plugin marketplace add "${MARKETPLACE_DIR}" >/dev/null
fi

echo "[3/9] Installing user plugin ${PLUGIN_NAME}..."
if has_plugin; then
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
mkdir -p "${BRIDGE_OPINIONS_DIR}"
mkdir -p "${BRIDGE_SESSIONS_DIR}"
mkdir -p "${BRIDGE_JOBS_DIR}"

# One-time compatibility merge from legacy folders.
merge_legacy_dir "${LEGACY_OPINIONS_DIR}" "${BRIDGE_OPINIONS_DIR}"
merge_legacy_dir "${LEGACY_SESSIONS_DIR}" "${BRIDGE_SESSIONS_DIR}"
merge_legacy_dir "${LEGACY_JOBS_DIR}" "${BRIDGE_JOBS_DIR}"

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
  second-opinion --task "<task>" --constraints "<optional>" [--reviewer claude|codex]
  ia-bridge --task "<task>" --constraints "<optional>"

Logs:
  ~/.bridge-ai/opinions/
  ~/.bridge-ai/sessions/
  ~/.bridge-ai/jobs/

Interactive Claude plugin commands:
  /second-opinion <task>
  /ia-bridge <task>
DONE
