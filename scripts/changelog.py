#!/usr/bin/env python3
"""Fills the changelog page for mactivity.app (scripts/site.sh runs it on the staged site).

Every version in website/appcast.xml, newest first, with its date from the feed and its notes from
docs/releases/<version>.md ("- " lines). Versions not in the feed yet stay off the page.
    scripts/changelog.py <staged site folder>
"""
import email.utils
import html
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
site = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build", "site")
feed = open(os.path.join(root, "website", "appcast.xml")).read()

def inline(text):
    """Escapes a note, then renders its **bold** and `code`."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


entries = []
for item in re.findall(r"<item>(.*?)</item>", feed, flags=re.S):
    version = re.search(r"<sparkle:shortVersionString>([^<]+)", item).group(1)
    date = email.utils.parsedate_to_datetime(re.search(r"<pubDate>([^<]+)", item).group(1))
    notes_path = os.path.join(root, "docs", "releases", f"{version}.md")
    notes = []
    if os.path.exists(notes_path):
        notes = [line[2:].strip() for line in open(notes_path) if line.startswith("- ") and line[2:].strip()]
    entries.append((version, date, notes))

blocks = []
for version, date, notes in entries:
    items = "".join(f"<li>{inline(note)}</li>" for note in notes) or "<li>Fixes and improvements.</li>"
    when = f"{date.strftime('%B')} {date.day}, {date.year}"
    blocks.append(
        f'<article class="release" id="v{html.escape(version)}"><header><h2>Mactivity {html.escape(version)}</h2>'
        f'<time datetime="{date.date().isoformat()}">{when}</time></header><ul>{items}</ul></article>'
    )

page_path = os.path.join(site, "changelog.html")
page = open(page_path).read()
page = page.replace("<!-- RELEASES -->", "\n".join(blocks))
open(page_path, "w").write(page)
print(f"Changelog: {len(entries)} releases.")
