# peer-opinion Plugin

Claude/Codex collaboration commands backed by `ia-bridge-mcp`.

## Commands

- `/second-opinion [claude|codex] <task>`: run one reviewer with `single_opinion_run`.
- `/forum <task>`: run full 3-round Claude/Codex bridge with `ia_bridge_run`.

Execution defaults:

- `single_opinion_run` uses `mode=async` unless sync is requested.
- `ia_bridge_run` is async; use `ia_bridge_job_status` and `ia_bridge_job_result`.

Bridge protocol stages:

1. Shared context
2. Claude proposal
3. Codex proposal
4. Claude critique
5. Codex critique
6. Final synthesis

## Logs

- Single opinions: `~/.bridge-ai/opinions/`
- Bridge sessions: `~/.bridge-ai/sessions/`
- Job metadata/logs: `~/.bridge-ai/jobs/`
