#!/bin/sh
# Renders the app icon (an Imp on the dungeon wall) with the Mac's own renderer: builds the app
# for the simulator, runs it once with -renderIcon, and writes the PNG into the asset catalog.
set -eu
cd "$(dirname "$0")/.."
OUT="$PWD/Imp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
DEVICE="${1:-iPhone 18 Pro}"
xcodegen generate >/dev/null
xcodebuild -project ImpPhone.xcodeproj -scheme ImpPhone -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath ../.build/ios CODE_SIGNING_ALLOWED=NO build >/dev/null
APP=../.build/ios/Build/Products/Debug-iphonesimulator/Imp.app
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" >/dev/null
xcrun simctl install "$DEVICE" "$APP"
# Simulator apps share the Mac's filesystem, so the app can write straight to /tmp.
TMP="/tmp/imp-icon.png"
rm -f "$TMP"
xcrun simctl launch "$DEVICE" app.imp.ImpPhone -renderIcon "$TMP" >/dev/null
for _ in $(seq 1 60); do [ -s "$TMP" ] && break; sleep 1; done
cp "$TMP" "$OUT"
echo "wrote $OUT"
