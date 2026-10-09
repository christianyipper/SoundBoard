#!/bin/bash
# Builds Scorely and packages it as a real, double-clickable .app bundle
# (Info.plist + bundle identifier) instead of the bare `swift run` executable.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/Scorely"

APP_DIR="build/Scorely.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Scorely"
cp "Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"
echo "Run it with: open \"$APP_DIR\""
