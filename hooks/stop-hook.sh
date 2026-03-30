#!/bin/bash

# Ralph Loop Stop Hook
# Prevents session exit when a ralph-loop is active for THIS session.
# Uses per-session state files (ralph-loop-<SESSION_ID>.local.md) to
# eliminate cross-session interference entirely.

set -euo pipefail

# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Extract this session's ID from the hook input - this is the key to isolation
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -z "$HOOK_SESSION" ]]; then
  # No session ID in hook input - can't locate session-scoped state file
  exit 0
fi

# Look for this session's state file.
# 1. Check for a session-scoped pointer file (used with --state-dir)
# 2. Fall back to session-scoped state file in .claude/
RALPH_PTR_FILE=".claude/ralph-loop-ptr-${HOOK_SESSION}.local"
RALPH_SESSION_STATE=".claude/ralph-loop-${HOOK_SESSION}.local.md"

if [[ -f "$RALPH_PTR_FILE" ]]; then
  RALPH_STATE_FILE=$(cat "$RALPH_PTR_FILE")
elif [[ -f "$RALPH_SESSION_STATE" ]]; then
  RALPH_STATE_FILE="$RALPH_SESSION_STATE"
else
  # No active loop for this session - allow exit
  exit 0
fi

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  # State file referenced by pointer doesn't exist - stale pointer, clean up
  rm -f "$RALPH_PTR_FILE"
  exit 0
fi

# Helper: clean up this session's state and pointer files
cleanup_state() {
  rm -f "$RALPH_STATE_FILE"
  rm -f "$RALPH_PTR_FILE"
}

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
# Extract completion_promise and strip surrounding quotes if present
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')

# Double-check session_id inside the state file matches (belt-and-suspenders).
# This catches edge cases like a manually created state file.
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Validate numeric fields before arithmetic operations
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "Ralph loop: State file corrupted (iteration='$ITERATION'). Stopping." >&2
  cleanup_state
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "Ralph loop: State file corrupted (max_iterations='$MAX_ITERATIONS'). Stopping." >&2
  cleanup_state
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
  cleanup_state
  exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "Ralph loop: Transcript file not found at $TRANSCRIPT_PATH. Stopping." >&2
  cleanup_state
  exit 0
fi

# Read last assistant message from transcript (JSONL format - one JSON per line)
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "Ralph loop: No assistant messages found in transcript. Stopping." >&2
  cleanup_state
  exit 0
fi

# Extract the most recent assistant text block.
# Capped at last 100 assistant lines to keep jq bounded for long sessions.
LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
if [[ -z "$LAST_LINES" ]]; then
  echo "Ralph loop: Failed to extract assistant messages. Stopping." >&2
  cleanup_state
  exit 0
fi

# Parse the recent lines and pull out the final text block.
set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>&1)
JQ_EXIT=$?
set -e

if [[ $JQ_EXIT -ne 0 ]]; then
  echo "Ralph loop: Failed to parse assistant message JSON. Stopping." >&2
  cleanup_state
  exit 0
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
    cleanup_state
    exit 0
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "Ralph loop: No prompt text found in state file. Stopping." >&2
  cleanup_state
  exit 0
fi

# Update iteration in frontmatter (portable across macOS and Linux)
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Build system message with iteration count and completion promise info
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="Ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when statement is TRUE - do not lie to exit!)"
else
  SYSTEM_MSG="Ralph iteration $NEXT_ITERATION | No completion promise set - loop runs infinitely"
fi

# Output JSON to block the stop and feed prompt back
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
