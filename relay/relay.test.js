// node --test  (from this directory)
//
// Drives the relay over real sockets on an ephemeral port: host, join,
// roster fan-out, unicast and broadcast routing, the error reasons the
// client shows, locking, and the host leaving.

import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { createRelay, CODE_ALPHABET, CODE_LENGTH, stats } from "./server.js";

class Client {
  constructor(port) {
    this.socket = net.createConnection({ port, host: "127.0.0.1" });
    this.socket.setEncoding("utf8");
    this.buf = "";
    this.inbox = [];
    this.waiters = [];
    this.closed = false;
    this.socket.on("data", (chunk) => {
      this.buf += chunk;
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        if (line) this.push(JSON.parse(line));
      }
    });
    this.socket.on("close", () => { this.closed = true; this.push({ type: "__closed" }); });
  }

  ready() {
    return new Promise((resolve, reject) => {
      this.socket.once("connect", resolve);
      this.socket.once("error", reject);
    });
  }

  push(msg) {
    const w = this.waiters.shift();
    if (w) w(msg); else this.inbox.push(msg);
  }

  send(msg) {
    this.socket.write(JSON.stringify(msg) + "\n");
  }

  raw(text) {
    this.socket.write(text);
  }

  next(timeoutMs = 2000) {
    if (this.inbox.length) return Promise.resolve(this.inbox.shift());
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out waiting for a message")), timeoutMs);
      this.waiters.push((msg) => { clearTimeout(timer); resolve(msg); });
    });
  }

  // Round-trip this connection: everything sent on it before the ping has
  // been processed by the time the pong comes back.  This is the only
  // ordering guarantee available between two clients -- the server reads one
  // connection in order, but nothing sequences one client against another.
  async settled(timeoutMs = 2000) {
    this.send({ type: "ping" });
    await this.until("pong", timeoutMs);
  }

  // skip messages until one of the given type arrives
  async until(type, timeoutMs = 2000) {
    for (;;) {
      const msg = await this.next(timeoutMs);
      if (msg.type === type) return msg;
    }
  }

  end() {
    this.socket.end();
    this.socket.destroy();
  }
}

async function withRelay(fn, limits) {
  const relay = createRelay({ limits });
  const addr = await relay.listen(0, "127.0.0.1");
  try {
    await fn(addr.port, relay);
  } finally {
    await relay.close();
  }
}

async function connect(port) {
  const c = new Client(port);
  await c.ready();
  return c;
}

test("host gets a code in the entry-widget alphabet and a roster of one", async () => {
  await withRelay(async (port) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "RED" });
    const hosted = await a.next();
    assert.equal(hosted.type, "room_hosted");
    assert.equal(hosted.id, 1);
    assert.equal(hosted.code.length, CODE_LENGTH);
    for (const ch of hosted.code) assert.ok(CODE_ALPHABET.includes(ch), `code char ${ch}`);
    const roster = await a.next();
    assert.equal(roster.type, "roster");
    assert.equal(roster.host, 1);
    assert.deepEqual(roster.members, [{ id: 1, name: "RED" }]);
    a.end();
  });
});

test("join by code: everyone sees the roster grow, names are cleaned", async () => {
  await withRelay(async (port) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "RED" });
    const { code } = await a.next();
    await a.next(); // roster

    const b = await connect(port);
    b.send({ type: "join_room", code: code.toLowerCase(), name: "  blue\x01toolongname " });
    const joined = await b.next();
    assert.equal(joined.type, "room_joined");
    assert.equal(joined.id, 2);
    assert.equal(joined.host, 1);
    assert.equal(joined.code, code);

    const rosterB = await b.next();
    const rosterA = await a.next();
    assert.deepEqual(rosterA, rosterB);
    assert.deepEqual(rosterA.members.map((m) => m.name), ["RED", "bluetoolon"]);
    a.end(); b.end();
  });
});

test("unicast reaches one member, broadcast reaches everyone else", async () => {
  await withRelay(async (port) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "A" });
    const { code } = await a.next();
    await a.next();
    const b = await connect(port);
    b.send({ type: "join_room", code, name: "B" });
    await b.next(); await b.next(); await a.next();
    const c = await connect(port);
    c.send({ type: "join_room", code, name: "C" });
    await c.next(); await c.next(); await a.next(); await b.next();

    a.send({ type: "to", id: 3, m: { t: "hi", n: 1 } });
    const got = await c.next();
    assert.deepEqual(got, { type: "recv", from: 1, m: { t: "hi", n: 1 } });

    b.send({ type: "all", m: { t: "step", d: "up" } });
    const ga = await a.next();
    const gc = await c.next();
    assert.deepEqual(ga, { type: "recv", from: 2, m: { t: "step", d: "up" } });
    assert.deepEqual(gc, ga);

    // the sender never hears its own broadcast, and a unicast to yourself
    // or to nobody is dropped rather than echoed
    b.send({ type: "to", id: 2, m: { t: "self" } });
    b.send({ type: "to", id: 99, m: { t: "nobody" } });
    b.send({ type: "ping", t: 7 });
    const pong = await b.next();
    assert.deepEqual(pong, { type: "pong", t: 7 });
    a.end(); b.end(); c.end();
  });
});

test("join errors: not_found, locked, full, already_in_room", async () => {
  await withRelay(async (port) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "A" });
    const { code } = await a.next();
    await a.next();

    const x = await connect(port);
    x.send({ type: "join_room", code: "ZZZZZZ", name: "X" });
    assert.deepEqual(await x.next(), { type: "room_error", reason: "not_found" });

    // lock_room is silent -- no ack, no roster -- and `a` and `x` are two
    // independent sockets, so "send the lock, then send the join" orders
    // nothing at all: on a fast machine the join is read first and the
    // assertion below fails against a server that is behaving perfectly.
    // A ping on the SAME connection as the lock is the ordering: the server
    // reads one connection's lines in order, so a pong means the lock landed.
    await a.settled();
    a.send({ type: "lock_room", locked: true });
    await a.settled();
    x.send({ type: "join_room", code, name: "X" });
    assert.deepEqual(await x.next(), { type: "room_error", reason: "locked" });
    a.send({ type: "lock_room", locked: false });
    await a.settled();

    x.send({ type: "join_room", code, name: "X" });
    assert.equal((await x.next()).type, "room_joined");
    await x.next(); await a.next();

    const y = await connect(port);
    y.send({ type: "join_room", code, name: "Y" });
    assert.deepEqual(await y.next(), { type: "room_error", reason: "full" });

    x.send({ type: "host_room", name: "X" });
    assert.deepEqual(await x.next(), { type: "room_error", reason: "already_in_room" });
    a.end(); x.end(); y.end();
  }, { members: 2 });
});

test("a guest leaving updates the roster; the host leaving closes the room", async () => {
  await withRelay(async (port, relay) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "A" });
    const { code } = await a.next();
    await a.next();
    const b = await connect(port);
    b.send({ type: "join_room", code, name: "B" });
    await b.next(); await b.next(); await a.next();
    const c = await connect(port);
    c.send({ type: "join_room", code, name: "C" });
    await c.next(); await c.next(); await a.next(); await b.next();

    b.end();
    const rosterA = await a.until("roster");
    assert.deepEqual(rosterA.members.map((m) => m.id), [1, 3]);
    const rosterC = await c.until("roster");
    assert.deepEqual(rosterC.members.map((m) => m.id), [1, 3]);

    a.send({ type: "leave_room" });
    const closed = await c.until("room_closed");
    assert.equal(closed.reason, "left");
    assert.equal(relay.rooms.size, 0);

    // ...and the code is gone
    c.send({ type: "join_room", code, name: "C" });
    assert.deepEqual(await c.next(), { type: "room_error", reason: "not_found" });
    a.end(); c.end();
  });
});

test("the room outlives its host when somebody can take it over", async () => {
  await withRelay(async (port, relay) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "A" });
    const { code } = await a.next();
    await a.next();
    const b = await connect(port);
    b.send({ type: "can_host", ok: true });
    b.send({ type: "join_room", code, name: "B" });
    await b.next(); await b.next(); await a.next();
    const c = await connect(port);
    c.send({ type: "can_host", ok: true });
    c.send({ type: "join_room", code, name: "C" });
    await c.next(); await c.next(); await a.next(); await b.next();

    // the host goes, and the room does not
    a.end();
    const roster = await b.until("roster");
    assert.equal(roster.host, 2, "the longest-standing eligible member inherits");
    assert.deepEqual(roster.members.map((m) => m.id), [2, 3]);
    assert.equal(relay.rooms.size, 1, "the room is still open");

    // and it is a working room: the new host is just a member like any other
    const rosterC = await c.until("roster");
    assert.equal(rosterC.host, 2);
    b.send({ type: "all", m: { t: "ring", phase: 2 } });
    const relayed = await c.until("recv");
    assert.equal(relayed.from, 2);
    assert.deepEqual(relayed.m, { t: "ring", phase: 2 });
    b.end(); c.end();
  });
});

test("a room of clients that cannot host still closes, as it always did", async () => {
  await withRelay(async (port, relay) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "A" });
    const { code } = await a.next();
    await a.next();
    // b never says it can host -- an older client, or one that never learned
    const b = await connect(port);
    b.send({ type: "join_room", code, name: "B" });
    await b.next(); await b.next(); await a.next();

    a.send({ type: "leave_room" });
    const closed = await b.until("room_closed");
    assert.equal(closed.reason, "left");
    assert.equal(relay.rooms.size, 0);
    a.end(); b.end();
  });
});

test("an eliminated player withdraws, and the room passes over them", async () => {
  await withRelay(async (port, relay) => {
    const a = await connect(port);
    a.send({ type: "host_room", name: "A" });
    const { code } = await a.next();
    await a.next();
    const b = await connect(port);
    b.send({ type: "can_host", ok: true });
    b.send({ type: "join_room", code, name: "B" });
    await b.next(); await b.next(); await a.next();
    const c = await connect(port);
    c.send({ type: "can_host", ok: true });
    c.send({ type: "join_room", code, name: "C" });
    await c.next(); await c.next(); await a.next(); await b.next();

    // B is knocked out and stands down; C is next in line despite joining later
    // A withdrawal is broadcast to nobody, so wait on a round-trip down B's
    // own socket instead: lines from one connection are handled in order, so
    // a pong proves the can_host ahead of it has already landed.
    b.send({ type: "can_host", ok: false });
    b.send({ type: "ping" });
    await b.until("pong");
    a.end();
    const roster = await c.until("roster");
    assert.equal(roster.host, 3, "the room skips the member that stood down");
    assert.equal(relay.rooms.size, 1);
    b.end(); c.end();
  });
});

test("quick_join finds an open room, and says so when there is none", async () => {
  await withRelay(async (port) => {
    // nobody is hosting: the answer is an answer, not an error, so the
    // client can turn round and host on the same connection
    const first = await connect(port);
    first.send({ type: "quick_join", name: "ANNA" });
    assert.equal((await first.next()).type, "no_open_rooms");

    // ...which is exactly what it then does
    first.send({ type: "host_room", name: "ANNA", open: true });
    const hosted = await first.until("room_hosted");
    const firstRoster = await first.until("roster");
    assert.equal(firstRoster.open, true);

    // a stranger with no code now lands in that room
    const second = await connect(port);
    second.send({ type: "quick_join", name: "BEN" });
    const joined = await second.until("room_joined");
    assert.equal(joined.code, hosted.code);
    assert.equal(joined.host, 1);
    const roster = await second.until("roster");
    assert.deepEqual(roster.members.map((m) => m.name), ["ANNA", "BEN"]);
    first.end();
    second.end();
  });
});

test("quick_join skips private, locked and full rooms", async () => {
  await withRelay(async (port) => {
    const priv = await connect(port);
    priv.send({ type: "host_room", name: "PRIV" });   // open defaults to false
    await priv.until("room_hosted");

    const shut = await connect(port);
    shut.send({ type: "host_room", name: "SHUT", open: true });
    await shut.until("room_hosted");
    shut.send({ type: "lock_room", locked: true });

    // ...but an open room that is LOCKED is a match in progress, and since
    // POK-133 that is its own answer: the seeker is not seated, but they
    // are told where to watch.
    const seeker = await connect(port);
    seeker.send({ type: "quick_join", name: "SEEK" });
    const answer = await seeker.next();
    assert.equal(answer.type, "match_in_progress");
    assert.equal(typeof answer.code, "string");

    priv.end(); shut.end(); seeker.end();
  }, { members: 2 });
});

test("quick_join with nothing open and nothing running says no_open_rooms", async () => {
  await withRelay(async (port) => {
    const priv = await connect(port);
    priv.send({ type: "host_room", name: "PRIV" });   // private, unlocked
    await priv.until("room_hosted");
    const seeker = await connect(port);
    seeker.send({ type: "quick_join", name: "SEEK" });
    // a private lobby is not a match in progress: it is invisible, full stop
    assert.equal((await seeker.next()).type, "no_open_rooms");
    priv.end(); seeker.end();
  });
});

test("quick_join gathers strangers into the fullest room, not the first", async () => {
  await withRelay(async (port) => {
    const small = await connect(port);
    small.send({ type: "host_room", name: "SMALL", open: true });
    await small.until("room_hosted");

    const big = await connect(port);
    big.send({ type: "host_room", name: "BIG", open: true });
    const bigCode = (await big.until("room_hosted")).code;
    const mate = await connect(port);
    mate.send({ type: "join_room", code: bigCode, name: "MATE" });
    await mate.until("room_joined");

    // two rooms are open; the one with people in it wins, so a handful of
    // strangers becomes one match rather than three lonely lobbies
    const seeker = await connect(port);
    seeker.send({ type: "quick_join", name: "SEEK" });
    assert.equal((await seeker.until("room_joined")).code, bigCode);

    small.end(); big.end(); mate.end(); seeker.end();
  });
});

test("set_open is the host's alone, and tells the room", async () => {
  await withRelay(async (port) => {
    const host = await connect(port);
    host.send({ type: "host_room", name: "HOST" });
    const code = (await host.until("room_hosted")).code;
    const guest = await connect(port);
    guest.send({ type: "join_room", code, name: "GUEST" });
    await guest.until("room_joined");
    await guest.until("roster");   // the one their own arrival caused

    // a guest asking is ignored
    guest.send({ type: "set_open", open: true });
    const seeker = await connect(port);
    seeker.send({ type: "quick_join", name: "SEEK" });
    assert.equal((await seeker.next()).type, "no_open_rooms");

    // the host asking is not
    host.send({ type: "set_open", open: true });
    assert.equal((await guest.until("roster")).open, true);
    const seeker2 = await connect(port);
    seeker2.send({ type: "quick_join", name: "SEEK2" });
    assert.equal((await seeker2.until("room_joined")).code, code);

    host.end(); guest.end(); seeker.end(); seeker2.end();
  });
});

test("MAX is the room's size: the host sets it, the relay refuses past it", async () => {
  await withRelay(async (port) => {
    const host = await connect(port);
    host.send({ type: "host_room", name: "HOST", open: true, max: 2 });
    const code = (await host.until("room_hosted")).code;
    assert.equal((await host.until("roster")).max, 2, "the roster says the size");

    const a = await connect(port);
    a.send({ type: "join_room", code, name: "A" });
    await a.until("room_joined");
    await a.until("roster");   // the one their own arrival caused
    const b = await connect(port);
    b.send({ type: "join_room", code, name: "B" });
    assert.equal((await b.next()).reason, "full", "a third trainer is refused");
    // ...and quick play walks past it too
    const seeker = await connect(port);
    seeker.send({ type: "quick_join", name: "SEEK" });
    assert.equal((await seeker.next()).type, "no_open_rooms");

    // a guest cannot resize the room; the host can, live
    a.send({ type: "set_max", max: 4 });
    const c = await connect(port);
    c.send({ type: "join_room", code, name: "C" });
    assert.equal((await c.next()).reason, "full");
    host.send({ type: "set_max", max: 4 });
    assert.equal((await a.until("roster")).max, 4);
    const d = await connect(port);
    d.send({ type: "join_room", code, name: "D" });
    await d.until("room_joined");
    await a.until("roster");   // D's arrival

    // and it never exceeds the relay's own ceiling, or drops under two
    host.send({ type: "set_max", max: 999 });
    assert.equal((await a.until("roster")).max, 16);
    host.send({ type: "set_max", max: 0 });
    assert.equal((await a.until("roster")).max, 2);

    host.end(); a.end(); b.end(); c.end(); d.end(); seeker.end();
  });
});

test("the room ceiling holds, refuses cleanly, and frees up again", async () => {
  await withRelay(async (port) => {
    // concurrent rooms are what a hosted relay is billed for, so the cap has
    // to be real and has to fail in a way the client can explain
    const a = await connect(port);
    a.send({ type: "host_room", name: "ONE" });
    await a.until("room_hosted");
    const b = await connect(port);
    b.send({ type: "host_room", name: "TWO" });
    await b.until("room_hosted");

    const third = await connect(port);
    third.send({ type: "host_room", name: "THREE" });
    const refused = await third.until("room_error");
    assert.equal(refused.reason, "server_full");

    // quick play must not squeeze past the ceiling by another door
    const quick = await connect(port);
    quick.send({ type: "quick_join", name: "QUICK" });
    assert.equal((await quick.next()).type, "no_open_rooms");

    // ...and a room closing gives the slot back
    a.end();
    await new Promise((r) => setTimeout(r, 50));
    const fourth = await connect(port);
    fourth.send({ type: "host_room", name: "FOUR" });
    assert.equal((await fourth.until("room_hosted")).code.length, CODE_LENGTH);

    b.end(); third.end(); quick.end(); fourth.end();
  }, { rooms: 2 });
});

test("traffic accounting counts what it actually wrote", async () => {
  await withRelay(async (port) => {
    const before = stats();
    const a = await connect(port);
    a.send({ type: "host_room", name: "RED" });
    await a.until("roster");
    const after = stats();
    assert.ok(after.bytesOut > before.bytesOut, "bytes out went up");
    assert.ok(after.linesOut > before.linesOut, "lines out went up");
    assert.ok(after.roomsOpened > before.roomsOpened, "a room was counted");
    a.end();
  });
});

test("garbage lines are dropped, a flood of them disconnects", async () => {
  await withRelay(async (port) => {
    const a = await connect(port);
    a.raw("not json\n[1,2]\n{\"noType\":1}\n");
    a.send({ type: "ping" });
    assert.equal((await a.next()).type, "pong");
    for (let i = 0; i < 30; i++) a.raw("garbage\n");
    const closed = await a.until("__closed");
    assert.equal(closed.type, "__closed");
  }, { badLines: 5 });
});

test("a stat line is counted and never answered", async () => {
  await withRelay(async (port) => {
    const before = stats();
    const a = await connect(port);
    a.send({ type: "stat", id: "0123456789abcdef", v: "0.31.0",
             solo: 3, since: "2026-08-20" });
    // nothing comes back: the client sends this and forgets it, so a reply
    // would be a message no client is listening for
    a.send({ type: "ping" });
    assert.equal((await a.next()).type, "pong");
    const after = stats();
    assert.equal(after.statSeen, before.statSeen + 1, "the stat was seen");
    assert.equal(after.statSolo, before.statSolo + 3, "and its solo count added");
    a.end();
  });
});

test("a stat with a junk id or count is dropped, not logged", async () => {
  await withRelay(async (port) => {
    const before = stats();
    const a = await connect(port);
    // the id is the one field whose whole content the client chooses, so a
    // non-hex id must never reach a log line
    a.send({ type: "stat", id: "../../etc/passwd", solo: 1 });
    a.send({ type: "stat", id: "not hex at all", solo: 1 });
    a.send({ type: "stat", solo: 1 });
    a.send({ type: "ping" });
    assert.equal((await a.next()).type, "pong");
    assert.equal(stats().statSeen, before.statSeen, "none of them counted");

    // a sane id with a nonsense count still counts the install, at zero
    a.send({ type: "stat", id: "abc123", solo: -5 });
    a.send({ type: "ping" });
    assert.equal((await a.next()).type, "pong");
    const after = stats();
    assert.equal(after.statSeen, before.statSeen + 1, "the install counted");
    assert.equal(after.statSolo, before.statSolo, "the bad count did not");
    a.end();
  });
});

test("a stat needs no room, which is the whole point", async () => {
  await withRelay(async (port) => {
    const before = stats();
    const a = await connect(port);
    // never hosts, never joins -- a solo player's count arriving on a
    // connection that exists for some other reason
    a.send({ type: "stat", id: "feedface", v: "0.31.0", solo: 12 });
    a.send({ type: "ping" });
    assert.equal((await a.next()).type, "pong");
    assert.equal(stats().statSolo, before.statSolo + 12, "counted without a room");
    a.end();
  });
});

// ------- POK-130: the host can show somebody the door

// the roster arrives once per change, so a test that hosted then joined has
// two of them queued; wait for the one that matches
async function rosterWhere(client, pred) {
  for (;;) {
    const roster = await client.until("roster");
    if (pred(roster)) return roster;
  }
}

test("kick removes a member, tells them, and their IP stays out", async () => {
  await withRelay(async (port) => {
    const host = await connect(port);
    host.send({ type: "host_room", name: "HOST", open: true });
    const code = (await host.until("room_hosted")).code;
    const guest = await connect(port);
    guest.send({ type: "join_room", code, name: "GUEST" });
    const joined = await guest.until("room_joined");
    await host.until("roster");

    host.send({ type: "kick", id: joined.id });
    const closed = await guest.until("room_closed");
    assert.equal(closed.reason, "removed");
    const roster = await rosterWhere(host, (r) => r.members.length === 1);
    assert.equal(roster.members[0].name, "HOST", "the roster is the host alone");

    // the same IP cannot come back through either door
    guest.send({ type: "join_room", code, name: "GUEST" });
    assert.equal((await guest.until("room_error")).reason, "removed");
    const again = await connect(port);   // a fresh connection, same IP
    again.send({ type: "quick_join", name: "GUEST" });
    assert.equal((await again.next()).type, "no_open_rooms");

    host.end(); guest.end(); again.end();
  });
});

test("only the host kicks, and never themselves", async () => {
  await withRelay(async (port, relay) => {
    const host = await connect(port);
    host.send({ type: "host_room", name: "HOST", open: true });
    const code = (await host.until("room_hosted")).code;
    const guest = await connect(port);
    guest.send({ type: "join_room", code, name: "GUEST" });
    await guest.until("room_joined");
    await host.until("roster");

    // a guest asking is ignored; so is a host aiming at their own id
    guest.send({ type: "kick", id: 1 });
    await guest.settled();
    host.send({ type: "kick", id: 1 });
    await host.settled();
    assert.equal(relay.rooms.get(code).members.size, 2, "nobody went anywhere");

    host.end(); guest.end();
  });
});

// ------- POK-133: watch the running match, play the next one

test("a spectator enters a locked room and is seated at the unlock", async () => {
  await withRelay(async (port) => {
    const host = await connect(port);
    host.send({ type: "host_room", name: "HOST", open: true });
    const code = (await host.until("room_hosted")).code;
    host.send({ type: "lock_room", locked: true });

    // a player is barred; a watcher is not
    const player = await connect(port);
    player.send({ type: "join_room", code, name: "LATE" });
    assert.equal((await player.until("room_error")).reason, "locked");
    const watcher = await connect(port);
    watcher.send({ type: "join_room", code, name: "LATE", spectate: true });
    await watcher.until("room_joined");
    let roster = await rosterWhere(host,
      (r) => r.members.some((m) => m.name === "LATE"));
    const seat = roster.members.find((m) => m.name === "LATE");
    assert.equal(seat.spectate, true, "the roster marks the watcher");

    // the match ends, the room unlocks, the watcher becomes a player
    host.send({ type: "lock_room", locked: false });
    roster = await rosterWhere(watcher,
      (r) => r.members.some((m) => m.name === "LATE" && !m.spectate));
    const seated = roster.members.find((m) => m.name === "LATE");
    assert.equal(seated.spectate, undefined, "the unlock seats them");

    host.end(); player.end(); watcher.end();
  });
});

// ------- POK-161: the official game time, served not shipped

test("info answers with the bounded motd and live counts", async () => {
  const { createRelay: mk } = await import("./server.js");
  const relay = mk({ motd: "GAME NIGHT DAILY\n7PM CENTRAL" });
  const addr = await relay.listen(0, "127.0.0.1");
  try {
    const a = await connect(addr.port);
    a.send({ type: "info" });
    const info = await a.until("info");
    assert.deepEqual(info.motd, ["GAME NIGHT DAILY", "7PM CENTRAL"]);
    assert.equal(info.conns, 1);
    assert.equal(info.rooms, 0);
    // needs no room, like stat: the empty lobby is exactly who asks
    a.send({ type: "host_room", name: "A" });
    await a.until("room_hosted");
    a.send({ type: "info" });
    const again = await a.until("info");
    assert.equal(again.rooms, 1);
    a.end();
  } finally {
    await relay.close();
  }
});

test("the motd is bounded: 17 cells, 3 rows, printable only", async () => {
  const { cleanMotd } = await import("./server.js");
  assert.deepEqual(cleanMotd(undefined), []);
  assert.deepEqual(cleanMotd(""), []);
  assert.deepEqual(cleanMotd("A ROW THAT RUNS FAR PAST THE BOX"),
    ["A ROW THAT RUNS F"]);
  assert.deepEqual(cleanMotd("ONE\nTWO\nTHREE\nFOUR"),
    ["ONE", "TWO", "THREE"]);
  assert.deepEqual(cleanMotd("G\u00c9M\u00c9  SOIR\u00c9E  "), ["GM  SOIRE"]);
});

// ------- POK-161 v2: the DAILY GAME

test("daily config parses, bounds, and counts down", async () => {
  const { parseDaily, dailySecondsUntil } = await import("./server.js");
  assert.equal(parseDaily(undefined), null);
  assert.equal(parseDaily("nonsense"), null);
  assert.equal(parseDaily("19:00|Not/AZone|X"), null);
  const d = parseDaily("19:00|America/Chicago|7PM CENTRAL");
  assert.equal(d.hour, 19);
  assert.equal(d.label, "7PM CENTRAL");
  const secs = dailySecondsUntil(d);
  assert.ok(secs > 0 && secs <= 86400, "within a day: " + secs);
  // a label past the box is trimmed like any motd row
  assert.equal(parseDaily("07:30|UTC|A LABEL THAT RUNS PAST THE BOX").label,
    "A LABEL THAT RUNS");
});

test("daily_join shares one room, and quick_join never seats there", async () => {
  const relay = createRelay({ daily: "19:00|America/Chicago|7PM CENTRAL" });
  const addr = await relay.listen(0, "127.0.0.1");
  try {
    const a = await connect(addr.port);
    a.send({ type: "info" });
    const info = await a.until("info");
    assert.ok(info.daily && info.daily.secs > 0, "info carries the schedule");
    assert.equal(info.daily.label, "7PM CENTRAL");

    // first press creates it, second press joins the SAME room
    a.send({ type: "daily_join", name: "EARLY" });
    const hosted = await a.until("room_hosted");
    const b = await connect(addr.port);
    b.send({ type: "daily_join", name: "ALSO" });
    assert.equal((await b.until("room_joined")).code, hosted.code);

    // quick play walks straight past the waiting daily room
    const q = await connect(addr.port);
    q.send({ type: "quick_join", name: "NOW" });
    assert.equal((await q.next()).type, "no_open_rooms");

    // ...but once its match runs, it is the POK-133 answer for everyone
    a.send({ type: "lock_room", locked: true });
    await a.settled();
    const late = await connect(addr.port);
    late.send({ type: "daily_join", name: "LATE" });
    const running = await late.next();
    assert.equal(running.type, "match_in_progress");
    assert.equal(running.code, hosted.code);
    const q2 = await connect(addr.port);
    q2.send({ type: "quick_join", name: "NOW2" });
    assert.equal((await q2.until("match_in_progress")).code, hosted.code);

    a.end(); b.end(); q.end(); late.end(); q2.end();
  } finally {
    await relay.close();
  }
});
