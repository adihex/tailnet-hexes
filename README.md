# Tailnet Hexes

My version of [Amp's Orbs](https://ampcode.com/docs/orbs), called **hexes**, on
[Pi Durable](https://github.com/earendil-works/pi/tree/main/packages/durable),
reachable only on my tailnet. Design and failure list: [SPEC.md](SPEC.md).

**Open:** http://adi-linux.tail6c6fd6.ts.net:8787. The sign-in link comes from
`hex url` on adi-linux; it carries the owner key, so keep it private.

A hex is a durable Pi agent in a fresh git worktree of a project. Spawn as many
as you like, close the laptop, steer from your phone, review the diff, and let
it sleep. An idle hex costs nothing, and the next message wakes it with the full
conversation. State is SQLite-backed and survives service restarts, crashes, and
VM reboots.

## Isolation

Two walls. The outer one: the service and all hexes run inside the Incus VM
`hexes-vm` (Debian 13, its own kernel). The service runs there as the
unprivileged user `hexes`: no sudo, no host mounts, no host credentials. The
host enforces the VM's network policy with the Incus ACL `hexes-egress`, so
even root inside the VM cannot loosen it:

| From the VM to | Result |
|---|---|
| Internet (model APIs, GitHub, npm) | allowed |
| Host services, LAN, tailnet, any private/ULA range | rejected |
| Into the VM | only the host proxy, on tcp/8787 |

The UI is published by a host socket proxy on the tailnet IP only
(100.109.83.57:8787 → 10.41.19.10:8787). Nothing listens on LAN or public addresses.

### Per-hex containers (the inner wall)

Inside the VM, every session except Jojo's runs in a container of its own
(`hex-<worktree>`, cloned copy-on-write from `hex-base`), as the
unprivileged user `hex` (uid 1000). Mounts, enforced by Incus (`shift=true`, so
files appear owned by `hex`):

| Mount | Mode |
|---|---|
| The hex's own worktree | read-write |
| The project's `.git` (objects, refs) | read-write |
| `.git/config`, `.git/hooks`, `.git/info`, `.git/modules`, `.git/worktrees` | read-only |
| The hex's own `.git/worktrees/<name>` entry | read-write |
| Other hexes' `.git/worktrees/*` entries | read-only |

Network (`hexbr0` + ACL `hex-egress` + port isolation): a hex reaches the
internet and DNS only — not the VM, its server, the host, LAN, tailnet, or
other hexes. The server's own git commands in a hex run inside the hex too,
so nothing a hex writes (a `.git` pointer, a config, a filter) ever runs as
the server or in another hex.

What a hex cannot do: `git gc` (`gc.auto 0` globally — gc would expire every
worktree's reflogs, and other hexes' entries are read-only there); write the
shared repo's `.git/config`, so it cannot record a branch's upstream. Push, fetch,
and pull with the remote and branch named — `git push origin HEAD`,
`git fetch origin`, `git pull origin <branch>` — which work and write no config
(verified against a throwaway remote). `git push -u` (and `push.autoSetupRemote`)
push the branch but then fail to record its upstream: git prints `could not write
config file`, may still say "set up to track", and exits 0 — the upstream is not set.
A plain `git push` on a new branch fails with "no upstream branch" and pushes nothing.

### Jojo

Jojo is Amp's Puck equivalent: the owner's assistant over every hex, in a
small panel over whatever is open (Alt+A, or `/jojo`). It finds out what
hexes are doing, starts and messages them, stops and archives them, follows
runs until they end, and watches GitHub. It only reads — it never writes code
or runs commands itself — and it cannot read the server's data folder or the
agent folder (owner token, database, model sign-ins).

### Residual risks

- Hexes of the same project share the git object store and refs, so they can
alter each other's branches.
- A container shares the VM's kernel: the VM is the outer wall.
- Anyone who can steer a hex controls its container. Give projects only
scoped credentials.

## CLI (on adi-linux)

```bash
hex add demo ~/hex-projects/demo        # or: hex add web https://github.com/you/web.git
hex spawn --project demo "Fix login"    # fresh hex: own worktree + container, prints URL
hex list                                # working | sleeping
hex status <id>                         # session details + container status
hex send 3 "Also run the full suite"    # steer a working hex, or wake a sleeping one
hex diff 3                              # uncommitted changes in the hex
hex attach 3                            # live native Tern viewer (or plain ANSI terminal)
hex suspend 3 / hex wake 3              # pause/resume container (cgroup freezer)
hex fork 3 [entry-id]                   # fork session history & clone container environment
hex stop 3                              # stop the run; hex sleeps, history stays
hex rm 3 [--force]                      # archive; worktree removed, branch kept
hex url                                 # owner sign-in link
hex shell [<id>]                        # shell in a hex as its agent user (no id: the VM as `hexes`)
```

Projects are copied (host path) or cloned (git URL) into the VM on first spawn.
Each new container finishes booting before `.agents/setup` or tools run, so early
files are not hidden by the boot-time `/tmp` mount. `.agents/setup` runs once inside
each new hex, in its worktree, before the first prompt, following Amp's convention.
If it fails, no hex is created (the spawn fails with the script's output) and the
prompt is never sent.

## Model sign-in (one time)

Host credentials are deliberately not copied into the VM. Open the UI, go to
**Providers**, and sign in or paste an API key; it is stored only inside the
VM (`~hexes/.pi/agent/auth.json`). Use a scoped, spend-capped key. The default
model is `meta/muse-spark-1.3-contributor`; change it in the UI. Contributor
mode is cheap because Meta may train on what it receives, which includes your
code: pick `muse-spark-1.3` (standard) for code you do not want shared.

## Layout

- `app/` is a fork of [pi-pocket](https://github.com/TannerMidd/pi-pocket) (MIT);
  see [PATCHES.md](PATCHES.md). It runs in the VM at `/opt/hexes/app`.
- `hex.mjs` (`~/bin/hex`) is the hexes layer: project registry
  (`~/.hexes/projects.json`) plus spawn, diff, attach, fork, suspend/wake, and rm CLI.
- `hex-client.mjs` is the shared controller client library for HTTP/SSE communication.
- `hex-attach.tsx` is the Tern-native attach client using `@stencil-hq/tern`.
- `omp-hexes.ts` is the OMP extension exposing Hex tools (`hex_start`, `hex_list`, `hex_send`,
  `hex_status`, `hex_history`, `hex_diff`, `hex_wait`, `hex_stop`, `hex_suspend`, `hex_wake`, `hex_fork`)
  and the `/hex` slash command. Installed at `~/.omp/agent/extensions/hexes.ts`.
- `vm/provision.sh` builds the VM (run as root inside it).
- `vm/host-setup.sh` sets up the host side: ACL, fixed IP, autostart, tailnet proxy.
- `vm/hexes-incus.sh` sets up Incus inside the VM for hexes: pool, bridge, ACL `hex-egress`, profile `hex`.
- `vm/hex-base.sh` builds `hex-base`, the container every hex is cloned from (expects the
  pi-env daemon at `/root/pi-env` in the VM).
- `hexsh.mjs <id> "<command>"` runs a command inside a hex the way `!command` does (used by the E2E).
- `e2e.mjs` is the end-to-end test. It writes `e2e-artifact.json` (check names
  and verdicts only, so it is repeatable).
## Ops

```bash
systemctl --user status hexes-proxy.socket                         # host: tailnet proxy
sg incus-admin -c "incus list hexes-vm"                            # host: the VM (autostarts)
sg incus-admin -c "incus exec hexes-vm -- journalctl -u hexes -f"  # service log
hex shell [<id>]                                                   # a hex as its agent user, or the VM as `hexes`
node ~/tailnet-hexes/e2e.mjs                                       # re-run the E2E
```

The VM-side scripts run as root inside the VM, pushed from the host (`hexes` has no sudo):

```bash
I() { sg incus-admin -c "incus $*"; }
I file push vm/hexes-incus.sh hexes-vm/root/ && I exec hexes-vm -- bash /root/hexes-incus.sh  # idempotent
I file push vm/hex-base.sh hexes-vm/root/ && I exec hexes-vm -- bash /root/hex-base.sh        # rebuild hex-base; hexes untouched
```

For an HTTPS MagicDNS name, run once (needs sudo):
`sudo tailscale set --operator=$USER && tailscale serve --bg --https=443 http://100.109.83.57:8787`
