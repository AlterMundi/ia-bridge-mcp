---
description: Run full Claude↔Codex exchange protocol through MCP bridge
argument-hint: "<task statement>"
allowed-tools: ["mcp__ia-bridge-mcp__ia_bridge_run", "mcp__ia-bridge-mcp__ia_bridge_list_sessions", "mcp__ia-bridge-mcp__ia_bridge_read_file"]
---

Selection rule:
- If the user asks for collaboration, bridge, compare Claude vs Codex, or mentions `ia_bridge`, you MUST use `ia_bridge_run`.

Call MCP tool `ia_bridge_run` with:

- `task`: `$ARGUMENTS`

Then summarize:
1. Session directory
2. Final synthesis file
3. Three key decisions
4. Remaining unresolved risks
