#!/usr/bin/env bash
# The catalog refresh (owner, 2026-10-05: "you should auto refresh every 12
# hours"; moved to its own droplet every 6 hours, owner-approved 2026-10-12; every 3 hours since 2026-10-18):
# re-download every brand's products, then publish them through the same
# gates a ship uses, so prices, stock, markdowns (brand-sale alerts) and Big
# Cartel prices stay fresh without an app build.
#
# Where it runs: the marracat-refresh droplet (refresh-server/README.md), as
# the systemd unit marracat-refresh.service on a 6-hourly timer. The unit's
# environment selects the droplet behaviour:
#   CATALOG_TARGET=receiver   publish through the least-privilege receiver on
#                             167.71 (scripts/publish_catalog.sh, then
#                             scripts/publish_web_data.sh: data only, no code)
#   MARRACAT_ALERTS=email     warnings are emailed (refresh-server/notify.py);
#                             a failed run is emailed by the unit's OnFailure
# Run by hand on the Mac (the fallback if the droplet is down) it publishes as
# root the old way and deploys the committed website with web/deploy.sh; follow
# it with scripts/refresh_ml.sh.
#
# NOT run here: the Apple-silicon steps (photo roles' fetch + MobileCLIP, the
# photo category check, meaning vectors). They run nightly on the Mac
# (scripts/refresh_ml.sh, launchd com.marracat.catalog-refresh) and send their
# outputs up: catalog/photo_moves.json (applied by build_catalog.py) and the
# photo-role cache (applied below without fetching anything). They may lag a
# day; nothing breaks.
# Also not run: Jev re-categorising (TypeSafe bills per call).
#
#   scripts/refresh_catalog.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${MARRACAT_VENV:+$MARRACAT_VENV/bin:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# The suggestion speed test's budget on this 2-vCPU droplet (owner's Mac:
# 400 ms). 'th' took 411 ms here and failed 5 of 7 refreshes on 2026-11-01,
# so no catalog published; double still fails a real slowdown, and the Mac
# keeps the tight budget for code changes (web/tests/search-suggestions).
export SUGGEST_BUDGET_MS="${SUGGEST_BUDGET_MS:-800}"
# The same for /api/query's index test (3 s on the Mac; over 3 s here 2026-11-11).
export QUERY_BUDGET_MS="${QUERY_BUDGET_MS:-8000}"
PY="${MARRACAT_VENV:-$HOME/.venvs/marracat}/bin/python"
[[ -x "$PY" ]] || PY=python3
LOCK=build/catalog-refresh.lock
# Where the Mac's nightly ML outputs land (rrsync, refresh-server/README.md).
ML_IN="${MARRACAT_EXCHANGE:-}/in"
mkdir -p build

notify() {
    echo "$(date '+%F %T') catalog refresh: $1"
    if [[ "${MARRACAT_ALERTS:-}" == email ]]; then
        python3 refresh-server/notify.py "Marracat catalog refresh: $1" "$2" || echo "(alert email failed)"
    else
        osascript -e "display notification \"$1 (see build/catalog-refresh.log)\" with title \"Marracat catalog refresh\"" 2>/dev/null || true
    fi
}
# A step that stops the run. On the droplet the unit's OnFailure emails the
# log tail (one email, not two), so this only says where it stopped.
fail() {
    if [[ "${MARRACAT_ALERTS:-}" == email ]]; then echo "$(date '+%F %T') catalog refresh: FAILED at: $1"
    else notify "FAILED at: $1" ""; fi
    exit 1
}

# A ship of THIS repo (another project's scripts/ship.sh, e.g. Find A Crib's,
# matched the plain pgrep and skipped runs, 2026-10-12).
ship_running() {
    local pid here; here=$(pwd -P)
    for pid in $(pgrep -f "scripts/ship.sh" || true); do
        [[ "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "$here" ]] && return 0
        [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$here" ]] && return 0
    done
    return 1
}
if ship_running; then echo "$(date '+%F %T') a ship is running; skipped"; exit 0; fi
if ! mkdir "$LOCK" 2>/dev/null; then
    # A lock older than 3 hours is left over from a crashed run.
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +180 2>/dev/null)" ]]; then rmdir "$LOCK"; mkdir "$LOCK"
    else echo "$(date '+%F %T') another refresh is running; skipped"; exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

step() { echo "==> $(date '+%T') $1"; }
run() { local name="$1"; shift; step "$name"; "$@" || fail "$name"; }

echo "=== $(date '+%F %T') catalog refresh"
# The Mac's latest photo outputs, when this is the droplet. Each must be a
# JSON object, or the copy in the checkout stays.
if [[ -n "${MARRACAT_EXCHANGE:-}" ]]; then
    step "taking the Mac's photo outputs"
    for pair in "photo_moves.json:catalog/photo_moves.json" "photo_roles.json:catalog/.cache/photo_roles.json"; do
        src="$ML_IN/${pair%%:*}"; dst="${pair#*:}"
        if [[ -s "$src" ]] && python3 -c "import json,sys; assert isinstance(json.load(open(sys.argv[1])), dict)" "$src" 2>/dev/null; then
            mkdir -p "$(dirname "$dst")"; cp "$src" "$dst.new" && mv -f "$dst.new" "$dst"
            echo "   $dst from the Mac ($(date -r "$src" '+%F %T'))"
            if [[ -n "$(find "$src" -mmin +4320 2>/dev/null)" ]]; then
                notify "the Mac's photo outputs are over 3 days old" "$src was last sent $(date -r "$src" '+%F %T'). Is the Mac's nightly com.marracat.catalog-refresh (scripts/refresh_ml.sh) running? The catalog still publishes; new products just miss photo moves and photo roles."
            fi
        else
            echo "   no usable $src; keeping $dst"
        fi
    done
fi
run "fetching every store"        "$PY" catalog/build_catalog.py
run "folding repeat listings"     "$PY" catalog/dedupe_products.py
# Products far from their brand's usual department, checked by Jev (at most
# 2,000 questions, ~4 cents; cached, so only new or edited products are asked).
# Jev trouble or no key only skips the asking; cached verdicts still apply.
run "brand fit"                   python3 catalog/brand_fit.py --ask
run "clean badge"                 python3 catalog/clean_badge.py --scrape --max-new 300
run "true metal badge"            python3 catalog/metal_badge.py
run "clear scent badge"           python3 catalog/scent_badge.py --scrape --max-new 200
run "safer clean badge"           python3 catalog/safer_clean_badge.py --scrape --max-new 200
run "clean food badge"            python3 catalog/food_badge.py --scrape --max-new 200
run "baby safe badge"             python3 catalog/baby_badge.py --scrape --max-new 200
run "natural fiber badge"         python3 catalog/fiber_badge.py
run "safe fabric badge"           python3 catalog/fabric_badge.py
run "lab verified badge"          python3 catalog/lab_badge.py
run "pet safe badge"              python3 catalog/pet_badge.py --scrape --max-new 200
run "true material badge"         python3 catalog/material_badge.py
run "natural home badge"          python3 catalog/home_badge.py
run "auditing categories"         python3 catalog/audit_categories.py --max-risky 30
# Shopper filters, colourways, best photo per place (owner, 2026-10-10).
run "attribute filters"           python3 catalog/attributes.py
# Women / Men on clothing and shoes, after attributes.py rebuilds attrs (owner,
# 2026-11-08). Up to 60 stale brands' Shopify collections are re-read a run.
run "gender (women / men)"        python3 catalog/gender.py --fetch 60
run "colorways"                   python3 catalog/colorways.py
# Tile/hero photo choice from the cached photo stats only (--max-new 0: no
# fetching, no MobileCLIP); the Mac fills the cache nightly.
step "photo roles (cached)"; python3 catalog/photo_roles.py --max-new 0 || notify "photo roles failed (continuing)" "catalog/photo_roles.py --max-new 0 failed; the catalog publishes without tile/hero picks."
# Again now the tiles are picked: two listings can open on different photos
# yet tile on the same one (catalog/dedupe_products.py, 2026-10-25).
run "folding repeat tiles"        "$PY" catalog/dedupe_products.py
# catalog.bin is the app bundle's (ship.sh); it needs Xcode, so not here.
run "compacting"                  python3 catalog/make_compact.py --no-binary
run "publishing the catalog"      ./scripts/publish_catalog.sh
if [[ "${CATALOG_TARGET:-droplet}" == receiver ]]; then
    run "deploying marracat.com data" ./scripts/publish_web_data.sh
else
    # web/deploy.sh ships the working tree's website code along with the
    # catalog. Uncommitted website changes mean someone is mid-edit: wait for
    # them (up to an hour), and never ship them from here (2026-10-05).
    for _ in $(seq 1 12); do git diff --quiet HEAD -- web/ && break; echo "website has uncommitted changes; waiting"; sleep 300; done
    if git diff --quiet HEAD -- web/; then run "deploying marracat.com" ./web/deploy.sh
    else fail "deploy skipped: uncommitted website changes (app catalog is published)"; fi
fi
# What the Mac's nightly ML job pulls (scripts/pull_catalog.sh): this run's
# catalog and the generated state files, so its commits carry fresh state.
if [[ -n "${MARRACAT_EXCHANGE:-}" ]]; then
    step "handing the catalog to the Mac"
    out="$MARRACAT_EXCHANGE/out"
    mkdir -p "$out/state"
    for f in Marracat/Resources/catalog.json Marracat/Resources/catalog-compact.json; do
        cp "$f" "$out/.$(basename "$f").new" && mv -f "$out/.$(basename "$f").new" "$out/$(basename "$f")"
    done
    git diff --name-only -- catalog/ | while read -r f; do cp "$f" "$out/state/$(basename "$f")"; done
fi
echo "=== $(date '+%F %T') done: $(python3 -c "import json;print(len(json.load(open('Marracat/Resources/catalog.json'))['products']))") products"
