#!/usr/bin/env bash
# Install (or update) the catalog signer on the refresh droplet, from the
# Mac. Idempotent.
#
#   refresh-server/signer/install.sh            # install, move the key, test
#   refresh-server/signer/install.sh --finish   # remove the refresh user's old copy of the key
#
# Why: the refresh service fetches and parses more than a thousand outside
# stores, and until 2026-11-12 it could read the key every iPhone trusts.
# After this, only marracat-signer can; the refresh asks for signatures over
# /run/marracat-signer.sock (marracat-sign).
#
# The files are copied from this Mac, never taken from the droplet's
# checkout, which the refresh user can write.
#
# Creates on the droplet:
#   user marracat-signer (system, no shell, no home)
#   /etc/marracat-signer/catalog-signing.key   0440 root:marracat-signer
#   /usr/local/sbin/marracat-sign              the signer (root-owned)
#   marracat-signer.socket + marracat-signer@.service
#   marracat-refresh.service                   with MARRACAT_SIGN_SOCKET, no key path
#
# A refresh that is running keeps the environment it started with and still
# needs the old key file, so the first run leaves that file alone. Run
# --finish once no refresh is running (it checks) to remove it.
set -euo pipefail
cd "$(dirname "$0")"
HOST="${MARRACAT_REFRESH_HOST:-root@104.236.122.134}"
OLD=/etc/marracat-refresh/catalog-signing.key
NEW=/etc/marracat-signer/catalog-signing.key
PUB=$(cat ../../scripts/catalog-signing.pub)

if [[ "${1:-}" == "--finish" ]]; then
    ssh "$HOST" bash -s -- "$OLD" "$NEW" <<'REMOTE'
set -euo pipefail
old="$1"; new="$2"
state=$(systemctl is-active marracat-refresh.service || true)
[[ "$state" == inactive || "$state" == failed ]] || { echo "a refresh is running ($state); try again when it is done" >&2; exit 1; }
[[ -s "$new" ]] || { echo "error: $new is missing; not removing the old key" >&2; exit 1; }
systemctl show marracat-refresh.service -p Environment | grep -q MARRACAT_SIGN_SOCKET \
    || { echo "error: marracat-refresh.service does not use the signer yet" >&2; exit 1; }
if [[ -e "$old" ]]; then shred -u "$old"; echo "removed $old"; else echo "$old was already gone"; fi
REMOTE
    exit 0
fi

python3 -c "import ast; ast.parse(open('marracat-sign').read())"
tmp=$(ssh "$HOST" mktemp -d)
scp -q marracat-sign marracat-signer.socket marracat-signer@.service ../marracat-refresh.service "$HOST:$tmp/"
ssh "$HOST" bash -s -- "$tmp" "$OLD" "$NEW" "$PUB" <<'REMOTE'
set -euo pipefail
tmp="$1"; old="$2"; new="$3"; pub="$4"
py=/opt/marracat-refresh/venv/bin/python
id marracat-signer >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin marracat-signer
install -d -m 750 -o root -g marracat-signer /etc/marracat-signer
if [[ ! -s "$new" ]]; then
    [[ -s "$old" ]] || { echo "error: no key at $old or $new" >&2; exit 1; }
    install -m 440 -o root -g marracat-signer "$old" "$new"
fi
chown root:marracat-signer "$new"; chmod 440 "$new"
# The key must be the one the app trusts, or nothing changes.
have=$("$py" - "$new" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(sys.argv[1]).read().strip()))
print(base64.b64encode(k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode())
PY
)
[[ "$have" == "$pub" ]] || { echo "error: the key on the droplet is not the app's catalog key" >&2; exit 1; }
install -m 755 -o root -g root "$tmp/marracat-sign" /usr/local/sbin/marracat-sign
install -m 644 -o root -g root "$tmp/marracat-signer.socket" "$tmp/marracat-signer@.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now marracat-signer.socket >/dev/null
systemctl restart marracat-signer.socket

# Prove it as the refresh user: a catalog-shaped file is signed and the
# signature is the app's key's; anything else is refused; the key itself
# can't be read by that user through the signer's copy.
t=$(sudo -u marracat-refresh mktemp -d)
sudo -u marracat-refresh "$py" - "$t" "$pub" <<'PY'
import base64, socket, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
def ask(name, data):
    s = socket.socket(socket.AF_UNIX); s.settimeout(120); s.connect("/run/marracat-signer.sock")
    try:
        s.sendall(f"sign {name} {len(data)}\n".encode()); s.sendall(data)
    except (BrokenPipeError, ConnectionResetError):
        pass
    out = b""
    while not out.endswith(b"\n"):
        c = s.recv(400)
        if not c: break
        out += c
    return out.decode().strip()
body = b'{"generated_at":"2026-11-12T00:00:00Z","products":[' + b'{"id":1},' * 150000 + b'{"id":2}]}'
word, _, sig = ask("catalog-v3.json", body).partition(" ")
assert word == "ok", (word, sig)
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[2])).verify(base64.b64decode(sig), body)
assert ask("authorized_keys", body).startswith("error"), "a non-catalog name was signed"
assert ask("catalog-v3.json", b"#!/bin/sh\n" + body).startswith("error"), "a non-catalog body was signed"
print("signer: signs catalogs with the app's key, refuses the rest")
PY
rm -rf "$t"
if sudo -u marracat-refresh test -r "$new"; then echo "error: marracat-refresh can read $new" >&2; exit 1; fi
echo "signer: marracat-refresh cannot read $new"

# The refresh service asks the signer from its next start on.
install -m 644 -o root -g root "$tmp/marracat-refresh.service" /etc/systemd/system/marracat-refresh.service
systemctl daemon-reload
rm -rf "$tmp"
echo "signer installed. When no refresh is running: refresh-server/signer/install.sh --finish"
REMOTE
