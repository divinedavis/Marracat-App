#!/usr/bin/env bash
# Root job on the refresh droplet: files the storefront database copies that
# 167.71 sends each night (web/backup/marracat-db-backup.sh), keeps 30, and
# emails the owner when the newest is over 30 hours old (2026-11-05).
#
# 167.71's key can only write into $IN (rrsync -wo -no-del), so anything that
# box sends is checked here before it's kept: the file name, a size cap, gzip
# and SQLite integrity. Kept copies live in $ARCHIVE, root-only, where the
# sending key can't overwrite them.
set -euo pipefail
IN=/var/lib/marracat-backup/incoming
ARCHIVE=/var/backups/marracat-db
KEEP=30
MAX_BYTES=$((512 * 1024 * 1024))
install -d -m 700 -o root -g root "$ARCHIVE"

alert() {
    runuser -u marracat-refresh -- /opt/marracat-refresh/venv/bin/python \
        /opt/marracat-refresh/Marracat/refresh-server/notify.py "$1" "$2" || true
}

shopt -s nullglob
for f in "$IN"/*; do
    base=$(basename "$f")
    # -L first: [[ -f ]] follows a symlink, and this job runs as root.
    if [[ -L "$f" ]] || [[ ! "$base" =~ ^marracat-[0-9]{8}T[0-9]{6}Z\.sqlite\.gz$ ]] || [[ ! -f "$f" ]] \
       || (( $(stat -c %s "$f") > MAX_BYTES )); then
        rm -rf -- "$f"; echo "rejected $base (name or size)"; continue
    fi
    tmp=$(mktemp /var/tmp/marracat-db-check.XXXXXX)
    if gzip -dc "$f" > "$tmp" 2>/dev/null \
       && [[ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("PRAGMA integrity_check").fetchone()[0])' "$tmp")" == "ok" ]]; then
        install -m 600 -o root -g root "$f" "$ARCHIVE/$base" && rm -f -- "$f"
        echo "kept $base ($(stat -c %s "$ARCHIVE/$base") bytes)"
    else
        rm -f -- "$f"; echo "rejected $base (not a sound database)"
        alert "Marracat backup: a nightly copy failed its check" "$base arrived from 167.71 but isn't a sound SQLite database; it was discarded. The previous copies are untouched in $ARCHIVE."
    fi
    rm -f -- "$tmp"
done

# rsync's own partial files (.name.XXXXXX) left by a cut-off transfer.
find "$IN" -maxdepth 1 -name '.*' -type f -mmin +720 -delete

# Newest first; drop all but $KEEP.
mapfile -t kept < <(ls -1t "$ARCHIVE"/marracat-*.sqlite.gz 2>/dev/null)
for old in "${kept[@]:$KEEP}"; do rm -f -- "$old"; echo "pruned $(basename "$old")"; done

newest=${kept[0]:-}
if [[ -z "$newest" ]] || (( $(date +%s) - $(stat -c %Y "$newest") > 30 * 3600 )); then
    alert "Marracat backup: no database copy in over 30 hours" \
        "The newest copy of marracat.com's database in $ARCHIVE on the refresh droplet is ${newest:+$(basename "$newest") — }over 30 hours old (or missing). Check marracat-db-backup.service on 167.71: journalctl -u marracat-db-backup."
fi
