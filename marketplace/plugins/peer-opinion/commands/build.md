---
command: build
description: Run autonomous implementation/build task with a single agent
argument-hint: "<agent> <task description>"
---

# Build Command

Executes an autonomous build/implementation task using a single agent.

## Usage

```
/build grok Implement JWT refresh token rotation with proper revocation

/build claude --with-review Refactor the auth module error handling

/build codex Add comprehensive tests for the payment flow
```

## Options

- `--agent <id>` — Specify the agent to use (default: grok)
- `--model <name>` — Override the agent's default model
- `--with-review` — After build, run a second-opinion review
- `--effort <level>` — Override effort level (low/medium/high/xhigh/max, default: max)
- `--max-turns <n>` — Override max turns (default: 80)
- `--constraints <text>` — Additional constraints or requirements

## What it does

1. Detects the git repository context (branch, commit, diff)
2. Prepares a structured implementation prompt
3. Dispatches to the chosen agent in autonomous mode (always-approve)
4. Returns the implementation result with a summary
