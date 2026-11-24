#!/usr/bin/python3
"""String Catalog upkeep (docs/localization/README.md).

  scripts/strings.py sync
      Merges the strings the compiler extracted in the last Debug build (`make build`) into every
      source catalog with `xcstringstool sync`: new keys are added, keys gone from the code are
      marked stale, translations are kept. Syncs App/InfoPlist.xcstrings from App/Info.plist, then
      lists count keys that have no English plural variation yet.

  scripts/strings.py plural <Catalog> "<key>" "<one>" ["<other>"]
      Gives a key English one/other variations, e.g.
      scripts/strings.py plural UI "%lld processes" "%lld process". <Catalog> is a package target
      (UI, Core, …), App, AppShortcuts, or Widgets. <other> defaults to the key.

  scripts/strings.py plural-args <Catalog> "<key>" "<format>" <name> <argNum> "<one>" "<other>" …
      For a key with two counts, each its own plural: <format> names each part %#@name@ and
      numbers every argument once any is numbered ("%1$lld of %2$#@macs@ · checked %3$@"; a
      mix of numbered and unnumbered reads the wrong argument and crashes), e.g.
      scripts/strings.py plural-args Readouts "%lld dev servers in %lld projects." \
          "%#@servers@ in %#@projects@." servers 1 "%arg dev server" "%arg dev servers" \
          projects 2 "%arg project" "%arg projects"

  scripts/strings.py check-plurals
      Only the plural listing. Exits 0 either way; it's advice, not a gate.
"""

import glob
import json
import os
import plistlib
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INTERMEDIATES = os.path.join(ROOT, "build/DerivedData.noindex/Build/Intermediates.noindex")
PACKAGE_SOURCES = os.path.join(ROOT, "Packages/MactivityKit/Sources")

# Info.plist keys shown to people: the app's name, copyright, and every permission prompt.
INFO_PLIST_KEYS = re.compile(r"^(CFBundleDisplayName|CFBundleName|NSHumanReadableCopyright|NS\w+UsageDescription)$")


def catalogs():
    """{name: (catalog paths, the directory of that target's .stringsdata)}."""
    targets = {}
    for path in sorted(glob.glob(os.path.join(PACKAGE_SOURCES, "*/Localizable.xcstrings"))):
        target = os.path.basename(os.path.dirname(path))
        targets[target] = ([path], os.path.join(INTERMEDIATES, f"MactivityKit.build/Debug/{target}-t.build"))
    app = os.path.join(INTERMEDIATES, "Mactivity.build/Debug/Mactivity.build")
    targets["App"] = ([os.path.join(ROOT, "App/Sources/Localizable.xcstrings")], app)
    targets["AppShortcuts"] = ([os.path.join(ROOT, "App/Sources/AppShortcuts.xcstrings")], app)
    widgets = os.path.join(INTERMEDIATES, "Mactivity.build/Debug/MactivityWidgets.build")
    targets["Widgets"] = ([os.path.join(ROOT, "Widgets/Sources/Localizable.xcstrings")], widgets)
    return targets


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save(path, catalog):
    """Xcode's own layout, so a sync after an edit here changes nothing."""
    text = json.dumps(catalog, indent=2, separators=(",", " : "), sort_keys=True, ensure_ascii=False)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text + "\n")


def current_stringsdata(directory):
    """The target's .stringsdata whose source file still exists (a deleted file's stays behind)."""
    files = []
    for path in sorted(glob.glob(os.path.join(directory, "Objects-normal/*/*.stringsdata"))):
        try:
            source = load(path).get("source", "")
        except (OSError, ValueError):
            continue
        if not source or os.path.exists(source):
            files.append(path)
    return files


def sync():
    if not os.path.isdir(INTERMEDIATES):
        sys.exit("No Debug build to read extracted strings from. Run `make build` first.")
    for name, (paths, directory) in catalogs().items():
        data = current_stringsdata(directory)
        if not data:
            print(f"{name}: no extracted strings in {os.path.relpath(directory, ROOT)}; skipped")
            continue
        # Each catalog takes the tables named like it, so the app's Localizable and AppShortcuts
        # tables sync from the same files without mixing.
        subprocess.run(["xcrun", "xcstringstool", "sync", *paths, "--stringsdata", *data], check=True)
        for path in paths:
            mark_untranslatable(path)
            print(f"{name}: {len(load(path)['strings'])} keys")
    sync_info_plist()
    check_plurals()


# Only placeholders and punctuation ("%@ · %@", "%@: %@"): nothing for a translator to do,
# unless the code gave it a comment (a join a language may want to reorder).
PLACEHOLDERS_ONLY = re.compile(r"^(?:%(?:\d+\$)?(?:@|l{0,2}[duf])|[\s·:,.()\-–—/|])*$")


def mark_untranslatable(path):
    catalog = load(path)
    changed = False
    for key, entry in catalog.get("strings", {}).items():
        wanted = not (PLACEHOLDERS_ONLY.match(key) and "comment" not in entry)
        if entry.get("shouldTranslate", True) != wanted:
            if wanted:
                del entry["shouldTranslate"]
            else:
                entry["shouldTranslate"] = False
            changed = True
    if changed:
        save(path, catalog)


def sync_info_plist():
    path = os.path.join(ROOT, "App/InfoPlist.xcstrings")
    with open(os.path.join(ROOT, "App/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    catalog = load(path)
    strings = catalog.setdefault("strings", {})
    wanted = {key: value for key, value in info.items() if INFO_PLIST_KEYS.match(key) and isinstance(value, str)}
    for key, value in wanted.items():
        entry = strings.setdefault(key, {})
        entry["extractionState"] = "extracted_with_value"
        english = entry.setdefault("localizations", {}).setdefault("en", {}).setdefault("stringUnit", {})
        if english.get("value") != value:
            english["value"] = value
            english["state"] = "new"
    for key in list(strings):
        if key not in wanted:
            strings[key]["extractionState"] = "stale"
    save(path, catalog)
    print(f"InfoPlist: {len(wanted)} keys")


# A count followed by a word: "%lld processes", "%1$lld items". Counts alone ("%lld%%") don't vary.
COUNT_WORD = re.compile(r"%(?:\d+\$)?l{0,2}[du]\s*[^\W\d_]")


def check_plurals():
    missing = []
    for name, (paths, _) in catalogs().items():
        for path in paths:
            for key, entry in load(path).get("strings", {}).items():
                if entry.get("extractionState") == "stale" or not COUNT_WORD.search(key):
                    continue
                english = entry.get("localizations", {}).get("en", {})
                if "plural" not in json.dumps(english.get("variations", {})) and "substitutions" not in english:
                    missing.append(f"  {name}: {key}")
    if missing:
        print("Count keys without an English plural variation (scripts/strings.py plural …, if the word inflects):")
        print("\n".join(missing))


def plural(name, key, one, other=None):
    targets = catalogs()
    if name not in targets:
        sys.exit(f"No catalog named {name}. One of: {', '.join(targets)}")
    path = targets[name][0][0]
    catalog = load(path)
    entry = catalog["strings"].setdefault(key, {"extractionState": "manual"})
    entry.setdefault("localizations", {})["en"] = {
        "variations": {
            "plural": {
                "one": {"stringUnit": {"state": "translated", "value": one}},
                "other": {"stringUnit": {"state": "translated", "value": other or key}},
            }
        }
    }
    save(path, catalog)


def plural_args(name, key, format_string, *parts):
    """One plural per argument: Xcode's substitutions (Vary by Plural on each argument)."""
    targets = catalogs()
    if name not in targets or len(parts) % 4:
        sys.exit(__doc__)
    path = targets[name][0][0]
    catalog = load(path)
    substitutions = {}
    for index in range(0, len(parts), 4):
        part, number, one, other = parts[index:index + 4]
        substitutions[part] = {
            "argNum": int(number),
            "formatSpecifier": "lld",
            "variations": {
                "plural": {
                    "one": {"stringUnit": {"state": "translated", "value": one}},
                    "other": {"stringUnit": {"state": "translated", "value": other}},
                }
            },
        }
    entry = catalog["strings"].setdefault(key, {"extractionState": "manual"})
    entry.setdefault("localizations", {})["en"] = {
        "stringUnit": {"state": "translated", "value": format_string},
        "substitutions": substitutions,
    }
    save(path, catalog)


def main(arguments):
    if arguments[:1] == ["sync"]:
        sync()
    elif arguments[:1] == ["check-plurals"]:
        check_plurals()
    elif arguments[:1] == ["plural"] and len(arguments) in (4, 5):
        plural(*arguments[1:])
    elif arguments[:1] == ["plural-args"] and len(arguments) >= 8:
        plural_args(*arguments[1:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
