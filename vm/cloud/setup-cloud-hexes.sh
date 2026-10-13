#!/usr/bin/env bash
set -euo pipefail

PUBLIC_IP="${1:-}"
if [ -z "$PUBLIC_IP" ]; then
  echo "Usage: $0 <public-ip>"
  exit 1
fi

SSH="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes ubuntu@$PUBLIC_IP"

echo "=== 1. Provisioning packages and Node.js on $PUBLIC_IP (ARM64) ==="
$SSH 'sudo bash -s' <<'REMOTE_SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Incus from Zabbly stable, not Ubuntu archives: noble's 6.0.0 cannot do
# idmapped (shift) mounts on newer kernels ("Required idmapping abilities not
# available"); hexes depend on shift mounts for worktrees.
curl -fsSL https://pkgs.zabbly.com/get/incus-stable | sh
apt-get update -qq
apt-get install -y -qq git curl ca-certificates xz-utils incus btrfs-progs ufw gnupg >/dev/null

# Tailscale (official repo; not in Ubuntu archives). The service below binds the
# tailnet IP only: port 8787 is never exposed to the public internet (SPEC tailnet-only).
if [ ! -x /usr/bin/tailscale ]; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if ! tailscale status >/dev/null 2>&1; then
  echo "tailscale is installed but not logged in: run 'tailscale up' and approve the login URL first."
  exit 1
fi
TAILNET_IP=$(tailscale ip -4 | head -n 1)
[ -n "$TAILNET_IP" ] || { echo "no tailscale IPv4 address"; exit 1; }
echo "tailnet IP: $TAILNET_IP (service binds here only; never 0.0.0.0)"

# Oracle Ubuntu images ship host iptables REJECT rules (INPUT/OUTPUTlo-only + REJECT) that
# drop container→host DNS/DHCP and container→internet forwarding before incus's own
# chains run (same nftables hook/priority, Oracle registered first). hexes-vm (Debian)
# has no such rules, so only the cloud host needs this. incus's hex-egress ACL then
# governs containers exactly as on hexes-vm; the OCI security list (22-only ingress)
# remains the perimeter.
iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
# Persist across reboots regardless of what restores Oracle's rules: a oneshot unit.
cat > /etc/systemd/system/hexes-firewall.service <<'EOF'
[Unit]
Description=Drop Oracle image REJECT rules so incus chains govern containers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Leading dash: rules are already absent on most boots; either state is fine.
ExecStart=-/usr/sbin/iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited
ExecStart=-/usr/sbin/iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hexes-firewall.service

# Install Node.js v24 ARM64
if [ ! -x /usr/local/bin/node ]; then
  curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o /tmp/node.sha
  NODE_TAR=$(awk '/linux-arm64\.tar\.xz$/ {print $2}' /tmp/node.sha)
  curl -fsSL "https://nodejs.org/dist/latest-v24.x/${NODE_TAR}" -o "/tmp/${NODE_TAR}"
  (cd /tmp && grep " ${NODE_TAR}\$" node.sha | sha256sum -c -)
  tar -xJf "/tmp/${NODE_TAR}" -C /usr/local --strip-components=1
  rm -f /tmp/node.sha "/tmp/${NODE_TAR}"
fi

# Set up user hexes
id hexes >/dev/null 2>&1 || useradd -m -s /bin/bash hexes
mkdir -p /opt/hexes/app /opt/hexes/data /home/hexes/hex-projects
chown -R hexes:hexes /opt/hexes /home/hexes/hex-projects
chmod 700 /opt/hexes/data
usermod -aG incus-admin hexes

runuser -u hexes -- git config --global user.name "hexes"
runuser -u hexes -- git config --global user.email "hexes@cloud-arm"

# Clone and install app
if [ ! -f /opt/hexes/app/package.json ]; then
  git clone -b hexes https://github.com/adihex/pi-pocket.git /opt/hexes/app
  chown -R hexes:hexes /opt/hexes/app
  runuser -u hexes -- bash -c 'cd /opt/hexes/app && npm ci --omit=dev --loglevel=error'
fi

# Set up Incus on ARM64 host
if ! incus storage show hexes >/dev/null 2>&1; then
  incus admin init --preseed <<'YAML'
storage_pools:
- name: hexes
  driver: btrfs
  config:
    size: 50GiB
networks:
- name: hexbr0
  type: bridge
  config:
    ipv4.address: 10.42.0.1/24
    ipv4.nat: "true"
    ipv6.address: none
YAML
fi

# Incus ACL hex-egress
incus network acl show hex-egress >/dev/null 2>&1 || incus network acl create hex-egress </dev/null
incus network acl edit hex-egress <<'YAML'
name: hex-egress
description: "Hex internet only"
egress:
- action: reject
  state: enabled
  destination: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16
- action: reject
  state: enabled
  destination: fc00::/7,fe80::/10
ingress:
- action: allow
  state: enabled
  source: 10.42.0.1
YAML

incus network set hexbr0 security.acls=hex-egress \
  security.acls.default.egress.action=allow security.acls.default.ingress.action=reject </dev/null

incus profile show hex >/dev/null 2>&1 || incus profile create hex </dev/null
incus profile edit hex <<'YAML'
description: "One hex = one container"
config:
  limits.cpu: "2"
  limits.memory: 4GiB
  limits.processes: "2000"
  security.nesting: "false"
  security.privileged: "false"
devices:
  root: {path: /, pool: hexes, type: disk, size: 25GiB}
  eth0:
    name: eth0
    network: hexbr0
    type: nic
    security.port_isolation: "true"
YAML

# Extract and stage ARM64 pi-env daemon
PI_ENV_SRC="/opt/hexes/app/node_modules/@earendil-works/pi-env/bin/pi-env-linux-arm64/pi-env"
if [ -f "$PI_ENV_SRC" ]; then
  cp "$PI_ENV_SRC" /root/pi-env
  chmod 755 /root/pi-env
fi

# Build hex-base container if missing
if ! incus info hex-base >/dev/null 2>&1; then
  echo "Building hex-base container on ARM64..."
  incus launch images:debian/13 hex-base --profile hex </dev/null
  for _ in $(seq 1 60); do
    incus exec hex-base -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 1
  done

  incus exec hex-base -T -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git ca-certificates curl xz-utils build-essential pkg-config python3 python3-venv \
  procps less unzip openssh-client >/dev/null

curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o /tmp/node.sha
NODE_TAR=$(awk '/linux-arm64\.tar\.xz$/ {print $2}' /tmp/node.sha)
curl -fsSL "https://nodejs.org/dist/latest-v24.x/${NODE_TAR}" -o "/tmp/${NODE_TAR}"
(cd /tmp && grep " ${NODE_TAR}\$" node.sha | sha256sum -c - >/dev/null)
tar -xJf "/tmp/${NODE_TAR}" -C /usr/local --strip-components=1
rm -f /tmp/node.sha "/tmp/${NODE_TAR}"

id hex >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash hex
runuser -u hex -- git config --global user.name hex
runuser -u hex -- git config --global user.email hex@cloud-arm
runuser -u hex -- git config --global gc.auto 0
apt-get clean
EOS

  incus file push /root/pi-env hex-base/usr/local/bin/pi-env --mode 0755 </dev/null
  incus stop hex-base </dev/null
  echo "hex-base container built successfully"

# Browser panel: Ubuntu ARM64 has no deb Chromium (snap-only, and snapd hangs on
# minimal cloud images), so use a Playwright Chromium download, which the app
# auto-discovers at ~hexes/.cache/ms-playwright.
if ! ls /home/hexes/.cache/ms-playwright/chromium-*/chrome-linux*/chrome >/dev/null 2>&1; then
  export HOME=/home/hexes
  export PLAYWRIGHT_BROWSERS_PATH=/home/hexes/.cache/ms-playwright
  export npm_config_cache=/home/hexes/.npm
  mkdir -p /home/hexes/.cache /home/hexes/.npm
  npx -y playwright install chromium --with-deps
  chown -R hexes:hexes /home/hexes/.cache /home/hexes/.npm
fi

# Set up systemd service (binds the tailnet IP only: 8787 never listens publicly)
# Playwright now ships ARM64 under chrome-linux-arm64, which the app's discovery
# does not list: resolve the binary explicitly (empty when absent: panel stays off).
BROWSER_BIN=$(ls -d /home/hexes/.cache/ms-playwright/chromium-*/chrome-linux*/chrome 2>/dev/null | sort -V | tail -n 1 || true)
cat > /etc/systemd/system/hexes.service <<EOF
[Unit]
Description=Tailnet Hexes on Cloud ARM
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=hexes
WorkingDirectory=/opt/hexes/app
Environment=PI_POCKET_DIR=/opt/hexes/data
Environment=HEXES=1
${BROWSER_BIN:+Environment=PI_POCKET_BROWSER=$BROWSER_BIN}
ExecStart=/usr/local/bin/node bin/pi-pocket.js --host $TAILNET_IP --yes --port 8787 --cwd /home/hexes/hex-projects
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hexes.service

# Tailnet-only firewall. UFW default-deny would also block bridge DHCP/DNS and
# container forwarding, so allow those narrowly first (per Incus bridge docs);
# the incus hex-egress ACL still enforces container isolation on top.
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow in on hexbr0 to any port 67 proto udp >/dev/null
ufw allow in on hexbr0 to any port 53 >/dev/null
ufw route allow in on hexbr0 from 10.42.0.0/24 >/dev/null
ufw allow in on tailscale0 to any port 8787 >/dev/null
ufw --force enable >/dev/null

echo "=== Cloud Hexes setup complete! Service on http://$TAILNET_IP:8787 (tailnet only) ==="
REMOTE_SETUP

echo "=== All done! Hexes live on tailnet; public check (expect 000/timeout): ==="
curl -m 8 -o /dev/null -w 'public http://'"$PUBLIC_IP"':8787 -> %{http_code}\n' "http://$PUBLIC_IP:8787/" || true
