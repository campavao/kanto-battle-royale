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
