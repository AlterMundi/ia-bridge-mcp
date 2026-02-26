#!/usr/bin/env bash
set -euo pipefail

# Allow running from within a Claude Code session (avoid nested-session detection)
unset CLAUDECODE 2>/dev/null || true

usage() {
  cat <<'USAGE'
Usage:
  ia-bridge.sh --task "<task description>" [options]
  ia-bridge.sh --resume <session-dir> [--task <additional context>] [options]

Options:
  --task <text>             Required (new session). Shared task statement.
  --resume <session-dir>    Resume an interrupted session by directory path.
                            Skips completed rounds and continues from where it failed.
                            Use --task to inject additional context when resuming.
  --constraints <text>      Optional. Shared constraints for both AIs.
  --claude-model <name>     Optional. Claude model (default: opus).
  --codex-model <name>      Optional. Codex model (default: gpt-5).
  --log-dir <path>          Optional. Session root (default: ~/.bridge-ai/sessions).
  --max-diff-lines <n>      Optional. Max diff lines in shared packet (default: 300).
  --timeout-seconds <n>     Optional. Per-call timeout in seconds (default: 240).
  -h, --help                Show this help.
USAGE
}

require_option_value() {
  local option_name="$1"
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    echo "Error: ${option_name} requires a value." >&2
    usage
    exit 1
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

TASK=""
CONSTRAINTS=""
CLAUDE_MODEL="opus"
CODEX_MODEL="gpt-5"
LOG_DIR="${HOME}/.bridge-ai/sessions"
MAX_DIFF_LINES=300
TIMEOUT_SECONDS=240
RESUME_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      require_option_value "$1" "${2:-}"
      TASK="$2"
      shift 2
      ;;
    --resume)
      require_option_value "$1" "${2:-}"
      RESUME_DIR="$2"
      shift 2
      ;;
    --constraints)
      require_option_value "$1" "${2:-}"
      CONSTRAINTS="$2"
      shift 2
      ;;
    --claude-model)
      require_option_value "$1" "${2:-}"
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    --codex-model)
      require_option_value "$1" "${2:-}"
      CODEX_MODEL="$2"
      shift 2
      ;;
    --log-dir)
      require_option_value "$1" "${2:-}"
      LOG_DIR="$2"
      shift 2
      ;;
    --max-diff-lines)
      require_option_value "$1" "${2:-}"
      MAX_DIFF_LINES="$2"
      shift 2
      ;;
    --timeout-seconds)
      require_option_value "$1" "${2:-}"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TASK" && -z "$RESUME_DIR" ]]; then
  echo "Error: --task is required (or --resume <session-dir> to continue an existing session)." >&2
  usage
  exit 1
fi

if [[ -n "$RESUME_DIR" ]]; then
  if [[ ! -d "$RESUME_DIR" ]]; then
    echo "Error: resume directory not found: $RESUME_DIR" >&2
    exit 1
  fi
  RESUME_DIR="$(realpath "$RESUME_DIR")"
fi

if ! [[ "$MAX_DIFF_LINES" =~ ^[0-9]+$ ]] || [[ "$MAX_DIFF_LINES" -le 0 ]]; then
  echo "Error: --max-diff-lines must be a positive integer." >&2
  exit 1
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -le 0 ]]; then
  echo "Error: --timeout-seconds must be a positive integer." >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude CLI not found in PATH." >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex CLI not found in PATH." >&2
  exit 1
fi

START_DIR="$(pwd)"
WORK_ROOT="$START_DIR"
MODE="non-code"

if command -v git >/dev/null 2>&1; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$REPO_ROOT" ]]; then
    WORK_ROOT="$REPO_ROOT"
    MODE="code"
  fi
fi

cd "$WORK_ROOT"

if [[ "$MODE" == "code" ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo 'no-head')"
  STATUS="clean"
  if [[ -n "$(git status --porcelain)" ]]; then
    STATUS="dirty"
  fi

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    DIFF_CONTENT="$(git --no-pager diff HEAD -- . | sed -n "1,${MAX_DIFF_LINES}p")"
    RECENT_COMMITS="$(git --no-pager log --oneline -10)"
  else
    DIFF_CONTENT="$(git --no-pager diff -- . | sed -n "1,${MAX_DIFF_LINES}p")"
    RECENT_COMMITS="(No commits yet.)"
  fi

  if [[ -z "$DIFF_CONTENT" ]]; then
    DIFF_CONTENT="(No working-tree diff against HEAD.)"
  fi
else
  BRANCH="n/a"
  COMMIT="n/a"
  STATUS="n/a"
  RECENT_COMMITS="(Unavailable in non-code mode: no git repository detected.)"
  DIFF_CONTENT="(Unavailable in non-code mode: no git repository detected.)"
fi

# Build codex exec base command (add --skip-git-repo-check in non-git mode)
codex_exec() {
  local model="$1"; shift
  local work_root="$1"; shift
  local output_file="$1"; shift
  local extra_flags=""
  if [[ "$MODE" == "non-code" ]]; then
    extra_flags="--skip-git-repo-check"
  fi
  # shellcheck disable=SC2086
  run_with_timeout "$TIMEOUT_SECONDS" codex exec -m "$model" -C "$work_root" \
    $extra_flags --output-last-message "$output_file" - "$@"
}

if [[ -n "$RESUME_DIR" ]]; then
  SESSION_DIR="$RESUME_DIR"
  echo "Resuming session: $SESSION_DIR"
  if [[ -n "$TASK" ]]; then
    echo "Additional context appended to task."
    # Append additional context to the shared context file if it exists
    if [[ -f "$SESSION_DIR/00-shared-context.md" ]]; then
      printf '\n## Additional Context (resume)\n\n%s\n' "$TASK" >> "$SESSION_DIR/00-shared-context.md"
    fi
  fi
else
  STAMP="$(date +%Y%m%d-%H%M%S)"
  REPO_SLUG="$(basename "$WORK_ROOT")"
  SESSION_DIR="${LOG_DIR}/${STAMP}-${REPO_SLUG}"
  mkdir -p "$SESSION_DIR"
fi

SHARED_CONTEXT_FILE="$SESSION_DIR/00-shared-context.md"
ROUND1_PROMPT_FILE="$SESSION_DIR/01-round1-shared-prompt.txt"
CLAUDE_ROUND1_FILE="$SESSION_DIR/10-claude-round1.md"
CODEX_ROUND1_FILE="$SESSION_DIR/20-codex-round1.md"
CLAUDE_CRITIQUE_PROMPT="$SESSION_DIR/31-claude-critiques-codex.prompt.txt"
CODEX_CRITIQUE_PROMPT="$SESSION_DIR/32-codex-critiques-claude.prompt.txt"
CLAUDE_CRITIQUE_FILE="$SESSION_DIR/30-claude-critiques-codex.md"
CODEX_CRITIQUE_FILE="$SESSION_DIR/40-codex-critiques-claude.md"
SYNTHESIS_PROMPT="$SESSION_DIR/51-codex-synthesis.prompt.txt"
SYNTHESIS_FILE="$SESSION_DIR/50-final-synthesis.md"
INDEX_FILE="$SESSION_DIR/INDEX.md"
CODEX_CLI_LOG="$SESSION_DIR/codex-cli.log"

# Only write shared context and round-1 prompt if not resuming (files already exist)
if [[ ! -f "$SHARED_CONTEXT_FILE" ]]; then
  {
    printf '# IA Bridge Shared Context\n\n'
    printf -- '- Timestamp: %s\n' "$(date -Iseconds)"
    printf -- '- Working root: %s\n' "$WORK_ROOT"
    printf -- '- Mode (auto): %s\n' "$MODE"
    printf -- '- Branch: %s\n' "$BRANCH"
    printf -- '- Commit: %s\n' "$COMMIT"
    printf -- '- Worktree: %s\n' "$STATUS"
    printf -- '- Task: %s\n' "$TASK"
    printf -- '- Constraints: %s\n' "${CONSTRAINTS:-none}"
    printf -- '- Claude model: %s\n' "$CLAUDE_MODEL"
    printf -- '- Codex model: %s\n' "$CODEX_MODEL"
    printf -- '- Timeout per round (s): %s\n\n' "$TIMEOUT_SECONDS"
    printf '## Protocol\n\nsymmetric-ctx|same-evidence|same-shape|mutual-critique|synthesis=agree+disagree+risks\n\n'
    printf '## Recent Commits\n\n%s\n\n' "$RECENT_COMMITS"
    printf '## Diff Preview\n\n%s\n' "$DIFF_CONTENT"
  } > "$SHARED_CONTEXT_FILE"
fi

if [[ ! -f "$ROUND1_PROMPT_FILE" ]]; then
  {
    printf 'CTX root=%s mode=%s branch=%s commit=%s tree=%s\nTASK %s\nCONSTRAINTS %s\n\nCOMMITS\n%s\n\nDIFF\n%s\n\n' \
      "$WORK_ROOT" "$MODE" "$BRANCH" "$COMMIT" "$STATUS" "$TASK" "${CONSTRAINTS:-none}" \
      "$RECENT_COMMITS" "$DIFF_CONTENT"
    printf 'R1:propose-best-solution\nRULES no-tools|ctx-only|no-invented|assume-explicit|concise\n'
    printf 'OUT findings-by-severity|plan-max-6|edits+paths|verify-commands|alternative+tradeoff|confidence+unknowns|rationale\n'
  } > "$ROUND1_PROMPT_FILE"
fi

# Round 1: independent proposals
if [[ ! -f "$CLAUDE_ROUND1_FILE" ]]; then
  echo "Running Claude round 1..."
  run_with_timeout "$TIMEOUT_SECONDS" claude -p --output-format text --model "$CLAUDE_MODEL" < "$ROUND1_PROMPT_FILE" > "$CLAUDE_ROUND1_FILE"
else
  echo "Skipping Claude round 1 (already complete)."
fi

if [[ ! -f "$CODEX_ROUND1_FILE" ]]; then
  echo "Running Codex round 1..."
  if ! codex_exec "$CODEX_MODEL" "$WORK_ROOT" "$CODEX_ROUND1_FILE" < "$ROUND1_PROMPT_FILE" >/dev/null 2>>"$CODEX_CLI_LOG"; then
    echo "Error: Codex round 1 failed. See $CODEX_CLI_LOG" >&2
    exit 1
  fi
else
  echo "Skipping Codex round 1 (already complete)."
fi

if [[ ! -f "$CLAUDE_CRITIQUE_PROMPT" ]]; then
  {
    printf 'R2:critique-peer SELF=claude PEER=codex\nRULES no-tools|ctx+proposals-only|flag-unsupported\n\nCTX\n%s\n\nSELF\n%s\n\nPEER\n%s\n\nOUT agree|disagree|peer-gaps(tests/risks)|adopt-from-peer|revised-rec\n' \
      "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "$CLAUDE_ROUND1_FILE")" "$(cat "$CODEX_ROUND1_FILE")"
  } > "$CLAUDE_CRITIQUE_PROMPT"
fi

if [[ ! -f "$CODEX_CRITIQUE_PROMPT" ]]; then
  {
    printf 'R2:critique-peer SELF=codex PEER=claude\nRULES no-tools|ctx+proposals-only|flag-unsupported\n\nCTX\n%s\n\nSELF\n%s\n\nPEER\n%s\n\nOUT agree|disagree|peer-gaps(tests/risks)|adopt-from-peer|revised-rec\n' \
      "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "$CODEX_ROUND1_FILE")" "$(cat "$CLAUDE_ROUND1_FILE")"
  } > "$CODEX_CRITIQUE_PROMPT"
fi

# Round 2: cross-critiques
if [[ ! -f "$CLAUDE_CRITIQUE_FILE" ]]; then
  echo "Running Claude critique round..."
  run_with_timeout "$TIMEOUT_SECONDS" claude -p --output-format text --model "$CLAUDE_MODEL" < "$CLAUDE_CRITIQUE_PROMPT" > "$CLAUDE_CRITIQUE_FILE"
else
  echo "Skipping Claude critique round (already complete)."
fi

if [[ ! -f "$CODEX_CRITIQUE_FILE" ]]; then
  echo "Running Codex critique round..."
  if ! codex_exec "$CODEX_MODEL" "$WORK_ROOT" "$CODEX_CRITIQUE_FILE" < "$CODEX_CRITIQUE_PROMPT" >/dev/null 2>>"$CODEX_CLI_LOG"; then
    echo "Error: Codex critique round failed. See $CODEX_CLI_LOG" >&2
    exit 1
  fi
else
  echo "Skipping Codex critique round (already complete)."
fi

if [[ ! -f "$SYNTHESIS_PROMPT" ]]; then
  {
    printf 'R3:synthesize\nRULES no-tools|evidence-backed\n\nCTX\n%s\n\nR1-CLAUDE\n%s\n\nR1-CODEX\n%s\n\nCRIT-CLAUDE\n%s\n\nCRIT-CODEX\n%s\n\nOUT final-approach|adopted-claude|adopted-codex|open-disagreements|verify-checklist|rollback|confidence+unknowns\nHUMAN-TL-DR prepend "## TL;DR" (3-5 plain sentences) before structured output\n' \
      "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "$CLAUDE_ROUND1_FILE")" "$(cat "$CODEX_ROUND1_FILE")" \
      "$(cat "$CLAUDE_CRITIQUE_FILE")" "$(cat "$CODEX_CRITIQUE_FILE")"
  } > "$SYNTHESIS_PROMPT"
fi

# Round 3: synthesis
if [[ ! -f "$SYNTHESIS_FILE" ]]; then
  echo "Running Codex synthesis round..."
  if ! codex_exec "$CODEX_MODEL" "$WORK_ROOT" "$SYNTHESIS_FILE" < "$SYNTHESIS_PROMPT" >/dev/null 2>>"$CODEX_CLI_LOG"; then
    echo "Error: Codex synthesis round failed. See $CODEX_CLI_LOG" >&2
    exit 1
  fi
else
  echo "Skipping synthesis round (already complete)."
fi

cat > "$INDEX_FILE" <<EOF_INDEX
# IA Bridge Session Index

- Shared context: 00-shared-context.md
- Shared round-1 prompt: 01-round1-shared-prompt.txt
- Claude round 1: 10-claude-round1.md
- Codex round 1: 20-codex-round1.md
- Claude critiques Codex: 30-claude-critiques-codex.md
- Codex critiques Claude: 40-codex-critiques-claude.md
- Final synthesis: 50-final-synthesis.md
- Codex CLI logs (if any): codex-cli.log
EOF_INDEX

echo "IA bridge session completed: $SESSION_DIR"
echo "Open: $SYNTHESIS_FILE"
