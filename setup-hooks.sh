#!/bin/bash
#
# Configure Claude Code hooks for Onyx integration.
# Run on any machine where Claude Code is used.
#
# Usage:
#   ./setup-hooks.sh                    # auto-detect OnyxMCP location
#   ./setup-hooks.sh /path/to/OnyxMCP   # specify OnyxMCP binary path
#
set -e

# Find OnyxMCP binary
ONYX_MCP="${1:-}"
if [ -z "$ONYX_MCP" ]; then
    for path in \
        "$HOME/.onyx/bin/OnyxMCP" \
        "$HOME/.local/bin/OnyxMCP" \
        /Users/Shared/flowtree/tools/OnyxMCP \
        /usr/local/bin/OnyxMCP \
        "$(command -v OnyxMCP 2>/dev/null)"; do
        if [ -x "$path" 2>/dev/null ]; then
            ONYX_MCP="$path"
            break
        fi
    done
fi

if [ -z "$ONYX_MCP" ] || [ ! -x "$ONYX_MCP" ]; then
    echo "Error: OnyxMCP binary not found."
    echo ""
    echo "Install options:"
    echo "  Local:  ./install-mcp.sh"
    echo "  Remote: ./setup-remote.sh user@hostname"
    echo "  Manual: ./setup-hooks.sh /path/to/OnyxMCP"
    exit 1
fi

echo "  Using OnyxMCP at: $ONYX_MCP"

HOOK_CMD="$ONYX_MCP --hook"
SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

mkdir -p "$SETTINGS_DIR"

# Build hooks JSON with the resolved binary path
HOOKS=$(cat <<HOOKSJSON
{
  "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "$HOOK_CMD", "timeout": 10}]}],
  "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "$HOOK_CMD", "timeout": 5, "async": true}]}],
  "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "$HOOK_CMD", "timeout": 120}]}],
  "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "$HOOK_CMD", "timeout": 5, "async": true}]}],
  "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "$HOOK_CMD", "timeout": 5, "async": true}]}]
}
HOOKSJSON
)

# Merge hooks into existing settings
MERGED=false

if [ -f "$SETTINGS_FILE" ]; then
    # Try python3 first
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
settings['hooks'] = json.loads('''$HOOKS''')
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" 2>/dev/null && MERGED=true
    fi

    # Try jq as fallback
    if [ "$MERGED" = false ] && command -v jq >/dev/null 2>&1; then
        TMP=$(mktemp)
        if jq --argjson hooks "$HOOKS" '.hooks = $hooks' "$SETTINGS_FILE" > "$TMP" 2>/dev/null; then
            mv "$TMP" "$SETTINGS_FILE"
            MERGED=true
        else
            rm -f "$TMP"
        fi
    fi
fi

if [ "$MERGED" = false ]; then
    # Write fresh settings (no existing file or merge tools unavailable)
    cat > "$SETTINGS_FILE" <<SETTINGSJSON
{
  "hooks": $HOOKS
}
SETTINGSJSON
fi

echo ""
echo "  Claude Code hooks configured in $SETTINGS_FILE"
echo ""
echo "  Hooks installed for Onyx integration:"
echo "    PreToolUse        — tracks tool usage in Onyx monitor"
echo "    PostToolUse       — clears tool status after completion"
echo "    PermissionRequest — approve/deny permissions from Onyx UI"
echo "    SessionStart      — registers new Claude Code sessions"
echo "    Stop              — marks sessions as stopped"
echo ""
echo "  ONYX_MCP_PORT is set automatically in Onyx SSH sessions."
echo "  See HOOKS.md for details and troubleshooting."
echo ""
