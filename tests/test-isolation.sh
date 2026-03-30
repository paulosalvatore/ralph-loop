#!/bin/bash

# Test script for ralph-loop per-session isolation
# Simulates multiple concurrent sessions and verifies no cross-session interference
#
# Usage: ./tests/test-isolation.sh
#
# This test does NOT require Claude Code to be running. It directly invokes
# the setup and stop-hook scripts with simulated session IDs and transcripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-ralph-loop.sh"
STOP_HOOK="$SCRIPT_DIR/hooks/stop-hook.sh"
TEST_DIR="/tmp/ralph-loop-test-$$"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/main-repo/.claude" "$TEST_DIR/worktree-1" "$TEST_DIR/worktree-2"
cd "$TEST_DIR/main-repo"

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

check_file_exists() {
  if [[ -f "$1" ]]; then pass "$2"; else fail "$2 (file not found: $1)"; fi
}

check_file_not_exists() {
  if [[ ! -f "$1" ]]; then pass "$2"; else fail "$2 (file unexpectedly exists: $1)"; fi
}

check_contains() {
  if grep -q "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3 (pattern '$1' not in $2)"; fi
}

make_transcript() {
  local path="$1" text="$2"
  echo "{\"role\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$text\"}]}}" > "$path"
}

echo "============================================"
echo "Ralph-Loop Per-Session Isolation Test Suite"
echo "============================================"
echo ""

# -----------------------------------------------
echo "TEST 1: Setup creates session-scoped state file"
# -----------------------------------------------
CLAUDE_CODE_SESSION_ID="sess-AAA" \
  "$SETUP_SCRIPT" "Build feature A" --max-iterations 10 --completion-promise "DONE" > /dev/null 2>&1

check_file_exists ".claude/ralph-loop-sess-AAA.local.md" "State file uses session ID in name"
check_contains "session_id: sess-AAA" ".claude/ralph-loop-sess-AAA.local.md" "State file contains correct session_id"
check_contains "max_iterations: 10" ".claude/ralph-loop-sess-AAA.local.md" "State file has correct max_iterations"
check_file_not_exists ".claude/ralph-loop.local.md" "No legacy shared state file"
check_file_not_exists ".claude/ralph-loop-ptr.local" "No legacy shared pointer file"
echo ""

# -----------------------------------------------
echo "TEST 2: Second session creates separate state file"
# -----------------------------------------------
CLAUDE_CODE_SESSION_ID="sess-BBB" \
  "$SETUP_SCRIPT" "Build feature B" --max-iterations 20 --completion-promise "ALL DONE" > /dev/null 2>&1

check_file_exists ".claude/ralph-loop-sess-BBB.local.md" "Session B has its own state file"
check_file_exists ".claude/ralph-loop-sess-AAA.local.md" "Session A state file still intact"
check_contains "session_id: sess-BBB" ".claude/ralph-loop-sess-BBB.local.md" "Session B has correct session_id"
check_contains "session_id: sess-AAA" ".claude/ralph-loop-sess-AAA.local.md" "Session A still has correct session_id"
echo ""

# -----------------------------------------------
echo "TEST 3: --state-dir creates session-scoped pointer and state"
# -----------------------------------------------
CLAUDE_CODE_SESSION_ID="sess-CCC" \
  "$SETUP_SCRIPT" "Build feature C" --max-iterations 5 --state-dir "$TEST_DIR/worktree-1" > /dev/null 2>&1

check_file_exists ".claude/ralph-loop-ptr-sess-CCC.local" "Pointer file is session-scoped"
check_file_exists "$TEST_DIR/worktree-1/.claude/ralph-loop-sess-CCC.local.md" "State file in worktree with session ID"
check_file_not_exists ".claude/ralph-loop-ptr.local" "No legacy shared pointer"

ACTUAL_PTR=$(cat ".claude/ralph-loop-ptr-sess-CCC.local")
EXPECTED_PTR="$TEST_DIR/worktree-1/.claude/ralph-loop-sess-CCC.local.md"
if [[ "$ACTUAL_PTR" == "$EXPECTED_PTR" ]]; then
  pass "Pointer file points to correct state file"
else
  fail "Pointer file points to wrong location (got: $ACTUAL_PTR, expected: $EXPECTED_PTR)"
fi
echo ""

# -----------------------------------------------
echo "TEST 4: Two --state-dir sessions don't clobber each other"
# -----------------------------------------------
CLAUDE_CODE_SESSION_ID="sess-DDD" \
  "$SETUP_SCRIPT" "Build feature D" --max-iterations 5 --state-dir "$TEST_DIR/worktree-2" > /dev/null 2>&1

check_file_exists ".claude/ralph-loop-ptr-sess-CCC.local" "Session C pointer still intact"
check_file_exists ".claude/ralph-loop-ptr-sess-DDD.local" "Session D has its own pointer"
check_file_exists "$TEST_DIR/worktree-1/.claude/ralph-loop-sess-CCC.local.md" "Session C state still in worktree-1"
check_file_exists "$TEST_DIR/worktree-2/.claude/ralph-loop-sess-DDD.local.md" "Session D state in worktree-2"
echo ""

# -----------------------------------------------
echo "TEST 5: Stop hook only affects its own session"
# -----------------------------------------------
make_transcript "$TEST_DIR/transcript-A.jsonl" "Working on feature A..."

# Session A hook should block (loop continues)
RESULT_A=$(echo "{\"session_id\":\"sess-AAA\",\"transcript_path\":\"$TEST_DIR/transcript-A.jsonl\"}" | "$STOP_HOOK" 2>/dev/null || true)
if echo "$RESULT_A" | python3 -c "import sys,json; d=json.loads(sys.stdin.buffer.read()); assert d['decision']=='block'" 2>/dev/null; then
  pass "Session A hook blocks exit (loop continues)"
else
  fail "Session A hook did not block exit"
fi

# Check iteration incremented for A only
check_contains "iteration: 2" ".claude/ralph-loop-sess-AAA.local.md" "Session A iteration incremented to 2"
check_contains "iteration: 1" ".claude/ralph-loop-sess-BBB.local.md" "Session B iteration unchanged at 1"
echo ""

# -----------------------------------------------
echo "TEST 6: Unknown session exits cleanly (no interference)"
# -----------------------------------------------
RESULT_X=$(echo "{\"session_id\":\"sess-UNKNOWN\",\"transcript_path\":\"$TEST_DIR/transcript-A.jsonl\"}" | "$STOP_HOOK" 2>/dev/null || true)
if [[ -z "$RESULT_X" ]]; then
  pass "Unknown session exits cleanly (empty output)"
else
  fail "Unknown session produced output: $RESULT_X"
fi
echo ""

# -----------------------------------------------
echo "TEST 7: Completion promise cleans up only its own session"
# -----------------------------------------------
make_transcript "$TEST_DIR/transcript-B-done.jsonl" "All work complete. <promise>ALL DONE</promise>"

RESULT_B=$(echo "{\"session_id\":\"sess-BBB\",\"transcript_path\":\"$TEST_DIR/transcript-B-done.jsonl\"}" | "$STOP_HOOK" 2>/dev/null || true)
check_file_not_exists ".claude/ralph-loop-sess-BBB.local.md" "Session B state cleaned up after promise"
check_file_exists ".claude/ralph-loop-sess-AAA.local.md" "Session A state still exists"
check_file_exists ".claude/ralph-loop-ptr-sess-CCC.local" "Session C pointer still exists"
echo ""

# -----------------------------------------------
echo "TEST 8: Stop hook with --state-dir finds state via pointer"
# -----------------------------------------------
make_transcript "$TEST_DIR/transcript-C.jsonl" "Working on feature C..."

RESULT_C=$(echo "{\"session_id\":\"sess-CCC\",\"transcript_path\":\"$TEST_DIR/transcript-C.jsonl\"}" | "$STOP_HOOK" 2>/dev/null || true)
if echo "$RESULT_C" | python3 -c "import sys,json; d=json.loads(sys.stdin.buffer.read()); assert d['decision']=='block'" 2>/dev/null; then
  pass "Session C hook blocks via pointer file"
else
  fail "Session C hook did not block (pointer lookup failed)"
fi
check_contains "iteration: 2" "$TEST_DIR/worktree-1/.claude/ralph-loop-sess-CCC.local.md" "Session C iteration incremented in worktree"
echo ""

# -----------------------------------------------
echo "TEST 9: Max iterations stops the loop"
# -----------------------------------------------
# Session C has max_iterations=5, currently at iteration 3 (after test 8).
# Need to run until iteration reaches 5: calls for iter 3->4, 4->5, then 5>=5 triggers stop.
for i in $(seq 3 10); do
  # Stop early if state file is already cleaned up
  if [[ ! -f "$TEST_DIR/worktree-1/.claude/ralph-loop-sess-CCC.local.md" ]]; then
    break
  fi
  make_transcript "$TEST_DIR/transcript-C-$i.jsonl" "Still working... iteration $i"
  echo "{\"session_id\":\"sess-CCC\",\"transcript_path\":\"$TEST_DIR/transcript-C-$i.jsonl\"}" | "$STOP_HOOK" > /dev/null 2>&1 || true
done

check_file_not_exists "$TEST_DIR/worktree-1/.claude/ralph-loop-sess-CCC.local.md" "Session C state removed after max iterations"
check_file_not_exists ".claude/ralph-loop-ptr-sess-CCC.local" "Session C pointer removed after max iterations"
echo ""

# -----------------------------------------------
echo "TEST 10: Missing session_id in hook input exits cleanly"
# -----------------------------------------------
RESULT_NOSESS=$(echo '{"transcript_path":"/tmp/fake"}' | "$STOP_HOOK" 2>/dev/null || true)
if [[ -z "$RESULT_NOSESS" ]]; then
  pass "Hook with no session_id exits cleanly"
else
  fail "Hook with no session_id produced output"
fi
echo ""

# -----------------------------------------------
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
