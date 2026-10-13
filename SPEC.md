# Tailnet Hexes: spec

My version of Amp's Orbs (https://ampcode.com/docs/orbs), where each orb is a
**hex**, built on [Pi Durable](https://github.com/earendil-works/pi/tree/main/packages/durable),
isolated in an Incus VM, and reachable only on my tailnet.

## Reuse, not reinvention

| Piece | Source | What it provides |
|---|---|---|
| Durable agent harness | `@earendil-works/pi-durable` 1.1 | Conversations, model calls, and tool calls committed to SQLite before display; crash resume; steer/follow-up inbox |
| Web app and server | Fork of [TannerMidd/pi-pocket](https://github.com/TannerMidd/pi-pocket) (MIT) in `app/` | Multiplayer mobile-first UI, per-session git worktrees, Files/Changes review, shell, schedules, Browser panel |
| VM isolation | [Incus](https://linuxcontainers.org/incus/) VM plus a host-enforced network ACL; pattern from [Coi](https://github.com/coipond/coi) and [Agentic Sandbox](https://github.com/jmagly/agentic-sandbox) | Separate kernel; no host files or credentials; egress policy the guest cannot change |
| Orb semantics | Amp Orbs docs; [schani/pi-orb](https://github.com/schani/pi-orb) and [richardanaya/pi-orbs](https://github.com/richardanaya/pi-orbs) (read only) | Project → fresh isolated workspace per thread, `.agents/setup` hook, spawn from the CLI, sleep/wake |

## Mapping: Amp orb → hex

- **Hex**: one pi-pocket session (one pi-durable conversation) in its own git
  worktree, inside `hexes-vm`.
- **Project**: an entry in `~/.hexes/projects.json` (name → host path or git
  URL). It is copied or cloned into `/home/hexes/hex-projects/<name>` on first
  spawn; every hex then gets a worktree of it.
- **Sleep/wake**: pi-durable idleness. An idle hex runs nothing; the next
  message resumes the exact conversation, even after a VM reboot.
- **Spawn from the CLI**: `hex spawn --project P "prompt"` (like `amp -ox`).
  It prints the hex's tailnet URL and exits.
- **Changes/Files/Terminal**: pi-pocket's Changes, Files, and shell panels,
  scoped to the hex's worktree.
- **Portal**: the Browser panel, driving Chromium inside the VM. Public
  per-hex URLs are out of scope.

## Failure list (the spec; `e2e.mjs` asserts it)

1. Spawn with an unknown project → the CLI exits non-zero and no hex is created.
2. A project copied in from the host must still yield a worktree. (Stale
   host stat data used to make `git stash create` fail.)
3. Two hexes on one project get distinct worktrees, never the project root.
4. A VM reboot: the service comes back, and hexes and history survive.
   A hex wakes and continues on the next message.
5. A message sent to a busy hex is queued as a follow-up or steer
   (pi-durable inbox; `requestId` dedupes retries).
6. A bad sign-in token gets 401/403.
7. Removing a hex: `rm` refuses uncommitted work; `rm --force` removes the
   worktree but keeps the branch; sibling hexes are untouched.
8. A failing `.agents/setup` makes the spawn fail: the server rejects it (HTTP
   422), so no hex is created and the prompt is never sent. A passing setup runs
   inside each new worktree.
9. The UI is served on the tailnet IP and not on the LAN IP.

Isolation (host-enforced, probed as root inside the VM, each with a positive control):

- I1–I3: the guest cannot reach host services (bridge IP), the host's LAN IP,
  or the tailnet. Control I0: the host reaches its own probe listener.
- I4: the guest has internet egress (control).
- I5: no host filesystem or credentials exist in the VM.
- I6: the agent user is unprivileged.

Per-hex isolation (probed from inside the hexes with `hexsh.mjs`, each with a
positive control):

- H1: a hex's tools run as the unprivileged hex user (uid 1000) in the hex's
  own container (hostname `hex-*`).
- H2: the owner token, server data, and server code are absent in a hex
  (`/opt/hexes/data/config.json` and `/opt/hexes/app` do not exist;
  `/opt/hexes/data` holds only `worktrees`).
- H3: a hex cannot reach the server, host, LAN, or tailnet (curl to the
  bridge, host LAN, and tailnet addresses gives `000`). Control H4: a hex has
  internet egress (`https://registry.npmjs.org/` gives `200`).
- H5: a hex cannot plant git config, hooks, or attributes (writes to
  `.git/hooks/x`, `.git/info/attributes`, and `git config` on the shared repo
  all fail).
- H6: hexes cannot see or reach each other (a sibling's worktree path does not
  exist, its `.git/worktrees/<name>/commondir` is not writable, its port 8000
  gives `000`; control: the sibling itself gets `200`).
- H7: normal git works in a hex (commit, branch create/delete, `pack-refs`).
- H8: sessions outside a hex are refused (`POST /api/sessions` without a
  worktree returns 400).
- H9: a git filter planted by a hex never runs as the server (an evil `clean`
  filter fires inside the hex only — positive control — and never in the VM).

Model-dependent checks fail until a provider is signed in inside the VM.

## Non-goals

Public URLs or funnel, one VM per hex (one shared VM; per-hex containers inside
it are now how every session runs), billing, Amp's cloud snapshots.

## Jojo

Jojo is Amp's Puck equivalent, built on pi-pocket's owner assistant PiP
(renamed; routes, identifiers, file names, and CSS classes keep `pip`).
What it can do, `/jojo`, Alt+A, and that it only reads (never the data or
agent folders) are in [README.md](README.md).
