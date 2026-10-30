#!/bin/sh
# Builds the Firefox and Safari copy of this extension in build/extension-firefox/.
# Chrome-family browsers take manifest.json as is (MV3 service worker). Firefox and Safari run the
# same background.js as an event page, which MV3 declares with "scripts" instead of "service_worker".
set -eu
cd "$(dirname "$0")"
out=../../build/extension-firefox
rm -rf "$out"
mkdir -p "$out"
cp -R background.js popup.js popup.html popup.css icons "$out/"
python3 -I - "$out/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open("manifest.json", encoding="utf-8") as f:
    m = json.load(f)
m["background"] = {"scripts": ["background.js"]}
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
echo "wrote $out"
