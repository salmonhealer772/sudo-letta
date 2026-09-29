// @letta-ai/check-agent
//
// Registers ONE agent-callable tool: `check_agent`.
//
// The merged observability read for the sudo-fleet. It reads a sibling's trail
// and answers BOTH "what has it been doing" and "what is it doing right now"
// from that same trail -- the what-is-it-doing answer falls out of the freshest
// entries (current conversation + latest process_state). There is no /status
// and no /ps surface any more.
//
//   mode="full" (default) -> GET http://<watch ClusterIP>:8000/events?n=N
//                            every event (user/thinking/assistant/tool_call/
//                            tool_result/session/process_state), raw ndjson.
//   mode="compressed"     -> read the sibling's transcript.txt file directly
//                            (the same read `stream.sh -t` does): plain chat
//                            only, no thinking/tool noise.
//
// `n` is identical in both modes: k>0 = the last k; n=-1 = the ENTIRE file, no
// depth cap; omitted = 100.
//
// Cluster facts this backend relies on:
//   * `sudo-<name>-watch` DNS does NOT resolve from inside an agent pod, so the
//     live ClusterIP is resolved from `kubectl get services -n default` on the
//     host bridge and the ClusterIP is GET directly.
//   * sibling transcripts live on the data volume, which is mounted into BOTH
//     containers of the pair:
//       Letta planner  (app=sudo-letta): /home/node/.letta/watch/transcript.txt
//       Hermes engineer(app=sudo-agent): /opt/data/watch/transcript.txt
//
// Every host read goes through the docker-socket + nsenter bridge with the
// argv passed as an ARRAY to spawn (no shell), so there is no quoting surface.

import { spawn } from "node:child_process";

// --- the host bridge: docker -> host namespaces -> host kubectl ------------

const BRIDGE_CMD = "docker";
const NSENTER_ARGS = [
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
];

const DEFAULT_DEPTH = 100;
const DEFAULT_PORT = 8000;
const HOST_TIMEOUT_MS = 45000;
const HTTP_TIMEOUT_MS = 20000;

const LETTA_TRANSCRIPT = "/home/node/.letta/watch/transcript.txt";
const HERMES_TRANSCRIPT = "/opt/data/watch/transcript.txt";
const HERMES_TRANSCRIPT_ALT = "/home/node/.hermes/transcript.txt";

/** Run one host command through the bridge. Always resolves, never throws. */
function runHost(argv, timeoutMs = HOST_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(BRIDGE_CMD, [...NSENTER_ARGS, ...argv], { stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve({ ok: false, error: error && error.message ? error.message : String(error), stdout: "", stderr: "" });
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
      finish({ ok: false, error: `host bridge timed out after ${timeoutMs}ms`, stdout, stderr });
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish({ ok: false, error: error && error.message ? error.message : String(error), stdout, stderr });
    });
    child.on("close", (code) => {
      finish({ ok: code === 0, code, stdout, stderr });
    });
  });
}

/** GET a URL over HTTP and return its body as text. Never throws. */
async function httpGetText(url, timeoutMs = HTTP_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: { accept: "application/x-ndjson, application/json, text/plain, */*" },
    });
    const text = await res.text();
    return { ok: res.ok, status: res.status, text };
  } catch (error) {
    return { ok: false, error: error && error.message ? error.message : String(error) };
  } finally {
    clearTimeout(timer);
  }
}

// --- roster + resolution ---------------------------------------------------

/**
 * Parse `kubectl get services -n default` into paired sibling entries.
 *
 * Columns: NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE. Only services named
 * `sudo-<bare>-mcp` / `sudo-<bare>-watch` pair up, so the header, `kubernetes`,
 * `sudo-*-redis` and `sudo-*-svc` drop out by construction. Exactly ONE
 * leading `sudo-` and ONE trailing `-mcp`/`-watch` are stripped.
 */
function parseServices(text) {
  const byBare = new Map();

  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const columns = line.split(/\s+/);
    const name = columns[0];
    if (!name || name === "NAME") continue;

    const match = /^sudo-(.+)-(mcp|watch)$/.exec(name);
    if (!match) continue;

    const bare = match[1];
    const facet = match[2];

    const clusterIp = columns[2] ?? "";
    const portsColumn = columns[4] ?? "";
    const portMatch = /(\d+)\/TCP/.exec(portsColumn);
    const port = portMatch ? Number(portMatch[1]) : DEFAULT_PORT;

    if (!byBare.has(bare)) {
      byBare.set(bare, { sibling: bare, mcp_service: `sudo-${bare}-mcp`, watch_service: `sudo-${bare}-watch` });
    }
    const entry = byBare.get(bare);
    if (clusterIp && clusterIp !== "<none>") {
      entry[facet === "mcp" ? "mcp_host" : "watch_host"] = `${clusterIp}:${port}`;
    }
  }

  return [...byBare.values()]
    .filter((entry) => entry.mcp_host && entry.watch_host)
    .sort((a, b) => a.sibling.localeCompare(b.sibling));
}

class SiblingNotFound extends Error {
  constructor(name) {
    super(`sibling not found: ${name}`);
    this.name = "SiblingNotFound";
  }
}

class AmbiguousSibling extends Error {
  constructor(candidates) {
    super(`ambiguous sibling name; candidates: ${candidates.join(", ")}`);
    this.name = "AmbiguousSibling";
    this.candidates = candidates;
  }
}

/** Resolve a bare name: exact -> case-insensitive -> unique substring. */
function resolveSibling(roster, name) {
  const wanted = String(name).trim();

  const exact = roster.filter((entry) => entry.sibling === wanted);
  if (exact.length === 1) return exact[0];

  const ci = roster.filter((entry) => entry.sibling.toLowerCase() === wanted.toLowerCase());
  if (ci.length === 1) return ci[0];

  const lowered = wanted.toLowerCase();
  const subs = roster.filter((entry) => entry.sibling.toLowerCase().includes(lowered));
  if (subs.length === 1) return subs[0];
  if (subs.length > 1) throw new AmbiguousSibling(subs.map((entry) => entry.sibling));

  throw new SiblingNotFound(wanted);
}

/** Which flavour of agent the sibling is: "letta" (planner) or "hermes". */
async function siblingKind(bare) {
  const deploy = `sudo-${bare}`;

  const byLabel = await runHost(["kubectl", "get", "deploy", deploy, "-o", "jsonpath={.metadata.labels.app}"]);
  const app = (byLabel.stdout || "").trim();
  if (app === "sudo-agent") return "hermes";
  if (app === "sudo-letta") return "letta";

  const byContainer = await runHost([
    "kubectl", "get", "deploy", deploy, "-o", "jsonpath={.spec.template.spec.containers[0].name}",
  ]);
  const first = (byContainer.stdout || "").trim();
  if (first === "sudo-agent") return "hermes";
  if (first === "sudo-letta") return "letta";

  // The fleet's default planner flavour.
  return "letta";
}

function transcriptPathsFor(kind) {
  return kind === "hermes" ? [HERMES_TRANSCRIPT, HERMES_TRANSCRIPT_ALT, LETTA_TRANSCRIPT] : [LETTA_TRANSCRIPT, HERMES_TRANSCRIPT];
}

// --- the tool --------------------------------------------------------------

function errorResult(content) {
  return { status: "error", content };
}

const DESCRIPTION =
  "Read a sibling agent's trail — the ONE observability read that answers both " +
  "\"what has it been doing\" and \"what is it doing right now\". " +
  "mode=\"full\" (default) returns the sibling's raw event stream over HTTP " +
  "(GET http://<watch>/events?n=N): every user/thinking/assistant/tool_call/tool_result/session/process_state " +
  "event as ndjson (one JSON object per line). " +
  "mode=\"compressed\" returns its plain chat transcript instead (real prompts and replies only, read from " +
  "transcript.txt via kubectl exec): no thinking, tool calls, sessions or reminders. " +
  "n sets the trailing depth identically in both modes: k>0 = the last k entries, n=-1 = the ENTIRE file, " +
  "omitted = 100. The sibling name is resolved live against the cluster (exact, then case-insensitive, " +
  "then unique substring). Use this before messaging a sibling, or to see what it is doing right now.";

export default function activate(letta) {
  if (!letta.capabilities.tools) return;

  return letta.tools.register({
    name: "check_agent",
    description: DESCRIPTION,
    parameters: {
      type: "object",
      properties: {
        sibling: {
          type: "string",
          description:
            "The sibling agent to read, by bare name (e.g. \"fa-glm-l\", \"mail-bot-letta\", \"psnvc\"). Resolved live: exact match, then case-insensitive, then unique substring.",
        },
        n: {
          type: "integer",
          description:
            "Trailing depth. A positive k returns the last k entries; -1 returns the ENTIRE file with no depth cap; omit for the default depth of 100. Same meaning in both modes.",
        },
        mode: {
          type: "string",
          enum: ["full", "compressed"],
          description:
            "\"full\" (default) = the raw event trail (thinking, tool calls/results, sessions, process states). \"compressed\" = the plain chat transcript only (You:/Agent: lines).",
        },
      },
      required: ["sibling"],
      additionalProperties: false,
    },
    requiresApproval: false,
    parallelSafe: true,
    async run(ctx) {
      const args = (ctx && ctx.args) || {};

      // --- inputs ---
      const rawSibling = args.sibling;
      if (typeof rawSibling !== "string" || !rawSibling.trim()) {
        return errorResult("check_agent requires a non-empty `sibling` name (e.g. \"fa-glm-l\").");
      }
      const sibling = rawSibling.trim();

      const rawMode = args.mode;
      if (rawMode !== undefined && rawMode !== null && rawMode !== "full" && rawMode !== "compressed") {
        return errorResult(`unknown mode ${JSON.stringify(rawMode)}; use "full" (default) or "compressed".`);
      }
      const mode = rawMode === "compressed" ? "compressed" : "full";

      let n;
      if (args.n === undefined || args.n === null) {
        n = undefined;
      } else {
        const parsed = typeof args.n === "number" ? args.n : Number(args.n);
        if (!Number.isInteger(parsed)) {
          return errorResult(`n must be an integer (positive = trailing entries; -1 = the entire file); got ${JSON.stringify(args.n)}.`);
        }
        if (parsed !== -1 && parsed <= 0) {
          return errorResult(`n must be a positive integer or -1 (the entire file); got ${parsed}.`);
        }
        n = parsed;
      }

      // --- resolve the sibling against the live roster ---
      const services = await runHost(["kubectl", "get", "services", "-n", "default"]);
      if (!services.ok) {
        const detail = (services.stderr || services.error || "").trim().slice(0, 1500);
        return errorResult(`check_agent could not read the fleet roster: ${detail || "unknown error"}`);
      }

      let entry;
      try {
        entry = resolveSibling(parseServices(services.stdout), sibling);
      } catch (error) {
        if (error instanceof SiblingNotFound) {
          return errorResult(`sibling not found: "${sibling}". No sudo-<name>-mcp/-watch pair matches that name.`);
        }
        if (error instanceof AmbiguousSibling) {
          return errorResult(`ambiguous sibling name "${sibling}"; candidates: ${error.candidates.join(", ")}. Use a longer, unique name.`);
        }
        return errorResult(`could not resolve sibling "${sibling}": ${error && error.message ? error.message : String(error)}`);
      }

      // --- compressed: read the transcript file directly ---
      if (mode === "compressed") {
        const kind = await siblingKind(entry.sibling);
        const candidates = transcriptPathsFor(kind);
        const deploy = `deploy/sudo-${entry.sibling}`;
        const depth = n === undefined ? DEFAULT_DEPTH : n;

        const failures = [];
        for (const path of candidates) {
          const tailArgs = n === -1
            ? ["cat", path]
            : ["tail", "-n", String(depth), path];
          const result = await runHost(["kubectl", "exec", deploy, "-c", "watch", "--", ...tailArgs]);
          if (result.ok) {
            const text = String(result.stdout || "").replace(/\s+$/, "");
            if (!text) {
              return `sibling ${entry.sibling} (${kind}): transcript ${path} is empty.`;
            }
            return text;
          }
          failures.push(`${path}: ${(result.stderr || result.error || "").trim().split("\n")[0].slice(0, 200)}`);
        }

        return errorResult(
          `could not read the ${kind} transcript of sibling "${entry.sibling}" via kubectl exec ${deploy} -c watch:\n` +
            failures.join("\n"),
        );
      }

      // --- full: GET the -watch sidecar's event tap ---
      const url = n === undefined
        ? `http://${entry.watch_host}/events`
        : `http://${entry.watch_host}/events?n=${n}`;

      const res = await httpGetText(url);
      if (!res.ok) {
        const detail = (res.error || `HTTP ${res.status}`).trim().slice(0, 1500);
        return errorResult(`check_agent could not read ${entry.watch_service} (GET ${url}): ${detail}`);
      }

      const text = String(res.text || "").replace(/\s+$/, "");
      if (!text) return `sibling ${entry.sibling}: no events (GET ${url}).`;
      return text;
    },
  });
}

export const __test = {
  NSENTER_ARGS,
  LETTA_TRANSCRIPT,
  HERMES_TRANSCRIPT,
  runHost,
  httpGetText,
  parseServices,
  resolveSibling,
  siblingKind,
  transcriptPathsFor,
};
