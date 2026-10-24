#!/usr/bin/env python3
"""List UI strings the last build extracted that have no zh-Hans entry.

Usage: scripts/l10n_missing.py [Debug|Release]
Reads the .stringsdata files of the last build and compares them with
ToastPeek/Resources/Localizable.xcstrings. Exits 1 when something is missing.
"""
import glob
import json
import os
import sys

config = sys.argv[1] if len(sys.argv) > 1 else "Debug"
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.environ.get("TOASTPEEK_BUILD_DIR", os.path.expanduser("~/Developer/Builds/ToastPeek"))
pattern = f"{out}/DerivedData/Build/Intermediates.noindex/ToastPeek.build/{config}/ToastPeek.build/Objects-normal/*/*.stringsdata"
keys = set()
for path in glob.glob(pattern):
    with open(path) as fh:
        for entries in json.load(fh).get("tables", {}).values():
            keys.update(e["key"] for e in entries if e["key"])
with open(os.path.join(root, "ToastPeek/Resources/Localizable.xcstrings")) as fh:
    catalog = json.load(fh)["strings"]
missing = sorted(k for k in keys if "zh-Hans" not in catalog.get(k, {}).get("localizations", {}))
for k in missing:
    print(k)
sys.exit(1 if missing else 0)
