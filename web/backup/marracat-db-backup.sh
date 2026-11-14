#!/usr/bin/env bash
# Nightly off-box copy of the storefront's SQLite (owner, 2026-11-05: "lets do
# a free nightly backup to another server"). Runs on 167.71 as marracat, the
# database's owner: sqlite3 run as root would leave root-owned -wal/-shm files
# the web server can't open.
#
#   1. sqlite3 .backup: a consistent copy while the site keeps writing (WAL);
#   2. PRAGMA integrity_check on the copy, then gzip;
#   3. rsync over the VPC to the refresh droplet (10.108.0.7), whose key for
#      this box is write-only into one folder (rrsync -wo -no-del, from= this
#      private IP): it can't read, list or delete what's there.
# The refresh droplet's root job (refresh-server/backup/) checks each arrival,
# keeps 30 nights, and emails the owner when a night is missing.
set -euo pipefail
DB="${MARRACAT_DB:-/var/lib/marracat/marracat.sqlite}"
KEY=/etc/marracat/backup/id_ed25519
HOSTS=/etc/marracat/backup/known_hosts
DEST="${MARRACAT_BACKUP_DEST:-marracat-backup@10.108.0.7:}"

work=$(mktemp -d /var/tmp/marracat-db-backup.XXXXXX)
trap 'rm -rf "$work"' EXIT
name="marracat-$(date -u +%Y%m%dT%H%M%SZ).sqlite"

sqlite3 "$DB" ".backup '$work/$name'"
check=$(sqlite3 "$work/$name" "PRAGMA integrity_check;")
[[ "$check" == "ok" ]] || { echo "integrity_check on the copy: $check" >&2; exit 1; }
tables=$(sqlite3 "$work/$name" "SELECT count(*) FROM sqlite_master WHERE type='table';")
gzip -9 "$work/$name"

rsync --timeout=120 -e "ssh -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes" \
    "$work/$name.gz" "$DEST"
echo "sent $name.gz ($(stat -c %s "$work/$name.gz") bytes, $tables tables, integrity ok)"
