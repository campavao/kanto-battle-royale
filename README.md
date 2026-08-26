# Kanto Battle Royale

Prove you're the very best, like no one ever was, in the Kanto Battle Royale!

Play with up to 30 other players at one time, dropping all over Kanto, to be the last one standing. Build up a strong team, avoid Weezing's Fog, and play it cool in ways Satoshi couldn't have imagined in this easy to install [gen1recomp](https://github.com/bryanthaboi/gen1recomp) mod! 

## Install

1. **[Download the latest release zip](../../releases/latest)**
2. Open [gen1recomp](https://github.com/bryanthaboi/gen1recomp), go to Mods, and import downloaded Battle Royale zip file.
    - If the download is not a `.zip` file when you download, compress first and then import
4. Launch the game. `BATTLE ROYALE` is on the title menu.

> **This mod needs gen1recomp v0.2.26 or newer.**

## Getting started

Here are the available options:
1. **Quick Play**
    - Creates a game if none are available, or joins an open game
    - Picks the fullest room available to join
    - Game auto-starts after a while
2. **Solo VS Bots**
    - Solo game which fills the game with bots, up to 30
3. **Host Game**
    - Creates a game with a code that you can invite others to
    - If you enable the option "OPEN" to "YES" then players will be able to join via Quick Play
4. **Join By Code**
    - Allows you to join a game if you know the code
5. **Name**
    - This is your name! It's what shows up in game
6. **Skin**
    - This is your Sprite. Default is RED. You can unlock more as you keep winning.
7. **Server...**
    - I have a dedicated host right now, but you can load up your own server and direct your client via updating this setting.

Info on each game settings can be seen down in the Game lobby options section down below.

## How the game plays

1. **Everyone starts in the Safari**
    - You get a set amount of time to try and catch as many Pokemon as you can
    - Pokemon in the Safari are on a randomized pool
    - If you don't catch any Pokemon before the time runs out, you're out!
2. **Pick where you're dropping**
    - Choose any of the towns to go to after the Safari
    - One town will be at the center of the **Weezing Fog**
3. **Weezing Fog**
    - Over time fog will cover Kanto, circling on one city/town
    - Location is randomized every game
    - You don't know the location until after you drop
    - Fog will hurt all your Pokemon over time
4. **Fight to be the last one standing**
    - Last player standing wins!
    - Every win helps you unlock a new Sprite
    - If you white out, you lose
5. **Spectating**
    - After whiting out, you go into Spectator mode
    - Use Left and Right buttons to swap between Players (or bots)
  
## Tips

- **Catch em all**
  - Fight other trainers and they'll drop their Pokemon for you to collect
  - Fighting other players (and bots) will also drop their bag
  - You can only have a max of 6 Pokemon
  - Battle Gym Leaders to get special Pokemon OR go find and catch Legendaries before someone else
- **You start with all HMs**
  - Catch a Flying type early to have access to Fly, or a Water type for Surf
  - Meant to help you get around Kanto a bit easier, if you have the right Pokemon
- **Apply Moves from the Pokemon screen**
  - Only available outside of battle
  - Swap your Pokemon's moves at any time to be any they can learn
  - Can learn better moves as the game goes on
  - Will automatically include applicable HMs and TMs you have in your bag
  

### Game lobby options

- Code
  - This is the code you'd share out with others for them to join your game
- Player list
  - Represented by a "-" and their name
  - Example "- Red"
- Open
  - Two options: OFF (default) or ON
  - If ON, allows players to join from Quick Play option
- Bots
  - Create a set amount of Bots
- Fog
  - Control how long it takes before the Fog rolls in
- Safari
  - Control how long the Safari intro is
- Debug Log (for nerds)
  - Enables debugging logs locally 
- Fill To
  - Set amount to fill with Bots (if players aren't available)
- Trainers
  - Non-interactive
  - Shows the total count of Trainers that will be in the battle
- Start Match
  - Starts the match!
  - When starting a game via "Quick Play" this kicks off automatically
- Leave
  - Back out of the menu

## Running the relay (for the nerds)

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

## Tests

```sh
luajit mods/battle_royale/tests/br_test.lua        # wire, engage, spawn, a live relay round-trip
luajit mods/battle_royale/tests/br_load_test.lua   # loads through the real headless loader
luajit mods/battle_royale/tests/seams_test.lua     # the engine really has the seams
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

### The two-client PvP harness

The PvP surface — the forced engage, the lockstep battle, the 30-second
shot clock, the loser's spill, PLAY AGAIN — is regression-tested with two
real clients fighting over a local relay:

```sh
python mods/battle_royale/tests/drivers/pvp/run_pvp.py         # duel
python mods/battle_royale/tests/drivers/pvp/run_pvp.py stall   # shot clock
```

The harness boots `relay/server.js` on `127.0.0.1`, launches two LOVE
instances under scripted drivers (`host_*.lua` / `guest_*.lua`, coordinated
through handshake files), and watches both logs: any `PVP FAIL` line fails
the run, both `PVP OK` lines pass it. **duel** walks the guest into the
host's eyeline in Pewter and plays the fight to a KO — asserting the
lockstep battle opens on both clients, the loser's bag hits the ground on
the winner's screen, and PLAY AGAIN returns both to the lobby. **stall**
has the host go silent mid-battle; lockstep means the fight cannot resolve
until they move, so the win must come from the shot clock forfeiting them.

It needs a `gen1recomp` checkout, an imported ROM (`POKEPORT_IMPORT_ROM`),
`node`, and LOVE (`LOVEC` overrides the default path). A run takes a few
minutes — real matches on real wall-clocks, twice.

### The champion's exit

One client and no relay server — a solo room is a `LocalRoom`:

```sh
POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_IDENTITY=br-fame \
  POKEPORT_DRIVER=mods/battle_royale/tests/drivers/fame_smoke.lua lovec .
```

`fame_smoke.lua` hosts a solo match, declares the win (`debugWin` — a
driver cannot play one down to a single survivor in the time it has), sits
through the Hall of Fame, and asserts the champion ends up **off** the
finished world with the room still standing, so PLAY AGAIN can run it
back. `FAME OK` passes it; any `PVP FAIL` line fails it.

`bot_smoke.lua` is the other half of that: it posts on Pewter's street,
drops a bot down the block with `debugPlaceBot`, and checks that the bot
wears a face of its own rather than the viewer's skin, **walks over**
before the fight, and carries its own name from the battle intro on.
`BOT OK` passes it.

### The playtest probes

Three more solo drivers, one per half of the 2026-08-25 playtest batch.
Same shape as the two above — one client, a `LocalRoom`, no relay server:

```sh
POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_SPEED=3 \
  POKEPORT_IDENTITY=br-playtest-drop \
  POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_drop.lua lovec .
```

`playtest_drop.lua` opens a battle in the SAFARI and then sounds the buzzer
with no further input, so the only thing that can close it is the PA
itself; checks the drop picker is the TOWN MAP with a cursor rather than a
list; flies to whichever town is furthest from the announced eye and holds
there to prove phase 1 really is a grace period; and reads the START menu
back to see OPTION and MODS gone and MAP present, then opens the map with
an emptied bag. `DROP OK` passes it.

`playtest_match.lua` is the in-match half: it proves a warp-blind spill
would land on a VIRIDIAN door and that the shipped one does not, that a
ghost is given the player's 16-frame step rather than an NPC's 32, that a
ghost keeps walking with the START menu open, that the eyeline stops
inside the frame — and finally that a fog shrink landing mid-battle does
not level the team until the battle closes. That last probe runs the ring
to the all-fog endgame, so it is deliberately last. `MATCH OK` passes it.

`playtest_hunt.lua` is the endgame: a three-trainer roster with the bots
exiled to opposite corners of Kanto and the fog turned off long enough
that it cannot be what herds them. It watches them cross seams and logs
each move with the distance it closed. `HUNT OK` passes it.

### Reading the logs

A match writes its own story to the client log, one line per beat: the
room, the start (seed, roster, clocks, where you dropped), each ring, every
elimination and what caused it, the winner, the teardown. Every line
carries the room code and the match seed —
`[A7QK/91823] ring 3: eye CELADON CITY at 8,6, radius 7` — and the relay
server prints the same room code on its own lines, so a client log and a
server log for one game can be lined up afterwards.

**DEBUG LOG** in the lobby turns on the tier below that: per-map detail,
and anything else that would otherwise bury the story. It is off by
default on purpose. `mod.exports.setDebug(true)` is the same switch, for
a driver.

> It is not an environment variable. `BR_DEBUG` was documented as one in
> v0.25.0 and never worked in the game: a mod runs inside the engine's
> compat sandbox, where `os.getenv` answers `nil` for any name that is not
> home-like — and warns that it did, putting a line into the very log it
> was meant to help with. It works only under the headless test loader,
> which is why it looked fine.

The relay logs connections with their identity, room create/join/leave, a
census of the message types each connection actually sent when it goes,
and errors with the message and room that caused them — never payloads.

## Credits and licence

MIT, and it ships no game data — you supply your own ROM to gen1recomp.
Built on [gen1recomp](https://github.com/bryanthaboi/gen1recomp) by BOIS CLUB
GAMES, LLC.

Pokemon is a trademark of Nintendo / Creatures Inc. / GAME FREAK inc. This
project is not affiliated with or endorsed by them.
