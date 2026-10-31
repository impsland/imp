#!/usr/bin/env bash
# Builds Imp for iPhone, installs it on a connected iPhone (cable, or Wi-Fi once paired in Xcode) and opens it.
#   DEVICE  the iPhone's name or UDID (default: the only one connected; see `xcrun devicectl list devices`)
#   TEAM    the Apple Developer Team ID to sign with (default: a team signed in to Xcode, else your certificate's)
#   CONFIG  Release (default) or Debug (Debug understands -demo, -openChat… see iOS/README.md)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
DERIVED=.build/ios-device

if [[ -z "${DEVICE:-}" ]]; then
  LIST="$(mktemp)"
  trap 'rm -f "$LIST"' EXIT
  xcrun devicectl list devices --quiet --json-output "$LIST" >/dev/null
  DEVICE="$(python3 -I - "$LIST" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("reality") == "physical"
          and d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
if len(phones) == 1:
    print(phones[0]["hardwareProperties"]["udid"])
else:
    for d in phones:
        print(f'  {d["deviceProperties"]["name"]}  {d["hardwareProperties"]["udid"]}', file=sys.stderr)
EOF
)"
  if [[ -z "$DEVICE" ]]; then
    echo "error: connect one iPhone (and trust this Mac), or pick one: make ios-device DEVICE=<name or UDID>" >&2
    exit 1
  fi
fi

if [[ -z "${TEAM:-}" ]]; then
  # A team signed in to Xcode first (it can make profiles), else one from a certificate.
  TEAM="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | awk -F' = ' '/teamID/ { gsub(/[";]/, "", $2); print $2; exit }')"
fi
if [[ -z "${TEAM:-}" ]]; then
  TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
  if [[ -z "$TEAM" ]]; then
    echo "error: no Apple Development certificate found: sign in to Xcode, or pass make ios-device TEAM=<Team ID>" >&2
    exit 1
  fi
fi

(cd iOS && xcodegen generate --quiet)
xcodebuild -project iOS/ImpPhone.xcodeproj -scheme ImpPhone -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates -quiet build

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Imp.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing app.imp.ImpPhone >/dev/null \
  || echo "Installed. Unlock the iPhone and open Imp (the first time: Settings › General › VPN & Device Management › trust the developer)."
