#!/usr/bin/env bash
# Copy the refresh droplet's latest catalog to this Mac (refresh-server/README.md).
#
#   scripts/pull_catalog.sh           # Marracat/Resources/catalog.json + catalog-compact.json
#   scripts/pull_catalog.sh --state   # + the generated state files (Jev caches,
#                                     # photo_hashes.json, reports) into catalog/,
#                                     # so commits from this Mac carry them
#
# The key (~/.ssh/id_marracat_exchange) is locked to rrsync in the droplet's
# exchange directory: it can read out/ and write in/, nothing else.
# Files this Mac owns are never taken: photo_moves.json and the photo report
# (scripts/refresh_ml.sh writes them).
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${MARRACAT_REFRESH_SSH:-marracat-refresh@104.236.122.134}"
KEY="${MARRACAT_EXCHANGE_KEY:-$HOME/.ssh/id_marracat_exchange}"
# rrsync needs real rsync; macOS's /usr/bin/rsync is openrsync. Homebrew's
# rsync is installed UNLINKED (brew install rsync && brew unlink rsync): on
# PATH it breaks Xcode's IPA export, which runs whatever rsync PATH finds.
RSYNC=/opt/homebrew/opt/rsync/bin/rsync; [[ -x "$RSYNC" ]] || RSYNC=rsync
RSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20"
mkdir -p build/refresh-pull
"$RSYNC" -t -z --partial -e "$RSH" "$HOST:out/catalog.json" "$HOST:out/catalog-compact.json" build/refresh-pull/
python3 -c "
import json, sys
for p in sys.argv[1:]:
    d = json.load(open(p))
    assert len(d['products']) > 50000, (p, len(d['products']))
print('pulled', len(d['products']), 'products, generated', d.get('generated_at') or d.get('generatedAt'))" \
    build/refresh-pull/catalog.json build/refresh-pull/catalog-compact.json
mv -f build/refresh-pull/catalog.json Marracat/Resources/catalog.json
mv -f build/refresh-pull/catalog-compact.json Marracat/Resources/catalog-compact.json
# The app bundles only the binary built from that JSON (2026-10-18); rebuild it
# now so a test build between ships doesn't carry yesterday's catalog.
python3 catalog/make_compact.py
if [[ "${1:-}" == --state ]]; then
    rm -rf build/refresh-pull/state
    "$RSYNC" -r -t -z -e "$RSH" "$HOST:out/state/" build/refresh-pull/state/
    for f in build/refresh-pull/state/*; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f")
        case "$name" in photo_moves.json|photo_category_report.md) continue ;; esac
        # Only files git already tracks in catalog/: the droplet can't add new ones here.
        git ls-files --error-unmatch "catalog/$name" >/dev/null 2>&1 || continue
        cp "$f" "catalog/$name"
    done
    echo "state: $(ls build/refresh-pull/state | wc -l | tr -d ' ') file(s) from the droplet"
fi
