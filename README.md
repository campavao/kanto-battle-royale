# Kanto Battle Royale

**Last trainer standing.** Everyone drops onto a random spot in Kanto with a
level 5 RATTATA, six Poke Balls and a Potion. You see the other trainers
walking the same world you are; walk into one face-to-face and the battle
starts on its own -- no menu, no consent, like a trainer's line of sight.
Your party is your health, so when your last Pokemon faints you are out. A
Weezing fog closes in on the Town Map until whoever is left is standing in
the same few squares.

The fog shrinks the world on a shared clock, everyone's level rides the
same clock, and a fallen team spills onto the ground as Poké Balls anyone
can claim. See "What's here / what's next" below.

The fog shrinks the world on a shared clock, everyone's level rides the
same clock, and a fallen team spills onto the ground as Poké Balls anyone
can claim. See "What's here / what's next" below.

A mod for [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

## Install

1. **[Download the latest release zip](../../releases/latest)**
2. Extract it into your gen1recomp `mods/` folder, so you end up with
   `mods/battle_royale/main.lua`
3. Launch the game. `BATTLE ROYALE` is on the title menu.

> **Use the release zip, not the green "Code -> Download ZIP" button.** GitHub
> names that folder after the repo, and the mod loads itself by path -- the
> folder has to be called exactly `battle_royale`.

Nothing else to install, **no server to run** (the mod ships pointed at a
hosted relay, so `QUICK PLAY` works immediately), and **no engine patch
required**: the mod carries a
compatibility shim, so it runs on a stock gen1recomp build. (See "...and
running without them" below. The seams it needs are proposed upstream in
[PR #1746](https://github.com/bryanthaboi/gen1recomp/pull/1746); when that
lands the shim stands down on its own.)

## Playing it

**On your own, from a cold start:** pick `BATTLE ROYALE` on the title
screen, then `SOLO VS BOTS`, then `START MATCH`. That is the whole setup.
No server to run, no save to make, no Oak. A solo room fills itself with
eight bots if you haven't picked a number, and the `BOTS` row changes it.

Solo needs no relay because there is nobody to relay to: `lib/localroom.lua`
answers the room protocol for a room of one, so the mod hosts, broadcasts
and runs the same match it always does — the messages just have nowhere to
go. Everything below is the same code path with other people in it.

**With other people, the short way:** `QUICK PLAY`. It joins whatever open
game is running, and if there isn't one it opens yours and counts down from
thirty while it waits for company — bots fill whatever seats are still empty
when the clock runs out. Nobody types a code and nobody has to press start,
so a newcomer with the mod installed is in a real match inside a minute.

The relay picks the *fullest* joinable room rather than the first, so a
handful of strangers arriving at once becomes one match instead of three
lonely lobbies.

**With other people, by invitation:** everyone needs this mod enabled and
the same game version. Play runs over a small relay server (see
[`relay/`](relay/)) so it works over the internet, through NAT, with no
port-forwarding.

1. `START` → `ROYALE` (or `BATTLE ROYALE` on the title screen)
2. `NAME` to pick the trainer name everyone else sees (7 letters, the
   Gen 1 naming grid). `SERVER...` once, to point at your relay as
   `host:port` (default is `127.0.0.1:7790` for a relay on your own
   machine). Both are remembered.
3. One player picks **HOST GAME** and reads out the six-character room code.
4. Everyone else picks **JOIN BY CODE** and enters it.
5. The host can add **BOTS** (the row steps 0, 1, 2, 3, 5, 8, 12, 16, 20,
   25, 30 and wraps) to fill the match out, or set **FILL TO** a number of
   trainers and let bots make up whatever the humans don't. The two compose
   by taking whichever wants more, and `TRAINERS:` shows the total the drop
   will actually hold. Fill is the one you want when you can't know how many
   people turn up.
6. **OPEN: YES** lists the room for `QUICK PLAY`, so strangers can find it
   without a code. Rooms are private until you say otherwise.
6. The host sees the roster fill in and picks **START MATCH**. Everyone
   lands in the SAFARI ZONE at once.

You can run a match entirely on your own: host, set some bots, start.

**The Safari opening.** A match begins with every trainer together in the
SAFARI ZONE centre, on the gate's own admission — thirty SAFARI BALLs and
the 500-step budget — and no Pokémon at all. You have `SAFARI SECONDS`
(a mod option, default 120) to catch what you can; the clock sits top-left,
and nobody can fight anybody until it runs out. Run out of balls or steps
and the PA sends you to the gate early, exactly as it always did, to wait
for the buzzer. When it sounds — "PA: Ding-dong! Time's up!" — everyone
walks to the gate and **picks the town they drop into**, landing on a
random cell of it so a popular choice doesn't stack everyone on one square.
**Caught nothing? You're out** at the buzzer: you brought no team to a mode
where the team is your health. The Safari is closed for the rest of the
match. `SAFARI SECONDS: 0` skips the opening for the old random drop with a
RATTATA.

You start with **all eight badges and all five HMs**, because a match is
twenty minutes and Kanto is gated for a campaign. The badges are what Gen 1
checks before a field move will run at all, and they open the Route 22 gate
and Victory Road. The HMs are still items you have to *teach* to something
compatible — so catch a water type and you can Surf, catch a Machop and you
can move boulders. Where you travel is still what team you can build; the
gyms are just no longer in the way.

Meanwhile the **fog** closes in. See below.

Walk into another trainer — be on the tile facing them — and the battle
begins. Win, lose or run; a lost battle only ends your match if it was your
last Pokémon. **Knock someone out and you take their bag and their money**
(the first slice of the loot spill), and their team hits the ground as
Poké Balls where they fell. **Opening a ball is a gift, not a fight**: it
shows the prompt Oak's lab uses —

> This contains a NIDORINO.
> Do you want it?

— take or leave. The Pokémon joins your party at 1 HP, exactly as it fell;
leaving puts the ball back for the next trainer, and a full party leaves it
too. Reopen `ROYALE` any time to leave the match.

**Beaten means gone.** When anything falls — a player, a bot, or one of
Kanto's own route trainers — its sprite disappears for every client and
only the Poké Balls stay. Walking into an area and finding balls with no
trainer is how you read that somebody else got there first: the world is a
record of the match. Kanto's trainers drop their teams too (at the rung
they fought at), which gives PvE a point beyond levels — and means a route
can be *picked over*.

**The HUD.** Two small boxes in the top corners of the overworld, drawn in
the game's own font: `7 LEFT` on the right is how many trainers are still
in it, and `FOG!` pulses on the left while you are standing outside the
ring. Each bite of the fog is the overworld-poison beat you already know —
the screen flickers dark and the poison chime plays — so you can feel it
without opening a menu.

**Once you are out, you watch.** `LEFT` / `RIGHT` hop between the trainers
still in the match; the box on the left names who you are watching, and
the view follows them — when they leave the map, or get five cells away,
you are warped back to their side. You cannot walk, catch, or fight; you
can turn on the spot and open your (empty) menus, and nothing you do
reaches the match.

A match plays in a throwaway world: **SAVE is disabled from the drop until
you return to the title** and start or continue a real game, so a match can
never overwrite your actual playthrough.

**The rules of a match**, from the drop until it ends and nowhere else:

- **The Safari comes first, and nobody fights in it.** Every battle there
  is a catch; the eyeline and the A press don't engage until you've
  dropped. Caught nothing by the buzzer and you're out.
- Every battle is at the current rung — trainers, bots, wild grass and
  water, the Safari, a bite on a rod. A Lv5 drop never meets a Lv22 Safari
  mon, and a route's PIDGEY is worth catching in the last ring.
- Battles are **SET** style whatever your OPTION row says: no "will you
  change POKéMON?" when the foe faints. SHIFT is free information and a free
  swap, and party-as-health is meant to bite.
- **No nickname prompt** on a catch. The team is disposable and you may
  catch a dozen under fog pressure.
- **A full party means choosing who to release.** At 6/6, a catch or a
  loot-ball take opens the party screen as a picker: drop one to make room,
  or keep the team you have. The released Pokémon lands as a ball at your
  feet, claimable by anyone — trading up leaves a trace. Nothing ever
  reaches a box.
- **Game speed is 1X.** A match has a shared clock and other people in it;
  fast-forward through the fog or slow-motion in a fight is cheating. The
  hotkey and the OPTION rows are ignored until the match ends.
- **LINK is off the START menu.** The mod owns the transport for PvP.
- **SAVE is off the START menu too.** The veto above already made saving
  impossible, but the row still ran the whole vanilla ceremony — the
  confirmation, the jingle, "...saved the game!" — and wrote nothing. A
  menu row that lies gets removed; the veto stays as the guarantee.
- **Every PC is OUT OF ORDER.** Boxes are a second health bar in a mode
  where the party IS your health — deposit fresh Pokémon, fight with one,
  withdraw and repeat — so storage, Pokémon and items both, is unreachable
  until the match ends.

None of these write to your saved options — they hold while a match is live
and your own settings are back the moment it is over.

The start-menu row reads `ROYALE.` while you're in a lobby and `ROYALE*`
once a match is live. The same screen is on the title menu, so a match is
reachable before a save exists — which matters because a match throws its
world away anyway.

## Running the relay

Only for playing with other people — `SOLO VS BOTS` never touches it, and
`QUICK PLAY` needs one only because the strangers are on the other side of
it.

```sh
node mods/battle_royale/relay/server.js   # :7790 (PORT or BR_RELAY_PORT to change)
```

Run it from the repo root, not from inside `relay/`. A process whose working
directory sits inside `mods/battle_royale/` holds a Windows directory handle,
and the headless loader's directory probe (`tests/fs_io.lua` uses
`os.rename(path, path)` there) then reports the mod folder as missing — so
`br_load_test` fails with a confusing "manifest id: nil" while the game
itself loads the mod perfectly well.

Zero dependencies — any machine with Node 18+ and a reachable port is a
server. On a LAN, one player runs it and everyone points `SERVER...` at that
machine's address.

### Hosting it so nobody has to run it

The relay is **raw TCP**, not HTTP — newline-delimited JSON on a socket. That
rules out anything that only forwards HTTP requests (Vercel, Netlify, Cloud
Functions), and it is the one thing to get right when picking a host.

**Railway** works, via its TCP Proxy:

1. New project → Deploy from GitHub repo, pointed at this repository
2. Service → Settings → **Root Directory: `relay`** (Nixpacks then sees
   `package.json` and runs `npm start` on its own)
3. Variables → add **`PORT=7790`**
4. Settings → Networking → **TCP Proxy** → target port **7790**. Railway
   answers with something like `roundhouse.proxy.rlwy.net:23456` — that
   `host:port`, not the HTTP domain it also offers, is what players enter
   under `SERVER...`
5. Settings → **turn App Sleeping off.** A sleeping relay drops every room
   it is holding, and the first player to arrive wakes it into an empty one

`relay/railway.json` pins the builder and start command so steps 2 and 5 are
the only settings that matter.

Fly.io is the other easy fit (it forwards raw TCP by default). Any $4-a-month
VPS works too — the process is a few MB and idles at nothing.

### What it costs, and capping it

Measured rather than guessed. A busy room — four players and thirty bots,
the host relaying every bot's step — moves **about 17 KB/s outbound**:

| | egress |
| --- | --- |
| one busy room, two hours a day | ~3.4 GB/month |
| ten such rooms, two hours a day | ~34 GB/month |
| one room pegged nonstop | ~41 GB/month |

Compute is the other half and barely moves: the process is a few MB and idles
at nothing, but it has to stay awake. On Railway's Hobby plan the included
credit covers a comfortable amount of this; check current pricing rather than
trusting that sentence.

Two ceilings keep it bounded, and the relay logs a line every five minutes
saying where it is against them:

```
rooms 3/40 conns 11/200 | sent 41.2MB in 260431 lines | peak 5 rooms 22 conns
```

- **`BR_MAX_ROOMS`** (default 40) caps concurrent rooms, which is what
  decides the bill — a refused host gets a clear "server is busy" rather
  than a hang, and `QUICK PLAY` cannot squeeze past it by another door
- **`BR_MAX_CONNS`** (default 200) caps sockets, with 24 per IP

The real backstop is Railway's own: **Workspace → Settings → Usage**, where
you can set a spend alert and a **hard usage limit** that stops the service
when hit. Set it. The room cap bounds concurrency, but only the platform
limit bounds money — forty rooms pegged nonstop would be far more traffic
than the plan's credit, and the failure you want is "the relay stops" rather
than a surprise invoice. Solo play keeps working regardless: it never touches
a server.

**Before you host one for other people:** it is a public service with your
name on it. It is deliberately small — no accounts, no persistence, rooms
vanish when their host leaves — and it has flood limits per connection (16KB
lines, 120 lines a second, 16 to a room, a 60-second idle sweep), but it has
no moderation, and anyone with the address can open a room on it.

## How it works

**Transport.** The engine already ships a newline-JSON TCP client in
`src/link/Net.lua` (its relay backend). This mod speaks a tiny **room
protocol** on top of it — host/join by code, then unicast and broadcast
between members — implemented in `relay/server.js` and spoken by
`lib/relay.lua`. A room can be *open*, which is the only thing `quick_join`
looks for; when there are none the relay answers `no_open_rooms` rather than
an error, so the client can turn around and host on the same connection.
That is what makes quick play one round trip whether or not anyone else is
already playing. `network` is the one permission the mod declares, exactly
so it can reach `src.link`.

**Movement.** Kanto movement is a grid: one tile per step. So presence is
one small message per step (about four a second), and each other machine
replays the same deterministic step. Cell coordinates ride along in every
message, so drift corrects itself.

**The other players.** Each is a runtime object (`mod.world:spawnNpc`), not
a sprite drawn over the world — so the tile renderer sorts them, collision
treats them as solid, and `A` finds them, all the engine's own code.
Eliminated players stay visible but walk-through.

**Forced battles.** Walking into someone face-to-face fires a
challenge/accept over the room; the lower room id hosts the lockstep. The
battle itself rides a **channel** (`lib/channel.lua`) tunnelled through the
room and handed to `LinkState` (`LinkState.newFromSession`), which owns
every link mode the game already has. Reimplementing a lockstep battle here
would be a second, worse copy of it. Because the channel is separate from
the room socket, a battle no longer ends your session — the old co-op
limitation is gone.

**The fog** (`lib/fog.lua`) is what turns this from a deathmatch into a
battle royale: a ring that tightens on a shared clock until everyone left is
in the same few squares — and then keeps tightening. The last phase is fog
over the whole of Kanto, so a match with survivors who refuse to fight each
other still ends: whoever lasts longest inside it wins, and that is a
tiebreak, not the plan.

Drawing it took one decision worth knowing about. Kanto here is not a single
canvas the way Hoenn was in the sibling project — it is 222 separate maps
stitched by warps, with no global coordinate space to put a circle in. But
the game already ships Kanto's real geography: `field.townMap.locations`
gives **every** map a cell on the 16×16 Town Map grid, interiors included (a
building sits on its town's square). So the ring is a circle in *Town Map
space*, and a map is safe when its square falls inside it. The fog therefore
follows the Kanto you know — it closes on a named place, the routes around
it go first, and hiding in a building doesn't help because the building is
on the same square as the town.

Outside the ring, every Pokémon in your party loses **a tenth of its maximum
HP every four seconds** — about forty seconds from full to fainted. It is a
fraction rather than Gen 1's flat 1-HP-per-4-steps because a flat point does
not survive level scaling: it would kill a Lv5 starter in a minute and take
twenty patient minutes against a Lv100 team, which is exactly backwards. The
fog has to bite hardest when the ring is smallest. Nothing is immune to it:
a Poison lead used to be (DESIGN D11), and it played badly — Kanto is full
of Zubat and Nidoran, so the common case was a team that ignored the ring
for a whole match. Losing your last Pokémon to the fog eliminates you
exactly like a whiteout.

The fog does not stop at the battle screen. In a wild or route-trainer
fight outside the ring **both sides keep taking the bite** — but the two
Pokémon actually on the field are drained only to 1 HP, never fainted: the
engine only knows how to faint a mon through its own move flow, so the fog
brings a battle to the brink and the killing blow is thrown inside it.
(PvP and bot fights are exempt: two machines biting HP outside the
lockstep is a desync, and both players sit in the same fog anyway.)

The host owns the clock and announces each shrink; nobody derives it from
their own wall clock, which would drift. Bots take the fog on the same terms
you do — they cannot walk between maps, so a bot the ring leaves behind is
a bot that dies in it, and its team hits the ground like anyone else's.

Kanto's own trainers are not spared either: a map the ring has left gets
one shared clock with the same grace you get, and when it runs out every
trainer on it is gone, on every client. They spill nothing — balls on the
ground mark a kill somebody *earned* — so a route the fog has taken is
simply empty, and the survivors' PvE shrinks with the world.

`FOG SECONDS` (a mod option, default 120) is how long each ring lasts. The
schedule is eight rings — the whole map, then 9, 7, 5, 3 and 1.5 squares
around the centre, then the centre's own square, then nothing — so a default
match reaches the all-fog endgame at sixteen minutes and a quick one can be
far shorter.

**Open the TOWN MAP to see it.** The ring is a circle in town-map space and
the TOWN MAP draws that exact grid, so the item you already reach for to
work out where you are also shows you where it is safe to be: taken squares
are shaded over, the ring is what stays clear, and a box marks its eye. It
is an overlay (`render.hud`) rather than a replacement screen — overriding
the town map's id would mean owning its background, cursor, fly list and
nest markers forever, to add one circle.

**Party as health.** A whiteout is elimination, however it happened — a bot,
a route trainer, a wild Pokémon — which the mod picks up from the engine's
`world.blacked_out`. PvP is the exception that needs its own path: link
battles follow cable rules and never touch your real party, so the mod reads
the lockstep party copy off `link.battle_ended` and copies the damage back
itself. The host is the authority on who's left and declares the winner.

**The Safari opening, and the drop.** The host deals every spawn once
(`lib/spawn.lua`, `Spawn.pickIn`: distinct walkable cells of the SAFARI
ZONE centre) and sends the list with the round's length; nobody else has to
agree on the algorithm, only on the answer. The Safari itself is the
engine's own — `save.safari` with thirty balls and the 500-step budget, the
BALL/BAIT/ROCK/RUN battles, the PA game-over — with three things added from
outside: a clock the host owns and re-announces every five seconds (like
the fog's, nobody derives it from their own wall clock), the centre's exit
warps refused while it runs, and a stand-in lead lent for exactly one
encounter while the party is empty — the engine refuses to open a battle
with nobody on your side, and never draws your lead in a Safari battle
anyway, so the stand-in is inserted as the roll lands and gone with the
screen. At the buzzer the vanilla game-over walks you to the gate, the
picker opens there (a `ListMenu` over the fly-town list), and you land on
a random cell of the town you chose. Bots pick a town the same way,
host-side. The fog's clock starts on the host's landing, so the Safari never
eats into the first ring. `SAFARI SECONDS: 0` is the old drop — `Spawn.pick`,
a random walkable, non-water cell on a random outdoor Kanto map, dealt
round-robin, with a RATTATA.

**Bots** (`lib/bots.lua`) fill a match out and make it playable solo. They
take spawns from the same list as everyone else, and the host walks them —
relaying each step tagged `as = <bot id>`, so every client renders them
through the same ghost driver a human gets. Only the host's `as` is
honoured, so nobody can puppet another trainer.

Everything *about* a bot — its name, its team — is derived from the match
seed and its id rather than sent, so every client computes the same answer.
That matters because a bot has no client to run a lockstep battle with:
whoever walks into one fights it **locally**, as an ordinary trainer battle
whose party comes from `Bots.party` through the engine's own `trainer.party`
hook. If two clients disagreed about the team, they would disagree about who
won. The winner tells the room (`botout`); the host recounts the survivors.

A bot drops with one Pokémon at the starting level, the same as a player —
two made the bot the favourite in every opening fight, which ended most
matches before anyone could build a team.

**How many bots?** Up to **30**, verified live end-to-end. Kanto has 34
outdoor maps, so thirty bots each get a route or town of their own and the
drop stays spread out. The limit above that is the wire rather than the
world: the host relays one step per bot per beat, about 1.4 messages a
second each, against the relay's 120-a-second flood guard — thirty sits near
40/s with comfortable room for everyone's own movement and a battle in
flight, while sixty would be at three quarters of the cap before a fight
starts. Going much past thirty wants area-of-interest relaying (only
broadcast a bot when somebody is on its map), which is DESIGN D6 and would
make the count nearly free.

Bot steps are paced in **real seconds**, not ticks. A bot's step is ambience
that happens to be network traffic, and tying its rate to the host's logic
clock means a fast-forwarding player floods the relay off its own connection.

## Engine additions

This mod needs a few small, generic engine seams that stock gen1recomp does
not have. They are proposed upstream -- the first batch as
[PR #1746](https://github.com/bryanthaboi/gen1recomp/pull/1746) (RFC 0014),
the battle-rule hooks and the full-party catch hook as RFCs 0015 and 0016 to
follow; until they land, `lib/shim.lua` installs them from outside, so you do
not need a patched build:

| Where | What | Why |
| --- | --- | --- |
| `src/world/WorldAPI.lua` | `Handle:stepNow / canStep / placeAt / isMoving / setPassable` | drive a networked actor without the scripted-move queue freezing your controls |
| `src/world/OverworldController.lua` | the `world.talk` hook around the NPC talk path | a runtime object has no `TEXT_*` id, so the mod claims the `A` press |
| `src/link/LinkState.lua` | `LinkState.newFromSession` + the `adopted` stage, and the `link.battle_ended` event | adopt an already-paired transport and skip the connect UI; report the battle's outcome + party so a mode above it can react |
| `src/core/Game.lua` | `Game:startNewGame(opts)` (with `intro=false`) | start a fresh game straight into the world, so a match can drop you in without Oak's speech |
| `src/battle/BattleState.lua` | the `battle.style` and `catch.nickname` hooks | force SET and skip the nickname prompt for a match without writing the player's OPTION row |
| `src/battle/BattleState.lua` | the `catch.party_full` hook (`partyFullDestination`) | hand a full-party catch to the mod's own picker instead of laundering it through a PC the mode has locked |

All of them are generic — any mod with a self-driven actor, an adopted link
transport, its own new-game flow, or a rule it wants to hold for a while
wants them. The first four are proposed upstream as **RFC 0014**, the two
battle-rule hooks as **RFC 0015**, and the full-party catch hook as
**RFC 0016**.

### ...and running without them

`lib/shim.lua` installs the same behaviour from outside on an engine that
does not have the seams, so **this mod folder works on a stock build too**.
On an engine that has them it does nothing at all. The boot log says which:

```
battle royale: engine has every seam natively
battle royale: shimmed: world.talk (interact wrapper), CodeEntry (...), ...
```

It is a fallback, not a design. Patching engine modules from a mod is worse
than a hook in every way that matters — two mods patching one function
clobber each other instead of chaining, and there is no version contract, so
an upstream refactor breaks it silently. Each patch therefore touches one
function, and the summary line keeps "still shimming X" visible instead of
letting it become the permanent normal.

Five of the six are values that are either there or not. `world.talk` is
the awkward one: a call site in the *middle* of `interact()`, so there is
nothing to extend and no way for a mod to see whether it exists. The shim
raises the hook first and hands the press back to the untouched original
whenever nobody claims it, and decides whether it is needed at all by asking
whether the other four are native — they ship in one commit. Guessing wrong
would raise the hook twice for one press, so it fails toward not patching.

Two known gaps, both harmless here: an object reached *across a counter* is
not claimed by the shimmed path (a ghost is never behind a mart counter),
and `os.time` is denied to mods, so a shimmed `startNewGame` does not stamp
`sessionStartedAt` — a match world is thrown away, and nothing reads it.

The two battle-rule hooks are the newest and the least clean to shim.
`catch.nickname` is fine: the prompt is its own method, so the patch asks the
hook first and, when it declines, fills the engine's reserved queue slot with
a text box that closes itself. `battle.style` is not: the stock engine reads
the OPTION value inline at the moment the foe faints, inside a function far
too big to replace, so the shim swaps the value for the battle's duration
(`enter` to `finish`) and puts it back. That is exactly the write-the-row
workaround the seam exists to avoid — one speed-hotkey press mid-battle
persists SET to disk, and the restore repairs it on the next press. It is
reported in the boot line like everything else, so it cannot quietly become
the normal.

`catch.party_full` is the same shape of problem as `world.talk` — a call
site in the middle of `storeCaughtMon` — but it has a name to check: a seam
engine answers through `BattleState:partyFullDestination()`, so the shim
stands down by looking for the method. Without it, the shim asks the hook
from inside `Boxes.deposit`, and a claim refuses the deposit so nothing
reaches a box either way. What that cannot repair is the text: the stock
branch prints "But every BOX is full!" before the mod's picker opens — the
wrong reason for the right decision, and the argument for the seam.

`tests/shim_test.lua` runs the same assertions on both engines and is the
thing that proves the fallback is honest; run it in either tree.

## What's here / what's next

**Here (v0):** rooms + lobby over a relay with name entry, bots (up to 30,
so a match is playable solo), the Safari opening (everyone together, two
minutes, no starter, caught nothing = out) and a choose-your-town drop, the
shared loadout plus all
badges and HMs, real-time presence, forced face-to-face battles, the
shrinking fog on a shared clock that closes all the way, party-as-health
elimination from any whiteout, victor-takes-the-bag loot, a save-slot guard
(matches can't overwrite a real save), last-trainer-standing. Route
trainers are PvE that pays out: beat one and its team spills, its sprite
goes, for everyone.

**Next** (from the design in the sibling `pokemon-battle-royale` project's
`docs/DESIGN.md`): loose item/money pickups on the ground to finish D8 (the
bag still transfers straight to the victor); the per-pair re-engage cooldown
and escape tools of D9; Repel shrinking your own eyeline; type-based
overworld abilities (D18/D20); and bots that pick
a fight with a *player* on sight rather than only closing distance.

## Tests

```sh
luajit mods/battle_royale/tests/br_test.lua        # wire, engage, spawn, a live relay round-trip
luajit mods/battle_royale/tests/br_load_test.lua   # loads through the real headless loader
luajit mods/battle_royale/tests/shim_test.lua      # the seams, native or shimmed
cd mods/battle_royale/relay && node --test && cd -  # the relay server over real sockets
```

The Lua suites use gen1recomp's own test harness, so run them from the root
of a gen1recomp checkout with this repo installed at `mods/battle_royale/`.
`relay.test.js` is standalone — it only needs Node.

Run the Lua tests with no shell or server parked inside `mods/battle_royale/`
(see the relay note above) — `cd -` in that last line is deliberate.

The Lua tests need no imported ROM (the relay round-trip runs over an
in-memory hub; the spawn test uses the imported Kanto data when present and
skips cleanly when it isn't). `relay.test.js` drives `server.js` over real
loopback sockets.

## Credits and licence

MIT, and it ships no game data — you supply your own ROM to gen1recomp.
Built on [gen1recomp](https://github.com/bryanthaboi/gen1recomp) by BOIS CLUB
GAMES, LLC.

Pokemon is a trademark of Nintendo / Creatures Inc. / GAME FREAK inc. This
project is not affiliated with or endorsed by them.
