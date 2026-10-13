#!/usr/bin/env bash
# Provision hexes-vm (Debian 13, Incus VM). Runs as root inside the VM; idempotent.
# Network policy is NOT set here: the host enforces it with the Incus ACL `hexes-egress`
# (see vm/host-setup.sh), so a compromised guest cannot loosen it.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
# chromium: pi-pocket's Browser panel (Amp "portal" equivalent) drives it server-side.
apt-get install -y -qq git curl ca-certificates xz-utils chromium incus btrfs-progs >/dev/null

if [ ! -x /usr/local/bin/node ]; then
  # Read the whole checksum file (no early-exit grep under pipefail), then verify the tarball.
  curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o /tmp/node.sha
  NODE_TAR=$(awk '/linux-x64\.tar\.xz$/ {print $2}' /tmp/node.sha)
  curl -fsSL "https://nodejs.org/dist/latest-v24.x/${NODE_TAR}" -o "/tmp/${NODE_TAR}"
  (cd /tmp && grep " ${NODE_TAR}\$" node.sha | sha256sum -c -)
  mv "/tmp/${NODE_TAR}" /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm /tmp/node.tar.xz
fi

# Unprivileged service user: no sudo, no host mounts, no host credentials.
id hexes >/dev/null 2>&1 || useradd -m -s /bin/bash hexes
mkdir -p /opt/hexes/app /opt/hexes/data /home/hexes/hex-projects
chown -R hexes:hexes /opt/hexes /home/hexes/hex-projects
chmod 700 /opt/hexes/data
# The server makes and removes hexes (incus-admin is root in this VM: the VM is the wall around the server).
usermod -aG incus-admin hexes
# Git identity for hex commits/stashes (worktree creation runs `git stash create`).
runuser -u hexes -- git config --global user.name "hexes"
runuser -u hexes -- git config --global user.email "hexes@hexes-vm"

cat > /etc/systemd/system/hexes.service <<'EOF'
[Unit]
Description=Tailnet Hexes (pi-durable) inside hexes-vm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hexes
WorkingDirectory=/opt/hexes/app
Environment=PI_POCKET_DIR=/opt/hexes/data
Environment=PI_POCKET_BROWSER=/usr/bin/chromium
# Every session but Jojo's runs in a hex: an Incus container of its own (vm/hex-base.sh, app/src/server/hexes.ts).
Environment=HEXES=1
ExecStart=/usr/local/bin/node bin/pi-pocket.js --host 10.41.19.10 --yes --port 8787 --cwd /home/hexes/hex-projects
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hexes.service

echo "provisioned: node $(node --version), chromium $(chromium --version 2>/dev/null | awk '{print $2}'), user hexes"
