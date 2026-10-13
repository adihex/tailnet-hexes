# Patches to upstream pi-pocket

Base: TannerMidd/pi-pocket (MIT) 0.13.2, cloned 2026-10-13 into `app/`. Our changes are commits on
the local branch `hexes` (`git -C app log --oneline main..hexes`); to take an upstream release,
`git -C app fetch origin && git -C app rebase origin/main hexes`, then run `npm run check` and the E2E.

| Commit | Change |
|---|---|
| `hexes: brand the app as Hexes` | `web/index.html`, `web/manifest.webmanifest`, `web/app.js`, `web/signin.js`: app name. |
| `hexes: run every session but PiP in an Incus container of its own (pi-env)` | Per-hex isolation, on only with `HEXES=1` (without it the fork behaves as upstream). `src/server/hexes.ts` (new): hex lifecycle (copy of `hex-base`; worktree and project `.git` mounted with `config`, `hooks`, `info`, `modules`, `worktrees` read-only and the hex's own worktree entry writable), `.agents/setup` run inside the new hex, and a pi-env `RemoteExecutionEnv` per hex. `app.ts`: every conversation's tools run in its hex; one outside a hex (other than PiP/Jojo) gets no place to run. `git.ts`: the server's git in a hex runs inside the hex; hooks off for all server git. `worktrees.ts`: a hex's worktree is removed by its known path, never through git metadata the hex could rewrite. `commands.ts`: sessions need a worktree; terminal Pi sessions cannot continue here. `package.json`: `@earendil-works/pi-env` 1.1.0. |
| `jojo: PiP becomes Jojo, hex-aware, and kept out of the data and agent folders` | User-visible `PiP` → `Jojo` (string literals only: identifiers, file names, CSS classes, routes such as `/api/pip`, and comments keep `pip`); `/pip` → `/jojo`; the preamble introduces Hexes; a `pip_hexes` prompt section (with `HEXES=1`) says how to start a hex and lists the projects; a `ToolTask` guard blocks Jojo reads that resolve (symlinks followed) into the data folder (except `worktrees/`, `uploads/`) or the agent folder; tests follow the rename. Built in hex #805, reviewed on the host. |
| `hexes: wait for a new hex to finish booting before using it` | `hexes.ts`: `createHex` waits for `systemctl is-system-running --wait`, retrying early bus-not-ready errors. Each status command has a 60 s timeout; no new retry starts after the 60 s retry window. Without it, files written right after creation (by `.agents/setup`, or the first tool call) landed under the boot-time `/tmp` tmpfs and vanished. |
| `hexes: environment lifecycle (suspend/wake) and coordinated container forks` | `hexes.ts`: `hexStatus`, `suspendHex`, `wakeHex` using Incus pause/start, and `createHex` support for cloning parent container rootfs. `commands.ts`: `fork` accepts `environment: true` and defaults `entryId` to latest finished assistant reply; auto-wake hex before turns in `submit`. `conversation-routes.ts`: `GET /api/c/:id/environment` and `POST` with `suspend`/`wake`. `worktrees.ts`: run `git worktree add` from main repository outside the read-only `.git/worktrees` hex mount. |

Why the git changes matter: upstream runs `git` itself in a session's folder (Changes, branches,
worktrees) and says so (`git.ts`: filters a repository configures still run). Fine for one trusted
user; with untrusted hexes, a hex could point its `.git` at a config it wrote and have the server
run it. E2E check H9 plants exactly that and asserts it runs inside the hex, never in the VM.

Deployment, not code (`vm/provision.sh`): the launcher runs in `hexes-vm` as `hexes`, with
`HEXES=1`, `--host 10.41.19.10 --port 8787`, data in `/opt/hexes/data`, default cwd
`/home/hexes/hex-projects`, and the Browser panel on the VM's Chromium. The owner's default model
lives in `/opt/hexes/data/config.json`.

Outside the fork: the `hex` CLI (`hex.mjs`: project registry, spawn, diff, rm, shell), the VM and
Incus scripts (`vm/`), and the E2E (`e2e.mjs`, `hexsh.mjs`).
