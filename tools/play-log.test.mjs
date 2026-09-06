// node --test tools/
//
// The parser and the session builder, against lines copied from the live
// relay on 2026-09-06. Names and install ids in here are the ones the relay
// logged that morning; the expectations are what the log says happened.

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseLine, derive } from "./play-log.mjs";

const LINES = [
  // three friends, one hosts by HOST (no quick_join in the census), two join
  // by code; the host drops mid third match and the room migrates
  "2026-09-06T06:40:28.893Z open 100.64.0.3 (1/200)",
  "2026-09-06T06:40:28.894Z room SA8QBK hosted by RED#1 (open)",
  "2026-09-06T06:40:28.991Z stat eb5dd2d0f128b3ac v0.47.0 | solo +0 | since 2026-09-06",
  "2026-09-06T06:41:44.335Z room SA8QBK: RED#2 joined",
  "2026-09-06T06:41:44.453Z stat a6c9d924117a42a7 v0.47.0 | solo +0 | since 2026-09-06",
  "2026-09-06T06:44:22.770Z room SA8QBK seats 16",
  "2026-09-06T06:44:50.142Z room SA8QBK: RED#2 left",
  "2026-09-06T06:44:50.142Z drop RED#2 (closed) after 186s | in allx250 pingx37 infox13 can_hostx4 join_roomx1 statx1 tox1 leave_roomx1 | headroom 1195/1200",
  "2026-09-06T06:46:56.438Z room SA8QBK: BLUE#3 joined",
  "2026-09-06T06:46:56.559Z stat a6c9d924117a42a7 v0.47.0 | solo +0 | since 2026-09-06",
  "2026-09-06T06:48:28.732Z drop RED#1 room SA8QBK (closed) after 480s | in allx184 pingx91 infox31 lock_roomx5 can_hostx4 host_roomx1 statx1 tox1 set_maxx1 | headroom 1195/1200",
  "2026-09-06T06:48:28.733Z room SA8QBK: host RED#1 left, BLUE#3 promoted",
  "2026-09-06T06:49:52.667Z drop BLUE#3 room SA8QBK (closed) after 176s | in allx61 pingx35 infox12 can_hostx2 join_roomx1 statx1 lock_roomx1 | headroom 1195/1200",
  "2026-09-06T06:49:52.668Z room SA8QBK closed (host_gone, no heir)",
  // quick play that found nobody and hosted its own; the leave comes before
  // the drop, so the drop line names no room
  "2026-09-05T19:41:46.084Z room JHHZHD hosted by ASH#1 (open)",
  "2026-09-05T19:41:46.310Z stat 9208c3c2580ee6a1 v0.45.0 | solo +0 | since 2026-08-26",
  "2026-09-05T19:41:46.324Z room JHHZHD closed (left, no heir)",
  "2026-09-05T19:41:46.325Z drop ASH#1 (closed) after 1s | in quick_joinx1 host_roomx1 can_hostx1 statx1 allx1 infox1 leave_roomx1 | headroom 1196/1200",
  // the daily, with a backlog of solo matches on its stat
  "2026-09-05T23:41:57.256Z room HKTWE2 hosted by CF#1 (daily)",
  "2026-09-05T23:41:57.348Z stat 864907c6cfb15675 v0.45.0 | solo +23 | since 2026-08-27",
  "2026-09-06T00:13:59.476Z room HKTWE2 closed (left, no heir)",
  "2026-09-06T00:13:59.476Z drop CF#1 (closed) after 1922s | in pingx384 infox129 can_hostx2 lock_roomx2 daily_joinx1 statx1 allx1 leave_roomx1 | headroom 1196/1200",
  // a quick play offered a running match that declined it
  "2026-09-06T00:37:40.284Z drop PLAYER#- (closed) after 7s | in quick_joinx1 pingx1 leave_roomx1 | headroom 1199/1200",
  // a spectator
  "2026-09-06T00:26:55.245Z room 5YKZAM hosted by CAM#1 (open)",
  "2026-09-06T00:38:34.641Z room 5YKZAM: RED#2 spectates",
  "2026-09-06T00:38:52.301Z room 5YKZAM: RED#2 left",
  "2026-09-06T00:38:52.301Z drop RED#2 (closed) after 20s | in pingx4 allx2 infox2 quick_joinx1 join_roomx1 can_hostx1 statx1 leave_roomx1 | headroom 1195/1200",
  "2026-09-06T00:38:55.076Z drop CAM#1 room 5YKZAM (closed) after 720s | in allx332 pingx143 infox48 can_hostx2 quick_joinx1 host_roomx1 statx1 lock_roomx1 | headroom 1111/1200",
  "2026-09-06T00:38:55.076Z room 5YKZAM closed (host_gone, no heir)",
  // a room still open when the log was read
  "2026-09-06T13:50:01.391Z room ZZZZZZ hosted by CAM#1 (open)",
];

const events = LINES.map(l => parseLine(l, "2026-09-06T00:00:00.000Z")).filter(Boolean);
const play = derive(events);
const room = code => play.sessions.find(s => s.code === code);

test("lines that say nothing about play parse to null", () => {
  assert.equal(parseLine("2026-09-06T06:40:28.893Z open 100.64.0.3 (1/200)", "x"), null);
  assert.equal(parseLine("Starting Container", "x"), null);
  assert.equal(parseLine("2026-09-06T06:43:23.306Z rooms 1/40 conns 2/200 | sent 145.2KB in 2292 lines | peak 1 rooms 2 conns | stats 9 (solo 25)", "x"), null);
});

test("no name or wire id survives parsing", () => {
  const text = JSON.stringify(events);
  for (const word of ["RED", "BLUE", "CAM", "ASH", "CF", "eb5dd2d0f128b3ac", "864907c6cfb15675"])
    assert.ok(!text.includes(word), `${word} leaked`);
});

test("the drop line is read whole", () => {
  const ev = parseLine(LINES[10], "x");
  assert.equal(ev.kind, "drop");
  assert.equal(ev.code, "SA8QBK");
  assert.equal(ev.why, "closed");
  assert.equal(ev.secs, 480);
  assert.equal(ev.sent.lock_room, 5);
  assert.equal(ev.sent.host_room, 1);
  assert.equal(ev.sent.quick_join, undefined);
});

test("a hosted room with joiners by code: humans, together, matches from the room's locks", () => {
  const s = room("SA8QBK");
  assert.equal(s.mode, "host");
  assert.equal(s.humans, 3);
  assert.equal(s.together, 2);
  // 5 locks from the opener + 1 from the heir = 6 -> three matches, not four
  assert.equal(s.matches, 3);
  assert.equal(s.migrated, 1);
  assert.deepEqual(s.joins.map(j => j.how), ["code", "code"]);
  assert.equal(s.secs, 564);
  assert.equal(s.installs.length, 2);
  assert.deepEqual(s.versions, ["0.47.0"]);
});

test("quick play that hosted its own room is quick, even when the drop follows the close", () => {
  assert.equal(room("JHHZHD").mode, "quick");
  assert.equal(room("JHHZHD").matches, 0);
});

test("the daily is the daily and two locks are one match", () => {
  const s = room("HKTWE2");
  assert.equal(s.mode, "daily");
  assert.equal(s.matches, 1);
  assert.equal(s.humans, 1);
});

test("a spectator counts as a spectator, not a human in the match", () => {
  const s = room("5YKZAM");
  assert.equal(s.mode, "quick");
  assert.equal(s.humans, 1);
  assert.equal(s.spectators, 1);
  assert.equal(s.matches, 1);
});

test("a connection that never got a room number is a bounce", () => {
  assert.equal(play.bounces.length, 1);
  assert.equal(play.bounces[0].tried, "quick");
  assert.equal(play.bounces[0].secs, 7);
});

test("a room open at the end of the record is live", () => {
  const s = room("ZZZZZZ");
  assert.equal(s.live, true);
  assert.equal(s.end, null);
  assert.equal(s.mode, "host");   // provisional until its opener drops
});

test("installs are counted across check-ins with their solo backlog", () => {
  const cf = play.installs.find(i => i.solo === 23);
  assert.ok(cf);
  assert.equal(cf.since, "2026-08-27");
  assert.equal(play.solo.length, 1);
  assert.equal(play.solo[0].n, 23);
  const twice = play.installs.find(i => i.checkins === 2);
  assert.ok(twice, "the joiner checked in twice on two connections");
});

test("sessions come newest first", () => {
  const at = play.sessions.map(s => s.at);
  assert.deepEqual(at, at.slice().sort().reverse());
});
