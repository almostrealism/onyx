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

echo ""
echo "  Installed OnyxMCP to $INSTALL_DIR/OnyxMCP"
echo ""
