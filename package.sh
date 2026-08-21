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
#   ONYX_APPLE_ID        Apple ID used for notarization.
#   ONYX_NOTARY_PROFILE  Preferred over ONYX_APPLE_ID: a notarytool
#                        keychain profile created once with
#                        `xcrun notarytool store-credentials`.
#                        Then no password ever appears in a command line.
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
    if [ -n "${ONYX_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$ONYX_NOTARY_PROFILE" --wait
    elif [ -n "${ONYX_APPLE_ID:-}" ] && [ -n "${ONYX_TEAM_ID:-}" ]; then
        # Password is read from the keychain item, never passed here.
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$ONYX_APPLE_ID" --team-id "$ONYX_TEAM_ID" \
            --password "@keychain:ONYX_NOTARY_PASSWORD" --wait
    else
        echo "  ERROR: set ONYX_NOTARY_PROFILE (preferred), or both" >&2
        echo "  ONYX_APPLE_ID and ONYX_TEAM_ID with the app-specific" >&2
        echo "  password stored in the keychain as ONYX_NOTARY_PASSWORD." >&2
        echo "  Create a profile once with:" >&2
        echo "    xcrun notarytool store-credentials ONYX --apple-id … --team-id …" >&2
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
