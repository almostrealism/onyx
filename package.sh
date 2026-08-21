#!/bin/bash
#
# Build Onyx.app and a distributable DMG.
#
#   ./package.sh                 → unsigned bundle + DMG (ad-hoc signed app)
#   ./package.sh --sign          → Developer ID signed, hardened runtime
#   ./package.sh --sign --notarize → …plus notarization and stapling
#
# Signing and notarization are OPT-IN and take every credential from the
# environment. Nothing secret belongs in this repo:
#
#   ONYX_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#                        Defaults to the first Developer ID Application
#                        identity in your keychain.
#   ONYX_TEAM_ID         Apple Developer team ID.
#   ONYX_SKIP_LAUNCH_CHECK=1  Skip the post-build launch check (it opens
#                        the app for four seconds).
#   ONYX_APPLE_ID        Apple ID used for notarization.
#   ONYX_NOTARY_PROFILE  Only needed to override the default. Notarization
#                        uses a notarytool keychain profile named ONYX,
#                        created once with:
#                          xcrun notarytool store-credentials ONYX \
#                            --apple-id <id> --team-id <TEAMID>
#                        No password ever appears in a command line.
#
# The signing certificate lives in the login keychain of the user who owns
# it, so run this as that user — `security find-identity -v -p codesigning`
# should list it before you start.
#
set -e

APP_NAME="Onyx"
BUILD_DIR=".build/release"
DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"

# Put the keychain's lock behaviour back however we leave — including on
# a failed signature, which is exactly when you'd forget. `set-keychain-
# settings` with no -lut restores lock-on-sleep; leaving an hour-long
# window open on someone's desktop because a build failed would be rude.
KEYCHAIN_PATH="${ONYX_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

keychain_locked() {
    [ -f "$KEYCHAIN_PATH" ] || return 1          # no keychain: nothing to unlock
    ! security show-keychain-info "$KEYCHAIN_PATH" >/dev/null 2>&1
}

# Unlock if needed. Called before signing AND again before notarizing:
# notarytool reads its credential profile OUT OF THE KEYCHAIN, so a
# keychain that re-locked during the build breaks notarization just as
# surely as it breaks codesign — and reports it as a missing profile.
ensure_keychain_unlocked() {
    [ -f "$KEYCHAIN_PATH" ] || return 0
    if ! keychain_locked; then return 0; fi
    echo "  Unlocking login keychain ($1)..."
    security unlock-keychain "$KEYCHAIN_PATH"
    # -ut, NOT -lut: `-l` means "also lock when the system sleeps", which
    # is how the keychain kept re-locking in the middle of a notarization
    # wait. Timeout only, generous enough for Apple's turnaround.
    security set-keychain-settings -ut 7200 "$KEYCHAIN_PATH"
    RELOCK_KEYCHAIN=1
}

restore_keychain() {
    if [ "${RELOCK_KEYCHAIN:-0}" = "1" ]; then
        security set-keychain-settings "$KEYCHAIN_PATH" 2>/dev/null || true
        echo "  Keychain lock settings restored."
    fi
}
trap restore_keychain EXIT

DO_SIGN=0
DO_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --sign)     DO_SIGN=1 ;;
        --notarize) DO_SIGN=1; DO_NOTARIZE=1 ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Version comes from the git tag, so the bundle can't drift from the
# release. A dirty or untagged tree is marked as such rather than
# silently shipping as the last tag.
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0")
FULL_VERSION=$(git describe --tags --dirty 2>/dev/null || echo "$VERSION")
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

echo ""
echo "  $APP_NAME $FULL_VERSION"
echo ""

# ---------------------------------------------------------------- build
echo "  Building (release)..."
swift build -c release

echo "  Assembling $APP_NAME.app..."
rm -rf "$STAGE_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Sources/OnyxApp/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# SPM resource bundles — Bundle.module needs these at runtime.
# NB: .build/release is a SYMLINK to arm64-apple-macosx/release, and BSD
# find does not follow symlinks, so `find "$BUILD_DIR" -name '*.bundle'`
# silently matched NOTHING and every install shipped without them (the
# dock icon is loaded via Bundle.module, so it quietly went missing).
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

# Stamp the real version into the bundle's Info.plist.
cp "Sources/OnyxApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

# ----------------------------------------------------------------- sign
if [ "$DO_SIGN" = "1" ]; then
    # Over SSH the login keychain stays LOCKED after login, and codesign
    # can't reach the private key: it fails with "User interaction is not
    # allowed" rather than anything mentioning the keychain. Unlock it
    # here, but only when we're actually signing — an unsigned build has
    # no business asking for a password.
    #
    # `security unlock-keychain` with no -p reads from the tty, which is
    # what makes this work over SSH; it's the GUI prompt that isn't
    # allowed. Skipped when the keychain is already unlocked, so a
    # desktop run is untouched.
    ensure_keychain_unlocked "codesign needs the private key"

    IDENTITY="${ONYX_SIGN_IDENTITY:-}"
    if [ -z "$IDENTITY" ]; then
        IDENTITY=$(security find-identity -v -p codesigning \
            | grep "Developer ID Application" | head -1 \
            | sed 's/.*"\(.*\)"/\1/')
    fi
    if [ -z "$IDENTITY" ]; then
        echo "  ERROR: no Developer ID Application identity found." >&2
        echo "  Run as the user who owns the certificate, or set" >&2
        echo "  ONYX_SIGN_IDENTITY. Check with:" >&2
        echo "    security find-identity -v -p codesigning" >&2
        exit 1
    fi
    echo "  Signing as: $IDENTITY"
    # Hardened runtime is required for notarization. Onyx spawns ssh and
    # scp as child processes, so it needs the inherit exception; without
    # it the hardened runtime kills those children.
    ENTITLEMENTS="$DIST_DIR/onyx.entitlements"
    cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
    <key>com.apple.security.inherit</key>
    <true/>
</dict>
</plist>
PLIST
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
    # Ad-hoc: required for the binary to run at all on Apple Silicon.
    # Gatekeeper will still warn on another Mac — that's what --sign is for.
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    codesign --force --sign - "$APP_BUNDLE"
fi

# --------------------------------------------------------------- verify
# Launch the assembled app and confirm it's still alive a moment later.
#
# The first packaged DMG crashed in OnyxApp.init() — before any window —
# because Bundle.module couldn't find its resource bundle. Nothing in the
# build caught it: SPM's fallback is an absolute path into THIS machine's
# .build directory, so on the build machine it always resolves. That is
# also this check's blind spot; BundleResourceTests is the real guard.
# What this catches is the gross stuff — a missing dylib, a bad signature,
# an immediate abort — which is worth the four seconds.
if [ "${ONYX_SKIP_LAUNCH_CHECK:-0}" != "1" ]; then
    echo "  Checking the app starts..."
    LAUNCH_LOG=$(mktemp)
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >"$LAUNCH_LOG" 2>&1 &
    LAUNCH_PID=$!
    sleep 4
    if kill -0 "$LAUNCH_PID" 2>/dev/null; then
        kill -9 "$LAUNCH_PID" 2>/dev/null || true
        wait "$LAUNCH_PID" 2>/dev/null || true
        echo "  Starts cleanly."
    else
        echo "  ERROR: the app exited immediately after launch." >&2
        echo "  ---" >&2
        tail -20 "$LAUNCH_LOG" >&2
        echo "  ---" >&2
        echo "  Refusing to build a DMG that won't start." >&2
        rm -f "$LAUNCH_LOG"
        exit 1
    fi
    rm -f "$LAUNCH_LOG"
fi

# ------------------------------------------------------------------ dmg
echo "  Building DMG..."
# A symlink to /Applications so the window is a drag-to-install target.
ln -sf /Applications "$STAGE_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

if [ "$DO_SIGN" = "1" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
fi

# ------------------------------------------------------------- notarize
if [ "$DO_NOTARIZE" = "1" ]; then
    echo "  Submitting for notarization (this waits for Apple)..."
    # Default to a profile named after the app. Anyone who ran
    # `notarytool store-credentials ONYX` — which is what the docs above
    # tell you to do — should not then have to export a variable saying
    # so. Set ONYX_NOTARY_PROFILE only to use a differently-named one.
    PROFILE="${ONYX_NOTARY_PROFILE:-ONYX}"
    # The profile lives in the keychain, so it can only be read while the
    # keychain is open. Signing may have finished an hour ago.
    ensure_keychain_unlocked "notarytool reads its profile from the keychain"
    if keychain_locked; then
        echo "  ERROR: the keychain is locked, so the '$PROFILE' profile" >&2
        echo "  can't be read. Unlock it and retry:" >&2
        echo "    security unlock-keychain \"$KEYCHAIN_PATH\"" >&2
        exit 1
    fi
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "  Using notary profile: $PROFILE"
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$PROFILE" --wait
    elif [ -n "${ONYX_APPLE_ID:-}" ] && [ -n "${ONYX_TEAM_ID:-}" ]; then
        # Password is read from the keychain item, never passed here.
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$ONYX_APPLE_ID" --team-id "$ONYX_TEAM_ID" \
            --password "@keychain:ONYX_NOTARY_PASSWORD" --wait
    else
        echo "  ERROR: no usable notarization credentials." >&2
        echo "  Looked for a keychain profile named '$PROFILE' in" >&2
        echo "  $KEYCHAIN_PATH (unlocked: yes — so it really is absent," >&2
        echo "  or stored in a different keychain/user account)." >&2
        echo "  Create one once with:" >&2
        echo "    xcrun notarytool store-credentials ONYX \\" >&2
        echo "      --apple-id <your-apple-id> --team-id <TEAMID>" >&2
        echo "  (or set ONYX_NOTARY_PROFILE to a different profile name," >&2
        echo "  or ONYX_APPLE_ID + ONYX_TEAM_ID with the password stored" >&2
        echo "  in the keychain as ONYX_NOTARY_PASSWORD)." >&2
        exit 1
    fi
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
fi

echo ""
echo "  $DMG_PATH"
du -h "$DMG_PATH" | awk '{print "  " $1}'
if [ "$DO_SIGN" != "1" ]; then
    echo ""
    echo "  NOTE: unsigned. On another Mac, Gatekeeper will refuse to open"
    echo "  it until the user right-clicks → Open, or you run with --sign."
fi
echo ""
