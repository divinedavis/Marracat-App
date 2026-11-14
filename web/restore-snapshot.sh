#!/usr/bin/env bash
# Runs ON the droplet: put marracat.com back the way a deploy snapshot found it.
#
#   bash restore-snapshot.sh /var/backups/marracat-web/<timestamp>
#
# A snapshot (taken by web/deploy.sh right before each release goes live)
# holds the docroot's top-level files (index.html, icons), the nginx site, the
# systemd unit, and `release`: the /opt/marracat-web/releases/<id> that was
# current. Hashed /assets/ are never deleted by a deploy, so restoring
# index.html is enough to bring back the old bundle. When `current` already
# points at that release the app is not restarted, so restoring an identical
# snapshot is invisible to visitors (nginx reloads gracefully).
# Used by web/deploy.sh on a failed release and by scripts/rollback_web.sh.
set -euo pipefail
snap="$1"
WWW=/var/www/marracat
[[ -f "$snap/release" && -f "$snap/www/index.html" && -f "$snap/nginx.conf" ]] || { echo "not a snapshot: $snap" >&2; exit 1; }
release=$(cat "$snap/release")
for f in "$snap"/www/*; do
  cp -p "$f" "$WWW/.$(basename "$f").restore"
  mv -f "$WWW/.$(basename "$f").restore" "$WWW/$(basename "$f")"
done
install -m 644 "$snap/nginx.conf" /etc/nginx/sites-available/marracat
if [[ -f "$snap/marracat-web.service" ]] && ! cmp -s "$snap/marracat-web.service" /etc/systemd/system/marracat-web.service; then
  install -m 644 "$snap/marracat-web.service" /etc/systemd/system/marracat-web.service
  systemctl daemon-reload
fi
if [[ -n "$release" && -d "$release" && "$(readlink -e /opt/marracat-web/current || true)" != "$release" ]]; then
  ln -sfn "$release" /opt/marracat-web/current.new
  mv -Tf /opt/marracat-web/current.new /opt/marracat-web/current
  systemctl restart marracat-web
  echo "restarted marracat-web on $release"
fi
nginx -t 2>/dev/null
systemctl reload nginx
for attempt in {1..15}; do
  if [[ $(curl -fsS --resolve marracat.com:443:127.0.0.1 https://marracat.com/api/health || true) == '{"ok":true}' ]]; then
    echo "restored $snap"
    exit 0
  fi
  sleep 1
done
echo "restored $snap but /api/health is not answering" >&2
exit 1
