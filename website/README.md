# mactivity.app

Static site: the pages (`index.html`, `download.html`, `privacy.html`, `changelog.html`, `roadmap.html`, `404.html`), `llms.txt`, `robots.txt`, and `appcast.xml`, the signed Sparkle feed the app reads. Never hand-edit the feed: `make release` writes and signs it, and `make site` refuses an unsigned one (D-256). The site's own scripts are `app.js` and `replica.js` (the working replica of the app). The only build step is the sitemap, made by `make site`.

Hosted on Cloudflare as a **Worker with static assets** (`wrangler.jsonc` at the repo root; D-076). There is no Worker code: everything is a static file.
- `_headers`: security headers (a CSP that allows only the site's own scripts and Cloudflare's analytics beacon) and caching (installers are immutable, the appcast is fresh).
- `_redirects`: `/download/latest` points at the current installer.

Deploy with `make site`. It stages this folder plus `dist/*.dmg` and `dist/*.zip` under `/download/` into `build/site`, then runs `npx wrangler deploy` with a Mactivity-only login pinned to the right account (see `scripts/site.sh`). Preview locally with `make site-preview` (http://localhost:8000; `_headers` and `_redirects` only apply on Cloudflare).