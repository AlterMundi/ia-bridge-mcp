# peer-opinion plugin

User-level collaboration plugin for Claude and Codex with a shared SDK-based MCP backend.

## Commands

- `/second-opinion [claude|codex] <task>`
  Uses MCP tool `single_opinion_run` with reviewer selection.

- `/ia-bridge <task>`
  Uses MCP tool `ia_bridge_run` and executes full two-agent protocol:
  1. Shared context packet
  2. Claude independent proposal
  3. Codex independent proposal
  4. Claude critiques Codex
  5. Codex critiques Claude
  6. Final synthesis

## Logging

- Claude-only: `~/.claude/opinions/`
- Bridge sessions: `~/.claude/ia-bridge/sessions/`
