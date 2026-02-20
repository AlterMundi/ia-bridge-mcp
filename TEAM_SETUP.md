# Claude + Codex Exchange Baseline (Real CLI Integration)

This package provides a real shared backend for collaboration between Claude and Codex.

## Integration architecture

- SDK-based MCP server: `ia-bridge-mcp`
- Registered in both CLIs:
  - `claude mcp`
  - `codex mcp`
- Both global commands call MCP tools (same backend):
  - `claude-second-opinion`
  - `ia-bridge`
- Claude plugin slash commands also call MCP tools:
  - `/second-opinion`
  - `/ia-bridge`

Note for Codex CLI:
- `codex mcp list` may show `Auth: Unsupported` for stdio servers.
- This indicates no OAuth flow is configured for that server, not a connectivity failure.

## Steps 2/3/4 implementation

- Step 2: SDK MCP backend
  - Server: `mcp/ia_bridge_mcp_server.mjs`
  - Runtime: Node.js + `@modelcontextprotocol/sdk`
  - Dependencies: `mcp/package.json` + `npm install`
- Step 3: Register backend in both CLIs
  - `claude mcp add -s user ia-bridge-mcp -- node <server-script>`
  - `codex mcp add ia-bridge-mcp -- node <server-script>`
- Step 4: Wire real CLI commands
  - Global commands: `ia-bridge`, `claude-second-opinion`
  - Claude slash commands: `/ia-bridge`, `/second-opinion`
  - All call the same MCP tools and protocol handlers

## One-time install

```bash
cd ~/REPOS/Skills/mcps/ia-bridge-mcp
./install.sh
```

## Usage

Mode selection is automatic:
- `code` mode when `cwd` is inside a git repository (includes branch/commit/diff/commits evidence)
- `non-code` mode when no git repository is detected (same protocol, git evidence omitted)

### Claude-only structured opinion

```bash
claude-second-opinion --task "Review this patch for regressions"
```

Reviewer-specific single-pass opinion:

```bash
claude-second-opinion --reviewer codex --task "Review this patch for regressions"
```

### Full two-agent exchange (recommended)

```bash
ia-bridge \
  --task "Design safer rollout for installer migration" \
  --constraints "Prefer backward-compatible minimal changes"
```

## Output locations

- Claude-only runs: `~/.claude/opinions/`
- Bridge sessions: `~/.claude/ia-bridge/sessions/<timestamp>-<repo>/`

Each bridge session includes:
- `00-shared-context.md`
- `10-claude-round1.md`
- `20-codex-round1.md`
- `30-claude-critiques-codex.md`
- `40-codex-critiques-claude.md`
- `50-final-synthesis.md`
- `INDEX.md`

## Remove

```bash
cd ~/REPOS/Skills/mcps/ia-bridge-mcp
./uninstall.sh
```
