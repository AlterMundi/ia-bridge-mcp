# ia-bridge-mcp Setup Reference

Shared MCP backend for Claude and Codex collaboration.

## Topology

```text
ia-bridge-mcp (Node stdio MCP server)
  -> registered in Claude MCP config
  -> registered in Codex MCP config
  -> exposes: ia_bridge_run, single_opinion_run, ia_bridge_job_status, ia_bridge_job_result, session list/read

CLI wrappers: ia-bridge, claude-second-opinion
Slash commands: /ia-bridge, /second-opinion
```

Codex may display `Auth: Unsupported` for stdio MCPs. That is expected and not a connectivity error.

## Main Components

| File | Purpose |
|---|---|
| `mcp/ia_bridge_mcp_server.mjs` | MCP server entrypoint |
| `marketplace/plugins/peer-opinion/scripts/ia-bridge.sh` | 3-round bridge protocol |
| `marketplace/plugins/peer-opinion/scripts/claude-second-opinion.sh` | single-pass opinion |

## Install

```bash
cd ~/REPOS/Skills/mcps/ia-bridge-mcp
./install.sh
```

## Use

```bash
claude-second-opinion --task "Review this patch"
claude-second-opinion --reviewer codex --task "Review this patch"
ia-bridge --task "Design safer rollout" --constraints "backward-compatible"
```

Tool auto-detects repo context: `code` mode in git repos, `non-code` otherwise.

Execution model:

- `single_opinion_run`: async by default (`mode=async`), optional sync.
- `ia_bridge_run`: async only; poll with `ia_bridge_job_status` and retrieve output via `ia_bridge_job_result`.

## Session Artifacts

Bridge sessions are stored under `~/.bridge-ai/sessions/<timestamp>-<repo>/`.

Typical files:

- `00-shared-context.md`
- `10-claude-round1.md`
- `20-codex-round1.md`
- `30-claude-critiques-codex.md`
- `40-codex-critiques-claude.md`
- `50-final-synthesis.md`
- `INDEX.md`

## Uninstall

```bash
cd ~/REPOS/Skills/mcps/ia-bridge-mcp
./uninstall.sh
```
