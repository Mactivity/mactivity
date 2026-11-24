#!/usr/bin/env python3
"""Moves strings between Mactivity's String Catalogs and plain translation files.

  scripts/translations.py export [out.json]
      Every key that needs translating, from every catalog, with its English text, comment and
      plural forms: docs/localization/source.json by default. Translators work from this.

  scripts/translations.py import <lang> <file.json>
      Writes one language's translations into the catalogs. The file maps catalog path → key →
      either a string, or {"one": …, "other": …} (any CLDR categories) for plural keys, or
      {"format": …, "substitutions": {name: {"one": …, "other": …}}} for keys with several counts.
      Existing translations for that language are replaced; other languages are untouched.

  scripts/translations.py validate <lang> <file.json>
      Checks a translation file before import: every key exists, placeholders (%@, %lld, %1$@ …)
      match the English exactly, placeholders that move carry position numbers, plural keys have
      an "other" form, nothing is empty.

  scripts/translations.py delta <lang> [<file.json>] [--since <git-rev>] [--prune]
      What a language's translation file (docs/localization/translations/<lang>.json by default)
      needs after the English moved on, against docs/localization/source.json:
        new       keys the file doesn't have yet;
        changed   keys whose English (text or plural forms) differs from the source.json the file
                  was last translated against (by default the source.json of the last commit that
                  touched the file; --since picks another revision), and whose translation hasn't
                  been touched since;
        obsolete  keys in the file that are gone from the catalogs.
      Prints the lists, then the new and changed keys as JSON (English, comment, the current
      translation) ready to hand to a translator. --prune removes the obsolete keys from the file.

  scripts/translations.py status
      How many keys each language has, per catalog.
"""
import re
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = sorted(
    p for p in glob.glob(os.path.join(ROOT, "**", "*.xcstrings"), recursive=True)
    if "/build/" not in p and "/.build/" not in p
)


def rel(path):
    return os.path.relpath(path, ROOT)


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, catalog):
    # Xcode writes catalogs with 2-space indents and " : " separators; match it so diffs stay small.
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
        f.write("\n")


def english(entry, key):
    """The English text: a plain value, plural forms, or a format with substitutions."""
    en = entry.get("localizations", {}).get("en", {})
    if "variations" in en and "plural" in en["variations"]:
        return {k: v["stringUnit"]["value"] for k, v in en["variations"]["plural"].items()}
    if "substitutions" in en:
        return {
            "format": en.get("stringUnit", {}).get("value", key),
            "substitutions": {
                name: {k: v["stringUnit"]["value"] for k, v in sub["variations"]["plural"].items()}
                for name, sub in en["substitutions"].items()
            },
        }
    return en.get("stringUnit", {}).get("value", key)


def export(out):
    entries = []
    for path in CATALOGS:
        catalog = load(path)
        for key, entry in sorted(catalog.get("strings", {}).items()):
            if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
                continue
            entries.append({"catalog": rel(path), "key": key, "english": english(entry, key),
                            "comment": entry.get("comment", "")})
    with open(out, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=1)
    print(f"{len(entries)} keys from {len(CATALOGS)} catalogs → {rel(out)}")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value, en_entry):
    if isinstance(value, str):
        return unit(value)
    if "format" in value:
        substitutions = {}
        for name, forms in value["substitutions"].items():
            base = en_entry.get("localizations", {}).get("en", {}).get("substitutions", {}).get(name, {})
            substitutions[name] = {
                "argNum": base.get("argNum", 1),
                "formatSpecifier": base.get("formatSpecifier", "lld"),
                "variations": {"plural": {k: unit(v) for k, v in forms.items()}},
            }
        return {"stringUnit": {"state": "translated", "value": value["format"]}, "substitutions": substitutions}
    return {"variations": {"plural": {k: unit(v) for k, v in value.items()}}}


def import_language(lang, file):
    translations = load(file)
    written = missing = 0
    for catalog_path, keys in translations.items():
        path = os.path.join(ROOT, catalog_path)
        catalog = load(path)
        strings = catalog.setdefault("strings", {})
        for key, value in keys.items():
            if key not in strings:
                missing += 1
                continue
            strings[key].setdefault("localizations", {})[lang] = localization(value, strings[key])
            written += 1
        save(path, catalog)
    print(f"{lang}: {written} translations written" + (f", {missing} keys not in the catalogs" if missing else ""))


PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|f|\.\d+f|%|#@[a-zA-Z]+@)")
# App Shortcuts phrases carry parameters as ${name}; Siri needs them exactly as written.
PARAMETER = re.compile(r"\$\{[A-Za-z]+\}")


def placeholders(text):
    """The placeholder types, ignoring position numbers: a language may reorder "%1$@ %2$lld"."""
    return sorted(re.sub(r"^%\d+\$", "%", p) for p in PLACEHOLDER.findall(text) if p != "%%")


def placeholders_in_order(text):
    return [re.sub(r"^%\d+\$", "%", p) for p in PLACEHOLDER.findall(text) if p != "%%"]


def texts(value):
    """Every string inside a translation value, flattened."""
    if isinstance(value, str):
        return [value]
    if "format" in value:
        return [value["format"]] + [t for forms in value["substitutions"].values() for t in forms.values()]
    return list(value.values())


def validate(lang, file):
    source = {(e["catalog"], e["key"]): e["english"] for e in load(os.path.join(ROOT, "docs", "localization", "source.json"))}
    translations = load(file)
    problems = []
    seen = 0
    for catalog, keys in translations.items():
        for key, value in keys.items():
            seen += 1
            if (catalog, key) not in source:
                problems.append(f"unknown key {catalog} :: {key!r}")
                continue
            english = source[(catalog, key)]
            if isinstance(english, dict) and not isinstance(value, dict):
                problems.append(f"{key!r}: English has plural forms; give an object")
                continue
            if isinstance(value, dict) and "format" not in value and "other" not in value:
                problems.append(f"{key!r}: plural needs an 'other' form")
            for text in texts(value):
                if not text.strip():
                    problems.append(f"{key!r}: empty text")
            # Compare the format's placeholders; plural forms may drop the count (e.g. "one").
            english_main = english if isinstance(english, str) else english.get("format", english.get("other", ""))
            value_main = value if isinstance(value, str) else value.get("format", value.get("other", ""))
            if placeholders(english_main) != placeholders(value_main):
                problems.append(f"{key!r}: placeholders {placeholders(value_main)} ≠ English {placeholders(english_main)}")
            # Moving placeholders needs position numbers ("%2$lld … %1$@"): an unnumbered
            # reorder reads each argument as the wrong type and crashes at runtime.
            for text in texts(value):
                found = [p for p in PLACEHOLDER.findall(text) if p != "%%"]
                if len(found) > 1 and any(not re.match(r"%\d+\$", p) for p in found):
                    kinds = [p for p in placeholders_in_order(text)]
                    if kinds != placeholders_in_order(english_main)[:len(kinds)] and "#@" not in text:
                        problems.append(f"{key!r}: placeholders moved without position numbers in {text!r}")
            if sorted(PARAMETER.findall(english_main)) != sorted(PARAMETER.findall(value_main)):
                problems.append(f"{key!r}: phrase parameters {PARAMETER.findall(value_main)} ≠ English {PARAMETER.findall(english_main)}")
    total = len(source)
    for problem in problems[:60]:
        print("  " + problem)
    print(f"{lang}: {seen}/{total} keys, {len(problems)} problems")
    return 1 if problems else 0


def git(*arguments):
    import subprocess
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def delta(lang, file=None, since=None, prune=False):
    file = file or os.path.join(ROOT, "docs", "localization", "translations", f"{lang}.json")
    source = {(e["catalog"], e["key"]): e for e in load(os.path.join(ROOT, "docs", "localization", "source.json"))}
    translations = load(file) if os.path.exists(file) else {}
    have = {(catalog, key): value for catalog, keys in translations.items() for key, value in keys.items()}
    if since is None:
        since = (git("log", "-1", "--format=%H", "--", rel(file)) or "").strip() or None
    baseline, translated_then = {}, {}
    if since:
        text = git("show", f"{since}:docs/localization/source.json")
        if text is None:
            sys.exit(f"No docs/localization/source.json at {since}")
        baseline = {(e["catalog"], e["key"]): e["english"] for e in json.loads(text)}
        then = git("show", f"{since}:{rel(file)}")
        # A file git doesn't have at the baseline counts as untouched since then.
        translated_then = have if then is None else {
            (catalog, key): value for catalog, keys in json.loads(then).items() for key, value in keys.items()
        }
    new = sorted(k for k in source if k not in have)
    # English moved on since the baseline, and the translation is still the one from then.
    changed = sorted(
        k for k in source
        if k in have and k in baseline and baseline[k] != source[k]["english"] and have[k] == translated_then.get(k)
    )
    obsolete = sorted(k for k in have if k not in source)
    for title, keys in (("new", new), ("changed", changed), ("obsolete", obsolete)):
        print(f"{title}: {len(keys)}")
        for catalog, key in keys:
            print(f"  {catalog} :: {key!r}")
    todo = [dict(source[k], current=have.get(k)) for k in new + changed]
    if todo:
        print(json.dumps(todo, ensure_ascii=False, indent=1))
    print(f"{lang}: {len(new)} new, {len(changed)} changed, {len(obsolete)} obsolete (baseline {since or 'none'})")
    if prune and obsolete:
        with open(file, encoding="utf-8") as f:
            text = f.read()
        # Keep the file's own layout (indent, final newline) so the diff shows only the removals.
        second = text.split("\n", 2)[1] if "\n" in text else ""
        indent = len(second) - len(second.lstrip(" ")) or 2
        for catalog, key in obsolete:
            del translations[catalog][key]
        with open(file, "w", encoding="utf-8") as f:
            f.write(json.dumps(translations, ensure_ascii=False, indent=indent) + ("\n" if text.endswith("\n") else ""))
        print(f"removed {len(obsolete)} obsolete keys from {rel(file)}")


def status():
    for path in CATALOGS:
        catalog = load(path)
        strings = {k: v for k, v in catalog.get("strings", {}).items() if v.get("shouldTranslate") is not False}
        counts = {}
        for entry in strings.values():
            for lang in entry.get("localizations", {}):
                counts[lang] = counts.get(lang, 0) + 1
        langs = ", ".join(f"{lang} {n}" for lang, n in sorted(counts.items()) if lang != "en")
        print(f"{rel(path)}: {len(strings)} keys" + (f" · {langs}" if langs else ""))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "export":
        export(sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "docs", "localization", "source.json"))
    elif command == "import" and len(sys.argv) == 4:
        import_language(sys.argv[2], sys.argv[3])
    elif command == "validate" and len(sys.argv) == 4:
        sys.exit(validate(sys.argv[2], sys.argv[3]))
    elif command == "delta" and len(sys.argv) >= 3:
        rest = sys.argv[3:]
        prune = "--prune" in rest
        rest = [a for a in rest if a != "--prune"]
        since = None
        if "--since" in rest:
            index = rest.index("--since")
            since = rest[index + 1] if index + 1 < len(rest) else sys.exit(__doc__)
            del rest[index:index + 2]
        delta(sys.argv[2], rest[0] if rest else None, since, prune)
    elif command == "status":
        status()
    else:
        sys.exit(__doc__)
