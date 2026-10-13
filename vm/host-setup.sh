#!/usr/bin/env bash
# Host side of hexes-vm. Run as adihex (member of incus-admin). Idempotent.
#  - Incus ACL `hexes-egress`, enforced by the host (a compromised guest cannot change it):
#      egress: internet allowed; host, LAN, tailnet, and every private/ULA range rejected
#      ingress: only the host proxy (10.41.19.1) → tcp/8787
#  - fixed address 10.41.19.10 (dnsmasq reservation) and autostart
#  - user-level socket proxy: tailnet IP 100.109.83.57:8787 → 10.41.19.10:8787
set -euo pipefail
I() { sg incus-admin -c "incus $*"; }
VM=hexes-vm
VM_IP=10.41.19.10
TAILNET_IP=100.109.83.57

I network acl show hexes-egress >/dev/null 2>&1 || I network acl create hexes-egress
cat <<EOF | sg incus-admin -c "incus network acl edit hexes-egress"
name: hexes-egress
description: hexes-vm may reach the internet only; nothing on the host, LAN, or tailnet
egress:
- action: reject
  state: enabled
  description: host, LAN, CGNAT/tailnet, link-local, private IPv4
  destination: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16
- action: reject
  state: enabled
  description: IPv6 ULA (includes tailnet fd7a:115c:a1e0::/48 and the bridge)
  destination: fc00::/7
ingress:
- action: allow
  state: enabled
  description: host proxy to the Hexes web service
  source: 10.41.19.1
  protocol: tcp
  destination_port: "8787"
EOF

# Instance-level NIC: fixed IP + ACL. Default egress allow (internet), default ingress reject.
if ! I config device show $VM | grep -q '^eth0:'; then
  I config device override $VM eth0 ipv4.address=$VM_IP
fi
I config device set $VM eth0 security.acls=hexes-egress \
  security.acls.default.egress.action=allow security.acls.default.ingress.action=reject
I config set $VM boot.autostart=true

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/hexes-proxy.socket <<EOF
[Unit]
Description=Hexes UI on the tailnet IP only (proxied into hexes-vm)

[Socket]
ListenStream=$TAILNET_IP:8787
FreeBind=true

[Install]
WantedBy=sockets.target
EOF
cat > ~/.config/systemd/user/hexes-proxy.service <<EOF
[Unit]
Description=Proxy tailnet :8787 to hexes-vm
Requires=hexes-proxy.socket
After=hexes-proxy.socket

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd $VM_IP:8787
EOF

systemctl --user daemon-reload
systemctl --user enable --now hexes-proxy.socket
echo "host setup done: ACL hexes-egress on $VM, proxy $TAILNET_IP:8787 → $VM_IP:8787"
