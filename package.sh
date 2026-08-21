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
        # Ask rather than exit. A certificate can't be typed into
        # existence — that's the one thing a prompt can't fix — but the
        # usual causes are a locked keychain (already handled above), a
        # non-default keychain, or an identity whose name we didn't
        # match. All of those the user can answer right here.
        echo ""
        echo "  No Developer ID Application identity was found automatically."
        echo "  Identities visible to this account:"
        security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' || true
        echo ""
        echo "  Enter the identity to sign with (paste the full name in"
        echo "  quotes from the list above), or leave blank to build an"
        echo "  UNSIGNED DMG and stop before notarization."
        ask IDENTITY "  Identity: "
        if [ -z "$IDENTITY" ]; then
            echo "  Continuing unsigned."
            DO_SIGN=0
            DO_NOTARIZE=0
        fi
    fi
fi

# Re-check: the prompt above may have turned signing off.
if [ "$DO_SIGN" = "1" ]; then
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
#
# The contract for this section: it finishes with a notarized DMG, or it
# keeps asking you for what it needs. It does not stop to tell you to go
# and run something yourself.
# Read an answer from the user. Prefers the controlling terminal so a
# prompt still works when stdin is redirected, but falls back to stdin
# when there ISN'T a terminal (piped input, CI) instead of silently
# reading nothing and looping on empty answers.
ask() {   # ask VAR "prompt" [--secret]
    __var="$1"; __prompt="$2"; __secret="${3:-}"
    if [ -r /dev/tty ]; then __src=/dev/tty; else __src=/dev/stdin; fi
    if [ "$__secret" = "--secret" ]; then
        read -r -s -p "$__prompt" __answer <"$__src" || __answer=""
        echo ""
    else
        read -r -p "$__prompt" __answer <"$__src" || __answer=""
    fi
    eval "$__var=\$__answer"
}

prompt_notary_credentials() {
    NOTARY_CONF="$HOME/.onyx-notary.conf"
    [ -f "$NOTARY_CONF" ] && . "$NOTARY_CONF"

    DEFAULT_ID="${ONYX_APPLE_ID:-${SAVED_APPLE_ID:-}}"
    if [ -n "$DEFAULT_ID" ]; then
        ask APPLE_ID "  Apple ID [$DEFAULT_ID]: "
        APPLE_ID="${APPLE_ID:-$DEFAULT_ID}"
    else
        ask APPLE_ID "  Apple ID: "
    fi

    DEFAULT_TEAM="${ONYX_TEAM_ID:-${SAVED_TEAM_ID:-}}"
    if [ -n "$DEFAULT_TEAM" ]; then
        ask TEAM_ID "  Team ID [$DEFAULT_TEAM]: "
        TEAM_ID="${TEAM_ID:-$DEFAULT_TEAM}"
    else
        ask TEAM_ID "  Team ID: "
    fi

    ask APP_PASSWORD "  App-specific password: " --secret

    # Remember the non-secret half so this is normally just the password.
    umask 077
    cat > "$NOTARY_CONF" <<CONF
SAVED_APPLE_ID="$APPLE_ID"
SAVED_TEAM_ID="$TEAM_ID"
CONF
}

if [ "$DO_NOTARIZE" = "1" ]; then
    ensure_keychain_unlocked "notarytool reads its profile from the keychain"
    PROFILE="${ONYX_NOTARY_PROFILE:-ONYX}"

    NOTARY_ARGS=""
    # A profile is used only if it actually WORKS — not if it merely
    # exists. Locked, unreadable and absent all mean the same thing here:
    # ask the human.
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "  Using notary profile: $PROFILE"
        NOTARY_ARGS="--keychain-profile $PROFILE"
    fi

    NOTARIZED=0
    for attempt in 1 2 3; do
        if [ -z "$NOTARY_ARGS" ]; then
            echo ""
            if [ "$attempt" = "1" ]; then
                echo "  Notarization credentials needed."
                echo "  (No working '$PROFILE' profile on this machine.)"
            else
                echo "  That didn't authenticate. Try again (attempt $attempt of 3)."
                echo "  The password is an APP-SPECIFIC password from"
                echo "  appleid.apple.com, not your Apple ID password."
            fi
            echo ""
            prompt_notary_credentials

            # Save a profile so future runs need no prompt. Best effort:
            # macOS refuses this write over SSH even with the keychain
            # unlocked, which must never block a release.
            if xcrun notarytool store-credentials "$PROFILE" \
                    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
                    --password "$APP_PASSWORD" >/dev/null 2>&1; then
                echo "  Saved profile '$PROFILE' for next time."
                NOTARY_ARGS="--keychain-profile $PROFILE"
            else
                echo "  (Keychain wouldn't store the profile — macOS blocks"
                echo "   that write over SSH. Using the credentials directly"
                echo "   for this run.)"
                # NB: this puts the password in this process's argv, which
                # is readable via `ps` by other users on the machine for
                # the duration of the submit. The keychain profile avoids
                # that; run once from the desktop session to store it.
                NOTARY_ARGS="--apple-id $APPLE_ID --team-id $TEAM_ID --password $APP_PASSWORD"
            fi
        fi

        echo "  Submitting for notarization (this waits for Apple)..."
        # shellcheck disable=SC2086
        if xcrun notarytool submit "$DMG_PATH" $NOTARY_ARGS --wait; then
            NOTARIZED=1
            unset APP_PASSWORD
            break
        fi
        # Failed. Drop the credentials and go round again.
        NOTARY_ARGS=""
        unset APP_PASSWORD
    done

    if [ "$NOTARIZED" != "1" ]; then
        echo "  Notarization did not succeed after 3 attempts." >&2
        echo "  The DMG at $DMG_PATH is signed but NOT notarized:" >&2
        echo "  Gatekeeper will refuse it on other Macs." >&2
        exit 1
    fi

    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
    echo "  Notarized and stapled."
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
