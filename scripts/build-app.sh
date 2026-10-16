#!/bin/bash
# Builds "Terminal Manager.app" into ./build. Run on macOS with Xcode 26 (or its command line tools).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Terminal Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TerminalManager" "$APP/Contents/MacOS/TerminalManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS lets the app post notifications.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Install with:  cp -R \"$APP\" /Applications/"
