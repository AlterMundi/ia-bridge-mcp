#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../lib/adapters.sh"

usage() {
  cat <<'USAGE'
Usage:
  build.sh --task "<task description>" [options]

Options:
  --task <text>             Required. Task statement.
  --agent <agent-id>        Optional. Agent id from config (default: 'grok' if enabled).
  --constraints <text>      Optional. Shared constraints.
  --model <name>            Optional. Override the agent's default model.
  --model-override <id:model> Optional. Repeatable. Override model for a specific agent.
  --with-review             Optional. After build, run a second-opinion review.
  --log-dir <path>          Optional. Output root (default: ~/.bridge-ai/builds).
  --max-diff-lines <n>      Optional. Max diff lines (default: 300).
  --timeout-seconds <n>     Optional. Per-call timeout (default: 600).
  --effort <level>          Optional. Override effort level (no default).
  --max-turns <n>           Optional. Override max turns (default: 80).
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
  if ! command -v timeout >/dev/null 2>&1; then
    "$@"
    return
  fi
  if type -t "$1" 2>/dev/null | grep -qx 'function'; then
    local func="$1"
    shift
    "$func" "$@" &
    local pid=$!
    ( sleep "$seconds"; kill "$pid" 2>/dev/null || true ) &
    local killer=$!
    wait "$pid" 2>/dev/null || true
    local rc=$?
    kill "$killer" 2>/dev/null || true
    return $rc
  fi
  timeout "$seconds" "$@"
}

TASK=""
CONSTRAINTS=""
AGENT=""
MODEL=""
WITH_REVIEW="false"
LOG_DIR="${HOME}/.bridge-ai/builds"
MAX_DIFF_LINES=300
TIMEOUT_SECONDS=600
EFFORT=""
MAX_TURNS="80"

MODEL_OVERRIDES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      require_option_value "$1" "${2:-}"
      TASK="$2"
      shift 2
      ;;
    --agent)
      require_option_value "$1" "${2:-}"
      AGENT="$2"
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
    --model-override)
      require_option_value "$1" "${2:-}"
      MODEL_OVERRIDES+=("$2")
      shift 2
      ;;
    --with-review)
      WITH_REVIEW="true"
      shift
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
    --effort)
      require_option_value "$1" "${2:-}"
      EFFORT="$2"
      shift 2
      ;;
    --max-turns)
      require_option_value "$1" "${2:-}"
      MAX_TURNS="$2"
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

if ! [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || [[ "$MAX_TURNS" -le 0 ]]; then
  echo "Error: --max-turns must be a positive integer." >&2
  exit 1
fi

AVAILABLE_AGENTS=$(bridge_agent_ids)

# Determine default agent
if [[ -z "$AGENT" ]]; then
  if grep -qx "grok" <<<"$AVAILABLE_AGENTS"; then
    AGENT="grok"
  else
    AGENT=$(head -n1 <<<"$AVAILABLE_AGENTS")
  fi
fi

if ! grep -qx "$AGENT" <<<"$AVAILABLE_AGENTS"; then
  echo "Error: agent '$AGENT' is not an enabled agent." >&2
  echo "Enabled agents: $(tr '\n' ' ' <<<"$AVAILABLE_AGENTS")" >&2
  exit 1
fi

# Resolve model override for this agent
RESOLVED_MODEL="$MODEL"
for override in "${MODEL_OVERRIDES[@]}"; do
  if [[ "$override" == "$AGENT:"* ]]; then
    RESOLVED_MODEL="${override#*:}"
  fi
done

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

STAMP="$(date +%Y%m%d-%H%M%S)"
REPO_SLUG="$(basename "$WORK_ROOT")"
AGENT_NAME=$(bridge_agent_field "$AGENT" "name")
OUTPUT_FILE="${LOG_DIR}/${STAMP}-${REPO_SLUG}-${AGENT}-build.md"
mkdir -p "$LOG_DIR"

PROMPT_FILE="${LOG_DIR}/.tmp-build-$$-${RANDOM}.txt"
trap 'rm -f "$PROMPT_FILE"' EXIT

# Build the implementation prompt
{
  printf 'You are %s, an autonomous build agent.\n\n' "$AGENT_NAME"
  printf '## BUILD TASK\n\n'
  printf '%s\n\n' "$TASK"
  if [[ -n "$CONSTRAINTS" ]]; then
    printf '## CONSTRAINTS\n\n'
    printf '%s\n\n' "$CONSTRAINTS"
  fi
  printf '## CONTEXT\n'
  printf 'Working directory: %s\n' "$WORK_ROOT"
  printf 'Branch: %s\n' "$BRANCH"
  printf 'Commit: %s\n' "$COMMIT"
  printf 'Tree: %s\n\n' "$STATUS"
  printf '## RECENT COMMITS\n\n'
  printf '%s\n\n' "$RECENT_COMMITS"
  printf '## CURRENT DIFF\n\n'
  printf '%s\n\n' "$DIFF_CONTENT"
  printf '## INSTRUCTIONS\n'
  printf '1. Implement the task autonomously using all available tools.\n'
  printf '2. Write code changes, tests, and documentation as needed.\n'
  printf '3. After implementation, provide a summary of what was done.\n'
  printf '4. List changed files and key design decisions.\n'
} > "$PROMPT_FILE"

echo "Building with $AGENT_NAME (agent: $AGENT, model: ${RESOLVED_MODEL:-default}, effort: $EFFORT, max-turns: $MAX_TURNS)..."

run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$AGENT" "$PROMPT_FILE" "$OUTPUT_FILE" "$WORK_ROOT" "$RESOLVED_MODEL"

# Prepend frontmatter
FRONTMATTER_FILE="${LOG_DIR}/.tmp-fm-$$-${RANDOM}.md"
trap 'rm -f "$FRONTMATTER_FILE" "$PROMPT_FILE"' EXIT
{
  printf -- '---\n'
  printf 'agent-id: %s\n' "$AGENT"
  printf 'agent-name: %s\n' "$AGENT_NAME"
  printf 'model: %s\n' "${RESOLVED_MODEL:-default}"
  printf 'effort: %s\n' "$EFFORT"
  printf 'max-turns: %s\n' "$MAX_TURNS"
  printf 'timestamp: %s\n' "$(date -Iseconds)"
  printf 'mode: %s\n' "$MODE"
  printf 'branch: %s\n' "$BRANCH"
  printf 'commit: %s\n' "$COMMIT"
  printf -- '---\n\n'
  cat "$OUTPUT_FILE"
} > "$FRONTMATTER_FILE"

mv "$FRONTMATTER_FILE" "$OUTPUT_FILE"

echo "Build result saved to: $OUTPUT_FILE"

# Optional review step: runs full forum protocol with claude + codex
if [[ "$WITH_REVIEW" == "true" ]]; then
  FORUM_SCRIPT="${BUILD_SCRIPT_DIR}/forum.sh"
  if [[ -x "$FORUM_SCRIPT" ]]; then
    echo ""
    echo "=== Running forum review (claude + codex) ==="
    REVIEW_TASK="Review the build implementation by $AGENT_NAME for task: $TASK. The build result is at: $OUTPUT_FILE. Review the changes and provide a GO/NO-GO synthesis with findings."
    "$FORUM_SCRIPT" \
      --task "$REVIEW_TASK" \
      --agent-a claude \
      --agent-b codex \
      --synthesizer codex \
      --log-dir "$LOG_DIR" \
      --timeout-seconds 900
    FORUM_RC=$?
    if [[ $FORUM_RC -eq 0 ]]; then
      echo "Forum review completed. Synthesis in: $LOG_DIR"
    else
      echo "Forum review failed with exit code $FORUM_RC" >&2
    fi
  else
    echo "Warning: --with-review specified but forum.sh not found at $FORUM_SCRIPT" >&2
  fi
fi
