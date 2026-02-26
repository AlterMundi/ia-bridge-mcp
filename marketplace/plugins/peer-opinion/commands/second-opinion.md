---
description: Run a structured single-pass second opinion (Claude or Codex) through ia-bridge MCP
argument-hint: "[claude|codex] <task statement>"
allowed-tools: ["mcp__ia-bridge-mcp__single_opinion_run"]
---

Use only when the user explicitly asks for a second opinion.

1. Parse reviewer from `$ARGUMENTS` if present (`claude` or `codex`), default to `claude`.
2. Call `single_opinion_run` with `task=<task-text>` and `reviewer=<reviewer>`.
3. Report: log path, top 3 findings, confidence level, unknowns.

If the user requests a multi-round collaboration instead, use `ia_bridge_run`.
