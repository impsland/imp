#!/usr/bin/env python3
"""Every dotted string key used in the given Swift files needs en, es and zh-Hans.
Keys live in design/strings/*.json or in apple/Resources/Localization/Localizable.xcstrings.
Usage: check-strings.py FILE.swift ..."""
import glob, json, re, sys

LANGS = ("en", "es", "zh-Hans")
known = {}
for path in glob.glob("design/strings/*.json"):
    for key, entry in json.load(open(path, encoding="utf-8")).items():
        known[key] = {l for l in LANGS if entry.get(l)}
catalog = json.load(open("apple/Resources/Localization/Localizable.xcstrings", encoding="utf-8"))["strings"]
for key, entry in catalog.items():
    known.setdefault(key, {l for l, v in entry.get("localizations", {}).items() if v.get("stringUnit", {}).get("value")})

pattern = re.compile(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"')
bad = 0
for path in sys.argv[1:]:
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("//"):
            continue
        for key in pattern.findall(line):
            if not re.match(r"^(settings|menu|common|states|home|imps|phone|sheets|first-run|extension|imp-settings|all-imps)\.", key):
                continue
            missing = [l for l in LANGS if l not in known.get(key, set())]
            if missing:
                bad += 1
                print(f"{path}:{number}: {key} lacks {', '.join(missing)}")
print("ok" if not bad else f"{bad} missing")
sys.exit(1 if bad else 0)
