#!/usr/bin/env bash
# Build the Onyx screensaver as a .saver bundle and install it to
# ~/Library/Screen Savers/.
#
# macOS screensavers are NSBundle plugins, not SwiftPM-friendly targets,
# so we compile a Mach-O bundle here directly via swiftc. Keep this script
# the single source of truth for the screensaver build — `swift build` for
# the main app is untouched.
#
# Usage:
#   ./OnyxScreenSaver/build.sh           # build + install (debug)
#   ./OnyxScreenSaver/build.sh release   # build + install (release/-O)
#   ./OnyxScreenSaver/build.sh --no-install   # build only, leave in .build
#
# After install, open System Settings → Screen Saver and pick "Onyx".
# (You may need to restart System Settings if it was already open.)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

BUNDLE_NAME="Onyx.saver"
BINARY_NAME="Onyx"
BUILD_DIR="$SCRIPT_DIR/.build"
BUNDLE_DIR="$BUILD_DIR/$BUNDLE_NAME"
INSTALL_DIR="$HOME/Library/Screen Savers"

MODE="debug"
DO_INSTALL=1
for arg in "$@"; do
    case "$arg" in
        release) MODE="release" ;;
        --no-install) DO_INSTALL=0 ;;
        *) echo "warning: unknown arg '$arg'" >&2 ;;
    esac
done

SWIFT_FLAGS=(-target arm64-apple-macos14 -emit-library -module-name OnyxScreenSaver)
if [[ "$MODE" == "release" ]]; then
    SWIFT_FLAGS+=(-O)
else
    SWIFT_FLAGS+=(-Onone -g)
fi

SOURCES=( "$SCRIPT_DIR"/Sources/*.swift )
echo "Compiling ${#SOURCES[@]} sources ($MODE)..."

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Compile the screensaver bundle binary. screensaver bundles are loaded
# via NSBundle / dlopen, so we need a Mach-O bundle (-bundle), not a dylib.
xcrun swiftc \
    "${SWIFT_FLAGS[@]}" \
    -Xlinker -bundle \
    -framework AppKit \
    -framework SceneKit \
    -framework ScreenSaver \
    -o "$BUNDLE_DIR/Contents/MacOS/$BINARY_NAME" \
    "${SOURCES[@]}"

cp "$SCRIPT_DIR/Resources/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

# Ad-hoc sign so macOS will load the bundle without quarantine complaints
# on the local machine. Distribution would need a real developer ID.
codesign --force --sign - --timestamp=none "$BUNDLE_DIR" || {
    echo "warning: codesign failed; the saver may still load if SIP allows it" >&2
}

echo "Built: $BUNDLE_DIR"

if [[ "$DO_INSTALL" == "1" ]]; then
    mkdir -p "$INSTALL_DIR"
    DEST="$INSTALL_DIR/$BUNDLE_NAME"
    rm -rf "$DEST"
    cp -R "$BUNDLE_DIR" "$DEST"
    # dSYM is debug-only; not needed in the installed bundle.
    rm -rf "$DEST/Contents/MacOS/$BINARY_NAME.dSYM"
    echo "Installed: $DEST"
    echo
    echo "Open System Settings → Screen Saver and select 'Onyx'."
    echo "If it doesn't appear, quit and reopen System Settings."
fi
