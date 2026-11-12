#!/usr/bin/env bash
# Packs build/Imp.app into build/Imp.dmg: the installer window with Imp next to an Applications
# link, on a background the app renders itself. Needs dmgbuild (pipx install dmgbuild).
# The image itself stays unsigned: Gatekeeper checks a signed disk image when it's opened and
# blocks one whose certificate isn't Apple's, while an unsigned one just opens. The app inside is
# signed, so a download asks for permission once, when Imp first launches.
# With $IMP_DEVELOPER_ID set, the image is signed with it too. With notary credentials (see
# notarize.sh), the app is notarized before it is packed and the image after.
set -euo pipefail
cd "$(dirname "$0")/../.."

APP="build/Imp.app"
DMG="build/Imp.dmg"
BACKGROUND="build/dmg-background"
DMGBUILD="${DMGBUILD:-dmgbuild}"

[[ -d "$APP" ]] || { echo "No $APP: run apple/scripts/build-app.sh first" >&2; exit 1; }
"$(dirname "$0")/notarize.sh" "$APP"
rm -rf "$BACKGROUND" "$DMG"
"$APP/Contents/MacOS/Imp" --render-dmg-background "$BACKGROUND"
"$DMGBUILD" -s apple/scripts/dmg-settings.py -D app="$APP" -D background="$BACKGROUND/background.png" Imp "$DMG"
if [[ -n "${IMP_DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$IMP_DEVELOPER_ID" "$DMG"
  "$(dirname "$0")/notarize.sh" "$DMG"
fi
echo "Built $DMG"
