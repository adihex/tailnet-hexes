#!/usr/bin/env bun
import { createInterface } from "node:readline";
import { connect, ui, type Session } from "@stencil-hq/tern";
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

export async function runAttach(idArg: string | number, options: { client?: HexesClient } = {}) {
  const id = Number(idArg);
  if (!Number.isInteger(id)) {
    console.error("hex attach: please provide a numeric session ID");
    process.exit(1);
  }

  const client = options.client ?? createClient();
  const sessionMeta = (await client.status(id)) as HexSessionState;
  const initialHistory = (await client.history(id)) as TranscriptEntry[];

  // One persistent Tern session owns stdin for the whole run. Every card
  // renders through it, and in Tern mode line input is read from its key
  // stream — never through a second stdin reader. Outside Tern (null) the
  // plain-terminal readline path below is used instead.
  const ternSession = await connect({ app: "hex-attach", version: "0.2.0" }).catch(() => null);

  // Serialize card renders: the live-event loop and command responses share
  // this, so two flow surfaces never interleave on one session.
  let renderTail = Promise.resolve();
  function renderCard(head: string, body: string, status?: "working" | "done" | "warn" | "fail") {
    renderTail = renderTail.then(async () => {
      if (ternSession) {
        const surface = ternSession.open({ mode: "flow", listen: false });
        try {
          surface.render(ui.card({ head, status }, ui.md(body || "(empty)")));
        } finally {
          await surface.close({ keep: true });
        }
      } else {
        const bar = status === "fail" ? "\x1b[31m[FAILED]\x1b[0m" : status === "working" ? "\x1b[33m[BUSY]\x1b[0m" : "\x1b[32m[HEX]\x1b[0m";
        console.log("\n" + bar + " \x1b[1m" + head + "\x1b[0m\n" + body + "\n");
      }
    });
    return renderTail;
  }

  await renderCard(
    `Attached: Hex #${id} (${sessionMeta.title ?? "Hex"})`,
    `Worktree: ${sessionMeta.worktree?.path ?? sessionMeta.cwd ?? "none"}\nWeb UI: ${client.url(id)}\nType prompts to steer, or commands: /status, /diff, /suspend, /wake, /fork, /stop, /quit`,
    sessionMeta.busy ? "working" : "done"
  );

  const seenEntries = new Set<number>();
  for (const entry of initialHistory.slice(-10)) {
    seenEntries.add(entry.id);
    const text = entry.text || (entry.blocks?.length ? entry.blocks.map((b) => b.text ?? b.code ?? "").filter(Boolean).join("\n") : "");
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
            const text = item.text || (item.blocks?.length ? item.blocks.map((b) => b.text ?? b.code ?? "").filter(Boolean).join("\n") : "");
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

  async function handleLine(trimmed: string): Promise<"quit" | void> {
    if (!trimmed) return;
    if (trimmed === "/quit" || trimmed === "/exit" || trimmed === "/q") {
      return "quit";
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
  }

  if (ternSession) {
    await ternInputLoop(ternSession, handleLine, id);
  } else {
    const rl = createInterface({
      input: process.stdin,
      output: process.stdout,
      prompt: `hex #${id}> `,
    });

    rl.prompt();

    for await (const line of rl) {
      const result = await handleLine(line.trim());
      if (result === "quit") break;
      try { rl.prompt(); } catch {}
    }

    try { rl.close(); } catch {}
  }

  abortController.abort();
  if (ternSession) {
    try { await ternSession.close(); } catch {}
  }
  console.log(`\nDetached from Hex #${id}. The remote session continues running.`);
}

/**
 * Line input from the persistent Tern session's key stream. The session owns
 * stdin (raw mode); readline must stay out while it lives, or protocol bytes
 * leak into the prompt and input stalls after a live card renders.
 */
async function ternInputLoop(
  session: Session,
  onLine: (trimmed: string) => Promise<"quit" | void>,
  id: number
) {
  const prompt = `hex #${id}> `;
  const out = process.stdout;
  let buffer = "";
  out.write(prompt);
  for await (const input of session) {
    if (input.type !== "key") continue;
    const key = input.key;
    if (key.ctrl && (key.name === "c" || key.name === "d")) {
      out.write("\r\n");
      return;
    }
    if (key.name === "enter") {
      out.write("\r\n");
      const line = buffer;
      buffer = "";
      const result = await onLine(line.trim());
      if (result === "quit") return;
      out.write(prompt);
      continue;
    }
    if (key.name === "backspace") {
      if (buffer.length > 0) {
        buffer = buffer.slice(0, -1);
        out.write("\r\x1b[K" + prompt + buffer);
      }
      continue;
    }
    const text = key.text ?? (key.name === "space" ? " " : undefined);
    if (text) {
      buffer += text;
      out.write(text);
    }
    // Other keys (arrows, function keys, modifiers alone) carry no text: ignore.
  }
}

if (import.meta.main) {
  const targetId = process.argv[2];
  if (!targetId) {
    console.error("Usage: bun hex-attach.tsx <id>");
    process.exit(1);
  }
  await runAttach(targetId);
}
