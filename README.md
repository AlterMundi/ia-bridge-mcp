# ia-bridge-mcp

A Model Context Protocol (MCP) server that enables structured collaboration between **Claude** and **Codex** — two independent AI assistants reviewing your code or decisions together, without either seeing the other's work until the right moment.

## What it does

**`/second-opinion`** — asks one reviewer (Claude or Codex) for a structured critique of a task, patch, or decision. Returns findings by severity, confidence level, and unknowns.

**`/forum`** — runs a full 3-round peer-review protocol:

```
Round 1: Claude and Codex each propose a solution independently
Round 2: Claude critiques Codex's proposal; Codex critiques Claude's
Round 3: Codex synthesizes both proposals + critiques into a final recommendation
```

Both commands run **asynchronously** — the review happens in the background and you can continue working while you wait. All sessions are saved as markdown files under `~/.bridge-ai/`.

## Prerequisites

- [Claude Code](https://claude.ai/code) (`claude` CLI)
- [Codex CLI](https://github.com/openai/codex) (`codex` CLI)
- Node.js ≥ 18
- npm
- Python 3

## Install

```bash
git clone https://github.com/AlterMundi/ia-bridge-mcp.git
cd ia-bridge-mcp
./install.sh
```

The installer will:
1. Run `npm install` to fetch the MCP SDK
2. Register a local plugin marketplace with Claude Code
3. Install the `peer-opinion` plugin (provides `/second-opinion` and `/forum` slash commands)
4. Register the MCP server with both Claude Code and Codex CLI
5. Create symlinks `~/.local/bin/second-opinion` and `~/.local/bin/forum` for direct CLI use
6. Create `~/.bridge-ai/{opinions,sessions,jobs}/` for storing outputs

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

Context is auto-detected: in a git repository the server captures branch, recent commits, and the current diff and passes them to both reviewers.

## Session artifacts

All output is saved as plain markdown:

```
~/.bridge-ai/
├── opinions/          # /second-opinion outputs
│   └── 20260316-<repo>-claude-second-opinion.md
├── sessions/          # /forum 3-round sessions
│   └── 20260316-<repo>/
│       ├── 00-shared-context.md
│       ├── 10-claude-round1.md
│       ├── 20-codex-round1.md
│       ├── 30-claude-critiques-codex.md
│       ├── 40-codex-critiques-claude.md
│       ├── 50-final-synthesis.md
│       └── INDEX.md
└── jobs/              # job metadata and logs
```

A `/forum` session can be **resumed** if interrupted:

```bash
forum --resume ~/.bridge-ai/sessions/20260316-myrepo
```

## How it works

```
ia-bridge-mcp (Node.js stdio MCP server)
  ├── registered in Claude Code MCP config
  ├── registered in Codex CLI MCP config
  └── exposes 6 tools (ia_bridge_run, single_opinion_run, status, result, list, read)

peer-opinion plugin (Claude Code plugin)
  ├── /second-opinion  →  single_opinion_run tool
  └── /forum           →  ia_bridge_run tool

CLI wrappers (~/.local/bin/)
  ├── second-opinion   →  second-opinion-via-mcp.sh  →  Python MCP client
  └── forum            →  forum-via-mcp.sh            →  Python MCP client
```

The server itself is a lightweight Node.js process using stdio transport. It spawns background shell jobs for each review run and exposes polling tools so Claude or any other MCP client can check progress and retrieve results without blocking.

## Repository layout

```
ia-bridge-mcp/
├── install.sh                          # one-step installer
├── uninstall.sh                        # clean uninstaller
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

## Uninstall

```bash
cd ia-bridge-mcp
./uninstall.sh
```

This removes MCP registrations, the plugin, marketplace entry, and symlinks. Your session logs in `~/.bridge-ai/` are preserved.

## License

MIT — see [AlterMundi](https://altermundi.net)
