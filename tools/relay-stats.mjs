// Reads the relay's heartbeat off Railway and writes site/data/stats.json,
// and the GitHub release list into site/data/releases.json.
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
// The release list is written here too, so the landing page has a copy of
// its own to draw from. It used to ask the GitHub API from the viewer's
// browser and nothing else, and a browser holding onto an old answer showed
// a history days out of date under a header that was current.
//
// Env: RAILWAY_TOKEN (account/workspace scope) or RAILWAY_PROJECT_TOKEN
//      (single environment, least privilege). One or the other.
//      GITHUB_TOKEN, optional: the Actions token keeps the release call off
//      the unauthenticated 60/hour limit.

import { writeFileSync, readFileSync, existsSync } from "node:fs";

const API = "https://backboard.railway.com/graphql/v2";
const PROJECT = "34e1da0b-5125-40be-9954-d90fafa3e156";
const SERVICE = "c115d029-c86b-4e7f-9a7b-e77fb41fce4b";
const ENVIRONMENT = "7e9c2775-9d8f-442a-ab1a-fbe8255d4dda";
const OUT = "site/data/stats.json";
const RELEASES = "site/data/releases.json";
const REPO = "campavao/kanto-battle-royale";

const account = process.env.RAILWAY_TOKEN;
const project = process.env.RAILWAY_PROJECT_TOKEN;
if (!account && !project) {
  console.error("no token: set RAILWAY_TOKEN or RAILWAY_PROJECT_TOKEN");
  process.exit(1);
}
const auth = project
  ? { "Project-Access-Token": project }
  : { Authorization: `Bearer ${account}` };

function readJson(path, fallback) {
  try { return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : fallback; }
  catch { return fallback; }
}
const previous = readJson(OUT, {});

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
//
// Every push to this repo makes another SKIPPED deployment (the watch paths
// keep the relay from rebuilding, but Railway still records the push), so a
// busy few days can walk the live one out of any fixed window -- twenty
// pushes did exactly that after the Aug 31 deploy and this failed on every
// run. The last stats file names the process it read, and a NEW relay
// deploy would be a SUCCESS inside the window, so falling back to that id
// can only ever pick the process that is still running.
async function liveDeployment() {
  const data = await gql(
    `query($input: DeploymentListInput!) {
       deployments(input: $input, first: 100) {
         edges { node { id status createdAt } }
       }
     }`,
    { input: { projectId: PROJECT, serviceId: SERVICE } }
  );
  const nodes = (data?.deployments?.edges || []).map(e => e.node);
  const live = nodes
    .filter(n => n.status === "SUCCESS")
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  if (live) return live;
  if (previous.deploymentId) {
    console.log(`no SUCCESS deployment in the last ${nodes.length}; ` +
                `reusing ${previous.deploymentId} from ${OUT}`);
    return { id: previous.deploymentId, createdAt: previous.deployedAt, status: "SUCCESS" };
  }
  throw new Error(`no SUCCESS deployment in the last ${nodes.length}: ` +
                  nodes.map(n => n.status).join(", "));
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

// The same shape the page builds from the API itself, so either source
// draws the same. Drafts only appear to an authenticated call; skip them.
async function releases() {
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  const r = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "kbr-relay-stats",
      ...(token ? { Authorization: `Bearer ${token}` } : {})
    }
  });
  if (!r.ok) throw new Error(`${r.status} from GitHub releases`);
  return (await r.json())
    .filter(x => !x.draft)
    .map(x => ({
      tag: x.tag_name,
      name: (x.name || "").replace(/^v[\d.]+\s*[—–-]\s*/, ""),
      at: x.published_at,
      dl: (x.assets || []).reduce((n, a) => n + a.download_count, 0)
    }));
}

// --- the heartbeat -------------------------------------------------------

const deployment = await liveDeployment();
const line = await heartbeat(deployment.id);
let moved = false;
if (!line) {
  // Under ~5 minutes old the deployment has not printed one yet. Leaving the
  // last good file in place beats overwriting it with nothing.
  console.log("no heartbeat in this deployment yet; leaving stats.json alone");
} else {
  const stats = {
    ...parse(line.message),
    deployedAt: deployment.createdAt,
    deploymentId: deployment.id,
    readAt: new Date().toISOString()
  };

  // Counters are in-process and reset on every deploy, so peak is always
  // "since deployedAt", never all-time. The page says so rather than implying
  // otherwise. Compare the counters only. `at` is the heartbeat's own
  // timestamp and moves every five minutes whether or not anything happened
  // -- including it here would commit on every run and bury the repo in
  // noise. So the stored `at` is the last time these numbers were actually
  // true, which is the more useful reading anyway, and the page labels it
  // that way.
  moved = !["rooms", "conns", "peakRooms", "peakConns", "statSeen", "statSolo", "lines"]
    .every(k => previous[k] === stats[k]);
  if (moved) {
    writeFileSync(OUT, JSON.stringify(stats, null, 2) + "\n");
    console.log("wrote", OUT, JSON.stringify(stats));
  } else {
    console.log("heartbeat unchanged; no commit");
  }
}

// --- the releases --------------------------------------------------------
//
// Download counts tick whenever anyone (or anything) fetches a zip, so
// committing every change would mean a commit and a Pages deploy every
// quarter hour. A new tag is written the run it appears; the counts ride
// along whenever the relay numbers are being committed anyway, and the page
// draws the live API over this copy when it can reach it.

let list = null;
try { list = await releases(); }
catch (e) { console.log(`releases: ${e.message}; leaving ${RELEASES} alone`); }
if (list) {
  const before = readJson(RELEASES, {});
  const tags = l => (l || []).map(r => r.tag).join(" ");
  const newTag = tags(before.list) !== tags(list);
  if (newTag || moved || !existsSync(RELEASES)) {
    writeFileSync(RELEASES, JSON.stringify({ readAt: new Date().toISOString(), list }, null, 2) + "\n");
    console.log("wrote", RELEASES, `${list.length} releases` + (newTag ? " (new tag)" : ""));
  } else {
    console.log("releases: no new tag; counts ride the next relay commit");
  }
}
