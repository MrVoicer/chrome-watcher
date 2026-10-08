#!/bin/bash
# Builds a release binary and wraps it in build/ChromeWatch.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin="$(swift build -c release --show-bin-path)/ChromeWatch"
app="build/ChromeWatch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/ChromeWatch"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier dev.chromewatch.ChromeWatch "$app"
echo "Built $app"
