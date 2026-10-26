#!/usr/bin/env bash
# Packs build/Imp.app into build/Imp.dmg: the installer window with Imp next to an Applications
# link, on a background the app renders itself. Needs dmgbuild (pipx install dmgbuild).
# Signs the image with $IMP_SIGN_IDENTITY when it's set (releases).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Imp.app"
DMG="build/Imp.dmg"
BACKGROUND="build/dmg-background"
DMGBUILD="${DMGBUILD:-dmgbuild}"

[[ -d "$APP" ]] || { echo "No $APP: run scripts/build-app.sh first" >&2; exit 1; }
rm -rf "$BACKGROUND" "$DMG"
"$APP/Contents/MacOS/Imp" --render-dmg-background "$BACKGROUND"
"$DMGBUILD" -s scripts/dmg-settings.py -D app="$APP" -D background="$BACKGROUND/background.png" Imp "$DMG"
if [[ -n "${IMP_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$IMP_SIGN_IDENTITY" "$DMG"
fi
echo "Built $DMG"
