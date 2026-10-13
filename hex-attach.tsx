#!/usr/bin/env bun
import { createInterface } from "node:readline";
import { connect, print, ui } from "@stencil-hq/tern";
import { createClient, type HexesClient } from "./hex-client.mjs";

interface TranscriptEntry {
  id: number;
  kind?: string;
  text?: string;
  role?: string;
  stopReason?: string;
  name?: string;
  blocks?: Array<{ type?: string; text?: string; code?: string }>;
  isError?: boolean;
}

interface HexSessionState {
  id: number;
  title?: string;
  busy?: boolean;
  waiting?: boolean;
  cwd?: string;
  worktree?: { path?: string; branch?: string };
}

function entryText(entry: TranscriptEntry): string {
  if (entry.text) return entry.text;
  if (entry.blocks?.length) {
    return entry.blocks.map((b) => b.text ?? b.code ?? "").filter(Boolean).join("\n");
  }
  return "";
}

export async function runAttach(idArg: string | number, options: { client?: HexesClient } = {}) {
  const id = Number(idArg);
  if (!Number.isInteger(id)) {
    console.error("hex attach: please provide a numeric session ID");
    process.exit(1);
  }

  const client = options.client ?? createClient();
  const sessionMeta = (await client.status(id)) as HexSessionState;
  const initialHistory = (await client.history(id)) as TranscriptEntry[];

  const ternSession = await connect({ app: "hex-attach", version: "0.1.0" }).catch(() => null);
  const isTern = ternSession !== null;

  async function renderCard(head: string, body: string, status?: "working" | "done" | "warn" | "fail") {
    if (isTern) {
      await print(
        ui.card(
          { head, status },
          ui.md(body || "(empty)")
        )
      );
    } else {
      const bar = status === "fail" ? "\x1b[31m[FAILED]\x1b[0m" : status === "working" ? "\x1b[33m[BUSY]\x1b[0m" : "\x1b[32m[HEX]\x1b[0m";
      console.log(`\n${bar} \x1b[1m${head}\x1b[0m\n${body}\n`);
    }
  }

  await renderCard(
    `Attached: Hex #${id} (${sessionMeta.title ?? "Hex"})`,
    `Worktree: ${sessionMeta.worktree?.path ?? sessionMeta.cwd ?? "none"}\nWeb UI: ${client.url(id)}\nType prompts to steer, or commands: /status, /diff, /suspend, /wake, /fork, /stop, /quit`,
    sessionMeta.busy ? "working" : "done"
  );

  const seenEntries = new Set<number>();
  for (const entry of initialHistory.slice(-10)) {
    seenEntries.add(entry.id);
    const text = entryText(entry);
    if (!text) continue;
    const author = entry.kind === "assistant" ? "Agent" : entry.kind === "user" ? "User" : entry.kind ?? "Message";
    await renderCard(`${author} (#${entry.id})`, text, entry.isError ? "fail" : "done");
  }

  const abortController = new AbortController();

  (async () => {
    try {
      for await (const message of client.events(id, { signal: abortController.signal, reconnect: true })) {
        if (message.event === "chat" && message.data && typeof message.data === "object") {
          const payload = message.data as { messages?: TranscriptEntry[]; entry?: TranscriptEntry };
          const list = payload.messages ?? (payload.entry ? [payload.entry] : []);
          for (const item of list) {
            if (!item?.id || seenEntries.has(item.id)) continue;
            seenEntries.add(item.id);
            const text = entryText(item);
            if (!text) continue;
            const author = item.kind === "assistant" ? "Agent" : item.kind === "user" ? "User" : item.kind ?? "Message";
            await renderCard(`${author} (#${item.id})`, text, item.isError ? "fail" : "done");
          }
        }
      }
    } catch {
      // Aborted or disconnected
    }
  })();

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: `hex #${id}> `,
  });

  rl.prompt();

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) {
      rl.prompt();
      continue;
    }

    if (trimmed === "/quit" || trimmed === "/exit" || trimmed === "/q") {
      break;
    } else if (trimmed === "/status") {
      const current = (await client.status(id)) as HexSessionState;
      const env = (await client.environment(id).catch(() => null)) as { container?: string; status?: string; busy?: boolean } | null;
      console.log(`Hex #${id}: ${current.busy ? "working" : current.waiting ? "waiting for input" : "sleeping"}`);
      console.log(`Container: ${env?.container ?? "none"} (${env?.status ?? "unknown"})`);
      console.log(`Worktree: ${current.worktree?.path ?? current.cwd}`);
    } else if (trimmed === "/diff") {
      const diff = await client.diff(id);
      console.log(typeof diff === "string" ? diff : JSON.stringify(diff, null, 2));
    } else if (trimmed === "/stop") {
      await client.stop(id);
      console.log(`Stopped Hex #${id} turn.`);
    } else if (trimmed === "/suspend") {
      await client.suspend(id);
      console.log(`Hex #${id} container suspended.`);
    } else if (trimmed === "/wake") {
      await client.wake(id);
      console.log(`Hex #${id} container awake.`);
    } else if (trimmed.startsWith("/fork")) {
      const parts = trimmed.split(/\s+/);
      const entryId = parts[1] ? Number(parts[1]) : undefined;
      const res = await client.fork(id, { entryId });
      console.log(`Forked into Hex #${res.id}: ${client.url(res.id)}`);
    } else {
      await client.send(id, trimmed);
      console.log(`Sent prompt to Hex #${id}...`);
    }
    try { rl.prompt(); } catch {}
  }

  abortController.abort();
  try { rl.close(); } catch {}
  console.log(`\nDetached from Hex #${id}. The remote session continues running.`);
}

if (import.meta.main) {
  const targetId = process.argv[2];
  if (!targetId) {
    console.error("Usage: bun hex-attach.tsx <id>");
    process.exit(1);
  }
  await runAttach(targetId);
}
