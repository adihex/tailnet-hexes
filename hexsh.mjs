#!/usr/bin/env node
// hexsh <id> "<command>": run a command in hex <id> the way a person's `!command` does (the
// same harness env the agent's tools use), wait for it, and print its output. Exit 0 when the
// command ran (whatever its own exit status), 1 when it could not be run. Used by e2e.mjs.
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";

const BASE = process.env.HEX_URL ?? "http://100.109.83.57:8787";
const [id, command] = process.argv.slice(2);
if (!id || !command) { console.error('usage: hexsh <id> "<command>"'); process.exit(2); }

const cfg = spawnSync("sg", ["incus-admin", "-c", "incus exec hexes-vm -- cat /opt/hexes/data/config.json"], { encoding: "utf8" });
const token = JSON.parse(cfg.stdout).ownerToken;
const headers = { cookie: `pocket_auth=${encodeURIComponent(token)}` };
const marker = `hexsh-${randomUUID()}`;

const started = await fetch(`${BASE}/api/c/${id}/shell`, {
  method: "POST",
  headers: { ...headers, "content-type": "application/json", "x-pocket": "1" },
  body: JSON.stringify({ command: `${command}\necho ${marker}`, requestId: randomUUID(), context: false }),
});
if (!started.ok) { console.error(`shell refused: ${started.status} ${await started.text()}`); process.exit(1); }

for (let i = 0; i < 120; i++) {
  const history = await (await fetch(`${BASE}/api/c/${id}/history`, { headers })).json();
  const entry = history.find((e) => JSON.stringify(e).includes(`echo ${marker}`) && e.status && e.status !== "running");
  if (entry) {
    const output = String(entry.output ?? "").replace(`${marker}\n`, "").replace(marker, "");
    process.stdout.write(output);
    process.exit(entry.status === "failed" && !String(entry.output ?? "").includes(marker) ? 1 : 0);
  }
  await new Promise((r) => setTimeout(r, 500));
}
console.error("timed out waiting for the command");
process.exit(1);
