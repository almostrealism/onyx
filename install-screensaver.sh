#!/usr/bin/env bash
# Build + install the Onyx CPU-totem screensaver as a system .saver bundle.
# Wraps OnyxScreenSaver/build.sh with release optimization on by default —
# the debug build is fine for iteration but noticeably slower at 60fps.
#
# Usage:
#   ./install-screensaver.sh              # release build, install for current user
#   ./install-screensaver.sh debug        # debug build (faster compile, slower at runtime)
#   ./install-screensaver.sh --stage DIR  # build to DIR for cross-user copy
#
# After install: open System Settings → Screen Saver and select "Onyx".

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MODE="release"
EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        debug) MODE="debug" ;;
        release) MODE="release" ;;
        *) EXTRA_ARGS+=("$arg") ;;
    esac
done

echo ""
echo "  Building Onyx screensaver ($MODE)..."
echo ""

if [[ "$MODE" == "release" ]]; then
    "$SCRIPT_DIR/OnyxScreenSaver/build.sh" release ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
else
    "$SCRIPT_DIR/OnyxScreenSaver/build.sh" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
fi
