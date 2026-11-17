#!/usr/bin/env bash
# Deploy marracat.com (Node app, static build, nginx site) to the droplet.
#
#   ./web/deploy.sh
#   WEB_SKIP_CHECKS=1 ./web/deploy.sh   # skip the test run + rebuild (know why)
#   ALLOW_SHRINK=1 ./web/deploy.sh      # the catalog is meant to lose >10%
#   SHIP_LOCAL_CATALOG=1 ./web/deploy.sh  # ship this Mac's catalog even if live is newer
#
# Gates, in order: scripts/run_tests.sh; the bundled catalog must be valid and
# not >10% smaller than what /api/catalog serves (scripts/check_catalog.py);
# then on the box, what is live is snapshotted to /var/backups/marracat-web/
# <release id> (15 kept) before anything changes. After the switch the box
# checks health, the signed-out session, the homepage and its JS bundle, and
# that /api/home serves the catalog just shipped; this Mac then checks the
# public site and the full /api/catalog product count. Any failure restores
# the snapshot (web/restore-snapshot.sh) and exits 1. Restore by hand with
# scripts/rollback_web.sh <release id>.
set -euo pipefail
cd "$(dirname "$0")"

# Refuse to deploy a checkout that is behind origin/main: it would silently roll
# back fixes other sessions already shipped (on 11/7 a stale main checkout would
# have put Google Fonts back on the live site). ALLOW_BEHIND=1 to override.
if [ "${ALLOW_BEHIND:-}" != 1 ]; then
  git fetch -q origin main || { echo "!! git fetch failed; cannot confirm this checkout is current (ALLOW_BEHIND=1 to override)" >&2; exit 1; }
  behind=$(git rev-list --count HEAD..origin/main)
  if [ "$behind" -gt 0 ]; then
    echo "!! this checkout is $behind commit(s) behind origin/main - pull/rebase first (ALLOW_BEHIND=1 to override)" >&2
    exit 1
  fi
fi
HOST=root@167.71.170.219
if [[ "${WEB_SKIP_CHECKS:-0}" != 1 ]]; then
  ../scripts/run_tests.sh
  npm run build
fi
# The catalog is build output, not a tracked file (it passed GitHub's 100 MB
# limit at every product a brand sells). A fresh checkout builds it with
# catalog/build_catalog.py, or pulls the published copy.
if [[ ! -f ../Marracat/Resources/catalog.json ]]; then
  echo "error: Marracat/Resources/catalog.json is missing." >&2
  echo "  build it:  ~/.venvs/marracat/bin/python catalog/build_catalog.py --cached" >&2
  echo "  or copy:   cp -a <another checkout>/Marracat/Resources/catalog.json ../Marracat/Resources/" >&2
  echo "  (not marracat.com/catalog-v2.json: it is a slim copy, ~56k of ~147k products, and the shrink check refuses it)" >&2
  exit 1
fi
# The catalog data ships only when this Mac's copy is at least as new as what
# is live. The refresh droplet publishes a fresh one every 6 hours
# (scripts/publish_web_data.sh), so the Mac's is usually older: shipping it
# swapped 154,189 live products for 148,900 and took down that day's 22 new
# brands until the droplet's copy was republished (2026-10-15). An older copy
# keeps the live data files, and only the code changes.
# SHIP_LOCAL_CATALOG=1 ships this Mac's copy anyway.
read -r now_generated now_products now_product_id < <(curl -fsS --compressed --max-time 300 https://marracat.com/api/catalog | python3 -c "
import json, sys; d = json.load(sys.stdin); ps = d.get('products') or [{}]
print(d.get('generated_at') or '-', len(d.get('products') or []), ps[0].get('id') or '-')") || now_generated="-"
local_generated=$(python3 -c "import json; print(json.load(open('../Marracat/Resources/catalog.json'))['generated_at'])")
keep_live_data=0
if [[ "${SHIP_LOCAL_CATALOG:-0}" != 1 && "$now_generated" != "-" && "$local_generated" < "$now_generated" ]]; then
  keep_live_data=1
  echo "   catalog: this Mac's ($local_generated) is older than live ($now_generated); keeping the live data, shipping code only"
fi
rm -f server/catalog-slim.json server/product-details.sqlite
if [[ "$keep_live_data" == 1 ]]; then
  expect_generated="$now_generated" expect_products="$now_products" expect_product_id="$now_product_id"
else
  python3 ../scripts/check_catalog.py ../Marracat/Resources/catalog.json https://marracat.com/api/catalog
  cp ../Marracat/Resources/catalog.json server/catalog-source.json
  # What the checks after the switch expect the site to serve.
  # The products it lists, not every one in the file (scripts/website_listed.py).
  read -r expect_generated expect_products expect_product_id < <(python3 ../scripts/website_listed.py server/catalog-source.json)
  # The server holds a slim list in memory and reads full product records from
  # SQLite (scripts/split_server_catalog.py): the whole catalog in memory ran
  # the 2 GB droplet out of heap at 120,873 products (2026-10-02).
  python3 ../scripts/split_server_catalog.py server/catalog-source.json server
  rm server/catalog-source.json
fi
# Only explicit server files and the public build are deployed. No source env files.
release_id="$(date -u +%Y%m%dT%H%M%SZ)"
release_path="/opt/marracat-web/releases/$release_id"
ssh "$HOST" "mkdir -p '$release_path'"
# The page's script and stylesheet ship already compressed. nginx was
# compressing them on every request at its default level 1 (181 KB for the
# script); gzip -9 once here is 153 KB and costs the droplet nothing
# (gzip_static in nginx.conf's /assets/). The names carry a content hash, so a
# stale .gz can't outlive its file.
find dist/assets -name '*.gz' -delete
for f in dist/assets/*.js dist/assets/*.css; do gzip -9 -k -n "$f"; done
bundle_path=$(mktemp "${TMPDIR:-/tmp}/marracat-web.XXXXXX")
trap 'rm -f "$bundle_path"' EXIT
tar -czf "$bundle_path" package.json package-lock.json server dist metrics mail backup nginx.conf marracat-web.service restore-snapshot.sh src/catalog.js src/catalog-format.js src/attrs.js src/colorways.js src/colors.js src/search-words.js src/search-synonyms.json
# Bound SFTP packets and transfer rate for connections with small tunnel buffers.
scp -q -l 8000 -X buffer=8192 -X nrequests=1 -o IPQoS=none "$bundle_path" "$HOST:$release_path/source.tar.gz"
ssh "$HOST" bash -s -- "$release_path" "$expect_generated" "$expect_product_id" "$keep_live_data" <<'REMOTE'
set -euo pipefail
release_path="$1"
expect_generated="$2"
expect_product_id="$3"
keep_live_data="$4"
cd "$release_path"
tar -xzf source.tar.gz
rm source.tar.gz
if [[ "$keep_live_data" == 1 ]]; then
  # The live release's catalog data, linked rather than copied (~520 MB).
  cp -al /opt/marracat-web/current/server/catalog-slim.json /opt/marracat-web/current/server/product-details.sqlite server/
fi
if [[ -d /opt/marracat-web/current/node_modules ]] && cmp -s package-lock.json /opt/marracat-web/current/package-lock.json; then
  cp -al /opt/marracat-web/current/node_modules node_modules
else
  npm ci --omit=dev --no-fund
fi
id marracat >/dev/null 2>&1 || useradd --system --home /var/lib/marracat --shell /usr/sbin/nologin marracat
install -d -m 750 -g marracat /etc/marracat
install -d -m 700 -o marracat -g marracat /var/lib/marracat
if [[ ! -f /etc/marracat/web.env ]]; then
  (umask 077; {
    echo NODE_ENV=production
    echo PORT=3107
    echo DATA_DIR=/var/lib/marracat
    echo "AUTH_SECRET=$(openssl rand -hex 32)"
  } > /etc/marracat/web.env)
fi
# The owner dashboard's API (another droplet) reads /api/owner/metrics with this key.
grep -q '^METRICS_KEY=' /etc/marracat/web.env || (umask 077; echo "METRICS_KEY=$(openssl rand -hex 32)" >> /etc/marracat/web.env)
install -d -m 750 -o root -g marracat /var/lib/marracat-metrics
# The metrics job runs as marracat and writes metrics.json here (2026-11-05).
chown marracat:marracat /var/lib/marracat-metrics
# Validate the new Node dependencies before changing the running release.
node --input-type=module -e "import Database from 'better-sqlite3'; const db=new Database(':memory:'); db.close(); console.log('SQLite runtime verified')"
# Snapshot everything this release replaces, so a failed check (here or on
# the Mac) can put it all back: scripts/rollback_web.sh <release id>.
snap="/var/backups/marracat-web/$(basename "$release_path")"
mkdir -p "$snap/www"
find /var/www/marracat -maxdepth 1 -type f -exec cp -p {} "$snap/www/" \;
cp -p /etc/nginx/sites-available/marracat "$snap/nginx.conf"
cp -p /etc/systemd/system/marracat-web.service "$snap/marracat-web.service" 2>/dev/null || true
readlink -e /opt/marracat-web/current > "$snap/release" || echo > "$snap/release"
echo "snapshot $snap"
rollback() {
  echo 'Release verification failed; restoring the snapshot.' >&2
  bash "$release_path/restore-snapshot.sh" "$snap" || true
}
trap rollback ERR
ln -sfn "$release_path" /opt/marracat-web/current.new
mv -Tf /opt/marracat-web/current.new /opt/marracat-web/current
install -m 644 marracat-web.service /etc/systemd/system/marracat-web.service
systemctl daemon-reload
systemctl enable marracat-web >/dev/null
systemctl restart marracat-web
install -m 644 metrics/marracat-metrics.service metrics/marracat-metrics.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now marracat-metrics.timer >/dev/null
systemctl start marracat-metrics.service || echo "Metrics refresh failed; the site release is unaffected." >&2
# Nightly off-box copy of the database to the refresh droplet (backup/,
# 2026-11-05). Its key and pinned host key live in /etc/marracat/backup and
# are made once by hand (refresh-server/README.md, "Database backups").
install -m 755 backup/marracat-db-backup.sh /usr/local/sbin/marracat-db-backup
install -m 644 backup/marracat-db-backup.service backup/marracat-db-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now marracat-db-backup.timer >/dev/null
# hello@marracat.com: file DMARC reports into their own folder (mail/dmarc_sort.py).
install -m 644 mail/marracat-dmarc-sort.service mail/marracat-dmarc-sort.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now marracat-dmarc-sort.timer >/dev/null
# The server loads the whole catalog before it listens: 20-30 s on this
# 1-CPU box by 2026-11-15, when a 10 s wait rolled back a good release.
for attempt in {1..120}; do
  if curl -fsS -H 'Host: marracat.com' http://127.0.0.1:3107/api/health >/dev/null; then break; fi
  sleep 1
done
curl -fsS -H 'Host: marracat.com' http://127.0.0.1:3107/api/health
# Keep existing hashed assets and ACME files so old open browser tabs still work.
cp -R dist/assets /var/www/marracat/
cp dist/*.svg dist/*.png dist/*.ico /var/www/marracat/
cp dist/*.jpg /var/www/marracat/ 2>/dev/null || true   # e.g. app-preview.jpg, the /app link card
# Plain scripts from public/ (bigcartel-go.js, for /go/bigcartel).
cp dist/*.js /var/www/marracat/ 2>/dev/null || true
# Data files from public/ (search-synonyms.json, which the app will load).
cp dist/*.json /var/www/marracat/ 2>/dev/null || true
cp dist/index.html /var/www/marracat/index.html.next
mv /var/www/marracat/index.html.next /var/www/marracat/index.html
install -m 644 nginx.conf /etc/nginx/sites-available/marracat
nginx -t
systemctl reload nginx
# nginx reloads gracefully; wait for the new worker to accept requests.
site_ready=0
for attempt in {1..10}; do
  if [[ $(curl -fsS --resolve marracat.com:443:127.0.0.1 https://marracat.com/api/health || true) == '{"ok":true}' ]]; then
    site_ready=1
    break
  fi
  sleep 1
done
[[ "$site_ready" == 1 ]]
[[ $(curl -fsS --resolve marracat.com:443:127.0.0.1 https://marracat.com/auth/session) == 'null' ]]
# Content, not just status codes: the homepage mounts the app and its bundle
# loads, and the API serves the catalog this release shipped.
page=$(curl -fsS --resolve marracat.com:443:127.0.0.1 https://marracat.com/)
grep -q '<div id="root">' <<<"$page"
bundle=$(grep -oE '/assets/index-[A-Za-z0-9_-]+\.js' <<<"$page" | head -1)
[[ -n "$bundle" ]]
curl -fsS --resolve marracat.com:443:127.0.0.1 "https://marracat.com$bundle" -o /dev/null
curl -fsS --compressed --resolve marracat.com:443:127.0.0.1 https://marracat.com/api/home | grep -qF "\"generated_at\":\"$expect_generated\""
curl -fsS --compressed --resolve marracat.com:443:127.0.0.1 "https://marracat.com/api/products/$expect_product_id" | grep -qF "\"id\":\"$expect_product_id\""
trap - ERR
# Keep 3 snapshots, and the 3 newest releases plus any a snapshot or
# `current` points at (each release carries a ~200 MB catalog).
ls -1d /var/backups/marracat-web/*/ | head -n -3 | xargs -r rm -rf
keep=$( { ls -1d /opt/marracat-web/releases/*/ | sed 's#/$##' | tail -n 3; readlink -e /opt/marracat-web/current; cat /var/backups/marracat-web/*/release; } | sort -u)
for d in /opt/marracat-web/releases/*; do
  grep -qxF "$d" <<<"$keep" || rm -rf "$d"
done
echo "Deployed $release_path"
REMOTE

# The public path (DNS, TLS, CDN-less nginx) and the full catalog count.
release_id=$(basename "$release_path")
public_ok=1
curl -fsS https://marracat.com/ | grep -q '<div id="root">' || public_ok=0
live_products=$(curl -fsS --compressed https://marracat.com/api/catalog | python3 -c "import json,sys; print(len(json.load(sys.stdin)['products']))" || echo 0)
[[ "$live_products" == "$expect_products" ]] || public_ok=0
echo "public check: homepage + /api/catalog $live_products/$expect_products products"
if [[ "$public_ok" != 1 ]]; then
  echo "!! public checks failed; rolling back to the snapshot $release_id" >&2
  ../scripts/rollback_web.sh "$release_id"
  exit 1
fi
