# Shared by package.sh (the Mac app) and package-ios.sh (the iOS app).
# Sourced, not run. Everything here is about the person running the build —
# their keychain, their answers, this checkout's version — and nothing in it
# is secret.

# ------------------------------------------------------------- version
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

# ------------------------------------------------------------ keychain
# Put the keychain's lock behaviour back however we leave — including on
# a failed signature, which is exactly when you'd forget. `set-keychain-
# settings` with no -lut restores lock-on-sleep; leaving an hour-long
# window open on someone's desktop because a build failed would be rude.
KEYCHAIN_PATH="${ONYX_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

keychain_locked() {
    [ -f "$KEYCHAIN_PATH" ] || return 1          # no keychain: nothing to unlock
    ! security show-keychain-info "$KEYCHAIN_PATH" >/dev/null 2>&1
}

# Unlock if needed. Over SSH the login keychain stays LOCKED after login,
# and codesign can't reach the private key: it fails with "User interaction
# is not allowed" rather than anything mentioning the keychain. notarytool
# and Xcode's own account tokens live there too, so a keychain that
# re-locked during a long build breaks them just as surely.
#
# `security unlock-keychain` with no -p reads from the tty, which is what
# makes this work over SSH; it's the GUI prompt that isn't allowed.
# Skipped when the keychain is already unlocked, so a desktop run is
# untouched.
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

# ----------------------------------------------------------------- ask
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
