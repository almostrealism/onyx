#!/bin/bash
set -e

APP_NAME="Onyx"
INSTALL_DIR="/Applications"
BUILD_DIR=".build/release"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"

# Onyx relies on tmux for session persistence. It must be present on the
# machine that actually hosts the sessions — the remote host for SSH
# sessions, or this Mac for local ones. We can only check this machine,
# so a miss is a non-fatal warning rather than a hard failure.
if command -v tmux >/dev/null 2>&1; then
    echo ""
    echo "  Found tmux: $(tmux -V) ($(command -v tmux))"
else
    echo ""
    echo "  WARNING: tmux was not found on this machine."
    echo "  Onyx uses tmux for session persistence. Local sessions need it"
    echo "  here; SSH sessions need it on the remote host. Install it with"
    echo "  'brew install tmux' (or your package manager) if you'll run"
    echo "  sessions on this Mac."
fi

echo ""
echo "  Building $APP_NAME..."
echo ""

swift build -c release

echo ""
echo "  Creating app bundle..."
echo ""

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ---------------------------------------------- MCP bridge payload
#
# Best effort, and never fatal. The app installs this bridge onto remote
# hosts in one click, so a build with no bridges can't do that at all —
# but a build with only the Mac one is still useful, and requiring a CI
# run before you can test locally would be absurd.
#
# macOS: built right here, always.
# Linux: cross-compiling from macOS needs the swift.org toolchain and a
#        static SDK Xcode's Swift can't use, so those come from CI. Try
#        dist/mcp first (a manual drop), then the newest GitHub release.
MCP_DIR="$APP_BUNDLE/Contents/Resources/mcp"
mkdir -p "$MCP_DIR"
if [ -f "$BUILD_DIR/OnyxMCP" ]; then
    cp "$BUILD_DIR/OnyxMCP" "$MCP_DIR/OnyxMCP-macos-arm64"
    chmod +x "$MCP_DIR/OnyxMCP-macos-arm64"
fi

for arch in linux-x86_64 linux-arm64; do
    if [ -f "dist/mcp/OnyxMCP-$arch" ]; then
        cp "dist/mcp/OnyxMCP-$arch" "$MCP_DIR/" && chmod +x "$MCP_DIR/OnyxMCP-$arch"
    elif command -v gh >/dev/null 2>&1 \
        && gh release download --pattern "OnyxMCP-$arch" --dir "$MCP_DIR" \
             --clobber >/dev/null 2>&1; then
        chmod +x "$MCP_DIR/OnyxMCP-$arch"
    fi
done

HAVE=$(ls "$MCP_DIR" 2>/dev/null | tr '\n' ' ')
echo "  MCP bridges: ${HAVE:-none}"
case "$HAVE" in
    *linux*) ;;
    *) echo "           (no Linux bridge — Linux hosts will say so in the"
       echo "            monitor. Run the 'MCP binaries' workflow, or drop"
       echo "            binaries in dist/mcp/, to include them.)" ;;
esac

# Copy Info.plist, stamping the real version into it.
#
# Without this the bundle keeps the placeholder 0.1.0 from the checked-in
# plist, and every macOS crash or hang report says "Version: 0.1.0 (1)"
# — so a report from a user can't be tied to a build, which is exactly
# when you need to know. package.sh does the same; a script-installed
# build has no less right to be identifiable.
#
# `git describe` (not the bare tag) so a build from a working tree that's
# ahead of the tag says so, rather than claiming to be the release.
cp "Sources/OnyxApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0")
BUILD_VERSION=$(git describe --tags --dirty --always 2>/dev/null || echo "$VERSION")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
echo "  Version: $BUILD_VERSION"

# Copy app icon so Finder shows it
cp "Sources/OnyxApp/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# SPM resource bundles — Bundle.module needs these at runtime.
# NB: .build/release is a SYMLINK to arm64-apple-macosx/release, and BSD
# find does not follow symlinks, so `find "$BUILD_DIR" -name '*.bundle'`
# silently matched NOTHING and every install shipped without them (the
# dock icon is loaded via Bundle.module, so it quietly went missing).
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

# Sign ad-hoc (required on Apple Silicon)
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo ""
echo "  Installed to $APP_BUNDLE"
echo "  You can now open Onyx from Applications or Spotlight."
echo ""
echo "  Optional: Run ./install-mcp.sh to install the OnyxMCP bridge"
echo "  binary to /Users/Shared/flowtree/tools/. This lets Claude Code in any"
echo "  repo communicate with Onyx via MCP (requires write access to"
echo "  /Users/Shared/flowtree/tools/)."
echo ""
