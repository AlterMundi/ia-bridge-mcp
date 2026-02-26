---
description: Run the full Claude<->Codex bridge protocol through forum MCP
argument-hint: "<task statement>"
allowed-tools: ["mcp__forum-mcp__ia_bridge_run", "mcp__forum-mcp__ia_bridge_job_status", "mcp__forum-mcp__ia_bridge_job_result", "mcp__forum-mcp__ia_bridge_read_file"]
---

Use when the user asks for bridge/collaboration/comparison across Claude and Codex.

1. Call `ia_bridge_run` with `task=$ARGUMENTS` (async contract).
2. Capture `job_id` from response.
3. Poll `ia_bridge_job_status` using `job_id` until status is `succeeded` or `failed`.
4. Call `ia_bridge_job_result` using `job_id`.
5. If `result_path` is returned, optionally read it with `ia_bridge_read_file`.
6. Report: `job_id`, status, session/result path, top 3 decisions, unresolved risks.
