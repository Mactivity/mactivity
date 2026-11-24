#!/bin/bash
# Fails on a SwiftUI call in the package with a string literal title and no `bundle:`
# (docs/localization/README.md). In a package, `Text("Quit")` looks in the app's catalog, not the
# target's, so the string would never be translated. `Text(verbatim:)` and calls that pass
# `bundle: .strings` are fine. With no arguments, checks every package source; otherwise the
# files given.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
    set -- $(find Packages/MactivityKit/Sources -name '*.swift' -not -path '*/MactivityCLI/*' | sort)
fi

exec /usr/bin/python3 - "$@" <<'PY'
import re
import sys

# Calls whose first argument, when it's a literal, is a localized title.
CALLS = (
    r"(?<![\w.])(?:Text|Button|Label|Toggle|Picker|Section|Menu|LabeledContent|TextField|SecureField"
    r"|Link|GroupBox|DisclosureGroup|ContentUnavailableView|Tab|Stepper|ProgressView|Gauge|ShareLink)"
    r"|\.(?:help|navigationTitle|navigationSubtitle|confirmationDialog|alert|accessibilityLabel"
    r"|accessibilityHint|accessibilityValue|badge|searchable)"
)
PATTERN = re.compile(r"(" + CALLS + r")\(\s*\"(?!\")")


def call_text(source, start):
    """The call from its opening parenthesis to the matching close, strings skipped."""
    depth, index, in_string = 0, start, False
    while index < len(source):
        char = source[index]
        if in_string:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    return source[start:]


failures = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    for match in PATTERN.finditer(source):
        line_start = source.rfind("\n", 0, match.start()) + 1
        line = source[line_start:source.find("\n", match.start())]
        if line.lstrip().startswith("//"):
            continue
        text = call_text(source, match.start(1) + len(match.group(1)))
        if re.search(r"\bbundle:", text):
            continue
        number = source.count("\n", 0, match.start()) + 1
        failures.append(f"{path}:{number}: {match.group(1)}(\"…\") without bundle: .strings: {line.strip()}")

if failures:
    print("\n".join(failures))
    print(f"\n{len(failures)} unlocalized SwiftUI literal(s). Pass `bundle: .strings`, or use "
          "Text(verbatim:) for data (docs/localization/README.md).", file=sys.stderr)
    sys.exit(1)
PY
