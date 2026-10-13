import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

export const VM = process.env.HEX_VM ?? "hexes-vm";
export const PUBLIC_URL = process.env.HEX_PUBLIC_URL ?? "http://adi-linux.tail6c6fd6.ts.net:8787";
const CONFIG = "/opt/hexes/data/config.json";
const REGISTRY = join(homedir(), ".hexes", "projects.json");
export const quote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;
export const isGitUrl = (value) => /^(https?:|git@|ssh:)/.test(value) || value.endsWith(".git");

export function vm(script, { allowFail = false } = {}) {
  const result = spawnSync("sg", ["incus-admin", "-c", `incus exec ${VM} -T -- runuser -u hexes -- bash -s`], {
    input: `set -euo pipefail\n${script}\n`, encoding: "utf8",
  });
  const value = { ok: result.status === 0, out: (result.stdout ?? "").trim(), err: (result.stderr ?? "").trim() };
  if (!value.ok && !allowFail) throw new Error(`in ${VM}: ${(value.err || value.out || result.error?.message || "command failed").slice(0, 500)}`);
  return value;
}

export function loadRegistry() { return existsSync(REGISTRY) ? JSON.parse(readFileSync(REGISTRY, "utf8")) : {}; }
export function saveRegistry(registry) {
  mkdirSync(dirname(REGISTRY), { recursive: true });
  writeFileSync(REGISTRY, JSON.stringify(registry, null, 2) + "\n");
}

export function ensureProject(arg) {
  const registry = loadRegistry();
  let name = arg;
  let source = registry[arg] && (registry[arg].source ?? registry[arg].url ?? registry[arg].path);
  if (!source) {
    if (isGitUrl(arg)) { name = basename(arg).replace(/\.git$/, ""); source = arg; }
    else if (existsSync(resolve(arg))) { name = basename(resolve(arg)); source = resolve(arg); }
    else throw new Error(`unknown project "${arg}" (not in ${REGISTRY}, not a host path or git URL)`);
    registry[name] = { source };
    saveRegistry(registry);
  }
  const vmPath = `/home/hexes/hex-projects/${name}`;
  if (!vm(`test -d ${quote(vmPath + "/.git")}`, { allowFail: true }).ok) {
    if (isGitUrl(source)) {
      vm(`git clone -q ${quote(source)} ${quote(vmPath)}`);
    } else {
      if (!existsSync(source)) throw new Error(`project ${name}: host path missing: ${source}`);
      vm(`mkdir -p ${quote(vmPath)}`);
      const copy = spawnSync("bash", ["-c", `set -o pipefail; tar -C ${quote(source)} -cf - . | sg incus-admin -c "incus exec ${VM} -T -- runuser -u hexes -- tar -xf - -C ${vmPath}"`], { encoding: "utf8" });
      if (copy.status !== 0) throw new Error(`copy ${source} into ${VM}: ${(copy.stderr ?? copy.error?.message ?? "failed").slice(0, 400)}`);
      vm(`cd ${quote(vmPath)}; if [ ! -d .git ]; then git init -q && git add -A && git commit -qm 'hex: initial'; else git worktree prune; fi`);
    }
  }
  vm(`cd ${quote(vmPath)}; git -c core.hooksPath=/dev/null update-index -q --refresh || true`);
  return { name, vmPath };
}

function ownerToken() {
  if (process.env.HEX_TOKEN) return process.env.HEX_TOKEN;
  if (process.env.HEX_TOKEN_FILE) {
    const contents = readFileSync(process.env.HEX_TOKEN_FILE, "utf8").trim();
    if (!contents.startsWith("{")) return contents;
    const stored = JSON.parse(contents);
    return stored.token ?? stored.ownerToken;
  }
  return JSON.parse(vm(`cat ${CONFIG}`).out).ownerToken;
}

export class HexesClient {
  #token;
  constructor({ baseUrl = process.env.HEX_URL ?? "http://100.109.83.57:8787", token, publicUrl = PUBLIC_URL } = {}) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.publicUrl = publicUrl.replace(/\/$/, "");
    this.#token = token;
  }
  url(id) { return `${this.publicUrl}/#/c/${encodeURIComponent(id)}`; }
  loginUrl() { return `${this.publicUrl}/login?token=${encodeURIComponent(this.#auth())}&next=/`; }
  #auth() { return this.#token ??= ownerToken(); }
  async request(path, { method = "GET", body, signal } = {}) {
    const response = await fetch(this.baseUrl + path, {
      method, signal,
      headers: { cookie: `pocket_auth=${encodeURIComponent(this.#auth())}`, ...(method === "GET" ? {} : { "content-type": "application/json", "x-pocket": "1" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    let data;
    try { data = JSON.parse(text); } catch { data = text; }
    if (!response.ok) {
      const error = new Error(`${method} ${path} → ${response.status}: ${String(data?.error ?? text).slice(0, 300)}`);
      error.status = response.status;
      throw error;
    }
    return data;
  }
  async list({ signal } = {}) { return (await this.request("/api/sessions", { signal })).filter(s => !s.archived); }
  async status(id, options) {
    const session = (await this.list(options)).find(s => String(s.id) === String(id));
    if (!session) throw new Error(`no hex ${id}`);
    return session;
  }
  async start({ project, cwd, prompt, title, requestId = randomUUID(), signal }) {
    const place = project ? ensureProject(project) : { vmPath: cwd };
    if (!place.vmPath) throw new Error("Name a project or VM working directory");
    const created = await this.request("/api/sessions", { method: "POST", body: { cwd: place.vmPath, title: title ?? prompt?.slice(0, 60), worktree: true }, signal });
    const meta = await this.status(created.id, { signal });
    if (!meta.worktree?.path || meta.worktree.path === place.vmPath) throw new Error(`hex ${created.id} did not get its own worktree`);
    if (prompt) await this.send(created.id, prompt, { requestId, signal });
    return { id: created.id, project: place.name, cwd: meta.worktree.path, url: this.url(created.id) };
  }
  send(id, text, { requestId = randomUUID(), signal } = {}) { return this.request(`/api/c/${id}/submit`, { method: "POST", body: { text, requestId }, signal }); }
  history(id, { before, signal } = {}) { return this.request(`/api/c/${id}/history${before === undefined ? "" : `?before=${encodeURIComponent(before)}`}`, { signal }); }
  diff(id, options) { return this.request(`/api/c/${id}/changes`, options); }
  stop(id, { signal } = {}) { return this.request(`/api/c/${id}/abort`, { method: "POST", body: {}, signal }); }
  environment(id, options) { return this.request(`/api/c/${id}/environment`, options); }
  suspend(id, { signal } = {}) { return this.request(`/api/c/${id}/environment`, { method: "POST", body: { action: "suspend" }, signal }); }
  wake(id, { signal } = {}) { return this.request(`/api/c/${id}/environment`, { method: "POST", body: { action: "wake" }, signal }); }
  fork(id, { entryId, environment = true, signal } = {}) { return this.request(`/api/c/${id}/fork`, { method: "POST", body: { entryId, worktree: true, environment }, signal }); }
  async remove(id, { force = false, signal } = {}) {
    await this.request(`/api/c/${id}/worktree`, { method: "POST", body: { remove: true, force }, signal });
    return this.request(`/api/sessions/${id}`, { method: "POST", body: { archived: true }, signal });
  }
  async wait(id, { signal, onUpdate } = {}) {
    for (;;) {
      signal?.throwIfAborted();
      const session = await this.status(id, { signal });
      onUpdate?.(session);
      if (!session.busy || session.waiting) return { session, history: await this.history(id, { signal }) };
      await sleep(1000, undefined, { signal });
    }
  }
  // Reattachment sends server snapshots, not an offset-based event log. Consumers reconcile entry IDs.
  async *events(id, { signal, reconnect = true, tab = randomUUID() } = {}) {
    do {
      signal?.throwIfAborted();
      let reader;
      try {
        const query = new URLSearchParams({ tab, ...(id === undefined ? {} : { c: String(id) }) });
        const response = await fetch(`${this.baseUrl}/api/events?${query}`, { signal, headers: { cookie: `pocket_auth=${encodeURIComponent(this.#auth())}` } });
        if (!response.ok) { const error = new Error(`events → ${response.status}`); error.status = response.status; throw error; }
        reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "", event = "message", data = [];
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) break;
          buffer += decoder.decode(chunk.value, { stream: true });
          let newline;
          while ((newline = buffer.indexOf("\n")) !== -1) {
            const line = buffer.slice(0, newline).replace(/\r$/, "");
            buffer = buffer.slice(newline + 1);
            if (line === "") {
              if (data.length) yield { event, data: JSON.parse(data.join("\n")) };
              event = "message"; data = [];
            } else if (line.startsWith("event:")) event = line.slice(6).trimStart();
            else if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
          }
        }
      } catch (error) {
        if (signal?.aborted || !reconnect || error.status) throw error;
      } finally {
        await reader?.cancel().catch(() => {});
      }
      if (reconnect) await sleep(1500, undefined, { signal });
    } while (reconnect);
  }
}

export function createClient(options) { return new HexesClient(options); }
