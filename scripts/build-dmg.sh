#!/usr/bin/env bash
# Packs build/Imp.app into build/Imp.dmg: the installer window with Imp next to an Applications
# link, on a background the app renders itself. Needs dmgbuild (pipx install dmgbuild).
# The image itself stays unsigned: Gatekeeper checks a signed disk image when it's opened and
# blocks one whose certificate isn't Apple's, while an unsigned one just opens. The app inside is
# signed, so a download asks for permission once, when Imp first launches.
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
echo "Built $DMG"
