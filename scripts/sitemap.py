#!/usr/bin/env python3
"""Writes sitemap.xml for mactivity.app (scripts/site.sh runs it on the staged site).

Every page in website/ except those marked noindex and the 404 page, at its clean address
(/download for download.html, as wrangler.jsonc's html_handling serves it), with the date its file last
changed in git. The changelog's date is the update feed's, since the feed is what fills it.
    scripts/sitemap.py <staged site folder>
"""
import os
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
site = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build", "site")
website = os.path.join(root, "website")
base = "https://mactivity.app"


def last_changed(*paths):
    """The newest commit date (YYYY-MM-DD) among the given repo paths."""
    out = subprocess.run(
        ["git", "-C", root, "log", "-1", "--format=%cs", "--", *paths],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    return out or None


urls = []
for name in sorted(os.listdir(website)):
    if not name.endswith(".html") or name == "404.html":
        continue
    text = open(os.path.join(website, name)).read()
    if 'name="robots" content="noindex"' in text:
        continue
    path = "/" if name == "index.html" else "/" + name[: -len(".html")]
    sources = [f"website/{name}"] + (["website/appcast.xml", "docs/releases"] if name == "changelog.html" else [])
    urls.append((path, last_changed(*sources)))

# The home page first, then the rest alphabetically.
urls.sort(key=lambda entry: (entry[0] != "/", entry[0]))
lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
for path, date in urls:
    lastmod = f"<lastmod>{date}</lastmod>" if date else ""
    lines.append(f"  <url><loc>{base}{path}</loc>{lastmod}</url>")
lines.append("</urlset>")
open(os.path.join(site, "sitemap.xml"), "w").write("\n".join(lines) + "\n")
print(f"Sitemap: {len(urls)} pages.")
