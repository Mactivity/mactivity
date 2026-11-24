#!/bin/bash
# Stages the website plus the current installers and deploys them to Cloudflare as a Worker with
# static assets (wrangler.jsonc; Cloudflare's successor to Pages, D-076).
#   scripts/site.sh            deploy (needs a wrangler login once, below)
#   scripts/site.sh preview    serve the staged site on http://localhost:8000
set -euo pipefail

# Mactivity's own wrangler login, separate from any other Cloudflare work on this Mac, so a deploy
# can't land in the wrong account. Sign in once with:
#   XDG_CONFIG_HOME="$HOME/.config/mactivity-wrangler" tools/site/node_modules/.bin/wrangler login
export XDG_CONFIG_HOME="${MACTIVITY_WRANGLER_HOME:-$HOME/.config/mactivity-wrangler}"
# The Cloudflare account that owns the site's zone. The login can see several accounts; pinning
# the ID means a deploy never lands in another one (D-076). It isn't kept in the repo: set
# CLOUDFLARE_ACCOUNT_ID, or put the ID in $XDG_CONFIG_HOME/account-id.
if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" && -r "$XDG_CONFIG_HOME/account-id" ]]; then
    CLOUDFLARE_ACCOUNT_ID="$(tr -d '[:space:]' < "$XDG_CONFIG_HOME/account-id")"
fi
if [[ "${1:-}" != "preview" && -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    echo "No Cloudflare account ID. Set CLOUDFLARE_ACCOUNT_ID or write it to $XDG_CONFIG_HOME/account-id." >&2
    exit 1
fi
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
# wrangler reports each command it runs to Cloudflare unless told not to; Mactivity doesn't do telemetry.
export WRANGLER_SEND_METRICS=false
# The update feed must carry a valid signature (D-256): from 1.7.1, Mactivity refuses an unsigned
# feed, so publishing one would stop updates. publish-version.sh signs it after each release.
SIGN_UPDATE="build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "Sparkle's sign_update is missing; run make build once." >&2; exit 1; }
if ! "$SIGN_UPDATE" --account mactivity --verify website/appcast.xml >/dev/null 2>&1; then
    echo "website/appcast.xml isn't signed, or changed since it was. Sign it: $SIGN_UPDATE --account mactivity website/appcast.xml" >&2
    exit 1
fi
STAGE=build/site
rm -rf "$STAGE"
mkdir -p "$STAGE/download"
cp -R website/. "$STAGE/"
rm -f "$STAGE/README.md"
# Installers built by `make beta` / `make release`. Workers static assets allow up to 25 MiB per file.
shopt -s nullglob
for file in dist/*.dmg dist/*.zip; do
    cp "$file" "$STAGE/download/"
done
find "$STAGE" -name .DS_Store -delete
# security.txt must not be past its Expires date (RFC 9116); renew it in website/.well-known/.
expires="$(sed -n 's/^Expires: \(.\{10\}\).*/\1/p' website/.well-known/security.txt)"
if [[ -z "$expires" || "$expires" < "$(date -u +%Y-%m-%d)" ]]; then
    echo "website/.well-known/security.txt has expired ($expires). Set a new Expires date first." >&2
    exit 1
fi
# The changelog, from the update feed and docs/releases/.
python3 scripts/changelog.py "$STAGE"
# Every indexable page, for search engines (robots.txt points at it).
python3 scripts/sitemap.py "$STAGE"
echo "Staged $(find "$STAGE" -type f | wc -l | tr -d ' ') files into $STAGE:"
ls -1 "$STAGE/download"

if [ "${1:-}" = "preview" ]; then
    cd "$STAGE" && exec python3 -m http.server 8000
fi
# wrangler from tools/site's lockfile (D-256), every package checked against its recorded hash and
# none of their install scripts run: never whatever npm has newest that day.
npm ci --prefix tools/site --ignore-scripts --no-audit --no-fund --silent
tools/site/node_modules/.bin/wrangler deploy

# A new installer takes a few seconds to reach Cloudflare's edge; the feed may already list it.
# Wait until the newest one downloads, so an update check never meets a 404 unnoticed.
newest="$(ls -t dist/*.dmg 2>/dev/null | head -1 || true)"
if [ -n "$newest" ]; then
    url="https://mactivity.app/download/$(basename "$newest")"
    for _ in $(seq 24); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$url")" = "206" ] || [ "$(curl -s -o /dev/null -w '%{http_code}' -I "$url")" = "200" ]; then
            echo "✓ $url is live."
            exit 0
        fi
        sleep 5
    done
    echo "⚠︎ $url still isn't downloadable after 2 minutes. Check it before announcing the release." >&2
    exit 1
fi
