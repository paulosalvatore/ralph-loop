---
description: "Cancel active Ralph Loop"
allowed-tools: ["Bash(ls .claude/ralph-loop-*.local.md:*)", "Bash(rm .claude/ralph-loop-*.local*)", "Bash(cat .claude/ralph-loop-ptr-*.local)", "Bash(rm -f:*)", "Read(.claude/*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Ralph

To cancel all active Ralph loops for this project:

1. List session-scoped state files using Bash: `ls .claude/ralph-loop-*.local.md 2>/dev/null`

2. **If no files found**: Say "No active Ralph loop found."

3. **If files exist**:
   - For each state file, read the `iteration:` and `session_id:` fields from the frontmatter
   - Also check for pointer files: `ls .claude/ralph-loop-ptr-*.local 2>/dev/null`
   - If pointer files exist, read each to find remote state files and remove those too
   - Remove all state files and pointer files: `rm -f .claude/ralph-loop-*.local.md .claude/ralph-loop-ptr-*.local`
   - Also remove any legacy shared files: `rm -f .claude/ralph-loop.local.md .claude/ralph-loop-ptr.local`
   - Report: "Cancelled N Ralph loop(s)" with session IDs and iteration counts

4. **Legacy cleanup**: Also check for old-format files:
   - `test -f .claude/ralph-loop.local.md && rm .claude/ralph-loop.local.md && echo "Removed legacy state file"`
   - `test -f .claude/ralph-loop-ptr.local && rm .claude/ralph-loop-ptr.local && echo "Removed legacy pointer file"`
