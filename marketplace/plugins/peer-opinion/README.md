# peer-opinion Plugin

Claude/Codex collaboration commands backed by `ia-bridge-mcp`.

## Commands

- `/second-opinion [claude|codex] <task>`: run one reviewer with `single_opinion_run`.
- `/ia-bridge <task>`: run full 3-round Claude/Codex bridge with `ia_bridge_run`.

Bridge protocol stages:

1. Shared context
2. Claude proposal
3. Codex proposal
4. Claude critique
5. Codex critique
6. Final synthesis

## Logs

- Single opinions: `~/.claude/opinions/`
- Bridge sessions: `~/.claude/ia-bridge/sessions/`
