#!/usr/bin/env bash
# Draws the main screens in their key states with the app's own offscreen renderer and saves them in
# docs/ux/images. The words come from the String Catalogs, so the binary runs inside a throwaway app
# folder that has them compiled (a plain `swift build` binary shows the keys instead).
set -euo pipefail
cd "$(dirname "$0")/../.."

SWIFT="${SWIFT:-xcrun swift}"
SCENES="canvas-empty canvas-imps canvas-picture imp-brain imp-sleeping imp-list imp-brain-open imp-narrow-open imp-personality imp-look imp-tools imp-triggers imp-moves imp-look-narrow imp-trigger-editor all-imps-app all-imps-app-narrow all-imps-nothing first-run-service first-run-error bar-menu bar-menu-es all-imps-pair all-imps-bubble all-imps-talking all-imps-brains all-imps-devices all-imps-devices-narrow all-imps-sharing all-imps-animations all-imps-privacy all-imps-backup bubble-short bubble-read-all bubble-chat"
OUT="docs/ux/images"

$SWIFT build --package-path apple --product Imp
BIN_DIR="$($SWIFT build --package-path apple --show-bin-path)"

APP="$(mktemp -d)/Imp.app"
trap 'rm -rf "$(dirname "$APP")"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Imp" "$APP/Contents/MacOS/Imp"
cp apple/Resources/Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN_DIR"/*.bundle; do [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"; done
for catalog in apple/Resources/Localization/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done

mkdir -p "$OUT"
for scene in $SCENES; do
  "$APP/Contents/MacOS/Imp" --render-home "$scene" "$OUT/$scene.png"
  echo "$OUT/$scene.png"
done
