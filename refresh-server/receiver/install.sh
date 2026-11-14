#!/usr/bin/env bash
# Install (or update) the publish receiver on marracat.com's droplet, from
# the Mac. Idempotent.
#
#   refresh-server/receiver/install.sh <refresh droplet's publish public key file> [<refresh private IP>]
#
# Creates on 167.71:
#   user marracat-pub (system, locked password, home /var/lib/marracat-pub)
#   /var/lib/marracat-pub/incoming          0750 marracat-pub (uploads land here)
#   /usr/local/sbin/marracat-pub-ssh        the forced command (root-owned)
#   /usr/local/sbin/marracat-catalog-swap   root: catalog files live
#   /usr/local/sbin/marracat-catalog-deltas root: their deltas live (called by the swap)
#   /usr/local/sbin/marracat-web-data-release  root: web data release/rollback
#   /usr/local/sbin/marracat-verify-sig     root: is this the catalog key's signature?
#   /etc/marracat-pub/catalog-signing.pub   the catalog's public key (scripts/catalog-signing.pub)
#   /etc/sudoers.d/marracat-pub             marracat-pub may run exactly those two
#   ~marracat-pub/.ssh/authorized_keys      the refresh key, restrict + from=<private IP>
set -euo pipefail
cd "$(dirname "$0")"
KEY_FILE="${1:?usage: install.sh <publish public key file> [<refresh private IP>]}"
FROM="${2:-10.108.0.7}"
HOST="${MARRACAT_HOST:-root@167.71.170.219}"
key=$(cat "$KEY_FILE")
[[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || { echo "error: not an ed25519 public key: $KEY_FILE" >&2; exit 1; }
[[ "$FROM" =~ ^[0-9.]+$ ]] || { echo "error: bad IP $FROM" >&2; exit 1; }
for f in marracat-pub-ssh marracat-catalog-swap marracat-catalog-deltas marracat-web-data-release; do bash -n "$f"; done
python3 -c "import ast,sys; ast.parse(open('marracat-verify-sig').read())"
tmp=$(ssh "$HOST" mktemp -d)
scp -q marracat-pub-ssh marracat-catalog-swap marracat-catalog-deltas marracat-web-data-release marracat-verify-sig ../../scripts/catalog-signing.pub "$HOST:$tmp/"
ssh "$HOST" bash -s -- "$tmp" "$FROM" "$(printf %q "$key")" <<'REMOTE'
set -euo pipefail
tmp="$1"; from="$2"; key="$3"
id marracat-pub >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/marracat-pub --shell /bin/bash marracat-pub
passwd -l marracat-pub >/dev/null
chmod 750 /var/lib/marracat-pub
install -d -m 750 -o marracat-pub -g marracat-pub /var/lib/marracat-pub/incoming
# The catalog's public key, root's copy, and what checks uploads against it.
# It goes in first, and must pass on what is live, so a swap never meets a
# verifier that can't run.
python3 -c "import cryptography" 2>/dev/null || apt-get install -y -q python3-cryptography >/dev/null
install -d -m 755 -o root -g root /etc/marracat-pub
install -m 644 -o root -g root "$tmp/catalog-signing.pub" /etc/marracat-pub/catalog-signing.pub
install -m 755 -o root -g root "$tmp/marracat-verify-sig" /usr/local/sbin/marracat-verify-sig
if [[ -f /var/www/marracat-catalog/catalog-v3.json ]]; then
  /usr/local/sbin/marracat-verify-sig /var/www/marracat-catalog/catalog-v3.json \
    || { echo "error: the live catalog fails the new signature check; nothing else installed" >&2; exit 1; }
fi
for f in marracat-pub-ssh marracat-catalog-swap marracat-catalog-deltas marracat-web-data-release; do
  install -m 755 -o root -g root "$tmp/$f" "/usr/local/sbin/$f"
done
rm -rf "$tmp"
cat > /etc/sudoers.d/marracat-pub.new <<'SUDO'
# The refresh droplet's publish key (refresh-server/receiver/): only these.
Defaults:marracat-pub !requiretty
marracat-pub ALL=(root) NOPASSWD: /usr/local/sbin/marracat-catalog-swap, /usr/local/sbin/marracat-web-data-release
SUDO
chmod 440 /etc/sudoers.d/marracat-pub.new
visudo -cf /etc/sudoers.d/marracat-pub.new >/dev/null
mv -f /etc/sudoers.d/marracat-pub.new /etc/sudoers.d/marracat-pub
install -d -m 700 -o marracat-pub -g marracat-pub /var/lib/marracat-pub/.ssh
echo "restrict,from=\"$from\",command=\"/usr/local/sbin/marracat-pub-ssh\" $key" > /var/lib/marracat-pub/.ssh/authorized_keys
chown marracat-pub:marracat-pub /var/lib/marracat-pub/.ssh/authorized_keys
chmod 600 /var/lib/marracat-pub/.ssh/authorized_keys
echo "receiver installed (from=$from)"
REMOTE
