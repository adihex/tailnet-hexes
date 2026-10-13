import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { createClient, type HexesClient } from "./hex-client.mjs";

const STATE_ENTRY = "hexes.session.association";

interface SessionSummary {
  id: number;
  busy?: boolean;
  waiting?: boolean;
  title?: string;
  cwd?: string;
  worktree?: { path?: string; branch?: string };
}

interface ExtensionSessionContext {
  ui?: {
    setStatus: (id: string, text: string | undefined) => void;
    notify: (message: string, tone?: "info" | "warning" | "error") => void;
  };
  sessionManager?: {
    getBranch: () => Array<{
      type?: string;
      customType?: string;
      data?: { hexId?: number };
    }>;
  };
}

export default function (pi: ExtensionAPI) {
  const client: HexesClient = createClient();
  let activeHexId: number | undefined;

  function reconstruct(ctx: ExtensionSessionContext | undefined) {
    if (!ctx?.sessionManager?.getBranch) return;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry?.type === "custom" && entry?.customType === STATE_ENTRY && typeof entry?.data?.hexId === "number") {
        activeHexId = entry.data.hexId;
      }
    }
  }

  pi.on("session_start", (_event, ctx) => {
    const sessionCtx = ctx as ExtensionSessionContext;
    reconstruct(sessionCtx);
    if (activeHexId) sessionCtx.ui?.setStatus("hexes", `Hex #${activeHexId}`);
  });
  pi.on("session_switch", (_event, ctx) => {
    const sessionCtx = ctx as ExtensionSessionContext;
    activeHexId = undefined;
    sessionCtx.ui?.setStatus("hexes", undefined);
  });
  pi.on("session_branch", (_event, ctx) => reconstruct(ctx as ExtensionSessionContext));
  pi.on("session_tree", (_event, ctx) => reconstruct(ctx as ExtensionSessionContext));

  pi.registerTool({
    name: "hex_list",
    label: "Hexes List",
    description: "List running and sleeping Hexes (durable remote agent sessions)",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    async execute() {
      const sessions = (await client.list()) as SessionSummary[];
      return {
        content: [{ type: "text", text: JSON.stringify(sessions, null, 2) }],
        details: { count: sessions.length, sessions },
      };
    },
  });

  pi.registerTool({
    name: "hex_status",
    label: "Hex Status",
    description: "Get detailed status of a Hex, including its container environment and worktree",
    parameters: {
      type: "object",
      properties: { id: { type: "integer", description: "Hex session ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number }) {
      const session = await client.status(params.id);
      const env = await client.environment(params.id).catch(() => null);
      return {
        content: [{ type: "text", text: JSON.stringify({ session, environment: env }, null, 2) }],
        details: { session, environment: env },
      };
    },
  });

  pi.registerTool({
    name: "hex_start",
    label: "Hex Start",
    description: "Start a fresh durable Hex agent in an isolated container worktree",
    parameters: {
      type: "object",
      properties: {
        project: { type: "string", description: "Registered project name or path" },
        prompt: { type: "string", description: "Initial task prompt" },
        title: { type: "string", description: "Optional session title" },
      },
      required: ["project"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { project: string; prompt?: string; title?: string }, _signal, _onUpdate, ctx) {
      const result = await client.start({
        project: params.project,
        prompt: params.prompt,
        title: params.title,
      });
      activeHexId = result.id;
      pi.appendEntry(STATE_ENTRY, { hexId: result.id, createdAt: Date.now() });
      (ctx as ExtensionSessionContext)?.ui?.setStatus("hexes", `Hex #${result.id}`);
      return {
        content: [{ type: "text", text: `Started Hex #${result.id} in ${result.cwd}\nURL: ${result.url}` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "hex_send",
    label: "Hex Send",
    description: "Send a follow-up prompt or steering command to a Hex",
    parameters: {
      type: "object",
      properties: {
        id: { type: "integer", description: "Hex session ID" },
        prompt: { type: "string", description: "Prompt or steering text" },
      },
      required: ["id", "prompt"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number; prompt: string }) {
      const result = await client.send(params.id, params.prompt);
      return {
        content: [{ type: "text", text: `Sent to Hex #${params.id}: "${params.prompt}"` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "hex_wait",
    label: "Hex Wait",
    description: "Wait for a Hex to finish its current turn or pause for input",
    parameters: {
      type: "object",
      properties: { id: { type: "integer", description: "Hex session ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number }, signal, onUpdate) {
      const { session, history } = await client.wait(params.id, {
        signal,
        onUpdate: (s) => onUpdate?.({ content: [{ type: "text", text: `Hex #${params.id} is ${s.busy ? "working" : "sleeping"}...` }] }),
      });
      const last = history[history.length - 1];
      const summary = `Hex #${params.id} is now ${session.busy ? "working" : session.waiting ? "waiting for input" : "sleeping"}.`;
      return {
        content: [{ type: "text", text: `${summary}\nLast entry: ${JSON.stringify(last ?? {})}` }],
        details: { session, lastEntry: last },
      };
    },
  });

  pi.registerTool({
    name: "hex_diff",
    label: "Hex Diff",
    description: "Get uncommitted changes made by a Hex in its worktree",
    parameters: {
      type: "object",
      properties: { id: { type: "integer", description: "Hex session ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number }) {
      const changes = await client.diff(params.id);
      return {
        content: [{ type: "text", text: typeof changes === "string" ? changes : JSON.stringify(changes, null, 2) }],
        details: { changes },
      };
    },
  });

  pi.registerTool({
    name: "hex_history",
    label: "Hex History",
    description: "Get conversation history of a Hex",
    parameters: {
      type: "object",
      properties: {
        id: { type: "integer", description: "Hex session ID" },
        before: { type: "integer", description: "Optional upper bound entry ID" },
      },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number; before?: number }) {
      const history = await client.history(params.id, { before: params.before });
      return {
        content: [{ type: "text", text: JSON.stringify(history, null, 2) }],
        details: { count: history.length, history },
      };
    },
  });

  pi.registerTool({
    name: "hex_stop",
    label: "Hex Stop",
    description: "Abort the running turn of a Hex (session sleeps, transcript kept)",
    parameters: {
      type: "object",
      properties: { id: { type: "integer", description: "Hex session ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number }) {
      const result = await client.stop(params.id);
      return {
        content: [{ type: "text", text: `Hex #${params.id} stopped.` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "hex_suspend",
    label: "Hex Suspend",
    description: "Suspend (pause) an idle Hex container to release CPU and memory",
    parameters: {
      type: "object",
      properties: { id: { type: "integer", description: "Hex session ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number }) {
      const result = await client.suspend(params.id);
      return {
        content: [{ type: "text", text: `Hex #${params.id} container suspended.` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "hex_wake",
    label: "Hex Wake",
    description: "Wake (unpause) a suspended Hex container",
    parameters: {
      type: "object",
      properties: { id: { type: "integer", description: "Hex session ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number }) {
      const result = await client.wake(params.id);
      return {
        content: [{ type: "text", text: `Hex #${params.id} container awake.` }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "hex_fork",
    label: "Hex Fork",
    description: "Fork a Hex session and optionally clone its container environment",
    parameters: {
      type: "object",
      properties: {
        id: { type: "integer", description: "Source Hex session ID" },
        entryId: { type: "integer", description: "Optional assistant reply entry ID to fork at (defaults to latest finished reply)" },
        environment: { type: "boolean", description: "Whether to clone container rootfs environment (default true)" },
      },
      required: ["id"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params: { id: number; entryId?: number; environment?: boolean }) {
      const result = await client.fork(params.id, {
        entryId: params.entryId,
        environment: params.environment ?? true,
      });
      return {
        content: [{ type: "text", text: `Forked Hex #${params.id} into new Hex #${result.id}` }],
        details: result,
      };
    },
  });

  pi.registerCommand("hex", {
    description: "Manage Tailnet Hexes (list, status, attach)",
    async handler(args: string, ctx) {
      const sessionCtx = ctx as ExtensionSessionContext;
      const parts = args.trim().split(/\s+/).filter(Boolean);
      const sub = parts[0];
      if (!sub || sub === "list") {
        const sessions = (await client.list()) as SessionSummary[];
        const text = sessions.map((s) => `#${s.id}\t${s.busy ? "working" : "sleeping"}\t${s.title}\t${s.cwd}`).join("\n");
        sessionCtx.ui?.notify(text || "No active hexes", "info");
        return;
      }
      if (sub === "attach" && parts[1]) {
        activeHexId = Number(parts[1]);
        pi.appendEntry(STATE_ENTRY, { hexId: activeHexId, attachedAt: Date.now() });
        sessionCtx.ui?.setStatus("hexes", `Hex #${activeHexId}`);
        sessionCtx.ui?.notify(`Attached to Hex #${activeHexId}: ${client.url(activeHexId)}`, "info");
        return;
      }
      sessionCtx.ui?.notify("Usage: /hex [list | attach <id>]", "warning");
    },
  });
}
