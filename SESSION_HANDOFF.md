# Session Handoff: Hermes Support for ia-bridge-mcp

**Date**: 2026-04-16  
**Project**: `/home/agent/Projects/ia-bridge-mcp` (clean clone of `https://github.com/AlterMundi/ia-bridge-mcp.git`)  
**Goal**: Generalize the hardcoded Claude↔Codex architecture into a config-driven multi-agent adapter system, adding Hermes support.

---

## What Has Been Done

### 1. Codebase Analysis
Read and analyzed all hardcoded touchpoints:
- `README.md` — entire pitch assumes Claude + Codex
- `install.sh` — requires both `claude` and `codex` in PATH; registers MCP with both
- `uninstall.sh` — removes MCP from `claude` and `codex` only
- `mcp/ia_bridge_mcp_server.mjs` — tool schemas hardcode `reviewer: ["claude", "codex"]`, `claude_model`, `codex_model`
- `marketplace/plugins/peer-opinion/scripts/second-opinion.sh` — `if [[ "$REVIEWER" == "claude" ]]` branching with direct `claude`/`codex` spawns
- `marketplace/plugins/peer-opinion/scripts/forum.sh` — fixed 3-round protocol with literal "Claude" and "Codex" file names and prompt roles
- `commands/second-opinion.md` and `commands/forum.md` — hardcoded agent names

### 2. Design Spec Written
Created `docs/hermes-support-design-spec.md` with:
- `~/.bridge-ai/config.json` as the configuration layer (version 2)
- `lib/adapters.sh` + `lib/config.sh` shared libraries
- Generic forum protocol with `--agent-a`, `--agent-b`, `--synthesizer`
- Refactored `install.sh` with interactive agent selection
- MCP server dynamic schema updates
- Hermes execution details (`hermes chat -q ...`)

### 3. Codex CLI Audit Completed
Ran the design spec through Codex CLI for audit.

**Verdict: ITERATE FIRST**

Key findings:
1. **Schema is still too pair-specific**: `agent_a_model` / `agent_b_model` should be keyed by agent ID, not positional role.
2. **Config underspecification**: `timeout_seconds` is referenced but not in the schema sample.
3. **Role/identity ambiguity**: Neutral filenames are fine, but headers should record both role and agent ID.
4. **Hermes execution is a blocker**: The spec proposes `hermes chat -q "$(cat prompt.txt)"`, which Codex flagged as a known `ARG_MAX` failure mode for large diffs. Shell expansion also introduces quoting and security risks.
5. **Config schema should avoid `exec_template` string templating** in favor of structured fields (`args`, `supports_stdin`, `prompt_transport`, `output_mode`, `supports_mcp_registration`).
6. **Missing migration contract** for partial configs, unknown agents, invalid templates.
7. **MVP implementation order**: `lib/config.sh` → `lib/adapters.sh` → `second-opinion.sh`.

---

## Current Blockers

1. **Hermes prompt transport is unresolved**
   - Need to test whether `hermes chat` supports safer prompt input (stdin file, `@file`, or a dedicated flag).
   - The `$(cat file)` approach is explicitly flagged as unsafe.

2. **GitHub credentials not configured on this device**
   - `git config`: `kate (LaVanguardIA agent) / kate@lavanguardia.local`
   - `gh` CLI is **not installed**
   - Cannot push branches or open PRs as `santiagocetran` without setup.

---

## Next Steps (Recommended Order)

1. **Investigate Hermes CLI** for a safe large-prompt input mechanism.
2. **Revise `docs/hermes-support-design-spec.md`**:
   - Replace positional model params with agent-ID-keyed overrides.
   - Replace `exec_template` with structured adapter fields.
   - Define explicit prompt transport contract.
   - Add migration/validation contract.
3. **Re-audit revised spec** with Codex CLI.
4. **Implement** in this order: `lib/config.sh` → `lib/adapters.sh` → `second-opinion.sh` → `forum.sh` → `install.sh` / `uninstall.sh` → `mcp/ia_bridge_mcp_server.mjs` → docs/commands.
5. **Install `gh` CLI and auth** as `santiagocetran` (or push manually) to open the PR.

---

## Key Files

| File | Status |
|------|--------|
| `docs/hermes-support-design-spec.md` | Draft written; needs revision per audit |
| `/tmp/codex-audit-response.md` | Codex audit output (on local disk) |
| `lib/adapters.sh` | Does not exist yet |
| `lib/config.sh` | Does not exist yet |
| All source files | Clean (no local modifications committed) |

---

## Quick Context

- **BitmapForge / Paperclip**: The Paperclip server is running on `10.10.20.37:3100` with company `BitmapForge` and agent `Marketing Agent` already configured. That work is orthogonal to this task.
- **User preference**: Always audit implementation plans with Codex CLI (or ia-bridge-mcp) before changing files. Do not modify files without explicit human approval.
