#!/usr/bin/env bash
# The Mac's half of the catalog refresh, nightly (launchd
# com.marracat.catalog-refresh, 01:30; owner-approved split 2026-10-12): the
# steps that need Apple silicon. Everything else runs every 6 hours on the
# marracat-refresh droplet (scripts/refresh_catalog.sh, refresh-server/README.md).
#
#   1. take the droplet's latest catalog + generated state (scripts/pull_catalog.sh --state)
#   2. photo roles: thumbnails + MobileCLIP for new products (cache:
#      catalog/.cache/photo_roles.json)
#   3. photo category check (MobileCLIP2-S4) with Jev-confirmed auto-moves
#      (catalog/photo_moves.json; safety cap, exit 3 = held, see
#      catalog/photo_categories.py)
#   4. send both up to the droplet's exchange/in; its next run applies them
#   5. meaning vectors for new products -> marracat.com/ml (scripts/publish_ml.sh)
#
# Heavy steps run under nice -n 10. A failed step notifies and the rest go on;
# the droplet keeps publishing with the last outputs it got.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ML="$HOME/.venvs/marracat-ml/bin/python"
# Jev confirms each photo auto-move (catalog/photo_categories.py); without the
# key no move is made, and the rest of the step still runs.
key="$HOME/.config/typesafe/api_key"
[[ -f "$key" ]] && export TYPESAFE_API_KEY="$(cat "$key")"
HOST="${MARRACAT_REFRESH_SSH:-marracat-refresh@104.236.122.134}"
KEY="${MARRACAT_EXCHANGE_KEY:-$HOME/.ssh/id_marracat_exchange}"
LOCK=build/catalog-refresh.lock
mkdir -p build

notify() {
    echo "$(date '+%F %T') $1"
    osascript -e "display notification \"$1 (see build/catalog-refresh.log)\" with title \"Marracat nightly photo + AI steps\"" 2>/dev/null || true
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
# A ship holds the catalog files for up to an hour: wait it out rather than
# skip the night (2026-10-21: the 01:30 run skipped and the night's photo checks
# and vectors never ran). Gives up after 6 hours.
waited=0
while ship_running; do
    if (( waited == 0 )); then echo "$(date '+%F %T') a ship is running; waiting for it"; fi
    if (( waited >= 360 )); then notify "a ship ran 6 hours; nightly steps skipped"; exit 0; fi
    sleep 120; waited=$((waited + 2))
done
(( waited )) && echo "$(date '+%F %T') ship finished after ~${waited} min; starting"
if ! mkdir "$LOCK" 2>/dev/null; then
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +180 2>/dev/null)" ]]; then rmdir "$LOCK"; mkdir "$LOCK"
    else echo "$(date '+%F %T') another refresh is running; skipped"; exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
step() { echo "==> $(date '+%T') $1"; }

echo "=== $(date '+%F %T') nightly photo + AI steps (Mac)"
step "taking the droplet's catalog"
./scripts/pull_catalog.sh --state || { notify "could not pull the droplet's catalog; nothing ran"; exit 1; }
step "photo roles"
nice -n 10 "$ML" catalog/photo_roles.py --max-new 2000 --clip 1000 --budget-min 40 || notify "photo roles failed (continuing)"
step "photo category check"
photo_rc=0
nice -n 10 "$ML" catalog/photo_categories.py --max-new 4000 --csv build/photo-category-flags.csv \
    --auto-move --move-log build/photo-category-moves.csv || photo_rc=$?
if [[ $photo_rc -eq 3 ]]; then notify "photo auto-moves held by the safety cap (see build/photo-category-moves.csv; continuing)"
elif [[ $photo_rc -ne 0 ]]; then notify "photo category check failed (continuing)"; fi
step "sending photo outputs to the droplet"
# Real rsync (Homebrew's, unlinked; see scripts/pull_catalog.sh): rrsync
# refuses macOS's openrsync.
/opt/homebrew/opt/rsync/bin/rsync -t -z -e "ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20" \
    catalog/photo_moves.json catalog/.cache/photo_roles.json "$HOST:in/" \
    || notify "could not send photo outputs to the droplet (continuing)"
step "meaning vectors"
# Each run's peak memory goes in this log (owner, 2026-11-01: "dont go over
# 15gb"; an S4 run reached 18 GB that day, swapping the Mac under a build).
peak() {
    local out="build/.peak-$$" rc=0
    /usr/bin/time -l -o "$out" "$@" || rc=$?
    awk -v what="$*" '/peak memory footprint/ { printf "   peak memory %.1f GB: %s\n", $1 / 1073741824, what }' "$out" 2>/dev/null || true
    rm -f "$out"
    return $rc
}
./scripts/ram_guard.sh 6 "embedding"
# S4 for app builds from 2026-10-24, S0 for the ones before them (each only
# embeds new or changed products; S4 reads ~16 a second on this Mac).
if peak nice -n 10 "$ML" catalog/embed_products.py --model s0 --publish \
   && peak nice -n 10 "$ML" catalog/embed_products.py --model s4 --publish \
   && ./scripts/publish_ml.sh; then :; else notify "meaning vectors failed"; fi
echo "=== $(date '+%F %T') done"
