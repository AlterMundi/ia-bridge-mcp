#!/usr/bin/env bash
set -euo pipefail

# Allow running from within a Claude Code session (avoid nested-session detection)
unset CLAUDECODE 2>/dev/null || true

usage() {
  cat <<'USAGE'
Usage:
  claude-second-opinion.sh --task "<task description>" [options]

Options:
  --task <text>             Required. One-line task statement.
  --reviewer <name>         Optional. `claude` or `codex` (default: claude).
  --constraints <text>      Optional. Constraints for Claude.
  --model <name>            Optional. Model alias (default: reviewer-specific).
  --log-dir <path>          Optional. Output directory (default: ~/.bridge-ai/opinions).
  --max-diff-lines <n>      Optional. Max diff lines in prompt (default: 300).
  --timeout-seconds <n>     Optional. Timeout in seconds (default: 180).
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

TASK=""
REVIEWER="claude"
CONSTRAINTS=""
MODEL=""
LOG_DIR="${HOME}/.bridge-ai/opinions"
MAX_DIFF_LINES=300
TIMEOUT_SECONDS=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      require_option_value "$1" "${2:-}"
      TASK="$2"
      shift 2
      ;;
    --reviewer)
      require_option_value "$1" "${2:-}"
      REVIEWER="$2"
      shift 2
      ;;
    --constraints)
      require_option_value "$1" "${2:-}"
      CONSTRAINTS="$2"
      shift 2
      ;;
    --model)
      require_option_value "$1" "${2:-}"
      MODEL="$2"
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

if [[ -z "$TASK" ]]; then
  echo "Error: --task is required." >&2
  usage
  exit 1
fi

if ! [[ "$MAX_DIFF_LINES" =~ ^[0-9]+$ ]] || [[ "$MAX_DIFF_LINES" -le 0 ]]; then
  echo "Error: --max-diff-lines must be a positive integer." >&2
  exit 1
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -le 0 ]]; then
  echo "Error: --timeout-seconds must be a positive integer." >&2
  exit 1
fi

if [[ "$REVIEWER" != "claude" && "$REVIEWER" != "codex" ]]; then
  echo "Error: --reviewer must be one of: claude, codex." >&2
  exit 1
fi

if [[ -z "$MODEL" ]]; then
  if [[ "$REVIEWER" == "claude" ]]; then
    MODEL="opus"
  else
    MODEL="gpt-5"
  fi
fi

if [[ "$REVIEWER" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found in PATH." >&2
    exit 1
  fi
else
  if ! command -v codex >/dev/null 2>&1; then
    echo "Error: codex CLI not found in PATH." >&2
    exit 1
  fi
fi


if [[ "$REVIEWER" == "claude" ]]; then
  RESPONSE_SECTION_TITLE="## Claude Response"
else
  RESPONSE_SECTION_TITLE="## Codex Response"
fi

if ! command -v date >/dev/null 2>&1; then
  echo "Error: date command not found in PATH." >&2
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
    RECENT_COMMITS="$(git --no-pager log --oneline -8)"
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

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPO_SLUG="$(basename "$WORK_ROOT")"
LOG_FILE="$LOG_DIR/${STAMP}-${REPO_SLUG}-${REVIEWER}-second-opinion.md"
CODEX_CLI_LOG="$LOG_DIR/${STAMP}-${REPO_SLUG}-codex-cli.log"
CODEX_LAST_MESSAGE_FILE="$LOG_DIR/${STAMP}-${REPO_SLUG}-codex-last-message.md"

PROMPT="CTX root=$WORK_ROOT mode=$MODE branch=$BRANCH commit=$COMMIT tree=$STATUS
TASK $TASK
CONSTRAINTS ${CONSTRAINTS:-none}
REVIEWER $REVIEWER

COMMITS
$RECENT_COMMITS

DIFF
$DIFF_CONTENT

R1:second-opinion
RULES no-tools|ctx-only|no-invented|assume-explicit
OUT findings-by-severity|plan-max-6|edits+paths|verify-commands|alternative+tradeoff|confidence+unknowns|rationale
HUMAN-TL-DR prepend \"## TL;DR\" (2-3 sentences) before structured output"

{
  echo "# Claude Second Opinion"
  echo
  echo "- Timestamp: $(date -Iseconds)"
  echo "- Working root: $WORK_ROOT"
  echo "- Mode (auto): $MODE"
  echo "- Branch: $BRANCH"
  echo "- Commit: $COMMIT"
  echo "- Worktree: $STATUS"
  echo "- Reviewer: $REVIEWER"
  echo "- Model: $MODEL"
  echo "- Task: $TASK"
  echo "- Constraints: ${CONSTRAINTS:-none}"
  echo "- Timeout seconds: $TIMEOUT_SECONDS"
  echo
  echo "## Prompt"
  echo
  echo '```text'
  echo "$PROMPT"
  echo '```'
  echo
  echo "$RESPONSE_SECTION_TITLE"
  echo
} > "$LOG_FILE"

set +e
if [[ "$REVIEWER" == "claude" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    CLAUDE_CMD=(timeout "$TIMEOUT_SECONDS" claude -p --output-format text --model "$MODEL")
  else
    CLAUDE_CMD=(claude -p --output-format text --model "$MODEL")
  fi
  echo "$PROMPT" | "${CLAUDE_CMD[@]}" >> "$LOG_FILE"
  REVIEWER_EXIT_CODE=$?
else
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" codex exec -m "$MODEL" -C "$WORK_ROOT" --output-last-message "$CODEX_LAST_MESSAGE_FILE" - < <(printf '%s\n' "$PROMPT") >/dev/null 2>>"$CODEX_CLI_LOG"
  else
    codex exec -m "$MODEL" -C "$WORK_ROOT" --output-last-message "$CODEX_LAST_MESSAGE_FILE" - < <(printf '%s\n' "$PROMPT") >/dev/null 2>>"$CODEX_CLI_LOG"
  fi
  REVIEWER_EXIT_CODE=$?
  if [[ "$REVIEWER_EXIT_CODE" -eq 0 ]] && [[ -f "$CODEX_LAST_MESSAGE_FILE" ]]; then
    cat "$CODEX_LAST_MESSAGE_FILE" >> "$LOG_FILE"
  fi
fi
set -e

if [[ "$REVIEWER_EXIT_CODE" -ne 0 ]]; then
  if [[ "$REVIEWER_EXIT_CODE" -eq 124 ]]; then
    echo "${REVIEWER^} call timed out after ${TIMEOUT_SECONDS}s. Partial log saved at: $LOG_FILE" >&2
  else
    echo "${REVIEWER^} call failed with exit code ${REVIEWER_EXIT_CODE}. Partial log saved at: $LOG_FILE" >&2
    if [[ "$REVIEWER" == "codex" ]]; then
      echo "Codex CLI log: $CODEX_CLI_LOG" >&2
    fi
  fi
  echo "_${REVIEWER^} call failed or timed out. See command stderr for details._" >> "$LOG_FILE"
  exit 1
fi

echo "Second opinion saved to: $LOG_FILE"
