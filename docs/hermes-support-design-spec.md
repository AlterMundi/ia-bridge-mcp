# Design Spec: Add Hermes Support to ia-bridge-mcp

## Problem Statement

`ia-bridge-mcp` is hardcoded for a Claude ↔ Codex pairing. Every layer — install, runtime, MCP schema, shell scripts, and documentation — assumes exactly these two agents. We need to generalize the architecture so that **any CLI agent** (Claude, Codex, Hermes, and future ones) can participate in the bridge protocol.

## Goals

1. **Adapter abstraction**: Each agent is described by a config-driven adapter with structured execution fields and strict validation.
2. **Dynamic agent selection at install time**: The installer asks which agents the user wants to enable.
3. **Generic forum protocol**: Round roles (proposer A, proposer B, critic A→B, critic B→A, synthesizer) are agent-agnostic.
4. **Hermes compatibility**: Hermes uses `hermes chat -q "<prompt>"` instead of stdin piping; the adapter must handle this safely with prompt-size guards and array-based execution (no shell-string interpolation).
5. **Backward compatibility**: Existing users with no config get a seamless migration path (Claude + Codex defaults). Old session filenames are still resumable.

## Non-Goals

- Adding a UI/TUI installer (keep it bash-based).
- Supporting non-CLI agents (web APIs, etc.).
- Changing the session artifact format beyond file naming and frontmatter.

## Proposed Architecture

### 1. Configuration Layer: `~/.bridge-ai/config.json`

Created by `install.sh` and read by all scripts + the MCP server. Version 2.

```json
{
  "version": 2,
  "agents": {
    "claude": {
      "enabled": true,
      "name": "Claude Code",
      "command": "claude",
      "args": ["-p", "--output-format", "text", "--model", "{{model}}"],
      "prompt_transport": "stdin",
      "output_mode": "stdout",
      "default_model": "opus",
      "max_prompt_bytes": null,
      "supports_mcp_registration": true,
      "capabilities": {
        "env_unset": ["CLAUDECODE"]
      }
    },
    "codex": {
      "enabled": true,
      "name": "Codex",
      "command": "codex",
      "args": ["exec", "-m", "{{model}}", "-C", "{{cwd}}", "--skip-git-repo-check", "--output-last-message", "{{output_file}}", "-"],
      "prompt_transport": "stdin",
      "output_mode": "file",
      "default_model": "o3",
      "max_prompt_bytes": null,
      "supports_mcp_registration": true,
      "capabilities": {}
    },
    "hermes": {
      "enabled": true,
      "name": "Hermes Agent",
      "command": "hermes",
      "args": ["chat", "-q", "{{prompt}}", "--quiet", "-m", "{{model}}", "--source", "tool"],
      "prompt_transport": "arg",
      "output_mode": "stdout",
      "default_model": "anthropic/claude-sonnet-4",
      "max_prompt_bytes": 120000,
      "supports_mcp_registration": false,
      "capabilities": {}
    }
  },
  "forum": {
    "agent_a": "claude",
    "agent_b": "codex",
    "synthesizer": "codex"
  },
  "mcp": {
    "registered_clients": ["claude", "codex"]
  },
  "runtime": {
    "timeout_seconds": 300
  }
}
```

**Schema rules:**
- `prompt_transport`: `"stdin"` pipes the prompt into the process; `"arg"` substitutes the literal prompt text for the `{{prompt}}` token inside `args`.
- `output_mode`: `"stdout"` captures process stdout; `"file"` reads from the path given by `{{output_file}}` after the process exits.
- `max_prompt_bytes`: If set, `bridge_run_agent` rejects prompts whose **UTF-8 byte length** exceeds this limit. For Hermes this is **120000** — a conservative per-adapter ceiling below the observed ~130KB `ARG_MAX` cliff. It is not a guarantee against the platform `execve` limit because argv and environment size also count toward `ARG_MAX`.
- `args` may contain these substitution tokens:
  - `{{prompt}}` — the literal prompt text (required for `prompt_transport: arg`; forbidden for `stdin`)
  - `{{model}}` — the resolved model name for this invocation
  - `{{output_file}}` — a temp file path (required for `output_mode: file`; forbidden for `stdout`)
  - `{{cwd}}` — the current working directory
- Unknown substitution tokens in `args` cause a fail-fast validation error.
- Unknown fields in `agents[<id>]` are ignored (forward compatibility).

**Adapter validation rules (enforced by `lib/adapters.sh`):**
| Rule | Failure message |
|------|-----------------|
| `command` must be a non-empty string | `Agent '<id>' missing or invalid field: command` |
| `args` must be an array of strings | `Agent '<id>' missing or invalid field: args` |
| `prompt_transport=arg` requires exactly one `{{prompt}}` | `Agent '<id>' with prompt_transport='arg' must have exactly one '{{prompt}}' token in args` |
| `prompt_transport=stdin` must have zero `{{prompt}}` | `Agent '<id>' with prompt_transport='stdin' must not contain '{{prompt}}' in args` |
| `output_mode=file` requires exactly one `{{output_file}}` | `Agent '<id>' with output_mode='file' must have exactly one '{{output_file}}' token in args` |
| `output_mode=stdout` must have zero `{{output_file}}` | `Agent '<id>' with output_mode='stdout' must not contain '{{output_file}}' in args` |
| Forum roles must point to enabled agents | `Forum role '<role>' uses disabled or unknown agent '<id>'` |

### 2. Shared Libraries

#### `lib/config.sh`

Responsibilities:
- Load `~/.bridge-ai/config.json` with `jq`.
- Validate `version`. If missing or < 2, treat as legacy and auto-migrate in memory.
- Return defaults for missing keys.
- Provide helpers:
  - `bridge_config_path` — returns config file path.
  - `bridge_load_config` — prints the validated config JSON.
  - `bridge_agent_ids` — lists enabled agent IDs.
  - `bridge_agent_field <id> <field>` — safely reads a field with fallback.
  - `bridge_forum_default <role>` — returns default agent ID for `agent_a`, `agent_b`, or `synthesizer`.

**Migration contract:**
| Condition | Behavior |
|-----------|----------|
| Config missing | Return hardcoded v2 defaults (Claude + Codex enabled, legacy forum defaults). Print stderr warning. |
| Config version < 2 | Deep-merge with v2 defaults. User-defined keys win at every level. Arrays are replaced (not merged). |
| Partial `config.json` | Missing fields filled from defaults. |
| Malformed JSON or wrong top-level types | **Hard-fail everywhere** (both shell and server) with the same error: `Invalid config at ~/.bridge-ai/config.json: <details>`. |
| Unknown agent ID in `forum` roles | Fail fast: `Unknown or disabled agent '<id>' in forum.<role>`. |
| Invalid `prompt_transport` | Fail fast: `Invalid prompt_transport '<value>' for agent '<id>'. Must be 'stdin' or 'arg'`. |
| Missing `args` or `command` | Fail fast: `Agent '<id>' missing required field: command/args`. |
| Zero enabled agents | Fail fast: `At least one agent must be enabled in config.json`. |
| Only one agent enabled | `forum.sh` fails fast: `Forum requires at least 2 enabled agents.`. `second-opinion.sh` works normally. |

**Resume compatibility:**
Old sessions with filenames like `10-claude-round1.md` remain resumable. `forum.sh` detects files by glob patterns and maps legacy names to their roles in memory. New sessions use neutral names (`10-agent-a-round1.md`).

#### `lib/adapters.sh`

Provides the generic agent runner:

```bash
bridge_run_agent <agent_id> <prompt_file> <output_file> [model_override]
```

Behaviors:
1. Read the adapter config for `<agent_id>`.
2. Resolve model: `model_override` → `agents.<id>.default_model` → error.
3. Validate adapter schema (command, args, token counts, transport/output consistency).
4. If `max_prompt_bytes` is set, compute the UTF-8 byte length of the prompt and reject if it exceeds the limit.
5. Build the command **as an array** (no `eval`, no shell-string interpolation of the prompt):
   - Start with `agents.<id>.command`.
   - Iterate `args`, replacing tokens with literal strings (`{{model}}`, `{{output_file}}`, `{{cwd}}`).
   - For `prompt_transport: arg`, replace the single `{{prompt}}` token with the literal prompt string.
   - For `prompt_transport: stdin`, remove any `{{prompt}}` token and pipe the prompt file via stdin.
6. Execute using bash array expansion or `env -i` + `exec` to avoid string interpolation risks.
7. Apply `timeout_seconds` wrapper: `timeout <runtime.timeout_seconds>s <command...>`.
8. Apply any `capabilities.env_unset` before spawning.
9. Return the underlying exit code.

**Prompt-size guard for Hermes:**
If prompt exceeds `max_prompt_bytes`, the adapter emits:
```
Error: Prompt size (N bytes) exceeds agent 'hermes' limit of 120000 bytes.
Suggestion: truncate the diff or reduce context files.
```

### 3. Refactored `forum.sh`

Changes:
- Source `lib/adapters.sh` and `lib/config.sh`.
- Remove `--claude-model` and `--codex-model`. Add:
  - `--agent-a <id>` (default from `config.forum.agent_a`)
  - `--agent-b <id>` (default from `config.forum.agent_b`)
  - `--synthesizer <id>` (default from `config.forum.synthesizer`)
  - `--model-override <id>:<model>` (repeatable; e.g. `--model-override hermes:claude-opus-4`)
- File naming becomes neutral:
  - `10-agent-a-round1.md`
  - `20-agent-b-round1.md`
  - `30-agent-a-critique.md`
  - `40-agent-b-critique.md`
  - `50-final-synthesis.md`
- **Frontmatter header** in every artifact records both role and agent identity:
  ```yaml
  ---
  role: agent_a
  agent_id: hermes
  agent_name: Hermes Agent
  model: anthropic/claude-sonnet-4
  round: 1
  ---
  ```
- Prompt templates replace literal "Claude" / "Codex" with `agents.<id>.name`.
- Resume logic maps both old (`10-claude-round1.md`) and new (`10-agent-a-round1.md`) filenames to the same roles.

### 4. Refactored `second-opinion.sh`

Changes:
- `--reviewer` enum becomes dynamic (any enabled agent from config).
- `--model` remains as a shorthand for `--model-override <reviewer>:<model>`.
- `--model-override <id>:<model>` is also accepted for consistency (repeatable).
- Use `bridge_run_agent` instead of inline `if claude ... else codex`.
- Response section title becomes `## <agent_name> Response`.
- Include frontmatter:
  ```yaml
  ---
  agent_id: hermes
  agent_name: Hermes Agent
  model: anthropic/claude-sonnet-4
  task: <task_description>
  ---
  ```

### 5. Refactored `install.sh`

Changes:
- Check for `jq` and `node` availability. If `jq` is missing, prompt to install it or abort.
- Detect available agents in PATH (`claude`, `codex`, `hermes`).
- Interactive selection (can be bypassed with `--non-interactive --agents claude,codex`):
  ```
  Select agents to enable (space-separated):
  [x] claude  (found: /usr/local/bin/claude)
  [x] codex   (found: /usr/local/bin/codex)
  [ ] hermes  (found: /usr/local/bin/hermes)
  ```
- Only require the *selected* agents to exist (today it hard-fails if either claude or codex is missing).
- Write `config.json` with detected defaults.
- Register MCP server only with agents where `supports_mcp_registration: true`.
- Forum defaults default to the first two selected agents (agent_a = first, agent_b = second, synthesizer = second), overridable with `--forum-defaults <a>,<b>,<synth>`.

### 6. Refactored `uninstall.sh`

Changes:
- Read `config.json` → `mcp.registered_clients`.
- Unregister only from those clients.
- Remove `config.json` on full uninstall (optional, preserve logs).

### 7. MCP Server and CLI Wrapper Updates

**`mcp_tool_call.py`:**
- **Must be updated** to support repeatable flags as arrays so that `--model-override id:model` can appear multiple times.
- When the same flag appears more than once, store its values as a list: `{"model_override": ["hermes:claude-opus-4", "codex:o3"]}`.
- When a flag appears once, keep the scalar value for backward compatibility.

**`ia_bridge_mcp_server.mjs`:**
- On startup, load `~/.bridge-ai/config.json`.
- If config is missing, fall back to built-in v2 defaults (Claude + Codex) and log a warning.
- **If config is malformed, hard-fail on startup** with `Invalid config at ~/.bridge-ai/config.json: <details>` (same behavior as shell scripts).
- Build tool schemas dynamically:
  - `single_opinion_run`: `reviewer` enum = enabled agent IDs.
  - `ia_bridge_run`: remove positional `claude_model` / `codex_model`.
    - Add `model_overrides`: object whose keys are enabled agent IDs and values are model strings.
    - Example: `{ "claude": "opus", "codex": "o3", "hermes": "claude-sonnet-4" }`
- **Translation contract**: When invoking shell scripts, the server **explicitly expands** `model_overrides` into repeatable `--model-override id:model` flags before passing them to `argsToFlags()`.
- Validate `model_overrides` keys against enabled agent IDs. Reject unknown IDs.
- If the same agent ID appears more than once in the overrides object, the last value wins (standard JSON object behavior).
- Descriptions become neutral: "Run a full peer-review bridge between two configured agents."
- Pass agent IDs through to shell scripts as flags (`--agent-a`, `--agent-b`, `--synthesizer`, `--model-override id:model`).

### 8. Plugin Commands and README

- `commands/second-opinion.md` and `commands/forum.md`: remove hardcoded Claude/Codex references.
- `README.md`: update pitch to "multi-agent bridge" and list supported adapters.
- Document the Hermes argv visibility caveat: because Hermes requires `prompt_transport: arg`, prompts are passed as command-line arguments and may be visible to other local processes via `ps` or `/proc`. For sensitive codebases, prefer agents that use `prompt_transport: stdin`.

## Hermes Execution Contract

Hermes does **not** read prompts from stdin for programmatic use. Verified command shape:

```bash
hermes chat -q "<prompt text>" --quiet -m <model> --source tool
```

Because of this, the adapter uses `prompt_transport: arg` and substitutes the literal prompt text for `{{prompt}}` in the `args` array.

**Security/visibility note:** Array execution (no `eval`) eliminates shell interpolation risks, but the full prompt is placed in `argv`. On multi-user systems, other processes may be able to see the prompt via `ps` or `/proc`. This is an unavoidable consequence of Hermes not supporting stdin prompts. The `max_prompt_bytes: 120000` setting is a conservative per-adapter ceiling below the observed `ARG_MAX` cliff, not a guarantee against platform-specific `execve` limits because `argv` and environment size also contribute to the limit.

If users encounter this limit in practice, the recommended mitigation is to reduce context (fewer files, shorter diffs) rather than trying to bypass the CLI constraint.

## Migration Path for Existing Users

| Condition | Behavior |
|-----------|----------|
| `config.json` missing | Scripts fall back to built-in v2 defaults (Claude + Codex) with a deprecation warning to stderr. `install.sh` creates the file on first run. |
| `config.json` version < 2 | Deep-merged with v2 defaults. User-defined keys win at every level. Arrays are replaced, not merged. |
| Partial `config.json` | Missing fields filled from defaults. |
| Malformed JSON / wrong types | Hard-fail everywhere with the same error message. |
| Old session directories | Fully resumable. `forum.sh` detects both legacy filenames (`10-claude-round1.md`) and new neutral filenames. |

## Files Changed

| File | Change |
|------|--------|
| `lib/adapters.sh` | **New** — generic agent runner |
| `lib/config.sh` | **New** — config I/O helpers |
| `install.sh` | Agent selection, config generation, `jq` dependency check, conditional MCP registration |
| `uninstall.sh` | Read config, unregister selectively |
| `forum.sh` | Generic round protocol, neutral file names, frontmatter headers, legacy resume support |
| `second-opinion.sh` | Generic reviewer selection, frontmatter headers |
| `mcp/ia_bridge_mcp_server.mjs` | Dynamic schemas, config loading, `model_overrides` → `--model-override` translation |
| `mcp/mcp_tool_call.py` | **Updated** — repeatable flags stored as arrays |
| `commands/second-opinion.md` | Neutral copy |
| `commands/forum.md` | Neutral copy |
| `README.md` | Update description and prerequisites |

## Implementation Order

1. `lib/config.sh`
2. `lib/adapters.sh`
3. Shell flag parsing changes in `second-opinion.sh` / `forum.sh`
4. `mcp_tool_call.py` repeated-flag support
5. `ia_bridge_mcp_server.mjs` dynamic schema + object-to-flag translation
6. `install.sh` / `uninstall.sh`
7. Docs

**Rule**: the server must not emit new flags before the scripts can consume them, and the wrapper must support repeated flags before the server emits them.

## Testing Plan

1. Run `./install.sh --non-interactive --agents claude,codex,hermes` and verify `config.json` schema.
2. Run `second-opinion --reviewer hermes --task "Hello world"` and verify output file contains frontmatter.
3. Run `forum --task "Hello world" --agent-a hermes --agent-b codex --synthesizer codex` and verify all 5 files with frontmatter.
4. Test prompt-size guard: create a >130KB prompt, run with `--reviewer hermes`, expect clean error instead of shell failure.
5. Test repeated `--model-override` flags: `second-opinion --model-override hermes:a --model-override codex:b` passes both to the wrapper correctly.
6. Test legacy resume: create an old-format session dir and run `forum --resume <dir>`.
7. Run Codex CLI audit on the implementation patch before PR.

## Open Questions

1. Should the synthesizer default to `agent_b`, or should we require an explicit `--synthesizer` flag when `agent_a != agent_b`?
2. Hermes does not have an MCP registration CLI. Should we attempt to write Hermes MCP config manually (e.g., `~/.hermes/mcp_servers.json`), or wait for native support?
3. Should `install.sh` support a `--default-pair claude,hermes` shortcut for the forum defaults?
