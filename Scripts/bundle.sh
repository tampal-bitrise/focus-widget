#!/bin/bash
# Builds a release binary and wraps it in build/FocusWidget.app (menu bar only, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/FocusWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/FocusWidget" "$APP/Contents/MacOS/FocusWidget"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc signature so macOS treats the bundle as a stable identity (needed for Launch at Login).
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; the app still runs" >&2

echo "Built $APP"
