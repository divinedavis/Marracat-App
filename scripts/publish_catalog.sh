#!/usr/bin/env bash
# Publish Marracat/Resources/catalog.json to where the app fetches it, so brands
# and prices change without an App Store build.
#
# The app reads CatalogStore.remoteURL. Marracat's domain proxies this GitHub
# origin, so the default publishes updates for both new and older app builds.
# See web/README.md for the domain configuration. The optional droplet target
# is for a future direct-file host, not the current proxy setup.
#
#   ./scripts/publish_catalog.sh
#   ALLOW_SHRINK=1 ./scripts/publish_catalog.sh   # a >10% product drop is intended
#   CATALOG_SKIP_TESTS=1 ./scripts/publish_catalog.sh   # ship.sh already tested
#   CATALOG_TARGET=droplet CATALOG_HOST=user@host:/var/www/catalog ./scripts/publish_catalog.sh
#   CATALOG_TARGET=receiver ./scripts/publish_catalog.sh   # the refresh droplet
#
# receiver (the marracat-refresh droplet, 2026-10-12): the same gates, but the
# files go to 167.71 through a key that can only upload named catalog files
# and ask for the swap (refresh-server/receiver/); the swap, snapshot, served-
# bytes check and rollback run there as root (marracat-catalog-swap).
set -euo pipefail
cd "$(dirname "$0")/.."
md5of() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }

SRC=Marracat/Resources/catalog.json
[[ -f "$SRC" ]] || { echo "error: $SRC missing — run catalog/build_catalog.py first" >&2; exit 1; }
# One read for all of it: valid JSON, and the date and count each target
# reports. Every full load is ~3.7 GB, and this script did five (2026-10-18).
meta=$(python3 -c "import json; c = json.load(open('$SRC')); print(c['generated_at'], len(c['products']))") \
    || { echo "error: $SRC isn't valid JSON" >&2; exit 1; }
read -r generated products <<<"$meta"
# Keep shortages visible on every catalog release, including empty aisles and
# the stricter count of brands with available Buy Now products.
python3 catalog/brand_coverage.py --catalog "$SRC" --output build/brand-coverage

# The droplet, because GitHub refuses a file over 100 MB and catalog-v3.json
# is 107 MB once it carries every product a brand sells. nginx serves the
# gzipped copy beside each file (gzip_static), so the wire cost is 13 MB.
TARGET="${CATALOG_TARGET:-droplet}"
CATALOG_HOST="${CATALOG_HOST:-root@167.71.170.219:/var/www/marracat-catalog}"
case "$TARGET" in
github)
    WORK="${CATALOG_REPO_DIR:-$HOME/.cache/marracat-catalog}"
    if [[ ! -d "$WORK/.git" ]]; then
        git clone -q git@github.com:divinedavis/marracat-catalog.git "$WORK"
    fi
    git -C "$WORK" pull -q --ff-only
    python3 catalog/publish_snapshots.py "$SRC" "$WORK"
    if git -C "$WORK" diff --quiet -- catalog.json catalog-v2.json catalog-v3.json && [[ -f "$WORK/catalog-v3.json" ]] && git -C "$WORK" ls-files --error-unmatch catalog-v3.json >/dev/null 2>&1; then
        echo "catalog: already published, nothing to push"
        exit 0
    fi
    git -C "$WORK" add catalog.json catalog-v2.json catalog-v3.json
    git -C "$WORK" commit -q -m "Catalog $generated — $products products"
    git -C "$WORK" push -q
    echo "catalog: published $products products ($generated)"
    ;;
droplet|receiver)
    # Gates before the copy: the fast tests, then each file must be valid and
    # not >10% smaller than the copy marracat.com serves now. Then what is live
    # is snapshotted (hard links, so it costs nothing until a file is
    # replaced) to /var/backups/marracat-catalog/<ts>, CATALOG_KEEP kept. After
    # the swap, the bytes nginx serves must match what was built, plain and
    # gzipped; if not, the snapshot goes back (scripts/rollback_catalog.sh).
    : "${CATALOG_HOST:?set CATALOG_HOST=user@host:/path/to/docroot}"
    [[ "${CATALOG_SKIP_TESTS:-0}" == 1 ]] || scripts/run_tests.sh
    snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/marracat-snapshots.XXXXXX")
    trap 'rm -rf "$snapshot_dir"' EXIT
    python3 catalog/publish_snapshots.py "$SRC" "$snapshot_dir"
    # Ed25519 signatures beside each file (catalog-v3.json.sig, ...): the app
    # refuses a downloaded catalog whose signature doesn't check out. The key
    # stays on this Mac (~/.config/marracat/catalog-signing.key).
    python3 scripts/sign_catalog.py "$snapshot_dir/catalog.json" "$snapshot_dir/catalog-v2.json" "$snapshot_dir/catalog-v3.json"
    python3 scripts/sign_catalog.py --verify "$snapshot_dir/catalog-v3.json"
    python3 scripts/check_catalog.py \
        "$snapshot_dir/catalog-v3.json" https://marracat.com/catalog-v3.json \
        "$snapshot_dir/catalog-v2.json" https://marracat.com/catalog-v2.json \
        "$snapshot_dir/catalog.json" https://marracat.com/catalog.json
    # Deltas (2026-10-18, catalog/catalog_delta.py): what changed since each
    # recent version, ~0.5 MB against 13.9, signed like the catalog. Optional:
    # if anything here fails, the full catalog publishes alone and phones
    # download it whole, as before.
    deltas="$snapshot_dir/deltas"
    if python3 catalog/catalog_delta.py "$snapshot_dir/catalog-v3.json" "$deltas"; then
        for d in "$deltas"/delta-*.json; do
            [[ -f "$d" ]] || continue
            { python3 scripts/sign_catalog.py "$d" && python3 scripts/sign_catalog.py --verify "$d" && gzip -6 -k -f "$d"; } \
                || { echo "warning: $(basename "$d") not signed; left out" >&2; rm -f "$d" "$d.sig" "$d.gz"; }
        done
    else
        echo "warning: no deltas this publish; phones take the full catalog" >&2
        rm -rf "$deltas"
    fi
    if [[ "$TARGET" == receiver ]]; then
        PUB="${PUBLISH_SSH:-marracat-pub@10.108.0.3}"
        for name in catalog.json catalog-v2.json catalog-v3.json; do
            gzip -6 -k -f "$snapshot_dir/$name"
            for f in "$name" "$name.gz" "$name.sig"; do
                got=$(ssh -o BatchMode=yes "$PUB" put "$f" < "$snapshot_dir/$f")
                [[ "$got" == "$(md5of "$snapshot_dir/$f")" ]] || { echo "error: upload of $f arrived damaged" >&2; exit 1; }
            done
        done
        # Deltas ride along under catalog-v3-<name>; the swap puts them live only
        # after the catalog itself (receiver/marracat-catalog-deltas). A receiver
        # that refuses them still swaps the catalog.
        for f in "$deltas"/manifest-*.json.gz "$deltas"/delta-*.json "$deltas"/delta-*.json.gz "$deltas"/delta-*.json.sig; do
            [[ -f "$f" ]] || continue
            got=$(ssh -o BatchMode=yes "$PUB" put "catalog-v3-$(basename "$f")" < "$f") || { echo "warning: receiver refused $(basename "$f")" >&2; continue; }
            [[ "$got" == "$(md5of "$f")" ]] || echo "warning: $(basename "$f") arrived damaged" >&2
        done
        ssh -o BatchMode=yes "$PUB" catalog-swap
        echo "catalog: published $products products through $PUB"
        exit 0
    fi
    host="${CATALOG_HOST%%:*}"; path="${CATALOG_HOST#*:}"
    ssh "$host" "mkdir -p '$path'"
    # One file up, resuming where a dropped transfer stopped (2026-10-21: a
    # home link dropped the 100 MB catalog three ships running, scp left no
    # .tmp and the swap found nothing). Up to 4 tries; fails the publish
    # rather than swapping in a partial file. $3 caps the speed in KB/s.
    # Each file is checked on the server after it lands (md5) and sent again
    # whole if it differs: a resumed upload over a stale partial from an
    # earlier run came out wrong once (catalog-v2, 2026-10-21).
    push() {
        local src=$1 dest=$2 limit=${3:-} want got
        want=$(md5of "$src")
        for attempt in 1 2 3 4; do
            if rsync -q --partial --timeout=60 ${limit:+--bwlimit=$limit} \
                -e "ssh -o IPQoS=none -o ServerAliveInterval=15 -o ServerAliveCountMax=4" "$src" "$dest"; then
                got=$(ssh "$host" "md5sum '${dest#*:}' 2>/dev/null" | cut -d' ' -f1)
                [[ "$got" == "$want" ]] && return 0
                echo "  $(basename "$src") arrived different (try $attempt of 4); sending it whole" >&2
                ssh "$host" "rm -f '${dest#*:}'"
            else
                echo "  upload of $(basename "$src") dropped (try $attempt of 4); resuming" >&2
            fi
            sleep $((attempt * 5))
        done
        echo "error: could not upload $(basename "$src") to $CATALOG_HOST" >&2
        exit 1
    }
    # No half-uploads left over from an earlier run to resume from.
    ssh "$host" "rm -f '$path'/*.tmp"
    for name in catalog.json catalog-v2.json catalog-v3.json; do
        # gzip_static wants file.gz beside file; -k keeps both, and nginx picks
        # whichever the client can take.
        gzip -6 -k -f "$snapshot_dir/$name"
        push "$snapshot_dir/$name" "$CATALOG_HOST/$name.tmp" 1000
        push "$snapshot_dir/$name.gz" "$CATALOG_HOST/$name.gz.tmp" 1000
        push "$snapshot_dir/$name.sig" "$CATALOG_HOST/$name.sig.tmp"
    done
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    backups=/var/backups/marracat-catalog
    # Taken after the upload, right before the swap, so the snapshot is
    # exactly what visitors were being served. *.tmp are this upload's files.
    ssh "$host" "set -e; mkdir -p $backups/$ts; cd '$path'
        for f in catalog*.json catalog*.json.gz catalog*.json.sig; do [ -f \"\$f\" ] && ln \"\$f\" $backups/$ts/\"\$f\"; done
        ls -1d $backups/*/ | head -n -${CATALOG_KEEP:-8} | xargs -r rm -rf"
    echo "catalog: snapshot $backups/$ts (scripts/rollback_catalog.sh $ts)"
    ssh "$host" "cd '$path' && for name in catalog.json catalog-v2.json catalog-v3.json; do mv \"\$name.tmp\" \"\$name\"; mv \"\$name.gz.tmp\" \"\$name.gz\"; mv \"\$name.sig.tmp\" \"\$name.sig\"; done"
    # What visitors get must be byte-for-byte what was built.
    expect=""
    for name in catalog.json catalog-v2.json catalog-v3.json; do
        expect+="$name $(md5of "$snapshot_dir/$name") $(md5of "$snapshot_dir/$name.gz") "
    done
    if ! ssh "$host" bash -s -- $expect <<'CHECK'
set -u
bad=0
while (( $# )); do
  name=$1 plain=$2 gz=$3; shift 3
  got=$(curl -fsS --resolve marracat.com:443:127.0.0.1 "https://marracat.com/$name" | md5sum | cut -d' ' -f1)
  gotgz=$(curl -fsS -H 'Accept-Encoding: gzip' --resolve marracat.com:443:127.0.0.1 "https://marracat.com/$name" | md5sum | cut -d' ' -f1)
  if [[ "$got" == "$plain" && "$gotgz" == "$gz" ]]; then echo "   served $name: ok"; else echo "!! served $name does not match the build" >&2; bad=1; fi
done
exit $bad
CHECK
    then
        echo "!! the published catalog is not what nginx serves; rolling back to $ts" >&2
        CATALOG_HOST="$CATALOG_HOST" scripts/rollback_catalog.sh "$ts"
        exit 1
    fi
    # Always called, even with no deltas: then it clears the list, so no phone
    # is told the replaced version is current.
    remote=$(ssh "$host" mktemp -d)
    if [[ -d "$deltas" ]] && ls "$deltas"/* >/dev/null 2>&1; then
        scp -q -o IPQoS=none "$deltas"/* "$host:$remote/" || echo "warning: deltas not uploaded; phones take the full catalog" >&2
    fi
    ssh "$host" "/usr/local/sbin/marracat-catalog-deltas '$remote'; rm -rf '$remote'" \
        || echo "warning: deltas not published; phones take the full catalog" >&2
    echo "catalog: published $products products to $CATALOG_HOST"
    ;;
*)
    echo "error: unknown CATALOG_TARGET '$TARGET' (github|droplet|receiver)" >&2
    exit 1
    ;;
esac
