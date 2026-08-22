#!/bin/bash
#
# Publish an Onyx release to GitHub: tag, notes, and the DMG people
# actually download.
#
#   ./release.sh              → the version of the most recent tag
#   ./release.sh 0.15         → that version
#   ./release.sh 0.15 --draft → create it as a draft first
#
# The contract, same as package.sh: this finishes with a published
# release whose DMG URL resolves, or it keeps asking you for what it
# needs. It never stops to tell you to go run something yourself, and it
# never leaves a half-made release behind without saying so.
#
# What it will ask for, only when it can't work it out:
#   - the tag, if the version isn't tagged or the tag isn't pushed
#   - the DMG, if dist/ doesn't have one (offers to build it)
#   - a GitHub token, if `gh` isn't logged in. A token is used for this
#     run only and never written to disk. Create one at
#     https://github.com/settings/tokens with the `repo` scope.
#
# The download URL on the marketing site is built from the version and
# the asset name (onyx-web/src/config/site.ts), so the asset MUST be
# named Onyx-<version>.dmg. The last thing this script does is fetch
# that exact URL and tell you what it returned.
#
set -e

DIST_DIR="dist"
DRAFT=0
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --draft)   DRAFT=1 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        -*)        echo "unknown option: $arg" >&2; exit 2 ;;
        *)         VERSION="$arg" ;;
    esac
done

# Read an answer from the user. Prefers the controlling terminal so a
# prompt still works when stdin is redirected, but falls back to stdin
# when there ISN'T a terminal instead of looping on empty answers.
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

confirm() {   # confirm "question" [default_yes]
    if [ "${2:-}" = "yes" ]; then __hint="[Y/n]"; else __hint="[y/N]"; fi
    ask __reply "$1 $__hint "
    case "$__reply" in
        [Yy]*) return 0 ;;
        "")    [ "${2:-}" = "yes" ] && return 0 || return 1 ;;
        *)     return 1 ;;
    esac
}

# ---------------------------------------------------------------------
# 1. Which version
# ---------------------------------------------------------------------
echo "==> Version"

if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$VERSION" ]; then
        ask REPLY_V "  Version to release [$VERSION]: "
        VERSION="${REPLY_V:-$VERSION}"
    else
        while [ -z "$VERSION" ]; do ask VERSION "  Version to release (e.g. 0.15): "; done
    fi
fi
VERSION="${VERSION#v}"
echo "  Releasing $VERSION"

DMG="$DIST_DIR/Onyx-$VERSION.dmg"
NOTES="docs/release-notes-$VERSION.md"

# ---------------------------------------------------------------------
# 2. The repository and the credentials to write to it
# ---------------------------------------------------------------------
echo ""
echo "==> GitHub"

# Derive owner/name from origin. Works for both SSH and HTTPS remotes,
# and doesn't depend on gh's repo auto-detection (which needs the cwd to
# be inside the checkout with a recognised remote).
ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
REPO="$(printf '%s' "$ORIGIN" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
if [ -z "$REPO" ] || [ "$REPO" = "$ORIGIN" ]; then
    while [ -z "$REPO" ]; do ask REPO "  Repository (owner/name): "; done
fi
echo "  Repository: $REPO"

GH_OK=0
TOKEN=""

if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        GH_OK=1
        echo "  gh: authenticated"
    fi
fi

# Not logged in (or no gh at all) → get a token. `gh auth login --web`
# is deliberately not offered: this is routinely run over SSH, where a
# browser flow has nowhere to open.
if [ "$GH_OK" = "0" ]; then
    TOKEN="${ONYX_GH_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
    if [ -n "$TOKEN" ]; then
        echo "  Using token from the environment."
    else
        echo "  Not logged in to GitHub."
        echo "  A personal access token with the 'repo' scope will do:"
        echo "    https://github.com/settings/tokens"
        while [ -z "$TOKEN" ]; do ask TOKEN "  GitHub token: " --secret; done
    fi

    if command -v gh >/dev/null 2>&1; then
        if printf '%s' "$TOKEN" | gh auth login --hostname github.com --with-token 2>/dev/null; then
            GH_OK=1
            echo "  gh: logged in with the token."
        else
            echo "  gh rejected the token; using the REST API directly."
        fi
    fi
    export GH_TOKEN="$TOKEN"
fi

# Everything below goes through these two, so the gh-present and
# gh-absent paths can't drift apart.
api() {   # api METHOD PATH [json-body]
    if [ "$GH_OK" = "1" ]; then
        if [ -n "${3:-}" ]; then
            printf '%s' "$3" | gh api --method "$1" "$2" --input - 2>&1
        else
            gh api --method "$1" "$2" 2>&1
        fi
    else
        if [ -n "${3:-}" ]; then
            curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" \
                 -H "Accept: application/vnd.github+json" \
                 -d "$3" "https://api.github.com/$2"
        else
            curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" \
                 -H "Accept: application/vnd.github+json" \
                 "https://api.github.com/$2"
        fi
    fi
}

json_field() {   # json_field FIELD  (reads JSON on stdin)
    python3 -c "import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
v = d.get('$1', '') if isinstance(d, dict) else ''
print(v if v is not None else '')"
}

# ---------------------------------------------------------------------
# 3. The tag — it must exist locally AND on the remote
# ---------------------------------------------------------------------
echo ""
echo "==> Tag"

if ! git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "  No local tag '$VERSION'."
    if confirm "  Create it at HEAD ($(git rev-parse --short HEAD))?" yes; then
        git tag "$VERSION"
        echo "  Tagged."
    else
        echo "  A release needs a tag. Nothing else can proceed." >&2
        exit 1
    fi
fi

LOCAL_SHA="$(git rev-parse "refs/tags/$VERSION^{commit}")"
REMOTE_LINE="$(git ls-remote --tags origin "refs/tags/$VERSION" 2>/dev/null || true)"

if [ -z "$REMOTE_LINE" ]; then
    echo "  Tag '$VERSION' is not on origin."
    if confirm "  Push it?" yes; then
        git push origin "refs/tags/$VERSION"
        echo "  Pushed."
    else
        # GitHub would create the tag itself from target_commitish, which
        # is a silent way to end up with a release pointing somewhere the
        # local tag doesn't. Better to stop.
        echo "  GitHub can't attach a release to a tag it can't see." >&2
        exit 1
    fi
else
    # ls-remote reports the tag OBJECT for annotated tags; ^{} is the
    # commit it points at. Compare against whichever we got.
    REMOTE_SHA="$(git ls-remote --tags origin "refs/tags/$VERSION^{}" 2>/dev/null | awk '{print $1}')"
    [ -z "$REMOTE_SHA" ] && REMOTE_SHA="$(printf '%s' "$REMOTE_LINE" | awk '{print $1}')"
    if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
        echo "  WARNING: local tag is $LOCAL_SHA but origin has $REMOTE_SHA."
        echo "  The release will describe whatever origin has."
        confirm "  Continue anyway?" || exit 1
    else
        echo "  Tag $VERSION → $LOCAL_SHA (matches origin)"
    fi
fi

# ---------------------------------------------------------------------
# 4. The DMG
# ---------------------------------------------------------------------
echo ""
echo "==> Disk image"

if [ ! -f "$DMG" ]; then
    echo "  $DMG not found."
    OTHER="$(ls -t "$DIST_DIR"/*.dmg 2>/dev/null | head -1 || true)"
    if [ -n "$OTHER" ]; then
        echo "  Found $OTHER."
        if confirm "  Use it (it will be uploaded as Onyx-$VERSION.dmg)?" yes; then
            cp "$OTHER" "$DMG"
        fi
    fi
fi

if [ ! -f "$DMG" ]; then
    if confirm "  Build it now with ./package.sh?" yes; then
        if confirm "  Sign and notarize (needed for other people's Macs)?" yes; then
            ./package.sh --notarize
        else
            ./package.sh
        fi
    fi
fi

while [ ! -f "$DMG" ]; do
    echo "  Still no $DMG."
    ask DMG_PATH "  Path to the disk image (or blank to build): "
    if [ -z "$DMG_PATH" ]; then
        ./package.sh --notarize
    elif [ -f "$DMG_PATH" ]; then
        [ "$DMG_PATH" = "$DMG" ] || cp "$DMG_PATH" "$DMG"
    else
        echo "  No file at '$DMG_PATH'."
    fi
done

SIZE="$(du -h "$DMG" | awk '{print $1}')"
echo "  $DMG ($SIZE)"

# Gatekeeper's verdict, not ours. An un-notarized DMG downloads fine and
# then refuses to open on every Mac but this one — worth knowing BEFORE
# it's the thing the website points at.
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "  Notarization: stapled ✓"
else
    echo "  Notarization: NOT stapled."
    echo "  Downloaders will get \"Apple could not verify Onyx is free of malware\"."
    if confirm "  Notarize it now (./package.sh --notarize)?" yes; then
        ./package.sh --notarize
        xcrun stapler validate "$DMG" >/dev/null 2>&1 \
            && echo "  Notarization: stapled ✓" \
            || { echo "  Still not stapled."; confirm "  Publish it anyway?" || exit 1; }
    else
        confirm "  Publish an un-notarized DMG anyway?" || exit 1
    fi
fi

# ---------------------------------------------------------------------
# 5. The notes
# ---------------------------------------------------------------------
echo ""
echo "==> Release notes"

if [ ! -f "$NOTES" ]; then
    echo "  $NOTES not found."
    ask NOTES_PATH "  Path to a notes file (blank = generate from commits): "
    if [ -n "$NOTES_PATH" ] && [ -f "$NOTES_PATH" ]; then
        NOTES="$NOTES_PATH"
    else
        PREV="$(git describe --tags --abbrev=0 "$VERSION^" 2>/dev/null || true)"
        NOTES="$(mktemp)"
        {
            echo "## Onyx $VERSION"
            echo ""
            if [ -n "$PREV" ]; then
                git log --no-merges --pretty='- %s' "$PREV..$VERSION"
            else
                git log --no-merges --pretty='- %s' "$VERSION" | head -50
            fi
        } > "$NOTES"
        echo "  Generated from commits${PREV:+ since $PREV}."
    fi
fi
echo "  Using $NOTES ($(wc -l < "$NOTES" | tr -d ' ') lines)"

# ---------------------------------------------------------------------
# 6. Create (or update) the release, then attach the DMG
# ---------------------------------------------------------------------
echo ""
echo "==> Publishing"

echo "  repository : $REPO"
echo "  tag        : $VERSION ($LOCAL_SHA)"
echo "  asset      : Onyx-$VERSION.dmg ($SIZE)"
echo "  notes      : $NOTES"
echo "  visibility : $([ "$DRAFT" = "1" ] && echo draft || echo PUBLIC)"
echo ""
# The last point at which nothing has happened. Everything above this
# line only read state (the tag push aside, which was asked for on its
# own); everything below is visible to the world.
confirm "  Publish this?" yes || { echo "  Nothing published."; exit 0; }
echo ""

EXISTING="$(api GET "repos/$REPO/releases/tags/$VERSION" 2>/dev/null | json_field id || true)"

if [ -n "$EXISTING" ]; then
    echo "  Release $VERSION already exists (id $EXISTING)."
    confirm "  Update its notes and replace the DMG?" yes || exit 0
    UPDATE_NOTES=1
else
    UPDATE_NOTES=0
fi

if [ "$GH_OK" = "1" ]; then
    if [ -z "$EXISTING" ]; then
        CREATE_ARGS=(--repo "$REPO" --title "Onyx $VERSION" --notes-file "$NOTES")
        [ "$DRAFT" = "1" ] && CREATE_ARGS+=(--draft)
        gh release create "$VERSION" "${CREATE_ARGS[@]}" "$DMG"
    else
        [ "$UPDATE_NOTES" = "1" ] && gh release edit "$VERSION" --repo "$REPO" --notes-file "$NOTES" >/dev/null
        gh release upload "$VERSION" "$DMG" --repo "$REPO" --clobber
    fi
else
    # No gh: the same two calls against the REST API.
    BODY="$(python3 -c "import json,sys
notes = open(sys.argv[1]).read()
print(json.dumps({'tag_name': sys.argv[2], 'name': 'Onyx ' + sys.argv[2],
                  'body': notes, 'draft': sys.argv[3] == '1'}))" "$NOTES" "$VERSION" "$DRAFT")"

    if [ -z "$EXISTING" ]; then
        EXISTING="$(api POST "repos/$REPO/releases" "$BODY" | json_field id)"
        [ -n "$EXISTING" ] || { echo "  Could not create the release." >&2; exit 1; }
        echo "  Created release id $EXISTING."
    elif [ "$UPDATE_NOTES" = "1" ]; then
        api PATCH "repos/$REPO/releases/$EXISTING" "$BODY" >/dev/null
    fi

    # Replace an asset of the same name rather than letting GitHub
    # rename the new one to Onyx-0.15.dmg.1 — the site links to the
    # exact name, so a rename is a broken link that looks like a success.
    OLD_ID="$(api GET "repos/$REPO/releases/$EXISTING/assets" | python3 -c "import json,sys
try: assets = json.load(sys.stdin)
except Exception: sys.exit(0)
for a in assets if isinstance(assets, list) else []:
    if a.get('name') == 'Onyx-$VERSION.dmg': print(a['id'])")"
    [ -n "$OLD_ID" ] && api DELETE "repos/$REPO/releases/assets/$OLD_ID" >/dev/null

    echo "  Uploading $(basename "$DMG") ($SIZE)..."
    curl -sS -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$DMG" \
        "https://uploads.github.com/repos/$REPO/releases/$EXISTING/assets?name=Onyx-$VERSION.dmg" \
        >/dev/null
fi

# ---------------------------------------------------------------------
# 7. Prove the link the website uses actually works
# ---------------------------------------------------------------------
echo ""
echo "==> Verifying the download link"

URL="https://github.com/$REPO/releases/download/$VERSION/Onyx-$VERSION.dmg"
echo "  $URL"

if [ "$DRAFT" = "1" ]; then
    echo "  Draft release — the download URL stays 404 until you publish it:"
    echo "    gh release edit $VERSION --repo $REPO --draft=false"
    exit 0
fi

# -L because the asset is a redirect to objects.githubusercontent.com,
# and the redirect target is what a browser actually fetches.
CODE="$(curl -sIL -o /dev/null -w '%{http_code}' "$URL" || echo 000)"
if [ "$CODE" = "200" ]; then
    echo "  HTTP $CODE ✓  the site's download button works."
else
    echo "  HTTP $CODE ✗  that is what a visitor's browser will get."
    echo "  The release exists but the asset isn't reachable under that name."
    echo "  Check the asset list:  gh release view $VERSION --repo $REPO"
    exit 1
fi

echo ""
echo "Released: https://github.com/$REPO/releases/tag/$VERSION"
