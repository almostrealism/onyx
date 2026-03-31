#!/bin/bash
#
# Build OnyxMCP for Linux using Docker.
# Produces a static binary at .build/linux/OnyxMCP
#
# Usage:
#   ./build-linux-mcp.sh              # build for linux/amd64
#   ./build-linux-mcp.sh arm64        # build for linux/arm64
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="${1:-amd64}"
OUTPUT_DIR="$SCRIPT_DIR/.build/linux"

# Map to Docker platform
case "$ARCH" in
    amd64|x86_64) PLATFORM="linux/amd64" ;;
    arm64|aarch64) PLATFORM="linux/arm64" ;;
    *) echo "Unknown arch: $ARCH (use amd64 or arm64)"; exit 1 ;;
esac

echo ""
echo "  Building OnyxMCP for Linux ($ARCH)..."
echo ""

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "  Docker is required. Install it from https://docker.com"
    echo ""
    echo "  Alternatively, build on a Linux machine directly:"
    echo "    git clone <this-repo>"
    echo "    swift build --product OnyxMCP -c release"
    echo "    cp .build/release/OnyxMCP ~/.onyx/bin/"
    exit 1
fi

# Build in a Swift container
mkdir -p "$OUTPUT_DIR"
docker run --rm \
    --platform "$PLATFORM" \
    -v "$SCRIPT_DIR:/src" \
    -w /src \
    swift:6.0 \
    bash -c "swift build --product OnyxMCP -c release --static-swift-stdlib 2>&1 && cp .build/release/OnyxMCP /src/.build/linux/OnyxMCP"

if [ -f "$OUTPUT_DIR/OnyxMCP" ]; then
    echo ""
    echo "  Built: $OUTPUT_DIR/OnyxMCP"
    echo "  Size: $(du -h "$OUTPUT_DIR/OnyxMCP" | cut -f1)"
    echo ""
    echo "  Install on remote host:"
    echo "    scp $OUTPUT_DIR/OnyxMCP user@host:~/.onyx/bin/OnyxMCP"
    echo "    ssh user@host 'chmod +x ~/.onyx/bin/OnyxMCP'"
    echo ""
else
    echo "  Build failed."
    exit 1
fi
