#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../lib/adapters.sh"

usage() {
  cat <<'USAGE'
Usage:
  second-opinion.sh --task "<task description>" [options]

Options:
  --task <text>             Required. Task statement.
  --reviewer <agent-id>     Optional. Agent id from config (default: first enabled agent).
  --constraints <text>      Optional. Shared constraints.
  --model <name>            Optional. Override the agent's default model.
  --model-override <id:model>  Optional. Repeatable. Override model for a specific agent.
  --log-dir <path>          Optional. Output root (default: ~/.bridge-ai/opinions).
  --max-diff-lines <n>      Optional. Max diff lines (default: 300).
  --timeout-seconds <n>     Optional. Per-call timeout (default: 240).
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
  # timeout(1) cannot run shell functions; detect and handle them directly
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
REVIEWER=""
MODEL=""
LOG_DIR="${HOME}/.bridge-ai/opinions"
MAX_DIFF_LINES=300
TIMEOUT_SECONDS=240

# Collect repeatable overrides
MODEL_OVERRIDES=()

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
    --model-override)
      require_option_value "$1" "${2:-}"
      MODEL_OVERRIDES+=("$2")
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

# Determine default reviewer if not provided
AVAILABLE_AGENTS=$(bridge_agent_ids)
if [[ -z "$REVIEWER" ]]; then
  REVIEWER=$(head -n1 <<<"$AVAILABLE_AGENTS")
fi

if ! grep -qx "$REVIEWER" <<<"$AVAILABLE_AGENTS"; then
  echo "Error: reviewer '$REVIEWER' is not an enabled agent." >&2
  echo "Enabled agents: $(tr '\n' ' ' <<<"$AVAILABLE_AGENTS")" >&2
  exit 1
fi

# Resolve model override for this reviewer
RESOLVED_MODEL="$MODEL"
for override in "${MODEL_OVERRIDES[@]}"; do
  if [[ "$override" == "$REVIEWER:"* ]]; then
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
AGENT_NAME=$(bridge_agent_field "$REVIEWER" "name")
OUTPUT_FILE="${LOG_DIR}/${STAMP}-${REPO_SLUG}-${REVIEWER}-second-opinion.md"
mkdir -p "$LOG_DIR"

PROMPT_FILE="${LOG_DIR}/.tmp-second-opinion-$$-${RANDOM}.txt"
trap 'rm -f "$PROMPT_FILE"' EXIT

{
  printf 'CTX root=%s mode=%s branch=%s commit=%s tree=%s\n' \
    "$WORK_ROOT" "$MODE" "$BRANCH" "$COMMIT" "$STATUS"
  printf 'TASK %s\n' "$TASK"
  printf 'CONSTRAINTS %s\n\n' "${CONSTRAINTS:-none}"
  printf 'COMMITS\n%s\n\n' "$RECENT_COMMITS"
  printf 'DIFF\n%s\n\n' "$DIFF_CONTENT"
  printf 'R1:single-opinion\nRULES no-tools|ctx-only|no-invented|assume-explicit|concise\n'
  printf 'OUT findings-by-severity|confidence+unknowns|rationale\n'
} > "$PROMPT_FILE"

run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$REVIEWER" "$PROMPT_FILE" "$OUTPUT_FILE" "$WORK_ROOT" "$RESOLVED_MODEL"

# Prepend frontmatter
FRONTMATTER_FILE="${LOG_DIR}/.tmp-fm-$$-${RANDOM}.md"
trap 'rm -f "$FRONTMATTER_FILE" "$PROMPT_FILE"' EXIT
{
  printf -- '---\n'
  printf 'agent-id: %s\n' "$REVIEWER"
  printf 'agent-name: %s\n' "$AGENT_NAME"
  printf 'model: %s\n' "${RESOLVED_MODEL:-default}"
  printf 'timestamp: %s\n' "$(date -Iseconds)"
  printf 'mode: %s\n' "$MODE"
  printf 'branch: %s\n' "$BRANCH"
  printf 'commit: %s\n' "$COMMIT"
  printf -- '---\n\n'
  cat "$OUTPUT_FILE"
} > "$FRONTMATTER_FILE"

mv "$FRONTMATTER_FILE" "$OUTPUT_FILE"

echo "Second opinion saved to: $OUTPUT_FILE"
