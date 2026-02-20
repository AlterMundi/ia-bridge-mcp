#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd -P)"
SERVER_SCRIPT="${ROOT}/mcp/ia_bridge_mcp_server.mjs"
CLIENT_SCRIPT="${ROOT}/mcp/mcp_tool_call.py"
MCP_NODE_MODULE="${ROOT}/mcp/node_modules/@modelcontextprotocol/sdk/package.json"

if [[ ! -f "${MCP_NODE_MODULE}" ]]; then
  echo "Error: MCP SDK runtime missing at ${MCP_NODE_MODULE}" >&2
  echo "Run: cd ${ROOT} && ./install.sh" >&2
  exit 1
fi

python3 "$CLIENT_SCRIPT" --node node --server "$SERVER_SCRIPT" --tool ia_bridge_run -- "$@"
