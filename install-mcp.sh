#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/Users/Shared/flowtree/tools"

echo ""
echo "  Building OnyxMCP..."
echo ""

cd "$SCRIPT_DIR"
swift build --product OnyxMCP

# Find the built binary (debug by default)
BINARY="$(swift build --product OnyxMCP --show-bin-path)/OnyxMCP"

if [ ! -f "$BINARY" ]; then
    echo "  Error: OnyxMCP binary not found at $BINARY"
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/OnyxMCP"
chmod +x "$INSTALL_DIR/OnyxMCP"

# Also install to ~/.onyx/bin for local use
LOCAL_BIN="$HOME/.onyx/bin"
mkdir -p "$LOCAL_BIN"
cp "$BINARY" "$LOCAL_BIN/OnyxMCP"
chmod +x "$LOCAL_BIN/OnyxMCP"

echo ""
echo "  Installed OnyxMCP to:"
echo "    $INSTALL_DIR/OnyxMCP"
echo "    $LOCAL_BIN/OnyxMCP"
echo ""
echo "  Next steps:"
echo "    Local:  ./setup-hooks.sh           (configure Claude Code hooks)"
echo "    Remote: ./setup-remote.sh user@host (set up a remote host)"
echo ""
