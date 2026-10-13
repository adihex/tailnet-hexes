#!/usr/bin/env node
// hex — spawn and steer hexes (Amp-style orbs). The pi-durable service runs inside the Incus VM
// `hexes-vm`; every hex is a container of its own inside it (the server makes it, and runs the
// project's .agents/setup in it). This CLI runs on the host: HTTP API through the tailnet proxy,
// files through `incus exec`.
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient, VM, PUBLIC_URL as PUBLIC, quote as q, isGitUrl as isUrl, loadRegistry, saveRegistry, vm } from "./hex-client.mjs";

function fail(message) { console.error(`hex: ${message}`); process.exit(1); }
const client = createClient();
const api = (...args) => client.request(...args);

const [cmd, ...rest] = process.argv.slice(2);

try {

if (cmd === "add") {
  const [name, source] = rest;
  if (!name || !source) fail("usage: hex add <name> <git-url|host-path>");
  const registry = loadRegistry();
  registry[name] = { source: isUrl(source) ? source : resolve(source) };
  saveRegistry(registry);
  console.log(`${name} → ${registry[name].source} (copied/cloned into ${VM} on first spawn)`);
} else if (cmd === "projects") {
  console.log(JSON.stringify(loadRegistry(), null, 2));
} else if (cmd === "spawn") {
  let project, title; const words = [];
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--project") project = rest[++i];
    else if (rest[i] === "--title") title = rest[++i];
    else words.push(rest[i]);
  }
  const prompt = words.join(" ");
  if (!project || !prompt) fail('usage: hex spawn --project <name|path|git-url> [--title T] "prompt"');
  console.log(JSON.stringify(await client.start({ project, prompt, title }), null, 2));
} else if (cmd === "list") {
  const sessions = (await api("/api/sessions")).filter((s) => !s.archived);
  for (const s of sessions) console.log(`${s.id}\t${s.busy ? "working" : "sleeping"}\t${s.title ?? ""}\t${s.worktree?.path ?? s.cwd}`);
  if (!sessions.length) console.log('(no hexes — hex spawn --project <p> "prompt")');
} else if (cmd === "send") {
  const [id, ...words] = rest;
  if (!id || !words.length) fail('usage: hex send <id> "prompt"   (steers if working, wakes if sleeping)');
  await client.send(id, words.join(" "));
  console.log(`sent to hex ${id}: ${PUBLIC}/#/c/${id}`);
} else if (cmd === "stop") {
  const [id] = rest; if (!id) fail("usage: hex stop <id>");
  await api(`/api/c/${id}/abort`, { method: "POST", body: {} });
  console.log(`hex ${id} stopped (sleeping; history kept)`);
} else if (cmd === "diff") {
  const [id] = rest; if (!id) fail("usage: hex diff <id>");
  const changes = await api(`/api/c/${id}/changes`);
  console.log(typeof changes === "string" ? changes : JSON.stringify(changes, null, 2));
} else if (cmd === "rm") {
  const force = rest.includes("--force");
  const [id] = rest.filter((a) => a !== "--force");
  if (!id) fail("usage: hex rm <id> [--force]   (--force discards uncommitted changes in the hex)");
  await api(`/api/c/${id}/worktree`, { method: "POST", body: { remove: true, force } });
  await api(`/api/sessions/${id}`, { method: "POST", body: { archived: true } });
  console.log(`hex ${id} archived; worktree removed (branch kept)`);
} else if (cmd === "url") {
  console.log(client.loginUrl());
} else if (cmd === "attach") {
  const [id] = rest;
  if (!id) fail("usage: hex attach <id>");
  const viewer = join(dirname(fileURLToPath(import.meta.url)), "hex-attach.tsx");
  const result = spawnSync("bun", [viewer, id], { stdio: "inherit" });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} else if (cmd === "status" || cmd === "history" || cmd === "wait" || cmd === "suspend" || cmd === "wake") {
  const [id] = rest;
  if (!id) fail(`usage: hex ${cmd} <id>`);
  console.log(JSON.stringify(await client[cmd](id), null, 2));
} else if (cmd === "fork") {
  const [id, entry] = rest;
  if (!id) fail("usage: hex fork <id> [finished-reply-entry-id]");
  console.log(JSON.stringify(await client.fork(id, { entryId: entry ? Number(entry) : undefined }), null, 2));
} else if (cmd === "shell") {
  // `hex shell <id>`: a shell inside that hex, as its agent user. `hex shell`: the VM, as the service user.
  const [id] = rest;
  let inner = "runuser -u hexes -- bash -l";
  if (id) {
    const path = (await api("/api/sessions")).find((s) => String(s.id) === id)?.worktree?.path;
    if (!path) fail(`no hex ${id} with a worktree`);
    const name = vm(`for n in $(incus list -f csv -c n); do [ "$(incus config device get "$n" work source 2>/dev/null)" = ${q(path)} ] && echo "$n"; done`).out;
    if (!name) fail(`hex ${id} has no container`);
    inner = `incus exec ${name} -t --user 1000 --group 1000 --cwd ${q(path)} --env HOME=/home/hex -- bash -l`;
  }
  spawnSync("sg", ["incus-admin", "-c", `incus exec ${VM} -t -- ${inner}`], { stdio: "inherit" });
} else {
  console.log(`hex — hexes (Amp-style orbs) on pi-durable, inside Incus VM ${VM}, tailnet-only

  hex add <name> <git-url|host-path>  register a project (copied/cloned into the VM on first spawn)
  hex projects                        list projects
  hex spawn --project P "prompt"      fresh hex: own worktree + agent, prints URL (like amp -ox)
  hex list                            hexes: agent working | sleeping
  hex attach <id>                     native Tern viewer (plain terminal fallback)
  hex status <id>                     session state
  hex history <id>                    committed transcript
  hex wait <id>                       wait for a run without owning its lifetime
  hex suspend <id> / hex wake <id>     suspend/wake the idle environment
  hex fork <id> <entry-id>             fork history and snapshot current environment
  hex send <id> "prompt"              steer a working hex / wake a sleeping one
  hex stop <id>                       stop the run; hex sleeps, history kept
  hex diff <id>                       uncommitted changes in the hex
  hex rm <id> [--force]               archive hex, remove its worktree (branch kept; --force discards uncommitted work)
  hex url                             owner sign-in link (keep private)
  hex shell [<id>]                    shell inside a hex as its agent user (no id: the VM, as the service user)

UI: ${PUBLIC}`);
}
} catch (error) {
  fail(error.message);
}
