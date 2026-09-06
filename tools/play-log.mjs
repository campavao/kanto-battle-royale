// Turns the relay's event lines into a durable play history for the site.
//
// relay-stats.mjs reads the heartbeat: one snapshot every five minutes, and
// counters that reset with every deploy. That answers "is anybody on right
// now" and nothing about last Tuesday. The relay also writes one line per
// thing that happens -- a room hosted, a join, a stat check-in, a drop with
// a census of what that connection sent -- and those lines are the whole
// record of who played what, when, and with whom. Railway keeps them for a
// few weeks and then they are gone, so this pulls them every run and keeps
// what it has parsed in site/data/events.json for good.
//
//   site/data/events.json   every parsed line, deduplicated, append-only
//   site/data/play.json     what the page draws: sessions, installs, solo
//                           reports, quick-play bounces
//
// What a line tells us (relay/server.js is the source of each):
//
//   room CODE hosted by NAME#ID (open|daily)     a room opened; the flag is
//                                                 its door, not the mode yet
//   room CODE: NAME#ID joined|quick-joined|joined the daily|spectates|left
//   room CODE: host NAME#ID left, NAME#ID promoted
//   room CODE closed (reason, no heir)
//   drop NAME#ID [room CODE] (reason) after Ns | in quick_joinx1 host_roomx1 lock_roomx3 ...
//   stat ID vVER | solo +N | since DATE
//
// The drop line's census is what names the mode. Quick play that finds an
// open room sends quick_join and lands; quick play that finds nothing hosts
// its own open room on the same connection, so its host shows
// `quick_joinx1 host_roomx1`; HOST from the lobby is `host_roomx1` alone;
// the daily is `daily_joinx1`; JOIN by code is `join_roomx1`. lock_room is
// sent once at every match start and once more when the room is kept at
// match end, so ceil(lock_room / 2) is that connection's match count.
//
// Nothing personal lands in the files. A trainer name is only needed to
// pair a drop line with the room that connection sat in, and a short hash
// of it does that just as well, so that is what is kept; install ids are
// hashed the same way, so an install can be counted across days without
// its wire id being on a public page.
//
// Env: RAILWAY_TOKEN or RAILWAY_PROJECT_TOKEN, as relay-stats.mjs.

import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";

const API = "https://backboard.railway.com/graphql/v2";
const PROJECT = "34e1da0b-5125-40be-9954-d90fafa3e156";
const SERVICE = "c115d029-c86b-4e7f-9a7b-e77fb41fce4b";
const EVENTS = "site/data/events.json";
const PLAY = "site/data/play.json";

// How far back a deployment's logs are worth asking for. Railway's retention
// is longer than this in practice, and the incremental fetch covers the live
// process anyway; this bounds the one-time sweep of dead ones.
const SWEEP_DAYS = 45;
// The incremental window overlaps the last thing seen by this much, so a
// line that was late reaching Railway is still collected.
const OVERLAP_MS = 2 * 60 * 60 * 1000;
const LIMIT = 500;

// Resolved in main(), so the parser can be imported by the tests without a
// token in the environment.
let auth = null;
function authHeaders() {
  if (auth) return auth;
  const account = process.env.RAILWAY_TOKEN;
  const project = process.env.RAILWAY_PROJECT_TOKEN;
  if (!account && !project) {
    console.error("no token: set RAILWAY_TOKEN or RAILWAY_PROJECT_TOKEN");
    process.exit(1);
  }
  auth = project
    ? { "Project-Access-Token": project }
    : { Authorization: `Bearer ${account}` };
  return auth;
}

function readJson(path, fallback) {
  try { return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : fallback; }
  catch { return fallback; }
}

async function gql(query, variables) {
  const r = await fetch(API, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
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

// --- fetching ------------------------------------------------------------

async function deployments() {
  const data = await gql(
    `query($input: DeploymentListInput!) {
       deployments(input: $input, first: 100) {
         edges { node { id status createdAt } }
       }
     }`,
    { input: { projectId: PROJECT, serviceId: SERVICE } }
  );
  return (data?.deployments?.edges || []).map(e => e.node)
    .filter(n => n.status === "SUCCESS" || n.status === "REMOVED" || n.status === "CRASHED")
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
}

// deploymentLogs answers with the NEWEST `limit` lines inside the window, so
// a window with more than that is walked backwards: ask again with the end
// moved to just before the oldest line that came back. The heartbeat is
// filtered out on the server side; it is relay-stats.mjs's business and
// three of them an hour would crowd the window for nothing.
async function lines(deploymentId, start, end) {
  const out = [];
  let endDate = end;
  for (let page = 0; page < 40; page++) {
    const data = await gql(
      `query($id: String!, $limit: Int, $filter: String, $startDate: DateTime, $endDate: DateTime) {
         deploymentLogs(deploymentId: $id, limit: $limit, filter: $filter,
                        startDate: $startDate, endDate: $endDate) {
           timestamp message
         }
       }`,
      { id: deploymentId, limit: LIMIT, filter: '-"| sent "',
        startDate: start.toISOString(), endDate: endDate.toISOString() }
    );
    const got = data?.deploymentLogs || [];
    out.push(...got);
    if (got.length < LIMIT) break;
    const oldest = got.reduce((m, l) => l.timestamp < m ? l.timestamp : m, got[0].timestamp);
    const next = new Date(new Date(oldest).getTime() - 1);
    if (!(next < endDate)) break;
    endDate = next;
  }
  return out;
}

// --- parsing -------------------------------------------------------------
//
// One event per line, or null for lines that say nothing about play (the
// container starting, a refused connection, an open socket that has no
// name yet). `t` is the relay's own clock, from the message, because
// Railway's timestamp is when the line reached it and lines arrive in
// bursts seconds later.

const NAME = "([^#\\s]{1,10})#(\\d+|-)";
// `who` is what pairs a drop with a room: the name the relay logged, hashed
// to four characters, plus the connection's number in that room.
const who = (name, id) =>
  createHash("sha256").update("kbr-name:" + name).digest("hex").slice(0, 4) + "#" + id;
const hashId = id => createHash("sha256").update("kbr:" + id).digest("hex").slice(0, 8);

function census(text) {
  const out = {};
  for (const m of text.matchAll(/([a-z_]+)x(\d+)/g)) out[m[1]] = Number(m[2]);
  return out;
}

export function parseLine(message, fallbackAt) {
  const stamp = message.match(/^(\d{4}-\d\d-\d\dT[\d:.]+Z) (.*)$/);
  const t = stamp ? stamp[1] : fallbackAt;
  const body = stamp ? stamp[2] : message;
  let m;

  if ((m = body.match(new RegExp(`^room ([A-Z0-9]+) hosted by ${NAME}(?: \\((open|daily)\\))?$`))))
    return { t, kind: "host", code: m[1], who: who(m[2], m[3]), door: m[4] || "private" };

  if ((m = body.match(new RegExp(`^room ([A-Z0-9]+): ${NAME} (joined the daily|quick-joined|joined|spectates|left)$`)))) {
    const how = { "joined the daily": "daily", "quick-joined": "quick", joined: "code",
                  spectates: "spectate", left: "left" }[m[4]];
    return { t, kind: how === "left" ? "left" : "join", code: m[1], who: who(m[2], m[3]), how };
  }

  if ((m = body.match(new RegExp(`^room ([A-Z0-9]+): host ${NAME} left, ${NAME} promoted$`))))
    return { t, kind: "promote", code: m[1], who: who(m[2], m[3]), heir: who(m[4], m[5]) };

  if ((m = body.match(/^room ([A-Z0-9]+) closed \(([a-z_]+)/)))
    return { t, kind: "close", code: m[1], why: m[2] };

  if ((m = body.match(new RegExp(`^drop ${NAME}(?: room ([A-Z0-9]+))? \\(([a-z_]+)\\) after (\\d+)s \\| in (.*?) \\| headroom`)))) {
    return { t, kind: "drop", who: who(m[1], m[2]), code: m[3] || null, why: m[4],
             secs: Number(m[5]), sent: census(m[6]) };
  }

  if ((m = body.match(/^stat ([0-9a-f]{1,32}) v(\S+) \| solo \+(\d+) \| since (\S+)$/)))
    return { t, kind: "stat", install: hashId(m[1]), v: m[2], solo: Number(m[3]), since: m[4] };

  if ((m = body.match(/^room ([A-Z0-9]+) is now (open|private)$/)))
    return { t, kind: "door", code: m[1], door: m[2] };

  if ((m = body.match(/^room ([A-Z0-9]+) seats (\d+)$/)))
    return { t, kind: "seats", code: m[1], max: Number(m[2]) };

  if ((m = body.match(new RegExp(`^room ([A-Z0-9]+): ${NAME} removed by host$`))))
    return { t, kind: "left", code: m[1], who: who(m[2], m[3]), how: "kicked" };

  return null;
}

const key = ev => [ev.t, ev.kind, ev.code || "", ev.who || ev.install || "", ev.why || ev.how || ""].join("|");

// --- sessions ------------------------------------------------------------
//
// Replay the events in order and keep one record per room. Mode is settled
// by the host's drop census; until then a room is "open" or "private".

function modeOf(sent, door) {
  if (sent.daily_join) return "daily";
  if (sent.quick_join) return "quick";
  if (sent.host_room) return "host";
  return door === "daily" ? "daily" : "host";
}

export function derive(events) {
  const sorted = events.slice().sort((a, b) => a.t < b.t ? -1 : a.t > b.t ? 1 : 0);
  const rooms = new Map();          // code -> session under construction
  const closed = new Map();         // code -> session, for a drop logged after the close
  const sessions = [];
  const byWho = new Map();          // NAME#ID -> code of the open room it sits in
  const installs = new Map();       // hash -> record
  const solo = [];
  const bounces = [];
  let lastSeat = null;              // the host/join just before a stat line

  const seat = (code, who) => { byWho.set(who, code); };

  // lock_room is sent by whoever is host at the time -- the opener, or an
  // heir after a migration -- once at each start and once at each kept
  // end, so the room's matches come from the room's total, not a conn's.
  const settle = (s) => {
    s.matches = Math.ceil(s.locks / 2);
    if (s.mode === "open" || s.mode === "private") s.mode = s.door === "daily" ? "daily" : "host";
  };
  const finish = (s, at) => {
    s.end = at;
    s.secs = Math.max(0, Math.round((new Date(at) - new Date(s.at)) / 1000));
    settle(s);
  };

  for (const ev of sorted) {
    switch (ev.kind) {
      case "host": {
        const s = { code: ev.code, at: ev.t, end: null, secs: null,
                    door: ev.door, mode: ev.door === "daily" ? "daily" : ev.door,
                    humans: 1, together: 1, spectators: 0, matches: 0, locks: 0,
                    joins: [], versions: [], installs: [], members: new Map(),
                    opener: ev.who };
        s.members.set(ev.who, { spectator: false, in: true });
        rooms.set(ev.code, s);
        seat(ev.code, ev.who);
        lastSeat = { code: ev.code, t: ev.t };
        break;
      }
      case "join": {
        const s = rooms.get(ev.code);
        if (!s) break;
        const spectator = ev.how === "spectate";
        s.members.set(ev.who, { spectator, in: true });
        seat(ev.code, ev.who);
        s.joins.push({ t: ev.t, how: ev.how });
        if (spectator) s.spectators += 1;
        else {
          s.humans = [...s.members.values()].filter(m => !m.spectator).length;
          const now = [...s.members.values()].filter(m => !m.spectator && m.in).length;
          s.together = Math.max(s.together, now);
        }
        lastSeat = { code: ev.code, t: ev.t };
        break;
      }
      case "left": {
        // stays seated in byWho: the drop that follows a leave has no room
        // on it, and it is the line that carries the census
        const s = rooms.get(ev.code);
        if (!s) break;
        const m = s.members.get(ev.who);
        if (m) m.in = false;
        break;
      }
      case "promote": {
        const s = rooms.get(ev.code);
        if (!s) break;
        const m = s.members.get(ev.who);
        if (m) m.in = false;
        s.migrated = (s.migrated || 0) + 1;
        break;
      }
      case "drop": {
        const code = ev.code || byWho.get(ev.who);
        const s = code && (rooms.get(code) || closed.get(code));
        if (s) {
          const m = s.members.get(ev.who);
          if (m) m.in = false;
          s.locks += ev.sent.lock_room || 0;
          // the room's opener names the mode; a promoted heir does not,
          // and neither does the fallback `settle` picked before this
          // drop was logged
          if (ev.who === s.opener) s.mode = modeOf(ev.sent, s.door);
          if (s.end) settle(s);
        } else if (ev.who.endsWith("#-")) {
          // a connection gets its number on entering a room, so `#-` never
          // sat in one: a quick play that was offered a running match and
          // declined it, a daily press outside its hour, or a socket that
          // said nothing and was reaped
          const tried = ev.sent.quick_join ? "quick" : ev.sent.daily_join ? "daily"
                      : ev.sent.join_room ? "code" : null;
          if (tried) bounces.push({ t: ev.t, tried, secs: ev.secs });
        }
        break;
      }
      case "close": {
        const s = rooms.get(ev.code);
        if (!s) break;
        finish(s, ev.t);
        sessions.push(s);
        rooms.delete(ev.code);
        closed.set(ev.code, s);
        break;
      }
      case "stat": {
        const id = ev.install;
        const rec = installs.get(id) || { id, first: ev.t, last: ev.t, since: ev.since,
                                          versions: [], solo: 0, checkins: 0 };
        rec.last = ev.t;
        rec.checkins += 1;
        rec.solo += ev.solo;
        if (!rec.versions.includes(ev.v)) rec.versions.push(ev.v);
        rec.v = ev.v;
        installs.set(id, rec);
        if (ev.solo > 0) solo.push({ t: ev.t, install: id, n: ev.solo, v: ev.v });
        if (lastSeat && new Date(ev.t) - new Date(lastSeat.t) < 5000) {
          const s = rooms.get(lastSeat.code);
          if (s) {
            if (!s.versions.includes(ev.v)) s.versions.push(ev.v);
            if (!s.installs.includes(id)) s.installs.push(id);
          }
        }
        break;
      }
      default: break;
    }
  }

  // rooms still open at the end of the record are live (or were, if the
  // record is stale)
  for (const s of rooms.values()) {
    s.live = true;
    settle(s);
    sessions.push(s);
  }
  for (const s of sessions) { delete s.members; delete s.locks; delete s.opener; }
  sessions.sort((a, b) => a.at < b.at ? 1 : -1);

  return {
    sessions,
    installs: [...installs.values()].sort((a, b) => a.first < b.first ? -1 : 1),
    solo: solo.sort((a, b) => a.t < b.t ? 1 : -1),
    bounces: bounces.sort((a, b) => a.t < b.t ? 1 : -1)
  };
}

// --- main ----------------------------------------------------------------

async function main() {
  const store = readJson(EVENTS, { events: [], swept: {} });
  store.swept = store.swept || {};
  const seen = new Set(store.events.map(key));
  let added = 0;

  const deps = await deployments();
  const cutoff = new Date(Date.now() - SWEEP_DAYS * 86400e3);
  const now = new Date();
  const lastT = store.events.reduce((m, e) => e.t > m ? e.t : m, "");
  const live = deps.find(d => d.status === "SUCCESS");

  for (const d of deps) {
    if (new Date(d.createdAt) < cutoff) continue;
    const isLive = live && d.id === live.id;
    // a dead process is read once, in full; the live one from just before
    // the last thing seen
    if (!isLive && store.swept[d.id]) continue;
    let start = new Date(d.createdAt);
    if (isLive && lastT && store.swept[d.id]) {
      const from = new Date(new Date(lastT).getTime() - OVERLAP_MS);
      if (from > start) start = from;
    }
    const got = await lines(d.id, start, now);
    let fresh = 0;
    for (const l of got) {
      const ev = parseLine(l.message, l.timestamp);
      if (!ev) continue;
      ev.deploy = d.id.slice(0, 8);
      const k = key(ev);
      if (seen.has(k)) continue;
      seen.add(k);
      store.events.push(ev);
      fresh += 1;
    }
    added += fresh;
    store.swept[d.id] = { at: now.toISOString(), status: d.status };
    console.log(`${d.id.slice(0, 8)} ${d.status.padEnd(7)} ${got.length} lines, ${fresh} new`);
  }

  store.events.sort((a, b) => a.t < b.t ? -1 : a.t > b.t ? 1 : 0);
  const play = derive(store.events);
  const out = { from: store.events.length ? store.events[0].t : null, ...play };

  // readAt moves every run; the files are only rewritten when what they
  // say has moved, so an idle relay makes no commit and no Pages deploy.
  const { readAt: _r, ...before } = readJson(PLAY, {});
  const same = added === 0 && JSON.stringify(before) === JSON.stringify(out);
  if (same) {
    console.log("play log unchanged; no write");
  } else {
    // One event a line, so a diff of this file reads as what happened.
    const NL = String.fromCharCode(10);
    writeFileSync(EVENTS,
      '{"readAt":' + JSON.stringify(now.toISOString()) +
      ',' + NL + ' "swept":' + JSON.stringify(store.swept) +
      ',' + NL + ' "events":[' + NL +
      store.events.map(e => "  " + JSON.stringify(e)).join("," + NL) +
      NL + " ]}" + NL);
    writeFileSync(PLAY, JSON.stringify({ readAt: now.toISOString(), ...out }, null, 1) + NL);
  }

  console.log(`${added} new events; ${play.sessions.length} sessions, ` +
              `${play.installs.length} installs, ${play.solo.length} solo reports`);
}

if (import.meta.url === `file://${process.argv[1].replace(/\\/g, "/")}`
    || process.argv[1]?.endsWith("play-log.mjs")) {
  await main();
}
