---
description: Run a structured single-pass second-opinion (Claude or Codex) through MCP bridge
argument-hint: "[claude|codex] <task statement>"
allowed-tools: ["mcp__ia-bridge-mcp__single_opinion_run"]
---

Selection rule:
- Use this command ONLY when the user explicitly asks for a "second opinion".
- If the user asks for bridge/collaboration/Claude+Codex exchange, do NOT use this command; use `ia_bridge_run`.
- Reviewer selection:
  - If user specifies `claude` or `codex`, use that reviewer.
  - If unspecified, default to `claude`.

Call MCP tool `single_opinion_run` with:

- `task`: the task text from `$ARGUMENTS` (without reviewer token if provided)
- `reviewer`: `claude` or `codex`

Then show:
1. Log file path
2. Top 3 findings
