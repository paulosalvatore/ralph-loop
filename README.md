# ralph-loop (fixed)

Fork of the official [ralph-loop](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop) plugin for Claude Code with **per-session state isolation**.

## Problem

The official plugin uses a single shared state file (`.claude/ralph-loop.local.md`) for the entire project. This causes:

1. **Cross-session leaking** - The stop hook fires in every terminal session, even those that didn't start a loop
2. **Pointer file clobbering** - When using `--state-dir` for worktrees, concurrent loops overwrite each other's pointer
3. **State interference** - One session's stop hook can read/modify another session's state

Upstream issue: [anthropics/claude-code#26514](https://github.com/anthropics/claude-code/issues/26514) (closed as "not planned").

## Fix

This version embeds the **session ID in the filename**, not just inside the file:

| Before (shared) | After (per-session) |
|---|---|
| `.claude/ralph-loop.local.md` | `.claude/ralph-loop-<SESSION_ID>.local.md` |
| `.claude/ralph-loop-ptr.local` | `.claude/ralph-loop-ptr-<SESSION_ID>.local` |

Each session only looks for its own files. No shared state = no interference.

## Install

```bash
git clone git@github.com:paulosalvatore/ralph-loop.git ~/.claude/plugins/local/ralph-loop
cd ~/.claude/plugins/local/ralph-loop
./install.sh
```

Re-run `./install.sh` after any marketplace plugin update to re-apply the fix.

## Test

```bash
./tests/test-isolation.sh
```

Runs 10 isolation tests simulating concurrent sessions, completion promises, max iterations, and worktree pointer files.

## Usage

Same as the official plugin:

```bash
/ralph-loop "Build a REST API" --completion-promise "DONE" --max-iterations 20
/ralph-loop "Fix bug" --state-dir /path/to/worktree --max-iterations 50
/cancel-ralph
```

## Compatibility

- Requires `CLAUDE_CODE_SESSION_ID` environment variable (set automatically by Claude Code)
- `.gitignore` pattern `.claude/*.local*` covers all session-scoped files
- Cleans up legacy shared state files on new loop creation
