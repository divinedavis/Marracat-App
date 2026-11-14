#!/usr/bin/env bash
# Put marracat.com (web app + docroot + nginx site) back to a deploy snapshot.
#
#   scripts/rollback_web.sh                    # list snapshots, newest last
#   scripts/rollback_web.sh 20261001T214022Z   # restore that one
#
# web/deploy.sh snapshots what is live right before every release and restores
# it on its own when the post-deploy checks fail. The restore logic itself is
# web/restore-snapshot.sh, run on the droplet. Catalog files have their own:
# scripts/rollback_catalog.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${MARRACAT_HOST:-root@167.71.170.219}
BACKUPS=/var/backups/marracat-web
SNAP=${1:-}
if [[ -z "$SNAP" ]]; then
  ssh "$HOST" "ls -1 $BACKUPS"
  exit 0
fi
[[ "$SNAP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "error: snapshot names look like 20261001T214022Z" >&2; exit 1; }
ssh "$HOST" bash -s -- "$BACKUPS/$SNAP" < web/restore-snapshot.sh
printf '%-28s %s\n' "https://marracat.com/" "$(curl -s -o /dev/null -w '%{http_code}' https://marracat.com/)"
printf '%-28s %s\n' "https://marracat.com/api/health" "$(curl -s https://marracat.com/api/health)"
echo "rolled back to $SNAP"
