#!/usr/bin/env bash
# Bring the refresh droplet's checkout to origin/main before a run (the unit's
# ExecStartPre, as marracat-refresh), keeping the state the refresh generated.
#
# The droplet never commits or pushes (its GitHub key is read-only). Files the
# refresh rewrites (Jev caches, photo_hashes.json, reports) are saved, the
# checkout is reset to origin/main, and each is merged back
# (refresh-server/merge_state.py). Runs before refresh_catalog.sh starts, in
# its own process, so a run never executes a script that changed under it.
# A fetch failure (GitHub down) keeps the current code and lets the run go on.
#
#   refresh-server/update_checkout.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! git fetch -q origin main; then
    echo "update_checkout: fetch failed; running the code already here ($(git rev-parse --short HEAD))"
    exit 0
fi
old=$(git rev-parse HEAD); new=$(git rev-parse origin/main)
if [[ "$old" == "$new" ]]; then
    echo "update_checkout: at $(git rev-parse --short HEAD)"
    exit 0
fi
save=$(mktemp -d)
trap 'rm -rf "$save"' EXIT
mapfile -t changed < <(git diff --name-only HEAD)
for f in "${changed[@]}"; do
    [[ -f "$f" ]] || continue
    mkdir -p "$save/$(dirname "$f")"; cp -p "$f" "$save/$f"
done
git reset -q --hard origin/main
for f in "${changed[@]}"; do
    [[ -f "$save/$f" ]] || continue
    if git diff --quiet "$old" "$new" -- "$f"; then
        python3 refresh-server/merge_state.py "$save/$f" "$f"
    else
        python3 refresh-server/merge_state.py --upstream-changed "$save/$f" "$f"
    fi
done
# Dependencies that moved with the code.
# No package's install script runs here except better-sqlite3's own build
# (2026-11-12): a dependency's script would run as this user, on the box
# that scrapes and publishes.
if ! git diff --quiet "$old" "$new" -- web/package-lock.json; then
    (cd web && npm ci --ignore-scripts --no-fund --no-audit --silent && npm rebuild better-sqlite3 --no-fund --no-audit --silent)
fi
# The venv is root's (read-only to this user): a new pin needs provision.sh.
if ! git diff --quiet "$old" "$new" -- refresh-server/requirements.txt; then
    echo "update_checkout: WARNING refresh-server/requirements.txt changed; run refresh-server/provision.sh as root"
fi
echo "update_checkout: $(git rev-parse --short "$old") -> $(git rev-parse --short "$new"); kept ${#changed[@]} generated file(s)"
