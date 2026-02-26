---
description: Run the full Claude<->Codex bridge protocol through ia-bridge MCP
argument-hint: "<task statement>"
allowed-tools: ["mcp__ia-bridge-mcp__ia_bridge_run", "mcp__ia-bridge-mcp__ia_bridge_list_sessions", "mcp__ia-bridge-mcp__ia_bridge_read_file"]
---

Use when the user asks for bridge/collaboration/comparison across Claude and Codex.

1. Call `ia_bridge_run` with `task=$ARGUMENTS`.
2. Treat response as background start; capture `log_dir` and `pid`.
3. Poll `ia_bridge_list_sessions` until the session appears complete.
4. Read `50-final-synthesis.md` with `ia_bridge_read_file`.
5. Report: session directory, synthesis path, top 3 decisions, unresolved risks.
