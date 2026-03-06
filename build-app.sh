#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="UsageBar"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME in release mode..."
swift build -c release --package-path "$SCRIPT_DIR"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/UsageBarApp" "$APP_BUNDLE/Contents/MacOS/UsageBarApp"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "App bundle created at: $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "To open:"
echo "  open \"$APP_BUNDLE\""
