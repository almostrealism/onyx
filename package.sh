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

# The version comes from Sources/OnyxVersion/OnyxVersion.swift — the same
# constant the app and the MCP bridge compile in. Reading it here is what
# keeps the bundle, the bridge and the tag from drifting apart.
#
# The BUILD identifier beside it is a commit COUNT plus the short sha, and
# deliberately not `git describe`: describe names the most recent TAG, so
# on the way to a release — when the new tag doesn't exist yet — every
# build announced itself as the PREVIOUS version ("0.16-65-g42764a1")
# while the bundle inside it was 0.17. A number that is wrong until
# someone remembers to tag is the same class of mistake as a version
# constant kept in two files.
onyx_version() {
    sed -n 's/.*public static let current = "\(.*\)".*/\1/p' \
        "Sources/OnyxVersion/OnyxVersion.swift" | head -1
}
VERSION="$(onyx_version)"
[ -n "$VERSION" ] || VERSION="0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet 2>/dev/null || COMMIT="$COMMIT-dirty"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

echo ""
echo "  $APP_NAME $VERSION  (build $BUILD_NUMBER, $COMMIT)"
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

# ------------------------------------------------- MCP bridge payload
#
# The app installs this bridge onto remote hosts in one click, so the
# binaries have to travel inside the bundle. The macOS one is built right
# here; the Linux ones are built on Linux by .github/workflows/
# mcp-binaries.yaml, because cross-compiling Swift to Linux needs the
# swift.org toolchain and a static SDK that Xcode's Swift can't use.
#
# Missing Linux binaries are a WARNING, not an error: a Mac-only bundle
# is still useful, and blocking the release on a CI artifact would be
# worse than shipping without it. The app tells the user plainly when a
# host's architecture isn't carried, rather than failing at install time
# with something cryptic.
MCP_DIR="$APP_BUNDLE/Contents/Resources/mcp"
mkdir -p "$MCP_DIR"
cp "$BUILD_DIR/OnyxMCP" "$MCP_DIR/OnyxMCP-macos-arm64"
chmod +x "$MCP_DIR/OnyxMCP-macos-arm64"

# Linux binaries, in order of preference:
#   1. dist/mcp/            — fetched by hand, or by the step below
#   2. this version's release
#   3. the CI RUN on master — the case that matters when packaging a
#      version that hasn't been tagged yet, which is every build before a
#      release. The workflow only attaches binaries to a release on a tag,
#      so during packaging the artifacts exist only on the run.
#   4. an older release      — closer to right than shipping none
for arch in linux-x86_64 linux-arm64; do
    if [ -f "$DIST_DIR/mcp/OnyxMCP-$arch" ]; then
        cp "$DIST_DIR/mcp/OnyxMCP-$arch" "$MCP_DIR/"
    elif command -v gh >/dev/null 2>&1 \
        && gh release download "$VERSION" --pattern "OnyxMCP-$arch" \
             --dir "$MCP_DIR" --clobber >/dev/null 2>&1; then
        :
    elif command -v gh >/dev/null 2>&1 \
        && gh run download --name "OnyxMCP-$arch" --dir "$MCP_DIR" >/dev/null 2>&1; then
        echo "  OnyxMCP-$arch came from the latest 'MCP binaries' run (not yet released)."
    elif command -v gh >/dev/null 2>&1 \
        && gh release download --pattern "OnyxMCP-$arch" \
             --dir "$MCP_DIR" --clobber >/dev/null 2>&1; then
        # This version's release has no bridge yet — the newest one that
        # does is closer to right than shipping none.
        echo "  NOTE: OnyxMCP-$arch came from an older release, not $VERSION."
    else
        echo "  WARNING: no OnyxMCP-$arch — hosts on that architecture"
        echo "           won't be able to install the bridge from this build."
        echo "           Run the 'MCP binaries' workflow, then re-package."
        continue
    fi
    chmod +x "$MCP_DIR/OnyxMCP-$arch"
done
echo "  MCP bridges: $(ls "$MCP_DIR" | tr '\n' ' ')"

# Stamp the real version into the bundle's Info.plist.
#
# Short version is what a person reads (the About panel's "Version 0.17");
# CFBundleVersion is the build, and macOS shows it in parentheses beside
# it and in every crash report — so it has to identify the build without
# ever contradicting the release.
cp "Sources/OnyxApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :OnyxBuildCommit string $COMMIT" "$PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :OnyxBuildCommit $COMMIT" "$PLIST"

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
    <!-- Sending Apple events is blocked by the hardened runtime without
         this. Needed for the iMessage alert-forwarding route, which asks
         Messages.app to text the user. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
PLIST
    # Nested code FIRST, inside-out: the bundle's signature seals its
    # resources, so anything signed after the bundle breaks that seal.
    #
    # The macOS MCP bridge in Contents/Resources/mcp is a real Mach-O
    # executable, and notarization checks every executable in the bundle,
    # not just the app's. Nothing local complains about it being
    # unsigned — `codesign --verify --deep --strict` passes, because to
    # codesign a file in Resources is a resource — so the first sign of
    # trouble is Apple answering "Invalid" several minutes later with no
    # reason attached. That is exactly what happened the first time this
    # bundle carried a bridge.
    #
    # The Linux bridges beside it are ELF: not code as far as macOS is
    # concerned, and codesign refuses them. Hence the macos-* glob.
    for nested in "$MCP_DIR"/OnyxMCP-macos-*; do
        [ -f "$nested" ] || continue
        echo "  Signing $(basename "$nested")..."
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$nested"
    done

    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

    # Ask the question Apple will ask, here, where it costs a second
    # instead of a round trip to Cupertino: is every Mach-O in this
    # bundle signed WITH A DEVELOPER ID and a hardened runtime?
    #
    # "Is it signed" is the wrong question and answers yes: on Apple
    # silicon the linker ad-hoc signs everything it produces, so an
    # untouched binary reports `Signature=adhoc, linker-signed` and
    # passes `codesign --verify --strict` cleanly. Notarization wants a
    # real identity and the runtime flag, and says so only afterwards.
    BAD=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$(/usr/bin/file -b "$f" 2>/dev/null)" in
            *Mach-O*) ;;
            *) continue ;;
        esac
        info="$(codesign -dvvv "$f" 2>&1 || true)"
        case "$info" in
            *"Authority=Developer ID Application"*) ;;
            *) BAD="$BAD
  $f
      not signed with a Developer ID (ad-hoc or unsigned)"
               continue ;;
        esac
        if ! printf '%s' "$info" | grep -q '^CodeDirectory .*flags=[^ ]*runtime'; then
            BAD="$BAD
  $f
      signed without the hardened runtime"
        fi
    done <<EOF
$(find "$APP_BUNDLE" -type f)
EOF
    if [ -n "$BAD" ]; then
        echo "  ERROR: executables Apple will reject:" >&2
        printf '%s\n' "$BAD" >&2
        echo "  Notarization would return \"Invalid\" for these, minutes" >&2
        echo "  from now, and name them only in its log." >&2
        exit 1
    fi
    echo "  Every executable in the bundle is Developer ID signed, hardened."
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
        # `notarytool submit --wait` EXITS 0 FOR A REJECTED SUBMISSION:
        # it succeeded at submitting and at waiting, and the verdict is
        # in its output, not its exit status. Trusting the exit status
        # sent a DMG Apple had called Invalid straight on to `stapler`,
        # which failed with a CloudKit "Record not found" — the ticket
        # doesn't exist because there is no ticket — and that is the
        # error a person was left holding.
        SUBMIT_LOG="$(mktemp)"
        # shellcheck disable=SC2086
        xcrun notarytool submit "$DMG_PATH" $NOTARY_ARGS --wait >"$SUBMIT_LOG" 2>&1 || true
        cat "$SUBMIT_LOG"
        SUB_ID="$(sed -n 's/^ *id: *\([0-9a-fA-F-]*\).*/\1/p' "$SUBMIT_LOG" | head -1)"
        SUB_STATUS="$(sed -n 's/^ *status: *\(.*\)$/\1/p' "$SUBMIT_LOG" \
            | tail -1 | tr -d '\r')"
        rm -f "$SUBMIT_LOG"

        if [ "$SUB_STATUS" = "Accepted" ]; then
            NOTARIZED=1
            unset APP_PASSWORD
            break
        fi

        if [ -n "$SUB_STATUS" ]; then
            # Apple answered, so the credentials were fine and retrying
            # changes nothing. What's wrong is the bundle, and the log
            # says which file — the one thing the status never does.
            echo ""
            echo "  Apple returned: $SUB_STATUS"
            if [ -n "$SUB_ID" ]; then
                echo "  Asking Apple why (submission $SUB_ID)..."
                # shellcheck disable=SC2086
                xcrun notarytool log "$SUB_ID" $NOTARY_ARGS 2>&1 | head -80
            fi
            unset APP_PASSWORD
            break
        fi

        # No status at all: the submission never happened — bad
        # credentials, no network. Drop them and go round again.
        NOTARY_ARGS=""
        unset APP_PASSWORD
    done

    if [ "$NOTARIZED" != "1" ]; then
        echo "" >&2
        echo "  Notarization did not succeed." >&2
        echo "  The DMG at $DMG_PATH is signed but NOT notarized:" >&2
        echo "  Gatekeeper will refuse it on other Macs." >&2
        echo "  The log above names the files Apple objected to; fix those" >&2
        echo "  and run this again. Nothing was stapled." >&2
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
