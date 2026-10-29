#!/usr/bin/env bash
# Syncs the String Catalogs in Resources/Localization with the source: the compiler lists every
# localizable string it sees (SwiftUI text, String(localized:), LocalizedStringResource), and
# xcstringstool adds new keys and marks removed ones stale. Translations are kept.
# Run after changing user-facing text (`make strings`), then translate what's new.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT="${SWIFT:-xcrun swift}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

$SWIFT build --product Imp --scratch-path .build/strings \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
xcrun xcstringstool sync Resources/Localization/Localizable.xcstrings --stringsdata "$OUT"/*.stringsdata
echo "Synced Resources/Localization/Localizable.xcstrings"
