#!/bin/bash
#
# Set up a remote host for Onyx + Claude Code integration.
# Copies OnyxMCP binary and configures Claude Code hooks.
#
# Usage:
#   ./setup-remote.sh user@hostname
#   ./setup-remote.sh -p 2222 user@hostname
#   ./setup-remote.sh -i ~/.ssh/id_rsa user@hostname
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_PORT=""
SSH_IDENTITY=""
REMOTE_BIN_DIR=".onyx/bin"

# Parse arguments
while [[ $# -gt 1 ]]; do
    case "$1" in
        -p) SSH_PORT="$2"; shift 2 ;;
        -i) SSH_IDENTITY="$2"; shift 2 ;;
        *) break ;;
    esac
done

REMOTE_HOST="${1:-}"
if [ -z "$REMOTE_HOST" ]; then
    echo "Usage: $0 [-p port] [-i identity_file] user@hostname"
    echo ""
    echo "Sets up a remote host for Onyx Claude Code integration:"
    echo "  1. Builds and copies OnyxMCP binary"
    echo "  2. Configures Claude Code hooks"
    echo ""
    echo "Options:"
    echo "  -p PORT      SSH port (default: 22)"
    echo "  -i FILE      SSH identity file"
    exit 1
fi

# Build SSH args
SSH_ARGS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
SCP_ARGS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [ -n "$SSH_PORT" ]; then
    SSH_ARGS="$SSH_ARGS -p $SSH_PORT"
    SCP_ARGS="$SCP_ARGS -P $SSH_PORT"
fi
if [ -n "$SSH_IDENTITY" ]; then
    SSH_ARGS="$SSH_ARGS -i $SSH_IDENTITY"
    SCP_ARGS="$SCP_ARGS -i $SSH_IDENTITY"
fi

echo ""
echo "  Setting up Onyx on $REMOTE_HOST"
echo ""

# Step 1: Build OnyxMCP locally
echo "  [1/4] Building OnyxMCP..."
cd "$SCRIPT_DIR"
swift build --product OnyxMCP -q 2>/dev/null
BINARY="$(swift build --product OnyxMCP --show-bin-path 2>/dev/null)/OnyxMCP"

if [ ! -f "$BINARY" ]; then
    echo "  Error: Failed to build OnyxMCP"
    exit 1
fi
echo "        Built: $BINARY"

# Step 2: Check remote architecture and copy binary
echo "  [2/4] Checking remote host..."
REMOTE_ARCH=$(ssh $SSH_ARGS "$REMOTE_HOST" "uname -m" 2>/dev/null)
LOCAL_ARCH=$(uname -m)

REMOTE_OS=$(ssh $SSH_ARGS "$REMOTE_HOST" uname -s 2>/dev/null)
if [ "$REMOTE_ARCH" = "$LOCAL_ARCH" ] && [ "$(uname -s)" = "$REMOTE_OS" ]; then
    # Same arch, same OS — copy directly
    echo "        Architecture match ($REMOTE_ARCH/$REMOTE_OS), copying binary..."
elif [ "$REMOTE_OS" = "Linux" ] && [ -f "$SCRIPT_DIR/.build/linux/OnyxMCP" ]; then
    # Linux binary available from Docker build
    BINARY="$SCRIPT_DIR/.build/linux/OnyxMCP"
    echo "        Using pre-built Linux binary..."
else
    echo ""
    echo "  WARNING: Remote host is $REMOTE_ARCH ($REMOTE_OS)"
    echo "  Local binary is $LOCAL_ARCH ($(uname -s))"
    echo ""
    if [ "$REMOTE_OS" = "Linux" ]; then
        echo "  Build a Linux binary first:"
        echo "    ./build-linux-mcp.sh    (requires Docker)"
        echo "  Then re-run this script."
        echo ""
        echo "  Or build on the remote host directly:"
        echo "    ssh $REMOTE_HOST"
        echo "    git clone <repo-url> && cd onyx"
        echo "    swift build --product OnyxMCP -c release"
        echo "    mkdir -p ~/.onyx/bin && cp .build/release/OnyxMCP ~/.onyx/bin/"
    else
        echo "  The binary may not work. Build OnyxMCP on the remote host."
    fi
    echo ""
    echo "  Continuing anyway (will fail at runtime if incompatible)..."
    echo ""
fi

echo "  [3/4] Copying OnyxMCP to $REMOTE_HOST:~/$REMOTE_BIN_DIR/..."
ssh $SSH_ARGS "$REMOTE_HOST" "mkdir -p ~/$REMOTE_BIN_DIR" 2>/dev/null
scp $SCP_ARGS -q "$BINARY" "$REMOTE_HOST:~/$REMOTE_BIN_DIR/OnyxMCP" 2>/dev/null
ssh $SSH_ARGS "$REMOTE_HOST" "chmod +x ~/$REMOTE_BIN_DIR/OnyxMCP" 2>/dev/null

# Step 3: Configure Claude Code hooks on remote host
echo "  [4/4] Configuring Claude Code hooks..."

HOOK_CMD="\$HOME/$REMOTE_BIN_DIR/OnyxMCP --hook"

# Use a heredoc sent via SSH — avoids needing python3 on the remote
ssh $SSH_ARGS "$REMOTE_HOST" bash <<'REMOTE_SCRIPT'
set -e
HOOK_CMD="$HOME/.onyx/bin/OnyxMCP --hook"
SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

mkdir -p "$SETTINGS_DIR"

# Build the complete hooks JSON
HOOKS=$(cat <<'HOOKSJSON'
{
  "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_CMD_PLACEHOLDER", "timeout": 10}]}],
  "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_CMD_PLACEHOLDER", "timeout": 5, "async": true}]}],
  "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_CMD_PLACEHOLDER", "timeout": 120}]}],
  "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_CMD_PLACEHOLDER", "timeout": 5, "async": true}]}],
  "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_CMD_PLACEHOLDER", "timeout": 5, "async": true}]}]
}
HOOKSJSON
)

# Replace placeholder with actual path
HOOKS=$(echo "$HOOKS" | sed "s|HOOK_CMD_PLACEHOLDER|$HOOK_CMD|g")

if [ -f "$SETTINGS_FILE" ]; then
    # Try to merge with existing settings
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
settings['hooks'] = json.loads('''$HOOKS''')
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" 2>/dev/null && exit 0
    fi

    # No python3 — try jq
    if command -v jq >/dev/null 2>&1; then
        TMP=$(mktemp)
        jq --argjson hooks "$HOOKS" '.hooks = $hooks' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
        exit 0
    fi

    # Fallback: just write the hooks (may lose other settings)
    echo "Warning: python3/jq not found, overwriting settings.json"
fi

# Write fresh settings file
cat > "$SETTINGS_FILE" <<SETTINGSJSON
{
  "hooks": $HOOKS
}
SETTINGSJSON
REMOTE_SCRIPT

echo ""
echo "  Setup complete!"
echo ""
echo "  What was done:"
echo "    - OnyxMCP installed to ~/$REMOTE_BIN_DIR/OnyxMCP on $REMOTE_HOST"
echo "    - Claude Code hooks configured in ~/.claude/settings.json"
echo ""
echo "  Next steps:"
echo "    1. Connect to $REMOTE_HOST via an Onyx terminal session"
echo "    2. Start Claude Code in that session"
echo "    3. Open the monitoring overlay (backtick key) to see sessions"
echo ""
echo "  See HOOKS.md for more details and troubleshooting."
echo ""
