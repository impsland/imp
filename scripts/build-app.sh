#!/usr/bin/env bash
# Builds build/Imp.app (release), renders the icon, and code-signs it.
# Optional: $ARCHS (e.g. "arm64 x86_64" for a universal binary), $VERSION (stamped into Info.plist).
# Signing identity: $IMP_SIGN_IDENTITY (releases: "Imp Release Signing"), else the first
# "Apple Development" identity, else ad-hoc. A stable identity matters: macOS ties Keychain access
# and the Microphone grant to the signature, so ad-hoc builds ask for them again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SWIFT="${SWIFT:-xcrun swift}"
APP="build/Imp.app"
ARCH_FLAGS=""
for arch in ${ARCHS:-}; do ARCH_FLAGS+=" --arch $arch"; done

$SWIFT build -c "$CONFIG" --product Imp $ARCH_FLAGS
BIN="$($SWIFT build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)/Imp"

# Render the icon first, then assemble the bundle in a staging folder and move it into place in
# one step. Building it in place let Finder and LaunchServices see (and cache) a half-made bundle
# whose Info.plist names AppIcon before AppIcon.icns existed; adding files to Contents/Resources
# never changes the bundle folder's date, so that generic icon stuck around.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET"

STAGE="build/.staging/Imp.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Imp"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$STAGE/Contents/Info.plist"
fi
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"

IDENTITY="${IMP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --entitlements Resources/Imp.entitlements --sign "$IDENTITY" "$STAGE"
  echo "Signed with: $IDENTITY"
else
  codesign --force --options runtime --entitlements Resources/Imp.entitlements --sign - "$STAGE"
  echo "Signed ad-hoc (permissions reset on each rebuild)"
fi

rm -rf "$APP"
mv "$STAGE" "$APP"
rmdir build/.staging 2>/dev/null || true
# A fresh date and registration, so Finder and the Dock pick up the icon right away.
touch "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" || true
echo "Built $APP"
