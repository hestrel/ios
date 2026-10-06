#!/usr/bin/env node
// Hestrel's bridge to the coding agents on this computer, for the app's Code tab.
//
// One minimal MCP server (Streamable HTTP, no dependencies) offering every agent installed here:
//
//   - Codex: `codex` and `codex-reply` tools backed by one long-lived `codex app-server`, the protocol
//     the Codex app uses. Sessions are ordinary Codex threads: they appear in the Codex app and resume
//     from disk. Progress streams as `codex/event` notifications, as `codex mcp-server` sends them.
//   - Claude Code: a `claude_code` tool that runs `claude -p` per prompt and streams its events as
//     `claude/event` notifications. Claude Code saves sessions on disk, so they resume by
//     `session_id` even after this bridge restarts.
//   - Any other harness (OpenCode, pi, Gemini CLI, Goose, Qwen Code, Hermes, or ACP agents listed in
//     ~/.hestrel/agents.json): one `agent_run` tool, reporting `hestrel/event` notifications.
//
// Turns don't depend on the connection that started them: if the phone sleeps or loses signal, the agent keeps
// working, and the app reconnects with `Last-Event-ID` to collect the rest (MCP's resumable streams). Only an
// explicit `notifications/cancelled` (Stop) ends a turn early.
//
// The first run shows a QR code. Scan it with Hestrel (or the iPhone Camera) to pair this computer with
// your Hestrel account; every device signed in to the account can then use it, from anywhere. The bridge
// connects out to Hestrel's relay, so nothing on this computer is exposed to the network.
//
//   cd ~/dev && node /path/to/hestrel-ios/Tools/hestrel-bridge.mjs
//   node hestrel-bridge.mjs --pair        # show a new QR code, e.g. to move to another account
//
// Environment:
//   PORT                     Local port (default 8933).
//   HOST                     Address to bind (default 127.0.0.1). 0.0.0.0 also serves the local network
//                            directly at http://<computer>:8933/mcp, without the relay.
//   HESTREL_BRIDGE_TOKEN     If set, direct requests need `Authorization: Bearer <token>`.
//   HESTREL_API              Hestrel's API (default https://hestrel-api.hestrel-cloud.workers.dev).
//   HESTREL_RELAY=off        Don't pair or connect to Hestrel; local network only.
//   HESTREL_BRIDGE_CONFIG    Where this computer's Hestrel identity is kept (default ~/.hestrel/bridge.json).
//   CLAUDE_PERMISSION_MODE   Claude Code's permission mode (default acceptEdits, with sandboxed Bash).
//   CLAUDE_BIN, CODEX_BIN    The agents' executables (default `claude` and `codex`).

import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, constants, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";

const port = Number(process.env.PORT ?? 8933);
const host = process.env.HOST ?? "127.0.0.1";
const token = process.env.HESTREL_BRIDGE_TOKEN;
const permissionMode = process.env.CLAUDE_PERMISSION_MODE ?? "acceptEdits";
const claudeBin = process.env.CLAUDE_BIN ?? "claude";
const codexBin = process.env.CODEX_BIN ?? "codex";
const protocolVersion = "2025-06-18";

// The agents run as the user would run them. When the bridge itself is started from inside a Claude Code
// session, that session's own variables would otherwise make them its children; account settings such as
// CLAUDE_CONFIG_DIR are kept.
const agentEnv = Object.fromEntries(Object.entries(process.env).filter(([name]) =>
  !["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"].includes(name)
  && !/^CLAUDE_CODE_(ENTRYPOINT|SESSION|CHILD_SESSION|MESSAGING|BRIDGE|EXECPATH)/.test(name)));

/** Turns in progress by `<mcp session>:<request id>`, for `notifications/cancelled`. */
const running = new Map();

createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname !== "/mcp") return reply(res, 404, { error: "Not found" });
  if (token && req.headers.authorization !== `Bearer ${token}`) return reply(res, 401, { error: "Unauthorized" });
  // Picking a turn's stream back up after the connection dropped (MCP's resumable streams).
  if (req.method === "GET") {
    const lastEventID = String(req.headers["last-event-id"] ?? "");
    const split = lastEventID.lastIndexOf(":");
    const turn = turns.get(lastEventID.slice(0, split));
    if (split < 0) return reply(res, 405, { error: "Method not allowed" });
    if (!turn) return reply(res, 404, { error: "Unknown stream" });
    return turn.attach(res, Number(lastEventID.slice(split + 1)));
  }
  if (req.method !== "POST") return reply(res, 405, { error: "Method not allowed" });

  let message;
  try {
    message = JSON.parse(await body(req));
  } catch {
    return reply(res, 400, rpcError(null, -32700, "Parse error"));
  }
  const session = req.headers["mcp-session-id"] ?? "";

  // Notifications get no response body.
  if (message.id === undefined || message.id === null) {
    if (message.method === "notifications/cancelled") {
      // The request ID, or the stream ID when a relaunched app stops a turn it reattached to.
      const requestId = message.params?.requestId;
      (running.get(`${session}:${requestId}`) ?? turns.get(String(requestId)))?.stop();
    }
    res.writeHead(202).end();
    return;
  }

  switch (message.method) {
    case "initialize":
      res.setHeader("Mcp-Session-Id", randomUUID());
      return reply(res, 200, rpcResult(message.id, {
        protocolVersion: message.params?.protocolVersion ?? protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "hestrel-bridge", version: "1.0.0" },
      }));
    case "ping":
      return reply(res, 200, rpcResult(message.id, {}));
    case "tools/list":
      return reply(res, 200, rpcResult(message.id, { tools: await tools() }));
    case "tools/call": {
      const { name, arguments: args = {} } = message.params ?? {};
      const key = `${session}:${message.id}`;
      if (name === claudeTool.name && (await claudeAvailable)) return runClaude(message.id, args, key, res);
      if (name === "agent_run" && harnesses.length) return runHarness(message.id, args, key, res);
      if (name === "agent_models" && harnesses.length) return harnessModels(message.id, args, res);
      if (codexTools.some((tool) => tool.name === name) && (await codexAvailable)) return runCodex(message.id, message.params, key, res);
      return reply(res, 200, rpcError(message.id, -32602, `Unknown tool: ${name}`));
    }
    default:
      return reply(res, 200, rpcError(message.id, -32601, `Method not found: ${message.method}`));
  }
}).listen(port, host, async () => {
  const agents = (await agentIDs()).map((id) => ({ codex: "Codex", claudeCode: "Claude Code" })[id] ?? harnesses.find((harness) => harness.id === id)?.title);
  console.log(agents.length ? `Agents: ${agents.join(", ")}. Default folder: ${process.cwd()}` : "No agents found: install Codex or Claude Code.");
  if (host !== "127.0.0.1" && host !== "localhost") {
    console.log(`Also serving the local network at http://${host}:${port}/mcp${token ? " (token required)" : ""}.`);
    if (!token) console.log("Anyone on the network can run code here. Set HESTREL_BRIDGE_TOKEN to require a token.");
  }
  if (process.env.HESTREL_RELAY !== "off") connectToHestrel();
});

async function agentIDs() {
  return [(await codexAvailable) ? "codex" : null, (await claudeAvailable) ? "claudeCode" : null, ...harnesses.map((harness) => harness.id)].filter(Boolean);
}

// MARK: Hestrel account and relay

const api = (process.env.HESTREL_API ?? "https://hestrel-api.hestrel-cloud.workers.dev").replace(/\/$/, "");
const configPath = process.env.HESTREL_BRIDGE_CONFIG ?? join(homedir(), ".hestrel", "bridge.json");

/** Pairs this computer if needed, then keeps the relay connection up for as long as the bridge runs. */
async function connectToHestrel() {
  let computer = loadComputer();
  let forcePairing = process.argv.includes("--pair");
  let delay = 1_000;
  for (;;) {
    try {
      if (!computer) computer = await registerComputer();
      const details = { name: computerName(), agents: await agentIDs() };
      await hestrel(computer, "PUT", "/v1/computers/self", details);
      const self = await hestrel(computer, "GET", "/v1/computers/self");
      if (!self.paired || forcePairing) {
        await pair(computer);
        forcePairing = false;
      }
      const closed = await relay(computer, () => { delay = 1_000; });
      if (closed.code === 4000) {
        console.log("Another bridge connected as this computer, so this one stopped relaying. Quit the other one, then restart this.");
        return;
      }
      if (closed.code === 4001) console.log("This computer was removed from your Hestrel account.");
    } catch (error) {
      if (error.status === 401) {
        // Removed from the account, or the server forgot it: start over with a new identity.
        rmSync(configPath, { force: true });
        computer = null;
        continue;
      }
      console.log(`Can't reach Hestrel (${error.message}). Retrying…`);
    }
    await sleep(delay);
    delay = Math.min(delay * 2, 30_000);
  }
}

async function registerComputer() {
  const response = await hestrel(null, "POST", "/v1/computers", { name: computerName(), agents: await agentIDs() });
  const computer = { api, id: response.id, secret: response.secret, pairing: response };
  mkdirSync(dirname(configPath), { recursive: true });
  writeFileSync(configPath, JSON.stringify({ api, id: computer.id, secret: computer.secret }, null, 2), { mode: 0o600 });
  return computer;
}

function loadComputer() {
  try {
    const saved = JSON.parse(readFileSync(configPath, "utf8"));
    return saved.api === api && saved.id && saved.secret ? saved : null;
  } catch {
    return null;
  }
}

/** Shows a pairing QR code until a signed-in Hestrel app claims it, renewing it as it expires. */
async function pair(computer) {
  let pairing = computer.pairing ?? (await hestrel(computer, "POST", "/v1/computers/self/pairing"));
  computer.pairing = null;
  for (;;) {
    const code = pairing.pairingCode;
    console.log(`\nPair this computer: scan the code with Hestrel (Code → Pair a Computer) or the iPhone Camera.\n`);
    console.log(qrTerminal(`hestrel://pair?code=${code}`));
    console.log(`\nOr enter ${code.slice(0, 4)}-${code.slice(4)} in Hestrel. The code expires in 10 minutes.\n`);
    while (Date.now() < pairing.pairingExpiresAt) {
      await sleep(2_000);
      const self = await hestrel(computer, "GET", "/v1/computers/self");
      // Already-paired computers showing a new code (--pair) wait for that code to be used.
      if (self.paired && !self.pairingPending) {
        console.log(`Paired as “${self.name}”. Your devices signed in to Hestrel can use it now.`);
        return;
      }
    }
    pairing = await hestrel(computer, "POST", "/v1/computers/self/pairing");
  }
}

/**
 * Keeps a WebSocket open to this computer's relay and answers the requests it forwards by passing them to
 * the local MCP server. Resolves when the socket closes.
 */
function relay(computer, onOpen) {
  return new Promise((resolve) => {
    const socket = new WebSocket(`${api.replace(/^http/, "ws")}/v1/computers/self/connect`, {
      headers: { Authorization: `Bearer ${computer.secret}` },
    });
    const requests = new Map();
    let keepAlive;
    const send = (frame) => { if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(frame)); };

    socket.addEventListener("open", () => {
      onOpen();
      console.log("Connected to Hestrel. Open the Code tab on your phone.");
      // Answered by the relay itself without waking it; keeps proxies from closing an idle socket.
      keepAlive = setInterval(() => socket.readyState === WebSocket.OPEN && socket.send("ping"), 25_000);
    });
    socket.addEventListener("message", async (event) => {
      if (event.data === "pong") return;
      let frame;
      try {
        frame = JSON.parse(event.data);
      } catch {
        return;
      }
      if (frame.t === "cancel") return requests.get(frame.id)?.abort();
      if (frame.t !== "request") return;

      const controller = new AbortController();
      requests.set(frame.id, controller);
      let started = false;
      try {
        const response = await fetch(`http://${localHost()}:${port}/mcp`, {
          method: frame.method,
          headers: { ...frame.headers, ...(token ? { authorization: `Bearer ${token}` } : {}) },
          body: frame.method === "GET" || frame.method === "HEAD" ? undefined : frame.body,
          signal: controller.signal,
        });
        const headers = {};
        for (const name of ["content-type", "mcp-session-id"]) {
          const value = response.headers.get(name);
          if (value) headers[name] = value;
        }
        send({ t: "head", id: frame.id, status: response.status, headers });
        started = true;
        const decoder = new TextDecoder();
        for await (const chunk of response.body ?? []) {
          send({ t: "data", id: frame.id, data: decoder.decode(chunk, { stream: true }) });
        }
        send({ t: "end", id: frame.id });
      } catch {
        if (!controller.signal.aborted) {
          if (!started) send({ t: "head", id: frame.id, status: 502, headers: { "content-type": "application/json" } });
          send({ t: "end", id: frame.id });
        }
      } finally {
        requests.delete(frame.id);
      }
    });
    socket.addEventListener("close", (event) => {
      clearInterval(keepAlive);
      for (const controller of requests.values()) controller.abort();
      resolve({ code: event.code });
    });
    socket.addEventListener("error", () => {});
  });
}

/** Where the relay reaches the local MCP server. */
function localHost() {
  return host === "0.0.0.0" || host === "::" || host === "localhost" ? "127.0.0.1" : host;
}

async function hestrel(computer, method, path, payload) {
  const response = await fetch(api + path, {
    method,
    headers: {
      ...(computer ? { Authorization: `Bearer ${computer.secret}` } : {}),
      ...(payload ? { "Content-Type": "application/json" } : {}),
    },
    body: payload ? JSON.stringify(payload) : undefined,
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw Object.assign(new Error(body?.error?.message ?? `HTTP ${response.status}`), { status: response.status });
  }
  return response.status === 204 ? null : response.json();
}

/** The name people know this computer by, e.g. "MacBook Pro". */
function computerName() {
  if (process.platform === "darwin") {
    try {
      return execFileSync("scutil", ["--get", "ComputerName"], { encoding: "utf8" }).trim();
    } catch {}
  }
  return hostname().replace(/\.local$/, "");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function tools() {
  return [...((await codexAvailable) ? codexTools : []), ...((await claudeAvailable) ? [claudeTool] : []), ...harnessTools()];
}

// MARK: Codex

// Codex runs through `codex app-server`, the protocol the Codex app itself uses, so sessions started from
// Hestrel are ordinary Codex threads: they show up in the Codex app and resume from disk. Toward Hestrel,
// the bridge offers the same `codex` and `codex-reply` tools as `codex mcp-server`, with the same events.

const codexTools = [
  {
    name: "codex",
    description: "Starts a Codex session on the user's computer: it reads, edits and runs code in a folder.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "What Codex should do." },
        cwd: { type: "string", description: "Working folder; `~` is expanded. Defaults to where the bridge runs." },
        model: { type: "string", description: "A model slug, e.g. gpt-6-astra." },
        sandbox: { type: "string", enum: ["read-only", "workspace-write", "danger-full-access"] },
        "approval-policy": { type: "string", enum: ["untrusted", "on-failure", "on-request", "never"] },
        config: { type: "object", description: "Codex config overrides, e.g. {\"model_reasoning_effort\": \"high\"}." },
      },
      required: ["prompt"],
    },
  },
  {
    name: "codex-reply",
    description: "Continues a Codex session by its `threadId`.",
    inputSchema: {
      type: "object",
      properties: {
        threadId: { type: "string" },
        prompt: { type: "string" },
      },
      required: ["threadId", "prompt"],
    },
  },
];

let codexServer = null;
/** Threads this app-server has loaded; others are resumed from disk first. */
const loadedThreads = new Set();
/** The turn running on each thread, which receives that thread's notifications. */
const activeTurns = new Map();

const codexAvailable = new Promise((resolve) => {
  const probe = spawn(codexBin, ["--version"], { stdio: "ignore", env: agentEnv });
  probe.on("error", () => resolve(false));
  probe.on("exit", (code) => resolve(code === 0));
});

/** The shared `codex app-server`, started on first use and again if it exits. */
function codex() {
  if (!codexServer) {
    codexServer = new StdioServer(codexBin, ["app-server"], {
      clientInfo: { name: "Hestrel", title: "Hestrel", version: "1.0.0" },
      onNotification: (message) => activeTurns.get(message.params?.threadId)?.(message),
      onExit: () => {
        codexServer = null;
        loadedThreads.clear();
        for (const handle of activeTurns.values()) handle({ method: "bridge/exited" });
      },
    });
  }
  return codexServer;
}

/** Runs one Codex turn, starting or resuming its thread, and streams it as `codex mcp-server` would. */
async function runCodex(id, params, key, res) {
  const args = params.arguments ?? {};
  const turn = new Turn(key);
  turn.attach(res);
  const event = (msg, threadId) => turn.emit({ jsonrpc: "2.0", method: "codex/event", params: { _meta: { threadId }, msg } });
  const finish = (text, isError, threadId) => {
    turn.finish(toolResult(id, text, isError, threadId ? { threadId, content: text } : undefined));
  };

  const server = codex();
  let threadId = args.threadId ?? null;
  try {
    if (params.name === "codex") {
      const cwd = expandHome(args.cwd) ?? process.cwd();
      const result = await server.request("thread/start", {
        cwd,
        model: args.model ?? null,
        sandbox: args.sandbox ?? "workspace-write",
        approvalPolicy: args["approval-policy"] ?? "never",
        config: args.config ?? null,
      });
      threadId = result.thread.id;
      loadedThreads.add(threadId);
      event({ type: "session_configured", thread_id: threadId, model: result.model ?? result.thread.model ?? null }, threadId);
      console.log(`[${new Date().toISOString()}] Codex start in ${cwd}`);
    } else if (!loadedThreads.has(threadId)) {
      try {
        await server.request("thread/resume", { threadId, excludeTurns: true });
      } catch (error) {
        return finish(`Session not found for thread_id: ${threadId} (${error.message})`, true, threadId);
      }
      loadedThreads.add(threadId);
      console.log(`[${new Date().toISOString()}] Codex resume ${threadId}`);
    }
  } catch (error) {
    return finish(`Couldn't start Codex: ${error.message}`, true);
  }

  let turnId = null;
  let answer = "";
  let done = false;
  const complete = (text, isError) => {
    if (done) return;
    done = true;
    activeTurns.delete(threadId);
    finish(text, isError, threadId);
  };

  activeTurns.set(threadId, (message) => {
    const p = message.params ?? {};
    switch (message.method) {
      case "item/agentMessage/delta":
        return event({ type: "agent_message_content_delta", item_id: p.itemId, delta: p.delta }, threadId);
      case "item/reasoning/summaryTextDelta":
      case "item/reasoning/textDelta":
        return event({ type: "agent_reasoning_delta", delta: p.delta }, threadId);
      case "item/started":
      case "item/completed": {
        const msg = codexItemEvent(p.item, message.method === "item/completed");
        if (p.item?.type === "agentMessage" && message.method === "item/completed") answer = p.item.text ?? answer;
        return msg && event(msg, threadId);
      }
      case "error":
        return p.willRetry ? undefined : event({ type: "error", message: p.error?.message ?? "Codex reported an error." }, threadId);
      case "turn/completed": {
        const turn = p.turn ?? {};
        if (turn.status === "failed") return complete(turn.error?.message ?? "Codex couldn't finish.", true);
        if (turn.status === "interrupted") return complete(answer || "Stopped.", false);
        return complete(answer, false);
      }
      case "bridge/exited":
        return complete("Codex exited unexpectedly.", true);
    }
  });

  // Only an explicit Stop ends the turn; a dropped connection just detaches from it.
  turn.stop = () => {
    if (!done && turnId) server.request("turn/interrupt", { threadId, turnId }).catch(() => {});
  };

  try {
    const effort = args.config?.model_reasoning_effort;
    const result = await server.request("turn/start", {
      threadId,
      input: [{ type: "text", text: String(args.prompt ?? "") }],
      ...(effort ? { effort } : {}),
    });
    turnId = result.turn?.id ?? null;
  } catch (error) {
    complete(`Codex couldn't start the turn: ${error.message}`, true);
  }
}

/** A Codex thread item as the `codex/event` Hestrel reads: commands, file changes and finished messages. */
function codexItemEvent(item, completed) {
  switch (item?.type) {
    case "agentMessage":
      return completed ? { type: "item_completed", item: { type: "AgentMessage", id: item.id, content: [{ type: "Text", text: item.text ?? "" }] } } : null;
    case "commandExecution":
      if (!completed) {
        return {
          type: "exec_command_begin",
          call_id: item.id,
          command: ["/bin/zsh", "-lc", shellScript(item.command ?? "")],
          parsed_cmd: (item.commandActions ?? []).map((action) => ({
            type: { listFiles: "list_files", read: "read", search: "search" }[action.type] ?? "unknown",
            cmd: action.command, name: action.name, path: action.path, query: action.query,
          })),
        };
      }
      return { type: "exec_command_end", call_id: item.id, aggregated_output: item.aggregatedOutput ?? "", exit_code: item.exitCode ?? 0 };
    case "fileChange": {
      const changes = Object.fromEntries((item.changes ?? []).map((change) => [
        change.path,
        { type: change.kind?.type ?? "update", unified_diff: change.diff ?? "" },
      ]));
      return completed
        ? { type: "patch_apply_end", call_id: item.id, success: item.status !== "failed", stdout: "", changes }
        : { type: "patch_apply_begin", call_id: item.id, changes };
    }
    default:
      return null;
  }
}

/** The script inside `/bin/zsh -lc <script>`, unquoted the way the shell would read it. */
function shellScript(command) {
  const match = command.match(/^\S+ -l?c (.*)$/s);
  if (!match) return command;
  const quoted = match[1];
  let script = "";
  let i = 0;
  while (i < quoted.length) {
    const char = quoted[i];
    if (char === "'") {
      const end = quoted.indexOf("'", i + 1);
      if (end < 0) return quoted;
      script += quoted.slice(i + 1, end);
      i = end + 1;
    } else if (char === '"') {
      i += 1;
      while (i < quoted.length && quoted[i] !== '"') {
        if (quoted[i] === "\\" && '"\\$`'.includes(quoted[i + 1])) i += 1;
        script += quoted[i];
        i += 1;
      }
      i += 1;
    } else if (char === "\\") {
      script += quoted[i + 1] ?? "";
      i += 2;
    } else if (/\s/.test(char)) {
      return quoted;  // More than one word: not a single quoted script, so show it as is.
    } else {
      script += char;
      i += 1;
    }
  }
  return script;
}

function expandHome(path) {
  return typeof path === "string" && path.trim() ? path.trim().replace(/^~(?=$|\/)/, homedir()) : null;
}

/**
 * A client for a JSON-RPC server spoken to over stdio: Codex's app server, or an ACP agent (which wants
 * `"jsonrpc": "2.0"` on every message and its own handshake).
 */
class StdioServer {
  constructor(command, args, { clientInfo, initialize, jsonrpc = false, onNotification, onRequest, onExit }) {
    this.nextID = 1;
    this.pending = new Map();
    this.jsonrpc = jsonrpc;
    this.onNotification = onNotification;
    this.onRequest = onRequest ?? (() => null);
    this.process = spawn(command, args, { stdio: ["pipe", "pipe", "ignore"], env: agentEnv });
    let buffer = "";
    this.process.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) this.receive(line);
      }
    });
    const fail = (error) => {
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
      onExit();
    };
    this.process.on("error", fail);
    this.process.on("exit", (code) => fail(new Error(`${command} exited (${code})`)));
    this.ready = initialize ? initialize(this) : this.send("initialize", { clientInfo }).then(() => this.notify("initialized"));
    this.ready.catch(() => {});
  }

  async request(method, params) {
    await this.ready;
    return this.send(method, params);
  }

  send(method, params) {
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ id, method, params });
    });
  }

  notify(method, params) {
    this.write({ method, ...(params ? { params } : {}) });
  }

  write(message) {
    if (this.process.stdin.writable) this.process.stdin.write(JSON.stringify(this.jsonrpc ? { jsonrpc: "2.0", ...message } : message) + "\n");
  }

  receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.method && message.id !== undefined) {
      // A request from the agent, such as a permission prompt; whatever the caller can't answer is declined.
      const result = this.onRequest(message);
      this.write(result ? { id: message.id, result } : { id: message.id, error: { code: -32601, message: "Not supported by Hestrel" } });
    } else if (message.method) {
      this.onNotification(message);
    } else if (this.pending.has(message.id)) {
      const { resolve, reject } = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    }
  }
}

// MARK: Claude Code

const claudeTool = {
  name: "claude_code",
  description:
    "Runs Claude Code on the user's computer: it reads, edits and runs code in a folder. " +
    "Pass `session_id` from a previous result to continue that session.",
  inputSchema: {
    type: "object",
    properties: {
      prompt: { type: "string", description: "What Claude Code should do." },
      cwd: { type: "string", description: "Working folder; `~` is expanded. Defaults to where the bridge runs." },
      model: { type: "string", description: "A model alias (fable, opus, sonnet, haiku) or full name." },
      effort: { type: "string", enum: ["low", "medium", "high", "xhigh", "max"] },
      session_id: { type: "string", description: "Continue this session." },
    },
    required: ["prompt"],
  },
};

const claudeAvailable = new Promise((resolve) => {
  const probe = spawn(claudeBin, ["--version"], { stdio: "ignore", env: agentEnv });
  probe.on("error", () => resolve(false));
  probe.on("exit", (code) => resolve(code === 0));
});

// Edits are accepted inside the working folder, and Bash runs in Claude Code's sandbox, so nothing
// waits on a permission prompt nobody can answer from the phone.
const claudeSettings = JSON.stringify({ sandbox: { enabled: true, autoAllowBashIfSandboxed: true } });

/** Runs one Claude Code turn, streaming its events until the result. */
function runClaude(id, args, key, res) {
  if (typeof args.prompt !== "string" || !args.prompt.trim()) {
    return reply(res, 200, rpcError(id, -32602, "`prompt` is required."));
  }
  const cli = [
    "-p", args.prompt,
    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
    "--permission-mode", permissionMode, "--settings", claudeSettings,
  ];
  if (args.model) cli.push("--model", String(args.model));
  if (args.effort) cli.push("--effort", String(args.effort));
  if (args.session_id) {
    cli.push("--resume", String(args.session_id));
  } else {
    // Named like Hestrel's session, which identifies it when resumed in a terminal (`claude --resume <id>`).
    const title = args.prompt.trim().split("\n")[0].slice(0, 50);
    cli.push("--name", `Hestrel: ${title}`);
  }

  const cwd = expandHome(args.cwd) ?? process.cwd();

  const turn = new Turn(key);
  turn.attach(res);
  const send = (payload) => turn.emit(payload);
  const child = spawn(claudeBin, cli, { cwd, stdio: ["ignore", "pipe", "pipe"], env: agentEnv });
  // Only an explicit Stop ends the turn; a dropped connection just detaches from it.
  let stopped = false;
  turn.stop = () => {
    if (child.exitCode !== null) return;
    stopped = true;
    child.kill("SIGINT");
  };
  console.log(`[${new Date().toISOString()}] Claude Code ${args.session_id ? "resume" : "start"} in ${cwd}`);

  let messageID = null;
  let result = null;
  let sessionID = args.session_id ?? null;
  let stderr = "";
  let buffer = "";

  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      // Partial-message events only carry a block index; tag them with their message.
      if (event.type === "stream_event") {
        if (event.event?.type === "message_start") messageID = event.event.message?.id ?? null;
        event.message_id = messageID;
      }
      if (event.type === "result") result = event;
      if (event.type === "system" && event.subtype === "init") sessionID = event.session_id;
      if (isUseful(event)) send({ jsonrpc: "2.0", method: "claude/event", params: event });
    }
  });
  child.stderr.on("data", (chunk) => { stderr = (stderr + chunk).slice(-8_000); });

  const finish = (payload) => turn.finish(payload);
  child.on("error", (error) => finish(toolResult(id, `Couldn't start Claude Code: ${error.message}`, true)));
  child.on("close", (code) => {
    // Claude Code's own output for an interrupted turn is diagnostic noise; the session is fine to continue.
    if (stopped) {
      return finish(toolResult(id, "Stopped.", false, sessionID ? { sessionId: sessionID, result: "Stopped." } : undefined));
    }
    if (result) {
      const text = lostSession(result.result ?? (result.errors ?? []).join("\n"));
      finish(toolResult(id, text, Boolean(result.is_error), { sessionId: result.session_id, result: text }));
    } else {
      finish(toolResult(id, lostSession(stderr.trim() || `Claude Code exited with code ${code}.`), true));
    }
  });
}

/** Hestrel starts a new session with a recap when one can't be resumed, as it does for Codex. */
function lostSession(message) {
  return /no conversation found/i.test(message) ? `Session not found: ${message}` : message;
}

/** Events worth sending to the phone: text and thinking as it streams, tool calls and their results, the session start. */
function isUseful(event) {
  switch (event.type) {
    case "system": return event.subtype === "init";
    case "stream_event": return event.event?.type === "content_block_delta";
    case "assistant":
    case "user":
      return true;
    default: return false;
  }
}

// MARK: Other harnesses
//
// Any other coding agent runs through one tool, `agent_run`, and reports in one format: `hestrel/event`
// notifications that Hestrel reads the same way for every harness. Most agents speak the Agent Client
// Protocol (ACP), so one adapter covers them all; pi has its own JSON mode.

/** Harnesses offered when their command is installed. More ACP agents can be listed in ~/.hestrel/agents.json:
 *  [{ "id": "my-agent", "title": "My Agent", "command": ["my-agent", "--acp"] }] */
const knownHarnesses = [
  { id: "opencode", title: "OpenCode", protocol: "acp", command: ["opencode", "acp"] },
  { id: "pi", title: "Pi", protocol: "pi", command: ["pi"], effort: true },
  { id: "gemini", title: "Gemini CLI", protocol: "acp", command: ["gemini", "--experimental-acp"] },
  { id: "qwen", title: "Qwen Code", protocol: "acp", command: ["qwen", "--experimental-acp"] },
  { id: "goose", title: "Goose", protocol: "acp", command: ["goose", "acp"] },
  { id: "hermes", title: "Hermes", protocol: "acp", command: ["hermes-acp"] },
];

const harnesses = (() => {
  let custom = [];
  try {
    custom = JSON.parse(readFileSync(join(dirname(configPath), "agents.json"), "utf8"))
      .filter((agent) => /^[a-z0-9-]{1,32}$/.test(agent.id) && Array.isArray(agent.command) && agent.command.length)
      .map((agent) => ({ id: agent.id, title: String(agent.title ?? agent.id), protocol: "acp", command: agent.command }));
  } catch {}
  const all = [...knownHarnesses.filter((known) => !custom.some((agent) => agent.id === known.id)), ...custom];
  return all.filter((harness) => onPath(harness.command[0]));
})();

function onPath(command) {
  if (command.includes("/")) return existsSync(command);
  return (process.env.PATH ?? "").split(":").some((dir) => {
    try {
      accessSync(join(dir, command), constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function harnessTools() {
  if (!harnesses.length) return [];
  const agent = {
    type: "string",
    description: "Which coding agent to run.",
    oneOf: harnesses.map((harness) => ({ const: harness.id, title: harness.title, "x-hestrel-effort": harness.effort === true })),
  };
  return [
    {
      name: "agent_run",
      description: "Runs a coding agent on the user's computer: it reads, edits and runs code in a folder. Pass `session_id` from a previous result to continue.",
      inputSchema: {
        type: "object",
        properties: {
          agent,
          prompt: { type: "string" },
          cwd: { type: "string", description: "Working folder; `~` is expanded." },
          model: { type: "string" },
          effort: { type: "string", enum: ["low", "medium", "high"] },
          session_id: { type: "string" },
        },
        required: ["agent", "prompt"],
      },
    },
    {
      name: "agent_models",
      description: "Lists the models a coding agent can use, as JSON: [{ id, title }].",
      inputSchema: { type: "object", properties: { agent }, required: ["agent"] },
    },
  ];
}

/** Runs one turn of a harness, streaming `hestrel/event` notifications until the result. */
function runHarness(id, args, key, res) {
  const harness = harnesses.find((candidate) => candidate.id === args.agent);
  if (!harness) return reply(res, 200, rpcError(id, -32602, `Unknown agent: ${args.agent}`));
  if (typeof args.prompt !== "string" || !args.prompt.trim()) return reply(res, 200, rpcError(id, -32602, "`prompt` is required."));

  const turn = new Turn(key);
  turn.attach(res);
  const cwd = expandHome(args.cwd) ?? process.cwd();
  const events = new EventWriter(turn, harness.title);
  console.log(`[${new Date().toISOString()}] ${harness.title} ${args.session_id ? "resume" : "start"} in ${cwd}`);
  const finish = (text, isError, sessionId) => {
    turn.finish(toolResult(id, text, isError, sessionId ? { sessionId, result: text } : undefined));
  };
  (harness.protocol === "pi" ? runPi : runACP)(harness, args, cwd, turn, events, finish).catch((error) => {
    finish(`${harness.title} stopped: ${error.message}`, true);
  });
}

/** Lists a harness's models: from its CLI for opencode and pi, from its last session for other ACP agents. */
async function harnessModels(id, args, res) {
  const harness = harnesses.find((candidate) => candidate.id === args.agent);
  if (!harness) return reply(res, 200, rpcError(id, -32602, `Unknown agent: ${args.agent}`));
  let models = acpModelCache.get(harness.id) ?? [];
  try {
    if (harness.id === "opencode") {
      // The first call can catch opencode's background service still starting.
      for (let attempt = 0; attempt < 2 && !models.length; attempt++) {
        if (attempt) await sleep(1_500);
        models = runLines(harness.command[0], ["models"]).filter((line) => /^[\w.-]+\/\S+$/.test(line)).map((id) => ({ id, title: id }));
      }
    } else if (harness.protocol === "pi") {
      models = runLines("pi", ["--list-models"]).slice(1).map((line) => line.split(/\s+/)).filter((cols) => cols.length >= 2)
        .map(([provider, model]) => ({ id: `${provider}/${model}`, title: `${provider}/${model}` }));
    }
  } catch {}
  return reply(res, 200, toolResult(id, JSON.stringify(models), false));
}

function runLines(command, args) {
  return execFileSync(command, args, { encoding: "utf8", env: agentEnv, timeout: 30_000, stdio: ["ignore", "pipe", "ignore"] })
    .replace(/\x1b\[[0-9;]*m/g, "").split("\n").map((line) => line.trim()).filter(Boolean);
}

/**
 * Writes Hestrel's agent events: what the app shows as the turn's messages and steps.
 *   { type: "session", sessionId, model }          { type: "text_delta", item, text }   { type: "text", item, text }
 *   { type: "reasoning_delta", text }               { type: "step", id, host, step }      { type: "step_done", id, output, isError }
 *   { type: "error", message }
 * `step` is { kind: "command", command, summary } | { kind: "edit", files: [{ path, kind, diff }] }
 *         | { kind: "activity", summary, detail, symbol }.
 */
class EventWriter {
  constructor(turn, host) {
    this.turn = turn;
    this.host = host;
    this.answer = "";
    this.textSinceStep = "";
  }
  send(event) {
    this.turn.emit({ jsonrpc: "2.0", method: "hestrel/event", params: event });
  }
  session(sessionId, model) { this.send({ type: "session", sessionId, model: model ?? null }); }
  textDelta(item, text) {
    this.textSinceStep += text;
    this.send({ type: "text_delta", item, text });
  }
  text(item, text) { this.send({ type: "text", item, text }); }
  reasoning(text) { this.send({ type: "reasoning_delta", text }); }
  step(id, step) {
    if (this.textSinceStep.trim()) this.answer = this.textSinceStep;
    this.textSinceStep = "";
    this.send({ type: "step", id, host: this.host, step });
  }
  stepDone(id, output, isError) { this.send({ type: "step_done", id, output: String(output ?? ""), isError: Boolean(isError) }); }
  error(message) { this.send({ type: "error", message }); }
  /** The final answer: the text after the last step, or the last text before it. */
  get finalAnswer() { return (this.textSinceStep.trim() ? this.textSinceStep : this.answer).trim(); }
}

function replacementDiff(oldText = "", newText = "") {
  const before = oldText ? oldText.split("\n") : [];
  const after = newText ? newText.split("\n") : [];
  let prefix = 0;
  while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix++;
  let suffix = 0;
  while (suffix < before.length - prefix && suffix < after.length - prefix
    && before[before.length - 1 - suffix] === after[after.length - 1 - suffix]) suffix++;
  return ["@@",
    ...before.slice(0, prefix).map((line) => ` ${line}`),
    ...before.slice(prefix, before.length - suffix).map((line) => `-${line}`),
    ...after.slice(prefix, after.length - suffix).map((line) => `+${line}`),
    ...before.slice(before.length - suffix).map((line) => ` ${line}`)].join("\n");
}

const fileName = (path) => String(path ?? "").split("/").pop() || "a file";

// MARK: ACP

const acpAgents = new Map();
const acpModelCache = new Map();

/** One long-lived ACP agent process per harness, which runs every session of that harness. */
function acpAgent(harness) {
  let agent = acpAgents.get(harness.id);
  if (agent) return agent;
  const sessions = new Map();
  const server = new StdioServer(harness.command[0], harness.command.slice(1), {
    jsonrpc: true,
    initialize: (server) => server.send("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: "hestrel-bridge", title: "Hestrel", version: "1.0.0" },
    }).then((result) => { agent.capabilities = result?.agentCapabilities ?? {}; }),
    onNotification: (message) => {
      if (message.method === "session/update") sessions.get(message.params?.sessionId)?.(message.params.update);
    },
    // Nobody can answer a permission prompt from the phone, so the agent gets what it asks for, once.
    onRequest: (message) => {
      if (message.method !== "session/request_permission") return null;
      const options = message.params?.options ?? [];
      const allow = options.find((option) => option.kind === "allow_once") ?? options.find((option) => option.kind?.startsWith("allow")) ?? options[0];
      // The request often carries the edit's diff, which the step can show.
      if (message.params?.toolCall?.toolCallId) {
        sessions.get(message.params.sessionId)?.({ sessionUpdate: "tool_call_update", ...message.params.toolCall });
      }
      return allow ? { outcome: { outcome: "selected", optionId: allow.optionId } } : { outcome: { outcome: "cancelled" } };
    },
    onExit: () => acpAgents.delete(harness.id),
  });
  agent = { server, sessions, loaded: new Set(), capabilities: {} };
  acpAgents.set(harness.id, agent);
  return agent;
}

async function runACP(harness, args, cwd, turn, events, finish) {
  const agent = acpAgent(harness);
  const { server } = agent;
  await server.ready;

  // Start or pick up the session. Loading replays its history as updates, which the phone already has.
  let sessionId = args.session_id ?? null;
  let replaying = false;
  let setup;
  if (sessionId && !agent.loaded.has(sessionId)) {
    replaying = true;
    agent.sessions.set(sessionId, () => {});
    try {
      setup = agent.capabilities.sessionCapabilities?.resume
        ? await server.request("session/resume", { sessionId, cwd, mcpServers: [] })
        : await server.request("session/load", { sessionId, cwd, mcpServers: [] });
    } catch (error) {
      agent.sessions.delete(sessionId);
      return finish(`Session not found: ${error.message}`, true, sessionId);
    }
    replaying = false;
  } else if (!sessionId) {
    setup = await server.request("session/new", { cwd, mcpServers: [] });
    sessionId = setup.sessionId;
  }
  agent.loaded.add(sessionId);
  rememberACPModels(harness.id, setup);

  if (args.model) {
    const viaConfig = setup?.configOptions?.some((option) => option.id === "model");
    await server.request(viaConfig ? "session/set_config_option" : "session/set_model",
      viaConfig ? { sessionId, configId: "model", value: args.model } : { sessionId, modelId: args.model })
      .catch((error) => events.error(`Couldn't switch to ${args.model}: ${error.message}`));
  }
  events.session(sessionId, args.model ?? currentACPModel(setup));

  // Messages without an ID are split wherever a step comes between them.
  let textItem = 0;
  const steps = new Map();
  agent.sessions.set(sessionId, (update) => {
    if (replaying || turn.done) return;
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
        if (update.content?.type === "text") events.textDelta(update.messageId ?? `text-${textItem}`, update.content.text);
        break;
      case "agent_thought_chunk":
        if (update.content?.type === "text") events.reasoning(update.content.text);
        break;
      case "tool_call":
      case "tool_call_update": {
        const known = steps.get(update.toolCallId) ?? {};
        const call = { ...known, ...Object.fromEntries(Object.entries(update).filter(([, value]) => value != null)) };
        steps.set(update.toolCallId, call);
        // A command's result replaces its content, so the command shown is the one it started with.
        const step = known.step?.kind === "command" ? known.step : acpStep(call);
        if (update.sessionUpdate === "tool_call" || JSON.stringify(step) !== JSON.stringify(known.step)) {
          call.step = step;
          events.step(update.toolCallId, step);
          textItem += 1;
        }
        if (update.status === "completed" || update.status === "failed") {
          events.stepDone(update.toolCallId, acpOutput(call), update.status === "failed");
        }
        break;
      }
      case "plan":
        events.step("plan", {
          kind: "activity", summary: "Updated the plan", symbol: "checklist",
          detail: (update.entries ?? []).map((entry) => `${entry.status === "completed" ? "✓" : "•"} ${entry.content}`).join("\n") || null,
        });
        events.stepDone("plan", "", false);
        break;
    }
  });

  turn.stop = () => server.notify("session/cancel", { sessionId });
  try {
    const result = await server.request("session/prompt", { sessionId, prompt: [{ type: "text", text: String(args.prompt) }] });
    // Some agents never report a step as finished; by the end of the turn, they all are.
    for (const [id, call] of steps) {
      if (call.status !== "completed" && call.status !== "failed") events.stepDone(id, acpOutput(call), false);
    }
    const stopped = result?.stopReason === "cancelled";
    finish(stopped ? "Stopped." : events.finalAnswer, false, sessionId);
  } catch (error) {
    finish(error.message, true, sessionId);
  } finally {
    agent.sessions.delete(sessionId);
  }
}

/** An ACP tool call as a Hestrel step. */
function acpStep(call) {
  const content = call.content ?? [];
  const diffs = content.filter((item) => item.type === "diff");
  const text = content.map((item) => item.content?.text).filter(Boolean).join("\n");
  const path = call.locations?.[0]?.path;
  switch (call.kind) {
    case "execute": {
      const command = call.rawInput?.command ?? (text.startsWith("$ ") ? text.slice(2).split("\n")[0] : null) ?? call.title ?? "";
      return { kind: "command", command: Array.isArray(command) ? command.join(" ") : String(command), summary: call.rawInput?.description ?? null };
    }
    case "edit":
    case "delete":
    case "move":
      if (diffs.length) {
        return { kind: "edit", files: diffs.map((diff) => ({
          path: diff.path ?? path ?? "",
          kind: diff.oldText == null || diff.oldText === "" ? "add" : "update",
          // Some agents (Hermes) send their apply-patch text instead of the new file.
          diff: String(diff.newText ?? "").startsWith("*** Begin Patch")
            ? diff.newText.split("\n").filter((line) => !line.startsWith("*** ")).join("\n")
            : replacementDiff(diff.oldText ?? "", diff.newText ?? ""),
        })) };
      }
      return { kind: "activity", summary: path ? `Edited ${fileName(path)}` : "Edited files", detail: path ?? null, symbol: "pencil" };
    case "read":
      return { kind: "activity", summary: path ? `Read ${fileName(path)}` : call.title ?? "Read a file", detail: path ?? null, symbol: "doc.text" };
    case "search":
      return { kind: "activity", summary: call.title ?? "Searched", detail: null, symbol: "magnifyingglass" };
    case "fetch":
      return { kind: "activity", summary: call.title ?? "Read a page", detail: null, symbol: "globe" };
    default:
      return { kind: "activity", summary: call.title ?? "Used a tool", detail: null, symbol: call.kind === "think" ? "brain" : "wrench.and.screwdriver" };
  }
}

function acpOutput(call) {
  const text = (call.content ?? []).map((item) => item.content?.text ?? (item.type === "terminal" ? "" : null)).filter(Boolean).join("\n");
  if (text) return text;
  const raw = call.rawOutput;
  return raw == null ? "" : typeof raw === "string" ? raw : raw.output ?? raw.stdout ?? JSON.stringify(raw, null, 2);
}

function rememberACPModels(id, setup) {
  const config = setup?.configOptions?.find((option) => option.id === "model");
  const models = config
    ? (config.options ?? []).map((option) => ({ id: option.value, title: option.name ?? option.value }))
    : (setup?.models?.availableModels ?? []).map((model) => ({ id: model.modelId, title: model.name ?? model.modelId }));
  if (models.length) acpModelCache.set(id, models);
}

function currentACPModel(setup) {
  return setup?.configOptions?.find((option) => option.id === "model")?.currentValue ?? setup?.models?.currentModelId ?? null;
}

// MARK: Pi

/** One pi turn: `pi -p --mode json` resumes the session by ID, like Claude Code's `--resume`. */
function runPi(harness, args, cwd, turn, events, finish) {
  return new Promise((resolve) => {
    const sessionId = args.session_id ?? randomUUID();
    const cli = ["-p", "--mode", "json", "--session-id", sessionId];
    if (args.model) cli.push("--model", String(args.model));
    if (args.effort) cli.push("--thinking", String(args.effort));
    cli.push("--", String(args.prompt));
    const child = spawn(harness.command[0], cli, { cwd, stdio: ["ignore", "pipe", "pipe"], env: agentEnv });
    let stopped = false;
    turn.stop = () => {
      if (child.exitCode !== null) return;
      stopped = true;
      child.kill("SIGINT");
    };

    let message = 0;
    let model = null;
    let stderr = "";
    const steps = new Map();
    let buffer = "";
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          continue;
        }
        switch (event.type) {
          case "session":
            events.session(event.id, args.model ?? null);
            break;
          case "message_start":
            if (event.message?.role === "assistant") {
              message += 1;
              if (!model && event.message.model) {
                model = `${event.message.provider}/${event.message.model}`;
                events.session(sessionId, model);
              }
            }
            break;
          case "message_update": {
            const update = event.assistantMessageEvent ?? {};
            const item = `${message}:${update.contentIndex ?? 0}`;
            if (update.type === "text_delta") events.textDelta(item, update.delta);
            else if (update.type === "text_end") events.text(item, update.content);
            else if (update.type === "thinking_delta") events.reasoning(update.delta);
            break;
          }
          case "tool_execution_start": {
            const step = piStep(event.toolName, event.args ?? {});
            steps.set(event.toolCallId, step);
            events.step(event.toolCallId, step);
            break;
          }
          case "tool_execution_end": {
            const patch = event.result?.details?.patch;
            const step = steps.get(event.toolCallId);
            // pi reports the real diff once the edit is made.
            if (patch && step?.kind === "edit") {
              events.step(event.toolCallId, { kind: "edit", files: step.files.map((file) => ({ ...file, kind: "update", diff: patch })) });
            }
            const output = (event.result?.content ?? []).map((part) => part.text).filter(Boolean).join("\n");
            events.stepDone(event.toolCallId, output, event.isError);
            break;
          }
        }
      }
    });
    child.stderr.on("data", (chunk) => { stderr = (stderr + chunk).slice(-8_000); });
    child.on("error", (error) => { finish(`Couldn't start pi: ${error.message}`, true); resolve(); });
    child.on("close", (code) => {
      if (stopped) finish("Stopped.", false, sessionId);
      else if (code === 0) finish(events.finalAnswer, false, sessionId);
      else finish(stderr.trim().split("\n").filter((line) => !line.startsWith("Warning:")).join("\n") || `pi exited with code ${code}.`, true, sessionId);
      resolve();
    });
  });
}

function piStep(tool, args) {
  switch (tool) {
    case "bash":
      return { kind: "command", command: String(args.command ?? ""), summary: null };
    case "edit": {
      const diff = (args.edits ?? [{ oldText: args.oldText, newText: args.newText }]).map((edit) => replacementDiff(edit.oldText, edit.newText)).join("\n");
      return { kind: "edit", files: [{ path: args.path ?? "", kind: "update", diff }] };
    }
    case "write":
      return { kind: "edit", files: [{ path: args.path ?? "", kind: "add", diff: String(args.content ?? "") }] };
    case "read":
      return { kind: "activity", summary: `Read ${fileName(args.path)}`, detail: args.path ?? null, symbol: "doc.text" };
    case "grep":
    case "find":
      return { kind: "activity", summary: `Searched for ${args.pattern ?? args.query ?? ""}`, detail: args.path ?? null, symbol: "magnifyingglass" };
    case "ls":
      return { kind: "activity", summary: "Listed files", detail: args.path ?? null, symbol: "folder" };
    default:
      return { kind: "activity", summary: `Used ${tool}`, detail: JSON.stringify(args, null, 2), symbol: "wrench.and.screwdriver" };
  }
}

// MARK: Turns

/** Turns by stream ID, kept a while after they finish so a device that was away can collect the result. */
const turns = new Map();
const TURN_RETENTION = 60 * 60_000;

/**
 * One agent turn as a stream of numbered events (`<turn>:<n>`), independent of any connection. The device that
 * started it may drop away, the phone sleeping or losing signal, and come back with `Last-Event-ID` for the rest.
 */
class Turn {
  constructor(key) {
    this.id = randomUUID();
    this.key = key;
    this.events = [];
    this.listeners = new Set();
    this.done = false;
    this.stop = () => {};
    turns.set(this.id, this);
    running.set(key, this);
  }

  emit(payload) {
    if (this.done) return;
    const index = this.events.length;
    this.events.push(payload);
    for (const res of this.listeners) writeEvent(res, `${this.id}:${index}`, payload);
  }

  /** Sends the JSON-RPC result, which ends the stream. */
  finish(payload) {
    if (this.done) return;
    this.emit(payload);
    this.done = true;
    running.delete(this.key);
    for (const res of this.listeners) res.end();
    this.listeners.clear();
    setTimeout(() => turns.delete(this.id), TURN_RETENTION).unref();
  }

  /** Streams the events after `after` to `res`, then the rest as they come. */
  attach(res, after = -1) {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
    for (let index = Math.max(after + 1, 0); index < this.events.length; index++) {
      writeEvent(res, `${this.id}:${index}`, this.events[index]);
    }
    if (this.done) return res.end();
    this.listeners.add(res);
    res.on("close", () => this.listeners.delete(res));
  }
}

function writeEvent(res, id, payload) {
  if (!res.writableEnded) res.write(`id: ${id}\nevent: message\ndata: ${JSON.stringify(payload)}\n\n`);
}

// MARK: HTTP and JSON-RPC

function toolResult(id, text, isError, structuredContent) {
  return rpcResult(id, {
    content: [{ type: "text", text }],
    ...(structuredContent ? { structuredContent } : {}),
    isError,
  });
}

function rpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function reply(res, status, payload) {
  res.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(payload));
}

function body(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => { data += chunk; if (data.length > 1_000_000) req.destroy(); });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

// MARK: QR codes

// QR codes (byte mode, error correction M, versions 1–10), enough for a pairing link.

/** [error-correction codewords per block, [blocks, data codewords per block]…] for level M, by version. */
const QR_BLOCKS_M = [
  null,
  [10, [1, 16]], [16, [1, 28]], [26, [1, 44]], [18, [2, 32]], [24, [2, 43]],
  [16, [4, 27]], [18, [4, 31]], [22, [2, 38], [2, 39]], [22, [3, 36], [2, 37]], [26, [4, 43], [1, 44]],
];
const QR_ALIGNMENT = [null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

/** The QR code for `text` as rows of booleans (true = dark), without the quiet zone. */
function qrMatrix(text) {
  const data = new TextEncoder().encode(text);
  let version = 1;
  const capacity = (v) => QR_BLOCKS_M[v].slice(1).reduce((sum, [count, size]) => sum + count * size, 0);
  while (version <= 10 && 4 + (version < 10 ? 8 : 16) + data.length * 8 > capacity(version) * 8) version += 1;
  if (version > 10) throw new Error("Too long for a QR code here.");

  // Data bits: byte mode, length, bytes, terminator, padding.
  const bits = [];
  const push = (value, length) => { for (let i = length - 1; i >= 0; i--) bits.push((value >> i) & 1); };
  push(0b0100, 4);
  push(data.length, version < 10 ? 8 : 16);
  for (const byte of data) push(byte, 8);
  const dataCapacity = capacity(version);
  push(0, Math.min(4, dataCapacity * 8 - bits.length));
  while (bits.length % 8) bits.push(0);
  const codewords = [];
  for (let i = 0; i < bits.length; i += 8) codewords.push(parseInt(bits.slice(i, i + 8).join(""), 2));
  for (let pad = 0; codewords.length < dataCapacity; pad++) codewords.push(pad % 2 ? 0x11 : 0xec);

  // Split into blocks, add Reed–Solomon error correction, interleave.
  const [ecLength, ...groups] = QR_BLOCKS_M[version];
  const blocks = [];
  let offset = 0;
  for (const [count, size] of groups) {
    for (let i = 0; i < count; i++) {
      const block = codewords.slice(offset, offset + size);
      offset += size;
      blocks.push({ data: block, ec: reedSolomon(block, ecLength) });
    }
  }
  const final = [];
  const longest = Math.max(...blocks.map((block) => block.data.length));
  for (let i = 0; i < longest; i++) for (const block of blocks) if (i < block.data.length) final.push(block.data[i]);
  for (let i = 0; i < ecLength; i++) for (const block of blocks) final.push(block.ec[i]);

  // Function patterns.
  const size = version * 4 + 17;
  const modules = Array.from({ length: size }, () => new Array(size).fill(false));
  const reserved = Array.from({ length: size }, () => new Array(size).fill(false));
  const set = (row, col, dark) => { modules[row][col] = dark; reserved[row][col] = true; };
  for (const [row, col] of [[0, 0], [0, size - 7], [size - 7, 0]]) {
    for (let r = -1; r <= 7; r++) {
      for (let c = -1; c <= 7; c++) {
        if (row + r < 0 || row + r >= size || col + c < 0 || col + c >= size) continue;
        const ring = Math.max(Math.abs(r - 3), Math.abs(c - 3));
        set(row + r, col + c, ring !== 2 && ring !== 4);
      }
    }
  }
  const centers = QR_ALIGNMENT[version];
  for (const row of centers) {
    for (const col of centers) {
      if (reserved[row][col]) continue;
      for (let r = -2; r <= 2; r++) for (let c = -2; c <= 2; c++) set(row + r, col + c, Math.max(Math.abs(r), Math.abs(c)) !== 1);
    }
  }
  for (let i = 8; i < size - 8; i++) {
    if (!reserved[6][i]) set(6, i, i % 2 === 0);
    if (!reserved[i][6]) set(i, 6, i % 2 === 0);
  }
  set(size - 8, 8, true);
  // Reserve format and version areas; they're written once the mask is chosen.
  for (let i = 0; i < 9; i++) { reserved[8][i] = true; reserved[i][8] = true; }
  for (let i = 0; i < 8; i++) { reserved[8][size - 1 - i] = true; reserved[size - 1 - i][8] = true; }
  if (version >= 7) for (let i = 0; i < 6; i++) for (let j = 0; j < 3; j++) { reserved[i][size - 11 + j] = true; reserved[size - 11 + j][i] = true; }

  // Data, in the zigzag order.
  const dataBits = final.flatMap((byte) => Array.from({ length: 8 }, (_, i) => (byte >> (7 - i)) & 1));
  let bitIndex = 0;
  for (let right = size - 1, upward = true; right > 0; right -= 2, upward = !upward) {
    if (right === 6) right = 5;
    for (let step = 0; step < size; step++) {
      const row = upward ? size - 1 - step : step;
      for (const col of [right, right - 1]) {
        if (reserved[row][col]) continue;
        modules[row][col] = bitIndex < dataBits.length ? dataBits[bitIndex] === 1 : false;
        bitIndex += 1;
      }
    }
  }

  // Try every mask; keep the one with the lowest penalty.
  const masks = [
    (r, c) => (r + c) % 2 === 0, (r) => r % 2 === 0, (_, c) => c % 3 === 0, (r, c) => (r + c) % 3 === 0,
    (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0, (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
    (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0, (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
  ];
  let best = null;
  for (let mask = 0; mask < 8; mask++) {
    const candidate = modules.map((row, r) => row.map((dark, c) => (reserved[r][c] ? dark : dark !== masks[mask](r, c))));
    writeFormat(candidate, size, mask);
    if (version >= 7) writeVersion(candidate, size, version);
    const score = penalty(candidate);
    if (!best || score < best.score) best = { score, matrix: candidate };
  }
  return best.matrix;
}

function writeFormat(matrix, size, mask) {
  // Level M is 00.
  const data = (0b00 << 3) | mask;
  let rem = data << 10;
  for (let i = 14; i >= 10; i--) if ((rem >> i) & 1) rem ^= 0b10100110111 << (i - 10);
  const bits = ((data << 10) | rem) ^ 0b101010000010010;
  const bit = (i) => ((bits >> i) & 1) === 1;
  for (let i = 0; i <= 5; i++) matrix[8][i] = bit(14 - i);
  matrix[8][7] = bit(8);
  matrix[8][8] = bit(7);
  matrix[7][8] = bit(6);
  for (let i = 9; i < 15; i++) matrix[14 - i][8] = bit(14 - i);
  for (let i = 0; i < 8; i++) matrix[size - 1 - i][8] = bit(14 - i);
  for (let i = 8; i < 15; i++) matrix[8][size - 15 + i] = bit(14 - i);
  matrix[size - 8][8] = true;
}

function writeVersion(matrix, size, version) {
  let rem = version << 12;
  for (let i = 17; i >= 12; i--) if ((rem >> i) & 1) rem ^= 0b1111100100101 << (i - 12);
  const bits = (version << 12) | rem;
  for (let i = 0; i < 18; i++) {
    const dark = ((bits >> i) & 1) === 1;
    const a = Math.floor(i / 3);
    const b = (i % 3) + size - 11;
    matrix[a][b] = dark;
    matrix[b][a] = dark;
  }
}

function penalty(matrix) {
  const size = matrix.length;
  let score = 0;
  for (let pass = 0; pass < 2; pass++) {
    for (let i = 0; i < size; i++) {
      let run = 1;
      for (let j = 1; j <= size; j++) {
        const same = j < size && (pass ? matrix[j][i] === matrix[j - 1][i] : matrix[i][j] === matrix[i][j - 1]);
        if (same) run += 1;
        else { if (run >= 5) score += run - 2; run = 1; }
      }
    }
  }
  for (let r = 0; r < size - 1; r++) {
    for (let c = 0; c < size - 1; c++) {
      const v = matrix[r][c];
      if (v === matrix[r + 1][c] && v === matrix[r][c + 1] && v === matrix[r + 1][c + 1]) score += 3;
    }
  }
  const finderLike = [true, false, true, true, true, false, true, false, false, false, false];
  const reversed = [...finderLike].reverse();
  for (let r = 0; r < size; r++) {
    for (let c = 0; c + 11 <= size; c++) {
      for (const pattern of [finderLike, reversed]) {
        if (pattern.every((v, k) => matrix[r][c + k] === v)) score += 40;
        if (pattern.every((v, k) => matrix[c + k][r] === v)) score += 40;
      }
    }
  }
  const dark = matrix.flat().filter(Boolean).length;
  score += Math.floor(Math.abs((dark * 100) / (size * size) - 50) / 5) * 10;
  return score;
}

function reedSolomon(data, length) {
  const exp = new Array(512);
  const log = new Array(256);
  for (let i = 0, x = 1; i < 255; i++) {
    exp[i] = x;
    log[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) exp[i] = exp[i - 255];
  const multiply = (a, b) => (a && b ? exp[log[a] + log[b]] : 0);
  let generator = [1];
  for (let i = 0; i < length; i++) {
    const next = new Array(generator.length + 1).fill(0);
    for (let j = 0; j < generator.length; j++) {
      next[j] ^= generator[j];
      next[j + 1] ^= multiply(generator[j], exp[i]);
    }
    generator = next;
  }
  const remainder = [...data, ...new Array(length).fill(0)];
  for (let i = 0; i < data.length; i++) {
    const factor = remainder[i];
    if (!factor) continue;
    for (let j = 0; j < generator.length; j++) remainder[i + j] ^= multiply(generator[j], factor);
  }
  return remainder.slice(data.length);
}

/** The QR code drawn with half blocks in explicit black and white, so it scans on light and dark terminals. */
function qrTerminal(text) {
  const matrix = qrMatrix(text);
  const quiet = 2;
  const size = matrix.length + quiet * 2;
  const dark = (r, c) => r >= quiet && c >= quiet && r < size - quiet && c < size - quiet && matrix[r - quiet][c - quiet];
  const lines = [];
  for (let r = 0; r < size; r += 2) {
    let line = "";
    for (let c = 0; c < size; c++) {
      const top = dark(r, c);
      const bottom = r + 1 < size ? dark(r + 1, c) : false;
      line += `\x1b[${top ? 30 : 97};${bottom ? 40 : 107}m▀`;
    }
    lines.push(line + "\x1b[0m");
  }
  return lines.join("\n");
}
