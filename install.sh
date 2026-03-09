#!/bin/bash
set -e

APP_NAME="Onyx"
INSTALL_DIR="/Applications"
BUILD_DIR=".build/release"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "  Building $APP_NAME..."
echo ""

swift build -c release

echo ""
echo "  Creating app bundle..."
echo ""

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "Sources/OnyxApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Sign ad-hoc (required on Apple Silicon)
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo ""
echo "  Installed to $APP_BUNDLE"
echo "  You can now open Onyx from Applications or Spotlight."
echo ""
