#!/usr/bin/env bash
# Incus inside hexes-vm, for hexes (one container per hex). Runs as root inside the VM; idempotent.
#  - pool `hexes`: btrfs, so each hex is a copy-on-write clone of `hex-base` (vm/hex-base.sh)
#  - bridge `hexbr0` with the ACL `hex-egress` set on the network (Incus 6.0.4 drops bridge DNS for ACLs set on a
#    NIC, and fails to re-apply them): a hex reaches the internet and DNS only; not the VM, its server, the host,
#    LAN, or tailnet
#  - profile `hex`: limits, and port isolation so hexes cannot reach each other
# Every incus call reads </dev/null: with no terminal, incus reads YAML from stdin.
set -euo pipefail

if ! incus storage show hexes >/dev/null 2>&1; then
  incus admin init --preseed <<'YAML'
storage_pools:
- name: hexes
  driver: btrfs
  config:
    size: 40GiB
networks:
- name: hexbr0
  type: bridge
  config:
    ipv4.address: 10.42.0.1/24
    ipv4.nat: "true"
    ipv6.address: none
YAML
fi

incus network acl show hex-egress >/dev/null 2>&1 || incus network acl create hex-egress </dev/null
incus network acl edit hex-egress <<'YAML'
name: hex-egress
description: "A hex may reach the internet and DNS only: not the VM, its server, other hexes, the host, LAN, or tailnet"
egress:
- action: reject
  state: enabled
  description: VM, server, host, LAN, CGNAT/tailnet, link-local, private IPv4 (bridge DNS/DHCP stay allowed by Incus baseline rules)
  destination: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16
- action: reject
  state: enabled
  description: IPv6 ULA and link-local
  destination: fc00::/7,fe80::/10
ingress:
- action: allow
  state: enabled
  description: the VM (server-side browser panel) may reach a hex's dev servers
  source: 10.42.0.1
YAML
incus network set hexbr0 security.acls=hex-egress \
  security.acls.default.egress.action=allow security.acls.default.ingress.action=reject </dev/null

incus profile show hex >/dev/null 2>&1 || incus profile create hex </dev/null
incus profile edit hex <<'YAML'
description: "One hex = one container, isolated from the VM, its server, and other hexes"
config:
  limits.cpu: "2"
  limits.memory: 3GiB
  limits.processes: "2000"
  security.nesting: "false"
  security.privileged: "false"
devices:
  root: {path: /, pool: hexes, type: disk, size: 20GiB}
  eth0:
    name: eth0
    network: hexbr0
    type: nic
    security.port_isolation: "true"
YAML
echo "hexes incus ready: pool hexes, bridge hexbr0 + ACL hex-egress, profile hex"
