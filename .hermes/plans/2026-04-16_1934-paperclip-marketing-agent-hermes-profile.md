# Implementation Plan: Wire Paperclip Marketing Agent to Hermes `marketing` Profile

## Goal

Make the Paperclip "Marketing Agent" run under the isolated Hermes `marketing` profile so it loads the BitmapForge marketing SOUL.md, uses the correct voice/persona, and does not execute with the current CEO instructions.

## Current Context

- **Hermes profile**: `/home/agent/.hermes/profiles/marketing/SOUL.md` exists and defines the BitmapForge Marketing Assistant persona (technical-friendly, slightly playful, evidence-based, no corporate speak).
- **Hermes alias**: `marketing` is already registered (`hermes profile alias marketing`).
- **Paperclip company**: `BitmapForge` (`61dee522-ebff-4310-910b-0716b4365b66`).
- **Paperclip agent**: `Marketing Agent` (`1f588b36-c1f5-4843-82e5-5f0878aa01c0`), role=`marketing`, adapter=`hermes_local`.
- **Current bug**: The agent's `AGENTS.md` instructions contain CEO delegation logic ("You are the CEO. Your job is to lead the company..."), which is completely wrong for a marketing agent.
- **Missing config**: The `hermes_local` adapter config does not specify a Hermes profile, so it falls back to the default `hermes` binary and default profile.

## Proposed Approach

1. **Update the Paperclip agent adapter config** to use the `marketing` Hermes alias (`hermesCommand: "marketing"`). This is the cleanest integration because the alias already launches Hermes with the correct profile directory and SOUL.md.
2. **Replace the agent's `AGENTS.md`** with marketing-appropriate instructions that complement the SOUL.md persona (focus on drafting, research, and delegation rules for marketing work).
3. **Verify end-to-end** by triggering a Paperclip heartbeat or a test task for the Marketing Agent and inspecting the Hermes session to confirm the `marketing` profile loaded.

## Step-by-Step Plan

### Step 1 — Update `adapterConfig` for the Marketing Agent

Target: Paperclip agent record for `Marketing Agent`.

Add these fields to `adapterConfig` (merge with existing keys like `instructionsFilePath`):

```json
{
  "hermesCommand": "marketing",
  "model": "anthropic/claude-sonnet-4",
  "quiet": true,
  "timeoutSec": 300,
  "persistSession": true
}
```

How:
- Option A: PATCH via Paperclip API (`/api/agents/<id>`).
- Option B: Direct SQL update in embedded PostgreSQL.

### Step 2 — Fix the Agent Instructions (`AGENTS.md`)

Target file:
`~/.paperclip/instances/default/companies/61dee522-ebff-4310-910b-0716b4365b66/agents/1f588b36-c1f5-4843-82e5-5f0878aa01c0/instructions/AGENTS.md`

Replace CEO content with a concise marketing-agent brief that:
- Identifies the agent as the CMO / Marketing Lead for BitmapForge.
- Delegates technical implementation to the CTO and design to the UXDesigner.
- Owns social media drafting, showcase gallery generation, community research, and website copy.
- References `SOUL.md` voice rules (already present in the Hermes profile).
- Explicitly forbids posting publicly without human approval.

### Step 3 — End-to-End Verification

1. Ensure Paperclip server is running (`paperclipai run`).
2. Trigger the Marketing Agent heartbeat (via dashboard or by creating a marketing task).
3. Check the agent run logs in Paperclip to confirm the command invoked was `marketing chat ...` instead of `hermes chat ...`.
4. Check the generated Hermes session in `~/.hermes/profiles/marketing/sessions/` to confirm the profile was active.

### Step 4 — Documentation

Add a brief note to the project docs (or a `MARKETING_AGENT_SETUP.md` in the Paperclip instance dir) documenting:
- Which Hermes profile maps to which Paperclip agent.
- How to recreate the alias if profiles are rebuilt.

## Files Likely to Change

| File | Change |
|------|--------|
| `~/.paperclip/instances/default/companies/.../agents/.../instructions/AGENTS.md` | Replace CEO text with marketing agent brief |
| Paperclip DB `agents.adapter_config` (agent `1f588b36...`) | Add `hermesCommand: "marketing"` and execution settings |

## Tests / Validation

- [ ] `adapterConfig.hermesCommand` is `"marketing"` in the DB.
- [ ] `AGENTS.md` no longer contains "You are the CEO".
- [ ] A Paperclip run for the Marketing Agent shows `marketing chat -q ...` in stdout logs.
- [ ] The corresponding Hermes session file appears under `~/.hermes/profiles/marketing/sessions/`.

## Risks, Tradeoffs, and Open Questions

- **Risk**: If the `marketing` alias binary is not in the PATH of the Paperclip server process, the spawn will fail. Mitigation: verify `which marketing` from the same shell that starts `paperclipai run`.
- **Risk**: The Hermes `marketing` profile uses `K2.6-code-preview` (Kimi) which may not have all toolsets enabled. Mitigation: ensure the profile's `config.yaml` has the required toolsets (`browser`, `terminal`, `file`, `web`, etc.) for marketing tasks.
- **Tradeoff**: Using `hermesCommand: "marketing"` binds the Paperclip agent tightly to the local alias. If we move to a remote Paperclip instance, we'd need to switch adapters. This is acceptable for the current local setup.
- **Open question**: Should we also update the Marketing Agent's `name` or `role` in Paperclip? The DB already says `name='Marketing Agent'`, `role='marketing'`, so this seems correct.
