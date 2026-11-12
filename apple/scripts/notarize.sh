#!/usr/bin/env bash
# Sends an app or a disk image to Apple's notary service and staples the ticket to it:
#   apple/scripts/notarize.sh build/Imp.app   (or build/Imp.dmg)
# It does nothing, and succeeds, when no credentials are set. Credentials, either one:
#   IMP_NOTARY_PROFILE   a keychain profile made once with `xcrun notarytool store-credentials`
#   IMP_NOTARY_KEY (path of the .p8 file), IMP_NOTARY_KEY_ID and IMP_NOTARY_ISSUER   an App Store Connect API key
set -euo pipefail

TARGET="${1:?usage: notarize.sh <Imp.app or Imp.dmg>}"
[[ -e "$TARGET" ]] || { echo "No $TARGET" >&2; exit 1; }

if [[ -n "${IMP_NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$IMP_NOTARY_PROFILE")
elif [[ -n "${IMP_NOTARY_KEY:-}" && -n "${IMP_NOTARY_KEY_ID:-}" && -n "${IMP_NOTARY_ISSUER:-}" ]]; then
  AUTH=(--key "$IMP_NOTARY_KEY" --key-id "$IMP_NOTARY_KEY_ID" --issuer "$IMP_NOTARY_ISSUER")
else
  echo "Not notarizing $TARGET (no notary credentials)"
  exit 0
fi

SUBMIT="$TARGET"
if [[ -d "$TARGET" ]]; then
  # The service takes an archive, not a bundle folder.
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  SUBMIT="$WORK/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "Notarized $TARGET"
