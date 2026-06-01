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
#   ./OnyxScreenSaver/build.sh                       # build + install (debug)
#   ./OnyxScreenSaver/build.sh release               # build + install (release/-O)
#   ./OnyxScreenSaver/build.sh --no-install          # build only, leave in .build
#   ./OnyxScreenSaver/build.sh --install-to <path>   # custom Screen Savers dir
#   ./OnyxScreenSaver/build.sh --stage /tmp/saver    # stage to a world-readable
#                                                    # path (no install). Useful
#                                                    # when the build runs under
#                                                    # a different user than the
#                                                    # one logged in to the GUI.
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
STAGE_DIR=""
while (( "$#" )); do
    case "$1" in
        release) MODE="release"; shift ;;
        --no-install) DO_INSTALL=0; shift ;;
        --install-to)
            INSTALL_DIR="$2"; shift 2 ;;
        --stage)
            STAGE_DIR="$2"; DO_INSTALL=0; shift 2 ;;
        *) echo "warning: unknown arg '$1'" >&2; shift ;;
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

# Copy other resources (background image, future assets) into the bundle's
# Resources/ — they're loaded via Bundle(for: ...).path(forResource:ofType:).
shopt -s nullglob
for f in "$SCRIPT_DIR"/Resources/*; do
    name=$(basename "$f")
    if [[ "$name" != "Info.plist" ]]; then
        cp -R "$f" "$BUNDLE_DIR/Contents/Resources/"
    fi
done
shopt -u nullglob

# Ad-hoc sign so macOS will load the bundle without quarantine complaints
# on the local machine. Distribution would need a real developer ID.
codesign --force --sign - --timestamp=none "$BUNDLE_DIR" || {
    echo "warning: codesign failed; the saver may still load if SIP allows it" >&2
}

echo "Built: $BUNDLE_DIR"

# Helper: copy bundle to a destination directory, stripping debug-only dSYM.
install_bundle() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    local dest="$dest_dir/$BUNDLE_NAME"
    rm -rf "$dest"
    cp -R "$BUNDLE_DIR" "$dest"
    rm -rf "$dest/Contents/MacOS/$BINARY_NAME.dSYM"
    chmod -R a+rX "$dest"
    echo "$dest"
}

if [[ -n "$STAGE_DIR" ]]; then
    DEST="$( install_bundle "$STAGE_DIR" )"
    echo "Staged: $DEST"
    echo
    echo "To install for the current GUI user, run (as that user):"
    echo "    cp -R '$DEST' \"\$HOME/Library/Screen Savers/\""
    echo "Then open System Settings → Screen Saver and select 'Onyx'."
elif [[ "$DO_INSTALL" == "1" ]]; then
    DEST="$( install_bundle "$INSTALL_DIR" )"
    echo "Installed: $DEST"
    echo
    echo "Open System Settings → Screen Saver and select 'Onyx'."
    echo "If it doesn't appear, quit and reopen System Settings."
fi
