# Compatibility and release notes

**What changed in each release is on the
[releases page](https://github.com/campavao/kanto-battle-royale/releases).**
Each release says in plain language what it changes and whether you can
update without everyone else having to. That is the changelog; this file
does not repeat it.

What this file holds is the part that has no other home: **why** two people
sometimes cannot play together, stated once, plus the per-release technical
detail that does not belong in player-facing notes.

---

## Why two people sometimes cannot play together

Three separate things have to line up. They fail in different ways, at
different moments, and are fixed in different places — which is the whole
reason they are worth telling apart.

| what | must match | what happens if it doesn't |
| -- | -- | -- |
| **wire protocol** | exactly | you cannot share a room at all |
| **engine release** | exactly | you share a room, walk around together, and cannot battle |
| **mod version** | exactly | same as above |

**The wire protocol** is this mod's own. It changes only when the messages
players exchange change shape, and every release says whether it moved. A
release that leaves it alone is one you can take without waiting for your
friends.

**The engine release and the mod version are the engine's rules, not
ours.** `src/link/Handshake.lua` compares the engine's version *string* —
not the major, not the minor — and refuses a battle on any difference at
all. That is deliberate: battle logic changes between releases, so two
installs a release apart would otherwise pair as compatible and then
desync several turns into a fight, which is a worse failure than being
told no. Separately, `src/link/Fingerprint.lua` folds every enabled mod's
`id@version` into the link fingerprint, so two people on different
versions of *this* mod are refused for exactly the same reason.

The awkward part is the shape of that second failure: everything except
fighting works. The room, the roster, the ghosts walking around, dropping
into Kanto together — all of that is this mod's own wire, and it does not
care. Only the battle is refused. Before 0.35.0 nothing said so until the
moment two people tried to fight, and the message named no numbers.

**A source checkout can never battle a packaged build.** The engine
reports `0.0.0-dev` in a working tree — CI stamps the real version into
the packaged game only — so a checkout and a release always mismatch.
Expected, not a bug, and worth knowing before it eats a playtest.

---

## Per-release technical detail

Only where there is something a release note should not carry. Tickets are
Linear (POK-nn).

### 0.36.0 — unreleased

**Wire protocol unchanged at 9,** but one message on it means something new
— see POK-144 below. Requires gen1recomp ≥ 0.2.26, unchanged.

- POK-144 — the end of a match is a funnel. There is no PLAY AGAIN row and
  no `BR:playAgain()`. Every client arms its own ending the moment the
  match ends (`BR:armEnding` → the tick → `BR:endMatch`) and leaves the
  finished world by itself, landing on the BR screen with the result on it;
  the lobby's own start row reads PLAY AGAIN when there is a result to run
  back from. Before this, five routes could end a match and two of them
  reached a teardown.

  **`Wire.again()` changed meaning without changing shape.** It is still
  `{ t = "again" }` and still host-only, but a peer that receives it at
  `"over"` now ARMS its exit rather than taking it, so a host who finished
  the Hall of Fame first cannot pop a guest's Hall of Fame out from under them; anywhere
  else in a session it still takes the exit, which is the recovery it has
  always been. Not a compatibility break, because the mod version has to
  match anyway: the door turns a guest out of a room whose host is on a
  different build (POK-142), and protocol 9 already refuses a pre-0.35.0
  peer's `place`. So nothing carrying the old meaning of `again` can be in
  the room. It is still a wire change, and belongs here.

  Two message-handling changes ride with it: a `start` is no longer refused
  because this client is still standing in the last match (it is torn down
  in full first), and `winner` is refused from any phase that is not a
  round.
- POK-145 — nothing new opens once the match is over. `canOpenBattle()` is
  asked at the moment a battle opens rather than the moment it was queued,
  so a walk-up armed during the match cannot open a fight in a finished
  world, and the 1X clamp holds through `"over"` so the Hall of Fame is
  never fast-forwarded. Wild rolls ask a different predicate,
  `canRollWild()`, which also says yes in `"safari"`: the zone's rule is
  "no trainer fights", not "no wild encounters", and the engine only calls
  `encounter.species` on a non-nil `encounter.roll`, so refusing there
  switches the Safari opening off rather than deferring it.
- POK-155 — the scripted route. `script.command` is wrapped so a gym
  leader, rival, Snorlax, bird or Mewtwo script cannot push its own
  `BattleState` past `encounter.roll` and `trainer.before_battle`. The wrap
  is armed by `BR:onStart` and dropped by `BR:resetMatch` rather than
  living for the process: `Runtime.wantsHook("script.command")` true for
  ever puts every script row of every ordinary playthrough down the
  runner's slower branch. A fight still on screen when the match ends is
  closed out rather than waited on.
- The manifest declares `engine_internals` and the package carries a
  `.modkitignore`, so `modkit.py validate --strict` and `lint` pass. Both
  are packaging only; nothing changes at runtime.

Tests: 1810 unit checks (1765 at 0.35.0), plus a new driver —
`tests/drivers/playtest_over.lua`, which drives every terminal route out of
a match in the running game.

### 0.35.0 — unreleased

**Wire protocol 8 → 9.** Everyone in a room must be on this build.
Requires gen1recomp ≥ 0.2.26, unchanged.

- POK-142 — the room door. `place` gained the sender's engine release and
  mod version, which is the protocol bump; a room now also announces
  itself at the join rather than at the drop, which nothing did before.
  New `lib/door.lua` holds the policy and the copy.
- POK-121 — bot errands and grades. `lib/bots.lua` gained goal selection,
  BFS pathing, dwells and three tiers; `Wire.busy` gained an `as` field so
  the host can mark a bot.
- POK-140 — the Poké Center gate is per-town, resolved through
  `save.lastOutdoor` (pokered's `wLastMap`).
- POK-139 — `battle.exp_award` is suppressed for every battle in a match,
  not just trainer ones. Takes stat experience with it.
- POK-76 — `Gyms.BOSS_BONUS` removed rather than zeroed.
- POK-128 — Elite Four rooms: the shove is cells in `lib/lockstep.lua`,
  the walk-in is a flag in `STORY_FLAGS`, because `map_scripts` composes
  `onEnter` all-run and a mod cannot consume it.
- POK-136 — Cerulean stays whole when the Rocket thief stands down. A live
  softlock in 0.33.0 and 0.34.0.

Tests: 1765 unit checks (1462 at 0.34.0), plus three runnable drivers — a
two-client `door` scenario, the `skew` scenario for the engine's own
refusal (POK-135), and a bot-walk measurement.

Known, not fixed: POK-143 (an Elite Four room seals you in until you beat
its leader).
