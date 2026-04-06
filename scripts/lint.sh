#!/usr/bin/env bash
# Onyx lint script.
#
# Downloads a pinned SwiftLint binary release from GitHub on first run,
# caches it under .build/tools/swiftlint/, and runs it against the project
# using .swiftlint.yml at the repository root.
#
# Usage:
#   scripts/lint.sh                # lint everything (warnings allowed)
#   scripts/lint.sh --strict       # warnings cause non-zero exit (CI mode)
#   scripts/lint.sh --fix          # apply auto-fixes
#   scripts/lint.sh -- <args...>   # pass extra args directly to swiftlint
#
# Why a script? See docs/static-analysis.md — the SwiftPM SwiftLint plugins
# (both realm/SwiftLint and SwiftLintPlugins) currently fail with
# "a prebuild command cannot use executables built from source" on Swift 6.x.

set -eo pipefail

SWIFTLINT_VERSION="0.57.1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/.build/tools/swiftlint/$SWIFTLINT_VERSION"
SWIFTLINT_BIN="$TOOLS_DIR/swiftlint"

install_swiftlint() {
    # Prefer a system swiftlint if it matches at least major.minor; otherwise download.
    if command -v swiftlint >/dev/null 2>&1; then
        SWIFTLINT_BIN="$(command -v swiftlint)"
        return
    fi

    if [[ -x "$SWIFTLINT_BIN" ]]; then
        return
    fi

    echo "Downloading SwiftLint $SWIFTLINT_VERSION (one-time setup)..." >&2
    mkdir -p "$TOOLS_DIR"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    local url="https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/SwiftLintBinary-macOS.artifactbundle.zip"
    curl -fsSL "$url" -o "$tmp/swiftlint.zip"
    unzip -q "$tmp/swiftlint.zip" -d "$tmp"

    local found
    found="$(find "$tmp" -type f -name swiftlint -perm +111 | head -1)"
    if [[ -z "$found" ]]; then
        echo "ERROR: could not locate swiftlint binary in artifact bundle" >&2
        exit 1
    fi
    cp "$found" "$SWIFTLINT_BIN"
    chmod +x "$SWIFTLINT_BIN"
}

install_swiftlint

cd "$REPO_ROOT"

MODE="lint"
EXTRA_ARGS=()
STRICT=""
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT="--strict" ;;
        --fix)    MODE="--fix" ;;
        --)       shift; EXTRA_ARGS+=("$@"); break ;;
        *)        EXTRA_ARGS+=("$arg") ;;
    esac
done

if [[ "$MODE" == "--fix" ]]; then
    exec "$SWIFTLINT_BIN" --fix --config "$REPO_ROOT/.swiftlint.yml" "${EXTRA_ARGS[@]}"
fi

exec "$SWIFTLINT_BIN" lint --config "$REPO_ROOT/.swiftlint.yml" $STRICT "${EXTRA_ARGS[@]}"
