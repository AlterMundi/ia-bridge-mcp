#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../lib/adapters.sh"

usage() {
  cat <<'USAGE'
Usage:
  forum.sh --task "<task description>" [options]
  forum.sh --resume <session-dir> [--task <additional context>] [options]

Options:
  --task <text>             Required (new session). Shared task statement.
  --resume <session-dir>    Resume an interrupted session by directory path.
  --constraints <text>      Optional. Shared constraints for all AIs.
  --agent-a <agent-id>      Optional. First agent (default: from config forum.agent_a).
  --agent-b <agent-id>      Optional. Second agent (default: from config forum.agent_b).
  --synthesizer <agent-id>  Optional. Synthesis agent (default: from config forum.synthesizer).
  --model-override <id:model>  Optional. Repeatable. Override model for a specific agent.
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
AGENT_A=""
AGENT_B=""
SYNTHESIZER=""
LOG_DIR="${HOME}/.bridge-ai/sessions"
MAX_DIFF_LINES=300
TIMEOUT_SECONDS=240
RESUME_DIR=""

MODEL_OVERRIDES=()

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
    --agent-a)
      require_option_value "$1" "${2:-}"
      AGENT_A="$2"
      shift 2
      ;;
    --agent-b)
      require_option_value "$1" "${2:-}"
      AGENT_B="$2"
      shift 2
      ;;
    --synthesizer)
      require_option_value "$1" "${2:-}"
      SYNTHESIZER="$2"
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

AVAILABLE_AGENTS=$(bridge_agent_ids)

# Defaults from config
AGENT_A="${AGENT_A:-$(bridge_forum_default agent_a)}"
AGENT_B="${AGENT_B:-$(bridge_forum_default agent_b)}"
SYNTHESIZER="${SYNTHESIZER:-$(bridge_forum_default synthesizer)}"

for agent in "$AGENT_A" "$AGENT_B" "$SYNTHESIZER"; do
  if ! grep -qx "$agent" <<<"$AVAILABLE_AGENTS"; then
    echo "Error: agent '$agent' is not an enabled agent." >&2
    echo "Enabled agents: $(tr '\n' ' ' <<<"$AVAILABLE_AGENTS")" >&2
    exit 1
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

AGENT_A_NAME=$(bridge_agent_field "$AGENT_A" "name")
AGENT_B_NAME=$(bridge_agent_field "$AGENT_B" "name")
SYNTH_NAME=$(bridge_agent_field "$SYNTHESIZER" "name")

resolve_model() {
  local id="$1"
  for override in "${MODEL_OVERRIDES[@]}"; do
    if [[ "$override" == "$id:"* ]]; then
      echo "${override#*:}"
      return 0
    fi
  done
  echo ""
}

AGENT_A_MODEL=$(resolve_model "$AGENT_A")
AGENT_B_MODEL=$(resolve_model "$AGENT_B")
SYNTH_MODEL=$(resolve_model "$SYNTHESIZER")

if [[ -n "$RESUME_DIR" ]]; then
  SESSION_DIR="$RESUME_DIR"
  echo "Resuming session: $SESSION_DIR"
  if [[ -n "$TASK" ]]; then
    echo "Additional context appended to task."
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
A_ROUND1_FILE="$SESSION_DIR/10-agent-a-round1.md"
B_ROUND1_FILE="$SESSION_DIR/20-agent-b-round1.md"
A_CRITIQUE_PROMPT="$SESSION_DIR/31-agent-a-critique.prompt.txt"
B_CRITIQUE_PROMPT="$SESSION_DIR/32-agent-b-critique.prompt.txt"
A_CRITIQUE_FILE="$SESSION_DIR/30-agent-a-critique.md"
B_CRITIQUE_FILE="$SESSION_DIR/40-agent-b-critique.md"
SYNTHESIS_PROMPT="$SESSION_DIR/51-synthesis.prompt.txt"
SYNTHESIS_FILE="$SESSION_DIR/50-final-synthesis.md"
INDEX_FILE="$SESSION_DIR/INDEX.md"
A_LOG="$SESSION_DIR/agent-a.log"
B_LOG="$SESSION_DIR/agent-b.log"
SYNTH_LOG="$SESSION_DIR/synth.log"

# Legacy file compatibility mapping
map_legacy_files() {
  if [[ -f "$SESSION_DIR/10-claude-round1.md" && ! -f "$A_ROUND1_FILE" ]]; then
    cp "$SESSION_DIR/10-claude-round1.md" "$A_ROUND1_FILE"
  fi
  if [[ -f "$SESSION_DIR/20-codex-round1.md" && ! -f "$B_ROUND1_FILE" ]]; then
    cp "$SESSION_DIR/20-codex-round1.md" "$B_ROUND1_FILE"
  fi
  if [[ -f "$SESSION_DIR/30-claude-critiques-codex.md" && ! -f "$A_CRITIQUE_FILE" ]]; then
    cp "$SESSION_DIR/30-claude-critiques-codex.md" "$A_CRITIQUE_FILE"
  fi
  if [[ -f "$SESSION_DIR/40-codex-critiques-claude.md" && ! -f "$B_CRITIQUE_FILE" ]]; then
    cp "$SESSION_DIR/40-codex-critiques-claude.md" "$B_CRITIQUE_FILE"
  fi
  if [[ -f "$SESSION_DIR/50-final-synthesis.md" && ! -f "$SYNTHESIS_FILE" ]]; then
    cp "$SESSION_DIR/50-final-synthesis.md" "$SYNTHESIS_FILE"
  fi
}
map_legacy_files

write_frontmatter() {
  local file="$1"
  local agent_id="$2"
  local agent_name="$3"
  local model="$4"
  local round="$5"
  local fm_file="${file}.fm.tmp"
  {
    printf -- '---\n'
    printf 'agent-id: %s\n' "$agent_id"
    printf 'agent-name: %s\n' "$agent_name"
    printf 'model: %s\n' "${model:-default}"
    printf 'timestamp: %s\n' "$(date -Iseconds)"
    printf 'round: %s\n' "$round"
    printf -- '---\n\n'
    cat "$file"
  } > "$fm_file"
  mv "$fm_file" "$file"
}

# Only write shared context and round-1 prompt if not resuming
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
    printf -- '- Agent A: %s (%s) model=%s\n' "$AGENT_A" "$AGENT_A_NAME" "${AGENT_A_MODEL:-default}"
    printf -- '- Agent B: %s (%s) model=%s\n' "$AGENT_B" "$AGENT_B_NAME" "${AGENT_B_MODEL:-default}"
    printf -- '- Synthesizer: %s (%s) model=%s\n' "$SYNTHESIZER" "$SYNTH_NAME" "${SYNTH_MODEL:-default}"
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
if [[ ! -f "$A_ROUND1_FILE" ]]; then
  echo "Running $AGENT_A_NAME round 1..."
  run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$AGENT_A" "$ROUND1_PROMPT_FILE" "$A_ROUND1_FILE" "$WORK_ROOT" "$AGENT_A_MODEL"
  write_frontmatter "$A_ROUND1_FILE" "$AGENT_A" "$AGENT_A_NAME" "$AGENT_A_MODEL" "round-1"
else
  echo "Skipping $AGENT_A_NAME round 1 (already complete)."
fi

if [[ ! -f "$B_ROUND1_FILE" ]]; then
  echo "Running $AGENT_B_NAME round 1..."
  run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$AGENT_B" "$ROUND1_PROMPT_FILE" "$B_ROUND1_FILE" "$WORK_ROOT" "$AGENT_B_MODEL"
  write_frontmatter "$B_ROUND1_FILE" "$AGENT_B" "$AGENT_B_NAME" "$AGENT_B_MODEL" "round-1"
else
  echo "Skipping $AGENT_B_NAME round 1 (already complete)."
fi

if [[ ! -f "$A_CRITIQUE_PROMPT" ]]; then
  {
    printf 'R2:critique-peer SELF=%s PEER=%s\nRULES no-tools|ctx+proposals-only|flag-unsupported\n\nCTX\n%s\n\nSELF\n%s\n\nPEER\n%s\n\nOUT agree|disagree|peer-gaps(tests/risks)|adopt-from-peer|revised-rec\n' \
      "$AGENT_A" "$AGENT_B" "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "$A_ROUND1_FILE")" "$(cat "$B_ROUND1_FILE")"
  } > "$A_CRITIQUE_PROMPT"
fi

if [[ ! -f "$B_CRITIQUE_PROMPT" ]]; then
  {
    printf 'R2:critique-peer SELF=%s PEER=%s\nRULES no-tools|ctx+proposals-only|flag-unsupported\n\nCTX\n%s\n\nSELF\n%s\n\nPEER\n%s\n\nOUT agree|disagree|peer-gaps(tests/risks)|adopt-from-peer|revised-rec\n' \
      "$AGENT_B" "$AGENT_A" "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "$B_ROUND1_FILE")" "$(cat "$A_ROUND1_FILE")"
  } > "$B_CRITIQUE_PROMPT"
fi

# Round 2: cross-critiques
if [[ ! -f "$A_CRITIQUE_FILE" ]]; then
  echo "Running $AGENT_A_NAME critique round..."
  run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$AGENT_A" "$A_CRITIQUE_PROMPT" "$A_CRITIQUE_FILE" "$WORK_ROOT" "$AGENT_A_MODEL"
  write_frontmatter "$A_CRITIQUE_FILE" "$AGENT_A" "$AGENT_A_NAME" "$AGENT_A_MODEL" "critique"
else
  echo "Skipping $AGENT_A_NAME critique round (already complete)."
fi

if [[ ! -f "$B_CRITIQUE_FILE" ]]; then
  echo "Running $AGENT_B_NAME critique round..."
  run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$AGENT_B" "$B_CRITIQUE_PROMPT" "$B_CRITIQUE_FILE" "$WORK_ROOT" "$AGENT_B_MODEL"
  write_frontmatter "$B_CRITIQUE_FILE" "$AGENT_B" "$AGENT_B_NAME" "$AGENT_B_MODEL" "critique"
else
  echo "Skipping $AGENT_B_NAME critique round (already complete)."
fi

if [[ ! -f "$SYNTHESIS_PROMPT" ]]; then
  {
    printf 'R3:synthesize\nRULES no-tools|evidence-backed\n\nCTX\n%s\n\nR1-%s\n%s\n\nR1-%s\n%s\n\nCRIT-%s\n%s\n\nCRIT-%s\n%s\n\nOUT final-approach|adopted-%s|adopted-%s|open-disagreements|verify-checklist|rollback|confidence+unknowns\nHUMAN-TL-DR prepend "## TL;DR" (3-5 plain sentences) before structured output\n' \
      "$(cat "$SHARED_CONTEXT_FILE")" "$AGENT_A" "$(cat "$A_ROUND1_FILE")" "$AGENT_B" "$(cat "$B_ROUND1_FILE")" \
      "$AGENT_A" "$(cat "$A_CRITIQUE_FILE")" "$AGENT_B" "$(cat "$B_CRITIQUE_FILE")" "$AGENT_A" "$AGENT_B"
  } > "$SYNTHESIS_PROMPT"
fi

# Round 3: synthesis
if [[ ! -f "$SYNTHESIS_FILE" ]]; then
  echo "Running $SYNTH_NAME synthesis round..."
  run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$SYNTHESIZER" "$SYNTHESIS_PROMPT" "$SYNTHESIS_FILE" "$WORK_ROOT" "$SYNTH_MODEL"
  write_frontmatter "$SYNTHESIS_FILE" "$SYNTHESIZER" "$SYNTH_NAME" "$SYNTH_MODEL" "synthesis"
else
  echo "Skipping synthesis round (already complete)."
fi

cat > "$INDEX_FILE" <<EOF_INDEX
# IA Bridge Session Index

- Shared context: 00-shared-context.md
- Shared round-1 prompt: 01-round1-shared-prompt.txt
- ${AGENT_A_NAME} round 1: 10-agent-a-round1.md
- ${AGENT_B_NAME} round 1: 20-agent-b-round1.md
- ${AGENT_A_NAME} critiques ${AGENT_B_NAME}: 30-agent-a-critique.md
- ${AGENT_B_NAME} critiques ${AGENT_A_NAME}: 40-agent-b-critique.md
- Final synthesis: 50-final-synthesis.md
- Agent logs (if any): agent-a.log, agent-b.log, synth.log
EOF_INDEX

echo "IA bridge session completed: $SESSION_DIR"
echo "Open: $SYNTHESIS_FILE"
