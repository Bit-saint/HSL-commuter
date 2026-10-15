#!/usr/bin/env python3
"""Generates App/Localizable.xcstrings and Widgets/Localizable.xcstrings (Finnish, Swedish)
from the keys used in the sources and tools/l10n/translations.py. Fails on missing translations
or placeholder mismatches. Run from the repo root: python3 tools/l10n/build_catalogs.py
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from extract import scan
from translations import T, EXTRA_APP_KEYS, EXTRA_WIDGET_KEYS

SPEC = re.compile(r'%(?:(\d+)\$)?(@|lld)')

def specs(s):
    """Placeholder types in argument order (positional ones by their index)."""
    found = [(int(m.group(1)) if m.group(1) else None, m.group(2)) for m in SPEC.finditer(s)]
    if any(i is not None for i, _ in found):
        return [t for _, t in sorted(found, key=lambda x: x[0] or 0)]
    return [t for _, t in found]

def build(keys, path):
    missing, bad, strings = [], [], {}
    for k in sorted(keys):
        if k not in T:
            missing.append(k); continue
        fi, sv = T[k]
        for lang, v in (("fi", fi), ("sv", sv)):
            if specs(v) != specs(k) and v != "":
                bad.append((k, lang, v))
        strings[k] = {"localizations": {
            lang: {"stringUnit": {"state": "translated", "value": v}} for lang, v in (("fi", fi), ("sv", sv))
        }}
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(path, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    return missing, bad, len(strings)

problems = False
for dirs, extra, out in ((["App", "Shared"], EXTRA_APP_KEYS, "App/Localizable.xcstrings"),
                         (["Widgets", "Shared"], EXTRA_WIDGET_KEYS, "Widgets/Localizable.xcstrings")):
    keys = scan(dirs) | set(extra)
    missing, bad, n = build(keys, out)
    print(f"{out}: {n} strings")
    for k in missing: print("  missing:", json.dumps(k, ensure_ascii=False)); problems = True
    for k, lang, v in bad: print(f"  placeholder mismatch [{lang}]: {k!r} -> {v!r}"); problems = True
sys.exit(1 if problems else 0)
