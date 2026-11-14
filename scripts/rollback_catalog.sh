#!/usr/bin/env bash
# Put the published catalog files back to a publish_catalog.sh snapshot.
#
#   scripts/rollback_catalog.sh                    # list snapshots, newest last
#   scripts/rollback_catalog.sh 20261001T214022Z   # restore that one
#   RESTORE_ALL=1 scripts/rollback_catalog.sh <ts>  # rewrite even identical files
#
# Snapshots live in /var/backups/marracat-catalog/<ts> as hard links to the
# files that were live right before a publish swapped them. Restoring copies
# each to a temp name and renames it into place, so a download in progress
# never sees half a file. The app picks the restored catalog up on its next
# cold launch (it compares generated_at).
set -euo pipefail
CATALOG_HOST="${CATALOG_HOST:-root@167.71.170.219:/var/www/marracat-catalog}"
host="${CATALOG_HOST%%:*}"; path="${CATALOG_HOST#*:}"
BACKUPS=/var/backups/marracat-catalog
SNAP=${1:-}
if [[ -z "$SNAP" ]]; then
  ssh "$host" "ls -1 $BACKUPS"
  exit 0
fi
[[ "$SNAP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "error: snapshot names look like 20261001T214022Z" >&2; exit 1; }
ssh "$host" bash -s -- "$BACKUPS/$SNAP" "$path" "${RESTORE_ALL:-0}" <<'REMOTE'
set -euo pipefail
snap="$1"; path="$2"; all="$3"
test -d "$snap"
cd "$snap"
for f in catalog*.json catalog*.json.gz catalog*.json.sig; do
  [[ -f "$f" ]] || continue
  [[ "$all" != 1 ]] && cmp -s "$f" "$path/$f" && { echo "   unchanged $f"; continue; }
  cp -p "$f" "$path/.$f.restore"
  mv -f "$path/.$f.restore" "$path/$f"
  echo "   restored $f"
done
# Deltas lead to the version just rolled back, and manifests.txt names it as
# current: drop both, so phones fetch the restored catalog whole.
rm -f "$path"/catalog-v3/delta-*.json* "$path"/catalog-v3/manifests.txt
REMOTE
for name in catalog.json catalog-v2.json catalog-v3.json; do
  printf '%-45s %s\n' "https://marracat.com/$name" "$(curl -sI -o /dev/null -w '%{http_code}' "https://marracat.com/$name")"
done
echo "catalog rolled back to $SNAP"
