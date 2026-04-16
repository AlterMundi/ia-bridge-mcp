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
FORUM_WRAPPER="${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/forum-via-mcp.sh"
USER_BIN_DIR="${HOME}/.local/bin"
SECOND_OPINION_LINK="${USER_BIN_DIR}/second-opinion"
FORUM_LINK="${USER_BIN_DIR}/forum"
BRIDGE_AI_DIR="${HOME}/.bridge-ai"
BRIDGE_CONFIG="${BRIDGE_AI_DIR}/config.json"
BRIDGE_OPINIONS_DIR="${BRIDGE_AI_DIR}/opinions"
BRIDGE_SESSIONS_DIR="${BRIDGE_AI_DIR}/sessions"
BRIDGE_JOBS_DIR="${BRIDGE_AI_DIR}/jobs"
BRIDGE_MIGRATED_SENTINEL="${BRIDGE_AI_DIR}/.migrated"
LEGACY_OPINIONS_DIR="${HOME}/.claude/opinions"
LEGACY_SESSIONS_DIR="${HOME}/.claude/forum/sessions"
LEGACY_JOBS_DIR="${HOME}/.claude/forum/jobs"

NON_INTERACTIVE=false
CLI_AGENTS=""
CLI_AGENT_A=""
CLI_AGENT_B=""
CLI_SYNTHESIZER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --agents)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --agents requires a value (comma-separated list)." >&2
        exit 1
      fi
      CLI_AGENTS="$2"
      shift 2
      ;;
    --forum-defaults)
      if [[ $# -lt 4 ]]; then
        echo "Error: --forum-defaults requires three values: agent_a,agent_b,synthesizer" >&2
        exit 1
      fi
      CLI_AGENT_A="$2"
      CLI_AGENT_B="$3"
      CLI_SYNTHESIZER="$4"
      shift 4
      ;;
    -h|--help)
      cat <<'HELP'
Usage: ./install.sh [options]

Options:
  --non-interactive        Skip prompts and use defaults or CLI overrides.
  --agents <list>          Comma-separated enabled agents (e.g. claude,codex,hermes).
  --forum-defaults <a,b,s> Set forum defaults: agent_a,agent_b,synthesizer.
  -h, --help               Show this help.
HELP
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Detect available agent commands
available_agents=()
agent_has_mcp=()

has_command() {
  command -v "$1" >/dev/null 2>&1
}

if has_command claude; then
  available_agents+=("claude")
  agent_has_mcp+=("true")
fi
if has_command codex; then
  available_agents+=("codex")
  agent_has_mcp+=("true")
fi
if has_command hermes; then
  available_agents+=("hermes")
  agent_has_mcp+=("false")
fi

if [[ ${#available_agents[@]} -eq 0 ]]; then
  echo "Error: no supported agent CLIs found in PATH." >&2
  echo "Please install at least one of: claude, codex, or hermes." >&2
  exit 1
fi

# Choose enabled agents
enabled_agents=()
if [[ -n "$CLI_AGENTS" ]]; then
  IFS=',' read -ra wanted <<< "$CLI_AGENTS"
  for a in "${wanted[@]}"; do
    a="$(echo "$a" | xargs)"
    found=false
    for i in "${!available_agents[@]}"; do
      if [[ "${available_agents[$i]}" == "$a" ]]; then
        enabled_agents+=("$a")
        found=true
        break
      fi
    done
    if [[ "$found" == "false" ]]; then
      echo "Error: requested agent '$a' is not available in PATH." >&2
      exit 1
    fi
  done
else
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    enabled_agents=("${available_agents[@]}")
  else
    echo "Detected agents: ${available_agents[*]}"
    read -rp "Enable all detected agents? [Y/n] " ans
    if [[ -z "$ans" || "$ans" =~ ^[Yy] ]]; then
      enabled_agents=("${available_agents[@]}")
    else
      for a in "${available_agents[@]}"; do
        read -rp "Enable $a? [Y/n] " aans
        if [[ -z "$aans" || "$aans" =~ ^[Yy] ]]; then
          enabled_agents+=("$a")
        fi
      done
    fi
  fi
fi

if [[ ${#enabled_agents[@]} -eq 0 ]]; then
  echo "Error: no agents selected." >&2
  exit 1
fi

# Determine forum defaults
if [[ -n "$CLI_AGENT_A" && -n "$CLI_AGENT_B" && -n "$CLI_SYNTHESIZER" ]]; then
  AGENT_A="$CLI_AGENT_A"
  AGENT_B="$CLI_AGENT_B"
  SYNTHESIZER="$CLI_SYNTHESIZER"
else
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    AGENT_A="${enabled_agents[0]}"
    AGENT_B="${enabled_agents[1]:-${enabled_agents[0]}}"
    SYNTHESIZER="${enabled_agents[0]}"
  else
    echo "Select forum participants:"
    read -rp "Agent A [${enabled_agents[0]}] " inp
    AGENT_A="${inp:-${enabled_agents[0]}}"
    default_b="${enabled_agents[1]:-${enabled_agents[0]}}"
    read -rp "Agent B [${default_b}] " inp
    AGENT_B="${inp:-$default_b}"
    read -rp "Synthesizer [${enabled_agents[0]}] " inp
    SYNTHESIZER="${inp:-${enabled_agents[0]}}"
  fi
fi

# Build config JSON
build_agent_obj() {
  local id="$1"
  local enabled="$2"
  case "$id" in
    claude)
      cat <<JSON
    "$id": {
      "enabled": $enabled,
      "name": "Claude Code",
      "command": "claude",
      "args": ["-p", "--output-format", "text", "--model", "{{model}}"],
      "prompt_transport": "stdin",
      "output_mode": "stdout",
      "default_model": "opus",
      "supports_mcp_registration": true,
      "capabilities": { "env_unset": ["CLAUDECODE"] }
    }
JSON
      ;;
    codex)
      cat <<JSON
    "$id": {
      "enabled": $enabled,
      "name": "Codex",
      "command": "codex",
      "args": ["exec", "-m", "{{model}}", "-C", "{{cwd}}", "--skip-git-repo-check", "--output-last-message", "{{output_file}}", "-"],
      "prompt_transport": "stdin",
      "output_mode": "file",
      "default_model": "o3",
      "supports_mcp_registration": true,
      "capabilities": {}
    }
JSON
      ;;
    hermes)
      cat <<JSON
    "$id": {
      "enabled": $enabled,
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
JSON
      ;;
    *)
      cat <<JSON
    "$id": {
      "enabled": $enabled,
      "name": "$id",
      "command": "$id",
      "args": ["-p", "--model", "{{model}}"],
      "prompt_transport": "stdin",
      "output_mode": "stdout",
      "default_model": "default",
      "supports_mcp_registration": false,
      "capabilities": {}
    }
JSON
      ;;
  esac
}

agent_entries=()
for a in "${available_agents[@]}"; do
  enabled="false"
  for e in "${enabled_agents[@]}"; do
    if [[ "$e" == "$a" ]]; then
      enabled="true"
      break
    fi
  done
  agent_entries+=("$(build_agent_obj "$a" "$enabled")")
done

joined_agents="${agent_entries[0]}"
for i in "${!agent_entries[@]}"; do
  if [[ $i -gt 0 ]]; then
    joined_agents="${joined_agents},\n${agent_entries[$i]}"
  fi
done

registered_clients=()
for i in "${!available_agents[@]}"; do
  if [[ "${agent_has_mcp[$i]}" == "true" ]]; then
    a="${available_agents[$i]}"
    for e in "${enabled_agents[@]}"; do
      if [[ "$e" == "$a" ]]; then
        registered_clients+=("\"$a\"")
        break
      fi
    done
  fi
done

joined_clients=""
if [[ ${#registered_clients[@]} -gt 0 ]]; then
  joined_clients="${registered_clients[0]}"
  for i in "${!registered_clients[@]}"; do
    if [[ $i -gt 0 ]]; then
      joined_clients="${joined_clients}, ${registered_clients[$i]}"
    fi
  done
fi

cat > "$BRIDGE_CONFIG" <<EOF_CONFIG
{
  "version": 2,
  "agents": {
${joined_agents}
  },
  "forum": {
    "agent_a": "$AGENT_A",
    "agent_b": "$AGENT_B",
    "synthesizer": "$SYNTHESIZER"
  },
  "mcp": {
    "registered_clients": [${joined_clients}]
  },
  "runtime": {
    "timeout_seconds": 300
  }
}
EOF_CONFIG

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

if ! command -v jq >/dev/null 2>&1; then
  echo "Warning: jq not found in PATH. Config validation is disabled." >&2
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

chmod +x "${MCP_SERVER_SCRIPT}" "${MCP_CLIENT_SCRIPT}" "${SECOND_OPINION_WRAPPER}" "${FORUM_WRAPPER}" \
  "${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/second-opinion.sh" \
  "${MARKETPLACE_DIR}/plugins/peer-opinion/scripts/forum.sh"

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

if has_command claude; then
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
else
  echo "[2/9] Claude CLI not found; skipping marketplace/plugin/MCP registration for Claude."
fi

if has_command codex; then
  echo "[5/9] Configuring Codex MCP server (${MCP_NAME})..."
  codex mcp remove "${MCP_NAME}" >/dev/null 2>&1 || true
  codex mcp add "${MCP_NAME}" -- node "${MCP_SERVER_SCRIPT}" >/dev/null
else
  echo "[5/9] Codex CLI not found; skipping MCP registration for Codex."
fi

echo "[6/9] Installing global executables..."
mkdir -p "${USER_BIN_DIR}"
ln -sf "${SECOND_OPINION_WRAPPER}" "${SECOND_OPINION_LINK}"
ln -sf "${FORUM_WRAPPER}" "${FORUM_LINK}"

echo "[7/9] Preparing user log directories..."
mkdir -p "${BRIDGE_OPINIONS_DIR}"
mkdir -p "${BRIDGE_SESSIONS_DIR}"
mkdir -p "${BRIDGE_JOBS_DIR}"

# One-time compatibility merge from legacy folders (skipped on subsequent installs).
if [[ ! -f "${BRIDGE_MIGRATED_SENTINEL}" ]]; then
  merge_legacy_dir "${LEGACY_OPINIONS_DIR}" "${BRIDGE_OPINIONS_DIR}"
  merge_legacy_dir "${LEGACY_SESSIONS_DIR}" "${BRIDGE_SESSIONS_DIR}"
  merge_legacy_dir "${LEGACY_JOBS_DIR}" "${BRIDGE_JOBS_DIR}"
  touch "${BRIDGE_MIGRATED_SENTINEL}"
fi

echo "[8/9] Verifying scripts..."
"${SECOND_OPINION_LINK}" --help >/dev/null
"${FORUM_LINK}" --help >/dev/null

echo "[9/9] Done"
cat <<'DONE'
Installed successfully.

SDK-backed MCP backend configured in supported CLIs:
  Claude MCP: ia-bridge-mcp (if claude CLI present)
  Codex MCP:  ia-bridge-mcp (if codex CLI present)

Global commands (MCP-backed):
  second-opinion --task "<task>" --constraints "<optional>" [--reviewer <agent-id>]
  forum --task "<task>" --constraints "<optional>" [--agent-a <id> --agent-b <id> --synthesizer <id>]

Logs:
  ~/.bridge-ai/opinions/
  ~/.bridge-ai/sessions/
  ~/.bridge-ai/jobs/
  ~/.bridge-ai/config.json

Interactive Claude plugin commands (if claude CLI present):
  /second-opinion <task>
  /forum <task>
DONE
