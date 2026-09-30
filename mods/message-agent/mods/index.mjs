// @letta-ai/message-agent
//
// Registers ONE agent-callable tool: `message_agent`.
//
// It messages any sibling agent in the sudo-fleet by bare name and returns
// that sibling's reply. Sibling resolution + reach use the same live-roster
// mechanism as @letta-ai/list-siblings (docker-socket + nsenter host bridge,
// `kubectl get services -n default`) -- except message-agent needs the
// ClusterIP of the sibling's -mcp service, because the k8s DNS name
// `sudo-<name>-mcp` does NOT resolve from inside a pod. The ClusterIP is read
// from the CLUSTER-IP column of `kubectl get services`.
//
// The sibling's -mcp door speaks MCP (streamable HTTP):
//   initialize -> notifications/initialized -> tools/list (to learn whether
//   the sibling is a Letta planner exposing `letta_prompt` or a Hermes
//   engineer exposing `hermes_prompt`) -> tools/call with the prompt.
// Direct mode waits for the reply with no client-side timeout (long jobs are
// not cut); inbox mode returns the enqueued message id immediately.

import { spawn } from "node:child_process";

// The host bridge: docker -> host namespaces -> host kubectl.
const BRIDGE_CMD = "docker";
const BRIDGE_ARGS = [
  "run",
  "--rm",
  "--privileged",
  "--pid=host",
  "--net=host",
  "-v",
  "/:/host",
  "alpine:latest",
  "nsenter",
  "-t",
  "1",
  "-m",
  "-u",
  "-i",
  "-n",
  "-p",
  "--",
  "env",
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
  "kubectl",
  "get",
  "services",
  "-n",
  "default",
];

const DEFAULT_PORT = 8000;
const BRIDGE_TIMEOUT_MS = 45000;

// Bare names that are infrastructure (redis), not sibling agents.
const SKIP_BARE = new Set(["agent-redis", "letta-redis"]);

/** Run the host bridge once; always resolves, never throws. */
function runBridge(timeoutMs = BRIDGE_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(BRIDGE_CMD, BRIDGE_ARGS, { stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve({
        ok: false,
        error: error && error.message ? error.message : String(error),
        stdout: "",
        stderr: "",
      });
      return;
    }

    let stdout = "";
    let stderr = "";
    let settled = false;

    const finish = (payload) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(payload);
    };

    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
      finish({
        ok: false,
        error: `host bridge timed out after ${timeoutMs}ms`,
        stdout,
        stderr,
      });
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish({
        ok: false,
        error: error && error.message ? error.message : String(error),
        stdout,
        stderr,
      });
    });
    child.on("close", (code) => {
      finish({ ok: code === 0, code, stdout, stderr });
    });
  });
}

/**
 * Parse `kubectl get services -n default` into a sibling roster keyed by bare
 * name, carrying the -mcp ClusterIP.
 *
 * Columns are NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE, so CLUSTER-IP is
 * column index 2. Only `sudo-<bare>-mcp` services pair up (the header row,
 * `kubernetes`, `sudo-*-redis` and `sudo-*-svc` are skipped by construction).
 */
function parseRoster(stdout) {
  const seen = new Map();

  for (const rawLine of String(stdout || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const cols = line.split(/\s+/);
    const name = cols[0];
    if (!name || name === "NAME") continue;

    const match = /^sudo-(.+)-mcp$/.exec(name);
    if (!match) continue;

    const bare = match[1];
    if (SKIP_BARE.has(bare)) continue;

    // CLUSTER-IP column; the DNS name does not resolve in-pod, so the IP is
    // what makes the sibling reachable.
    const ip = cols[2] || "";
    if (!ip || ip === "<none>") continue;

    seen.set(bare, {
      sibling: bare,
      mcpIp: ip,
      mcpHost: `${ip}:${DEFAULT_PORT}`,
    });
  }

  return [...seen.values()].sort((a, b) => a.sibling.localeCompare(b.sibling));
}

/**
 * Resolve a sibling by bare name: exact (case-insensitive) -> unique substring
 * -> ambiguous error -> not-found error.
 */
function resolveSibling(roster, name) {
  const q = String(name || "").trim().toLowerCase();
  if (!q) throw new Error("`sibling` is required");

  const exact = roster.filter((e) => e.sibling.toLowerCase() === q);
  if (exact.length === 1) return exact[0];

  const subs = roster.filter((e) => e.sibling.toLowerCase().includes(q));
  if (subs.length === 1) return subs[0];
  if (subs.length > 1) {
    throw new Error(
      `ambiguous sibling "${name}"; candidates: ${subs
        .map((e) => e.sibling)
        .join(", ")}`,
    );
  }
  throw new Error(`sibling not found: ${name}`);
}

/**
 * One MCP JSON-RPC round trip over streamable HTTP. Returns the (possibly
 * updated) session id and the decoded SSE `data:` payload.
 */
async function mcpRpc(url, sid, method, params) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
  };
  if (sid) headers["Mcp-Session-Id"] = sid;

  const res = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: method, method, params }),
  });
  const nextSid = res.headers.get("mcp-session-id") || sid;
  const body = await res.text();

  let msg = null;
  for (const line of body.split(/\r?\n/)) {
    if (line.startsWith("data:")) {
      const chunk = line.slice(5).trim();
      if (chunk) {
        try {
          msg = JSON.parse(chunk);
        } catch {
          /* keep scanning */
        }
      }
    }
  }
  return { sid: nextSid, msg };
}

/**
 * Connect to a sibling's -mcp door: initialize -> notifications/initialized ->
 * tools/list. Returns the live connection (url + session id) and the sibling's
 * kind ("hermes" if it exposes `hermes_prompt`, else "letta").
 */
async function connect(entry) {
  const url = `http://${entry.mcpIp}:${DEFAULT_PORT}/mcp`;

  let r = await mcpRpc(url, null, "initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "sudo-fleet-comm", version: "1.0" },
  });
  const sid = r.sid;
  if (!r.msg || r.msg.error) {
    throw new Error(`MCP initialize failed: ${JSON.stringify(r.msg && r.msg.error)}`);
  }

  await mcpRpc(url, sid, "notifications/initialized", {});

  r = await mcpRpc(url, sid, "tools/list", {});
  const tools = (r.msg && r.msg.result && r.msg.result.tools) || [];
  const kind = tools.some((t) => t.name === "hermes_prompt") ? "hermes" : "letta";

  return { url, sid, kind };
}

/** tools/call the sibling's prompt tool and unwrap the reply text. */
async function callPrompt(conn, toolName, args) {
  const r = await mcpRpc(conn.url, conn.sid, "tools/call", {
    name: toolName,
    arguments: args,
  });
  if (r.msg && r.msg.error) {
    throw new Error(`MCP tools/call failed: ${JSON.stringify(r.msg.error)}`);
  }
  const content = (r.msg && r.msg.result && r.msg.result.content) || [];
  return content
    .filter((c) => c && c.type === "text")
    .map((c) => c.text)
    .join("\n");
}

/** Coerce a raw reply string into the final tool result. */
function shapeResult(text, { json, mode }) {
  if (mode === "inbox" || json) {
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
  return text;
}

export default function activate(letta) {
  if (!letta.capabilities.tools) return;

  return letta.tools.register({
    name: "message_agent",
    description:
      "Message any sibling agent in this sudo-fleet by bare name and return its reply. This is the PRIMARY way agents work together -- delegate, ask, coordinate, hand off. Resolves the sibling from the live cluster roster (exact -> case-insensitive -> unique substring -> error), reaches its -mcp door over MCP, and calls its prompt tool (letta_prompt for a Letta planner, hermes_prompt for a Hermes engineer -- auto-detected). mode='inbox' (default) sends and returns a message id immediately; mode='direct' waits for the full reply with no timeout (explicit opt-in). new_chat=true starts a fresh conversation (planners only; ignored for engineers). json=true returns the structured reply. source tags the message for group-by-source ordering in the recipient's queue.",
    parameters: {
      type: "object",
      properties: {
        sibling: {
          type: "string",
          description:
            "The sibling agent to message, by bare name (e.g. 'fa-glm-h', 'ms-glm-l'). Resolved exact -> case-insensitive -> unique substring.",
        },
        prompt: {
          type: "string",
          description: "The message to send.",
        },
        mode: {
          type: "string",
          enum: ["direct", "inbox"],
          description:
            "'inbox' (default) = send and return a message id immediately (fire-and-forget; fetch the reply later via the sibling's queue_status tool). 'direct' = send and WAIT for the full reply (no timeout, safe for long jobs) -- an explicit opt-in.",
        },
        new_chat: {
          type: "boolean",
          description:
            "Planners only: true starts a fresh conversation, false (default) resumes the planner's persisted conversation. Ignored for Hermes engineers.",
        },
        json: {
          type: "boolean",
          description:
            "true returns the structured reply (planners return the JSON object; engineers pretty-print valid JSON, else raw text).",
        },
        source: {
          type: "string",
          description:
            "A stable tag (e.g. your own name) grouping your messages in the recipient's queue. Optional; defaults to the MCP session id on the recipient.",
        },
      },
      required: ["sibling", "prompt"],
      additionalProperties: false,
    },
    requiresApproval: false,
    parallelSafe: true,
    async run(ctx) {
      const args = (ctx && ctx.args) || {};
      const sibling = args.sibling;
      const prompt = args.prompt;
      const mode = args.mode === "direct" ? "direct" : "inbox";
      const json = !!args.json;
      const newChat = !!args.new_chat;
      const source = typeof args.source === "string" ? args.source.trim() : "";

      if (!sibling || !prompt) {
        return "message_agent requires both `sibling` and `prompt`.";
      }

      const bridge = await runBridge();
      if (!bridge.ok) {
        const detail = (bridge.stderr || bridge.error || "").trim().slice(0, 1500);
        return `message_agent could not read the cluster: ${detail || "unknown error"}`;
      }

      let entry;
      try {
        entry = resolveSibling(parseRoster(bridge.stdout), sibling);
      } catch (error) {
        return `message_agent: ${error.message}`;
      }

      let conn;
      try {
        conn = await connect(entry);
      } catch (error) {
        return `message_agent: could not reach ${entry.sibling} at ${entry.mcpHost}: ${error.message}`;
      }

      const callArgs = { prompt, json, mode };
      if (conn.kind === "letta") callArgs.new_chat = newChat;
      if (source) callArgs.source = source;
      const toolName = conn.kind === "hermes" ? "hermes_prompt" : "letta_prompt";

      try {
        const text = await callPrompt(conn, toolName, callArgs);
        return shapeResult(text, { json, mode });
      } catch (error) {
        return `message_agent: ${toolName} on ${entry.sibling} failed: ${error.message}`;
      }
    },
  });
}

export const __test = { BRIDGE_ARGS, runBridge, parseRoster, resolveSibling };
