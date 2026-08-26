// The Battle Royale relay: N players in one room, every message forwarded.
//
// Plain TCP, one JSON object per line -- the same framing src/link/Net.lua
// already speaks to the link relay, so the game needs no new transport to
// reach this.  Nothing here knows what a battle or a step is: a room is a
// set of connections, and the server's whole job is to hand each line to
// the member it names (or to everyone else) and to keep the roster honest
// when someone drops.  Game rules live in the host player's client.
//
// Zero dependencies on purpose: `node server.js` on any box with a public
// port is a deployment.
//
// Client -> server
//   {type:"host_room", name}           -> room_hosted {code, id}, then a roster
//   {type:"join_room", code, name}     -> room_joined {code, id, host}, or
//                                         room_error {reason}
//   {type:"lock_room", locked}         host only: refuse new joiners (a match
//                                      in progress)
//   {type:"leave_room"}
//   {type:"to", id, m}                 unicast m to one member
//   {type:"all", m}                    m to every other member
//   {type:"ping"}                      -> pong
// Server -> client
//   {type:"roster", code, host, members:[{id,name}]}   on every change
//   {type:"recv", from, m}
//   {type:"room_closed", reason}       the host left
//
// Ids are small integers handed out per room, never reused within it; the
// host is whoever created the room.  Codes use the same 0/O/1/I/L-free
// alphabet as the game's room-code entry widget (src/link/CodeEntry.lua),
// so a code read aloud never has to be checked twice.

import net from "node:net";
import { randomInt } from "node:crypto";

export const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export const CODE_LENGTH = 6;

export const DEFAULT_LIMITS = Object.freeze({
  line: 16 * 1024,      // bytes per line; the game caps at the same order
  // Sustained rate, drained from a bucket -- NOT a per-second window.
  // Steps are ~4/s/player, so 120/s is a flood and not play; but a host
  // legitimately bursts far above its average in a single frame, and a
  // window counter cannot tell the two apart.  When the ring first shrinks,
  // every map it left behind runs out its grace on the SAME beat, and the
  // host retires each of their trainers with an npcout -- a few hundred
  // lines in one tick, from a client averaging four (POK-114).  It got
  // dropped for flooding, and with no host migration that ended the match.
  linesPerSec: 120,
  burstLines: 1200,     // bucket depth: one fog sweep, with room over it
  badLines: 20,         // unparsable lines before we give up on a socket
  members: 16,
  // Ceilings, not targets.  A relay is billed by what it moves, and what
  // moves bytes is a live room: the host of a 30-bot match broadcasts ~40
  // small messages a second to everyone in it, so concurrent ROOMS -- not
  // connections -- decide the bill.  These are sized for a small hosted box;
  // BR_MAX_ROOMS / BR_MAX_CONNS raise them.
  rooms: 40,
  conns: 200,
  connsPerIp: 24,
  idleMs: 60_000,       // clients ping every few seconds
  unboundMs: 30_000,    // connected but never hosted/joined
  sweepMs: 5_000,
});

const NAME_MAX = 10;

// Bytes actually written, so "what is this costing" has an answer that is not
// a guess.  Egress is the line item that scales with players.
const traffic = { bytesOut: 0, linesOut: 0, roomsOpened: 0, peakRooms: 0,
                  peakConns: 0, rejected: 0 };

export function stats() { return { ...traffic }; }

function human(bytes) {
  if (bytes < 1024) return bytes + "B";
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + "KB";
  if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + "MB";
  return (bytes / 1073741824).toFixed(2) + "GB";
}

function cleanName(name) {
  if (typeof name !== "string") return "PLAYER";
  const out = name.replace(/[^\x20-\x7e]/g, "").trim().slice(0, NAME_MAX);
  return out === "" ? "PLAYER" : out;
}

function makeCode(taken) {
  for (let attempt = 0; attempt < 64; attempt++) {
    let code = "";
    for (let i = 0; i < CODE_LENGTH; i++) {
      code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
    }
    if (!taken.has(code)) return code;
  }
  throw new Error("relay: could not allocate a room code");
}

class Room {
  constructor(code, host) {
    this.code = code;
    this.host = host;
    this.members = new Map();
    this.nextId = 1;
    this.locked = false;
    // an open room is one quick_join is allowed to hand strangers; a room
    // is private until its host says otherwise
    this.open = false;
  }

  add(conn) {
    conn.id = this.nextId++;
    conn.room = this;
    this.members.set(conn.id, conn);
    return conn.id;
  }

  remove(conn) {
    this.members.delete(conn.id);
    conn.room = null;
  }

  roster() {
    const members = [];
    for (const m of this.members.values()) members.push({ id: m.id, name: m.name });
    return { type: "roster", code: this.code, host: this.host.id,
             open: this.open, members };
  }

  broadcast(msg, except) {
    for (const m of this.members.values()) {
      if (m !== except) m.send(msg);
    }
  }
}

class Conn {
  constructor(socket, relay) {
    this.socket = socket;
    this.relay = relay;
    this.ip = socket.remoteAddress || "?";
    this.buf = "";
    this.id = null;
    this.room = null;
    this.name = "PLAYER";
    this.lastSeen = Date.now();
    this.openedAt = this.lastSeen;
    this.tokens = relay.limits.burstLines;
    this.tokenAt = this.lastSeen;
    this.minTokens = this.tokens;   // how close real play came to the wall
    this.badLines = 0;
    this.closed = false;
    // What this connection actually moved, by message TYPE and bytes
    // (POK-86).  Per-message logging on a relay carrying a match's
    // movement would be its own denial of service, and the payloads are
    // the players' business -- but a count per type, printed once when
    // the connection goes, is what tells you afterwards whether a client
    // that "froze" had stopped sending or stopped being heard.
    this.seen = new Map();
    this.bytesIn = 0;
  }

  note(type, bytes) {
    this.seen.set(type, (this.seen.get(type) || 0) + 1);
    this.bytesIn += bytes;
  }

  census() {
    if (this.seen.size === 0) return "nothing";
    return [...this.seen.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([type, n]) => `${type}x${n}`)
      .join(" ");
  }

  send(msg) {
    if (this.closed) return;
    try {
      const line = JSON.stringify(msg) + "\n";
      traffic.bytesOut += Buffer.byteLength(line);
      traffic.linesOut += 1;
      this.socket.write(line);
    } catch {
      this.destroy("write_failed");
    }
  }

  destroy(reason) {
    if (this.closed) return;
    this.closed = true;
    // Why a connection went away is the first thing you need when a match
    // breaks, and "the client just vanished" is indistinguishable from
    // "we dropped them for flooding" without it.
    this.relay.log(`drop ${this.name}#${this.id ?? "-"}`
      + `${this.room ? ` room ${this.room.code}` : ""} (${reason})`
      + ` after ${Math.round((Date.now() - this.openedAt) / 1000)}s`
      + ` | in ${this.census()}`
      + ` | headroom ${Math.round(this.minTokens)}/${this.relay.limits.burstLines}`);
    this.relay.onClose(this, reason);
    this.socket.destroy();
  }
}

export function createRelay(options = {}) {
  const limits = { ...DEFAULT_LIMITS, ...(options.limits || {}) };
  const log = options.log || (() => {});
  const rooms = new Map();
  const conns = new Set();
  const perIp = new Map();

  function leaveRoom(conn, reason) {
    const room = conn.room;
    if (!room) return;
    room.remove(conn);
    if (room.host === conn) {
      // no host migration in v0: the host's client is the match authority,
      // so a match without it is over anyway
      room.broadcast({ type: "room_closed", reason: reason || "host_left" });
      for (const m of [...room.members.values()]) {
        room.remove(m);
      }
      rooms.delete(room.code);
      log(`room ${room.code} closed (${reason || "host_left"})`);
    } else {
      room.broadcast(room.roster());
      log(`room ${room.code}: ${conn.name}#${conn.id} left`);
    }
  }

  function handle(conn, msg) {
    switch (msg.type) {
      case "ping":
        conn.send({ type: "pong", t: msg.t });
        return;

      case "host_room": {
        if (conn.room) { conn.send({ type: "room_error", reason: "already_in_room" }); return; }
        if (rooms.size >= limits.rooms) {
          traffic.rejected += 1;
          conn.send({ type: "room_error", reason: "server_full" });
          log(`room refused: at the ${limits.rooms}-room ceiling`);
          return;
        }
        conn.name = cleanName(msg.name);
        const room = new Room(makeCode(rooms), conn);
        room.open = msg.open === true;
        rooms.set(room.code, room);
        room.add(conn);
        traffic.roomsOpened += 1;
        if (rooms.size > traffic.peakRooms) traffic.peakRooms = rooms.size;
        conn.send({ type: "room_hosted", code: room.code, id: conn.id });
        conn.send(room.roster());
        log(`room ${room.code} hosted by ${conn.name}#${conn.id}` +
            (room.open ? " (open)" : ""));
        return;
      }

      case "join_room": {
        if (conn.room) { conn.send({ type: "room_error", reason: "already_in_room" }); return; }
        const code = typeof msg.code === "string" ? msg.code.toUpperCase() : "";
        const room = rooms.get(code);
        if (!room) { conn.send({ type: "room_error", reason: "not_found" }); return; }
        if (room.locked) { conn.send({ type: "room_error", reason: "locked" }); return; }
        if (room.members.size >= limits.members) { conn.send({ type: "room_error", reason: "full" }); return; }
        conn.name = cleanName(msg.name);
        room.add(conn);
        conn.send({ type: "room_joined", code: room.code, id: conn.id, host: room.host.id });
        room.broadcast(room.roster());
        log(`room ${room.code}: ${conn.name}#${conn.id} joined`);
        return;
      }

      // Quick play: the point is that a newcomer needs nothing from anyone
      // -- no code read out over voice chat, no friend already playing.  We
      // pick the FULLEST joinable room rather than the first, so strangers
      // gather into one match instead of scattering one-per-room.
      case "quick_join": {
        if (conn.room) { conn.send({ type: "room_error", reason: "already_in_room" }); return; }
        let best = null;
        for (const room of rooms.values()) {
          if (!room.open || room.locked) continue;
          if (room.members.size >= limits.members) continue;
          if (!best || room.members.size > best.members.size) best = room;
        }
        if (!best) { conn.send({ type: "no_open_rooms" }); return; }
        conn.name = cleanName(msg.name);
        best.add(conn);
        conn.send({ type: "room_joined", code: best.code, id: conn.id, host: best.host.id });
        best.broadcast(best.roster());
        log(`room ${best.code}: ${conn.name}#${conn.id} quick-joined`);
        return;
      }

      case "set_open": {
        const room = conn.room;
        if (!room || room.host !== conn) return;
        room.open = msg.open === true;
        room.broadcast(room.roster());
        log(`room ${room.code} is now ${room.open ? "open" : "private"}`);
        return;
      }

      case "lock_room": {
        const room = conn.room;
        if (!room || room.host !== conn) return;
        room.locked = msg.locked !== false;
        return;
      }

      case "leave_room":
        leaveRoom(conn, "left");
        return;

      case "to": {
        const room = conn.room;
        if (!room || typeof msg.m !== "object" || msg.m === null) return;
        const target = room.members.get(Number(msg.id));
        if (target && target !== conn) target.send({ type: "recv", from: conn.id, m: msg.m });
        return;
      }

      case "all": {
        const room = conn.room;
        if (!room || typeof msg.m !== "object" || msg.m === null) return;
        room.broadcast({ type: "recv", from: conn.id, m: msg.m }, conn);
        return;
      }

      default:
        // unknown control types are ignored rather than fatal: a newer
        // client talking to an older relay should degrade, not disconnect
        return;
    }
  }

  function onLine(conn, line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      msg = null;
    }
    if (!msg || typeof msg !== "object" || Array.isArray(msg) || typeof msg.type !== "string") {
      if (++conn.badLines > limits.badLines) conn.destroy("bad_input");
      return;
    }
    conn.note(msg.type, line.length);
    try {
      handle(conn, msg);
    } catch (err) {
      // WHICH message, from whom, in which room: a bare stack tells you
      // the line of code and nothing about the game that hit it (POK-86)
      log(`handler error on ${msg.type} from ${conn.name}#${conn.id ?? "-"}`
          + `${conn.room ? ` in room ${conn.room.code}` : ""}:`
          + ` ${err && err.stack || err}`);
    }
  }

  function onData(conn, chunk) {
    const now = Date.now();
    conn.lastSeen = now;
    conn.buf += chunk;
    if (conn.buf.length > limits.line * 2) { conn.destroy("line_too_long"); return; }
    let nl;
    while ((nl = conn.buf.indexOf("\n")) >= 0) {
      const line = conn.buf.slice(0, nl);
      conn.buf = conn.buf.slice(nl + 1);
      if (line.length === 0) continue;
      if (line.length > limits.line) { conn.destroy("line_too_long"); return; }
      conn.tokens = Math.min(limits.burstLines,
        conn.tokens + ((now - conn.tokenAt) / 1000) * limits.linesPerSec);
      conn.tokenAt = now;
      if (conn.tokens < 1) { conn.destroy("flood"); return; }
      conn.tokens -= 1;
      if (conn.tokens < conn.minTokens) conn.minTokens = conn.tokens;
      onLine(conn, line);
      if (conn.closed) return;
    }
  }

  const relay = {
    rooms,
    conns,
    limits,
    log,
    onClose(conn, reason) {
      leaveRoom(conn, reason === "left" ? "left" : "host_gone");
      conns.delete(conn);
      const n = (perIp.get(conn.ip) || 1) - 1;
      if (n <= 0) perIp.delete(conn.ip); else perIp.set(conn.ip, n);
    },
  };

  const server = net.createServer((socket) => {
    socket.setEncoding("utf8");
    socket.setNoDelay(true);
    const conn = new Conn(socket, relay);
    const ipCount = (perIp.get(conn.ip) || 0) + 1;
    if (conns.size >= limits.conns || ipCount > limits.connsPerIp) {
      // silently dropping these made a full relay look like a network
      // fault from the client side, with nothing on the server to match
      log(`refused ${conn.ip}: `
          + (conns.size >= limits.conns
             ? `at the ${limits.conns}-connection ceiling`
             : `${ipCount} connections from one address`));
      traffic.rejected += 1;
      socket.destroy();
      return;
    }
    log(`open ${conn.ip} (${conns.size + 1}/${limits.conns})`);
    perIp.set(conn.ip, ipCount);
    conns.add(conn);
    if (conns.size > traffic.peakConns) traffic.peakConns = conns.size;
    socket.on("data", (chunk) => onData(conn, chunk));
    socket.on("error", () => conn.destroy("socket_error"));
    socket.on("close", () => conn.destroy("closed"));
  });

  // One line every few minutes: enough to see whether the box is busy or
  // idle and what it has moved, without shipping a metrics stack.
  const reporter = setInterval(() => {
    log(`rooms ${rooms.size}/${limits.rooms} conns ${conns.size}/${limits.conns}`
        + ` | sent ${human(traffic.bytesOut)} in ${traffic.linesOut} lines`
        + ` | peak ${traffic.peakRooms} rooms ${traffic.peakConns} conns`
        + (traffic.rejected ? ` | refused ${traffic.rejected}` : ""));
  }, 5 * 60_000);
  reporter.unref();

  const sweeper = setInterval(() => {
    const now = Date.now();
    for (const conn of [...conns]) {
      if (now - conn.lastSeen > limits.idleMs) conn.destroy("idle");
      else if (!conn.room && now - conn.openedAt > limits.unboundMs) conn.destroy("unbound");
    }
  }, limits.sweepMs);
  sweeper.unref();

  server.on("error", (err) => log(`server error: ${err && err.message}`));

  return {
    server,
    rooms,
    conns,
    listen(port, host) {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          resolve(server.address());
        });
      });
    },
    close() {
      clearInterval(sweeper);
      for (const conn of [...conns]) conn.destroy("shutdown");
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1].replace(/\\/g, "/")}`).href
  || (process.argv[1] && process.argv[1].endsWith("server.js") && import.meta.url.endsWith("server.js"));

if (isMain) {
  const port = Number(process.env.PORT || process.env.BR_RELAY_PORT || 7790);
  const host = process.env.HOST || "0.0.0.0";
  const limits = {};
  if (process.env.BR_MAX_ROOMS) limits.rooms = Number(process.env.BR_MAX_ROOMS);
  if (process.env.BR_MAX_CONNS) limits.conns = Number(process.env.BR_MAX_CONNS);
  if (process.env.BR_LINES_PER_SEC) limits.linesPerSec = Number(process.env.BR_LINES_PER_SEC);
  if (process.env.BR_BURST_LINES) limits.burstLines = Number(process.env.BR_BURST_LINES);
  const relay = createRelay({ limits,
    log: (line) => console.log(new Date().toISOString(), line) });
  process.on("uncaughtException", (err) => console.error("uncaught:", err));
  process.on("unhandledRejection", (err) => console.error("unhandled:", err));
  relay.listen(port, host).then((addr) => {
    console.log(`battle royale relay listening on ${addr.address}:${addr.port}`);
  });
}
