#!/usr/bin/env node
// E2E for Tailnet Hexes in hexes-vm. Asserts SPEC.md's failure list plus VM isolation.
// Artifact (~/tailnet-hexes/e2e-artifact.json) holds only check names + verdicts, so
// identical behavior produces an identical file; volatile details go to stdout.
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = homedir();
const OUT = join(HOME, "tailnet-hexes", "e2e-artifact.json");
const BASE = "http://100.109.83.57:8787";
const HOST_BRIDGE = "10.41.19.1", HOST_LAN = "192.168.1.8", HOST_TAILNET = "100.109.83.57";
const PROBE_PORT = 18999;
const checks = [];
const check = (name, ok, detail = "") => {
  checks.push({ name, ok: Boolean(ok) });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  [${detail}]` : ""}`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (...args) => spawnSync(join(HOME, "bin", "hex"), args, { encoding: "utf8" });
const vm = (script, user = "hexes") => {
  const run = user === "root" ? "bash -s" : `runuser -u ${user} -- bash -s`;
  const r = spawnSync("sg", ["incus-admin", "-c", `incus exec hexes-vm -T -- ${run}`], { input: script, encoding: "utf8" });
  return { ok: r.status === 0, out: (r.stdout || "").trim(), err: (r.stderr || "").trim() };
};
const httpCode = (url, extra = []) =>
  spawnSync("curl", ["-s", "--max-time", "4", "-o", "/dev/null", "-w", "%{http_code}", ...extra, url], { encoding: "utf8" }).stdout;
// hexsh <id> "<command>": run a command inside a hex the way a person's `!command` does
// (the same harness env the agent's tools use) and print its output.
const sh = (id, command) =>
  spawnSync("node", [join(HOME, "tailnet-hexes", "hexsh.mjs"), String(id), command], { encoding: "utf8" });
// A command's own verdict, as a word: hexsh exits 0 whenever the command ran, so the
// command reports itself (`... && echo VERDICT-OK || echo VERDICT-NO`).
const verdict = (id, command) => sh(id, command).stdout.trim().split(/\s+/).pop();
// Inside a hex: "000" means the connection could not be made.
const hexCode = (id, url) =>
  sh(id, `curl -s -m 4 -o /dev/null -w '%{http_code}' ${url} || true`).stdout.trim();
// From inside the VM: "000" means the connection could not be made.
const vmCode = (url, user = "root") =>
  vm(`curl -s --max-time 4 -o /dev/null -w '%{http_code}' ${url} || true`, user).out;

// ── Exposure ────────────────────────────────────────────────────────────────
check("9 UI served on tailnet IP", httpCode(`${BASE}/`) === "200");
check("9 UI not served on LAN IP", httpCode(`http://${HOST_LAN}:8787/`) === "000");
const bad = httpCode(`${BASE}/api/sessions`, ["-H", "Cookie: pocket_auth=wrong-token"]);
check("6 bad token rejected", bad === "401" || bad === "403", `status=${bad}`);

// ── Isolation (host-enforced ACL, probed as guest root) ────────────────────
// Separate process: the checks below use spawnSync, which would block an in-process server.
const probe = spawn("python3", ["-m", "http.server", String(PROBE_PORT), "--bind", "0.0.0.0", "--directory", "/tmp"], { stdio: "ignore" });
for (let i = 0; i < 20 && httpCode(`http://127.0.0.1:${PROBE_PORT}/`) !== "200"; i++) await sleep(250);
const hostSees = httpCode(`http://${HOST_BRIDGE}:${PROBE_PORT}/`) === "200" && httpCode(`http://${HOST_LAN}:${PROBE_PORT}/`) === "200";
check("I0 control: host probe listener reachable from host", hostSees);
check("I1 guest root cannot reach host services (bridge IP)", vmCode(`http://${HOST_BRIDGE}:${PROBE_PORT}/`) === "000");
check("I2 guest root cannot reach host via LAN IP", vmCode(`http://${HOST_LAN}:${PROBE_PORT}/`) === "000");
check("I3 guest root cannot reach tailnet (incl. own UI)", vmCode(`http://${HOST_TAILNET}:8787/`) === "000");
probe.kill();
const net = vmCode("https://registry.npmjs.org/", "hexes");
check("I4 control: hexes user has internet egress", net === "200", `npm=${net}`);
check("I5 host filesystem absent in VM", vm("test ! -e /home/adihex && test ! -e /home/hexes/.ssh/id_ed25519").ok);
check("I6 agent user is unprivileged (no sudo)", vm("test \"$(id -u)\" != 0 && ! sudo -n true 2>/dev/null").ok);

// ── Spawn semantics ─────────────────────────────────────────────────────────
const listBefore = hex("list").stdout;
const unknown = hex("spawn", "--project", "no-such-project-xyz", "hi");
check("1 unknown project rejected, no hex created", unknown.status !== 0 && hex("list").stdout === listBefore);

// The server rejects the spawn itself (HTTP 422), so no hex is created and the prompt is never sent.
const badSetup = hex("spawn", "--project", "badsetup", "this prompt must never be sent");
check("8 failing .agents/setup: no hex created, prompt never sent",
  badSetup.status !== 0 && /\.agents\/setup failed/.test(badSetup.stderr || "") && hex("list").stdout === listBefore,
  (badSetup.stderr || "").trim().split("\n").at(-1));

const prompt = 'Create hello.txt containing exactly "hello from hex" (without the quotation marks or a trailing period). Then run `cat hello.txt` to verify. Do not commit.';
const spawned = [];
for (let i = 0; i < 2; i++) {
  const r = hex("spawn", "--project", "demo", prompt);
  if (r.status === 0) spawned.push(JSON.parse(r.stdout));
  else console.log(`spawn ${i + 1} failed: ${(r.stderr || r.stdout).slice(0, 300)}`);
}
check("spawn two hexes", spawned.length === 2);
if (spawned.length === 2) {
  check("2/3 hexes get distinct worktrees, never the project root",
    spawned[0].cwd !== spawned[1].cwd && spawned.every((s) => !s.cwd.endsWith("/hex-projects/demo")));
  check("8 .agents/setup ran inside each hex worktree", spawned.every((s) => vm(`test -f '${s.cwd}/.hex-setup-ran'`).ok));
}

async function waitIdle(id, ms = 300_000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(3000)) {
    const line = hex("list").stdout.split("\n").find((l) => l.startsWith(`${id}\t`));
    if (line?.includes("sleeping")) return true;
  }
  return false;
}
const token = JSON.parse(vm("cat /opt/hexes/data/config.json").out).ownerToken;
async function lastError(id) {
  const h = await (await fetch(`${BASE}/api/c/${id}/history`, { headers: { cookie: `pocket_auth=${token}` } })).json();
  return h.filter((e) => e.kind === "assistant" && e.error).at(-1)?.error?.slice(0, 120) ?? "";
}
const fileIn = (cwd) => { const r = vm(`cat '${cwd}/hello.txt'`); return r.ok ? r.out : "<missing>"; };

for (const s of spawned) {
  const idle = await waitIdle(s.id);
  const content = fileIn(s.cwd);
  check("model: hex completes task in its worktree", idle && content === "hello from hex", content === "<missing>" ? await lastError(s.id) : content);
}

// ── Per-hex isolation (probed from inside the hexes) ───────────────────────
// A freshly spawned hex A, and a second hex B on the same project.
if (spawned.length === 2) {
  const [hexA, hexB] = spawned;
  const uid = sh(hexA.id, "id -u").stdout.trim();
  const host = sh(hexA.id, "hostname").stdout.trim();
  check("H1 tools run as the unprivileged hex user in the hex's own container",
    uid === "1000" && host.startsWith("hex-"), `uid=${uid} host=${host}`);
  check("H2 owner token, server data and code are absent in a hex",
    verdict(hexA.id, "test ! -e /opt/hexes/data/config.json && echo ABSENT || echo PRESENT") === "ABSENT" &&
    verdict(hexA.id, "test ! -e /opt/hexes/app && echo ABSENT || echo PRESENT") === "ABSENT" &&
    sh(hexA.id, "ls /opt/hexes/data").stdout.trim() === "worktrees");
  const urls = ["http://10.42.0.1:8787/", "http://10.41.19.10:8787/", "http://192.168.1.8:8787/", "http://100.109.83.57:8787/"];
  const codes = urls.map((url) => hexCode(hexA.id, url));
  check("H3 a hex cannot reach the server, host, LAN, or tailnet", codes.every((c) => c === "000"), codes.join(","));
  const npm = hexCode(hexA.id, "https://registry.npmjs.org/");
  check("H4 control: a hex has internet egress", npm === "200", `npm=${npm}`);
  check("H5 a hex cannot plant git config, hooks, or attributes",
    verdict(hexA.id, "touch /home/hexes/hex-projects/demo/.git/hooks/x 2>/dev/null && echo WROTE || echo DENIED") === "DENIED" &&
    verdict(hexA.id, "touch /home/hexes/hex-projects/demo/.git/info/attributes 2>/dev/null && echo WROTE || echo DENIED") === "DENIED" &&
    verdict(hexA.id, `cd '${hexA.cwd}' && git config core.fsmonitor x 2>/dev/null && echo WROTE || echo DENIED`) === "DENIED");
  const bGitDir = sh(hexB.id, "git rev-parse --git-dir").stdout.trim();
  sh(hexB.id, "nohup python3 -m http.server 8000 >/tmp/h6.log 2>&1 &");
  await sleep(2000);
  const bControl = hexCode(hexB.id, "http://localhost:8000/");
  // B's own address on the hex bridge: what A would have to reach (A's localhost is A's alone).
  const bAddress = sh(hexB.id, "hostname -I").stdout.trim().split(/\s+/)[0];
  const bHidden = verdict(hexA.id, `test ! -e '${hexB.cwd}' && echo ABSENT || echo PRESENT`);
  const bLocked = verdict(hexA.id, `test ! -w '${bGitDir}/commondir' && echo DENIED || echo WROTE`);
  const bDark = hexCode(hexA.id, `http://${bAddress}:8000/`);
  sh(hexB.id, "pkill -f 'http.server 8000' || true");
  check("H6 hexes cannot see or reach each other",
    bHidden === "ABSENT" && bLocked === "DENIED" && bDark === "000" && bControl === "200",
    `hidden=${bHidden} locked=${bLocked} dark=${bDark} control=${bControl}`);
  check("H7 normal git works in a hex",
    verdict(hexA.id, `cd '${hexA.cwd}' && echo h7 > h7.txt && git add h7.txt && git -c user.name=hex -c user.email=hex@hex.local commit -qm h7 && git branch t && git branch -D t && git pack-refs --all && echo H7OK || echo H7FAIL`) === "H7OK");
}
// Without a worktree the server refuses the session outright.
const noWt = await fetch(`${BASE}/api/sessions`, {
  method: "POST",
  headers: { cookie: `pocket_auth=${token}`, "content-type": "application/json", "x-pocket": "1" },
  body: JSON.stringify({ cwd: "/home/hexes/hex-projects/demo" }),
});
check("H8 sessions outside a hex are refused", noWt.status === 400, `status=${noWt.status}`);

// ── Durability: full VM reboot ─────────────────────────────────────────────
if (spawned.length) {
  spawnSync("sg", ["incus-admin", "-c", "incus restart hexes-vm"], { encoding: "utf8" });
  let up = false;
  for (let i = 0; i < 40 && !up; i++) { await sleep(3000); up = httpCode(`${BASE}/`) === "200"; }
  check("4 service back after VM reboot", up);
  const list = hex("list").stdout;
  check("4 hexes and history survive VM reboot", spawned.every((s) => list.includes(`${s.id}\t`)));
  const sent = hex("send", String(spawned[0].id), "Append a second line 'woke up' to hello.txt, then cat the file. Do not commit.");
  const idle = sent.status === 0 && (await waitIdle(spawned[0].id, 180_000));
  const content = fileIn(spawned[0].cwd);
  check("model: hex wakes after reboot and continues", idle && content.includes("woke up"),
    content.includes("woke up") ? "" : await lastError(spawned[0].id));
}

// ── H9: a git filter planted by a hex never runs as the server ─────────────
// A dedicated hex E (made through the API, no prompt) points its own .git file at a git dir it
// wrote: an index tracking a file it then modifies, and a `clean` filter that touches
// /tmp/pwned-by-hex. The server is then made to run git there (its Changes view). The filter
// must fire inside hex E (positive control: the plant works) and never in the VM. E's git is
// left broken on purpose, so E is used for nothing else and removed right after.
{
  const made = await fetch(`${BASE}/api/sessions`, {
    method: "POST",
    headers: { cookie: `pocket_auth=${token}`, "content-type": "application/json", "x-pocket": "1" },
    body: JSON.stringify({ cwd: "/home/hexes/hex-projects/demo", title: "e2e escape probe", worktree: true }),
  });
  const eId = made.ok ? (await made.json()).id : undefined;
  const eCwd = eId === undefined ? undefined :
    (await (await fetch(`${BASE}/api/sessions`, { headers: { cookie: `pocket_auth=${token}` } })).json())
      .find((s) => s.id === eId)?.worktree?.path;
  let detail = `made=${made.status}`;
  let ok = false;
  if (eId !== undefined && eCwd !== undefined) {
    const evil = `${eCwd}/.evil`;
    const tracked = sh(eId, `cd '${eCwd}' && git ls-files | head -1`).stdout.trim();
    // The base commit comes first, with no filter yet: Changes runs `git diff HEAD` (which runs the
    // clean filter on a modified file) only when HEAD exists, and a filter set before `git add`
    // would fire during planting and fake the control.
    const planted = verdict(eId, [
      `git init -q --bare '${evil}'`,
      `git --git-dir='${evil}' config core.bare false`,
      `git --git-dir='${evil}' --work-tree='${eCwd}' add '${tracked}'`,
      `git --git-dir='${evil}' --work-tree='${eCwd}' -c user.name=e2e -c user.email=e2e@hex commit -qm base`,
      `git --git-dir='${evil}' config filter.x.clean "sh -c 'touch /tmp/pwned-by-hex; cat'"`,
      `echo '* filter=x' > '${eCwd}/.gitattributes'`,
      `echo evil >> '${eCwd}/${tracked}'`,
      `printf 'gitdir: ${evil}\\n' > '${eCwd}/.git'`,
      "test ! -e /tmp/pwned-by-hex",
      "echo PLANTED",
    ].join(" && ") + " || echo NOTPLANTED");
    await fetch(`${BASE}/api/c/${eId}/changes`, { headers: { cookie: `pocket_auth=${token}` } });
    await sleep(3000);
    const vmPwned = vm("test -e /tmp/pwned-by-hex").ok;
    const hexPwned = verdict(eId, "test -e /tmp/pwned-by-hex && echo PWNED || echo CLEAN");
    ok = planted === "PLANTED" && !vmPwned && hexPwned === "PWNED";
    detail = `planted=${planted} vm=${vmPwned ? "PWNED" : "clean"} hex=${hexPwned}`;
    hex("rm", String(eId), "--force");
  }
  check("H9 a git filter planted by a hex never runs as the server", ok, detail);
}

// ── Jojo starts a hex that completes a task (model-dependent) ──────────────
// Asked through the same route its panel posts to (POST /api/pip, then the new
// conversation's submit), Jojo starts a hex in project demo and follows it.
let jojoHex = null;
const listHexes = () =>
  hex("list").stdout.split("\n")
    .filter((l) => /^\d+\t/.test(l))
    .map((l) => ({ id: l.split("\t")[0], cwd: l.split("\t")[3] }));
{
  const seen = new Set(listHexes().map((s) => s.id));
  const opened = await (await fetch(`${BASE}/api/pip`, {
    method: "POST",
    headers: { cookie: `pocket_auth=${token}`, "content-type": "application/json", "x-pocket": "1" },
    body: JSON.stringify({ connection: "e2e-jojo", on: true }),
  })).json();
  const jojoId = opened?.pip?.id;
  let asked = false;
  if (jojoId !== undefined) {
    const sent = await fetch(`${BASE}/api/c/${jojoId}/submit`, {
      method: "POST",
      headers: { cookie: `pocket_auth=${token}`, "content-type": "application/json", "x-pocket": "1" },
      body: JSON.stringify({
        text: "Start a hex in project demo that creates jojo.txt containing exactly: hello from jojo. Follow it.",
        requestId: randomUUID(),
      }),
    });
    asked = sent.ok;
  }
  let found = "";
  if (asked) {
    for (const t0 = Date.now(); Date.now() - t0 < 300_000; await sleep(5000)) {
      for (const s of listHexes().filter((s) => !seen.has(s.id) && String(s.id) !== String(jojoId))) {
        if (s.cwd !== undefined && sh(s.id, `cat '${s.cwd}/jojo.txt'`).stdout.trim() === "hello from jojo") {
          jojoHex = s.id;
          found = `${s.id}:jojo.txt`;
          break;
        }
      }
      if (jojoHex !== null) break;
    }
  }
  check("model: Jojo starts a hex that completes a task", jojoHex !== null, found || (asked ? "no hex wrote jojo.txt in time" : "Jojo was not asked"));
  for (const s of listHexes().filter((s) => !seen.has(s.id) && String(s.id) !== String(jojoId) && String(s.id) !== String(jojoHex))) {
    hex("rm", String(s.id), "--force");
  }
  if (jojoHex !== null) hex("rm", String(jojoHex), "--force");
}

// ── 7: removal (also cleans up this run) ───────────────────────────────────
if (spawned.length === 2) {
  const [a, b] = spawned; // both worktrees hold an untracked .hex-setup-ran → uncommitted work
  const branch = vm(`git -C '${a.cwd}' rev-parse --abbrev-ref HEAD`).out;
  const refused = hex("rm", String(a.id));
  check("7 rm refuses a hex with uncommitted work", refused.status !== 0 && vm(`test -d '${a.cwd}'`).ok);
  const forced = hex("rm", String(a.id), "--force");
  check("7 rm --force removes worktree, keeps branch",
    forced.status === 0 && !vm(`test -e '${a.cwd}'`).ok && vm(`git -C /home/hexes/hex-projects/demo rev-parse --verify -q 'refs/heads/${branch}'`).ok);
  check("7 sibling hex untouched by rm", vm(`test -d '${b.cwd}'`).ok && hex("list").stdout.includes(`${b.id}\t`));
  hex("rm", String(b.id), "--force");
} else for (const s of spawned) hex("rm", String(s.id), "--force");

const artifact = { suite: "tailnet-hexes-vm", checks, pass: checks.every((c) => c.ok) };
writeFileSync(OUT, JSON.stringify(artifact, null, 2) + "\n");
console.log(`\nartifact: ${OUT} — ${checks.filter((c) => c.ok).length}/${checks.length} pass`);
process.exit(artifact.pass ? 0 : 1);
