#!/bin/bash
#
# Build, sign and deliver the iOS app (iPhone and iPad: one app, the root
# picks by idiom — docs/ios-today.md).
#
#   ./package-ios.sh               → development build, installed on the
#                                    iPad or iPhone connected to this Mac
#   ./package-ios.sh --testflight  → App Store build, uploaded to
#                                    App Store Connect for TestFlight
#   ./package-ios.sh --list        → the devices this Mac can install to
#
# Run it as the user whose Apple developer account signs Onyx: the
# certificate and Xcode's account sign-in are that user's, in that user's
# keychain. Over SSH it unlocks the login keychain first, as package.sh does.
#
# Nothing secret belongs in this repo, and nothing here asks for a password
# except the keychain's own unlock prompt:
#
#   ONYX_TEAM_ID         Apple Developer team ID. Defaults to the one
#                        package.sh saved in ~/.onyx-notary.conf.
#   ONYX_IOS_BUNDLE_ID   Defaults to com.onyx.today. Change it if that id
#                        isn't yours to register.
#   ONYX_IOS_DEVICE      The device to install on (name or UDID, from
#                        --list). Defaults to the only one connected.
#
# Signing is Xcode's automatic signing: it creates the Apple Development /
# Distribution certificate, registers the bundle id and the device, and
# makes the profiles. It needs to sign in to Apple as you, one of two ways:
#
#   1. Xcode → Settings → Accounts, signed in once as this user. Nothing
#      else to set.
#   2. An App Store Connect API key (Users and Access → Integrations →
#      Team Keys, role Admin) — the way to go if you only ever reach this
#      Mac over SSH:
#        ONYX_ASC_KEY_PATH   the AuthKey_XXXX.p8 file (keep it out of the repo)
#        ONYX_ASC_KEY_ID     its key id
#        ONYX_ASC_ISSUER_ID  the issuer id shown above the key list
#
set -e
cd "$(dirname "$0")"

. scripts/lib/packaging.sh
trap restore_keychain EXIT

PROJECT="Apps/OnyxToday/OnyxToday.xcodeproj"
SCHEME="TodayApp"
DIST_DIR="dist/ios"
# Our own DerivedData, in the CALLER's home: this checkout is shared
# between accounts, and a build directory one account wrote is one the
# other may not be able to overwrite.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/onyx-ios-package"

MODE="install"
for arg in "$@"; do
    case "$arg" in
        --testflight) MODE="testflight" ;;
        --list)       MODE="list" ;;
        -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------- devices
# `devicectl` knows every device this Mac is paired with, connected now or
# not. Only a connected one can be installed to.
DEVICES_JSON="$(mktemp)"
list_devices() {
    xcrun devicectl list devices --quiet --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
    /usr/bin/python3 -I - "$DEVICES_JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        continue
    print("\t".join([hw.get("udid", ""), props.get("name", ""), hw.get("marketingName", hw.get("deviceType", "")),
                     props.get("osVersionNumber", ""), conn.get("pairingState", ""), conn.get("transportType", "") or "-",
                     "yes" if props.get("developerModeStatus") == "enabled" else "no"]))
PY
}

if [ "$MODE" = "list" ]; then
    DEVS="$(list_devices)"
    if [ -z "$DEVS" ]; then
        echo "  No iPhone or iPad is known to this Mac. Connect one by cable and"
        echo "  tap Trust on it."
    else
        printf '  %-27s %-20s %-22s %-6s %-9s %-10s %s\n' UDID NAME MODEL IOS PAIRING TRANSPORT DEVMODE
        printf '%s\n' "$DEVS" | while IFS="$(printf '\t')" read -r u n m o p t dm; do
            printf '  %-27s %-20s %-22s %-6s %-9s %-10s %s\n' "$u" "$n" "$m" "$o" "$p" "$t" "$dm"
        done
    fi
    rm -f "$DEVICES_JSON"; exit 0
fi

# ---------------------------------------------------------------- team
NOTARY_CONF="$HOME/.onyx-notary.conf"
[ -f "$NOTARY_CONF" ] && . "$NOTARY_CONF"
TEAM_ID="${ONYX_TEAM_ID:-${SAVED_TEAM_ID:-}}"
if [ -z "$TEAM_ID" ]; then
    ask TEAM_ID "  Apple Developer team ID: "
    [ -n "$TEAM_ID" ] || { echo "  A team ID is needed to sign." >&2; exit 1; }
fi
BUNDLE_ID="${ONYX_IOS_BUNDLE_ID:-com.onyx.today}"

AUTH_ARGS=()
if [ -n "${ONYX_ASC_KEY_PATH:-}" ]; then
    [ -f "$ONYX_ASC_KEY_PATH" ] || { echo "  ONYX_ASC_KEY_PATH: no such file: $ONYX_ASC_KEY_PATH" >&2; exit 1; }
    [ -n "${ONYX_ASC_KEY_ID:-}" ] && [ -n "${ONYX_ASC_ISSUER_ID:-}" ] || {
        echo "  ONYX_ASC_KEY_PATH needs ONYX_ASC_KEY_ID and ONYX_ASC_ISSUER_ID beside it." >&2; exit 1; }
    AUTH_ARGS=(-authenticationKeyPath "$ONYX_ASC_KEY_PATH"
               -authenticationKeyID "$ONYX_ASC_KEY_ID"
               -authenticationKeyIssuerID "$ONYX_ASC_ISSUER_ID")
    AUTH_DESC="App Store Connect API key $ONYX_ASC_KEY_ID"
else
    AUTH_DESC="Xcode's signed-in account"
fi

echo ""
echo "  Onyx for iOS $VERSION  (build $BUILD_NUMBER, $COMMIT)"
echo "  Team $TEAM_ID, bundle id $BUNDLE_ID, signing in with $AUTH_DESC"
echo ""

ensure_keychain_unlocked "codesign and Xcode's account need it"

# Every build: automatic signing for this team, the build number that
# package.sh gives the Mac (TestFlight refuses a number it has seen), and
# SwiftTerm's build plugin trusted without the GUI prompt Xcode would show.
COMMON=(-project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DERIVED"
        -allowProvisioningUpdates -skipPackagePluginValidation
        "${AUTH_ARGS[@]}"
        DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

# xcodebuild's own output is thousands of lines; keep it in a log and show
# the part that matters when it fails.
mkdir -p "$DIST_DIR"
LOG="$DIST_DIR/xcodebuild.log"
run_xcodebuild() {   # run_xcodebuild WHAT ARGS...
    __what="$1"; shift
    echo "  $__what... (log: $LOG)"
    if ! xcodebuild "$@" >"$LOG" 2>&1; then
        echo "" >&2
        echo "  $__what failed. The errors:" >&2
        grep -E "error:|Error Domain|No Accounts|No profiles|requires a provisioning|not registered|Signing for" "$LOG" \
            | grep -v "^note:" | sort -u | head -20 | sed 's/^/    /' >&2
        if grep -q "No Accounts\|No account for team\|Your session has expired" "$LOG"; then
            echo "" >&2
            echo "  → Xcode isn't signed in to Apple as this user. Open Xcode →" >&2
            echo "    Settings → Accounts and add your Apple ID, or set the" >&2
            echo "    ONYX_ASC_KEY_* variables (see ./package-ios.sh --help)." >&2
        fi
        if grep -qi "bundle identifier.*not available\|cannot be registered\|already in use" "$LOG"; then
            echo "" >&2
            echo "  → $BUNDLE_ID belongs to someone else. Pick one under a name" >&2
            echo "    you own: ONYX_IOS_BUNDLE_ID=com.<you>.onyx ./package-ios.sh" >&2
        fi
        echo "" >&2
        echo "  Full log: $LOG" >&2
        exit 1
    fi
}

# -------------------------------------------------------------- install
if [ "$MODE" = "install" ]; then
    DEVS="$(list_devices)"
    if [ -n "${ONYX_IOS_DEVICE:-}" ]; then
        LINE="$(printf '%s\n' "$DEVS" | awk -F'\t' -v w="$ONYX_IOS_DEVICE" '$1==w || $2==w' | head -1)"
        [ -n "$LINE" ] || { echo "  No device named or numbered '$ONYX_IOS_DEVICE'. ./package-ios.sh --list shows them." >&2; exit 1; }
    else
        COUNT="$(printf '%s' "$DEVS" | grep -c . || true)"
        if [ "$COUNT" = "0" ]; then
            echo "  No iPhone or iPad is known to this Mac." >&2
            echo "  Connect the iPad to this Mac by cable, unlock it and tap Trust," >&2
            echo "  then run this again. (After the first time, the same Wi-Fi is enough.)" >&2
            echo "  Or send a build to TestFlight instead: ./package-ios.sh --testflight" >&2
            exit 1
        elif [ "$COUNT" != "1" ]; then
            echo "  More than one device; choose with ONYX_IOS_DEVICE=<name or UDID>:" >&2
            printf '%s\n' "$DEVS" | awk -F'\t' '{print "    " $2 "  (" $3 ", " $1 ")"}' >&2
            exit 1
        fi
        LINE="$DEVS"
    fi
    UDID="$(printf '%s' "$LINE" | cut -f1)"
    NAME="$(printf '%s' "$LINE" | cut -f2)"
    DEVMODE="$(printf '%s' "$LINE" | cut -f7)"
    echo "  Device: $NAME ($UDID)"
    if [ "$DEVMODE" != "yes" ]; then
        echo "  NOTE: Developer Mode looks off on $NAME. The install will be refused"
        echo "        until it's on: Settings → Privacy & Security → Developer Mode"
        echo "        (it restarts the device)."
    fi

    run_xcodebuild "Building for $NAME" "${COMMON[@]}" \
        -configuration Debug -destination "id=$UDID" \
        -allowProvisioningDeviceRegistration build
    APP="$(find "$DERIVED/Build/Products/Debug-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
    [ -d "$APP" ] || { echo "  The build finished but no .app came out of it." >&2; exit 1; }

    echo "  Installing on $NAME..."
    xcrun devicectl device install app --device "$UDID" "$APP"
    echo "  Launching..."
    if ! xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
        # The first install from a new developer can't launch until the
        # device trusts that developer — a step only the device can take.
        echo "  Installed, but it wouldn't launch. If this is the first build"
        echo "  signed by you on $NAME: Settings → General → VPN & Device"
        echo "  Management → your developer certificate → Trust, then open it."
    fi
    rm -f "$DEVICES_JSON"
    echo ""
    echo "  Onyx $VERSION ($BUILD_NUMBER) is on $NAME."
    echo ""
    exit 0
fi

# ----------------------------------------------------------- testflight
ARCHIVE="$DIST_DIR/Onyx-iOS-$VERSION-$BUILD_NUMBER.xcarchive"
rm -rf "$ARCHIVE"
run_xcodebuild "Archiving" "${COMMON[@]}" \
    -configuration Release -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" archive

# Export straight to App Store Connect: Xcode signs for distribution and
# uploads in one step. The app has to exist in App Store Connect first
# (Apps → + → New App, with this bundle id); the archive above has already
# registered the id, so it's in that form's list.
EXPORT_OPTIONS="$DIST_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>                        <string>app-store-connect</string>
    <key>destination</key>                   <string>upload</string>
    <key>teamID</key>                        <string>$TEAM_ID</string>
    <key>signingStyle</key>                  <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key>                 <true/>
</dict>
</plist>
PLIST
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$DIST_DIR/export" -allowProvisioningUpdates "${AUTH_ARGS[@]}" >"$LOG" 2>&1; then
    echo "" >&2
    echo "  Uploading failed:" >&2
    grep -E "error:|Error Domain" "$LOG" | sort -u | head -15 | sed 's/^/    /' >&2
    if grep -qi "no suitable application records\|application record" "$LOG"; then
        echo "" >&2
        echo "  → App Store Connect has no app for $BUNDLE_ID yet. Create it at" >&2
        echo "    https://appstoreconnect.apple.com → Apps → + → New App (iOS," >&2
        echo "    bundle id $BUNDLE_ID), then run this again. The archive is" >&2
        echo "    kept at $ARCHIVE." >&2
    fi
    if grep -qi "bundle version must be higher\|has already been used" "$LOG"; then
        echo "" >&2
        echo "  → Build $BUILD_NUMBER was uploaded before. Commit, then run again." >&2
    fi
    echo "  Full log: $LOG" >&2
    exit 1
fi
rm -f "$DEVICES_JSON"
echo ""
echo "  Uploaded Onyx $VERSION ($BUILD_NUMBER). App Store Connect processes it"
echo "  for a few minutes; it then appears under TestFlight, where you add"
echo "  yourself as a tester (internal testers need no review)."
echo ""
