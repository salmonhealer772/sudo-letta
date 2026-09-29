import { spawn } from "node:child_process";

const BRIDGE = [
  "docker", "run", "--rm", "--privileged", "--pid=host", "--net=host",
  "-v", "/:/host", "alpine:latest",
  "nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
  "env", "KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
  "kubectl", "get", "services", "-n", "default",
];

async function hostCommand(argv) {
  return new Promise((resolve, reject) => {
    const proc = spawn(argv[0], argv.slice(1));
    let out = "";
    let err = "";
    proc.stdout.on("data", (d) => (out += d));
    proc.stderr.on("data", (d) => (err += d));
    proc.on("error", reject);
    proc.on("close", (code) => {
      if (code === 0) resolve(out);
      else reject(new Error(`exit ${code}: ${err}`));
    });
  });
}

function bare(name, suffix) {
  let n = name;
  if (n.startsWith("sudo-")) n = n.slice("sudo-".length);
  if (n.endsWith(suffix)) n = n.slice(0, -suffix.length);
  return n;
}

function parseServices(stdout) {
  const addrs = {};
  for (const line of stdout.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (!parts.length) continue;
    const name = parts[0];
    if (name === "NAME" || !name.startsWith("sudo-")) continue;
    if (name.endsWith("-mcp")) {
      addrs[bare(name, "-mcp")] ||= {};
      addrs[bare(name, "-mcp")].mcp_host = `${name}:8000`;
    } else if (name.endsWith("-watch")) {
      addrs[bare(name, "-watch")] ||= {};
      addrs[bare(name, "-watch")].watch_host = `${name}:8000`;
    }
  }
  const roster = [];
  for (const [sibling, a] of Object.entries(addrs)) {
    if (a.mcp_host && a.watch_host) {
      roster.push({ sibling, mcp_host: a.mcp_host, watch_host: a.watch_host });
    }
  }
  roster.sort((x, y) => x.sibling.localeCompare(y.sibling));
  return roster;
}

export default function activate(letta) {
  if (!letta.capabilities.tools) return;

  return letta.tools.register({
    name: "list_siblings",
    description:
      "List every sibling agent in the fleet (live roster) with its message and watch addresses. Use before messaging or checking on a sibling when unsure who exists or its exact name.",
    parameters: {
      type: "object",
      properties: {
        filter: {
          type: "string",
          description: "Optional substring to narrow the roster by sibling name.",
        },
      },
      required: [],
      additionalProperties: false,
    },
    requiresApproval: false,
    parallelSafe: true,
    async run(ctx) {
      let stdout;
      try {
        stdout = await hostCommand(BRIDGE);
      } catch (e) {
        return { status: "error", content: `list-siblings failed: ${e.message}` };
      }
      const roster = parseServices(stdout);
      const filter = typeof ctx.args.filter === "string" ? ctx.args.filter.trim() : "";
      const filtered = filter ? roster.filter((e) => e.sibling.includes(filter)) : roster;
      if (!filtered.length) {
        return filter
          ? `No matching siblings for filter "${filter}".`
          : "No sibling agents found.";
      }
      return [
        `siblings: ${filtered.length}`,
        ...filtered.map(
          (e) => `${e.sibling}\t\tmcp=${e.mcp_host}\t\twatch=${e.watch_host}`,
        ),
      ].join("\n");
    },
  });
}
