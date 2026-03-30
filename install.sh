#!/bin/bash

# Install ralph-loop plugin into Claude Code's plugin cache
#
# This replaces the marketplace version with our fixed per-session version.
# Re-run this script after any marketplace plugin update to re-apply the fix.
#
# Usage: ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/ralph-loop/1.0.0"

echo "Ralph-Loop v2.0 Installer"
echo "========================="
echo ""

# Check if cache directory exists
if [[ ! -d "$CACHE_DIR" ]]; then
  echo "Cache directory not found: $CACHE_DIR"
  echo "Make sure the official ralph-loop plugin is installed first via:"
  echo "  /plugin install ralph-loop@claude-plugins-official"
  exit 1
fi

# Backup existing files
BACKUP_DIR="$CACHE_DIR/.backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$CACHE_DIR/scripts/setup-ralph-loop.sh" "$BACKUP_DIR/" 2>/dev/null || true
cp "$CACHE_DIR/hooks/stop-hook.sh" "$BACKUP_DIR/" 2>/dev/null || true
cp "$CACHE_DIR/commands/cancel-ralph.md" "$BACKUP_DIR/" 2>/dev/null || true
cp "$CACHE_DIR/commands/help.md" "$BACKUP_DIR/" 2>/dev/null || true
echo "Backed up existing files to: $BACKUP_DIR"

# Copy fixed files
cp "$SCRIPT_DIR/scripts/setup-ralph-loop.sh" "$CACHE_DIR/scripts/setup-ralph-loop.sh"
cp "$SCRIPT_DIR/hooks/stop-hook.sh" "$CACHE_DIR/hooks/stop-hook.sh"
cp "$SCRIPT_DIR/hooks/hooks.json" "$CACHE_DIR/hooks/hooks.json"
cp "$SCRIPT_DIR/commands/cancel-ralph.md" "$CACHE_DIR/commands/cancel-ralph.md"
cp "$SCRIPT_DIR/commands/ralph-loop.md" "$CACHE_DIR/commands/ralph-loop.md"
cp "$SCRIPT_DIR/commands/help.md" "$CACHE_DIR/commands/help.md"

# Ensure scripts are executable
chmod +x "$CACHE_DIR/scripts/setup-ralph-loop.sh"
chmod +x "$CACHE_DIR/hooks/stop-hook.sh"

echo ""
echo "Installed successfully!"
echo "  Source: $SCRIPT_DIR"
echo "  Target: $CACHE_DIR"
echo ""
echo "Changes applied:"
echo "  - Per-session state files (ralph-loop-<SESSION_ID>.local.md)"
echo "  - Per-session pointer files (ralph-loop-ptr-<SESSION_ID>.local)"
echo "  - No cross-session interference"
echo "  - Multiple concurrent ralph-loops supported"
echo ""
echo "Note: Re-run this script after any marketplace plugin update."
