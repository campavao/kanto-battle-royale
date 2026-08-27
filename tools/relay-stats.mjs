// Reads the relay's heartbeat off Railway and writes site/data/stats.json.
//
// The relay is a raw TCP server with no HTTP surface, so nothing can ask it
// how it is doing. What it does have is one log line every five minutes:
//
//   rooms 0/40 conns 0/200 | sent 1.7MB in 19919 lines | peak 2 rooms 2 conns | stats 20 (solo 1)
//
// That is the whole signal. This scrapes it from outside rather than adding
// an endpoint, because deploying the relay kills every live match -- there is
// no SIGTERM handler, so Node exits instantly and every socket dies.
//
// Env: RAILWAY_TOKEN (account/workspace scope) or RAILWAY_PROJECT_TOKEN
//      (single environment, least privilege). One or the other.

import { writeFileSync, readFileSync, existsSync } from "node:fs";

const API = "https://backboard.railway.com/graphql/v2";
const PROJECT = "34e1da0b-5125-40be-9954-d90fafa3e156";
const SERVICE = "c115d029-c86b-4e7f-9a7b-e77fb41fce4b";
const ENVIRONMENT = "7e9c2775-9d8f-442a-ab1a-fbe8255d4dda";
const OUT = "site/data/stats.json";

const account = process.env.RAILWAY_TOKEN;
const project = process.env.RAILWAY_PROJECT_TOKEN;
if (!account && !project) {
  console.error("no token: set RAILWAY_TOKEN or RAILWAY_PROJECT_TOKEN");
  process.exit(1);
}
const auth = project
  ? { "Project-Access-Token": project }
  : { Authorization: `Bearer ${account}` };

async function gql(query, variables) {
  const r = await fetch(API, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...auth },
    body: JSON.stringify({ query, variables })
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${r.status} from Railway: ${text.slice(0, 400)}`);
  let body;
  try { body = JSON.parse(text); }
  catch { throw new Error(`Railway sent non-JSON: ${text.slice(0, 400)}`); }
  if (body.errors) throw new Error(`Railway rejected the query: ${JSON.stringify(body.errors).slice(0, 400)}`);
  return body.data;
}

// A SKIPPED deployment becomes the "latest" one and carries no logs, so
// asking for the latest deployment returns an empty list that reads exactly
// like an idle relay. Resolve the newest SUCCESS instead.
//
// DeploymentListInput takes projectId and serviceId only -- an environmentId
// or a status filter in there is a 400. Sort and filter here instead.
async function liveDeployment() {
  const data = await gql(
    `query($input: DeploymentListInput!) {
       deployments(input: $input, first: 20) {
         edges { node { id status createdAt } }
       }
     }`,
    { input: { projectId: PROJECT, serviceId: SERVICE } }
  );
  const nodes = (data?.deployments?.edges || []).map(e => e.node);
  const live = nodes
    .filter(n => n.status === "SUCCESS")
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  if (!live) {
    throw new Error(`no SUCCESS deployment in the last ${nodes.length}: ` +
                    nodes.map(n => n.status).join(", "));
  }
  return live;
}

// deploymentLogs takes deploymentId and limit only. There is no server-side
// filter argument, so pull a window and match the heartbeat here.
async function heartbeat(deploymentId) {
  const data = await gql(
    `query($deploymentId: String!, $limit: Int) {
       deploymentLogs(deploymentId: $deploymentId, limit: $limit) {
         timestamp message
       }
     }`,
    { deploymentId, limit: 500 }
  );
  const lines = (data?.deploymentLogs || []).filter(l => /\bpeak \d+ rooms/.test(l.message));
  if (!lines.length) return null;
  return lines[lines.length - 1];
}

function parse(message) {
  const one = (re, ...names) => {
    const m = message.match(re);
    if (!m) return {};
    return Object.fromEntries(names.map((n, i) => [n, Number(m[i + 1])]));
  };
  const stamp = message.match(/^(\S+Z)/);
  const sent = message.match(/sent (\S+) in (\d+) lines/);
  return {
    at: stamp ? stamp[1] : null,
    ...one(/rooms (\d+)\/(\d+)/, "rooms", "roomCap"),
    ...one(/conns (\d+)\/(\d+)/, "conns", "connCap"),
    ...one(/peak (\d+) rooms (\d+) conns/, "peakRooms", "peakConns"),
    ...one(/stats (\d+) \(solo (\d+)\)/, "statSeen", "statSolo"),
    ...one(/refused (\d+)/, "refused"),
    sent: sent ? sent[1] : null,
    lines: sent ? Number(sent[2]) : null
  };
}

const deployment = await liveDeployment();
const line = await heartbeat(deployment.id);
if (!line) {
  // Under ~5 minutes old the deployment has not printed one yet. Leaving the
  // last good file in place beats overwriting it with nothing.
  console.log("no heartbeat in this deployment yet; leaving stats.json alone");
  process.exit(0);
}

const stats = {
  ...parse(line.message),
  deployedAt: deployment.createdAt,
  deploymentId: deployment.id,
  readAt: new Date().toISOString()
};

// Counters are in-process and reset on every deploy, so peak is always "since
// deployedAt", never all-time. The page says so rather than implying otherwise.
// Compare the counters only. `at` is the heartbeat's own timestamp and moves
// every five minutes whether or not anything happened -- including it here
// would commit on every run and bury the repo in noise. So the stored `at` is
// the last time these numbers were actually true, which is the more useful
// reading anyway, and the page labels it that way.
const previous = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};
const same = ["rooms", "conns", "peakRooms", "peakConns", "statSeen", "statSolo", "lines"]
  .every(k => previous[k] === stats[k]);

if (same) {
  console.log("heartbeat unchanged; no commit");
  process.exit(0);
}

writeFileSync(OUT, JSON.stringify(stats, null, 2) + "\n");
console.log("wrote", OUT, JSON.stringify(stats));
