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
  --agents <id1,id2,...>    Optional. Comma-separated list of agents (default: from config forum.agents or forum.agent_a,forum.agent_b).
  --agent-a <agent-id>      Optional. First agent (legacy, default: from config forum.agent_a).
  --agent-b <agent-id>      Optional. Second agent (legacy, default: from config forum.agent_b).
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
AGENTS_STR=""
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
    --agents)
      require_option_value "$1" "${2:-}"
      AGENTS_STR="$2"
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

# Build AGENTS array
AGENTS=()

if [[ -n "$AGENTS_STR" ]]; then
  IFS=',' read -ra AGENTS <<< "$AGENTS_STR"
else
  # Fallback to legacy agent-a / agent-b or config defaults
  local_agent_a="${AGENT_A:-$(bridge_forum_default agent_a)}"
  local_agent_b="${AGENT_B:-$(bridge_forum_default agent_b)}"
  AGENTS+=("$local_agent_a")
  AGENTS+=("$local_agent_b")
fi

SYNTHESIZER="${SYNTHESIZER:-$(bridge_forum_default synthesizer)}"

# Validate all agents are enabled
for agent in "${AGENTS[@]}" "$SYNTHESIZER"; do
  if ! grep -qx "$agent" <<<"$AVAILABLE_AGENTS"; then
    echo "Error: agent '$agent' is not an enabled agent." >&2
    echo "Enabled agents: $(tr '\n' ' ' <<<"$AVAILABLE_AGENTS")" >&2
    exit 1
  fi
done

NUM_AGENTS=${#AGENTS[@]}

if [[ "$NUM_AGENTS" -lt 2 ]]; then
  echo "Error: Forum requires at least 2 agents. Got: ${AGENTS[*]}" >&2
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

# Agent metadata arrays
AGENT_NAMES=()
AGENT_MODELS=()

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

for agent in "${AGENTS[@]}"; do
  AGENT_NAMES+=("$(bridge_agent_field "$agent" "name")")
  AGENT_MODELS+=("$(resolve_model "$agent")")
done

SYNTH_NAME=$(bridge_agent_field "$SYNTHESIZER" "name")
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
INDEX_FILE="$SESSION_DIR/INDEX.md"

# Build file arrays
ROUND1_FILES=()
CRITIQUE_PROMPTS=()
CRITIQUE_FILES=()
AGENT_LOGS=()

for i in "${!AGENTS[@]}"; do
  idx=$((i + 1))
  ROUND1_FILES+=("$SESSION_DIR/$(printf "%02d-agent-%d-round1.md" "$idx" "$i")")
  CRITIQUE_PROMPTS+=("$SESSION_DIR/$(printf "%02d-agent-%d-critique.prompt.txt" "$idx" "$i")")
  CRITIQUE_FILES+=("$SESSION_DIR/$(printf "%02d-agent-%d-critique.md" "$idx" "$i")")
  AGENT_LOGS+=("$SESSION_DIR/agent-$i.log")
done

SYNTHESIS_PROMPT="$SESSION_DIR/99-synthesis.prompt.txt"
SYNTHESIS_FILE="$SESSION_DIR/98-final-synthesis.md"
SYNTH_LOG="$SESSION_DIR/synth.log"

# Legacy file compatibility mapping (only for 2-agent sessions)
map_legacy_files() {
  if [[ "$NUM_AGENTS" -eq 2 ]]; then
    if [[ -f "$SESSION_DIR/10-claude-round1.md" && ! -f "${ROUND1_FILES[0]}" ]]; then
      cp "$SESSION_DIR/10-claude-round1.md" "${ROUND1_FILES[0]}"
    fi
    if [[ -f "$SESSION_DIR/20-codex-round1.md" && ! -f "${ROUND1_FILES[1]}" ]]; then
      cp "$SESSION_DIR/20-codex-round1.md" "${ROUND1_FILES[1]}"
    fi
    if [[ -f "$SESSION_DIR/30-claude-critiques-codex.md" && ! -f "${CRITIQUE_FILES[0]}" ]]; then
      cp "$SESSION_DIR/30-claude-critiques-codex.md" "${CRITIQUE_FILES[0]}"
    fi
    if [[ -f "$SESSION_DIR/40-codex-critiques-claude.md" && ! -f "${CRITIQUE_FILES[1]}" ]]; then
      cp "$SESSION_DIR/40-codex-critiques-claude.md" "${CRITIQUE_FILES[1]}"
    fi
    if [[ -f "$SESSION_DIR/50-final-synthesis.md" && ! -f "$SYNTHESIS_FILE" ]]; then
      cp "$SESSION_DIR/50-final-synthesis.md" "$SYNTHESIS_FILE"
    fi
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
    printf -- '- Agents (%d):\n' "$NUM_AGENTS"
    for i in "${!AGENTS[@]}"; do
      printf -- '  - %s (%s) model=%s\n' "${AGENTS[$i]}" "${AGENT_NAMES[$i]}" "${AGENT_MODELS[$i]:-default}"
    done
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

# Round 1: independent proposals for all agents
for i in "${!AGENTS[@]}"; do
  agent="${AGENTS[$i]}"
  name="${AGENT_NAMES[$i]}"
  model="${AGENT_MODELS[$i]}"
  outfile="${ROUND1_FILES[$i]}"
  logfile="${AGENT_LOGS[$i]}"

  if [[ ! -f "$outfile" ]]; then
    echo "Running $name round 1..."
    run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$agent" "$ROUND1_PROMPT_FILE" "$outfile" "$WORK_ROOT" "$model" > "$logfile" 2>&1 || true
    write_frontmatter "$outfile" "$agent" "$name" "$model" "round-1"
  else
    echo "Skipping $name round 1 (already complete)."
  fi
done

# Round 2: cross-critiques only for exactly 2 agents (classic protocol)
# For N>2, we skip pairwise critiques and go straight to synthesis with all proposals.
# The value of N independent perspectives outweighs pairwise critique scaling issues.
if [[ "$NUM_AGENTS" -eq 2 ]]; then
  if [[ ! -f "${CRITIQUE_PROMPTS[0]}" ]]; then
    {
      printf 'R2:critique-peer SELF=%s PEER=%s\nRULES no-tools|ctx+proposals-only|flag-unsupported\n\nCTX\n%s\n\nSELF\n%s\n\nPEER\n%s\n\nOUT agree|disagree|peer-gaps(tests/risks)|adopt-from-peer|revised-rec\n' \
        "${AGENTS[0]}" "${AGENTS[1]}" "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "${ROUND1_FILES[0]}")" "$(cat "${ROUND1_FILES[1]}")"
    } > "${CRITIQUE_PROMPTS[0]}"
  fi

  if [[ ! -f "${CRITIQUE_PROMPTS[1]}" ]]; then
    {
      printf 'R2:critique-peer SELF=%s PEER=%s\nRULES no-tools|ctx+proposals-only|flag-unsupported\n\nCTX\n%s\n\nSELF\n%s\n\nPEER\n%s\n\nOUT agree|disagree|peer-gaps(tests/risks)|adopt-from-peer|revised-rec\n' \
        "${AGENTS[1]}" "${AGENTS[0]}" "$(cat "$SHARED_CONTEXT_FILE")" "$(cat "${ROUND1_FILES[1]}")" "$(cat "${ROUND1_FILES[0]}")"
    } > "${CRITIQUE_PROMPTS[1]}"
  fi

  for i in 0 1; do
    agent="${AGENTS[$i]}"
    name="${AGENT_NAMES[$i]}"
    model="${AGENT_MODELS[$i]}"
    prompt="${CRITIQUE_PROMPTS[$i]}"
    outfile="${CRITIQUE_FILES[$i]}"
    logfile="${AGENT_LOGS[$i]}"

    if [[ ! -f "$outfile" ]]; then
      echo "Running $name critique round..."
      run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$agent" "$prompt" "$outfile" "$WORK_ROOT" "$model" >> "$logfile" 2>&1 || true
      write_frontmatter "$outfile" "$agent" "$name" "$model" "critique"
    else
      echo "Skipping $name critique round (already complete)."
    fi
  done
fi

# Round 3: synthesis
if [[ ! -f "$SYNTHESIS_PROMPT" ]]; then
  {
    printf 'R3:synthesize\nRULES no-tools|evidence-backed\n\nCTX\n%s\n\n' "$(cat "$SHARED_CONTEXT_FILE")"

    for i in "${!AGENTS[@]}"; do
      printf 'R1-%s\n%s\n\n' "${AGENTS[$i]}" "$(cat "${ROUND1_FILES[$i]}")"
    done

    if [[ "$NUM_AGENTS" -eq 2 ]]; then
      for i in 0 1; do
        printf 'CRIT-%s\n%s\n\n' "${AGENTS[$i]}" "$(cat "${CRITIQUE_FILES[$i]}")"
      done
      printf 'OUT final-approach|adopted-%s|adopted-%s|open-disagreements|verify-checklist|rollback|confidence+unknowns\n' "${AGENTS[0]}" "${AGENTS[1]}"
    else
      printf 'OUT final-approach|adopted-recommendations|open-disagreements|verify-checklist|rollback|confidence+unknowns\n'
    fi

    printf 'HUMAN-TL-DR prepend "## TL;DR" (3-5 plain sentences) before structured output\n'
  } > "$SYNTHESIS_PROMPT"
fi

if [[ ! -f "$SYNTHESIS_FILE" ]]; then
  echo "Running $SYNTH_NAME synthesis round..."
  run_with_timeout "$TIMEOUT_SECONDS" bridge_run_agent "$SYNTHESIZER" "$SYNTHESIS_PROMPT" "$SYNTHESIS_FILE" "$WORK_ROOT" "$SYNTH_MODEL" > "$SYNTH_LOG" 2>&1 || true
  write_frontmatter "$SYNTHESIS_FILE" "$SYNTHESIZER" "$SYNTH_NAME" "$SYNTH_MODEL" "synthesis"
else
  echo "Skipping synthesis round (already complete)."
fi

# Build INDEX.md
cat > "$INDEX_FILE" <<EOF_INDEX
# IA Bridge Session Index

- Shared context: 00-shared-context.md
- Shared round-1 prompt: 01-round1-shared-prompt.txt
EOF_INDEX

for i in "${!AGENTS[@]}"; do
  printf '- %s round 1: %s\n' "${AGENT_NAMES[$i]}" "$(basename "${ROUND1_FILES[$i]}")" >> "$INDEX_FILE"
done

if [[ "$NUM_AGENTS" -eq 2 ]]; then
  for i in 0 1; do
    printf '- %s critiques %s: %s\n' "${AGENT_NAMES[$i]}" "${AGENT_NAMES[$((1-i))]}" "$(basename "${CRITIQUE_FILES[$i]}")" >> "$INDEX_FILE"
  done
fi

printf '- Final synthesis: %s\n' "$(basename "$SYNTHESIS_FILE")" >> "$INDEX_FILE"
printf '- Agent logs (if any): %s\n' "$(for f in "${AGENT_LOGS[@]}"; do basename "$f"; done | tr '\n' ' ')" >> "$INDEX_FILE"

echo "IA bridge session completed: $SESSION_DIR"
echo "Open: $SYNTHESIS_FILE"
