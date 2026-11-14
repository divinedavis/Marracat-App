#!/usr/bin/env bash
# marracat.com's catalog data, without its code (the refresh droplet,
# 2026-10-12). The refresh used to run web/deploy.sh, which ships whatever
# website code the checkout holds as root; from the refresh droplet only the
# two data files change, through a key that can do nothing else
# (refresh-server/receiver/):
#
#   1. scripts/check_catalog.py: valid, not >10% smaller than /api/catalog
#      (ALLOW_SHRINK=1 when intended)
#   2. scripts/split_server_catalog.py -> catalog-slim.json + product-details.sqlite
#   3. upload both (each checked by md5 on arrival)
#   4. web-data-release on 167.71 (root, marracat-web-data-release): a new
#      release = the current one's code + these files, the same snapshot,
#      switch, restart and content checks as web/deploy.sh, restored on failure
#   5. here: the public site and the full /api/catalog count; a mismatch rolls
#      back to the snapshot of step 4
#
# Website code still ships only with web/deploy.sh, from the Mac.
#
#   CATALOG_TARGET=receiver scripts/publish_web_data.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PUB="${PUBLISH_SSH:-marracat-pub@10.108.0.3}"
md5of() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
SRC=Marracat/Resources/catalog.json
[[ -f "$SRC" ]] || { echo "error: $SRC missing" >&2; exit 1; }
python3 scripts/check_catalog.py "$SRC" https://marracat.com/api/catalog
work=$(mktemp -d "${TMPDIR:-/tmp}/marracat-webdata.XXXXXX")
trap 'rm -rf "$work"' EXIT
# What the site will serve: the products it lists, not every one in the file
# (a title that is only the omitted wording isn't listed; scripts/website_listed.py).
read -r expect_generated expect_products expect_product_id < <(python3 scripts/website_listed.py "$SRC")
python3 scripts/split_server_catalog.py "$SRC" "$work"
for f in catalog-slim.json product-details.sqlite; do
    [[ -s "$work/$f" ]] || { echo "error: split_server_catalog.py wrote no $f" >&2; exit 1; }
    got=$(ssh -o BatchMode=yes "$PUB" put "$f" < "$work/$f")
    [[ "$got" == "$(md5of "$work/$f")" ]] || { echo "error: upload of $f arrived damaged" >&2; exit 1; }
done
# (No tee to /dev/stderr: under systemd's append: logging it can't be reopened.)
out=$(ssh -o BatchMode=yes "$PUB" web-data-release "$expect_generated" "$expect_product_id")
echo "$out"
release_id=$(sed -n 's/^released \([0-9]\{8\}T[0-9]\{6\}Z\)$/\1/p' <<<"$out" | tail -1)
[[ -n "$release_id" ]] || { echo "error: no release id from web-data-release" >&2; exit 1; }
public_ok=1
curl -fsS https://marracat.com/ | grep -q '<div id="root">' || public_ok=0
live_products=$(curl -fsS --compressed https://marracat.com/api/catalog | python3 -c "import json,sys; print(len(json.load(sys.stdin)['products']))" || echo 0)
[[ "$live_products" == "$expect_products" ]] || public_ok=0
echo "public check: homepage + /api/catalog $live_products/$expect_products products"
if [[ "$public_ok" != 1 ]]; then
    echo "!! public checks failed; rolling back to the snapshot $release_id" >&2
    ssh -o BatchMode=yes "$PUB" web-rollback "$release_id"
    exit 1
fi
echo "marracat.com data: release $release_id, $expect_products products ($expect_generated)"
