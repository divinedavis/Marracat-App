#!/usr/bin/env bash
# Set up (or re-apply) the marracat-refresh droplet. Runs ON the droplet as
# root; idempotent. From the Mac:
#
#   ssh root@104.236.122.134 'bash -s' < refresh-server/provision.sh
#
# What it does (refresh-server/README.md has the why):
#   - UTC, apt upgrade, 4 GB swap (build_catalog.py peaks ~5 GB: 3.5 GB RAM +
#     1.6 GB swap on the first run; a 2 GB swap + 3.6 GB cap OOM-killed the second)
#   - sshd: keys only, root by key only, no forwarding; ufw: 22/tcp only;
#     fail2ban sshd jail; unattended-upgrades with a 07:30 UTC reboot when one
#     is needed (between the 03:00 and 09:00 runs)
#   - user marracat-refresh (system, locked password, home /var/lib/marracat-refresh)
#   - Python 3.14 venv (uv, pinned) at /opt/marracat-refresh/venv, root-owned
#   - Node (pinned, = marracat.com's) in /usr/local for the web tests
#   - /etc/marracat-refresh (0750 root:marracat-refresh) for the secrets, which
#     this script never writes: refresh.env, smtp.json
#   - the catalog signing key is NOT there (2026-11-12): it belongs to the
#     signer's own user, set up from the Mac by refresh-server/signer/install.sh
#   - the checkout /opt/marracat-refresh/Marracat (marracat-refresh's), cloned
#     with the read-only GitHub deploy key once it is in ~/.ssh
#   - systemd units + timer, logrotate
# The secrets, keys and first clone are separate steps (README "Rebuild").
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
U=marracat-refresh
HOME_DIR=/var/lib/marracat-refresh
APP=/opt/marracat-refresh
UV_VERSION=0.12.18
NODE_VERSION=24.21.0
PYTHON_VERSION=3.14

timedatectl set-timezone UTC
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
apt-get install -y -q git curl rsync ufw fail2ban unattended-upgrades ca-certificates gzip xz-utils logrotate

if [[ "$(stat -c %s /swapfile 2>/dev/null || echo 0)" -lt 4294967296 ]]; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
fi
swapon --show | grep -q /swapfile || swapon /swapfile
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=60' > /etc/sysctl.d/60-swappiness.conf && sysctl -q -p /etc/sysctl.d/60-swappiness.conf

cat > /etc/ssh/sshd_config.d/60-marracat.conf <<'EOF'
# refresh-server/provision.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
MaxAuthTries 4
LoginGraceTime 30
EOF
sshd -t && systemctl reload ssh

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null

cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
# refresh-server/provision.sh. Ubuntu 24.04's unit is ssh.service, so read
# auth.log rather than trust a journal match on sshd.service.
[sshd]
enabled = true
backend = auto
logpath = /var/log/auth.log
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52marracat-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "07:30";
EOF
systemctl enable --now unattended-upgrades >/dev/null

id "$U" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$HOME_DIR" --shell /bin/bash "$U"
passwd -l "$U" >/dev/null
chmod 750 "$HOME_DIR"
install -d -m 700 -o "$U" -g "$U" "$HOME_DIR/.ssh"
install -d -m 750 -o "$U" -g "$U" "$HOME_DIR/exchange" "$HOME_DIR/exchange/in" "$HOME_DIR/exchange/out" "$HOME_DIR/alerts"
install -d -m 750 -o "$U" -g "$U" /var/log/marracat-refresh
install -d -m 750 -o root -g "$U" /etc/marracat-refresh
install -d -m 755 "$APP"

# uv (pinned, checksum-verified) -> Python 3.14 -> the venv, all root-owned.
if [[ "$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]]; then
    t=$(mktemp -d)
    base="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
    curl -fsSL "$base" -o "$t/uv.tgz"
    curl -fsSL "$base.sha256" -o "$t/uv.sha256"
    (cd "$t" && echo "$(awk '{print $1}' uv.sha256)  uv.tgz" | sha256sum -c --quiet)
    tar -xzf "$t/uv.tgz" -C "$t"
    install -m 755 "$t"/uv-x86_64-unknown-linux-gnu/uv "$t"/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/
    rm -rf "$t"
fi
export UV_PYTHON_INSTALL_DIR="$APP/python" UV_CACHE_DIR=/root/.cache/uv
[[ -x "$APP/venv/bin/python" ]] || uv venv -q --python "$PYTHON_VERSION" --managed-python "$APP/venv"
REQ="$APP/Marracat/refresh-server/requirements.txt"
[[ -f "$REQ" ]] || REQ=$(dirname "$0")/requirements.txt
if [[ -f "$REQ" ]]; then uv pip install -q --python "$APP/venv/bin/python" -r "$REQ"; fi

if [[ "$(/usr/local/bin/node -v 2>/dev/null)" != "v$NODE_VERSION" ]]; then
    t=$(mktemp -d)
    f="node-v$NODE_VERSION-linux-x64.tar.xz"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$f" -o "$t/$f"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o "$t/SHASUMS256.txt"
    (cd "$t" && grep " $f\$" SHASUMS256.txt | sha256sum -c --quiet)
    tar -xJf "$t/$f" -C /usr/local --strip-components=1 --no-same-owner
    rm -rf "$t"
fi

# Which key goes where: GitHub (read-only deploy key) and the publish
# receiver on 167.71 over the private network (refresh-server/receiver/).
cat > "$HOME_DIR/.ssh/config" <<'EOF'
Host github.com
  IdentityFile ~/.ssh/id_github
  IdentitiesOnly yes
Host 10.108.0.3
  IdentityFile ~/.ssh/id_publish
  IdentitiesOnly yes
  ServerAliveInterval 30
EOF
# Host keys, so neither first connection needs a prompt.
touch "$HOME_DIR/.ssh/known_hosts"
grep -q '^github.com ' "$HOME_DIR/.ssh/known_hosts" || ssh-keyscan -t ed25519 github.com 2>/dev/null >> "$HOME_DIR/.ssh/known_hosts"
grep -q '^10.108.0.3 ' "$HOME_DIR/.ssh/known_hosts" || ssh-keyscan -t ed25519 10.108.0.3 2>/dev/null >> "$HOME_DIR/.ssh/known_hosts"
for k in id_github id_publish; do
    [[ -f "$HOME_DIR/.ssh/$k" ]] || ssh-keygen -q -t ed25519 -N '' -C "$U@marracat-refresh ($k)" -f "$HOME_DIR/.ssh/$k"
done
chown -R "$U:$U" "$HOME_DIR/.ssh"; chmod 600 "$HOME_DIR/.ssh/config"
if [[ ! -d "$APP/Marracat/.git" && -f "$HOME_DIR/.ssh/id_github" ]]; then
    install -d -m 755 -o "$U" -g "$U" "$APP/Marracat"
    sudo -u "$U" -H git clone -q git@github.com:divinedavis/Marracat.git "$APP/Marracat"
fi
if [[ -d "$APP/Marracat/.git" ]]; then
    R="$APP/Marracat/refresh-server"
    install -m 644 "$R/marracat-refresh.service" "$R/marracat-refresh-alert.service" "$R/marracat-refresh.timer" /etc/systemd/system/
    install -m 644 "$R/logrotate.conf" /etc/logrotate.d/marracat-refresh
    systemctl daemon-reload
    systemctl enable marracat-refresh.timer >/dev/null
    [[ -d "$APP/Marracat/web/node_modules" ]] || sudo -u "$U" -H bash -c "cd '$APP/Marracat/web' && npm ci --ignore-scripts --no-fund --no-audit --silent && npm rebuild better-sqlite3 --no-fund --no-audit --silent"
fi
echo "provisioned: $(uv --version), $("$APP/venv/bin/python" --version), node $(node -v)"
