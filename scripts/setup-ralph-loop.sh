#!/bin/bash

# Ralph Loop Setup Script
# Creates session-scoped state file for in-session Ralph loop
# State files use session ID in the filename to prevent cross-session interference

set -euo pipefail

# Parse arguments
PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE="null"
STATE_DIR=""

# Parse options and positional arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Ralph Loop - Interactive self-referential development loop

USAGE:
  /ralph-loop [PROMPT...] [OPTIONS]

ARGUMENTS:
  PROMPT...    Initial prompt to start the loop (can be multiple words without quotes)

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: unlimited)
  --completion-promise '<text>'  Promise phrase (USE QUOTES for multi-word)
  --state-dir <path>             Directory for state file (default: current directory)
  -h, --help                     Show this help message

DESCRIPTION:
  Starts a Ralph Loop in your CURRENT session. The stop hook prevents
  exit and feeds your output back as input until completion or iteration limit.

  To signal completion, you must output: <promise>YOUR_PHRASE</promise>

  Use this for:
  - Interactive iteration where you want to see progress
  - Tasks requiring self-correction and refinement
  - Learning how Ralph works

EXAMPLES:
  /ralph-loop Build a todo API --completion-promise 'DONE' --max-iterations 20
  /ralph-loop --max-iterations 10 Fix the auth bug
  /ralph-loop Refactor cache layer  (runs forever)
  /ralph-loop --completion-promise 'TASK COMPLETE' Create a REST API
  /ralph-loop --state-dir /path/to/worktree Build feature X

STOPPING:
  Only by reaching --max-iterations or detecting --completion-promise
  No manual stop - Ralph runs infinitely by default!

MONITORING:
  # View current iteration:
  grep '^iteration:' .claude/ralph-loop-*.local.md

  # View full state:
  head -10 .claude/ralph-loop-*.local.md
HELP_EOF
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-iterations requires a number argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --max-iterations 10" >&2
        echo "     --max-iterations 50" >&2
        echo "     --max-iterations 0  (unlimited)" >&2
        echo "" >&2
        echo "   You provided: --max-iterations (with no number)" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations must be a positive integer or 0, got: $2" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --max-iterations 10" >&2
        echo "     --max-iterations 50" >&2
        echo "     --max-iterations 0  (unlimited)" >&2
        echo "" >&2
        echo "   Invalid: decimals (10.5), negative numbers (-5), text" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --completion-promise 'DONE'" >&2
        echo "     --completion-promise 'TASK COMPLETE'" >&2
        echo "     --completion-promise 'All tests passing'" >&2
        echo "" >&2
        echo "   You provided: --completion-promise (with no text)" >&2
        echo "" >&2
        echo "   Note: Multi-word promises must be quoted!" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --state-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --state-dir requires a directory path argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --state-dir /path/to/worktree" >&2
        echo "     --state-dir ../my-worktree" >&2
        echo "" >&2
        echo "   You provided: --state-dir (with no path)" >&2
        exit 1
      fi
      STATE_DIR="$2"
      shift 2
      ;;
    *)
      # Non-option argument - collect all as prompt parts
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

# Join all prompt parts with spaces
PROMPT="${PROMPT_PARTS[*]:-}"

# Validate prompt is non-empty
if [[ -z "$PROMPT" ]]; then
  echo "Error: No prompt provided" >&2
  echo "" >&2
  echo "   Ralph needs a task description to work on." >&2
  echo "" >&2
  echo "   Examples:" >&2
  echo "     /ralph-loop Build a REST API for todos" >&2
  echo "     /ralph-loop Fix the auth bug --max-iterations 20" >&2
  echo "     /ralph-loop --completion-promise 'DONE' Refactor code" >&2
  echo "" >&2
  echo "   For all options: /ralph-loop --help" >&2
  exit 1
fi

# Get session ID - critical for per-session isolation.
# CLAUDE_CODE_SESSION_ID is supposed to be set by Claude Code automatically,
# but is unreliable in many installs and not propagated into sub-agent shells
# (see https://github.com/anthropics/claude-code/issues/39530).
#
# Fallback: derive the session ID from the active transcript file. Claude Code
# writes the current session's transcript continuously to:
#   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
# The most-recently-modified .jsonl across all projects is the active session.
# The stop-hook receives the same ID via its stdin JSON, so they match.
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
  if [[ -d "$CLAUDE_PROJECTS_DIR" ]]; then
    LATEST_JSONL=$(ls -t "${CLAUDE_PROJECTS_DIR}"/*/*.jsonl 2>/dev/null | head -1)
    if [[ -n "$LATEST_JSONL" ]]; then
      SESSION_ID=$(basename "$LATEST_JSONL" .jsonl)
    fi
  fi
fi
if [[ -z "$SESSION_ID" ]]; then
  echo "Error: CLAUDE_CODE_SESSION_ID is not set and no active transcript found." >&2
  echo "   Session isolation requires either the env var or a transcript under ~/.claude/projects." >&2
  echo "   See https://github.com/anthropics/claude-code/issues/39530" >&2
  exit 1
fi

# Determine state file path using session-scoped filename
# Pattern: ralph-loop-<SESSION_ID>.local.md
STATE_FILENAME="ralph-loop-${SESSION_ID}.local.md"

if [[ -n "$STATE_DIR" ]]; then
  # State file goes in the specified directory
  STATE_FILE_DIR="${STATE_DIR}/.claude"
  STATE_FILE="${STATE_FILE_DIR}/${STATE_FILENAME}"
else
  # Default: state file in current directory
  STATE_FILE_DIR=".claude"
  STATE_FILE="${STATE_FILE_DIR}/${STATE_FILENAME}"
fi

# Create state file directory
mkdir -p "$STATE_FILE_DIR"

# Quote completion promise for YAML if it contains special chars or is not null
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""
else
  COMPLETION_PROMISE_YAML="null"
fi

cat > "$STATE_FILE" <<EOF
---
active: true
iteration: 1
session_id: ${SESSION_ID}
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

# If using a non-default state dir, write a session-scoped pointer file in the
# cwd so the stop hook (which runs from cwd) can find the actual state file.
# Pointer is also session-scoped to prevent cross-session clobbering.
if [[ -n "$STATE_DIR" ]]; then
  mkdir -p .claude
  echo "$STATE_FILE" > ".claude/ralph-loop-ptr-${SESSION_ID}.local"
fi

# Clean up any legacy shared state/pointer files from the old plugin version
# to prevent the old stop-hook logic from interfering.
rm -f .claude/ralph-loop.local.md
rm -f .claude/ralph-loop-ptr.local

# Output setup message
cat <<EOF
Ralph loop activated in this session!

Session ID: ${SESSION_ID}
Iteration: 1
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo "unlimited"; fi)
Completion promise: $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "${COMPLETION_PROMISE//\"/} (ONLY output when TRUE - do not lie!)"; else echo "none (runs forever)"; fi)
State file: $STATE_FILE

The stop hook is now active. When you try to exit, the SAME PROMPT will be
fed back to you. You'll see your previous work in files, creating a
self-referential loop where you iteratively improve on the same task.

To monitor: head -10 $STATE_FILE

WARNING: This loop cannot be stopped manually! It will run infinitely
    unless you set --max-iterations or --completion-promise.
EOF

# Output the initial prompt if provided
if [[ -n "$PROMPT" ]]; then
  echo ""
  echo "$PROMPT"
fi

# Display completion promise requirements if set
if [[ "$COMPLETION_PROMISE" != "null" ]]; then
  echo ""
  echo "==========================================================="
  echo "CRITICAL - Ralph Loop Completion Promise"
  echo "==========================================================="
  echo ""
  echo "To complete this loop, output this EXACT text:"
  echo "  <promise>$COMPLETION_PROMISE</promise>"
  echo ""
  echo "STRICT REQUIREMENTS (DO NOT VIOLATE):"
  echo "  - Use <promise> XML tags EXACTLY as shown above"
  echo "  - The statement MUST be completely and unequivocally TRUE"
  echo "  - Do NOT output false statements to exit the loop"
  echo "  - Do NOT lie even if you think you should exit"
  echo ""
  echo "IMPORTANT - Do not circumvent the loop:"
  echo "  Even if you believe you're stuck, the task is impossible,"
  echo "  or you've been running too long - you MUST NOT output a"
  echo "  false promise statement. The loop is designed to continue"
  echo "  until the promise is GENUINELY TRUE. Trust the process."
  echo ""
  echo "  If the loop should stop, the promise statement will become"
  echo "  true naturally. Do not force it by lying."
  echo "==========================================================="
fi
