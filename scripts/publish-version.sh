#!/bin/bash
# After make release: points the website at the new DMG and adds it to Sparkle's feed.
#   scripts/publish-version.sh dist/Mactivity-0.9.1.dmg
# Edits website/appcast.xml, website/_redirects, website/download.html, website/index.html. Publishing
# is separate: review the diff, then make site.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$MACTIVITY_ROOT"
DMG="${1:?Usage: scripts/publish-version.sh dist/Mactivity-<version>.dmg}"
[[ -f "$DMG" ]] || { echo "No file at $DMG" >&2; exit 1; }
SIGN_UPDATE="$ROOT/build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "Sparkle's sign_update is missing; run make build once." >&2; exit 1; }

VERSION="$(project_setting MARKETING_VERSION)"
BUILD="$(project_setting CURRENT_PROJECT_VERSION)"
MIN_OS="$(project_setting MACOSX_DEPLOYMENT_TARGET)"
# The EdDSA signature and length, from the key in the keychain (make apple-setup).
SIGNATURE="$("$SIGN_UPDATE" --account mactivity "$DMG")"

python3 - "$ROOT" "$DMG" "$VERSION" "$BUILD" "$MIN_OS" "$SIGNATURE" <<'PY'
import html, os, re, sys, email.utils
root, dmg, version, build, min_os, signature = sys.argv[1:]
name = os.path.basename(dmg)
size_mb = max(1, round(os.path.getsize(dmg) / 1_000_000))
url = f"https://mactivity.app/download/{name}"

# Release notes: "- " lines in docs/releases/<version>.md become a list.
notes_path = os.path.join(root, "docs", "releases", f"{version}.md")
items = []
if os.path.exists(notes_path):
    items = [line[2:].strip() for line in open(notes_path) if line.startswith("- ") and line[2:].strip()]
def inline(text):
    # Escaped, then **bold** and `code`, as the changelog page renders them.
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)
notes = "".join(f"<li>{inline(item)}</li>" for item in items)
description = f"\n      <description><![CDATA[<ul>{notes}</ul>]]></description>" if notes else ""

appcast = os.path.join(root, "website", "appcast.xml")
feed = open(appcast).read()
if f"<sparkle:version>{build}</sparkle:version>" in feed:
    if os.environ.get("REPLACE") != "1":
        sys.exit(f"The appcast already has build {build}. Bump the version first (make bump V=...), "
                 "or rebuild the same version with REPLACE=1 make release.")
    # A rebuild of an unpublished version: its old entry's signature no longer matches the DMG.
    feed = re.sub(rf"    <item>\n(?:(?!</item>).)*?<sparkle:version>{build}</sparkle:version>.*?    </item>\n", "", feed, count=1, flags=re.S)
item = f"""    <item>
      <title>Mactivity {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>{description}
      <enclosure url="{url}" type="application/octet-stream"
        {signature}/>
    </item>
"""
# Newest first, right after the channel's own fields.
feed = feed.replace("    <language>en</language>\n", "    <language>en</language>\n" + item, 1)
open(appcast, "w").write(feed)

def edit(path, pattern, replacement):
    full = os.path.join(root, "website", path)
    text = open(full).read()
    new, count = re.subn(pattern, replacement, text)
    if count == 0:
        print(f"  (nothing to change in {path} for {pattern})")
    open(full, "w").write(new)

edit("_redirects", r"(?m)^/download/latest\s+\S+", f"/download/latest  /download/{name}")
edit("download.html", r'href="/download/Mactivity-[^"]+\.dmg"', f'href="/download/{name}"')
edit("download.html", r"<p class=\"fine\" data-version>Mactivity [^,]+, about \d+ MB\.", f"<p class=\"fine\" data-version>Mactivity {version}, about {size_mb} MB.")
edit("index.html", r"About \d+ MB\.", f"About {size_mb} MB.")
edit("index.html", r"installed, \d+ MB download", f"installed, {size_mb} MB download")
print(f"Website points at {name} ({size_mb} MB); appcast has {version} (build {build}).")
PY
# The whole feed signed too, release notes included (D-256): from 1.7.1, Mactivity refuses a feed
# without a valid signature (SURequireSignedFeed). Any later edit means signing it again.
"$SIGN_UPDATE" --account mactivity "$ROOT/website/appcast.xml" >/dev/null
"$SIGN_UPDATE" --account mactivity --verify "$ROOT/website/appcast.xml" >/dev/null
cp "$DMG" "$ROOT/dist/" 2>/dev/null || true
echo "Review with git diff website/, then publish with make site."
