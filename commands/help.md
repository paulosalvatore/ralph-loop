---
description: "Explain Ralph Loop plugin and available commands"
---

# Ralph Loop Plugin Help

Please explain the following to the user:

## What is Ralph Loop?

Ralph Loop implements the Ralph Wiggum technique - an iterative development methodology based on continuous AI loops, pioneered by Geoffrey Huntley.

**Core concept:** The same prompt is fed to Claude repeatedly. The "self-referential" aspect comes from Claude seeing its own previous work in the files and git history, not from feeding output back as input.

**Each iteration:**
1. Claude receives the SAME prompt
2. Works on the task, modifying files
3. Tries to exit
4. Stop hook intercepts and feeds the same prompt again
5. Claude sees its previous work in the files
6. Iteratively improves until completion

## Per-Session Isolation (v2.0)

This version uses **per-session state files**. Each Claude Code session gets its own state file with the session ID embedded in the filename:
- State: `.claude/ralph-loop-<SESSION_ID>.local.md`
- Pointer: `.claude/ralph-loop-ptr-<SESSION_ID>.local` (only when using `--state-dir`)

This means multiple ralph-loops can run simultaneously in different terminals without interfering with each other.

## Available Commands

### /ralph-loop <PROMPT> [OPTIONS]

Start a Ralph loop in your current session.

**Usage:**
```
/ralph-loop "Refactor the cache layer" --max-iterations 20
/ralph-loop "Add tests" --completion-promise "TESTS COMPLETE"
/ralph-loop "Build feature" --state-dir /path/to/worktree --max-iterations 50
```

**Options:**
- `--max-iterations <n>` - Max iterations before auto-stop
- `--completion-promise <text>` - Promise phrase to signal completion
- `--state-dir <path>` - Directory for state file (for worktree isolation)

### /cancel-ralph

Cancel active Ralph loop(s) (removes loop state files).

## Completion Promises

To signal completion, Claude must output a `<promise>` tag:

```
<promise>TASK COMPLETE</promise>
```

The stop hook looks for this specific tag. Without it (or `--max-iterations`), Ralph runs infinitely.

## When to Use Ralph

**Good for:**
- Well-defined tasks with clear success criteria
- Tasks requiring iteration and refinement
- Iterative development with self-correction

**Not good for:**
- Tasks requiring human judgment or design decisions
- One-shot operations
- Tasks with unclear success criteria
