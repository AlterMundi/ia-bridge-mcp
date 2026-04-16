# ia-bridge-mcp

A Model Context Protocol (MCP) server that enables structured collaboration between **multiple AI agents** — independent AI assistants reviewing your code or decisions together, without either seeing the other's work until the right moment.

## What it does

**`/second-opinion`** — asks one reviewer for a structured critique of a task, patch, or decision. Returns findings by severity, confidence level, and unknowns.

**`/forum`** — runs a full 3-round peer-review protocol:

```
Round 1: Agent A and Agent B each propose a solution independently
Round 2: Agent A critiques Agent B's proposal; Agent B critiques Agent A's
Round 3: Synthesizer combines both proposals + critiques into a final recommendation
```

Both commands run **asynchronously** — the review happens in the background and you can continue working while you wait. All sessions are saved as markdown files under `~/.bridge-ai/`.

## Supported agents

Out of the box, `ia-bridge-mcp` supports any combination of:

- [Claude Code](https://claude.ai/code) (`claude` CLI)
- [Codex CLI](https://github.com/openai/codex) (`codex` CLI)
- [Hermes Agent](https://github.com/hermes-ai/cli) (`hermes` CLI)

You can enable/disable agents and choose forum defaults via `~/.bridge-ai/config.json`.

## Prerequisites

- Node.js ≥ 18
- npm
- Python 3
- At least one supported agent CLI in your `PATH`

## Install

```bash
git clone https://github.com/AlterMundi/ia-bridge-mcp.git
cd ia-bridge-mcp
./install.sh
```

The installer will:
1. Detect available agent CLIs in your `PATH`
2. Write `~/.bridge-ai/config.json` with sensible defaults
3. Run `npm install` to fetch the MCP SDK
4. Register a local plugin marketplace with Claude Code (if present)
5. Install the `peer-opinion` plugin (provides `/second-opinion` and `/forum` slash commands)
6. Register the MCP server with each supported agent CLI
7. Create symlinks `~/.local/bin/second-opinion` and `~/.local/bin/forum` for direct CLI use
8. Create `~/.bridge-ai/{opinions,sessions,jobs}/` for storing outputs

### Non-interactive install

```bash
./install.sh --non-interactive --agents claude,codex,hermes --forum-defaults claude,codex,hermes
```

> **Note:** Codex may display `Auth: Unsupported` for stdio MCPs — this is expected and does not affect functionality.

## Usage

### Inside Claude Code (slash commands)

```
/second-opinion Review this authentication patch
/second-opinion codex Should we use Redis or Postgres for session storage?
/forum Design a safer rollout strategy for this migration
```

### From the terminal (CLI)

```bash
second-opinion --task "Review this patch"
second-opinion --reviewer codex --task "Review this patch"
forum --task "Design safer rollout" --constraints "must be backward-compatible"
forum --task "Compare approaches" --agent-a hermes --agent-b claude --synthesizer claude
```

### From any MCP-capable client (tools)

| Tool | Description |
|------|-------------|
| `ia_bridge_run` | Start a full 3-round forum session (async) |
| `single_opinion_run` | Start a single-reviewer opinion (async by default, supports sync) |
| `ia_bridge_job_status` | Poll a background job's status |
| `ia_bridge_job_result` | Fetch the result and output path of a completed job |
| `ia_bridge_list_sessions` | List past bridge sessions |
| `ia_bridge_read_file` | Read a session file by path |

Context is auto-detected: in a git repository the server captures branch, recent commits, and the current diff and passes them to all reviewers.

## Session artifacts

All output is saved as plain markdown:

```
~/.bridge-ai/
├── opinions/          # /second-opinion outputs
│   └── 20260316-<repo>-<reviewer>-second-opinion.md
├── sessions/          # /forum 3-round sessions
│   └── 20260316-<repo>/
│       ├── 00-shared-context.md
│       ├── 01-round1-shared-prompt.txt
│       ├── 10-agent-a-round1.md
│       ├── 20-agent-b-round1.md
│       ├── 30-agent-a-critique.md
│       ├── 40-agent-b-critique.md
│       ├── 50-final-synthesis.md
│       └── INDEX.md
└── jobs/              # job metadata and logs
```

A `/forum` session can be **resumed** if interrupted:

```bash
forum --resume ~/.bridge-ai/sessions/20260316-myrepo
```

## Configuration

`~/.bridge-ai/config.json` controls which agents are enabled and which models are used:

```json
{
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
      "supports_mcp_registration": true,
      "capabilities": { "env_unset": ["CLAUDECODE"] }
    },
    "codex": {
      "enabled": true,
      "name": "Codex",
      "command": "codex",
      "args": ["exec", "-m", "{{model}}", "-C", "{{cwd}}", "--skip-git-repo-check", "--output-last-message", "{{output_file}}", "-"],
      "prompt_transport": "stdin",
      "output_mode": "file",
      "default_model": "o3",
      "supports_mcp_registration": true
    },
    "hermes": {
      "enabled": true,
      "name": "Hermes Agent",
      "command": "hermes",
      "args": ["chat", "-q", "{{prompt}}", "--quiet", "-m", "{{model}}", "--source", "tool"],
      "prompt_transport": "arg",
      "output_mode": "stdout",
      "default_model": "anthropic/claude-sonnet-4",
      "supports_mcp_registration": false
    }
  },
  "forum": {
    "agent_a": "claude",
    "agent_b": "codex",
    "synthesizer": "hermes"
  },
  "mcp": {
    "registered_clients": ["claude", "codex"]
  },
  "runtime": {
    "timeout_seconds": 300
  }
}
```

## How it works

```
ia-bridge-mcp (Node.js stdio MCP server)
  ├── registered in each supported agent's MCP config
  └── exposes 6 tools (ia_bridge_run, single_opinion_run, status, result, list, read)

peer-opinion plugin (Claude Code plugin)
  ├── /second-opinion  →  single_opinion_run tool
  └── /forum           →  ia_bridge_run tool

CLI wrappers (~/.local/bin/)
  ├── second-opinion   →  second-opinion-via-mcp.sh  →  Python MCP client
  └── forum            →  forum-via-mcp.sh            →  Python MCP client

Shared libraries (lib/)
  ├── config.sh        →  config loading, migration, and helper functions
  └── adapters.sh      →  generic agent runner (bridge_run_agent)
```

The server itself is a lightweight Node.js process using stdio transport. It spawns background shell jobs for each review run and exposes polling tools so any MCP client can check progress and retrieve results without blocking.

## Repository layout

```
ia-bridge-mcp/
├── install.sh                          # one-step installer
├── uninstall.sh                        # clean uninstaller
├── lib/
│   ├── config.sh                       # config loader + helpers
│   └── adapters.sh                     # generic agent adapter runner
├── mcp/
│   ├── ia_bridge_mcp_server.mjs        # MCP server (Node.js, stdio)
│   ├── mcp_tool_call.py                # Python client for CLI wrappers
│   └── package.json                    # single dependency: @modelcontextprotocol/sdk
└── marketplace/
    └── plugins/peer-opinion/
        ├── scripts/
        │   ├── forum.sh                # 3-round bridge protocol
        │   ├── second-opinion.sh       # single-pass opinion
        │   ├── forum-via-mcp.sh        # CLI wrapper (calls MCP server)
        │   └── second-opinion-via-mcp.sh
        └── commands/
            ├── forum.md                # /forum slash command definition
            └── second-opinion.md       # /second-opinion slash command definition
```

## Privacy note

When run inside a git repository, both scripts capture your current branch, recent commits, and `git diff HEAD` and include them in the prompts sent to the enabled agents. No data is sent to any other service. If you are working with sensitive code, review your API providers' data handling policies before use.

## Uninstall

```bash
cd ia-bridge-mcp
./uninstall.sh
```

This removes MCP registrations, the plugin, marketplace entry, and symlinks. Your session logs in `~/.bridge-ai/` are preserved.

## License

MIT — see [AlterMundi](https://altermundi.net)
