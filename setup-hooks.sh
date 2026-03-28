#!/bin/bash
#
# Configure Claude Code hooks to integrate with Onyx.
# Run this on any machine where Claude Code is used (local or remote).
#
# Prerequisites:
#   - OnyxMCP binary installed (run install-mcp.sh or copy the binary)
#   - ONYX_MCP_PORT set in environment (automatic via Onyx SSH sessions)
#
# Usage:
#   ./setup-hooks.sh [path-to-OnyxMCP]
#
set -e

# Find OnyxMCP binary
ONYX_MCP="${1:-}"
if [ -z "$ONYX_MCP" ]; then
    # Search common locations
    for path in \
        /Users/Shared/flowtree/tools/OnyxMCP \
        /usr/local/bin/OnyxMCP \
        "$HOME/.local/bin/OnyxMCP" \
        "$(which OnyxMCP 2>/dev/null)"; do
        if [ -x "$path" ]; then
            ONYX_MCP="$path"
            break
        fi
    done
fi

if [ -z "$ONYX_MCP" ] || [ ! -x "$ONYX_MCP" ]; then
    echo "Error: OnyxMCP binary not found."
    echo "Install it with: ./install-mcp.sh"
    echo "Or specify the path: ./setup-hooks.sh /path/to/OnyxMCP"
    exit 1
fi

echo "Using OnyxMCP at: $ONYX_MCP"

# Create or update Claude Code settings
SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

mkdir -p "$SETTINGS_DIR"

# Read existing settings or start fresh
if [ -f "$SETTINGS_FILE" ]; then
    EXISTING=$(cat "$SETTINGS_FILE")
else
    EXISTING="{}"
fi

# Build the hooks configuration
HOOK_CMD="$ONYX_MCP --hook"

HOOKS_JSON=$(cat <<ENDJSON
{
  "PreToolUse": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$HOOK_CMD",
          "timeout": 10
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$HOOK_CMD",
          "timeout": 5,
          "async": true
        }
      ]
    }
  ],
  "PermissionRequest": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$HOOK_CMD",
          "timeout": 120
        }
      ]
    }
  ],
  "SessionStart": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$HOOK_CMD",
          "timeout": 5,
          "async": true
        }
      ]
    }
  ],
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$HOOK_CMD",
          "timeout": 5,
          "async": true
        }
      ]
    }
  ]
}
ENDJSON
)

# Merge hooks into existing settings using Python (widely available)
python3 -c "
import json, sys

existing = json.loads('''$EXISTING''')
hooks = json.loads('''$HOOKS_JSON''')
existing['hooks'] = hooks

with open('$SETTINGS_FILE', 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')
" 2>/dev/null

if [ $? -eq 0 ]; then
    echo ""
    echo "  Claude Code hooks configured in $SETTINGS_FILE"
    echo ""
    echo "  Hooks installed:"
    echo "    - PreToolUse:       tracks tool usage in Onyx monitor"
    echo "    - PostToolUse:      clears tool status after completion"
    echo "    - PermissionRequest: approve/deny permissions from Onyx UI"
    echo "    - SessionStart:     registers new sessions"
    echo "    - Stop:             marks sessions as stopped"
    echo ""
    echo "  Make sure ONYX_MCP_PORT is set in your environment."
    echo "  (Automatic when using Onyx SSH sessions with tmux)"
    echo ""
else
    echo "Error: Failed to update settings. Install python3 or edit manually."
    echo ""
    echo "Add to $SETTINGS_FILE:"
    echo '  "hooks": { ... }'
    exit 1
fi
