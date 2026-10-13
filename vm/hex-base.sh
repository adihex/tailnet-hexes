#!/usr/bin/env bash
# Build `hex-base`, the container every hex is cloned from (btrfs copy-on-write).
# Runs as root inside hexes-vm. Expects the pi-env daemon at /root/pi-env (linux-x64).
# Idempotent: rebuilds hex-base from scratch; existing hexes are untouched.
set -euo pipefail

[ -x /root/pi-env ] || { echo "missing /root/pi-env daemon" >&2; exit 1; }
incus delete --force hex-base </dev/null 2>/dev/null || true
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
NODE_TAR=$(awk '/linux-x64\.tar\.xz$/ {print $2}' /tmp/node.sha)
curl -fsSL "https://nodejs.org/dist/latest-v24.x/${NODE_TAR}" -o "/tmp/${NODE_TAR}"
(cd /tmp && grep " ${NODE_TAR}\$" node.sha | sha256sum -c - >/dev/null)
tar -xJf "/tmp/${NODE_TAR}" -C /usr/local --strip-components=1
rm -f /tmp/node.sha "/tmp/${NODE_TAR}"
# The agent's user: uid 1000, no sudo. Mounted hex files appear owned by it (shift=true).
id hex >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash hex
runuser -u hex -- git config --global user.name hex
runuser -u hex -- git config --global user.email hex@hexes-vm
# gc expires every worktree's reflogs, and other hexes' entries are read-only here: never gc in a hex.
runuser -u hex -- git config --global gc.auto 0
apt-get clean
EOS

incus file push /root/pi-env hex-base/usr/local/bin/pi-env --mode 0755 </dev/null
incus exec hex-base -- /usr/local/bin/pi-env --version </dev/null || incus exec hex-base -- ls -la /usr/local/bin/pi-env </dev/null
incus stop hex-base </dev/null
echo "hex-base ready: node $(incus exec hex-base -- true 2>/dev/null; echo stopped)"
