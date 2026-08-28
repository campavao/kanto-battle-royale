-- Kanto Battle Royale: last trainer standing.
--
-- Shape of the thing:
--   lib/wire.lua     the room message vocabulary (pure, headless-testable)
--   lib/relay.lua    the connection to relay/server.js (over src/link/Net.lua)
--   lib/spawn.lua    where everyone drops (pure)
--   lib/engage.lua   the forced-battle rule (pure)
--   lib/ghosts.lua   the other players as real overworld NPCs
--   lib/channel.lua  one battle's transport, tunnelled through the room
--   lib/menu.lua     the BATTLE ROYALE start-menu screen
--   lib/career.lua   the name/skin/wins that outlive a playthrough
--   lib/stats.lua    how much play there has been (never opens a socket)
--   this file        the wiring
--
-- The loop, once a match starts: everyone drops onto a random Kanto cell
-- with a level 5 RATTATA, six POKe BALLs and a POTION; you see each other
-- walk in real time; walk into someone face-to-face and the battle starts
-- with no prompt; your party is your health, so a whiteout puts you out;
-- last trainer standing wins.
--
-- Two directions to keep straight.  Outbound: local steps/turns become
-- room messages (off movement.speed and a per-tick facing check).  Inbound:
-- the relay's messages drive the ghosts and the engage/battle handoff.
--
-- Everything runs on the engine's 60 Hz fixed step (the input.step hook),
-- so there is no thread and no lock anywhere in here.

local Wire = require("mods.battle_royale.lib.wire")
local Relay = require("mods.battle_royale.lib.relay")
local Spawn = require("mods.battle_royale.lib.spawn")
local Engage = require("mods.battle_royale.lib.engage")
local Ghosts = require("mods.battle_royale.lib.ghosts")
local Channel = require("mods.battle_royale.lib.channel")
local LocalRoom = require("mods.battle_royale.lib.localroom")
local Seams = require("mods.battle_royale.lib.seams")
local Bots = require("mods.battle_royale.lib.bots")
local Fog = require("mods.battle_royale.lib.fog")
local Safari = require("mods.battle_royale.lib.safari")
local Rods = require("mods.battle_royale.lib.rods")
local Levels = require("mods.battle_royale.lib.levels")
local Spills = require("mods.battle_royale.lib.spills")
local Flee = require("mods.battle_royale.lib.flee")
local MoveKit = require("mods.battle_royale.lib.moves")
local Fame = require("mods.battle_royale.lib.fame")
local Gyms = require("mods.battle_royale.lib.gyms")
local Peek = require("mods.battle_royale.lib.peek")
local BRMenu = require("mods.battle_royale.lib.menu")
local Machines = require("mods.battle_royale.lib.machines")
local Career = require("mods.battle_royale.lib.career")
local Coexist = require("mods.battle_royale.lib.coexist")
local Lockstep = require("mods.battle_royale.lib.lockstep")
local Stats = require("mods.battle_royale.lib.stats")
local Door = require("mods.battle_royale.lib.door")
local Log = require("mods.battle_royale.lib.log")
local Despawn = require("mods.battle_royale.lib.despawn")

local SCREEN = "BattleRoyaleMenu"
-- The relay the mod ships pointed at, so downloading it and pressing QUICK
-- PLAY needs no configuration.  SERVER... overrides it, and SOLO VS BOTS
-- never touches it -- if this host is ever down or gone, a solo match still
-- works and anyone can run their own (see relay/).
local DEFAULT_RELAY = "maglev.proxy.rlwy.net:55436"

-- Full position resync cadence: steps and turns keep a ghost honest, this
-- is insurance against a dropped message and against a peer moving in a way
-- we do not model (a warp).  5 seconds at 60 Hz.
local RESYNC_TICKS = 300

-- How often a bot takes a beat, in REAL seconds (it may still stand still).
--
-- Wall clock rather than ticks on purpose.  A bot's step is not simulation,
-- it is ambience that happens to be network traffic: one broadcast per bot
-- per beat, from the host, to everyone.  Pacing it on the logic clock ties
-- the send rate to how fast the host's loop happens to run -- a
-- fast-forwarding player, or a scripted run stepping logic as fast as it
-- can, turns a stroll into hundreds of messages a second and the relay
-- rightly drops the connection as a flood.  Seconds keep bots walking at a
-- human pace and the traffic bounded, whatever the host's clock is doing.
local BOT_STEP_SECONDS = 0.45
local FOG_SHELTER_SECONDS = 30    -- a bot fight blocks the fog this long (POK-63)
-- what SOLO VS BOTS fills an empty roster with: enough that the match has a
-- shape to it, few enough that the first fight is not immediate
local SOLO_BOTS = 8
-- QUICK PLAY aims at this many trainers and lets bots make up the shortfall
local QUICK_FILL = 8
-- ...and starts on its own after this long, so a newcomer who quick-plays
-- into an empty relay is playing rather than staring at a roster of one
local QUICK_START_SECONDS = 30
-- somebody arriving late deserves a moment to see the lobby before the drop
local QUICK_START_GRACE = 10

-- The trainer class a bot fights as when it has no look of its own -- a
-- build missing every sheet in Bots.LOOKS.  The class supplies the pic
-- and the AI temperament; the party comes from Bots.party through the
-- trainer.party hook, and the NAME is overlaid with the bot's own.
-- Bots.look is what normally decides this now (POK-89): one hardcoded
-- class meant every bot in Kanto was the same YOUNGSTER.
local BOT_TRAINER_CLASS = "OPP_YOUNGSTER"

-- What beating a bot is worth.  Bots do not carry a real bag, so this is
-- authored rather than transferred: enough to be worth the fight.
local BOT_LOOT = { items = { { id = "POKE_BALL", n = 2 }, { id = "POTION", n = 1 } },
                   money = 500 }

-- The starting loadout, all in one place (docs/DESIGN.md D7).
local START_SPECIES = "RATTATA"
local START_LEVEL = 5
-- TOWN_MAP: the fog ring draws on the TownMap screen, so the map is match
-- equipment, not a collectible (POK-39)
-- SECRET_KEY rides along (POK-69): BLAINE's door is `blocked = not
-- inventory.SECRET_KEY`, and the mansion crawl for it has no place in a
-- twenty-minute match when the gym is a POK-26 objective.
local START_ITEMS = { POKE_BALL = 6, POTION = 1, TOWN_MAP = 1, SECRET_KEY = 1,
                      [Rods.FIRST] = 1 }
local START_MONEY = 3000

-- Every badge and every HM, from the drop.
--
-- Kanto is gated for a story campaign, and a battle royale has no campaign:
-- a match is twenty minutes long, so a player who catches a water type
-- should be able to SURF on it now, not after beating Koga.  The badges are
-- what Gen 1 checks before letting a field move run at all
-- (Cut/CASCADE, Fly/THUNDER, Surf/SOUL, Strength/RAINBOW, Flash/BOULDER),
-- and they also open the Route 22 gate and Victory Road (field.badgeGates).
--
-- The HMs are still ITEMS you have to teach to something compatible, so the
-- traversal is earned by catching the right Pokemon -- which is exactly the
-- "where you travel is what team you can build" loop the design wants
-- (DESIGN D13), just without the gyms in the way.
local START_BADGES = {
  "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE",
  "SOULBADGE", "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE",
}
local START_HMS = { "HM_CUT", "HM_FLY", "HM_SURF", "HM_STRENGTH", "HM_FLASH" }

-- The Safari opening (POK-21): a match starts with everyone together in the
-- SAFARI ZONE on the gate's own admission -- thirty SAFARI BALLs and the
-- 500-step budget -- catching what they can until the PA calls time.  No
-- starter: the Safari IS the team-building phase, so a player who catches
-- nothing brought no team to a team-as-health mode and is out at the
-- buzzer.  The steps and the balls are the real game's limits; the clock
-- is ours, and the host owns it the way it owns the fog's.
local SAFARI_MAP = "SAFARI_ZONE_CENTER"
local SAFARI_BALLS = 30
local SAFARI_STEPS = 502          -- what the gate script writes (data/scripts/safari.lua)
local DEFAULT_SAFARI_SECONDS = 120
local SAFARI_BEAT_SECONDS = 5     -- how often the host re-announces the clock
-- How long the PA humours a battle that is still open at the buzzer
-- (POK-92).  Long enough for a ball already in the air to land -- a throw
-- and its shakes run about two seconds -- and far too short to hide in.
local BUZZER_BATTLE_GRACE = 3
-- How long a finished match stays standing (POK-144).  The banner gets read
-- before the world goes, and nothing holds a match that is already over
-- open past the deadline -- a screen that never goes quiet is exactly the
-- state this exists to leave.  The end-of-match battle close reuses
-- BUZZER_BATTLE_GRACE above: a throw in flight deserves the same grace at
-- the win as at the buzzer (POK-155).
local END_GRACE_SECONDS = 4
local END_DEADLINE_SECONDS = 15
local PVP_TURN_SECONDS = 30       -- the PvP shot clock: pick or forfeit (POK-59)
-- the two south warps out of the centre, to the gate: there is no leaving
-- early -- the buzzer is the only way out
local SAFARI_EXIT_WARPS = { { x = 14, y = 25 }, { x = 15, y = 25 } }
-- the gate's door on FUCHSIA CITY: shut for the rest of the match
local SAFARI_DOOR = { map = "FUCHSIA_CITY", x = 18, y = 3 }
-- story rooms locked during a match (POK-51): any warp leading here refuses
local CLOSED_DOORS = { OAKS_LAB = true }

-- Story flags a fresh Kanto save normally earns in Pallet/Oak's lab.  Set
-- at match start so the intro scripts never fire and the towns are free to
-- walk, while every route/gym trainer stays live as PvE.
local STORY_FLAGS = {
  "EVENT_FOLLOWED_OAK_INTO_LAB", "EVENT_GOT_STARTER", "EVENT_GOT_POKEDEX",
  "EVENT_GOT_POKEBALLS_FROM_OAK", "EVENT_PALLET_AFTER_GETTING_POKEBALLS",
  "EVENT_GOT_OAKS_PARCEL", "EVENT_OAK_GOT_PARCEL",
  -- the rival's story ambushes never fire in a match (POK-67): every one
  -- of his scripted fights gates on its own beaten-flag, so the loadout
  -- says they all already happened.  The names are the engine scripts'
  -- own set_flag/check_flag strings (data/scripts/story*.lua).
  "EVENT_BATTLED_RIVAL_IN_OAKS_LAB",
  "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE", "EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE",
  "EVENT_BEAT_CERULEAN_RIVAL", "EVENT_BEAT_SS_ANNE_RIVAL",
  "EVENT_BEAT_POKEMON_TOWER_RIVAL", "EVENT_BEAT_SILPH_CO_RIVAL",
  -- the arena is walkable (POK-69): the roadblocks a story campaign
  -- meters out are already down when a match begins -- both Snorlax
  -- (hideBeatenSnorlax reconciles the sprites away on entry), the
  -- thirsty Saffron gate guards, and the tower's ghost MAROWAK.  The
  -- rest of Kanto's chases (a bike, the SS ticket, the CARD KEY, the
  -- SILPH SCOPE) stay vanilla: going and getting one is fair play.
  "EVENT_BEAT_ROUTE12_SNORLAX", "EVENT_BEAT_ROUTE16_SNORLAX",
  "EVENT_GAVE_GUARDS_DRINK", "EVENT_BEAT_GHOST_MAROWAK",
  -- POK-128.  The Elite Four rooms walk a first-time visitor six cells
  -- north (data/scripts/story4.lua e4ExitSeal).  That half is an onEnter,
  -- and map_scripts composes onEnter ALL-RUN, so unlike the shove beside
  -- it (lib/lockstep.lua) a mod cannot consume it -- the flag is the only
  -- lever.  Saying the walk already happened costs a match nothing: it
  -- gates one cutscene and nothing else reads it.
  "EVENT_AUTOWALKED_INTO_LORELEIS_ROOM",
  "EVENT_AUTOWALKED_INTO_BRUNOS_ROOM",
  "EVENT_AUTOWALKED_INTO_AGATHAS_ROOM",
}

return function(mod)
  -- On an engine that already has the seams (RFC 0014) this does nothing.
  -- On one that does not, it installs them from outside so the same mod
  -- folder runs on a stock build.  First, because everything below assumes
  -- they exist.

  -- The match log (POK-86).  say() is the story, deep() is off unless
  -- someone asks (DEBUG LOG in the lobby), and both carry the room code
  -- and seed so this log
  -- and the relay's own can be lined up afterwards.
  local log = Log.new(mod.log)
  -- Wall clock, or nil where there is no LOVE under us (the headless test
  -- loader).  Defined up here rather than beside its first caller because
  -- a Lua local is only in scope BELOW its line: half the file used to be
  -- above it and hand-rolled `(love.timer and love.timer.getTime and
  -- love.timer.getTime()) or 0` instead -- six copies of a helper that
  -- already existed, and each one indexing `love` without checking it is
  -- there at all.  `clock() or 0` is the same expression for callers that
  -- want a number rather than the absence of one.
  local function clock()
    if love and love.timer and love.timer.getTime then return love.timer.getTime() end
    return nil
  end
  -- One line at boot saying whether this engine really has what the mod
  -- is built on (POK-29).  manifest.json gates the version, but a fork or
  -- a local build can still be missing a seam, and a named complaint here
  -- beats a stack trace three screens later.
  if Seams.ok() then
    log:say("battle royale: %s", Seams.summary())
  else
    log:warn("battle royale: %s", Seams.summary())
  end

  -- The BAG on the ground (POK-25) is our own 16x16 sheet, drawn in the
  -- item ball's four shades -- Gen 1 has no bag sprite -- and registered
  -- like any mod actor.  If the registry will not take it, the POKeDEX
  -- prop stands in and the loot still lands.
  do
    local ok, err = pcall(function()
      mod.content.sprites:register("SPRITE_BR_BAG", {
        image = "mods/battle_royale/assets/bag.png", frames = 1, walker = false,
      })
    end)
    if ok then
      Spills.BAG_SPRITE = "SPRITE_BR_BAG"
    else
      mod.log:warn("bag sprite not registered (%s); the POKeDEX stands in", tostring(err))
    end
  end

  -- The move-scoring layer an ai-tier bot fights with (POK-160): a
  -- record in the same ai_classes registry the vanilla three passes
  -- live in, named from the trainer overlay in startBotBattle.  Inert
  -- for every other battle -- nothing else's aiMods names it.  A
  -- registry that will not take it degrades to the vanilla passes.
  do
    local ok, err = pcall(function()
      mod.content.ai_classes:register("BR_BOT_MOVES", Bots.MOVE_LAYER)
    end)
    if not ok then
      mod.log:warn("bot move layer not registered (%s); vanilla AI stands in",
                   tostring(err))
    end
  end

  mod.options:define({
    { key = "relay", label = "RELAY", type = "text", default = DEFAULT_RELAY },
    -- seconds per ring, not minutes: a short game wants 30, a long one 300
    { key = "fog", label = "FOG SECONDS", type = "number",
      default = Fog.DEFAULT_PHASE_SECONDS, min = 5, max = 600 },
    -- the Safari opening's clock; 0 skips it for the old random drop with
    -- a RATTATA, which is what the smoke drivers still expect
    { key = "safari", label = "SAFARI SECONDS", type = "number",
      default = DEFAULT_SAFARI_SECONDS, min = 0, max = 600 },
  })

  -- The career (POK-120) comes off mod.cache, which is keyed by mod id
  -- alone and so outlives the throwaway NEW GAME a match is played in.
  local career = Career.load(mod)
  -- The install id and the solo counter (POK-124).  Reading this cannot
  -- block: mod.cache is a local file, and nothing in lib/stats.lua ever
  -- touches the network.
  local stats = Stats.ensure(mod)

  local BR = {
    relay = nil,
    ghosts = Ghosts.new(mod),
    spills = Spills.new(mod),
    game = nil,
    phase = "off",        -- off | lobby | safari | drop | match | over
    status = "lobby",     -- my status: lobby | alive | battle | out
    players = {},         -- id -> { name, map, x, y, facing, sprite, status }
    myId = nil,
    sentFacing = nil,
    sentMap = nil,
    resync = 0,
    pending = nil,        -- an outstanding challenge { to, nonce, host }
    battle = nil,         -- active fight { channel, opponentId, isHost }
    nonceSeq = 0,
    pendingSays = {},     -- says waiting for a free runner (POK-49/POK-50)
    despawns = Despawn.new(),  -- beaten trainers, hidden on a quiet frame
    stats = nil,          -- the run's record: catches, beats, steps (POK-47)
    pendingParade = nil,  -- when the champion's ending should start (POK-47)
    pendingFame = nil,    -- a parade that belongs to somebody else (POK-107)
    winnerId = nil,       -- who the host crowned (POK-107)
    pendingEnd = nil,     -- the exit is DUE: { why, earliest, deadline } (POK-144)
    parading = nil,       -- the Hall of Fame STATE, while one is on the stack
    overBattleAt = nil,   -- when the ending first found a battle still open (POK-155)
    lastResult = nil,     -- what the screen we land on has to say (POK-144)
    endingMatch = false,  -- an exit is in flight; endMatch must not re-enter
    arming = nil,         -- { map, x, y } while save.new_game reshapes the skeleton
    refusedBattle = nil,  -- the last battle never ran, so its blackout is not a loss (POK-134)
    started = false,      -- have I dropped into the world yet this match
    myName = career.name, -- chosen on the NAME row; nil falls back to the save
    skin = career.skin,   -- the walk sheet every other trainer sees (POK-79)
    wins = Career.cleanWins(career.wins),  -- career wins: the wardrobe's key
    matchWorld = false,   -- in a BR world: SAVE stays vetoed until a real save
    tearingDown = false,  -- an exit is already in flight (POK-115)
    wasHost = false,      -- were we the host as of the last roster (POK-116)
    matchFog = nil,       -- the starting host's fog phase length (POK-116)
    safariPool = nil,     -- this match's rotating zone (POK-118)
    -- Who the last battle was against, kept OUTSIDE self.battle on purpose:
    -- the channel (and with it self.battle) is torn down by LinkState before
    -- link.battle_ended reaches us, so reading the opponent off self.battle
    -- in that handler finds nil and the loot goes nowhere.
    lastOpponent = nil,
    fledFrom = {},        -- opponent id -> how often we ran from them (POK-24)
    fleeGrace = {},       -- opponent id -> clock until neither of us engages
    fleeLockout = {},     -- opponent id -> clock until we may initiate on them
    fleeing = nil,        -- who we are running from, while the battle unwinds
    peeked = nil,         -- what the trainer we watch carries, as last answered (POK-18)
    lastPeekAt = nil,
    botCount = 0,         -- how many bots the host will add at start
    fillTo = 0,           -- ...or top the roster up to this many, 0 = off
    solo = false,         -- hosting a room of one, with no server
    quick = false,        -- came in through QUICK PLAY, so it self-starts
    fellAt = nil,         -- where a whiteout caught us, to spectate from
    autoStartAt = nil,    -- quick play starts itself at this clock time
    lastRoster = 0,       -- to notice an arrival and hold the countdown open
    matchSeed = nil,      -- every client derives bot names/parties from this
    botFight = nil,       -- the bot id we are locally fighting right now
    botRecords = {},      -- id -> persistent team, POK-158 (see botRecord)
    botParty = nil,       -- handed to the trainer.party hook for one battle
    ring = nil,           -- { phase, center = {x,y,id,name}, radius }
    matchStartedAt = nil, -- host only: when the shared clock started
    lastFogTick = nil,    -- when the fog last took its bite out of us
    wasInFog = false,     -- so entering the fog is announced once
  }

  local function say(text) BRMenu.say(mod, text) end

  -- A say that must not be lost.  The runner refuses a script while one is
  -- running (POK-49), and a say issued the frame of a warp can be eaten by
  -- a held button (POK-50) -- so park it here and let tickSays deliver it
  -- once the runner is free and the delay has passed.
  local function sayLater(text, delay)
    local now = clock() or 0
    local q = BR.pendingSays
    q[#q + 1] = { text = text, at = now + (delay or 0) }
  end

  -- ------- relay address (a mod option, editable from the menu)

  function BR:relayAddress()
    return mod.options:get("relay") or DEFAULT_RELAY
  end

  function BR:setRelayAddress(addr)
    mod.save:set("relay", addr)   -- remembered per playthrough
    mod.options:define({          -- and live for this session
      { key = "relay", label = "RELAY", type = "text", default = addr },
    })
  end

  -- ------- identity + presence

  local function myName()
    if BR.myName then return BR.myName end
    local save = BR.game and BR.game.save
    return Wire.cleanName(save and save.player and save.player.name or "PLAYER")
  end

  function BR:playerName() return myName() end
  function BR:maxBots() return Bots.MAX end
  function BR:nextBotCount() return Bots.nextCount(self.botCount) end

  function BR:setName(name)
    self.myName = Wire.cleanName(name)
    self:saveCareer()
    return self.myName
  end

  local function mySprite()
    local field = BR.game and BR.game.data and BR.game.data.field
    return field and field.playerSprites and field.playerSprites.walk
  end

  local function here()
    return BR.game and mod.world:current()
  end

  -- Which build this client is, for the room door.  Computed once: neither
  -- half can change while the process is running -- the engine release is
  -- baked into the binary and the loader hands a mod its manifest version
  -- at load -- and this is read on every place broadcast.
  local myBuild
  local function build()
    if not myBuild then
      myBuild = { engine = Seams.engineVersion(),
                  mod = tostring(mod.version or "?") }
    end
    return myBuild
  end
  BR.buildOf = build

  local function broadcastPlace()
    if not (BR.relay and BR.relay:isOpen()) then return end
    local h = here()
    BR.relay:broadcast(Wire.place(h and h.mapId, h and h.x, h and h.y,
                                  h and h.facing, BR.status, mySprite(),
                                  nil, build()))
    if h then BR.sentMap, BR.sentFacing = h.mapId, h.facing end
  end

  -- POK-113: the mark that goes over a trainer's head on everyone else's
  -- screen.  A fight of any kind -- a duel, a bot, one of Kanto's own
  -- trainers, a wild encounter -- reads as a battle; anything else above
  -- the overworld (the PACK, the party screen, a dialog) reads as a menu.
  -- Both are worth knowing before you walk over: someone in a fight cannot
  -- answer you, and someone in a menu is not about to run.
  --
  -- The battle test is tickLevels' pair, and for the same reason: `status`
  -- alone says "battle" only for a duel or a bot fight, and a wild
  -- encounter or a route trainer leaves it "alive".
  local function myBusy()
    local game = BR.game
    if not game then return nil end
    if BR.status == "battle" or BR.botFight or BR:liveLocalBattle() then
      return "battle"
    end
    local ow = mod.world:overworld()
    local top = game.stack and game.stack:top()
    if not (ow and top) or top == ow then return nil end
    return "menu"
  end

  -- Edge-triggered: a frame goes out only when the answer CHANGES, so a
  -- whole match of walking costs nothing.  sentBusy starts (and resyncs)
  -- at `false` rather than nil, because nil is a real answer -- "back on
  -- the map" -- and a peer that missed that edge would otherwise be left
  -- holding a mark over someone who put their PACK away five minutes ago.
  local function broadcastBusy()
    if not (BR.relay and BR.relay:isOpen()) then return end
    local kind = myBusy()
    if kind == BR.sentBusy then return end
    BR.sentBusy = kind
    BR.relay:broadcast(Wire.busy(kind))
  end

  -- ------- trainer skins (POK-79)
  --
  -- The walk sheet every other trainer sees, unlocked by career wins.  The
  -- ladder and the picker live in lib/skins.lua; the wins and the choice
  -- persist through lib/career.lua next to the name.  The engine seam is
  -- field.playerSprites.walk: Player builds its sheet from it, mySprite()
  -- advertises it on the wire, and the TownMap marker follows for free --
  -- applied only inside the throwaway match world and restored on the way
  -- out, so a real playthrough never wears it.

  -- One writer for the whole career, so the name, the skin and the wins
  -- can never disagree about which of them was written last.
  function BR:saveCareer()
    return Career.save(mod, { name = self.myName, skin = self.skin,
                              wins = self:winCount() }, log)
  end

  -- The player's say in POK-124.  Off means nothing is counted and nothing
  -- is sent -- the solo counter stops moving too, so turning it off does
  -- not leave a backlog to be flushed the moment it goes back on.
  function BR:statsOn() return not stats.off end
  function BR:setStatsOn(on)
    return not Stats.setOff(mod, stats, not on, log)
  end

  function BR:winCount() return self.wins or 0 end

  function BR:skinId()
    local Skins = require("mods.battle_royale.lib.skins")
    return Skins.get(self.skin).id
  end

  function BR:skinLabel()
    local Skins = require("mods.battle_royale.lib.skins")
    return Skins.get(self.skin).label
  end

  function BR:setSkin(id)
    local Skins = require("mods.battle_royale.lib.skins")
    local entry = Skins.get(id)
    if not Skins.isUnlocked(entry, self:winCount()) then
      return nil, ("unlock at %d wins"):format(entry.wins)
    end
    self.skin = entry.id
    self:saveCareer()
    if self.matchWorld then self:applySkinWalk() end
    if self.relay and self.relay:isOpen() then broadcastPlace() end
    return entry.id
  end

  function BR:applySkinWalk()
    local Skins = require("mods.battle_royale.lib.skins")
    local data = self.game and self.game.data
    local ps = data and data.field and data.field.playerSprites
    if not ps then return end
    self.stockWalk = self.stockWalk or ps.walk or "SPRITE_RED"
    local walk = Skins.get(self.skin).walk
    if data.sprites and not data.sprites[walk] then walk = self.stockWalk end
    ps.walk = walk
  end

  function BR:restoreSkinWalk()
    local data = self.game and self.game.data
    local ps = data and data.field and data.field.playerSprites
    if ps and self.stockWalk then ps.walk = self.stockWalk end
  end

  -- Fast-forward is the engine's, not ours (POK-83).  Game:logicSpeed
  -- reads speedOverride BEFORE the core.logic_speed hook -- deliberately,
  -- so no mod can defeat it -- which is also why the mod's speed veto
  -- (POK-10) cannot see the touch skin's hold-to-fast-forward.  What we
  -- CAN do is put it back: baseSpeed remembers what the session started
  -- with, which is --speed / POKEPORT_SPEED on a driver run and nil for a
  -- player, so restoring it never steals a run argument.
  function BR:restoreSpeed()
    local game = self.game
    if game and self.baseSpeed ~= nil then
      game.speedOverride = self.baseSpeed or nil
      game.skinSpeedSaved = nil
    end
    self.baseSpeed = nil
  end

  function BR:recordWin()
    local Skins = require("mods.battle_royale.lib.skins")
    local before = self:winCount()
    self.wins = before + 1
    self:saveCareer()
    for _, e in ipairs(Skins.justUnlocked(before, self.wins)) do
      sayLater(("You unlocked the\n%s skin!"):format(e.label), 3)
    end
  end

  -- ------- room lifecycle

  -- What a fallen trainer's BAG holds (POK-25, the other half of D8): the
  -- items and the money, on the ground where they fell, for whoever walks
  -- over -- no longer a number that changes in the victor's pocket.
  -- Badges and HMs are the drop's grant, not loot (everyone has them), so
  -- they stay out of it.
  local GRANTED = {}
  for _, id in ipairs(START_BADGES) do GRANTED[id] = true end
  for _, id in ipairs(START_HMS) do GRANTED[id] = true end
  -- a rod is a grant like a badge: everyone has one, and the one you have
  -- is decided by the ring rather than by who you beat (POK-119)
  for _, id in ipairs(Rods.ALL) do GRANTED[id] = true end
  local function bagOf(save, name)
    local items = {}
    for id, n in pairs((save and save.inventory) or {}) do
      if not GRANTED[id] and (tonumber(n) or 0) > 0 then
        items[#items + 1] = { id = id, n = math.floor(n) }
      end
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    return { items = items, money = (save and save.money) or 0, name = name }
  end

  local function wireRelay(relay)
    relay:on("joined", function()
      BR.myId = relay.id
      -- the correlation key: the relay prints this code on every room
      -- line of its own (POK-86)
      log:match(relay.code, nil)
      BR:setPhase("lobby", relay:isHost() and "hosting" or "joined")
      -- POK-116: tell the relay we can take the room over if the host goes.
      -- Recorded here rather than inferred, so that a room whose members
      -- cannot do it still ends the old way instead of being handed to a
      -- client that would restart the fog.
      BR.wasHost = relay:isHost()
      relay:canHost(true)
      log:say("room %s as %s#%s%s", tostring(relay.code), myName(),
              tostring(relay.id), relay:isHost() and " (host)" or "")
      -- a quick-play host is the only one who counts down: whoever opened
      -- the room owns the clock, exactly as they own the start
      if BR.quick and relay:isHost() then
        BR.autoStartAt = love.timer.getTime() + QUICK_START_SECONDS
      end
      -- Whatever solo play has piled up since last time goes out on this
      -- connection, which exists for its own reasons (POK-124).  Relay:stat
      -- refuses a LocalRoom, so a solo room cannot eat the count, and the
      -- counter is only cleared once the send is actually accepted.
      local m = Stats.message(stats, mod.version)
      if m and relay:stat(m) then Stats.flushed(mod, stats, log) end
      -- Say who we are AT THE JOIN (POK-142).  Until the door there was no
      -- reason to: the first place used to go out at the drop (onStart),
      -- and the tick's is gated on inRound(), so nothing at all travelled
      -- while a room sat in the lobby.  That is exactly the window the
      -- door has to work in -- a mismatch found after START is a mismatch
      -- found too late to do anything about.
      --
      -- There is no overworld yet (this screen opens from the TITLE), so
      -- `here()` is nil and the place carries no map.  That is a shape the
      -- decoder already allows and the ghost layer already ignores: a
      -- trainer with no map is on no map, so nobody is drawn anywhere.
      -- What rides it is the build.
      broadcastPlace()
    end)
    relay:on("roster", function(members)
      -- someone arriving with seconds left would be dropped into a match
      -- they never saw the lobby for; give them a moment
      if BR.autoStartAt and #members > (BR.lastRoster or 0) then
        local floor = love.timer.getTime() + QUICK_START_GRACE
        if BR.autoStartAt < floor then BR.autoStartAt = floor end
      end
      -- The room stopped being solo, so the `all` fan-out that was being
      -- suppressed while nobody could hear it (POK-102) starts flowing
      -- again -- and whoever just arrived has none of the stream they
      -- missed.  Today this is insurance rather than a fix: the room is
      -- locked for the length of a round (no late joiners), so a roster can
      -- only GROW in the lobby, where there is no positional stream yet and
      -- Wire.start hands out every spawn anyway.  It is here so that a
      -- future change which lets someone in mid-round cannot quietly
      -- reintroduce a ghost that never moves.  Clearing sentFacing
      -- re-announces the facing; arming resync sends a full place next tick
      -- instead of waiting out the five-second cadence.
      if #members > 1 and (BR.lastRoster or 0) <= 1 then
        BR.sentFacing, BR.resync = nil, RESYNC_TICKS
      end
      -- A newcomer has heard nobody's join announcement, so everyone
      -- already here repeats theirs (POK-142).  Lobby only: in a round the
      -- resync cadence above already covers it, and the room is locked
      -- against late joiners anyway.
      if BR.phase == "lobby" and #members > (BR.lastRoster or 0)
         and relay:isOpen() then
        broadcastPlace()
      end
      BR.lastRoster = #members
      -- forget anyone who left; the host recounts survivors
      local present = {}
      for _, m in ipairs(members) do present[m.id] = true end
      for id in pairs(BR.players) do
        if not present[id] then
          -- if the one who left is who we are fighting, end the battle as a
          -- pulled cable rather than waiting on a move that never comes
          if BR.battle and BR.battle.opponentId == id then
            BR.battle.channel:peerGone()
          end
          BR.ghosts:despawn(id)
          BR.players[id] = nil
        end
      end
      -- The door's findings deliberately SURVIVE the leave (POK-142).  An
      -- earlier cut cleared them here, on the reasoning that a warning
      -- outliving the trainer it was about is worse than none.  That was
      -- right while the door only warned; under the refusal it is exactly
      -- backwards, because leaving is now what a flagged trainer always
      -- does -- clearing on leave would erase the note a fraction of a
      -- second after it was written, every single time.  They go on
      -- resetMatch instead, with the room they belonged to -- or on the
      -- clock, once Door.NOTE_SECONDS is up.
      -- The relay hands the room on by naming a new host in the roster, and
      -- lib/relay.lua has already adopted it by the time we get here -- so a
      -- promotion is something to notice, not something to negotiate.
      local amHost = relay:isHost()
      if amHost and not BR.wasHost then BR:onPromoted() end
      BR.wasHost = amHost
      if BR:inRound() then BR:checkWinner() end
    end)
    relay:on("message", function(fromId, m) BR:onMessage(fromId, m) end)
    relay:on("closed", function(reason)
      -- A room that closes under us is an exit like any other, and it has
      -- to leave the throwaway world the same way a deliberate LEAVE does.
      -- reset() alone cleared the match state and left the match Kanto on
      -- the stack, so the player stood in a world that was no longer a
      -- match and no longer a save -- with SAVE un-vetoed over their real
      -- slot, since matchWorld is exactly what the save.write hook reads
      -- (POK-115).
      --
      -- Through the SAME funnel as every other ending now (POK-144).
      -- relay:isOpen() is already false by the time we get here, so
      -- endMatch takes its no-room branch straight into teardown; the only
      -- difference is that a room closing MID-MATCH now records a
      -- lastResult for the screen it lands on, and one closing from the
      -- lobby does not.
      BR:endMatch(reason)
    end)
  end

  function BR:host()
    self:reset()
    local relay = Relay.new({ address = self:relayAddress(), log = mod.log })
    wireRelay(relay)
    local ok, err = relay:host(myName())
    if not ok then return false, err end
    self.relay = relay
    return true
  end

  -- A match against bots needs no server: hand the relay a room that has
  -- nobody else in it.  Everything above this line is unchanged -- the mod
  -- still hosts, still broadcasts, still runs the same match; the messages
  -- just have nowhere to go.  It matters because "I want to try this" should
  -- not begin with starting a Node process.
  function BR:hostSolo()
    self:reset()
    local relay = Relay.new({ transport = LocalRoom.new(), log = mod.log })
    wireRelay(relay)
    local ok, err = relay:host(myName())
    if not ok then return false, err end
    self.relay = relay
    self.solo = true
    if self.botCount < 1 then self.botCount = SOLO_BOTS end
    return true
  end

  -- Two ways to ask for bots, and they compose by taking whichever wants
  -- more: BOTS is an absolute number, FILL TO is a target for the whole
  -- roster that shrinks as humans arrive.  Fill is what quick play wants --
  -- you cannot know in advance how many strangers show up.
  function BR:botsAtStart()
    local humans = self.relay and #self.relay.members or 1
    local want = self.botCount
    if self.fillTo > 0 then want = math.max(want, self.fillTo - humans) end
    return math.max(0, math.min(want, Bots.MAX))
  end

  function BR:setFill(n)
    self.fillTo = math.max(0, math.min(Bots.MAX + 1, math.floor(tonumber(n) or 0)))
    return self.fillTo
  end

  function BR:nextFill() return Bots.nextFill(self.fillTo) end

  -- QUICK PLAY: join whatever is open, and if nothing is, become the thing
  -- that is open.  The fallback rides the SAME connection -- no_open_rooms
  -- is an answer, not a failure -- so this is one round trip either way.
  function BR:quickPlay()
    self:reset()
    local relay = Relay.new({ address = self:relayAddress(), log = mod.log })
    wireRelay(relay)
    relay:on("noopen", function()
      relay:host(myName(), { open = true })
    end)
    local ok, err = relay:quickJoin(myName())
    if not ok then return false, err end
    self.relay = relay
    self.fillTo = QUICK_FILL
    self.quick = true
    return true
  end

  function BR:setOpen(open)
    local relay = self.relay
    if not (relay and relay:isHost()) then return false end
    relay:setOpen(open)
    if not open then self.autoStartAt = nil end
    return true
  end

  function BR:isOpen() return self.relay and self.relay.open == true end

  -- seconds left on the quick-play countdown, or nil when nothing is counting
  function BR:startsIn()
    if not self.autoStartAt then return nil end
    return math.max(0, math.ceil(self.autoStartAt - love.timer.getTime()))
  end

  function BR:join(code)
    self:reset()
    local relay = Relay.new({ address = self:relayAddress(), log = mod.log })
    wireRelay(relay)
    local ok, err = relay:join(code, myName())
    if not ok then return false, err end
    self.relay = relay
    return true
  end

  -- Give another mod its overworld back (POK-134).  Idempotent, and called
  -- from more than one place ON PURPOSE.  resetMatch is the one path every
  -- deliberate exit goes through, and it is the primary route -- but it is
  -- reached by this mod's own code, so a fault in this mod between the
  -- suspend and the exit would strand somebody else's game for the rest of
  -- the session.  The save events are the second net: they already mean
  -- "the player is in a real playthrough again" (they clear matchWorld for
  -- the same reason), and they are raised by the ENGINE, so they still
  -- arrive when this mod is the thing that went wrong.
  --
  -- A hard close needs no net at all: these mods install their hooks at
  -- module init, so the next launch puts them back regardless.
  function BR:unsuspendMods()
    if not self.suspendedMods then return end
    Coexist.restore(self.suspendedMods, log)
    self.suspendedMods = nil
  end

  -- Everything an ENDING owns, in ONE list because two lists drift.
  --
  -- resetMatch clears it on the way OUT of a match; onStart clears it on the
  -- way IN.  The two are not the same call and neither is redundant:
  --
  --   arriving from a SESSION -- a guest still on the MATCH RECORD card
  --   when the host's next `start` lands (the card waits for A forever,
  --   lib/fame.lua:95-99), or the host's own startMatch, which has no phase
  --   guard and is what tests/drivers/playtest_over.lua's `twice` legs
  --   drive -- onStart runs a whole resetMatch first, and this list is one
  --   line of it;
  --
  --   arriving from the LOBBY, which is every ordinary start, there is no
  --   resetMatch to run and this call is the only clear there is.  It is
  --   what takes the last match's lastResult off the screen the new one
  --   starts from.
  --
  -- Delete either call and one of those two paths carries an ending into a
  -- match.  What that costs: startNewGame drops the Fame state under a
  -- guest who was still parading, so its onDone never runs, and `parading`
  -- stays set for the rest of the session -- match two reaches "over",
  -- armEnding is refused by the stale pendingEnd, and the tick pushes the
  -- clocks out every frame.  That client's second match never ends at all.
  --
  -- ORDER IS LOAD-BEARING (POK-144): endMatch sets lastResult AFTER it
  -- calls resetMatch, because this is what would eat it.  Move that
  -- assignment up there -- which reads like a tidy-up -- and the result the
  -- screen we are about to land on has to say is silently deleted.
  function BR:clearEnding()
    self.pendingParade = nil
    self.pendingFame = nil
    self.pendingEnd = nil
    self.parading = nil
    self.overBattleAt = nil
    self.lastResult = nil
    self.winnerId = nil
  end

  -- ------- the scripted-battle refusal, armed for the length of a match
  --
  -- The third route into a battle, and the one neither encounter.roll nor
  -- trainer.before_battle can see: a SCRIPT builds its own BattleState and
  -- pushes it (src/script/Commands.lua start_battle -> pushBattle), so every
  -- gym leader, rival fight, Snorlax, bird and Mewtwo reached the stack past
  -- both of them.  script.command is the one seam a mod has on that -- it
  -- wraps every row ScriptRunner dispatches
  -- (src/script/ScriptRunner.lua:168-176) -- and returning "end" stops the
  -- script where it stands rather than letting the rest of it run without
  -- the fight it was written around.
  --
  -- ARMED PER MATCH, NOT AT LOAD (POK-155).  A wrap that lives for the
  -- process makes Runtime.wantsHook("script.command") true for ever, and the
  -- runner takes its slower branch whenever that is so.  Measured per
  -- command on LuaJIT 2.1.1720049189: 40ns unhooked, 1747ns with this link
  -- live.  Arming at the drop and dropping it at resetMatch hands that back
  -- to every playthrough that is not a match -- 91% of it.
  --
  -- What it does NOT hand back is the emptied chain.  Hooks:wrap's
  -- unregister closure removes the entry and leaves chains["script.command"]
  -- a live (empty) table, so wantsHook stays true and the dispatch still
  -- costs ~189ns and two allocations.  That residue is the ENGINE's to fix
  -- -- src/mods/Events.lua:26-27 nils an emptied key and says why,
  -- src/mods/Hooks.lua:27-31 does not -- and is filed there.  Do NOT reach
  -- into Runtime.hooks.chains from here to shave it: that table is shared,
  -- and nilling the key would delete every other mod's link on the hook.
  --
  -- Two hazards, both benign only because BR is the single link on this hook
  -- today (checked across every mod in the tree):
  --
  --   1. Hooks:call has no dispatch snapshot.  It captures `local chain` and
  --      re-reads #chain per recursion, unlike Events:emit, which copies the
  --      list precisely because a listener may retire itself mid-emit
  --      (src/mods/Events.lua:49-53).  Dropping a link mid-dispatch shifts
  --      the walk PAST the next one -- three links with A removing itself
  --      runs A, C, vanilla and silently skips B.  Latent the moment a
  --      second mod wraps script.command.
  --   2. A yielded command can span the disarm.  show_text and start_battle
  --      yield inside the hook's pcall while the input.step tick keeps
  --      running and can reach resetMatch.  With a single link that resumes
  --      cleanly -- `entry` is a captured local and run(index + 1) re-reads
  --      #chain as 0 and runs vanilla -- which is the same single-link
  --      assumption as (1).  Both halves are covered by the yielding-command
  --      case in tests/br_load_test.lua.
  --
  -- And it is still not COMPLETE: a native map script that calls
  -- Commands.start_battle directly has no ScriptRunner under it, so this
  -- never fires for it (the same gap the gift hook documents further down).
  -- battle.started recording localBattle at "over" is the backstop for those
  -- -- the funnel can close a battle it could not refuse.
  --
  -- Nor is it the SOLE guard, and nothing above should be read as saying so.
  -- resetMatch disarms this link before it reaches phase = "lobby", so a
  -- throw anywhere in the forty lines between the two leaves a client still
  -- in a session with the wrap already gone.  What holds in that window is
  -- the rest of the set: canOpenBattle is asked again at encounter.roll, at
  -- trainer.before_battle, in startBotBattle and in beginBattle, so three of
  -- the four routes into a battle are still refused, and the battle.started
  -- backstop above still records whatever the fourth lets through for the
  -- exit funnel to close.  Only the scripted route is uncovered there, and
  -- only while a teardown is already failing.
  local SCRIPT_BATTLES = { start_battle = true, static_battle = true,
                           rival_battle = true, old_man_demo = true }
  -- The live link, or nil.  Declared HERE rather than beside armScriptWrap's
  -- one caller because a Lua local is only in scope BELOW its line, and
  -- resetMatch -- the function that drops it -- is the next one down.
  local dropScriptWrap
  local function armScriptWrap()
    if dropScriptWrap then return end   -- idempotent, like every other arm
    dropScriptWrap = mod.hooks:wrap("script.command", function(next, ctx, name, args)
      -- inSession() is redundant on paper now that the wrap only EXISTS
      -- during a session.  Kept anyway: it is what makes an arm/disarm bug
      -- cost nothing instead of costing a real playthrough its gym leaders.
      if SCRIPT_BATTLES[name] and BR:inSession() and not BR:canOpenBattle() then
        log:say("refused a scripted battle (%s) at phase %s",
                tostring(name), tostring(BR.phase))
        return "end"
      end
      return next(ctx, name, args)
    end)
  end
  local function disarmScriptWrap()
    if not dropScriptWrap then return end
    dropScriptWrap()
    dropScriptWrap = nil
  end

  -- Back to a clean slate without leaving the world (a closed relay, a
  -- cancelled lobby).  teardown() is the deliberate exit that also tells the
  -- relay goodbye.
  -- Everything one match owns, cleared for the next: a leave (reset) or the
  -- ending every client now takes for itself (endMatch), which keeps the room.
  function BR:resetMatch()
    -- What belongs to somebody ELSE goes back first, before anything here
    -- can throw and strand it: every other line of this function is our own
    -- state, and losing that costs a match, while losing this costs a
    -- stranger their overworld for the session (POK-134).  Idempotent, so
    -- the save-event net behind it is still free to arrive.
    self:unsuspendMods()
    self:restoreSpeed()
    -- ...and the ENGINE gets its cheap script dispatch back (POK-155).  This
    -- is the only disarm, because resetMatch is the one path every exit goes
    -- through -- the same claim the TM restore below leans on.  Deliberately
    -- NOT hung on setPhase: resetMatch sets self.phase directly further down
    -- ("setPhase would log a teardown as a new match") and so does BR:reset,
    -- so a disarm inside setPhase would never fire on the way out.
    disarmScriptWrap()
    -- ...and the route trainers get their sight lines back (POK-150):
    -- emptying the live talk tables re-exposes vanilla engagement, and
    -- the disarm is idempotent so the save-event net may call it too
    self:disarmTrainerTalk()
    self.ghosts:despawnAll()
    self.spills:clear()
    if self.battle then
      self.battle.channel:peerGone()
      self.battle = nil
    end
    self.fellAt = nil
    self.refusedBattle = nil
    self.players = {}
    -- the door's findings go with the room they were about (POK-142): the
    -- next room is different people, and a stale "!" against an id the
    -- relay has since handed to somebody else would be a lie
    self.oldPeers = {}
    self.flagged = {}
    self.buildWarned = nil
    self.pending = nil
    self.phase = "lobby"   -- setPhase would log a teardown as a new match
    self.status = "lobby"
    self.started = false
    self.matchWorld = false
    -- ...and go back to TM01..TM50 on the way out (POK-110).  game.data is
    -- the engine's, shared with the player's real save, so a rename left
    -- behind would follow them into an ordinary game.  resetMatch is the
    -- one path every exit goes through -- a deliberate LEAVE, a teardown,
    -- a host drop, PLAY AGAIN -- which is why it lives here and not in
    -- teardown beside restoreSkinWalk.
    if self.machineNames then
      Machines.restore(self.game and self.game.data, self.machineNames)
      self.machineNames = nil
    end
    self.lastOpponent = nil
    self.fledFrom, self.fleeGrace, self.fleeLockout, self.fleeing = {}, {}, {}, nil
    self.peeked, self.lastPeekAt = nil, nil
    self.pendingDrop = nil   -- a release that never landed (POK-34)
    self.pendingGift = nil   -- a gift whose box was never reopened (POK-112)
    self.pendingSays = {}
    self.despawns:clear()
    self.runnerBusySince, self.lastAutoA = nil, nil
    self.stats = nil
    self.walkUp = nil
    self:clearEnding()
    self.ringDistOf = nil
    self.ringLocs = nil
    self.matchFog = nil
    self.safariPool = nil
    self.dropSeq = nil
    self.safariEndsAt = nil  -- the Safari opening's clock (POK-21)
    self.lastSafariBeat = nil
    self.safariGhost = nil
    self.buzzed = nil
    self.buzzedAt = nil
    self.lastBuzzB = nil
    self.pickingTown = nil
    self.matchSeed = nil
    self.botFight = nil
    self.botFightPos = nil
    self.botFightIdx = nil
    self.botParty = nil
    self.botRecords = {}
    self.npcFight = nil
    self.ring = nil
    self.ringCenter = nil
    self.matchStartedAt = nil
    self.lastFogTick = nil
    self.wasInFog = false
    self.lastLevelTick = nil
    self.announcedLevel = nil
    self.watching = nil
    self.lastHopAt = nil
    self:releaseCamera()
  end

  function BR:reset()
    self:resetMatch()
    self.relay = nil
    self.solo = false
    self.quick = false
    self.autoStartAt = nil
    self.lastRoster = 0
    self.phase = "off"
    self.myId = nil
    self.wasHost = false
  end

  function BR:teardown(message)
    -- Re-entrant by construction: teardown drops the relay, and a dropped
    -- relay fires `closed`, whose handler is itself an exit that tears
    -- down.  Whoever arrives first owns the exit; the other turns around.
    -- The flag is cleared through a pcall because a teardown that threw
    -- with it still set would disable every exit after it.
    if self.tearingDown then return end
    self.tearingDown = true
    local ok, err = pcall(function()
      log:say("teardown (%s)", tostring(message or "left"))
      local wasMatchWorld = self.matchWorld
      log:forget()
      self:restoreSkinWalk()
      if self.relay then self.relay:leave() end
      self:reset()
      -- A say cannot outlive the stack pop: Menu.say queues a script in the
      -- world we are leaving, so only an exit that stays put can deliver
      -- one.  Leaving the world with no reason given is POK-115's known
      -- gap, not an oversight here.
      --
      -- POK-144: every terminal state ends on the BR SCREEN, not the bare
      -- title.  With no room left the screen shows its first face -- QUICK
      -- PLAY / SOLO / HOST -- which is the right answer to "the room
      -- closed": there is nothing to go back to, so it offers the way to
      -- start again.  And the screen has rows where a say cannot reach, so
      -- POK-115's gap is narrower than it was: BR.lastResult is read there
      -- (lib/menu.lua) by everything that arrives with a result to report.
      if wasMatchWorld and self.game then
        self:toLobbyScreen()
      elseif message then
        say(message)
      end
    end)
    self.tearingDown = false
    if not ok then
      mod.log:warn("battle royale teardown failed: %s", tostring(err))
    end
  end

  -- Leaving the finished world: the throwaway Kanto is dropped and the BR
  -- screen comes back -- with the roster intact while there is still a
  -- room, and on its own first face when there is not.  THE landing, now
  -- (POK-144), not one of several: a win, a loss, a LEAVE and a room that
  -- closed under us all arrive here, where they used to scatter between
  -- here, the bare title, and standing in the match world forever.
  function BR:toLobbyScreen()
    local game = self.game
    if not game then return false end
    self.matchWorld = false   -- the throwaway world is gone; SAVE is theirs again
    local ok, err = pcall(function()
      while game.stack:top() do game.stack:pop() end
      game.stack:push(game:makeTitleState())
      mod.ui.push(game, SCREEN)
    end)
    if not ok then
      mod.log:warn("could not return to the lobby: %s", tostring(err))
    end
    return ok
  end

  -- The match is over for this client.  Not an exit in itself: it says the
  -- exit is DUE, and the tick takes it once the screen is quiet -- or when
  -- the deadline runs out, because a finished match nothing tears down is
  -- exactly POK-144.  Armed by EVERY way a match can end, not only by the
  -- one that has a parade behind it.
  function BR:armEnding(why)
    if self.endingMatch or self.pendingEnd then return end
    -- Nothing to arm outside the window the tick can take it in.  onAgain
    -- is the caller that can arrive here cold -- a guest that finished its
    -- own ending while the host was still parading -- and a pendingEnd
    -- left standing in the lobby would be dead weight that the NEXT
    -- match's arm is then refused by, one line above.
    if self.phase ~= "over" then return end
    local now = clock() or 0
    self.pendingEnd = { why = why or "ended",
                        earliest = now + END_GRACE_SECONDS,
                        deadline = now + END_DEADLINE_SECONDS }
  end

  -- The one teardown every terminal route funnels into (POK-144).  Before
  -- this there were five ways a match could end and two of them reached a
  -- reset; a bot winning, nobody winning, and a champion whose parade
  -- could not run left the player standing in a throwaway Kanto with
  -- another mod's overworld hooks still stood down (POK-134) and TM01..50
  -- still wearing BR names in game.data, which the real save shares.
  -- Returns true when the exit was actually taken, so the caller that armed
  -- it can arm it again: this swallows its own throw (a teardown that dies
  -- before resetMatch reaches phase = "lobby" leaves the client at "over"
  -- with nothing left to re-arm it, which is POK-144 reopened by the first
  -- exception).
  function BR:endMatch(why)
    if self.endingMatch then return false end
    -- A teardown already owns this exit.  Relay:leave fires `closed`
    -- SYNCHRONOUSLY (lib/relay.lua), so LEAVE MATCH nests
    -- teardown -> closed -> endMatch inside itself: without this line the
    -- inner call sets a lastResult that the outer reset() then clears, and
    -- "a player who chose to leave gets no result row" would be true only
    -- by the order of two statements nobody is warned about.
    if self.tearingDown then return false end
    self.endingMatch = true
    local ok, err = pcall(function()
      local wasInSession = self:inSession()
      local wasMatchWorld = self.matchWorld
      local keepRoom = (self.relay and self.relay:isOpen()) or false
      local won = self.winnerId ~= nil and self.winnerId == self.myId
      local winner = self.winnerId and self.players[self.winnerId]
      local result = { won = won, winnerId = self.winnerId,
                       name = (not won) and self.winnerId
                              and ((winner and winner.name)
                                   or (self.relay and self.relay:nameOf(self.winnerId)))
                              or nil,
                       at = clock() or 0 }
      -- only when there WAS a match: this funnel is shared with the relay's
      -- `closed`, which fires just as readily over a lobby nobody had
      -- started, and "match over (room_closed)" in the story log with no
      -- match behind it is a false positive in the tier this project reads
      -- as evidence
      if wasInSession then log:say("match over (%s)", tostring(why or "ended")) end
      if keepRoom then
        -- the host runs the room back, as PLAY AGAIN used to (POK-20): the
        -- roster kept, the code kept, the door unlocked for anyone else.
        -- What it does NOT do is start the next match: PLAY AGAIN is the
        -- lobby's own start row now, and a countdown nobody pressed
        -- anything to arm would drop a host who won, read the result and
        -- walked away into a fresh match thirty seconds later.
        if self.relay:isHost() then
          self.relay:broadcast(Wire.again())
          self.relay:lock(false)
        end
        self:resetMatch()
        if wasMatchWorld then self:toLobbyScreen() end
      else
        self:teardown(why)   -- reset() -> resetMatch(), then the same screen
      end
      -- LAST: resetMatch clears this, and the result is what the screen we
      -- just landed on has to say
      if wasInSession then self.lastResult = result end
    end)
    self.endingMatch = false
    if not ok then mod.log:warn("could not end the match: %s", tostring(err)) end
    return ok
  end

  -- The Hall of Fame is the end of the run (POK-82): the parade hands off
  -- to here, and here hands off to the one funnel.
  function BR:endRun()
    self.pendingEnd = nil     -- the parade WAS the ending; nothing to wait for
    -- ...unless the exit threw on the way out.  endMatch warns and returns
    -- false rather than raising, so the only thing that can try again is
    -- whoever asked it to go.
    if not self:endMatch("the parade ended") and self.phase == "over" then
      self:armEnding("the parade ended")
    end
  end

  -- PLAY AGAIN is no longer a row of its own (POK-144).  Every client now
  -- returns to the lobby on its own the moment its ending finishes, so the
  -- host's job shrank to the one thing only a host can do -- unlock the
  -- room -- and endMatch does it.  The `again` message is kept and still
  -- means "back to the lobby", in the two shapes that are left:
  --
  --   at "over" it only ARMS the exit, so a host who finished the parade
  --   first cannot pop a guest's Hall of Fame out from under them;
  --
  --   anywhere else in a session it TAKES it, which is the recovery this
  --   message has always been and the reason it is still on the wire.  A
  --   client that never saw `winner` -- a dropped packet, a rejoin -- is
  --   still standing in a match the rest of the room has left, and `again`
  --   is the only thing that will ever tell it so.
  function BR:onAgain()
    if not (self.relay and self.relay:isOpen()) then return end
    if self.phase == "over" then
      self:armEnding("play again")
    elseif self:inSession() then
      self:endMatch("play again")
    end
  end

  -- ------- starting a match
  --
  -- The host picks every drop point and sends them; nobody else has to agree
  -- on the algorithm, only on the answer.  Host and guests both apply the
  -- same `start` message through onStart.

  function BR:startMatch()
    local relay = self.relay
    if not (relay and relay:isHost()) then return end
    -- A solo match is the one nothing else can see: it runs on a LocalRoom
    -- and never opens a socket (POK-124).  This is a counter bump and a
    -- local file write -- deliberately NOT a connection, because
    -- Net:connectTCP blocks for up to five seconds and the player just
    -- asked for the offline mode.  The count rides the next real relay
    -- connection instead.
    if self.solo then Stats.recordSolo(mod, stats, log) end
    local ids = {}
    for _, m in ipairs(relay.members) do ids[#ids + 1] = m.id end
    table.sort(ids)
    -- bots ride the same spawn list as everyone else; their ids are far
    -- above any the relay hands out, so nothing has to be kept apart
    for i = 1, self:botsAtStart() do
      ids[#ids + 1] = Bots.idFor(i)
    end
    local seed = love.math.random(1, 2 ^ 30)
    local rng = Spawn.rng(seed)
    local data = self.game.data
    -- the Safari opening: everyone on one map, together.  0 seconds is the
    -- old drop, scattered over Kanto with a starter.
    local safari = self:safariSeconds()
    local drops, err
    if safari > 0 then
      drops, err = Spawn.pickIn(data.maps, data.tilesets, SAFARI_MAP, #ids, rng)
    else
      drops, err = Spawn.pick(data.maps, data.tilesets, #ids, rng)
    end
    if not drops then
      say("Couldn't start:\n" .. tostring(err))
      return
    end
    local spawns = {}
    for i, id in ipairs(ids) do
      spawns[i] = { id = id, map = drops[i].map, x = drops[i].x, y = drops[i].y }
    end
    relay:lock(true)                       -- no late joiners mid-match
    relay:broadcast(Wire.start(seed, spawns, safari, self:fogSeconds()))
    self:onStart({ seed = seed, spawns = spawns, safari = safari,
                   fog = self:fogSeconds() })
  end

  function BR:onStart(msg)
    -- The LAST match, gone in full, before this one is built on top of it
    -- (POK-144).  A client can arrive here still standing in one: a guest
    -- reading the MATCH RECORD card cannot leave "over" on its own, and the
    -- message gate no longer drops the host's `start` at it -- dropping it
    -- is what made that client a phantom survivor of the next match.
    --
    -- resetMatch, not clearEnding: the ending is seven fields and a match is
    -- forty.  The difference is the ring (match one's final radius, so
    -- tickFog bites from frame one until the host's first `ring` arrives),
    -- the ghosts, the spills, the flee lockouts, the buzzer flags, the say
    -- queue, the bot fight and the door's findings -- every one of which
    -- would otherwise walk into match two.
    --
    -- Skipped from the LOBBY, which is every ordinary start, so nothing is
    -- reset twice.  And resetMatch sets self.phase directly rather than
    -- through setPhase, so an arrival at "over" does not log its teardown
    -- as a new match either.
    --
    -- Before baseSpeed is read, because resetMatch's restoreSpeed hands the
    -- pre-match speed back to the game: this line has to record what the
    -- game is left running at, not what the last match was running at.
    if self:inSession() then self:resetMatch() end
    -- what this session runs at normally, before anyone holds a bumper
    self.baseSpeed = (self.game and self.game.speedOverride) or false
    -- Nothing the LAST match ended with comes into this one (POK-144): not
    -- its result, and above all not a parade flag or an armed exit that
    -- this match's own ending would then be refused by.  The same list
    -- resetMatch uses, so the two cannot drift apart -- and NOT redundant
    -- with the line above, which runs only for an arrival from a session.
    -- This is the clear the ordinary lobby start gets.
    self:clearEnding()
    -- find my drop
    local mine
    for _, s in ipairs(msg.spawns) do
      if s.id == self.myId then mine = s break end
    end
    if not mine then
      say("The match started\nwithout a spawn\nfor you.")
      return
    end
    -- seed the peers as alive-in-lobby until their first place message.
    -- A bot's name and party are derived from the shared seed rather than
    -- sent, so every client agrees on the team it is about to fight.
    self.matchSeed = msg.seed
    -- the starting host's phase length, so an heir runs the ring at the pace
    -- the match was started at rather than its own option (POK-116)
    self.matchFog = msg.fog
    -- ...and this match's zone, drawn from the same seed on every client
    -- rather than sent, so the draft is the same for everyone (POK-118)
    self.safariPool = Safari.pool(msg.seed, self.game and self.game.data)
    log:say("the zone today: %s", Safari.describe(self.safariPool))
    log:match(self.relay and self.relay.code, msg.seed)
    self.players = {}
    for _, s in ipairs(msg.spawns) do
      if s.id ~= self.myId then
        local bot = Bots.isBot(s.id)
        -- a bot's face is seeded like its name and its team (POK-89), so
        -- it needs no wire field -- though place() carries it anyway, the
        -- same way a human advertises the skin they picked
        local look = bot and Bots.look(msg.seed, s.id,
                                       self.game and self.game.data) or nil
        self.players[s.id] = {
          name = bot and Bots.name(msg.seed, s.id) or self.relay:nameOf(s.id),
          map = bot and s.map or nil,   -- a bot is where the host says at once
          x = s.x, y = s.y, facing = "down",
          status = "alive", bot = bot or nil,
          sprite = look and look.walk or nil,
          class = look and look.class or nil,
        }
      end
    end
    do  -- the drop, in one line you can grep for (POK-86)
      local bots = 0
      for id in pairs(self.players) do if Bots.isBot(id) then bots = bots + 1 end end
      log:say("match starts: %d trainers (%d bots), safari %ss, fog %ss, mine %s at %d,%d",
              #msg.spawns, bots, tostring(msg.safari or 0), tostring(self:roundFog()),
              tostring(mine.map), mine.x or -1, mine.y or -1)
    end
    -- arm the loadout hook, then start a fresh game straight into the world
    local safari = tonumber(msg.safari) or 0
    self.arming = { map = mine.map, x = mine.x, y = mine.y,
                    safari = safari > 0, safariSeconds = safari }
    -- The scripted-battle refusal goes live HERE and nowhere else: onStart
    -- is the single entry into a session, the way resetMatch is the single
    -- exit (POK-155).  Before setPhase, so no script can dispatch a row in
    -- the new phase ahead of the guard that reads it.
    armScriptWrap()
    -- ...and route trainers go opt-in for the same window (POK-150):
    -- their sight lines stand down, their talk still fights
    self:armTrainerTalk()
    self:setPhase(safari > 0 and "safari" or "match",
                  safari > 0 and "the SAFARI opens" or "straight to the drop")
    self.status = "alive"
    -- back in the running for the room: a PLAY AGAIN puts whoever stood
    -- down last match back on their feet, and on the heir list (POK-116)
    if self.relay then self.relay:canHost(true) end
    self.started = true
    self.matchWorld = true
    -- TMs say what they teach for the length of the match (POK-110).
    -- Guarded on machineNames rather than on the phase: apply() is a no-op
    -- the second time and would hand back an EMPTY restore table, so a
    -- double call is how the way back gets lost.
    if self.game and not self.machineNames then
      self.machineNames = Machines.apply(self.game.data)
    end
    -- Other mods that act on the overworld stand down for the match
    -- (POK-134).  This guard looks like the TMs' above but is load-bearing
    -- in a way that one is not: Machines.apply is idempotent, while
    -- Coexist.suspend is NOT -- call it twice and the second token is
    -- live too, so restoring both reinstalls another mod's hooks twice.
    -- This `if` is the only thing standing between us and that.  restore
    -- lives in resetMatch, the one path every exit goes through.
    if not self.suspendedMods then
      self.suspendedMods = Coexist.suspend(function(id) return mod.find(id) end,
                                           log)
    end
    self.stats = { catches = 0, beats = 0, steps = 0,
                   startedAt = clock() or 0 }
    if safari > 0 then
      -- the host's beats correct this; until the first lands it is the
      -- announced length from now, which is close enough for a clock
      local now = clock() or 0
      self.safariEndsAt = now + safari
      self.lastSafariBeat = nil
    end
    -- arming is cleared whatever happens.  It gates the save.created net
    -- (BR.matchWorld, and the overworld another mod is owed back, POK-134),
    -- so a throw in startNewGame leaving it set would switch that net off
    -- for the rest of the session -- the one fault the net exists for.  The
    -- failure still travels: the tick's pcall logs it exactly as before.
    local ok, err = pcall(self.game.startNewGame, self.game, { intro = false })
    self.arming = nil
    if not ok then error(err, 0) end
    self.sentMap, self.sentFacing, self.resync = nil, nil, 0
    self.sentBusy = false    -- not nil: nil is "not busy", a real answer
    broadcastPlace()
    if safari > 0 then
      -- a beat and a half after landing: past the held A that started the
      -- match, so the rules are actually readable (POK-50)
      sayLater(("Catch what you can!\nThe PA calls time\nin %d:%02d."):format(
        math.floor(safari / 60), safari % 60), 1.5)
    end
  end

  -- the loadout, applied to the fresh skeleton (save.new_game).  Only when a
  -- match is arming; a normal New Game passes straight through.
  mod.hooks:wrap("save.new_game", function(next, save)
    save = next(save)
    if not BR.arming then return save end
    local Pokemon = require("src.pokemon.Pokemon")
    local Data = require("src.core.Data")
    if BR.arming.safari then
      -- no starter: the Safari is where the team comes from.  The admission
      -- is the gate's own -- thirty balls and the step budget -- so the
      -- start menu's steps/500 and BALL counter read true.
      save.party = {}
      -- the step budget rides the round's clock (POK-46): 502 steps at
      -- walking speed is ~125 s, hand-tuned to the default 120 s round --
      -- so a longer round deserves a longer leash
      local secs = BR.arming.safariSeconds or DEFAULT_SAFARI_SECONDS
      save.safari = { balls = SAFARI_BALLS,
                      steps = math.max(1, math.floor(
                        SAFARI_STEPS * secs / DEFAULT_SAFARI_SECONDS)) }
    else
      save.party = { Pokemon.new(Data, START_SPECIES, START_LEVEL) }
    end
    save.inventory = {}
    for id, n in pairs(START_ITEMS) do save.inventory[id] = n end
    -- a badge or an HM this build does not carry is skipped rather than
    -- written as a phantom id the bag would have to quarantine later
    for _, id in ipairs(START_BADGES) do
      if Data.items[id] then save.inventory[id] = 1 end
    end
    for _, id in ipairs(START_HMS) do
      if Data.items[id] then save.inventory[id] = 1 end
    end
    -- The dex owns everything from frame one, so no in-match catch is ever
    -- "new" -- the dex-page fanfare and entry screen, a beat that stops an
    -- online match, never fire (POK-57).  This skeleton is the match's
    -- throwaway world; real saves never see it.
    save.pokedex = { seen = {}, owned = {} }
    for id in pairs(Data.pokemon) do
      save.pokedex.seen[id] = true
      save.pokedex.owned[id] = true
    end
    -- Every town is a FLY destination from frame one (POK-52): the map is
    -- the arena, and travel is strategy, not a diary of where you have
    -- been.  The same trick as the dex above.
    local WMap = require("src.world.Map")
    save.visited = save.visited or {}
    for id, mdef in pairs(Data.maps) do
      if WMap.isFlyTown(mdef) then save.visited[id] = true end
    end
    save.bagOrder = nil            -- rebuilt from inventory on next open
    save.pcItems = {}
    save.money = START_MONEY
    save.flags = save.flags or {}
    for _, f in ipairs(STORY_FLAGS) do save.flags[f] = true end
    save.player.name = Wire.cleanName(BR.myName or save.player.name)
    BR:applySkinWalk()
    save.player.map = BR.arming.map
    save.player.x, save.player.y = BR.arming.x, BR.arming.y
    save.player.facing = "down"
    -- a whiteout should return here, not to a Pallet that never happened
    save.lastHeal = { map = BR.arming.map, x = BR.arming.x, y = BR.arming.y }
    save.lastOutdoor = { id = BR.arming.map, x = BR.arming.x, y = BR.arming.y }
    return save
  end)

  -- ------- the PvP shot clock (POK-59)
  --
  -- The engine's tournament clock (opts.turnLimit) is exactly the rule a
  -- battle royale needs: a visible countdown while the menu is yours, and
  -- a forfeit on the wire -- with a definite winner -- when it runs out.
  -- Nobody drags an opponent into the fog by sitting in a menu.  Wrapped
  -- rather than passed because the opts are built inside the engine's own
  -- LinkState; a pre-clock engine simply ignores the extra field.
  do
    local LinkBattle = require("src.link.LinkBattle")
    local function withClock(base)
      return function(game, net, opts)
        if opts and not opts.turnLimit and BR:inRound() then
          opts.turnLimit = PVP_TURN_SECONDS
        end
        local battle, why = base(game, net, opts)
        -- POK-80: the link foe wears the skin they picked.  Their advertised
        -- walk sheet (BR.players[id].sprite, off the wire) maps back to a
        -- trainer class, and enter() keeps a trainerPic set before it over
        -- the vanilla RED link default -- so setting it here is the whole
        -- fix.  Wrapped in pcall: a missing class or pic must never stop a
        -- battle starting, only leave the RED default.
        if battle and not battle.trainerPic and BR:inRound() then
          pcall(function()
            local opp = BR.battle and BR.battle.opponentId
            local peer = opp and BR.players[opp]
            if not (peer and peer.sprite) then return end
            local Skins = require("mods.battle_royale.lib.skins")
            local class = Skins.classForWalk(peer.sprite)
            local data = game and game.data
            if class and data and data.trainers and data.trainers[class] then
              local BattleState = require("src.battle.BattleState")
              battle.trainerPic = BattleState.trainerSprite(
                data, data.trainers[class], class, 1)
            end
          end)
        end
        return battle, why
      end
    end
    LinkBattle.newHost = withClock(LinkBattle.newHost)
    LinkBattle.newGuest = withClock(LinkBattle.newGuest)
  end

  -- ------- the room door (POK-142)
  --
  -- Sharing the overworld needs nothing but this mod's own PROTOCOL.
  -- FIGHTING needs two more things to match, and the wire never carried
  -- either of them:
  --
  --   the ENGINE RELEASE   src/link/Handshake.lua checkCompat returns
  --                        `engine_skew` for any difference in the version
  --                        STRING, and battleAllowed refuses it.  Not the
  --                        major, not the minor -- the string.
  --   this MOD's VERSION   Fingerprint.modKey folds `id@version` of every
  --                        enabled mod that has not declared
  --                        affects_link = false into the link digest, and
  --                        this mod has not.  Different version, different
  --                        digest, verdict `subset`, battle refused.
  --
  -- So a mismatched pair joins, shares a room, watches each other's ghosts
  -- walk around, drops into Kanto together -- and then cannot engage.  The
  -- only thing said at that moment is the engine's own "Link battle needs
  -- the same version and mods", which names neither number and appears
  -- several minutes after the decision that caused it.
  --
  -- This is a DOOR, not a bouncer.  Nobody is refused: the comparison is
  -- new, the overworld genuinely does work, and bouncing a player out of a
  -- room over it would be a worse failure than the one being diagnosed.
  -- What it does is name the difference, at the join, in both numbers.

  -- A peer whose place we could not even decode, because their BATTLE
  -- ROYALE speaks a different PROTOCOL.  We know nothing about them except
  -- that they are there -- their versions rode the message we just threw
  -- away -- so this is the one case the door cannot put numbers on.
  function BR:noteOldPeer(id)
    if not id or Bots.isBot(id) then return end
    self.oldPeers = self.oldPeers or {}
    if self.oldPeers[id] then return end
    self.oldPeers[id] = true
    local name = (self.relay and self.relay:nameOf(id)) or "A trainer"
    log:warn("door: %s speaks another BATTLE ROYALE protocol", tostring(name))
    self:warnBuild(Door.oldSentence(name))
  end

  -- A peer we understood, who told us what they are running.
  function BR:noteBuild(id, p)
    if not p or Bots.isBot(id) then return end
    local mine, theirs = self:buildOf(), p.build
    if not Wire.buildDiffers(mine, theirs) then return end
    p.buildBad = true
    -- Sticky, and keyed on the ROOM rather than on who is currently in it.
    -- Under the refusal below a mismatched guest is gone a moment after
    -- they arrive, so a note that expires with their roster line expires
    -- before the host can read it -- and a host on a stale build watching
    -- people bounce off in silence is the failure this whole thing exists
    -- to prevent, just from the other side.
    self.flagged = self.flagged or {}
    if not self.flagged[id] then
      -- love.timer inline, not the clock() helper: that is defined
       -- further down and locals capture lexically -- the POK-24 lesson,
       -- and br_test gates on it.
      self.flagged[id] = { name = p.name or "A trainer", build = theirs,
                           at = (love.timer and love.timer.getTime
                                 and love.timer.getTime()) or 0 }
      log:warn("door: %s is on %s", tostring(p.name),
               table.concat(Door.parts(mine, theirs), ", "))
    end

    -- ------- and the refusal itself
    --
    -- Measured against the HOST, and only the host.  "Leave if I differ
    -- from anyone here" inverts under a crowd: when it is the HOST who is
    -- the odd one out, every guest walks and the one person nobody can
    -- fight keeps the room.  Matching the host makes the room homogeneous
    -- by construction -- everyone agrees with the host, so everyone agrees
    -- with each other -- and needs no majority logic anywhere.
    --
    -- Lobby only.  A room locks for the length of a round, so this is the
    -- only window it can fire in anyway; and a host handed on mid-match
    -- (POK-116) must never bounce a player out of a match they are already
    -- playing, which is what a phase-blind rule would do.
    local relay = self.relay
    if self.phase == "lobby" and relay and not relay:isHost()
       and id == relay.hostId then
      self:refuseRoom(theirs)
      return
    end
    if not p.buildTold then
      p.buildTold = true
      self:warnBuild(Door.sentence(p.name or "A trainer", mine, theirs))
    end
  end

  -- Out of the room, and told why, without going anywhere near the title.
  -- teardown()'s own `message` is documented as lost when it lands on the
  -- title (POK-115), and this is the single message the feature exists to
  -- deliver -- so the exit stays on the ROYALE screen and the explanation
  -- becomes the screen.
  function BR:refuseRoom(theirs)
    if self.refusing then return end
    self.refusing = true
    local mine = self:buildOf()
    local rows = Door.refusalRows(mine, theirs)
    log:warn("door: refused this room -- %s",
             table.concat(Door.parts(mine, theirs), ", "))
    local ok, err = pcall(function()
      if self.relay then self.relay:leave() end
      self:reset()
    end)
    -- after reset(), which runs resetMatch() and would clear it
    self.refused = { rows = rows }
    self.refusing = nil
    if not ok then
      mod.log:warn("battle royale refusal failed: %s", tostring(err))
    end
  end

  function BR:clearRefusal() self.refused = nil end

  -- Said ONCE per session, however many mismatched trainers turn up: seven
  -- text boxes at the drop would be worse than the silence this replaces.
  -- The ROYALE menu carries the rest -- a mark against every trainer the
  -- door flagged, which is where somebody waiting in a lobby is looking
  -- anyway, and which does not need the script runner.  That matters:
  -- the menu opens from the TITLE screen as well as from the start menu,
  -- and with no overworld under it there is nothing to queue a say onto.
  function BR:warnBuild(text)
    if self.buildWarned then return end
    self.buildWarned = true
    sayLater(text, 1)
  end

  -- What the menu marks a roster row with: nil, or a reason.
  function BR:buildTrouble(id)
    if id == self.myId then return nil end
    if self.oldPeers and self.oldPeers[id] then return "old" end
    if self.flagged and self.flagged[id] then return "build" end
    return nil
  end

  -- One line for the lobby saying what would have to change, or nil when
  -- the room is fightable.  Specific on purpose: "cannot battle" leaves a
  -- player guessing which of the two numbers to chase, and the two are
  -- chased in different places -- the GAME from wherever they installed
  -- it, this mod from the launcher's own Check for updates.  An older
  -- BATTLE ROYALE told us nothing (its place never decoded), so it can
  -- only ever mean "one of you is behind on the mod".
  -- Both readers below PRUNE FIRST (Door.NOTE_SECONDS), so a note and the
  -- row that summarises it can never disagree about whether it is still
  -- there.
  function BR:pruneFlagged()
    -- love.timer inline for the same reason the stamp above is (POK-24)
    local now = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
    local flagged = self.flagged
    if not flagged then return end
    for id, f in pairs(flagged) do
      if f.at and (now - f.at) > Door.NOTE_SECONDS then flagged[id] = nil end
    end
  end

  -- Computed on the read rather than cached.  An earlier cut cached it and
  -- refreshed on events, to keep Menu.items -- which runs every frame --
  -- off a walk of the roster.  The expiry ended that: a note that goes
  -- stale on a CLOCK has no event to refresh on, and the cache would sit
  -- there contradicting a row that had already gone.  The walk is over
  -- `flagged`, which holds only mismatched trainers and is empty in every
  -- healthy room, so a normal frame pays for one empty table.
  function BR:buildTroubleLabel()
    self:pruneFlagged()
    local peers = {}
    for _ in pairs(self.oldPeers or {}) do peers[#peers + 1] = { old = true } end
    for id, f in pairs(self.flagged or {}) do
      if id ~= self.myId then peers[#peers + 1] = { build = f.build } end
    end
    return Door.label(self:buildOf(), peers)
  end

  -- Trainers the door flagged who are no longer on the roster -- which,
  -- once a mismatch refuses the room, is all of them within a frame.  The
  -- lobby lists these under the live members so a host can see who tried.
  function BR:flaggedAbsent()
    self:pruneFlagged()
    local out = {}
    for id, f in pairs(self.flagged or {}) do
      if id ~= self.myId and not self.players[id] then
        out[#out + 1] = { id = id, name = f.name, build = f.build }
      end
    end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
  end

  -- ------- inbound room messages

  function BR:onMessage(fromId, raw)
    local msg, why, code = Wire.decode(raw)
    if not msg then
      mod.log:warn("battle royale dropped a message: %s", tostring(why))
      -- The one drop a player can do something about, and the one that
      -- will happen on every wire bump: their BATTLE ROYALE is a different
      -- version from ours, so their `place` never decodes and they are
      -- invisible.  Indistinguishable, from here, from a trainer who
      -- joined and then never moved -- so say it once.
      if code == "protocol" then self:noteOldPeer(fromId) end
      return
    end
    -- `as` lets the host move its bots.  Honoured only from the host, so a
    -- guest cannot puppet another trainer, and never to impersonate a human.
    local actor = fromId
    if msg.as and self.relay and fromId == self.relay.hostId
       and Bots.isBot(msg.as) then
      actor = msg.as
    end
    local p = self.players[actor]

    if msg.t == "place" then
      p = p or { name = Bots.isBot(actor) and Bots.name(self.matchSeed, actor)
                        or self.relay:nameOf(actor),
                 bot = Bots.isBot(actor) or nil }
      self.players[actor] = p
      p.map, p.x, p.y, p.facing = msg.map, msg.x, msg.y, msg.facing
      p.sprite = msg.sprite or p.sprite
      p.status = msg.status
      -- keep the first answer rather than the latest: a resync from a bot
      -- the host is puppeting carries no build, and "no build in this
      -- message" must not erase what the trainer already told us
      p.build = msg.build or p.build
      self:noteBuild(actor, p)
      if msg.status == "out" and self:inRound() then self:checkWinner() end

    elseif msg.t == "step" then
      if p then
        if msg.map then p.map = msg.map end
        p.x, p.y, p.facing = msg.x, msg.y, msg.dir
        self.ghosts:pushStep(actor, msg.dir)
      end

    elseif msg.t == "face" then
      if p then
        p.facing = msg.facing
        self.ghosts:face(actor, msg.facing)
      end

    -- POK-113: what they are doing that is not walking.  Only meaningful
    -- for somebody we already know about -- a busy arriving before their
    -- first place has nowhere to be drawn, and their next resync carries
    -- the answer again anyway.
    elseif msg.t == "busy" then
      if p then p.busy = msg.kind end

    elseif msg.t == "start" then
      -- Only the host is a legitimate author; ignore a forged one.
      --
      -- What used to stand beside that was `not self.started`, and it cost
      -- a match (POK-144).  A client at "over" still has started = true and
      -- cannot clear it by itself -- the MATCH RECORD card waits for A
      -- forever (lib/fame.lua:95-99) and pushes the exit's clocks out every
      -- frame while it is up -- so a host who read their own card first and
      -- pressed PLAY AGAIN had this message DROPPED here, with no log line
      -- and no change on screen.  startMatch still allocated that guest a
      -- spawn, every other client seeded them "alive", and nothing they own
      -- ever broadcast again: the fog could not reach them, checkWinner
      -- counted them to the end, and the phantom was crowned.
      --
      -- So a session is not a reason to refuse this message; it is a reason
      -- to tear the last match down first, which is what onStart does with
      -- it now.  Nothing is lost by dropping the guard: startMatch is the
      -- only sender, the stream is ordered, and the server broadcasts to
      -- every OTHER member (relay/server.js:376-380), so the host applies
      -- its own start directly rather than reading it back.
      if fromId == self.relay.hostId then
        self:onStart(msg)
      end

    elseif msg.t == "challenge" then
      self:onChallenge(fromId, msg.nonce)

    elseif msg.t == "accept" then
      if self.pending and self.pending.to == fromId then
        local nonce = self.pending.nonce
        self.pending = nil
        self:beginBattle(fromId, Engage.isHost(self.myId, fromId), nonce)
      end

    elseif msg.t == "decline" then
      if self.pending and self.pending.to == fromId then
        self.pending = nil
        say("...They ran off.")
      end

    elseif msg.t == "bt" then
      if self.battle and self.battle.opponentId == fromId then
        self.battle.channel:push(msg.inner)
      end

    elseif msg.t == "out" then
      if p then p.status = "out" end
      if self:inRound() then self:checkWinner() end

    elseif msg.t == "botout" then
      -- whoever beat it says so; everyone marks it down, the host recounts
      local bot = Bots.isBot(msg.id) and self.players[msg.id]
      if bot then bot.status = "out" end
      if self:inRound() then self:checkWinner() end

    elseif msg.t == "spill" then
      self.spills:add(msg)

    elseif msg.t == "npcout" then
      -- somebody beat one of Kanto's own; the sprite goes away here too
      pcall(function() BR.despawns:hide(BR.game, msg.map, msg.obj) end)
      -- a fallen gym leader is news to the whole lobby (POK-26) -- whether
      -- a rival took the prize or the fog burned it
      local fallen = Gyms.leaderOfObject(
        self.game and self.game.data and self.game.data.maps, msg.map, msg.obj)
      if fallen and self:inRound() then
        sayLater(("%s has fallen!"):format(fallen.name))
      end

    elseif msg.t == "took" then
      self.spills:take(msg.key)

    elseif msg.t == "safari" then
      -- the Safari clock is the host's too
      if fromId == self.relay.hostId then self:onSafariBeat(msg.left) end

    elseif msg.t == "ring" then
      -- the fog is the host's to declare, like the winner
      if fromId == self.relay.hostId then
        self:applyRing(msg.phase, msg.cx, msg.cy, msg.r, msg.place, msg.elapsed)
      end

    elseif msg.t == "winner" then
      if fromId == self.relay.hostId then self:onWinner(msg.id) end

    elseif msg.t == "fame" then
      -- The champion's own team, and nobody else's to send: a parade from
      -- anyone but the trainer the host just crowned is not a parade.  One
      -- only, so a second cannot restart an ending already running.
      if self.phase == "over" and fromId == self.winnerId
         and not self.pendingFame then
        self.pendingFame = { party = msg.party, stats = msg.stats }
        local nowF = clock() or 0
        self.pendingParade = nowF + 2.5
      end

    elseif msg.t == "again" then
      if fromId == self.relay.hostId then self:onAgain() end

    elseif msg.t == "botrec" then
      -- a bot's team changed: a catch (the host) or a fight's scars (the
      -- client who fought it).  Applied verbatim -- the record is owned
      -- by whoever last touched it, like the bots' movement is
      self.botRecords[msg.id] = msg.record

    elseif msg.t == "peek" then
      self:answerPeek(fromId)

    elseif msg.t == "state" then
      -- only the trainer we are watching has anything to tell us
      if fromId == self.watching then
        self.peeked = { id = fromId, party = msg.party, items = msg.items, money = msg.money }
      end
    end
  end

  -- ------- forced battles
  --
  -- The challenge/accept exchange settles who fights whom; the battle itself
  -- rides a Channel handed to LinkState (LinkState.newFromSession), which
  -- owns every link mode the game has.  The lower room id hosts the lockstep
  -- so both machines start it the same way round.

  -- The aggressor wears the ! (POK-55): the engine's own emotion bubble
  -- (EXCLAMATION, index 1), held for the classic trainer-sight beat -- and
  -- the engine freezes NPCs while an emote runs, so the moment reads
  -- exactly like an NPC trainer spotting you.  Flavor, never a gate: with
  -- nothing to draw it over, the fight just starts.
  local ENGAGE_FLASH_FRAMES = 40
  local function engageFlash(entity, onDone)
    local ow = mod.world:overworld()
    if not (ow and entity) then onDone() return end
    ow.emote = { npc = entity, frames = ENGAGE_FLASH_FRAMES, bubble = 1,
                 onDone = onDone }
  end

  function BR:onChallenge(fromId, nonce)
    -- nobody fights before the drop (POK-21): a peer whose clock ran ahead
    -- of ours is told we are busy, which is true
    if self.phase ~= "match" then
      self.relay:send(fromId, Wire.decline(nonce, "busy"))
      return
    end
    -- a challenge from the player we are already challenging is an accept
    if self.pending and self.pending.to == fromId then
      self.pending = nil
      self.relay:send(fromId, Wire.accept(nonce))
      self:beginBattle(fromId, Engage.isHost(self.myId, fromId), nonce)
      return
    end
    local decision = Engage.answer(
      { status = self.status, inBattle = self.battle ~= nil }, fromId, self.pending,
      self:fleeAvoid(false))
    if decision ~= "accept" then
      self.relay:send(fromId, Wire.decline(nonce, "busy"))
      return
    end
    -- the beat over the challenger's ghost, THEN the accept -- both
    -- machines start after the flash (POK-55)
    self.pending = { to = fromId, nonce = nonce,
                     host = Engage.isHost(self.myId, fromId) }
    engageFlash(self.ghosts:npcOf(fromId), function()
      if not (BR.pending and BR.pending.to == fromId
              and BR.pending.nonce == nonce) then return end
      BR.pending = nil
      if BR.battle or BR.status ~= "alive" then return end
      local challenger = BR.players[fromId]
      if not (challenger and challenger.status == "alive") then return end
      BR.relay:send(fromId, Wire.accept(nonce))
      BR:beginBattle(fromId, Engage.isHost(BR.myId, fromId), nonce)
    end)
  end

  -- The world view along one axis, in pixels, for POK-96's eyeline cap.
  -- Renderer:worldViewSize already accounts for zoom, the faithful-ratio
  -- lock and the window; nil whenever it cannot be asked, and the cap then
  -- falls back to the tuned range.
  function BR:viewSpan(facing)
    local renderer = self.game and self.game.renderer
    if not (renderer and renderer.worldViewSize) then return nil end
    local ok, vw, vh = pcall(renderer.worldViewSize, renderer)
    if not ok then return nil end
    return (facing == "up" or facing == "down") and vh or vw
  end

  function BR:tryEngage()
    if self.status ~= "alive" or self.battle or self.pending then return end
    local ow = mod.world:overworld()
    local player = ow and ow.player
    if not (player and ow.map) then return end
    if player.moving or player.inputLocked then return end
    local me = { id = self.myId, map = ow.map.id, x = player.cellX,
                 y = player.cellY, facing = player.facing,
                 moving = false, status = "alive", busy = false }
    local others = {}
    for id, p in pairs(self.players) do
      -- Their GHOST's cell, not their wire cell (POK-96).  The wire is
      -- where they really are; the ghost is where this screen has drawn
      -- them, and a fight that opens against the wire is a fight against
      -- somebody the player was never shown -- "a battle is triggered and
      -- I don't even see the other player".  The two are a step or two
      -- apart on a live walk and were much further apart before POK-97
      -- fixed the replay rate.  Asking the screen can only ever make an
      -- engage LATER, never earlier, and an idle ghost is snapped onto the
      -- truth by the very next sync.
      local gx, gy = self.ghosts:cellOf(id)
      -- No drawn ghost, no engage (POK-149).  The old `gx or p.x` fallback
      -- was the pop-in: a bot that had just crossed a seam onto this map
      -- could be fought off its wire cell before this screen had drawn it
      -- at all -- "I couldn't see them before the ! appeared".  Skipping it
      -- only ever delays the engage a beat, until the ghost exists.
      if gx then
        others[#others + 1] = { id = id, map = p.map, x = gx, y = gy,
                                facing = p.facing, moving = false,
                                status = p.status,
                                busy = p.status == "battle" }
      end
    end
    -- terrain stops the eyeline; the other trainers on it do not, since they
    -- are entities rather than map tiles (a body in the way is exactly the
    -- nearest-first case Engage.target already resolves)
    local map = ow.map
    local target = Engage.target(me, others, {
      -- and the frame stops it too (POK-96): a fight that opens against
      -- somebody who was never drawn reads as the game jumping you, and
      -- it wasted the walk-up beat on a bot stepping in from off screen
      range = Engage.visibleRange(me.facing, self:viewSpan(me.facing)),
      blocked = function(x, y)
        return not (map:inBounds(x, y) and map:isWalkableCell(x, y))
      end,
      avoid = self:fleeAvoid(true),
    })
    if not target then return end
    -- A bot has no client to lockstep with, so its fight is a local trainer
    -- battle against the party every client derives from the seed.  No
    -- challenge/accept: there is nobody to ask.
    local ow = mod.world:overworld()
    if Bots.isBot(target) then
      -- you are the aggressor: the ! over your own head, then the fight
      self.pending = { to = target, nonce = -1, host = true }
      engageFlash(ow and ow.player, function()
        -- ...and then it walks over (POK-85).  pending is held until it
        -- arrives, so nothing else can start in the meantime.
        BR:walkUpThen(target, function()
          if BR.pending and BR.pending.to == target then BR.pending = nil end
          if BR.status == "alive" and not BR.battle and not BR.botFight then
            BR:startBotBattle(target)
          end
        end)
      end)
      return
    end
    self.nonceSeq = self.nonceSeq + 1
    self.pending = { to = target, nonce = self.nonceSeq,
                     host = Engage.isHost(self.myId, target) }
    self.relay:send(target, Wire.challenge(self.nonceSeq))
    -- and the challenger flashes while the challenge flies (POK-55)
    if ow then
      ow.emote = { npc = ow.player, frames = ENGAGE_FLASH_FRAMES, bubble = 1 }
    end
  end

  -- The other half of the eyeline (POK-149).  tryEngage is the player
  -- spotting somebody; nothing ever let a bot spot the PLAYER, so the only
  -- way a bot fight started was the player standing still, facing it, at
  -- whatever range it had already closed to -- and the walk-up beat
  -- (POK-85) was built for a range nobody ever engaged at.  Now a bot
  -- whose own facing crosses you calls the fight the way a route trainer
  -- does: the ! goes up over ITS head, it walks over, the battle opens.
  --
  -- Local, like every bot fight: each client tests its own player against
  -- the bots on its map, and whoever is seen fights the team every client
  -- derives from the seed anyway.
  function BR:tryBotEngage()
    if self.status ~= "alive" or self.battle or self.pending
       or self.botFight then return end
    local ow = mod.world:overworld()
    local player = ow and ow.player
    if not (player and ow.map) or ow.transitioning then return end
    local map = ow.map
    local blocked = function(x, y)
      return not (map:inBounds(x, y) and map:isWalkableCell(x, y))
    end
    -- inbound honours a flee's grace only, like an inbound challenge
    local avoid = self:fleeAvoid(false)
    local me = { { id = self.myId, map = map.id, x = player.cellX,
                   y = player.cellY, facing = player.facing, moving = false,
                   status = "alive", busy = false } }
    for id, p in pairs(self.players) do
      -- A bot that wants the nurse does not call fights (POK-160): the
      -- record every client derives (and botrec keeps in step) says when
      -- a team is wrecked, and a wrecked bot walking up to a healthy
      -- trainer was the engine of its own elimination.  One-way on
      -- purpose -- the PLAYER may still jump a wounded bot via tryEngage,
      -- which is what wounds are for.
      if Bots.isBot(id) and p.status == "alive" and p.map == map.id
         and not avoid[id] and not Bots.wantsHeal(self:botRecord(id)) then
        -- its GHOST's cell, never its wire cell, for the same reason
        -- tryEngage asks the screen (POK-96): a bot this client has not
        -- drawn cannot call a fight
        local gx, gy = self.ghosts:cellOf(id)
        if gx and Engage.target(
             { id = id, map = p.map, x = gx, y = gy, facing = p.facing,
               moving = false, status = "alive", busy = p.busy and true },
             me, { range = Bots.SIGHT, blocked = blocked }) == self.myId then
          self.pending = { to = id, nonce = -1, host = true }
          engageFlash(self.ghosts:npcOf(id), function()
            BR:walkUpThen(id, function()
              if BR.pending and BR.pending.to == id then BR.pending = nil end
              if BR.status == "alive" and not BR.battle and not BR.botFight then
                BR:startBotBattle(id)
              end
            end)
          end)
          return
        end
      end
    end
  end

  -- ------- bots
  --
  -- The host walks them and relays each step with `as`; every client renders
  -- them through the same ghost driver a human gets.  Anyone may fight one.

  local function canWalk(mapId, x, y)
    local data = BR.game and BR.game.data
    local maps, tilesets = data and data.maps, data and data.tilesets
    if not Spawn.walkable(maps, tilesets, mapId, x, y) then return false end
    -- and never onto a doorway (POK-94).  src/world/NPC.lua refuses this
    -- for Kanto's own NPCs already -- "never wander onto warps, so NPCs
    -- don't walk out of the map" -- and ours were walking on raw tile
    -- walkability, so a bot could stand in a mart's door, block it, and
    -- drop its bag there when it fell.  Roam placement never could: it
    -- deals cells from Spawn.cellsOf, which has excluded warps all along.
    return not Spawn.isWarp(maps, mapId, x, y)
  end

  -- How THIS bot crosses a map (POK-158 M4): on foot, and over water
  -- when the team it built carries a healthy SURF learner -- the same
  -- capability test a player's party menu runs, read from the record.
  -- Same signature as canWalk, so it drops into every path, step check
  -- and wander a bot walks with; the surf answer is asked once per
  -- closure (a BFS asks thousands of times).  Goals, spawns and roam
  -- landings all stay on land -- water is TRANSIT: a route across a bay
  -- to the prey or the errand on the far shore, not a place to live.
  local function botCross(id)
    local surf
    return function(mapId, x, y)
      if canWalk(mapId, x, y) then return true end
      if surf == nil then
        surf = (BR.matchSeed and Bots.canSurf(BR:botRecord(id),
                                              BR.game and BR.game.data))
          or false
      end
      if not surf then return false end
      local data = BR.game and BR.game.data
      return data ~= nil
        and Spawn.swimmable(data.maps, data.tilesets, mapId, x, y)
        and not Spawn.isWarp(data.maps, mapId, x, y)
    end
  end

  -- Fleeing is not free (POK-24, lib/flee.lua).  After a flee neither of
  -- the pair engages the other for a few seconds -- the head start a flee
  -- promises -- and the runner may not initiate on who they fled from for
  -- longer.  `initiating` asks for both sets; an inbound challenge only
  -- honours the grace, so a pursuer who catches up again gets their fight.
  function BR:fleeAvoid(initiating)
    local now = clock() or 0
    local avoid = {}
    for id, until_ in pairs(self.fleeGrace) do
      if until_ > now then avoid[id] = true else self.fleeGrace[id] = nil end
    end
    if initiating then
      for id, until_ in pairs(self.fleeLockout) do
        if until_ > now then avoid[id] = true else self.fleeLockout[id] = nil end
      end
    end
    return avoid
  end


  local cellCache = {}
  local function walkableCells(mapId)
    if cellCache[mapId] then return cellCache[mapId] end
    local data = BR.game and BR.game.data
    local def = data and data.maps[mapId]
    if not def then return {} end
    local cells = Spawn.cellsOf(def, data.tilesets[def.tileset],
                                data.maps, data.tilesets)
    cellCache[mapId] = cells
    return cells
  end

  -- THE ENDGAME HUNT (POK-95).
  --
  -- Squared town-map distance from any map to the NEAREST live trainer's
  -- map -- the same grid the fog is drawn on, so it costs a lookup rather
  -- than a search across Kanto's warp graph.  Returned as a function so
  -- Bots.homeward can rank a bot's exits by it exactly the way it ranks
  -- them by distance to the ring's eye.
  --
  -- nil means "no hunt this beat": too many trainers still alive (the ring
  -- is doing the herding and a beeline would read as an aimbot), no ring
  -- yet, or nobody placeable to hunt.  The caller falls back to the eye.
  --
  -- self.players never holds the local player, so we are added by hand --
  -- a bot that hunts every trainer except the human is not a hunt.
  function BR:huntDistOf(botId)
    if self.phase ~= "match" then return nil end
    if self:aliveCount() > Bots.HUNT_FROM then return nil end
    local locs = self.ringLocs
    if not locs then return nil end
    local targets = {}
    local me = here()
    if self.status ~= "out" and me and locs[me.mapId] then
      targets[#targets + 1] = locs[me.mapId]
    end
    for id, o in pairs(self.players) do
      if id ~= botId and o.status == "alive" and o.map and locs[o.map] then
        targets[#targets + 1] = locs[o.map]
      end
    end
    if #targets == 0 then return nil end
    return function(mapId)
      local l = locs[mapId]
      if not (l and l.x and l.y) then return nil end
      local best
      for _, t in ipairs(targets) do
        local dx, dy = l.x - t.x, l.y - t.y
        local d = dx * dx + dy * dy
        if not best or d < best then best = d end
      end
      return best
    end
  end

  local function roamBot(id, p, now)
    local data = BR.game and BR.game.data
    local exits = Bots.exits(data and data.maps[p.map])
    if #exits == 0 then return end
    p.rng = p.rng or Bots.rng(BR.matchSeed, id)
    -- homeward, not aimless (POK-42): prefer the seam that closes on the
    -- ring's eye, so the mid-game drifts everyone toward the same
    -- shrinking ground.  The distances are cached on BR by applyRing --
    -- this helper sits above townLocations and must not call it (the
    -- POK-24 lesson).
    --
    -- LATE ON, THE PULL CHANGES (POK-95): once the roster is down to a
    -- handful the eye stops being the interesting gradient -- everyone is
    -- already near it -- and the bot walks at whoever is nearest instead.
    -- Otherwise the last three trainers pace three separate maps until the
    -- fog decides it, which is what a playtest actually watched happen.
    local hunt = BR:huntDistOf(id)
    local dist = BR.ringDistOf
    local dest
    if hunt then
      -- no safe-here exemption: standing still is exactly the failure
      -- being fixed.  homeward still holds when no exit is any closer.
      dest = Bots.homeward(exits, hunt, hunt(p.map), p.rng)
      if not dest then
        local hereD = hunt(p.map)
        if hereD and hereD > 0 then
          -- A PLATEAU, not an arrival (POK-153): the target is on another
          -- map, yet no seam is strictly closer at town-map grain, so the
          -- hunt had nothing to say and the bot paced here forever.  Head
          -- for the ring's eye instead -- the user's own fallback ask --
          -- and failing even that, any seam beats standing still.
          dest = (dist and Bots.homeward(exits,
                    function(m) return dist[m] end, nil, p.rng))
            or exits[p.rng(1, #exits)]
        end
        if not dest then p.lastRoam = now return end
      end
    elseif dist then
      -- holding still is only wisdom INSIDE the ring; outside it, the
      -- least-bad seam beats waiting for the fog
      local r = BR.ring and BR.ring.radius
      local hereD = dist[p.map]
      local safeHere = r and hereD and hereD <= r * r
      dest = Bots.homeward(exits, function(m) return dist[m] end,
                           safeHere and hereD or nil, p.rng)
      if not dest then p.lastRoam = now return end -- nearest already: hold
    else
      dest = exits[p.rng(1, #exits)]
    end
    local cells = walkableCells(dest)
    if #cells == 0 then return end
    local c = cells[p.rng(1, #cells)]
    p.map, p.x, p.y = dest, c.x, c.y
    p.lastRoam = now
    -- fogTicks deliberately survive the move.  They used to reset here ("a
    -- new map is a fresh verdict"), and with a roam every 25 seconds against
    -- a 40-second kill, a bot that kept walking could never die in the fog
    -- -- which is exactly the match-never-ends that POK-5 was about.  The
    -- ticks are the damage a player would still be carrying; whether the NEW
    -- map is inside the ring is re-asked every tick anyway.
    BR.ghosts:despawn(id)
    BR.relay:broadcast(Wire.place(p.map, p.x, p.y, p.facing or "down",
                                  p.status, p.sprite, id))
  end

  -- ------- the walk over (POK-85)
  --
  -- The "!" said a bot had seen you and then the battle simply happened,
  -- from wherever it was standing.  A Gen 1 trainer walks over first, so
  -- this does: after the flash, the bot closes the distance and the fight
  -- starts when it arrives.
  --
  -- Cosmetic on purpose.  A bot fight is entirely local -- every client
  -- derives the same party from the seed and there is no handoff to keep
  -- in step -- so the stride needs nobody's agreement.  A host broadcasts
  -- the steps so other screens see it too; a guest walks only its own copy
  -- and the host's next step message puts the bot back where it really is.
  -- BR.pending is held for the whole walk, so tryEngage cannot start a
  -- second fight while this one is on its way over.
  function BR:walkUpThen(botId, onDone)
    local p = self.players[botId]
    local me = here()
    if not (p and me and p.map == me.mapId) then return onDone() end
    self.walkUp = { id = botId, steps = 0, at = 0, onDone = onDone }
  end

  function BR:tickWalkUp()
    local w = self.walkUp
    if not w then return end
    -- The walk ARRIVED: the callback opens the fight.
    local function arrived()
      self.walkUp = nil
      if w.onDone then w.onDone() end
    end
    -- It did not.  POK-145: this used to call onDone too, so the moment the
    -- match moved on the pending walk-up IMMEDIATELY opened a bot battle in
    -- a finished world.  The callbacks clear BR.pending, so an abandon has
    -- to clear it here or tryEngage is wedged on a challenge that will
    -- never resolve.
    local function abandon()
      self.walkUp = nil
      if self.pending and self.pending.to == w.id then self.pending = nil end
    end
    local p = self.players[w.id]
    local me = here()
    -- it died on the way, we left the map, or the match moved on
    if not (p and me and p.map == me.mapId and p.status == "alive"
            and self.phase == "match") then return abandon() end
    local now = clock() or 0
    if (now - (w.at or 0)) < Bots.WALKUP_SECONDS then return end
    w.at = now
    -- re-aimed every step: you are free to move, and it follows
    local dir = Bots.approach(p, canWalk, { x = me.x, y = me.y })
    if not dir or w.steps >= Bots.WALKUP_STEPS then return arrived() end
    w.steps = w.steps + 1
    local d = Bots.DELTA[dir]
    p.facing = dir
    p.x, p.y = p.x + d[1], p.y + d[2]
    self.ghosts:pushStep(w.id, dir)
    if self.relay and self.relay:isHost() then
      self.relay:broadcast(Wire.step(dir, p.x, p.y, p.map, w.id))
    end
  end

  -- Put a mark over a bot's head, once, and tell the room.  Guarded on the
  -- current value for the same reason broadcastBusy is: this runs on every
  -- beat of a dwell and the room only needs the edges.
  -- `id` is passed rather than read off `p`: BR.players is KEYED by id and
  -- the records do not carry one.
  function BR:markBot(id, p, kind)
    if p.busy == kind then return end
    p.busy = kind
    if self.relay then self.relay:broadcast(Wire.busy(kind, id)) end
  end

  -- Tall grass per map, swept once.  It cannot change during a match, and
  -- the sweep is every cell of the map -- fine once, not once a beat.
  function BR:grassOn(mapId)
    local data = self.game and self.game.data
    if not (data and mapId) then return {} end
    self.grassCache = self.grassCache or {}
    local hit = self.grassCache[mapId]
    if not hit then
      hit = Bots.grassCells(data.maps, data.tilesets, mapId)
      self.grassCache[mapId] = hit
    end
    return hit
  end

  -- The bot's persistent team (POK-158 M1).  Created lazily and
  -- IDENTICALLY on every client -- Bots.newRecord derives the one drop
  -- mon from the seed at the floor rung -- so no message is needed until
  -- the record actually changes; every change after that arrives as a
  -- botrec broadcast and replaces the copy wholesale.
  function BR:botRecord(id)
    local rec = self.botRecords[id]
    if not rec then
      rec = Bots.newRecord(self.matchSeed, id, self.game and self.game.data)
      self.botRecords[id] = rec
    end
    if not rec.bag then
      -- The bag is part of the record now (POK-158 M2): the authored
      -- staples plus the seeded TM, derived identically everywhere like
      -- the drop mon -- and then LIVED OUT OF: potions get drunk, looted
      -- bags fold in.  Rows are copies: BOT_LOOT is shared authored data
      -- and a bot drinking from it would drink for every bot at once.
      local items = {}
      for _, it in ipairs(BOT_LOOT.items) do
        items[#items + 1] = { id = it.id, n = it.n }
      end
      local tm = Bots.lootTM(self.matchSeed, id)
      local data = self.game and self.game.data
      if tm and data and data.items and data.items[tm] then
        items[#items + 1] = { id = tm, n = 1 }
      end
      rec.bag = { items = items, money = BOT_LOOT.money }
    end
    return rec
  end

  -- A grass dwell DOES the thing it used to pretend to (POK-158): the six
  -- seconds standing in the grass are a catch roll against the map's own
  -- encounter table.  Host only, like everything that moves a bot; the
  -- catch rides a botrec broadcast so every client's copy of the team
  -- grows together.
  function BR:botCatch(id, p)
    local data = self.game and self.game.data
    local enc = data and data.encounters and data.encounters[p.map]
    local slots = enc and enc.grass and enc.grass.slots
    local rec = self:botRecord(id)
    local caught = Bots.rollCatch(rec, Bots.recordCap(), slots, p.rng)
    if caught then
      log:say("CAUGHT: %s got %s (%d mons)", tostring(p.name),
              tostring(caught), #rec)
      if self.relay then self.relay:broadcast(Wire.botrec(id, rec)) end
    end
  end

  -- A spill under a bot's feet joins its team (POK-158 M2).  The 1.5s
  -- item dwell used to be pure theater; now the ball it stood on is
  -- taken -- gone for everyone, exactly as if a player had pocketed it
  -- -- and the mon inside joins the record, fresh the way a player's
  -- pickup is.  Bags stay on the ground: a bot has no persistent bag
  -- yet, and eating one would erase loot a player could still use.
  function BR:botLoot(id, p)
    local rec = self:botRecord(id)
    local key = self.spills and self.spills:keyAt(p.map, p.x, p.y)
    local ball = key and self.spills:get(key)
    if not ball then return end
    if ball.bag then
      -- a fallen trainer's bag folds into the bot's own (POK-158 M2):
      -- the potions get drunk later, the TMs get taught, the money rides
      -- to whoever finally beats it
      Bots.bagMerge(rec.bag, ball)
      log:say("LOOTED: %s took %s's bag", tostring(p.name),
              tostring(ball.name or "someone"))
    elseif ball.species and #rec < Bots.recordCap() then
      rec[#rec + 1] = { species = ball.species, hpFrac = 1 }
      log:say("LOOTED: %s took %s (%d mons)", tostring(p.name),
              tostring(ball.species), #rec)
    else
      return
    end
    self.spills:take(key)
    if self.relay then
      self.relay:broadcast(Wire.took(key))
      self.relay:broadcast(Wire.botrec(id, rec))
    end
  end

  -- The Centre serves bots too (POK-158 M2).  Walking to the door and
  -- waiting the dwell out is the whole visit -- the interior trip is
  -- abstracted, the way the fight against another bot is -- and the rule
  -- is the player's own: no nurse in a fogged town (POK-117/140), which
  -- pickBotGoal enforced when it offered the errand and this re-checks,
  -- because the ring may have moved while the bot walked over.
  function BR:botHeal(id, p)
    if self:fogOver(p.map) then return end
    local rec = self:botRecord(id)
    local healed = false
    for _, m in ipairs(rec) do
      if (m.hpFrac or 0) < 1 then m.hpFrac = 1 healed = true end
    end
    if not healed then return end
    log:say("HEALED: %s at the %s CENTER", tostring(p.name), tostring(p.map))
    if self.relay then self.relay:broadcast(Wire.botrec(id, rec)) end
  end

  -- The cell in front of this map's POKeMON CENTER door, or nil.  Doors
  -- all face south in Gen 1, so "in front" is one cell down; a door whose
  -- step cell is not walkable is not offered (a bot grinding at a blocked
  -- doorway forever is worse than one that never heals).  Cached: warps
  -- cannot move during a match.
  function BR:centerDoorOn(mapId)
    self.centerDoorCache = self.centerDoorCache or {}
    local hit = self.centerDoorCache[mapId]
    if hit ~= nil then return hit or nil end
    local data = self.game and self.game.data
    local def = data and data.maps and data.maps[mapId]
    local found = false
    for _, w in ipairs((def and def.warps) or {}) do
      if type(w.destMap) == "string" and w.destMap:find("POKECENTER", 1, true)
         and canWalk(mapId, w.x, w.y + 1) then
        found = { x = w.x, y = w.y + 1 }
        break
      end
    end
    self.centerDoorCache[mapId] = found
    return found or nil
  end

  -- What this bot is off to do, or nil to let the roam clock move it on.
  function BR:pickBotGoal(id, p, now)
    local rec = self:botRecord(id)
    -- a wrecked team walks to the Centre (POK-158 M2), under the same
    -- rule the player's nurse serves by: not once the fog has the town
    local door = not self:fogOver(p.map) and self:centerDoorOn(p.map) or nil
    -- The bag where there is no nurse (POK-160).  quaff only ran as a
    -- winner's swig after a bot-vs-bot fight, so a bot wounded any other
    -- way -- a lost trade, the fog -- sat on a bag of potions while it
    -- hiked toward a Centre it might never reach.  Now a hurt bot on a
    -- map with no (unfogged) Centre drinks when it stops to think, one
    -- sip per goal pick, and the errand below is chosen off the healed
    -- record.  Where the nurse IS an option she wins: she is free and
    -- heals everything, and the potions keep for the road.
    if Bots.wantsHeal(rec) and not door then
      local drank = Bots.quaff(rec, rec.bag)
      if drank then
        log:say("POTION: %s used its %s", tostring(p.name), tostring(drank))
        if self.relay then self.relay:broadcast(Wire.botrec(id, rec)) end
      end
    end
    local g = Bots.chooseGoal(p, {
      -- the fog outranks every errand, as it does for a player.  Reuses
      -- the per-map question POK-140 needed for the CENTRE counters.
      inFog = self:fogOver(p.map),
      heal = Bots.wantsHeal(rec) and door or nil,
      -- loot is only an errand while something there can be taken: any
      -- of it with room in the party, just the bags without
      items = self.spills
        and self.spills:cellsOn(p.map, #rec >= Bots.recordCap()) or nil,
      grass = self:grassOn(p.map),
      -- the floor under every other errand: a bot must always have
      -- somewhere it can walk HERE, or a town with no grass freezes it
      cells = walkableCells(p.map),
    }, p.rng)
    if not g or g.kind == "seam" then
      -- nothing here worth walking to: bring the seam clock forward rather
      -- than standing still until it comes round on its own
      p.lastRoam = 0
      return nil
    end
    g.map, g.at = p.map, now or 0
    return g
  end

  -- One step of an errand: walk the path, then STAND THERE for a beat.
  --
  -- The dwell is the half that sells it.  A bot that walks to a patch of
  -- grass and immediately leaves is a bot on a route; a bot that walks
  -- into the grass and stops for six seconds is a trainer who found
  -- something.  Same for a spill: you stop to pick things up.
  function BR:stepBotErrand(id, p, now)
    if p.dwellUntil then
      if now and now < p.dwellUntil then return nil end
      p.dwellUntil = nil
      self:markBot(id, p, nil)
      -- the dwell pays out as it ends: six seconds in the grass was a
      -- hunt, a pause on a spill was picking it up, a wait at the Centre
      -- door was the nurse (POK-158)
      if p.dwellKind == "grass" then self:botCatch(id, p)
      elseif p.dwellKind == "item" then self:botLoot(id, p)
      elseif p.dwellKind == "heal" then self:botHeal(id, p) end
      p.dwellKind = nil
    end

    local goal = p.goal
    local stale = not goal or goal.map ~= p.map
      or (now and (now - (goal.at or 0)) > Bots.GOAL_SECONDS)
    if stale then
      p.goal, p.path = self:pickBotGoal(id, p, now), nil
      goal = p.goal
    end
    if not goal then return nil end

    if p.x == goal.x and p.y == goal.y then
      local dwell = Bots.DWELL[goal.kind] or 0
      if dwell > 0 then
        p.dwellUntil = (now or 0) + dwell
        p.dwellKind = goal.kind
        -- What the room sees over their head while they stand there
        -- (POK-113's marks, POK-121's errands).  Grass reads as a FIGHT,
        -- because that is what standing in grass for six seconds is; a
        -- spill reads as a menu, because picking things up is.
        self:markBot(id, p, goal.kind == "grass" and "battle" or "menu")
      end
      p.goal, p.path = nil, nil
      return nil
    end

    -- A real path, not a greedy step: the whole point is that a wall or a
    -- ledge is walked AROUND.  Kept on the bot and rebuilt only when it
    -- runs out or a step is refused, because the host pays for this thirty
    -- times a beat.
    local cross = botCross(id)
    if not (p.path and p.path[1]) then
      p.path = Bots.path(function(x, y) return cross(p.map, x, y) end,
                         { x = p.x, y = p.y }, { x = goal.x, y = goal.y })
      if not p.path then
        -- Unreachable, which is a REAL answer on these maps: walkable is
        -- not reachable (POK-23 -- an island behind Surf, a Cut-fenced
        -- pocket, a ledge-locked hollow all pass the walkable test), and
        -- walkableCells hands out cells from the whole map.  A bot in a
        -- pocket can pick unreachable goals forever.
        --
        -- The measured run said so: with the stroll fallback in but no
        -- floor under it, two of six bots still never moved.  So the
        -- errand system is allowed to fail, and WANDER IS THE FLOOR -- a
        -- bot always moves, even when it has nowhere sensible to go.
        p.goal = nil
        p.pathFails = (p.pathFails or 0) + 1
        if p.pathFails >= 2 then
          p.pathFails = 0
          return Bots.wander(p, p.rng, cross, nil)
        end
        return nil
      end
      p.pathFails = 0
    end

    local dir = table.remove(p.path, 1)
    local d = dir and Bots.DELTA[dir]
    if not (d and cross(p.map, p.x + d[1], p.y + d[2])) then
      p.path = nil          -- somebody moved into us; repath next beat
      return nil
    end
    return dir
  end

  -- The stalk, at cell grain (POK-153).  Same-map prey used to get the
  -- greedy Bots.wander(toward), and greedy is exactly what paces: two
  -- blocked candidate directions at a ledge or a fence and the march
  -- turns back into shuffling -- which a spectator at three-left watched
  -- a bot do indefinitely.  A stalk deserves what errands already have:
  -- a real BFS path, walked cell by cell, rebuilt when the prey moves.
  function BR:stepBotHunt(id, p, prey)
    -- a stalk interrupts an errand: the FIGHT/menu mark from a dwell must
    -- not stay over its head while it walks somebody down
    if p.busy then self:markBot(id, p, nil) end
    p.dwellUntil = nil
    -- adjacent is as close as a stalk gets; the eyelines do the rest
    if math.abs(prey.x - p.x) + math.abs(prey.y - p.y) <= 1 then
      p.huntPath, p.huntFor = nil, nil
      return nil
    end
    if p.rng() < 0.2 then return nil end -- the wobble the wander had
    -- with SURF on the team, the path may cross the bay (POK-158 M4)
    local cross = botCross(id)
    local stale = not (p.huntPath and p.huntPath[1])
      or p.huntMap ~= p.map
      or not p.huntFor
      or (math.abs(p.huntFor.x - prey.x) + math.abs(p.huntFor.y - prey.y)) > 2
    if stale then
      p.huntMap, p.huntFor = p.map, { x = prey.x, y = prey.y }
      p.huntPath = Bots.path(function(x, y) return cross(p.map, x, y) end,
                             { x = p.x, y = p.y },
                             { x = prey.x, y = prey.y })
      if not p.huntPath then
        -- unreachable -- a Surf pocket the team cannot cross, a ledge-
        -- locked hollow: the greedy step is still better than standing
        -- down
        return Bots.wander(p, p.rng, cross, prey)
      end
    end
    local dir = table.remove(p.huntPath, 1)
    local d = dir and Bots.DELTA[dir]
    if not (d and cross(p.map, p.x + d[1], p.y + d[2])) then
      p.huntPath = nil        -- somebody moved into us; repath next beat
      return nil
    end
    return dir
  end

  function BR:tickBots()
    if not (self.relay and self.relay:isHost() and self:inRound()) then return end
    local now = clock()
    local striding = self.walkUp and self.walkUp.id
    -- The roster half is once per tick -- the seam clock tightens as the
    -- roster thins (POK-95) and every bot reads the same roster -- but the
    -- TIER half is per bot (POK-121), so the multiply happens inside.
    local alive = self:aliveCount()
    -- self.players never holds the local player (the huntDistOf lesson),
    -- so the host's own trainer was invisible to every same-map hunt: on a
    -- solo match no bot ever walked at the player at all, and "hunt the
    -- nearest trainer, bot or human" only ever meant remote humans.
    local meHere = (self.phase == "match" and self.status == "alive")
      and here() or nil
    for id, p in pairs(self.players) do
      -- a bot on its way over is not also strolling somewhere (POK-85),
      -- and the one we are FIGHTING stands its ground (POK-154): walkUp is
      -- cleared the moment the battle opens, so without this the opponent
      -- resumed roaming behind the battle screen and its loot spilled
      -- wherever it had wandered to by the end
      if p.bot and p.status == "alive" and p.map and id ~= striding
         and id ~= self.botFight then
        -- cached on the bot beside its rng, for the same reason: derived
        -- from (seed, id) and constant for the match
        p.tier = p.tier or Bots.tier(self.matchSeed, id)
        local roamEvery = Bots.roamSeconds(alive, p.tier)
        -- every so often, walk a seam into a connected map -- but not out
        -- from under a walk to the nurse (POK-160): the endgame roam pull
        -- (huntDistOf) could drag a wrecked bot off the one map with a
        -- Centre on it, arriving at the last trainers half-dead, which is
        -- the "pre-heal, then hunt" beat backwards.  An unreachable door
        -- clears the goal (stepBotErrand's path failure), so this cannot
        -- pin a bot to a map it can never heal on.
        local nursing = (p.goal and p.goal.kind == "heal")
          or p.dwellKind == "heal"
        -- ...nor out from under a STALK (POK-160): the roam clock kept
        -- running while a bot walked prey down, so every 15-25s the hunt
        -- was teleported into a connected map and all the closing was
        -- thrown away -- on a big map the stalk could never finish.
        -- Roam exists so bots MEET trainers; a bot sharing a map with
        -- one has already met theirs.
        -- (the fog still outranks the hunt, as it does every errand:
        -- deferring roam on a fogged map would let prey bait a bot into
        -- the fog and camp there while it burned)
        local preyHere = false
        if self.phase == "match" and p.map and not self:fogOver(p.map)
           and not Bots.wantsHeal(self:botRecord(id)) then
          if meHere and meHere.mapId == p.map then preyHere = true end
          if not preyHere then
            for otherId, o in pairs(self.players) do
              if otherId ~= id and o.status == "alive" and o.map == p.map then
                preyHere = true
                break
              end
            end
          end
        end
        if now and not nursing and not preyHere
           and (now - (p.lastRoam or 0)) >= roamEvery then
          roamBot(id, p, now)
        end
        local due = now == nil or (now - (p.lastStep or 0)) >= BOT_STEP_SECONDS
        if due then
          p.lastStep = now or 0
          p.dueBeats = (p.dueBeats or 0) + 1
          -- one stream per bot, kept on the bot so its walk does not depend
          -- on how many other bots are in the table or what order pairs()
          -- happens to hand them back
          p.rng = p.rng or Bots.rng(self.matchSeed, id)
          -- hunt the nearest trainer sharing this map, bot or human, so a
          -- crowded route resolves itself instead of two strangers pacing
          -- opposite ends of it forever
          -- (not in the Safari: nobody fights there, and a ghost body
          -- closing in on you is a wall in a phase with no way past it)
          -- ...unless ITS OWN team says no (POK-160).  A bot picks its
          -- fights now: wrecked -- the same wantsHeal line the Centre
          -- errand runs on -- means the stalk stands down and the errand
          -- system takes over, whose heal goal outranks everything else
          -- on the map.  Healed (nurse or quaff), the hunt resumes on its
          -- own the next beat.  tickBotFights stays ungated: two bots
          -- that blunder into each other still fight, or nobody thins
          -- the roster.
          local prey
          if not Bots.wantsHeal(self:botRecord(id)) then
            if meHere and meHere.mapId == p.map then
              prey = { x = meHere.x, y = meHere.y }
            end
            for otherId, o in pairs(self.phase == "match" and self.players or {}) do
              if otherId ~= id and o.status == "alive" and o.map == p.map then
                if not prey or (math.abs(o.x - p.x) + math.abs(o.y - p.y))
                   < (math.abs(prey.x - p.x) + math.abs(prey.y - p.y)) then
                  prey = o
                end
              end
            end
          end
          -- Prey outranks any errand: a trainer on your map is what you
          -- came for.  The stalk walks a real path now (POK-153) -- see
          -- stepBotHunt for why greedy wandering paced instead.
          --
          -- Everything else is an ERRAND now (POK-121).  The old version
          -- picked a far random walkable cell and biased wander toward it,
          -- which aimed the walk but not at anything: a spectator following
          -- a bot saw it cross a route for no reason, turn around, and do
          -- it again.  Worse, wander is greedy -- two candidate directions
          -- and a stroll when both are blocked -- so a ledge or a fence
          -- turned the march back into pacing, which is exactly what a
          -- watched bot must never do.
          local dir
          if prey then
            dir = self:stepBotHunt(id, p, prey)
          elseif self.phase ~= "match" then
            dir = Bots.wander(p, p.rng, canWalk, nil)
          else
            dir = self:stepBotErrand(id, p, now)
          end
          if dir then
            local d = Bots.DELTA[dir]
            p.facing = dir
            p.x, p.y = p.x + d[1], p.y + d[2]
            p.stepsTaken = (p.stepsTaken or 0) + 1
            self.relay:broadcast(Wire.step(dir, p.x, p.y, p.map, id))
            self.ghosts:pushStep(id, dir) -- our own copy walks it too
          end
        end
      end
    end
  end

  -- ------- the fog
  --
  -- A circle in Town Map space (see lib/fog.lua).  The host owns the clock
  -- and announces each shrink; nobody derives it from their own wall clock,
  -- which would drift.  Everything after that is local: whether YOUR map is
  -- inside, and what the fog does to you if it is not.

  local function townLocations()
    local field = BR.game and BR.game.data and BR.game.data.field
    return field and field.townMap and field.townMap.locations
  end

  -- the named places worth closing the ring on; `all` widens it from the
  -- fly towns to every outdoor map the Town Map can place (the routes)
  local function townList(all)
    local locations = townLocations()
    local maps = BR.game and BR.game.data and BR.game.data.maps
    if not (locations and maps) then return {} end
    local Map = require("src.world.Map")
    local out = {}
    for id, def in pairs(maps) do
      if Map.isOutdoor(def) and (all or Map.isFlyTown(def)) and locations[id] then
        out[#out + 1] = { id = id, x = locations[id].x, y = locations[id].y,
                          name = locations[id].name or id }
      end
    end
    return out
  end

  -- ------- the Safari opening (POK-21) and the drop (POK-22)
  --
  -- A match opens with everyone in the SAFARI ZONE together: thirty SAFARI
  -- BALLs, the vanilla step budget, a clock the host owns, and nobody able
  -- to fight anybody.  The buzzer is the vanilla PA -- "Ding-dong!  Time's
  -- up!" and the walk to the gate -- and the gate's exit is a picker:
  -- choose the town you drop into, land on a random cell of it, and the
  -- match proper begins.  A player who caught nothing is out at the
  -- buzzer: they brought no team to a team-as-health mode.
  --
  -- Phases: "safari" (the round), "drop" (the buzzer has sounded; PA, gate
  -- and picker in flight, per client), then "match".  The fog's clock
  -- starts with the host's own landing (tickRing stamps it on its first
  -- call), so the Safari never eats into the first ring.

  -- Every phase change goes through here (POK-86).  Seven scattered
  -- assignments meant the log could not say what the match was DOING,
  -- only what happened to be printed near the moment it changed.
  function BR:setPhase(phase, why)
    if self.phase == phase then return end
    log:say("phase %s -> %s%s", tostring(self.phase), tostring(phase),
            why and (" (" .. why .. ")") or "")
    self.phase = phase
  end

  function BR:inRound()
    return self.phase == "safari" or self.phase == "drop" or self.phase == "match"
  end

  -- The window where an EMPTY PARTY is the designed state, not a defeat.
  -- The SAFARI is entered with nothing and the team is caught during it
  -- (lendGhostLead lends a stand-in precisely because #party == 0), and
  -- "drop" is the buzzer's own frame, before tickDrop has eliminated an
  -- empty-handed player for catching nothing.  Past it, no party means a
  -- real whiteout.  POK-134's refusal guard is scoped to this on BOTH
  -- sides -- recorded here, spent here -- so a verdict cannot outlive the
  -- phase that earned it.
  function BR:catching()
    return self.phase == "safari" or self.phase == "drop"
  end

  -- inRound() is the RULES window -- levels, bag, encounters.  This is the
  -- wider one: the throwaway world is still under our feet, "over"
  -- included.  A match that has just ended is still not somewhere the
  -- engine's own link play or a fast-forward belongs (POK-83/84), and
  -- until POK-82's exit runs there is a real window to stand in.
  function BR:inSession()
    return self:inRound() or self.phase == "over"
  end

  -- May a NEW battle open right now?  Distinct from inRound(), which is the
  -- rules window (levels, bag, encounters).  This is about the screen, and
  -- it is asked at the moment a battle OPENS rather than the moment it was
  -- queued -- the gap between the two is where POK-145 lived: a walk-up
  -- armed during the match arrived after the winner was named and opened a
  -- fight in a finished world.
  function BR:canOpenBattle()
    return self.phase == "match" and self.status == "alive" and not self.battle
  end

  -- May a WILD encounter roll right now?  Narrower than inRound() and
  -- WIDER than canOpenBattle(), by exactly one phase: the Safari's rule is
  -- "no trainer fights", not "no wild encounters" -- catching is the whole
  -- point of the phase, and a party caught there is what you drop with.
  -- Everything else answers the same as canOpenBattle: "drop" is the
  -- buzzer's own frame, "over" is a finished world, and a spectator or a
  -- player already in a battle is in neither of them.
  --
  -- Scoping the grass to canOpenBattle() instead killed the Safari
  -- outright, and the reason it is not merely cosmetic is the ENGINE's
  -- chain: encounter.species is only called on a NON-NIL roll
  -- (src/world/OverworldController.lua:3867-3871, and the same shape in
  -- src/world/gen2/World.lua:3956-3959).  A nil here is not "the zone
  -- rolls through the other hook", it is no zone at all -- two minutes of
  -- empty grass and then tickDrop eliminating the whole room for catching
  -- nothing.
  function BR:canRollWild()
    return (self.phase == "safari" or self.phase == "match")
       and self.status == "alive" and not self.battle
  end

  -- Has the ring started closing?  Distinct from mod.exports.inFog, which
  -- asks whether THIS player is standing in it: this is the match-wide
  -- clock, true for everyone from the first shrink onwards however safe the
  -- square they are on.  What closes the Pokemon Centre (POK-117) is the
  -- match reaching attrition, not the player's own map going dark.
  function BR:fogIsUp()
    return self.ring ~= nil and Fog.isUp(self.ring.radius)
  end

  -- Is the ring over this map?  False for a map the town grid cannot place,
  -- which is isSafe's own answer for an interior.
  function BR:fogOver(mapId)
    if not (self.ring and mapId) then return false end
    return not Fog.isSafe(townLocations(), mapId,
                          self.ring.center, self.ring.radius)
  end

  -- Has the fog reached the CENTRE the player is standing in (POK-140)?
  -- Resolved through the town the building's door opens onto, because an
  -- interior has no square on the ring's grid -- see Fog.outdoorFor.
  function BR:nurseClosed()
    if not self.ring then return false end
    local ow = mod.world:current()
    local save = self.game and self.game.save
    local last = save and save.lastOutdoor and save.lastOutdoor.id
    local mapId = Fog.outdoorFor(townLocations(), ow and ow.mapId, last)
    if not mapId then return false end   -- cannot say: serve them
    return self:fogOver(mapId)
  end

  function BR:safariLeft()
    local now = clock()
    if not (self.safariEndsAt and now) then return 0 end
    return math.max(0, math.ceil(self.safariEndsAt - now))
  end

  -- host only: keep the room's clock in step, and sound the buzzer
  function BR:tickSafari()
    if not (self.relay and self.relay:isHost() and self.phase == "safari") then return end
    local now = clock()
    if not (now and self.safariEndsAt) then return end
    local left = self:safariLeft()
    if left <= 0 then
      self.relay:broadcast(Wire.safari(0))
      self:onBuzzer()
      return
    end
    if not self.lastSafariBeat or (now - self.lastSafariBeat) >= SAFARI_BEAT_SECONDS then
      self.lastSafariBeat = now
      self.relay:broadcast(Wire.safari(left))
    end
  end

  -- a guest hears the host's clock; zero is the buzzer
  function BR:onSafariBeat(left)
    if self.phase ~= "safari" then return end
    local now = clock()
    if now then self.safariEndsAt = now + left end
    if left <= 0 then self:onBuzzer() end
  end

  function BR:onBuzzer()
    if self.phase ~= "safari" then return end
    self:setPhase("drop", "the buzzer")
    self.buzzed = true
    self.buzzedAt = clock()
    self:dropBots()
  end

  -- The engine refuses to open a battle with nobody on your side
  -- (BattleState.newWild: "no healthy party; skipping"), and a Safari
  -- battle never draws or uses your lead anyway.  So while the party is
  -- empty a stand-in is lent for exactly one encounter -- inserted as the
  -- roll lands, gone with the battle screen -- and after the first catch
  -- it is never needed again.  It is never on the overworld, in the START
  -- menu, or in a spill.
  function BR:lendGhostLead()
    local save = self.game and self.game.save
    if not (save and self.phase == "safari") then return end
    if self.safariGhost or #(save.party or {}) > 0 then return end
    local Pokemon = require("src.pokemon.Pokemon")
    local Data = require("src.core.Data")
    local ghost = Pokemon.new(Data, START_SPECIES, START_LEVEL)
    save.party = save.party or {}
    table.insert(save.party, ghost)
    self.safariGhost = ghost
  end

  function BR:reclaimGhostLead()
    local ghost = self.safariGhost
    if not ghost then return end
    self.safariGhost = nil
    local save = self.game and self.game.save
    for i, mon in ipairs((save and save.party) or {}) do
      if mon == ghost then table.remove(save.party, i) break end
    end
  end

  -- the named places a drop can choose, in the Town Map's own order
  function BR:dropTowns()
    local towns = townList()
    local maps = (self.game and self.game.data and self.game.data.maps) or {}
    table.sort(towns, function(a, b)
      local ia = maps[a.id] and maps[a.id].index or 0
      local ib = maps[b.id] and maps[b.id].index or 0
      if ia ~= ib then return ia < ib end
      return a.id < b.id
    end)
    return towns
  end

  -- Where a BOT can be dealt at the buzzer: the fly towns AND the routes
  -- (POK-147).  The player's picker stays towns-only -- a town is a place
  -- you can name -- but a thirty-bot deal over eleven towns wraps into
  -- guaranteed pairs standing in each other's sight-line at t=0, and the
  -- roster was resolving itself before anybody met anybody.  Kanto has 34
  -- placeable outdoor maps, so at Bots.MAX every bot starts a map of its
  -- own and the early fights go back to being found, not dealt.
  function BR:botDropSpots()
    local spots = townList(true)
    local maps = (self.game and self.game.data and self.game.data.maps) or {}
    table.sort(spots, function(a, b)
      local ia = maps[a.id] and maps[a.id].index or 0
      local ib = maps[b.id] and maps[b.id].index or 0
      if ia ~= ib then return ia < ib end
      return a.id < b.id
    end)
    return spots
  end

  -- host only: at the buzzer the bots are DEALT drop maps -- the deck, not
  -- the dice (POK-43), so no two share one while maps remain and the drop
  -- stops resolving itself in the first minute
  function BR:dropBots()
    if not (self.relay and self.relay:isHost()) then return end
    local towns = self:botDropSpots()
    if #towns == 0 then return end
    local now = clock() or 0
    local ids = {}
    for id, p in pairs(self.players) do
      if p.bot and p.status == "alive" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local deal = Bots.dealTowns(#towns, #ids,
                                Spawn.rng((self.matchSeed or 1) + 4242))
    for k, id in ipairs(ids) do
      local p = self.players[id]
      p.rng = p.rng or Bots.rng(self.matchSeed, id)
      local town = towns[deal[k]]
      local cells = walkableCells(town.id)
      if #cells > 0 then
        local c = cells[p.rng(1, #cells)]
        p.map, p.x, p.y, p.facing = town.id, c.x, c.y, "down"
        p.lastRoam = now
        self.ghosts:despawn(id)
        self.relay:broadcast(Wire.place(p.map, p.x, p.y, "down", p.status, p.sprite, id))
      end
    end
  end

  -- The PA is patient, not infinitely so (POK-92).
  --
  -- tickDrop below only works on the overworld, so a battle that is open at
  -- the buzzer simply parks the whole drop -- and a player who kept
  -- throwing balls (or just sat in the SAFARI menu) stayed in the zone
  -- catching a team while everyone else was already picking a town.  That
  -- is the one thing the Safari clock exists to prevent.
  --
  -- So: a throw already in flight gets its grace seconds to land, and then
  -- the battle is closed out from under it.  BattleState:finish is the
  -- engine's own choke point for leaving a battle -- it restores the map
  -- music, pops itself and emits battle.ended -- so the ghost lead is still
  -- reclaimed (POK-21) and the return fade still plays.  It pops the TOP of
  -- the stack, though, so anything the player parked above the battle (the
  -- bag, a party screen) is backed out with B first -- never A, which would
  -- choose something in there (the POK-66 rule).
  --
  -- Close a live local battle out from under whatever is happening in it.
  -- `since` is the caller's own clock, `grace` how long a throw already in
  -- flight gets to land.  Returns "none" | "waiting" | "closed".
  function BR:closeLiveBattle(since, grace, why)
    local battle = self:liveLocalBattle()
    if not battle then return "none" end
    local game, now = self.game, clock()
    if not (game and now and since) then return "waiting" end
    if (now - since) < (grace or 0) then return "waiting" end
    if game.stack:top() ~= battle then
      if self.lastBuzzB and (now - self.lastBuzzB) < 0.5 then return "waiting" end
      self.lastBuzzB = now
      if game.input and game.input.pressQueue then
        table.insert(game.input.pressQueue, "b")
      end
      return "waiting"
    end
    log:say("%s closed a battle that was still open", tostring(why or "something"))
    battle.result = battle.result or "run"
    local ok, err = pcall(battle.finish, battle)
    if not ok then
      mod.log:warn("couldn't close the battle: %s", tostring(err))
      return "waiting"
    end
    self.localBattle = nil
    return "closed"
  end

  function BR:closeBuzzedBattle()
    if self.phase ~= "drop" then return end
    self.buzzedAt = self.buzzedAt or clock()
    self:closeLiveBattle(self.buzzedAt, BUZZER_BATTLE_GRACE, "the buzzer")
  end

  -- POK-155: the match ended while a fight was still open.  Waiting for it
  -- to finish is the one thing that cannot happen -- checkWinner counts the
  -- local player as a survivor on status ~= "out" and a route trainer
  -- leaves status "alive", so the win lands mid-fight; the banner is queued
  -- into a script runner nothing is updating; and the parade's gate can
  -- never pass while a battle owns the top of the stack.  So the fight is
  -- closed the way the buzzer closes one: B out of anything parked above
  -- it, then BattleState:finish -- which restores the music, pops itself,
  -- and emits battle.ended as a run.  Nobody collects: the npcDefeated
  -- payout is gated on phase "match", which this is not.
  --
  -- A blackout is nearly, but not quite, impossible on the way out.
  -- BattleState:finish upgrades ANY non-"lose" result to "lose" when the
  -- party has nothing healthy left (src/battle/BattleState.lua:5293-5298),
  -- so "a run raises no world.blacked_out" is not unconditional.  The
  -- window is thin -- the champion normally has a healthy mon, and
  -- fogBiteBattle floors the active at 1 HP rather than fainting it -- and
  -- what comes through it is bounded: eliminate() refuses outright at
  -- "over", and the blackout's own save is written into the throwaway world
  -- this exit is about to discard.
  function BR:closeOverBattle()
    if self.phase ~= "over" then return end
    self.overBattleAt = self.overBattleAt or clock()
    self:closeLiveBattle(self.overBattleAt, BUZZER_BATTLE_GRACE, "the end of the match")
  end

  -- The buzzer's work, once we are standing on the overworld with no battle
  -- open (closeBuzzedBattle above is what guarantees we get there).  Caught
  -- nothing: out.  Still in the zone: the vanilla game-over -- the PA
  -- jingle, "Time's up!", the walk to the gate.  Then the picker, at the
  -- gate -- or straight away for a player the PA already sent there.
  function BR:tickDrop()
    if self.phase ~= "drop" then return end
    local game = self.game
    local ow = mod.world:overworld()
    if not (game and ow and game.stack:top() == ow and not ow.transitioning) then return end
    if self:liveLocalBattle() then return end
    local save = game.save
    if self.buzzed then
      self.buzzed = nil
      if #(save.party or {}) == 0 then
        pcall(function() require("src.core.Sound").play(game.data, "Safari_Zone_PA") end)
        save.safari = nil
        self:eliminate("PA: Ding-dong!\nTime's up!\fYou caught nothing.\nYou are out of\nthe match.",
                       "caught nothing")
        self:setPhase("match", "caught nothing")   -- a spectator from here on
        return
      end
      self.pickingTown = true
      if save.safari and ow.safariGameOver then
        local t = game.data and game.data.text
        ow:safariGameOver((t and t._TimesUpText) or "PA: Ding-dong!\nTime's up!")
        return
      end
    end
    if self.pickingTown and not save.safari then
      self:openTownPicker()
    end
  end

  -- YOU PICK YOUR DROP ON THE MAP (POK-101).
  --
  -- It was a list of town names, which is the one screen in Gen 1 that
  -- tells you nothing about where anywhere IS -- and where you drop is a
  -- geography decision: how far from the others, how far from wherever the
  -- fog will close.  So it is the TOWN MAP with a cursor, the way the game
  -- already asks "fly where?".
  --
  -- Built by handing TownMap its fly picker and then swapping the fly list
  -- for the drop list.  The engine's own list is `field.flyOrder` filtered
  -- to towns the save has VISITED, which at the buzzer is very nearly
  -- nothing -- a fresh match has been outside exactly one building.  The
  -- cursor machinery (Up/Down to cycle, A to commit, the banner naming
  -- what is under it) is what we want; only its contents are ours.
  --
  -- The mod's ring overlay hooks this same screen by metatable, so the
  -- fog eye draws on it for free -- though at the buzzer the eye has not
  -- been announced yet, since the clock starts at the landing.
  function BR:openTownPickerMap(towns)
    local game = self.game
    local okTM, TownMap = pcall(require, "src.ui.TownMap")
    if not (okTM and TownMap and TownMap.new) then return nil end
    local ok, screen = pcall(TownMap.new, game, {
      fly = true,
      onFly = function(mapId) BR:landIn(mapId) end,
    })
    if not (ok and screen and screen.byMap) then return nil end

    local locs, ids = {}, {}
    for _, town in ipairs(towns) do
      local loc = screen.byMap[town.id]
      -- a town the Town Map cannot place has no square to put a cursor on
      if loc and loc.x and loc.y then
        locs[#locs + 1] = loc
        ids[#locs] = town.id
      end
    end
    if #locs == 0 then return nil end

    screen.fly = true                  -- new() leaves it unset with nothing
    screen.onFly = function(mapId) BR:landIn(mapId) end
    screen.locs = locs
    screen.flyMapIds = ids
    -- start on where we are standing (the Safari gate's town) if it is a
    -- choice, so the cursor opens somewhere the player recognises
    screen.sel = 1
    for i, loc in ipairs(locs) do
      if loc == screen.playerLoc then screen.sel = i break end
    end
    return screen
  end

  function BR:openTownPicker()
    local game = self.game
    local towns = self:dropTowns()
    if #towns == 0 then
      -- no town data to choose from: land where we stand
      self:landIn(nil)
      return
    end
    -- B closes either picker like any other screen; the tick opens it
    -- again, because there is no staying at the gate.  (tickDrop only runs
    -- with the overworld on top, so it can never stack a second one.)
    local mapPicker = self:openTownPickerMap(towns)
    if mapPicker then
      game.stack:push(mapPicker)
      return
    end
    -- no Town Map on this build, or no town it can place: the names still
    -- get you into Kanto
    mod.log:warn("town map picker unavailable; falling back to the list")
    local items = {}
    for _, town in ipairs(towns) do
      items[#items + 1] = { label = town.name, value = town.id }
    end
    game.stack:push(mod.ui.ListMenu.new(game, "DROP WHERE?", items, {
      onChoose = function(item, list)
        list:close()
        self:landIn(item.value)
      end,
    }))
  end

  -- the exact cell is random (POK-22): a popular town does not stack
  -- everyone on one square
  function BR:landIn(mapId)
    self.pickingTown = nil
    self:setPhase("match", "landed")
    local game = self.game
    local data = game and game.data
    if not (mapId and data) then return end
    local rng = Spawn.rng(love.math.random(1, 2 ^ 30))
    local spot = Spawn.pickIn(data.maps, data.tilesets, mapId, 1, rng)
    local cell = spot and spot[1]
    if not cell then return end
    local save = game.save
    -- a whiteout returns here, not to a Safari that is closed
    save.lastHeal = { map = mapId, x = cell.x, y = cell.y }
    save.lastOutdoor = { id = mapId, x = cell.x, y = cell.y }
    local ok, err = mod.world:warpTo(mapId, cell.x, cell.y, "down", { arrive = "fly" })
    if not ok then
      mod.log:warn("could not drop into %s (%s)", tostring(mapId), tostring(err))
    end
  end

  -- The FOG option: what a match started from here would run at.  The
  -- lobby row and the option cyclers all mean this one.
  function BR:fogSeconds()
    return tonumber(mod.options:get("fog")) or Fog.DEFAULT_PHASE_SECONDS
  end

  -- The phase length of the match actually being played, which is whatever
  -- the host who STARTED it had set.  It rides the start message so that an
  -- heir carries the ring on at the pace the round began with rather than
  -- its own (POK-116); before a match, and for a client old enough not to
  -- have been told, it is just the option.
  function BR:roundFog()
    return self.matchFog or self:fogSeconds()
  end

  function BR:safariSeconds()
    local n = tonumber(mod.options:get("safari"))
    if n == nil then return DEFAULT_SAFARI_SECONDS end
    return math.max(0, math.floor(n))
  end


  function BR:applyRing(phase, cx, cy, radius, place, elapsed)
    local was = self.ring and self.ring.phase
    self.ring = { phase = phase, center = { x = cx, y = cy, name = place },
                  radius = radius }
    -- The fog clock is the only thing the host owns that nobody else can
    -- work out for themselves, so it rides every shrink and everyone keeps
    -- it against the day they inherit the room (POK-116).  The host's own
    -- applyRing passes nothing and keeps the clock it already has.
    if elapsed then
      local now = clock()
      if now then self.matchStartedAt = now - elapsed end
    end
    -- every placed map's squared distance to the eye, for the bots'
    -- homeward roams (POK-42); cached here because roamBot is defined
    -- above townLocations
    local locs = townLocations() or {}
    local dists = {}
    for id, loc in pairs(locs) do
      if loc.x and loc.y then
        local dx, dy = loc.x - cx, loc.y - cy
        dists[id] = dx * dx + dy * dy
      end
    end
    self.ringDistOf = dists
    -- kept whole for the endgame hunt (POK-95): roamBot needs distances to
    -- a MOVING target, not just to the eye, and it sits above
    -- townLocations and may not call it (the POK-24 lesson)
    self.ringLocs = locs
    log:say("ring %s: eye %s at %s,%s, radius %s", tostring(phase),
            tostring(place), tostring(cx), tostring(cy), tostring(radius))
    if was == nil then
      -- the eye is public from the landing (POK-39): the ring itself stays
      -- quiet until it first shrinks, but where it will shrink TO is not a
      -- secret -- and the TOWN MAP in the bag can show it
      sayLater(("The fog will close\non %s.\fCheck your\nTOWN MAP."):format(
        place or "KANTO"))
    elseif was ~= phase and phase > 1 then
      -- ONE box per shrink, not three.  The ring, the level rung and the
      -- rod all move on the same beat by design -- lib/levels.lua and
      -- lib/rods.lua both index off the fog phase precisely so the match
      -- keeps one rhythm -- so three messages in a row said one thing
      -- three times and buried the one that mattered under the two that
      -- did not.  The level number and the rod's name were the detail
      -- nobody was reading; that the fog moved and everything got
      -- stronger is the news.  WHERE it closed stays on the TOWN MAP,
      -- which the opening message above points at.
      if Fog.coversAll(radius) then
        sayLater("The fog covers\nall of KANTO!\fYour POKeMON and\nitems grew\nstronger!")
      else
        sayLater("The fog spreads!\fYour POKeMON and\nitems grew\nstronger!")
      end
    end
    -- after the announcement, so the news lands before the gift
    self:upgradeRod()
  end

  -- The fog's other gift (POK-119): the rung that makes everyone stronger
  -- makes the sea better to fish, on the same beat.  A swap rather than a
  -- stack -- three rods in the bag is three ways to do one thing -- and
  -- only ever upward, so a re-applied ring cannot take a SUPER ROD back.
  function BR:upgradeRod()
    if not self:inRound() then return end
    local save = self.game and self.game.save
    local items = self.game and self.game.data and self.game.data.items
    if not (save and save.inventory and items) then return end
    local want = Rods.at(self.ring and self.ring.phase or 1)
    if not (want and items[want]) then return end
    local have = nil
    for _, id in ipairs(Rods.ALL) do
      if (tonumber(save.inventory[id]) or 0) > 0 and Rods.isBetter(id, have) then
        have = id
      end
    end
    if have == want or not Rods.isBetter(want, have) then return end
    for _, id in ipairs(Rods.ALL) do save.inventory[id] = nil end
    save.inventory[want] = 1
    -- Silent on screen: the ring's own message already said the items
    -- got better, and this fires on that same beat.  The transition is
    -- still named in the log, which is where anyone debugging a rung
    -- goes looking for it.
    log:say("rod: %s -> %s", tostring(have or "none"), tostring(want))
  end

  -- The room has been handed to us (POK-116).  Almost nothing needs moving:
  -- everything the old host was authoritative over, every guest was already
  -- mirroring -- where each trainer stands, what has spilled, which of
  -- Kanto's own the fog took, where the ring is -- and the rest (bot names,
  -- teams, faces, walk streams, the ring's eye) falls out of the shared seed
  -- at its use site.  The fog clock is the exception, which is why it rides
  -- every shrink.
  --
  -- What does NOT come across is accumulated grace: the bots' fogTicks and
  -- the per-map npcFog clocks start again here, so a sweep already counting
  -- down gets its forty seconds back.  That is one wobble, in the players'
  -- favour, and cheaper than shipping a state transfer to avoid it.
  function BR:onPromoted()
    log:say("the room is ours now: %s is the host", myName())
    -- the say needs a world to land in; a promotion in the lobby is
    -- the screen's own news, and the log has it either way
    if not self:inRound() then return end
    sayLater("The host left.\fYou are the host\nnow.")
    -- the eye as it was announced, rather than re-derived from the seed
    if self.ring and self.ring.center then self.ringCenter = self.ring.center end
    -- applyRing has been keeping the clock from the host's own `e`.  A
    -- promotion before the first shrink ever landed has none to keep, so
    -- fall back to the phase we can see: starting its clock at the phase
    -- boundary is the closest guess that cannot walk the ring backwards.
    if not self.matchStartedAt then
      local now = clock()
      if now then
        local phase = (self.ring and self.ring.phase) or 1
        self.matchStartedAt = now - (phase - 1) * self:roundFog()
      end
    end
  end

  -- host only: advance the shared clock and tell the room
  function BR:tickRing()
    if not (self.relay and self.relay:isHost() and self.phase == "match") then return end
    local now = clock()
    if not now then return end
    self.matchStartedAt = self.matchStartedAt or now
    local phase = Fog.phaseAt(now - self.matchStartedAt, self:roundFog())
    if self.ring and self.ring.phase == phase then return end

    local center = self.ringCenter or Fog.center(self.matchSeed, townList())
    self.ringCenter = center
    if not center then return end
    local radius = Fog.radius(phase)
    self.relay:broadcast(Wire.ring(phase, center.x, center.y, radius,
                                   center.name, now - self.matchStartedAt))
    self:applyRing(phase, center.x, center.y, radius, center.name)
  end

  -- The fog takes bots on the same terms it takes players: they cannot walk
  -- between maps (that would want pathing across the warp graph), so a bot
  -- the ring leaves behind is a bot that dies in it.  That is the ring doing
  -- its job -- the field compresses phase by phase (about 30 -> 19 -> 14 ->
  -- 9 -> 4 -> 1 on Kanto's 34 outdoor maps) and the survivors end up in the
  -- last few squares with you, which is where the endgame fights come from.
  -- Anything cleverer (relocating them to safety) would be a rule that
  -- applies to bots and not to players, and the player can catch you at it.
  function BR:tickBotFog()
    if not (self.relay and self.relay:isHost() and self.phase == "match"
            and self.ring) then return end
    local now, data = clock(), self.game and self.game.data
    if not (now and data) then return end
    local locations = townLocations()
    local level = Levels.at(self.ring.phase)

    for id, p in pairs(self.players) do
      if p.bot and p.status == "alive" and p.map
         and not Fog.isSafe(locations, p.map, self.ring.center, self.ring.radius) then
        -- ticks, not hit points: the bite is a fraction of maximum HP, so the
        -- same count of them finishes a team at any rung of the ladder, and
        -- nothing here has to know how big a level 100 bot is
        if (now - (p.lastFogTick or 0)) >= Fog.TICK_SECONDS then
          p.lastFogTick = now
          p.fogTicks = (p.fogTicks or 0) + 1
          if p.fogTicks >= Fog.TICKS_TO_KILL then
            -- same exit as losing a fight, so the fog leaves a team on the
            -- ground too rather than quietly deleting one
            self:eliminateBot(id, p, nil)
          end
        end
      else
        p.lastFogTick = nil
      end
    end
  end

  -- Kanto's own trainers die to the fog too (POK-35).  Host-run, like the
  -- bots' fog: every map that holds trainers gets one shared clock once
  -- the ring leaves it (per-trainer would be overkill), and when it runs
  -- out each trainer object on the map is toggled off everywhere -- the
  -- npcout the beaten path already speaks.  No spill: balls mark a kill
  -- site somebody EARNED; fog-killed teams would be litter on maps nobody
  -- can safely loot.
  function BR:tickNpcFog()
    if not (self.relay and self.relay:isHost() and self.phase == "match"
            and self.ring) then return end
    local now, data = clock(), self.game and self.game.data
    if not (now and data) then return end
    if (now - (self.npcFogScanAt or 0)) < 1 then return end
    self.npcFogScanAt = now
    if not self.trainerMaps then
      self.trainerMaps = {}
      for id, map in pairs(data.maps or {}) do
        for _, obj in ipairs(map.objects or {}) do
          if obj.trainerClass then
            self.trainerMaps[#self.trainerMaps + 1] = id
            break
          end
        end
      end
      table.sort(self.trainerMaps)     -- pairs order is not a schedule
    end
    self.npcFog = self.npcFog or {}
    local died = Fog.tickMaps(self.npcFog, self.trainerMaps, townLocations(),
                              self.ring.center, self.ring.radius, now)
    local swept = 0
    for _, mapId in ipairs(died) do
      local took = 0
      for _, obj in ipairs((data.maps[mapId] and data.maps[mapId].objects) or {}) do
        if obj.trainerClass and obj.name then
          took = took + 1
          pcall(function() BR.despawns:hide(BR.game, mapId, obj.name) end)
          if self.relay then self.relay:broadcast(Wire.npcout(mapId, obj.name)) end
        end
      end
      swept = swept + took
      if took > 0 then
        -- POK-87: this used to be an info line PER MAP, every phase, saying
        -- only a number -- so a fog sweep read like something going wrong
        -- and told you nothing about what went.  The per-map detail is the
        -- deep tier's now; the story gets one line for the whole sweep.
        log:deep("cleared %d static trainers on %s", took, tostring(mapId))
      end
    end
    if swept > 0 then
      -- "static trainers", never just "trainers": the old wording read as
      -- eliminations, so a sweep that cleared a gym's worth of authored
      -- NPCs looked like half the lobby dying at once (POK-87)
      log:say("the ring cleared %d static trainers across %d map(s)",
              swept, #died)
    end
  end

  -- The live LOCAL battle, if any (wild, or one of Kanto's own trainers).
  -- PvP and bot fights set status = "battle", which holds tickFog off
  -- entirely, so anything this returns is by construction a battle the
  -- fog may reach into (POK-31).  battle.ended clears it; the stack walk
  -- covers any exit that never said so.
  function BR:liveLocalBattle()
    local b = self.localBattle
    if not b then return nil end
    local stack = self.game and self.game.stack
    local states = (stack and stack.states) or {}
    for i = #states, 1, -1 do
      if states[i] == b then return b end
    end
    self.localBattle = nil
    return nil
  end

  -- Nothing on screen but the world: the overworld is the top state, its
  -- script runner is idle, and no battle is open.  The gate for anything
  -- that takes the world away -- the parade (POK-47) and the exit that
  -- follows it (POK-144).  StateStack:update runs the TOP state only
  -- (src/core/StateStack.lua:60), so a screen pushed under a battle is
  -- pushed somewhere nothing is updating, and a say queued under one is
  -- accepted and then frozen (src/world/WorldAPI.lua:493).
  function BR:screenIsQuiet()
    local game = self.game
    local ow = mod.world:overworld()
    if not (game and ow and game.stack:top() == ow) then return false end
    if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then return false end
    return self:liveLocalBattle() == nil
  end

  -- The other half of POK-31: the enemy's bench ticks like ours, and the
  -- two ACTIVE battlers are floored at 1 HP -- the engine only knows how
  -- to faint a mon through its own move flow (an active at 0 outside it
  -- wedges the menu: ChooseNextMon with no healthy pick just returns
  -- forever, #core.asm:1086).  The fog drains a battle to the brink; the
  -- killing blow has to be thrown inside it.  Display: a running drain
  -- re-reads mon.hp as its goal and lands true on its own; otherwise the
  -- bar is snapped, on the poison beat the tick already plays.
  function BR:fogBiteBattle(battle)
    local seen = {}
    local function bite(mon, floor)
      if not (mon and mon.hp and mon.hp > 0) or seen[mon] then return end
      seen[mon] = true
      mon.hp = math.max(floor, mon.hp - Fog.bite(mon.stats and mon.stats.hp))
    end
    bite(battle.enemy and battle.enemy.mon, 1)
    for _, mon in ipairs(battle.enemyParty or {}) do bite(mon, 0) end
    if not battle.draining then
      local Timing = require("src.core.Timing")
      for _, b in ipairs({ battle.player, battle.enemy }) do
        if b and b.mon and b.shownHP then
          b.shownHP = b.mon.hp
          b.shownPx = Timing.hpBarPixels(b.mon.hp,
            math.max(1, (b.mon.stats and b.mon.stats.hp) or 1))
        end
      end
    end
  end

  -- Are we standing in it, and what it costs.  The fog does not stop at a
  -- LOCAL battle's screen (POK-31): both sides keep taking the bite.
  function BR:tickFog()
    -- A battle holds the fog off (PvP: biting outside the lockstep is a
    -- desync) -- but a LOCAL bot fight stops sheltering after thirty
    -- seconds: the FIGHT menu is not a roof (POK-63).  The body below
    -- already knows how to bite into a live local battle (POK-31).
    local shelterOver = self.status == "battle" and self.botFight
      and self.botFightAt
      and ((clock() or 0) - self.botFightAt) > FOG_SHELTER_SECONDS
    if not (self.phase == "match" and self.ring
            and (self.status == "alive" or shelterOver)) then return end
    local game, now = self.game, clock()
    if not (game and now) then return end
    local here = mod.world:current()
    if not here then return end

    local locations = townLocations()
    if Fog.isSafe(locations, here.mapId, self.ring.center, self.ring.radius) then
      self.wasInFog = false
      return
    end

    local battle = self:liveLocalBattle()

    if not self.wasInFog then
      self.wasInFog = true
      self.lastFogTick = now
      -- the ring moved past us mid-fight: no textbox over a battle screen;
      -- start the clock quietly and let the poison beat carry the news
      if battle then return end
      if Fog.coversAll(self.ring.radius) then
        -- nowhere to send them: the announcement already said so, and a
        -- "get to X" here would be a lie
        say("You are in the fog!")
      else
        say(("You are in the fog!\nGet to %s!")
          :format((self.ring.center and self.ring.center.name) or "safety"))
      end
      return
    end

    if (now - (self.lastFogTick or now)) < Fog.TICK_SECONDS then return end
    self.lastFogTick = now
    -- makeBattler holds the party table itself, so identity finds the mon
    -- on the field right now; it is floored at 1 like the enemy's (above)
    local active = battle and battle.player and battle.player.mon
    local anyLeft = false
    for _, mon in ipairs(game.save.party or {}) do
      if mon.hp > 0 then
        mon.hp = math.max((mon == active) and 1 or 0,
                          mon.hp - Fog.bite(mon.stats and mon.stats.hp))
      end
      if mon.hp > 0 then anyLeft = true end
    end
    if battle then self:fogBiteBattle(battle) end
    -- the bite has to be FELT: one text box on entry and then silence read
    -- as "the fog is broken" in play.  So each tick is the overworld-poison
    -- beat Gen 1 players already know -- the screen flickers dark and the
    -- poison chime plays -- on the engine's own flash so it looks exactly
    -- like walking poisoned does.
    local ow = mod.world:overworld()
    if ow then ow.poisonFlash = 12 end
    pcall(function() require("src.core.Sound").play(game.data, "Poisoned") end)
    if not anyLeft then
      self:eliminate("The fog took your\nlast POKeMON!", "fog")
    end
  end

  -- ------- spectating (after elimination)
  --
  -- Being out used to mean standing where you fell with nothing to do.  Now
  -- LEFT / RIGHT hop between the trainers still in it, and the view follows
  -- whoever you picked: a camera, not a body (POK-30) -- the spectator's
  -- sprite is hidden and walk-through, the camera pans from it to the
  -- watched trainer, and only a change of map warps it.  Nothing the spectator
  -- does reaches the match: steps are refused (movement.collision below),
  -- encounters and trainers already are, and a hop is a warp, which the
  -- wire never carries.

  local FOLLOW_SECONDS = 2      -- a cross-map catch-up, no more often than this

  -- the trainers still in it, in a stable order so LEFT/RIGHT mean something
  function BR:watchable()
    local ids = {}
    for id, p in pairs(self.players) do
      if p.status ~= "out" and p.map and p.x and p.y then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    return ids
  end

  -- warp beside them, on a cell nobody is standing on
  function BR:warpBeside(p)
    local data = self.game and self.game.data
    if not (data and p and p.map) then return false end
    local cells = Spills.placeAround(p.x, p.y, 1, function(x, y)
      if x == p.x and y == p.y then return false end
      return Spawn.walkable(data.maps, data.tilesets, p.map, x, y)
    end)
    local c = cells[1] or { x = p.x, y = p.y }
    -- face them, so the hop reads as "looking at" rather than "standing by"
    local facing = "down"
    if c.x < p.x then facing = "right" elseif c.x > p.x then facing = "left"
    elseif c.y > p.y then facing = "up" end
    local ok = mod.world:warpTo(p.map, c.x, c.y, facing, { arrive = "teleport" })
    self.lastHopAt = clock()
    return ok
  end

  function BR:hop(dir)
    local ids = self:watchable()
    if #ids == 0 then return false end
    local idx = 0
    for i, id in ipairs(ids) do if id == self.watching then idx = i break end end
    if idx == 0 then
      idx = (dir or 1) > 0 and 1 or #ids
    else
      idx = ((idx - 1 + (dir or 1)) % #ids) + 1
    end
    self.watching = ids[idx]
    self.fellAt = nil              -- a deliberate move, nothing to undo
    self.lastHopAt = nil           -- catch up at once, wherever they are
    self.peeked, self.lastPeekAt = nil, nil   -- and ask them, not the last one
    return true
  end

  -- ------- what they carry (POK-18)
  --
  -- A spectator's START menu opens the watched trainer's team and bag in
  -- place of their own empty ones.  A human is asked (peek) and answers
  -- (state) every few seconds while watched; a bot has no client to ask,
  -- so its team is derived from the seed like everything else about it.

  function BR:answerPeek(fromId)
    local save = self.game and self.game.save
    if not (save and self.relay) then return end
    self.relay:send(fromId, Wire.state(Peek.summary(save, bagOf(save))))
  end

  function BR:tickPeek()
    local id = self.watching
    local p = id and self.players[id]
    if not (p and self.relay) then return end
    if p.bot then
      if not (self.peeked and self.peeked.id == id) then
        local data = self.game and self.game.data
        local bag = self:botBag(id)   -- the TM shows in the peek too (POK-62)
        self.peeked = { id = id, bot = true,
                        party = Peek.botParty(Bots, self.matchSeed, id, data,
                                              self:level(), self:botRecord(id)),
                        items = bag.items, money = bag.money }
      end
      return
    end
    local now = clock() or 0
    if self.lastPeekAt and (now - self.lastPeekAt) < Peek.SECONDS then return end
    self.lastPeekAt = now
    self.relay:send(id, Wire.peek())
  end

  local function watchedName()
    local p = BR.watching and BR.players[BR.watching]
    return (p and p.name) or "them"
  end

  function BR:openWatchedParty(game)
    local data = game.data
    local state = self.peeked
    local name = watchedName()
    if not (state and state.id == self.watching) then
      game.stack:push(mod.ui.ListMenu.new(game, name .. "'s TEAM",
        { { label = ("(no word from\n%s yet)"):format(name) } },
        { onChoose = function() end }))
      return
    end
    -- the engine's own Party screen over the synced view (POK-53).
    -- pickOnly + keepOpen make it read-only: A opens the mon's moves on
    -- top of the list, B backs out -- no SWITCH, no STATS, no field moves
    local PartyMenu = require("src.ui.PartyMenu")
    game.stack:push(PartyMenu.new(game, {
      party = Peek.saveView(data, state.party),
      pickOnly = true,
      keepOpen = true,
      pickText = name .. "'s POKeMON.",
      onSwitch = function(mon)
        game.stack:push(mod.ui.ListMenu.new(game,
          (data.pokemon[mon.species] and data.pokemon[mon.species].name) or tostring(mon.species),
          Peek.moveRows(data, mon), { onChoose = function() end }))
      end,
    }))
  end

  function BR:openWatchedBag(game)
    local state = self.peeked
    local name = watchedName()
    if not (state and state.id == self.watching) then
      game.stack:push(mod.ui.ListMenu.new(game, name .. "'s BAG",
        { { label = ("(no word from\n%s yet)"):format(name) } },
        { onChoose = function() end }))
      return
    end
    -- the vanilla floating item box (POK-53), read-only: BagMenu's row
    -- shape through ListMenu's itemBox geometry, and an empty bag prints
    -- the engine's own "Nothing here."
    game.stack:push(mod.ui.ListMenu.new(game, "ITEMS",
      Peek.itemRows(game.data, state.items, state.money),
      { kind = "bag", itemBox = true, onChoose = function() end }))
  end

  -- keep the watched trainer in frame
  function BR:tickWatch()
    if not (self.phase == "match" and self.status == "out" and self.watching) then return end
    local p = self.players[self.watching]
    if not p or p.status == "out" then
      self.watching = nil           -- they fell; the next LEFT/RIGHT picks anew
      return
    end
    local here = mod.world:current()
    -- on their map the camera has them (tickCamera); only another map warps
    if not here or here.mapId == p.map then return end
    local ow = mod.world:overworld()
    if not ow or ow.transitioning or self.game.stack:top() ~= ow then return end
    local now = clock()
    if now and self.lastHopAt and (now - self.lastHopAt) < FOLLOW_SECONDS then return end
    self:warpBeside(p)
  end

  -- A camera, not a body (POK-30).  Other clients stopped drawing us when
  -- we fell (POK-13); now we stop drawing us: the sprite is hidden, the
  -- body is walk-through, and the view is the engine's own follow plus a
  -- pan_camera offset pointing from our invisible body to the watched
  -- trainer -- recomputed every tick off their ghost's pixel position, so
  -- it walks when they walk.  Nobody picked yet means the first living
  -- trainer, so being out never reads as standing in a field alone.
  function BR:tickCamera()
    local ow = mod.world:overworld()
    if not (ow and ow.player) then return end
    if not (self.phase == "match" and self.status == "out") then
      if self.cameraOwned then self:releaseCamera(ow) end
      return
    end
    self.cameraOwned = true
    ow.playerHidden = true          -- the engine clears it on every arrival
    ow.player.passable = true       -- Collision.occupied lets the living through
    if not self.watching then self:hop(1) end
    self:tickPeek()
    local p = self.watching and self.players[self.watching]
    local here = mod.world:current()
    if not (p and here and p.map == here.mapId) or ow.transitioning then
      ow.cameraPan = nil
      return
    end
    -- their ghost's pixels while it is placed (smooth mid-step); the
    -- wire's cell until it is
    local npc = self.ghosts:npcOf(self.watching)
    local tx = npc and npc.px or (p.x * 16)
    local ty = npc and npc.py or (p.y * 16)
    ow.cameraPan = { ox = tx - ow.player.px, oy = ty - ow.player.py }
  end

  function BR:releaseCamera(ow)
    self.cameraOwned = nil
    ow = ow or mod.world:overworld()
    if not ow then return end
    ow.cameraPan = nil
    ow.playerHidden = false
    if ow.player then ow.player.passable = nil end
  end

  -- LEFT / RIGHT while out: a hop, not a turn.  input.step runs before the
  -- engine promotes this tick's presses, so the queue is where they can
  -- still be taken back.
  function BR:spectatorInput(game)
    if not (self.phase == "match" and self.status == "out") then return end
    local input = game and game.input
    local ow = mod.world:overworld()
    if not (input and input.pressQueue and ow and game.stack:top() == ow) then return end
    local queue, kept, hop = input.pressQueue, {}, nil
    for _, btn in ipairs(queue) do
      if btn == "left" then hop = -1
      elseif btn == "right" then hop = 1
      else kept[#kept + 1] = btn end
    end
    if hop then
      input.pressQueue = kept
      input.state.left, input.state.right = false, false
      self:hop(hop)
    end
  end

  -- a spectator does not walk.  They may turn on the spot (harmless, and
  -- refusing it would fight the engine's turn-in-place), but no step of
  -- theirs ever lands.
  mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
    local ow = mod.world:overworld()
    if BR.phase == "match" and BR.status == "out" and ow and ctx
       and ctx.mover == ow.player then
      ctx.reason = "spectating"
      return false
    end
    -- the Safari opening (POK-21): the way out of the zone is the buzzer,
    -- and once it has sounded the gate is shut for the rest of the match
    if ow and ctx and ctx.mover == ow.player and ctx.map then
      local mapId = ctx.map.id
      if BR.phase == "safari" and mapId == SAFARI_MAP then
        for _, w in ipairs(SAFARI_EXIT_WARPS) do
          if ctx.toX == w.x and ctx.toY == w.y then
            ctx.reason = "safari"
            return false
          end
        end
      elseif BR:inRound() and mapId == "SAFARI_ZONE_GATE" and ctx.toY <= 2
             and not (BR.game and BR.game.save and BR.game.save.safari) then
        -- no admission, no north half: the join trigger (y=2) and the
        -- warps back into the zone (y=0) are both behind this line (POK-40)
        ctx.reason = "closed"
        local now = clock() or 0
        if now - (BR.lastClosedSay or -10) > 3 then
          BR.lastClosedSay = now
          if BR.phase == "safari" then
            say("The PA called\ntime on you!\fWait for the\nbuzzer.")
          else
            say("The SAFARI ZONE\nis closed for\nthe match.")
          end
        end
        return false
      elseif (BR.phase == "drop" or BR.phase == "match") and mapId == SAFARI_DOOR.map
             and ctx.toX == SAFARI_DOOR.x and ctx.toY == SAFARI_DOOR.y then
        ctx.reason = "closed"
        local now = clock() or 0
        if now - (BR.lastClosedSay or -10) > 3 then
          BR.lastClosedSay = now
          say("The SAFARI ZONE\nis closed for\nthe match.")
        end
        return false
      elseif BR.phase == "drop" or BR.phase == "match" then
        -- story rooms are locked for the match (POK-51): the rival script
        -- in OAK's LAB starts a real battle and pays EXP off the ladder
        local def = BR.game and BR.game.data and BR.game.data.maps[mapId]
        for _, w in ipairs((def and def.warps) or {}) do
          if ctx.toX == w.x and ctx.toY == w.y and CLOSED_DOORS[w.destMap] then
            ctx.reason = "closed"
            local now = clock() or 0
            if now - (BR.lastClosedSay or -10) > 3 then
              BR.lastClosedSay = now
              say("OAK's LAB is\nclosed for the\nmatch.")
            end
            return false
          end
        end
      end
    end
    return next(allowed, ctx)
  end)

  -- ------- level scaling (DESIGN D12)
  --
  -- The rung is indexed by the fog's phase, so a ring shrink and a power
  -- spike are the same beat rather than two unrelated timers.

  function BR:level()
    return Levels.at(self.ring and self.ring.phase or 1)
  end

  -- Pull one Pokemon up to `target`: real level-ups, the natural level-up
  -- moves, and automatic LEVEL evolutions (stones and trades stay manual,
  -- D12).  Damage carries across as an absolute amount, which is what a
  -- Gen 1 level-up does -- a hurt mon stays hurt rather than being quietly
  -- healed by the clock, and a fainted mon stays fainted rather than being
  -- revived by it (POK-38).
  local function scaleMon(game, mon, target)
    local Pokemon = require("src.pokemon.Pokemon")
    local Stats = require("src.pokemon.Stats")
    local Growth = require("src.pokemon.Growth")
    local Evolution = require("src.pokemon.Evolution")
    local def = game.data.pokemon[mon.species]
    if not def then return false end

    local from = mon.level
    local oldMax, oldHp = (mon.stats and mon.stats.hp or 0), (mon.hp or 0)
    mon.level = target
    Pokemon.learnMovesFromDayCare(game.data, mon, def, from, target)
    mon.stats = Stats.calc(def, target, mon.dvs, mon.statExp)
    mon.hp = Levels.carryHp(oldMax, oldHp, mon.stats.hp)
    local okExp, exp = pcall(Growth.expForLevel, def.growthRate, target,
                             game.data.growthRates)
    if okExp and exp then mon.exp = exp end

    -- an evolution can itself qualify for the next one (a level 50 jump can
    -- take a CATERPIE the whole way), so run it to a fixed point
    for _ = 1, 4 do
      local evo = Evolution.pendingLevelEvo(game.data, mon)
      if not evo then break end
      Evolution.apply(game, mon, evo, "LEVEL")
      local newDef = game.data.pokemon[mon.species]
      if newDef then
        Pokemon.learnMovesFromDayCare(game.data, mon, newDef, from, target)
      end
    end
    return true
  end

  -- Runs on a slow tick rather than only on the shrink, so a Pokemon caught
  -- mid-phase snaps up to the rung too (D12: a late catch stays relevant).
  -- Deliver the says nothing may swallow -- oldest first, one per tick,
  -- and only when the runner actually takes it (POK-49/POK-50).
  function BR:tickSays()
    local q = self.pendingSays
    if not (q and q[1]) then return end
    local now = clock()
    if not now or now < q[1].at then return end
    -- Never onto a screen that is not the overworld (POK-155).  queueScript
    -- refuses only while the runner is RUNNING; under anything else on the
    -- stack the runner is idle, so a say queued there is ACCEPTED and then
    -- pushed somewhere StateStack:update never reaches
    -- (src/core/StateStack.lua:60).  That is what the win banner did for
    -- the two and a half seconds between onWinner's sayLater and
    -- closeOverBattle's grace.
    --
    -- A battle was only the first screen it was found under, and gating on
    -- liveLocalBattle alone would leave the rest of the class open: a say
    -- due while Transition.battleReturn is on top (pushed by
    -- BattleState:finish, src/battle/BattleState.lua:5327) freezes and
    -- resurfaces later, and one due during the parade freezes and is then
    -- dropped by resetMatch.  So the gate is the same predicate the parade
    -- and the exit ask, which covers all three.
    --
    -- A queue can wait: it lands on the overworld whatever is on top
    -- returns to -- or, if the match ends first, resetMatch drops it, which
    -- is the right answer for a say about a match that is over.
    if not self:screenIsQuiet() then return end
    if BRMenu.say(mod, q[1].text) then table.remove(q, 1) end
  end

  -- An online match never waits on a read (POK-54).  Any dialog left open
  -- five continuous seconds gets pressed through -- one A a second until
  -- the runner is quiet.  Plain-text says are the common case; the rare
  -- prompt resolves to its default rather than holding the match hostage.
  function BR:tickAutoResolve(game)
    if not self.matchWorld then
      self.runnerBusySince = nil
      self.linkWaitSince = nil
      return
    end
    local now = clock()
    -- A link battle's text waits auto-advance too (POK-65): the intro and
    -- turn messages cannot be parked on forever, so a silent player always
    -- drifts to the move menu, where the shot clock (POK-59) takes over.
    -- The menu and the wait-for-remote phases are exempt -- this never
    -- picks a move -- and the party/bag screens sit above the battle on
    -- the stack, so top == battle rules them out on its own.
    local lb = self.localBattle
    local top = game and game.stack and game.stack:top()
    if now and lb and lb.kind == "link" and top == lb
       and lb.phase ~= "menu" and lb.phase ~= "waitBoth"
       and lb.phase ~= "waitRemote" then
      self.linkWaitSince = self.linkWaitSince or now
      if (now - self.linkWaitSince) >= 5
         and not (self.lastAutoA and (now - self.lastAutoA) < 1) then
        self.lastAutoA = now
        if game.input and game.input.pressQueue then
          -- B, never A (POK-66): B advances text exactly like A, but in
          -- any menu it BACKS OUT instead of choosing -- the watchdog can
          -- keep a stalled duel moving yet can never pick a move.  Full
          -- silence still drifts to the action menu, where the POK-59
          -- clock forfeits it.
          table.insert(game.input.pressQueue, "b")
        end
      end
    else
      self.linkWaitSince = nil
    end
    -- a battle on the stack silences the runner watchdog (POK-66): a
    -- script-started trainer fight keeps the runner busy for the whole
    -- battle, and pressing A into it picks moves nobody chose.  Battle
    -- text paces like vanilla; only the overworld's own dialogs resolve.
    if self.localBattle then self.runnerBusySince = nil return end
    local ow = mod.world:overworld()
    local busy = ow and ow.runner and ow.runner.isRunning and ow.runner:isRunning()
    if not (busy and now) then self.runnerBusySince = nil return end
    self.runnerBusySince = self.runnerBusySince or now
    if (now - self.runnerBusySince) < 5 then return end
    if self.lastAutoA and (now - self.lastAutoA) < 1 then return end
    self.lastAutoA = now
    if game and game.input and game.input.pressQueue then
      table.insert(game.input.pressQueue, "a")
    end
  end

  function BR:tickLevels()
    if not (self.phase == "match" and self.game) then return end
    -- an OUT player's party is a record of the fall, not a combatant --
    -- leave it alone (POK-38)
    if self.status == "out" then return end
    -- NEVER MID-FIGHT (POK-91).  The rung you walked in with is the rung
    -- you fight at: scaleMon replaces mon.stats wholesale and can evolve
    -- the thing on the field, and BattleState's battlers alias those very
    -- party tables (the aliasing the POK-31 fog bite relies on), so a
    -- shrink that lands mid-battle used to take a Lv5 lead to Lv15
    -- between turns.  The ring and the fog still move; only the ladder
    -- waits, and the next tick after the battle closes pays it out.
    --
    -- `status` alone was the old guard and it is not enough: it only says
    -- "battle" for a PvP duel or a bot fight (BR:beginBattle /
    -- BR:startBotFight).  A WILD encounter or one of Kanto's own trainers
    -- leaves it "alive", which is how this shipped.
    if self.status == "battle" or self:liveLocalBattle() then return end
    -- ...and the guard above still left a window (the Discord report of a
    -- party jumping 15 -> 30 against Brock): localBattle is set by
    -- battle.started, which BattleState emits AFTER it is pushed -- the
    -- BattleTransition flash before it is a second or two in which the
    -- rung can land, and the fight then OPENS on freshly-jumped mons.
    -- Sweep the stack for either state instead of trusting the event's
    -- timing; same test startBotBattle applies before opening a fight.
    local BattleTransition = require("src.render.BattleTransition")
    for _, state in ipairs((self.game.stack and self.game.stack.states) or {}) do
      if state.awardExp or getmetatable(state) == BattleTransition then
        return
      end
    end
    local now = clock()
    if not now then return end
    if (now - (self.lastLevelTick or 0)) < 1 then return end
    self.lastLevelTick = now

    local target = self:level()
    local raised, evolved = 0, nil
    for _, mon in ipairs(self.game.save.party or {}) do
      if Levels.needsScaling(mon, target) then
        local was = mon.species
        if scaleMon(self.game, mon, target) then
          raised = raised + 1
          if mon.species ~= was then evolved = mon.species end
        end
      end
    end
    if raised > 0 and self.announcedLevel ~= target then
      self.announcedLevel = target
      -- The rung itself is announced by the ring that caused it, in the
      -- one message that also covers the rod (see applyRing).  An
      -- evolution is the part of that beat the ring cannot carry -- it is
      -- per-player and not known until the party is actually scaled --
      -- and it is rare enough to be news rather than noise.
      if evolved then sayLater("One of your\nPOKeMON evolved!") end
    end
  end

  -- One way out of a match, however it happened: a battle whiteout, or the
  -- fog finishing the job outside one.
  -- `cause` is for the log, not the player: the message on screen says
  -- it in Gen 1 English, this says it in one greppable word (POK-86).
  function BR:eliminate(message, cause)
    -- The champion cannot be eliminated by their own win (POK-155).  Closing
    -- a fight out at "over" pops it as a "run", not a loss, so nothing
    -- should arrive here -- but the fog, a late blackout, or any future
    -- widening of the guard below to inSession() (as the speedOverride
    -- take-back and the START-menu guard both correctly do) would white out
    -- the trainer who just won: the engine's blackout heals the party,
    -- halves the money and warps them to a POKeMON CENTER, and with fellAt
    -- nil and status "alive" the spectator return-warp never fires.  This
    -- protection currently rests on "over" not being in inRound(), which is
    -- an accident anyone could tidy away.  Now it is a decision.
    if self.phase == "over" then return end
    if self.status == "out" or not self:inRound() then return end
    self.status = "out"
    -- Out of the match is out of the running for the room: a spectator can
    -- still run the fog and the bots perfectly well, but handing it to
    -- somebody still playing keeps the authority with somebody who has a
    -- reason to stay (POK-116).  If nobody else can, the relay closes the
    -- room exactly as it used to.
    if self.relay then self.relay:canHost(false) end
    log:say("OUT: you (%s), %d left", tostring(cause or "unknown"),
            self:aliveCount())
    -- Where the match ended for us, captured here rather than in any one
    -- caller: a whiteout, a PvP loss and the fog all arrive by different
    -- routes, and only the engine's whiteout then moves us.  The step hook
    -- brings us back if something did.
    local spot = mod.world:current()
    if spot and spot.mapId then
      self.fellAt = { map = spot.mapId, x = spot.x, y = spot.y,
                      facing = spot.facing }
    else
      self.fellAt = nil
      mod.log:warn("eliminated with no readable position; spectating wherever "
                   .. "the engine leaves us")
    end
    local save = self.game and self.game.save
    -- the team hits the ground where you fell (DESIGN D8), so an elimination
    -- is worth converging on rather than only paying whoever landed the hit.
    -- Except before the match proper (the Safari buzzer, POK-46): the zone
    -- closes over anything dropped there, and unreachable loot reads as a
    -- bug, not a bounty.
    if save and self.phase == "match" then self:spillParty() end
    if save then
      save.inventory = {}
      save.bagOrder = nil
      save.money = 0
    end
    if self.relay then self.relay:broadcast(Wire.out()) end
    say(message or "You are out of\nthe match.")
    self:checkWinner()
    broadcastPlace()
  end

  -- ------- the loot spill (DESIGN D8)
  --
  -- Placement is computed by whoever fell and broadcast, because a spill
  -- lands where they happened to be and nobody else can derive that.  Every
  -- client lays out the same balls; the first to open one says so.

  -- Ground truth for a ball's landing cell (POK-75): a walkable tile, NOT a
  -- doorway (POK-94), and nobody standing there -- a ball under an NPC
  -- answers the NPC's talk, not its own.  Occupancy is only checkable on
  -- the loaded map (elsewhere there are no runtime objects); placement is
  -- computed by whoever fell and broadcast (D8), so this one client's view
  -- is authoritative.
  --
  -- The doorway rule is not about looking untidy.  A ball is a solid
  -- runtime object and a warp only fires when you STEP ON it, so a ball on
  -- a mart's door shuts that building for the rest of the match -- for
  -- everyone, since every client lays the spill out the same way.  A
  -- doorway is walkable by design, which is exactly why walkability alone
  -- never caught it.
  local function spillCellFree(data, mapId, x, y)
    if not Spawn.walkable(data.maps, data.tilesets, mapId, x, y) then
      return false
    end
    if Spawn.isWarp(data.maps, mapId, x, y) then return false end
    local ow = mod.world:overworld()
    if ow and ow.map and ow.map.id == mapId and ow.npcs then
      local Collision = require("src.world.Collision")
      if Collision.occupied(ow.npcs, x, y) then return false end
    end
    return true
  end

  function BR:spillParty()
    local game, relay = self.game, self.relay
    local here = game and mod.world:current()
    if not (game and here and relay) then return end
    local data = game.data
    local spill = Spills.build(self.myId or 0, here.mapId, here.x, here.y,
                               game.save.party,
                               function(x, y)
                                 return spillCellFree(data, here.mapId, x, y)
                               end,
                               bagOf(game.save, self:playerName()),
                               function(x, y)
                                 return Spawn.isWarp(data.maps, here.mapId, x, y)
                               end)
    if not spill then return end
    relay:broadcast(Wire.spill(spill.map, spill.mons, spill.bag))
    self.spills:add(spill)
    if #spill.mons > 0 then
      say("Your POKeMON\nscattered!")
    elseif spill.bag then
      say("Your BAG hit\nthe ground!")
    end
  end

  -- Open one: the prompt Oak's lab uses for the starters, take or leave.
  -- It used to start a catch battle against the fallen Pokemon at 1 HP; the
  -- hard part was the battle its owner already lost, and fighting it again
  -- to earn it was ceremony -- and slow, under fog pressure.  A beaten team
  -- is yours if you reach it first.
  --
  -- The ball is claimed for everyone only on YES.  NO -- or backing out of
  -- the drop picker at a full party -- leaves it on the ground for the next
  -- trainer, and a claim that lands while a menu is still open is answered
  -- by the ball being gone.
  function BR:openSpill(key)
    local ball = self.spills:get(key)
    local game = self.game
    if not ball then return nil, "no such ball" end
    if not game then return nil, "no game" end
    local ow = mod.world:overworld()
    if not ow then return nil, "no overworld" end
    if ow.transitioning then return nil, "mid-warp" end
    if ball.bag then return self:openBag(key, ball) end
    local data = game.data
    local def = data.pokemon and data.pokemon[ball.species]
    local name = (def and def.name) or tostring(ball.species)
    local TextBox = require("src.render.TextBox")
    game.stack:push(TextBox.new(game,
      ("This contains a\n%s.\nDo you want it?"):format(name), nil, {
      choice = function(yes)
        if not yes then return end
        if not self.spills:get(key) then
          say("It's gone --\nsomeone was\nquicker.")
          return
        end
        local save = game.save
        if #(save.party or {}) >= 6 then
          -- POK-34: full is not a refusal any more -- you choose who makes
          -- room, and what you release lands here as a ball.  Cancel (or
          -- losing the race while the picker is up) keeps the status quo:
          -- the ball stays right where it is.
          self:offerDropForBall(key, ball, name)
          return
        end
        self:claimSpill(key, ball, name)
      end,
    }))
    return true
  end

  -- A fallen trainer's BAG (POK-25): what it holds, then take or leave.
  -- The take is claimed for everyone like a ball's, and the contents land
  -- in our bag the way the loot message used to put them there.
  function BR:openBag(key, ball)
    local game = self.game
    local data = game.data
    local bag = ball.bag
    local who = bag.name or "Someone"
    local lines = {}
    for _, it in ipairs(bag.items or {}) do
      local def = data.items and data.items[it.id]
      lines[#lines + 1] = ("%s x%d"):format((def and def.name) or it.id, it.n)
    end
    if (bag.money or 0) > 0 then lines[#lines + 1] = ("¥%d"):format(bag.money) end
    if #lines == 0 then lines[1] = "nothing" end
    -- two lines a page, the owner's name on the first
    local pages = { ("%s's BAG:\n%s"):format(who, lines[1]) }
    local i = 2
    while i <= #lines do
      pages[#pages + 1] = lines[i] .. (lines[i + 1] and ("\n" .. lines[i + 1]) or "")
      i = i + 2
    end
    local TextBox = require("src.render.TextBox")
    game.stack:push(TextBox.new(game, table.concat(pages, "\f") .. "\fTake it?", nil, {
      choice = function(yes)
        if not yes then return end
        if not self.spills:get(key) then
          say("It's gone --\nsomeone was\nquicker.")
          return
        end
        self.spills:take(key)
        if self.relay then self.relay:broadcast(Wire.took(key)) end
        local save = game.save
        for _, it in ipairs(bag.items or {}) do
          save.inventory[it.id] = math.min(99, (save.inventory[it.id] or 0) + it.n)
        end
        save.bagOrder = nil -- rebuilt from the inventory on the next PACK open
        save.money = math.min(999999, (save.money or 0) + (bag.money or 0))
        -- straight to using it (POK-73): the moment you loot is the moment
        -- you want the POTION -- offer the PACK without the START round-trip
        game.stack:push(TextBox.new(game,
          ("You took %s's\nBAG!\fOpen the PACK\nnow?"):format(who), nil, {
          choice = function(open)
            if not open then return end
            local BagMenu = require("src.ui.BagMenu")
            game.stack:push(BagMenu.new(game, {}))
          end,
        }))
      end,
    }))
    return true
  end

  -- Take a claimed spill ball: build the mon at 1 HP exactly as it fell,
  -- mark the dex, tell the room.  Shared by the plain take and the
  -- full-party trade (POK-34).
  function BR:claimSpill(key, ball, name)
    local game = self.game
    local save = game.save
    -- claimed now, everywhere
    self.spills:take(key)
    if self.relay then self.relay:broadcast(Wire.took(key)) end
    local Pokemon = require("src.pokemon.Pokemon")
    local Party = require("src.pokemon.Party")
    local BattleState = require("src.battle.BattleState")
    local mon = Pokemon.new(game.data, ball.species, ball.level)
    mon.hp = 1                 -- on its last legs, exactly as it fell
    BattleState.stampOT(save, mon)
    Party.add(save.party, mon)
    local dex = save.pokedex
    if dex then
      dex.seen[ball.species] = true
      dex.owned[ball.species] = true
    end
    say(("%s joined\nyour party!"):format(name))
  end

  -- One mon on the ground, in the spill's own language: the same placement
  -- search, the same wire message, the same claim flow as the balls a
  -- beaten trainer leaves (POK-34).  Trading up leaves a trace anyone can
  -- profit from.
  function BR:spillDropped(mon)
    local game, relay = self.game, self.relay
    local here = game and mod.world:current()
    if not (game and here and here.mapId and mon and mon.species) then return end
    local data = game.data
    local cells = Spills.placeAround(here.x, here.y, 1, function(x, y)
      return Spawn.walkable(data.maps, data.tilesets, here.mapId, x, y)
    end)
    local cell = cells[1] or { x = here.x, y = here.y }
    self.dropSeq = (self.dropSeq or 0) + 1
    local spill = { map = here.mapId, mons = {
      { key = (self.myId or 0) .. ":drop:" .. self.dropSeq,
        x = cell.x, y = cell.y, species = mon.species, level = mon.level or 5 },
    } }
    if relay then relay:broadcast(Wire.spill(spill.map, spill.mons)) end
    self.spills:add(spill)
  end

  -- The full-party trade for a claimed ball: the party screen as a picker
  -- (PartyMenu's pickOnly -- A picks, B keeps what you have).  The pick
  -- re-checks the race, because the ball could change hands while the
  -- picker was up.
  function BR:offerDropForBall(key, ball, ballName)
    local game = self.game
    local save = game.save
    local PartyMenu = require("src.ui.PartyMenu")
    game.stack:push(PartyMenu.new(game, {
      party = save.party,
      pickOnly = true,
      onSwitch = function(dropped)
        if not self.spills:get(key) then
          say("It's gone --\nsomeone was\nquicker.")
          return
        end
        for i, member in ipairs(save.party) do
          if member == dropped then table.remove(save.party, i) break end
        end
        self:spillDropped(dropped)
        self:claimSpill(key, ball, ballName)
      end,
    }))
  end

  -- A gift that lands on a full party (POK-112).
  --
  -- Kanto hands out Pokemon that are ALREADY in a ball -- the Fighting
  -- Dojo's HITMONLEE and HITMONCHAN, the Silph LAPRAS, the Celadon EEVEE,
  -- the revived fossils -- and Commands.give_pokemon puts those in the
  -- party or, failing that, in the BOX.  In a match the PC answers OUT OF
  -- ORDER, so "sent to BOX" is a hole in the floor: the prize is gone the
  -- instant it is won and nobody can ever reach it again.
  --
  -- A ball on the ground is a ball on the ground, so a gift gets the same
  -- rule as a catch and as a spilled ball: the party screen as a picker,
  -- and whoever you release lands at your feet for somebody else.  The one
  -- difference from offerDropForBall is that there is no race to re-check
  -- -- a gift is yours alone, and cannot change hands while the picker is
  -- up.  Both outcomes route the released mon through pendingDrop rather
  -- than spilling here, so the ball lands under the tick's guards (on the
  -- map, not mid-warp) exactly as POK-34's does.
  function BR:offerDropForGift(mon, giftName)
    local game = self.game
    local save = game and game.save
    if not (game and save and mon) then return end
    local data = game.data
    local PartyMenu = require("src.ui.PartyMenu")
    local Party = require("src.pokemon.Party")
    game.stack:push(PartyMenu.new(game, {
      party = save.party,
      pickOnly = true,
      onSwitch = function(dropped)
        local ddef = data and data.pokemon and data.pokemon[dropped.species]
        local droppedName = (ddef and ddef.name) or tostring(dropped.species)
        for i, member in ipairs(save.party) do
          if member == dropped then table.remove(save.party, i) break end
        end
        if not Party.add(save.party, mon) then
          -- cannot happen at 5/6, but a prize is never lost to a table
          save.party[#save.party + 1] = mon
        end
        self.pendingDrop = dropped
        say(("%s was\nreleased."):format(droppedName))
      end,
      -- B keeps your six.  The gift still does not evaporate: "released"
      -- means "lands as a ball" everywhere else in here, so it means that
      -- here too and whoever walks past next can have it.
      onCancel = function()
        self.pendingDrop = mon
        say(("%s was\nreleased."):format(giftName))
      end,
    }))
  end

  -- Take back what the box just swallowed.  Boxes are plain arrays and
  -- Boxes.deposit appends, so the gift is the last row of the box the
  -- command named.  Nothing else can be writing to storage while this runs
  -- -- the PC is out of order for the length of a match and a deposit is
  -- the only other way in -- so the last row is the gift.
  function BR:rescueBoxedGift(ctx)
    local game = self.game
    local save = game and game.save
    local boxNum = ctx and ctx.boxNum
    if not (game and save and boxNum and save.boxes) then return end
    local box = save.boxes[boxNum]
    local mon = box and box[#box]
    if not (mon and mon.species) then return end
    table.remove(box, #box)
    local def = game.data and game.data.pokemon and game.data.pokemon[mon.species]
    self:offerDropForGift(mon, (def and def.name) or tostring(mon.species))
  end

  -- The catch picker (POK-34): a 6/6 catch hands you the decision the PC
  -- used to make silently.  Pick a member to release and the catch takes
  -- their slot; B keeps your six and the catch is gone.  The release itself
  -- waits for the overworld -- the pick happens inside the battle screen,
  -- and the ball lands where you stand (pendingDrop, flushed by the tick
  -- below once the stack is back on the map).
  function BR:offerDropForCatch(battle, mon)
    local data = battle.game and battle.game.data
    local def = data and data.pokemon and data.pokemon[mon.species]
    local caughtName = (def and def.name) or tostring(mon.species)
    battle:uiNext(function()
      return battle:buildScreen("PartyMenu", {
        battle = battle,
        party = battle:playerPartyView(),
        pickOnly = true,
        onSwitch = function(dropped)
          local save = battle.game.save
          local ddef = data and data.pokemon and data.pokemon[dropped.species]
          local droppedName = (ddef and ddef.name) or tostring(dropped.species)
          for i, member in ipairs(save.party) do
            if member == dropped then table.remove(save.party, i) break end
          end
          if not require("src.pokemon.Party").add(save.party, mon) then
            -- cannot happen at 5/6, but a catch is never lost to a table
            save.party[#save.party + 1] = mon
          end
          self.pendingDrop = dropped
          battle:sayNext(("%s was\nreleased."):format(droppedName))
        end,
        onCancel = function()
          battle:sayNext(("%s was\nreleased."):format(caughtName))
        end,
      })
    end)
  end

  -- ------- bots roaming, and bots fighting each other
  --
  -- A bot that can only pace its spawn map never meets anybody: with thirty
  -- of them across thirty-four maps they would each die alone to the fog.
  -- Walking a connection is the same move a player makes at a route seam,
  -- so it costs nothing in fiction and it is what makes the roster interact.

  -- Resolve one meeting per tick, host-side and abstractly.  There is no
  -- lockstep to run because neither side is a client, and nobody is owed a
  -- battle screen for a fight they are not in -- a player watching the map
  -- sees one trainer walk off and the other's team hit the ground, which is
  -- what a fight between two strangers looks like from across a route.
  function BR:tickBotFights()
    if not (self.relay and self.relay:isHost() and self.phase == "match") then return end
    local now = clock()
    if not now then return end
    local live = {}
    for id, p in pairs(self.players) do
      -- the bot in OUR battle screen is not free to be jumped (POK-154).
      -- The cooldown is a breather AFTER a fight; a bot that has never
      -- fought owes nobody one.  (`or 0` here made it a clock-since-boot
      -- gate: for the first twelve real seconds of the process no bot
      -- could fight at all, which an accelerated driver sits entirely
      -- inside.)
      if p.bot and p.status == "alive" and p.map and id ~= self.botFight
         and (not p.lastFight
              or (now - p.lastFight) >= Bots.FIGHT_COOLDOWN) then
        live[#live + 1] = { id = id, p = p }
      end
    end
    table.sort(live, function(a, b) return a.id < b.id end)
    for i = 1, #live do
      for j = i + 1, #live do
        local a, b = live[i], live[j]
        if Bots.near(a.p, b.p) then
          a.p.lastFight, b.p.lastFight = now, now
          -- The RECORDS fight (POK-158 M3), not a coin: base-stat power
          -- times what each team has left, an upset still possible, and
          -- the winner walks away hurt.  The loser's record is what the
          -- spill puts on the ground; the winner's scars ride a botrec so
          -- every client carries them into its next fight.
          local w = Bots.resolveFight(self:botRecord(a.id), self:botRecord(b.id),
                                      self.game and self.game.data,
                                      function() return love.math.random() end)
          local winner = (w == "a") and a or b
          local loser = (w == "a") and b or a
          self:eliminateBot(loser.id, loser.p, winner.p.name)
          local wrec = self:botRecord(winner.id)
          local drank = Bots.quaff(wrec, wrec.bag)
          if drank then
            log:say("POTION: %s used its %s", tostring(winner.p.name),
                    tostring(drank))
          end
          if self.relay then
            self.relay:broadcast(Wire.botrec(winner.id, wrec))
          end
          return
        end
      end
    end
  end

  -- A bot is out: its team spills where it fell, exactly as a player's does.
  function BR:eliminateBot(id, p, killerName)
    p.status = "out"
    if self.relay then self.relay:broadcast(Wire.botout(id)) end
    self.ghosts:despawn(id)
    self:spillBot(id, p)
    -- The fog has no killer, and this line used to be inside
    -- `if killerName` -- so the one event POK-72 is about, a wave of
    -- bots going down together, left no trace in the log at all.
    log:say("OUT: %s (%s), %d left", tostring(p.name),
            killerName and ("beaten by " .. tostring(killerName)) or "fog",
            self:aliveCount())
    self:checkWinner()
  end

  -- A bot's bag: what its RECORD is actually carrying by now (POK-158),
  -- the same answer for the spill on the ground and the spectator's peek.
  -- A copy, so the spill/peek plumbing (which decorates the table) never
  -- writes into the record.
  function BR:botBag(id)
    local bag = self:botRecord(id).bag or { items = {}, money = 0 }
    local items = {}
    for _, it in ipairs(bag.items or {}) do
      items[#items + 1] = { id = it.id, n = it.n }
    end
    return { items = items, money = bag.money or 0 }
  end

  -- A bot's loot: its team as balls and its authored bag (botBag -- a
  -- bot carries no real one) where it stood, whoever put it down: the fog,
  -- another bot, or a player, who now finds it on the ground beside them
  -- rather than in their pocket (POK-25).
  function BR:spillBot(id, p)
    local data = self.game and self.game.data
    if not (data and p and p.map and p.x and p.y) then return end
    -- the team it actually built (POK-158), fainted included -- what hits
    -- the ground is the record, not a synth
    local party = Bots.spillRows(self:botRecord(id), self:level())
    local bag = self:botBag(id)
    bag.name = p.name
    -- A surfing bot can die ON the water (the fog mid-crossing), and the
    -- BAG hard-lands on the faller's own cell -- loot only a swimmer
    -- could ever reach.  It washes ashore instead: the nearest land cell,
    -- scanned outward, so the spill lands where anybody can walk to it.
    local sx, sy = p.x, p.y
    if Spawn.swimmable(data.maps, data.tilesets, p.map, sx, sy) then
      local found
      for r = 1, 12 do
        for dy = -r, r do
          for dx = -r, r do
            if math.abs(dx) + math.abs(dy) == r
               and canWalk(p.map, p.x + dx, p.y + dy) then
              found = { x = p.x + dx, y = p.y + dy }
              break
            end
          end
          if found then break end
        end
        if found then break end
      end
      if found then sx, sy = found.x, found.y end
    end
    local spill = Spills.build(id, p.map, sx, sy, party, function(x, y)
      return spillCellFree(data, p.map, x, y)
    end, bag, function(x, y) return Spawn.isWarp(data.maps, p.map, x, y) end)
    if spill and self.relay then
      self.relay:broadcast(Wire.spill(spill.map, spill.mons, spill.bag))
      self.spills:add(spill)
    end
  end

  -- Taught ahead of time (POK-158 M4).  A bot's bag has carried a seeded
  -- TM since POK-62; now the moves inside actually reach its mons: at
  -- fight build, each TM in the bag is offered to the first compatible
  -- mon (the species' own tmhm list), whose default moveset gets its
  -- oldest move swapped for it.  BattleState honours a party slot's
  -- `moves` list, so this rides the engine's own seam.  The TM stays in
  -- the bag for the winner -- the teaching happened "before the match",
  -- and eating it would starve the TM economy POK-62 built.  Two teaches
  -- at most: a team that is nothing but machine moves reads as a hack,
  -- not an ace.
  function BR:teachBotMoves(rows)
    local data = self.game and self.game.data
    local rec = self.botFight and self:botRecord(self.botFight)
    local bag = rec and rec.bag
    if not (data and bag) then return end
    local Pokemon = require("src.pokemon.Pokemon")
    local taught = 0
    for _, it in ipairs(bag.items or {}) do
      if taught >= 2 then break end
      local moveId = Bots.tmMove(it.id)
      if moveId and data.moves and data.moves[moveId] then
        for _, row in ipairs(rows) do
          if not row.moves
             and Bots.canLearn(data.pokemon and data.pokemon[row.species], moveId) then
            local okM, built = pcall(Pokemon.new, data, row.species, row.level)
            local ids, dup = {}, false
            for _, mv in ipairs((okM and built and built.moves) or {}) do
              local mid = type(mv) == "table" and mv.id or mv
              ids[#ids + 1] = mid
              if mid == moveId then dup = true end
            end
            if not dup and #ids > 0 then
              if #ids >= 4 then ids[1] = moveId else ids[#ids + 1] = moveId end
              row.moves = ids
              taught = taught + 1
            end
            break -- one attempt per TM: taught, or it already knew it
          end
        end
      end
    end
  end

  function BR:startBotBattle(botId)
    -- POK-145: asked HERE, at the moment the fight opens, and not at the
    -- moment the walk-up that leads to it was armed.
    if not self:canOpenBattle() then return end
    local bot = self.players[botId]
    local game = self.game
    if not (bot and bot.status == "alive" and game) then return end
    local ow = mod.world:overworld()
    if not ow or ow.transitioning then return end
    -- the same guards WorldAPI:startWildBattle applies before stacking a
    -- battle: never a second one, never mid-warp, never with a dead party
    local BattleTransition = require("src.render.BattleTransition")
    for _, state in ipairs(game.stack and game.stack.states or {}) do
      if state.awardExp or getmetatable(state) == BattleTransition then return end
    end
    local Party = require("src.pokemon.Party")
    if not Party.firstHealthy(game.save.party or {}) then return end

    self.status = "battle"
    self.botFight = botId
    self.botFightAt = clock()
    -- Where the fight is happening, kept for the spill (POK-154).  On the
    -- host the roam exclusion above freezes the bot anyway, but a non-host
    -- client keeps receiving the host's steps for it, so by battle.ended
    -- bot.map/x/y can be a seam away from where anybody fought.
    self.botFightPos = { map = bot.map, x = bot.x, y = bot.y }
    self.pending = nil
    broadcastPlace()

    -- the party is handed to BattleState through the trainer.party hook
    -- below, which is the engine's own seam for exactly this.  The rows
    -- come from the bot's RECORD (POK-158) -- the team it has actually
    -- built and the wounds it is actually carrying -- not a fresh synth.
    local rec = self:botRecord(botId)
    local rows, idx = Bots.fightRows(rec, self:level())
    if #rows == 0 then
      -- cannot happen short of a desynced record (a wiped team is an
      -- eliminated bot); heal it rather than opening an unwinnable fight
      mod.log:warn("bot %s had no healthy mon; record reset", tostring(botId))
      for _, m in ipairs(rec) do m.hpFrac = 1 end
      rows, idx = Bots.fightRows(rec, self:level())
    end
    self.botParty = rows
    self.botFightIdx = idx
    self:teachBotMoves(rows)
    local look = self.players[botId]
    local class = (look and look.class) or BOT_TRAINER_CLASS
    local ok, battle = pcall(function()
      return require("src.battle.BattleState")
        .newTrainer(game, class, 1)
    end)
    self.botParty = nil
    if not ok or not battle then
      mod.log:warn("couldn't start a bot battle: %s", tostring(battle))
      self.status = "alive"
      self.botFight = nil
      self.botFightPos = nil
      self.botFightIdx = nil
      return
    end
    -- Overlay the bot's own name on the class chassis, the engine's own
    -- rival-name pattern (POK-61).  Every line in BattleState reads
    -- trainer.name live, so this is enough for all of them -- except
    -- introText, which newTrainer BAKES before we get the battle back
    -- (BattleState.lua, "%s wants to fight!").  That is why the fight
    -- opened as the CLASS and only the defeat line said SAM (POK-89): so
    -- swap the baked-in class for the name rather than reformatting the
    -- string, which would drop whatever localisation Strings applied.
    local bp = self.players[botId]
    -- The brain rides the overlay too (POK-160).  TrainerAI.classFor
    -- reads trainer.aiClass before trainer.id, so an ai-tier bot fights
    -- with a cooltrainer's item-and-switch AI whatever face it wears --
    -- the face stopped being the brain in Bots.look the same ticket.
    -- aiUses (wAICount) was already baked from the face's class at
    -- newTrainer time, so it is re-asked once the overlay is on.
    local aiClass = Bots.fightAI(self.matchSeed, botId)
    if bp and (bp.name or aiClass) then
      local was = battle.trainer and battle.trainer.name
      -- ...and an ai-tier bot also PICKS its moves (POK-160 item 3): the
      -- face's own vanilla passes, plus the mod's BR_BOT_MOVES layer on
      -- top.  A ROOKIE keeps whatever move choice its face class shipped
      -- with -- no field, so the chassis answers through __index.
      local aiMods
      if aiClass then
        aiMods = {}
        for _, m in ipairs((battle.trainer and battle.trainer.aiMods) or {}) do
          aiMods[#aiMods + 1] = m
        end
        aiMods[#aiMods + 1] = "BR_BOT_MOVES"
      end
      battle.trainer = setmetatable(
        { name = bp.name, aiClass = aiClass, aiMods = aiMods },
        { __index = battle.trainer })
      if bp.name and was and was ~= bp.name
         and type(battle.introText) == "string" then
        local pattern = was:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        battle.introText = battle.introText:gsub(pattern,
                                                 (bp.name:gsub("%%", "%%%%")), 1)
      end
      -- both were baked from the face's class before the overlay existed
      -- (newTrainer sets aiUses at construction, enemyAIMods at line ~812)
      battle.aiUses = battle:aiUsesFor()
      battle.enemyAIMods = battle.trainer.aiMods
    end
    battle.onFinish = function(result) ow:afterBattle(result, battle) end
    ow:pushBattle(battle)
  end

  -- one battle's worth of party override, for the bot fight we just built
  mod.hooks:wrap("trainer.party", function(next, oppClass, partyIndex, partyDef)
    if BR.botParty then return BR.botParty end
    local party = next(oppClass, partyIndex, partyDef)
    -- Kanto's own trainers keep their vanilla levels, which in a match means
    -- a Lv20 ace against the Lv5 you dropped with -- an unwinnable wall on
    -- whichever route you happened to spawn beside.  They ride the same rung
    -- the fog sets for players and bots, so PvE stays a real fight instead of
    -- a roadblock, and gyms get harder as the ring closes rather than going
    -- stale.
    if BR.phase ~= "match" or type(party) ~= "table" then return party end
    local rung = BR:level()
    -- Leaders included (POK-76): they used to carry a flat +10, which is
    -- the one shape a bonus cannot take on a ladder from 5 to 100 -- see
    -- the note in lib/gyms.lua.  The race for the TM is what makes a gym
    -- a boss, not the levels.
    local scaled = {}
    for i, slot in ipairs(party) do
      if type(slot) == "table" and slot.species then
        local copy = {}
        for k, v in pairs(slot) do copy[k] = v end
        copy.level = math.min(100, rung)
        scaled[i] = copy
      else
        scaled[i] = slot
      end
    end
    return #scaled > 0 and scaled or party
  end)

  -- ------- being out has to mean out
  --
  -- The engine's whiteout heals the party, halves the money and warps you to
  -- a POKeMON CENTER, and world.blacked_out is raised in the MIDDLE of that
  -- -- after the heal, before the warp.  Marking the match over was therefore
  -- not enough on its own: the engine handed the loser a full team and put
  -- them back in the world, which is the exact opposite of party-as-health.

  -- ...and nothing new opens once the match is over (POK-145).  Both hooks
  -- ask inSession() first, so out of a session they stay invisible: a real
  -- playthrough is untouched by the mod being installed.  Inside one they
  -- ask DIFFERENT questions, and the difference is one phase: the Safari.
  -- Its rule is "no trainer fights" (POK-21), not "no wild encounters" --
  -- the two minutes in the zone are where the party comes from -- so the
  -- grass asks canRollWild() and a trainer asks canOpenBattle().  Both
  -- still refuse at "drop", the buzzer's own frame, and at "over".
  mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
    if BR.status == "out" then return nil end
    -- NOT canOpenBattle(): the engine calls encounter.species only on a
    -- non-nil roll (src/world/OverworldController.lua:3867-3871), so a nil
    -- returned here does not hand the zone over to that hook -- it is the
    -- zone's grass switched off, and with it the whole Safari opening.
    if BR:inSession() and not BR:canRollWild() then return nil end
    return next(encDef, ctx)
  end)

  mod.hooks:wrap("trainer.before_battle", function(next, game, context, continue)
    -- Kanto's own trainers are in the match (POK-14) -- but only while
    -- there IS one.  canOpenBattle() here rather than canRollWild(): the
    -- Safari refuses trainers even though it welcomes wild rolls.  There
    -- are no route trainers in the zone to notice, so this is a decision
    -- about what the phase MEANS rather than an observable change.
    if BR.status == "out" or (BR:inSession() and not BR:canOpenBattle()) then
      continue({ cancel = true })
      return true
    end
    return next(game, context, continue)
  end)

  -- ...and the third route, which neither hook above can see: encounter.roll
  -- is raised only by the grass-step roll and trainer.before_battle only by
  -- trainer sight and talk, while a SCRIPT builds its BattleState itself and
  -- pushes it past both.  That one is the script.command wrap, and it is NOT
  -- registered here beside its two siblings: it is armed for the length of a
  -- match and dropped at resetMatch (POK-155), so it lives up beside the
  -- function that drops it.  See armScriptWrap.

  -- ------- the rules of a match
  --
  -- Everything here holds from the drop until the match ends, and nowhere
  -- else: a real playthrough must be untouched by the mod being installed.

  -- "in a match" is from the Safari on: every rule below holds there too
  local function inMatch() return BR:inRound() end

  -- Every battle is at the rung.  Trainer parties already ride it through
  -- trainer.party above; wild encounters did not, so the Safari handed out
  -- Lv22+ against a Lv5 drop and a route's Pidgey stayed Lv3 at the end.
  -- The roll keeps its species and its odds -- only the level is rewritten,
  -- at the same point the spectator guard already sits.
  mod.hooks:wrap("encounter.species", function(next, enc, ctx)
    local rolled = next(enc, ctx)
    if rolled and inMatch() then
      -- The Safari opening drafts from THIS match's zone (POK-118).  The
      -- roll still decides WHETHER something is in the grass -- the zone's
      -- own rate, untouched -- and this decides which of today's species it
      -- turns out to be.  Rolled live rather than from the match seed: what
      -- is in the zone is everyone's business, what walks into your grass
      -- is nobody's, and seeding it would deal every player the same
      -- catches in the same order.
      if BR.phase == "safari" and BR.safariPool then
        rolled.species = Safari.pick(BR.safariPool, function(a, b)
          return love.math.random(a, b)
        end) or rolled.species
      end
      rolled.level = BR:level()
      BR:lendGhostLead()
    end
    return rolled
  end)

  -- ...and a bite is a wild encounter by another rod.  The chain hands back
  -- the catch ({ species, level }) from the candidate list; the list itself
  -- is not touched, so Old Rod still hooks its MAGIKARP, just at the rung.
  mod.hooks:wrap("encounter.fishing", function(next, rod, mapId, candidates)
    -- Not in the zone (POK-119).  The Safari's whole economy is the step
    -- budget -- 502 steps to find what you can -- and a cast costs none of
    -- them, so a rod at the water's edge would be an unlimited draft that
    -- beat walking every time.  The zone's ponds are scenery for two
    -- minutes; the rod starts working when the match does.
    if BR.phase == "safari" then return nil end
    local catch = next(rod, mapId, candidates)
    if catch and inMatch() then
      catch.level = BR:level()
      BR:lendGhostLead()
    end
    return catch
  end)

  -- SET style, whatever the OPTION row says.  SHIFT's "will you change
  -- POKeMON?" is free information and a free swap, which makes
  -- party-as-health softer than it is meant to be.  The row itself is left
  -- alone: the hook wins without writing to the player's preference.
  mod.hooks:wrap("battle.style", function(next, battle)
    if inMatch() then return "set" end
    return next(battle)
  end)

  -- No level on any screen during a round (RFC 0019).  The rung makes the
  -- number the same for everyone and moves it on a clock, so it reads as a
  -- threat it is not -- a Lv37 opponent looks dangerous to a player who
  -- has not worked out their own team is Lv37 too -- and the one time it
  -- moves visibly (a shrink paying out between fights) it reads as a bug.
  -- All four surfaces at once: levels are simply not a thing in a match.
  -- On an engine without the seam the hook is never called and this wrap
  -- costs nothing, so shipping it ahead of the engine is safe.
  mod.hooks:wrap("pokemon.level_visible", function(next, mon, ctx)
    if inMatch() then return false end
    return next(mon, ctx)
  end)

  -- No EXP from ANY battle during a round (POK-74, widened by POK-139).
  -- The rung is the only power curve: D12 scaling never demotes, so paid
  -- EXP compounds into a party above the fog's beat while every opponent
  -- stays at the rung.  Skipping the award skips the whole payout --
  -- levels, stat exp and the "gained EXP" boxes with it.
  --
  -- This used to exempt WILD battles, on the reasoning that a catch snaps
  -- to the rung anyway and grinding wilds is time the fog does not give
  -- back.  Both of those are still true, and they were the wrong thing to
  -- weigh: the EXP a wild fight pays cannot buy a level the rung has not
  -- already granted, so the ONLY thing it produces is boxes -- one per
  -- surviving party member, after every encounter, while the ring closes.
  -- It was never a reward, only a reading cost.
  --
  -- If a reason to pay wild EXP ever comes back, it needs a reason the
  -- LEVEL LADDER can see; restoring the `kind` test alone would only
  -- restore the text.
  mod.hooks:wrap("battle.exp_award", function(next, ctx)
    if inMatch() then return end
    return next(ctx)
  end)

  -- No nickname prompt on a catch.  A match team is disposable and you may
  -- catch a dozen under fog pressure; the naming grid is friction with
  -- nothing behind it.  false keeps the species name with no prompt.
  mod.hooks:wrap("catch.nickname", function(next, mon, ctx)
    if inMatch() then return false end
    return next(mon, ctx)
  end)

  -- A full party never sends a catch to the box -- there is no box in a
  -- match (POK-36) -- so the decision is the player's: release a team
  -- member for it, or let the catch go (POK-34).  RFC 0018's hook carries
  -- the battle, so the picker opens right here.
  --
  -- There used to be a second path: a shimmed engine raised this from
  -- inside Boxes.deposit with only the mon, so the mod took CUSTODY and
  -- waited for pokemon.caught to supply the battle.  The shim is gone
  -- (POK-29) and with it that whole detour.
  mod.hooks:wrap("catch.party_full", function(next, ctx)
    if not inMatch() then return next(ctx) end
    BR:offerDropForCatch(ctx.battle, ctx.mon)
    return true
  end)

  -- Free move management (POK-19): a MOVES row on the party submenu, in a
  -- round and out of battle.  Any move the species could ever learn --
  -- level-up moves at any level, every compatible TM and HM -- with no
  -- tutor, no item and no ceremony: a list to learn from, and when all four
  -- slots are taken, a list to forget from.  A real playthrough never sees
  -- the row.
  mod.hooks:wrap("ui.party.submenu", function(next, game, items, mon, ctx)
    local out = next(game, items, mon, ctx)
    if not (inMatch() and type(out) == "table" and mon and not (ctx and ctx.battle)) then
      return out
    end
    -- above STATS, where the field moves already sit
    local at = #out + 1
    for i, it in ipairs(out) do
      if it.action == "stats" then at = i break end
    end
    table.insert(out, at, { label = "MOVES",
                            onSelect = function(m, g) BR:openMoves(g, m) end })
    return out
  end)

  function BR:openMoves(game, mon)
    local data = game.data
    local def = data.pokemon[mon.species]
    local name = mon.nickname or (def and def.name) or tostring(mon.species)
    local function tell(text)
      game.stack:push(mod.ui.TextBox.new(game, text))
    end
    -- a TM is spent by teaching; an HM is a tool, not a consumable (POK-58)
    local function spendMachine(row)
      if not row.spend then return end
      local inv = game.save.inventory or {}
      local n = (inv[row.spend] or 0) - 1
      inv[row.spend] = n > 0 and n or nil
      game.save.bagOrder = nil   -- rebuilt from what is left on next open
    end
    local learnable = MoveKit.learnable(data, mon, { bag = game.save.inventory })
    if #learnable == 0 then
      tell(("%s has nothing\nto learn right now."):format(name))
      return
    end
    local items = {}
    for _, m in ipairs(learnable) do
      items[#items + 1] = { label = m.name, right = m.how, value = m.id,
                            spend = (m.how == "TM") and m.item or nil }
    end
    game.stack:push(mod.ui.ListMenu.new(game, "LEARN WHICH?", items, {
      onChoose = function(item, list)
        local moveName = data.moves[item.value].name
        if #(mon.moves or {}) < 4 then
          local _, why = MoveKit.teach(data, mon, item.value)
          if not why then spendMachine(item) end
          list:close()
          tell(("%s learned\n%s!"):format(name, moveName))
          return
        end
        local slots = {}
        for i, mv in ipairs(mon.moves) do
          local md = data.moves[mv.id]
          slots[#slots + 1] = { label = (md and md.name) or mv.id, value = i }
        end
        game.stack:push(mod.ui.ListMenu.new(game, "FORGET WHICH?", slots, {
          onChoose = function(slot, forget)
            local old, why = MoveKit.teach(data, mon, item.value, slot.value)
            if not why then spendMachine(item) end
            forget:close()
            list:close()
            local oldName = (old and data.moves[old] and data.moves[old].name) or tostring(old)
            tell(("%s forgot\n%s!\f%s learned\n%s!"):format(name, oldName, name, moveName))
          end,
        }))
      end,
    }))
  end

  -- 1X, whatever the speed rows say.  A match has a shared clock (the fog),
  -- other people, and a lockstep battle at the end of a walk; fast-forward
  -- through any of it is cheating, and slow-motion in a fight is too.  The
  -- engine asks this hook AFTER its own link-play and --speed overrides, so
  -- a scripted run (POKEPORT_SPEED) still works and the touch skin's hold
  -- button is the one control this cannot reach.
  --
  -- ...and past the last elimination too (POK-144).  The other half of this
  -- defence already used inSession() -- the speedOverride take-back in the
  -- tick -- and its comment claimed to cover "over"; only that half did.
  -- The clamp lifting the frame the winner is named is what made the Hall
  -- of Fame blink past: Game:logicSpeed reads save.options AFTER this hook,
  -- and a player who ever pressed the fast-forward key has speedOverworld
  -- persisted in their global options.lua (Game:_cycleSpeed,
  -- src/core/Game.lua:727).  inMatch() itself is NOT widened: its other
  -- call sites are the rules window and are correctly scoped to the round.
  mod.hooks:wrap("core.logic_speed", function(next, game)
    if BR:inSession() then return 1 end
    return next(game)
  end)

  -- Kanto's own trainers are in the match too (POK-14): beating one leaves
  -- its team on the ground and takes its sprite away, for every client --
  -- balls with no trainer is how you read that somebody got there first,
  -- and a fallen trainer cannot pay out twice.  The engagement is stashed
  -- here because battle.ended only knows the battle, not which map object
  -- started it; a bot battle never comes through engageTrainer, so a set
  -- npcFight is exactly "this was one of Kanto's own".
  mod.events:on("world.trainer_engaged", function(ev)
    if BR.phase ~= "match" or BR.status ~= "alive" or BR.botFight then return end
    local here = mod.world:current()
    local npc = ev and ev.npc
    local obj = npc and npc.def and npc.def.name
    if not (here and npc and obj) then
      BR.npcFight = nil
      return
    end
    BR.npcFight = { map = here.mapId, obj = obj, x = npc.cellX, y = npc.cellY }
  end)

  function BR:npcDefeated(npc, party)
    local data = self.game and self.game.data
    if not data then return end
    local spill = Spills.build("npc:" .. npc.map .. ":" .. npc.obj,
                               npc.map, npc.x, npc.y, party, function(x, y)
      return spillCellFree(data, npc.map, x, y)
    end)
    -- the toggle store is the engine's own "this object is gone" switch; a
    -- reload mid-fade can refuse, and then the sprite lingers until the map
    -- is next entered, which is the acceptable failure
    pcall(function() BR.despawns:hide(BR.game, npc.map, npc.obj) end)
    if self.relay then
      self.relay:broadcast(Wire.npcout(npc.map, npc.obj))
      if spill then self.relay:broadcast(Wire.spill(spill.map, spill.mons)) end
    end
    if spill then self.spills:add(spill) end
  end

  -- Remember the battle the fog may reach into (POK-31).  Only a local
  -- BattleState says battle.started -- LinkBattle never emits it -- and
  -- PvP and bot fights hold tickFog off via status anyway.
  mod.events:on("battle.started", function(ev)
    -- inSession(), not inRound(): a battle that opens at "over" -- a
    -- scripted one, which no phase guard the mod can reach refuses (see the
    -- script.command wrap below) -- was invisible here, so liveLocalBattle
    -- returned nil, closeOverBattle could never close it, screenIsQuiet
    -- blocked until the deadline, and the exit popped the stack out from
    -- under a live BattleState with no finish(): no music restore, no
    -- battle.ended.  Every other reader of localBattle is safe at "over":
    -- the fog is not ticking, and both watchdogs only ever hold OFF while
    -- one is set.
    if BR:inSession() and ev and ev.battle then BR.localBattle = ev.battle end
    -- A bot walks in with the wounds it walked out with (POK-158).  The
    -- engine builds the trainer party at full HP; the record says how much
    -- of each mon is actually left, so clamp before the first turn.  Never
    -- below 1: fightRows only sends healthy mons, and a mon at 1 HP is
    -- exactly what "barely standing" should mean.
    if BR.botFight and ev and ev.battle and ev.battle.enemyParty then
      local rec = BR:botRecord(BR.botFight)
      for k, recI in ipairs(BR.botFightIdx or {}) do
        local mon = ev.battle.enemyParty[k]
        local m = rec[recI]
        if mon and m and (m.hpFrac or 1) < 1 then
          local maxHp = (mon.stats and mon.stats.hp) or mon.maxHp or mon.hp
          if maxHp and maxHp > 0 then
            mon.hp = math.max(1, math.floor(maxHp * m.hpFrac + 0.5))
          end
        end
      end
    end
    -- a PvP lockstep battle: RUN on our side goes through the flee roll
    -- (POK-24); the other side only ever sees a run we actually submitted
    local opponent = BR.battle and BR.battle.opponentId
    if opponent and ev and ev.battle and ev.battle.kind == "link" and BR.game then
      Flee.wrap(ev.battle, {
        save = BR.game.save,
        prior = BR.fledFrom[opponent] or 0,
        onFlee = function() BR.fleeing = opponent end,
      })
    end
  end)


  -- the record keeps count (POK-47)
  mod.events:on("pokemon.caught", function()
    if BR:inRound() and BR.stats then
      BR.stats.catches = BR.stats.catches + 1
    end
  end)

  -- A bot battle is an ordinary engine battle, so its outcome arrives on
  -- battle.ended rather than link.battle_ended.  A loss blacks the player
  -- out, which world.blacked_out below turns into elimination.
  mod.events:on("battle.ended", function(ev)
    BR.localBattle = nil
    BR:reclaimGhostLead()   -- the Safari's stand-in leaves with the screen
    -- A battle that never ran is not a defeat (POK-134).  The engine
    -- refuses a wild battle against an empty party -- BattleState marks it
    -- dead and emits `lose` with `skipped` set, then forces the blackout --
    -- and the SAFARI opening is played with an empty party by design, so
    -- anything that keeps the ghost lead from being lent used to eliminate
    -- the player on the spot, every time they touched a wild mon.
    --
    -- The second clause does not depend on knowing why.  A SAFARI battle
    -- has no player turn at all: the menu is BALL/BAIT/ROCK/RUN and no mon
    -- of yours ever acts (BattleState makeSafari), so a `lose` arriving
    -- from one is the engine's empty-party blackout ("battle finished with
    -- no healthy party; forcing blackout") and never something the player
    -- did.
    --
    -- Keyed on the BATTLE being a Safari one rather than on the phase.
    -- Engagement is gated to phase "match" today, so a bot cannot beat
    -- anyone during the SAFARI and a phase test would be equivalent -- but
    -- it would be equivalent by an invariant held somewhere else, and a
    -- bot defeat quietly not counting is exactly the bug this would become
    -- if that ever moved.
    --
    -- Recorded rather than acted on here: the elimination is raised by the
    -- blackout that follows (world.blacked_out), not by this event, so the
    -- verdict has to survive the gap.  Written on EVERY battle.ended, so
    -- an ordinary battle clears a refusal nobody blacked out for.
    -- ...and ONLY while an empty party is the designed state.  The SAFARI
    -- is entered with nothing and the team is caught during it --
    -- lendGhostLead lends a stand-in precisely because #party == 0 -- so
    -- there the engine's "no usable POKeMON" bail-out means "has not
    -- caught anything yet", and everywhere else it means a real whiteout.
    --
    -- This must not undo the rule it sits next to: catching nothing DOES
    -- cost you the match.  tickDrop eliminates an empty-handed player at
    -- the buzzer ("caught nothing"), and that is the elimination that
    -- counts -- being refused a battle mid-hunt is the only thing excused.
    -- "drop" is in because the buzzer sets it a frame before tickDrop runs,
    -- so a wild mon touched in that gap must not white the player out
    -- before the PA has had its say.
    BR.refusedBattle = (BR:catching() and (ev.skipped
      or (ev.battle and ev.battle.safari and ev.result == "lose"))) and true or nil
    local npc = BR.npcFight
    BR.npcFight = nil
    if npc and BR.phase == "match" and ev.result == "win" and not BR.botFight then
      local party = {}
      for _, mon in ipairs((ev.battle and ev.battle.enemyParty) or {}) do
        if mon.species then
          party[#party + 1] = { species = mon.species, level = mon.level, hp = 0 }
        end
      end
      if #party > 0 then BR:npcDefeated(npc, party) end
      -- a gym leader is a landmark (POK-26): first to fell them takes the
      -- prize, and npcDefeated's npcout closes the gym for everyone
      -- npcFight carries the object's NAME; the class lives in map data
      local prize = Gyms.leaderOfObject(
        BR.game and BR.game.data and BR.game.data.maps, npc.map, npc.obj)
      if prize then
        local psave = BR.game and BR.game.save
        local pdata = BR.game and BR.game.data
        if psave and pdata and pdata.items and pdata.items[prize.tm] then
          psave.inventory[prize.tm] = (psave.inventory[prize.tm] or 0) + 1
          psave.bagOrder = nil
          psave.money = (psave.money or 0) + Gyms.PURSE
          if BR.stats then BR.stats.beats = BR.stats.beats + 1 end
          sayLater(("%s fell!\fThe %s is\nyours, and %d\ncame with it!"):format(
            prize.name, prize.label, Gyms.PURSE))
        end
      end
    end
    local botId = BR.botFight
    if not botId then return end
    local fightPos = BR.botFightPos
    local fightIdx = BR.botFightIdx
    BR.botFight, BR.botFightPos, BR.botFightIdx = nil, nil, nil
    if BR.status == "battle" then BR.status = "alive" end
    if ev.result ~= "win" and not ev.skipped and ev.battle
       and ev.battle.enemyParty then
      -- The fight is over and the bot lived: it keeps its wounds
      -- (POK-158).  Whoever fought it is the one client that knows the
      -- outcome, so this client writes the scars and tells the room --
      -- and the bot reaches for its own bag on the way out, the way a
      -- player patches a lead before walking on.
      local rec = BR:botRecord(botId)
      Bots.scarRecord(rec, fightIdx, ev.battle.enemyParty)
      local drank = Bots.quaff(rec, rec.bag)
      if drank then
        log:say("POTION: %s used its %s", tostring(BR.players[botId]
          and BR.players[botId].name), tostring(drank))
      end
      if BR.relay then BR.relay:broadcast(Wire.botrec(botId, rec)) end
    end
    if ev.result == "win" then
      local bot = BR.players[botId]
      -- `alive` guards the race where the host already put this bot out
      -- while our battle screen was up -- eliminating it twice would spill
      -- its loot twice
      if bot and bot.status == "alive" then
        -- the loot lands where the fight happened, beside the winner, not
        -- wherever the tracked position drifted to mid-battle (POK-154)
        if fightPos then
          bot.map, bot.x, bot.y = fightPos.map, fightPos.x, fightPos.y
        end
        -- eliminateBot, not an inline copy of it: the copy had drifted to
        -- omit the OUT log line, so the one elimination the player caused
        -- was the one the log never showed
        BR:eliminateBot(botId, bot, BR:playerName())
      end
      if BR.stats then BR.stats.beats = BR.stats.beats + 1 end
      say(("You beat %s!"):format((bot and bot.name) or "them"))
    end
    broadcastPlace()
  end)

  function BR:beginBattle(opponentId, isHost, _nonce)
    -- POK-145: the `accept` message handler had no phase check at all, and
    -- onChallenge's own is spent when the challenge ARRIVES, not when the
    -- flash that follows it opens the fight.
    if not self:canOpenBattle() then return end
    local channel = Channel.new(self.relay, opponentId, {
      onClose = function() BR:onBattleClosed(opponentId) end,
    })
    self.battle = { channel = channel, opponentId = opponentId, isHost = isHost }
    self.lastOpponent = opponentId
    self.status = "battle"
    self.pending = nil
    self.ghosts:despawnAll()             -- the world pauses under the battle
    broadcastPlace()                     -- tell everyone I am busy
    local LinkState = require("src.link.LinkState")
    self.game.stack:push(LinkState.newFromSession(self.game, channel,
                                                  "battle", isHost))
  end

  function BR:onBattleClosed(_opponentId)
    -- the channel closed (LinkState:exitWith); the result arrives separately
    -- on link.battle_ended, so here we only drop our handle
    if self.battle then self.battle = nil end
  end

  -- link.battle_ended carries the lockstep party copies, which took the
  -- damage the real save.party never does under cable rules.  Party is
  -- health here, so we copy the damage back and a wiped party is elimination.
  mod.events:on("link.battle_ended", function(ev)
    if not (BR.phase == "match" and BR.game) then return end
    local save = BR.game.save
    -- self.battle is usually already gone here (LinkState closes the channel
    -- on its way out), so lastOpponent is the reliable answer
    local opponent = (BR.battle and BR.battle.opponentId) or BR.lastOpponent
    BR.lastOpponent = nil
    for i, mon in ipairs(save.party) do
      local after = ev.myParty and ev.myParty[i]
      if after and after.species == mon.species then
        mon.hp = math.max(0, math.min(mon.stats.hp, after.hp or mon.hp))
        mon.status = after.status
      end
    end
    -- a flee (POK-24): ours counts against us with this pursuer and locks
    -- us out of restarting it; either way the pair gets a breather
    if opponent then
      local now = clock() or 0
      if BR.fleeing == opponent then
        BR.fledFrom[opponent] = (BR.fledFrom[opponent] or 0) + 1
        BR.fleeLockout[opponent] = now + Flee.LOCKOUT_SECONDS
        BR.fleeGrace[opponent] = now + Flee.GRACE_SECONDS
      elseif ev.result == "draw" then
        BR.fleeGrace[opponent] = now + Flee.GRACE_SECONDS
      end
    end
    BR.fleeing = nil
    -- No "a refused battle is not a defeat" guard here on purpose: a
    -- refusal cannot reach this event.  LinkState builds this payload by
    -- hand -- { result, myParty, theirParty, peerName, role } -- so there
    -- is no `skipped` and no `battle` to read, and a link battle always
    -- has a player battler installed, so it is never the empty-party
    -- refusal in the first place.  POK-134's guard lives on the path that
    -- really carries one: battle.ended sets BR.refusedBattle and
    -- world.blacked_out honours it.
    if ev.result == "lose" then
      -- one elimination path for every way of losing, so a PvP defeat
      -- spills the team -- and the bag, on the ground beside the victor
      -- (POK-25) -- exactly as a whiteout or the fog does
      BR:eliminate("You whited out!\nYou are out of\nthe match.", "whiteout")
    else
      if ev.result == "win" and BR.stats then
        BR.stats.beats = BR.stats.beats + 1
      end
      BR.status = "alive"
    end
    broadcastPlace()
  end)

  -- ------- winner
  --
  -- The host is the authority: when one trainer is left un-eliminated it
  -- names them.  Everyone (host included) reacts to the winner message.

  function BR:aliveCount()
    local n = (self.status ~= "out") and 1 or 0
    for _, p in pairs(self.players) do
      if p.status ~= "out" then n = n + 1 end
    end
    return n
  end

  function BR:checkWinner()
    if not (self.relay and self.relay:isHost() and self:inRound()) then return end
    -- survivors among everyone still in the room
    local survivors = {}
    if self.status ~= "out" then survivors[#survivors + 1] = self.myId end
    for id, p in pairs(self.players) do
      if p.status ~= "out" then survivors[#survivors + 1] = id end
    end
    if #survivors == 1 then
      self.relay:broadcast(Wire.winner(survivors[1]))
      self:onWinner(survivors[1])
    elseif #survivors == 0 then
      self.relay:broadcast(Wire.winner(nil))
      self:onWinner(nil)
    end
  end

  -- the numbers of the run, for the record card (POK-47)
  function BR:matchStats()
    local st = self.stats or {}
    local now = clock() or 0
    return {
      catches = st.catches or 0,
      beats = st.beats or 0,
      steps = st.steps or 0,
      rings = (self.ring and self.ring.phase) or 1,
      seconds = math.max(0, math.floor(now - (st.startedAt or now))),
      money = (self.game and self.game.save and self.game.save.money) or 0,
    }
  end

  function BR:onWinner(id)
    -- Only a match can be won (POK-144).  "over" is the ordinary refusal --
    -- a second `winner` for the same match -- but the phases UNDER a
    -- session are the half that cost something.  A client whose `start` was
    -- dropped sat in the LOBBY while the room played a whole match around
    -- it, and the `winner` that ended that match was accepted there: phase
    -- "over" from the lobby, and, because a phantom is allocated a spawn
    -- and therefore can be the last one counted alive, recordWin() and a
    -- saveCareer() of a match it never played -- a career win, possibly a
    -- skin unlock, and YOU WIN! on the lobby face fifteen seconds later.
    --
    -- inRound() and not inSession(): "over" has to stay refused, and the
    -- legitimate transition is always FROM a round, on the host through
    -- checkWinner (itself gated on inRound) and on everyone else through
    -- the wire.  A spectator is inside it -- eliminate leaves the phase
    -- alone and only moves status -- so the watching half of the room still
    -- sees the ending.
    if not self:inRound() then return end
    self:setPhase("over", "a winner")
    self.winnerId = id
    self.ghosts:despawnAll()
    self.pendingDrop = nil   -- the match ended before the release could land
    self.pendingGift = nil   -- ...and before the boxed gift could be handed back
    self.buzzed, self.pickingTown = nil, nil
    -- via sayLater: the fog line that ended the match is usually still on
    -- screen, and the runner would refuse -- and silently drop -- the
    -- banner said directly (POK-49)
    log:say("WINNER: %s", id == self.myId and "you"
            or (id and tostring((self.players[id] or {}).name or id) or "nobody"))
    if id == self.myId then
      sayLater("You are the last\ntrainer standing!\nYou win!", 0.5)
      self:recordWin()
      -- and the Champion gets the Champion's ending (POK-47)
      self.pendingParade = (clock() or 0) + 2.5
      -- ...which the rest of the room watches too (POK-107).  An ending
      -- only the winner sees is the one moment in the match that has
      -- nothing to say to the people it just happened to.
      if self.relay then
        local party = (self.game and self.game.save and self.game.save.party) or {}
        self.relay:broadcast(Wire.fame(party, self:matchStats()))
      end
    elseif id then
      -- prefer the roster name: the relay has never heard of a bot (POK-41)
      local p = self.players and self.players[id]
      sayLater(((p and p.name) or self.relay:nameOf(id)) .. " wins\nthe match!", 0.5)
    else
      sayLater("The match is\nover.", 0.5)
    end
    -- ...and the match ENDS for everybody, parade or no parade (POK-144).
    -- Only the local winner ever armed pendingParade above, and everyone
    -- else waited on a `fame` the champion sends -- so a bot winning, a
    -- match nobody won, and a champion who never got to parade all left the
    -- whole room standing in a world nothing tore down.  The tick defers to
    -- a parade while one is armed or running, so this does not race it.
    self:armEnding(id == self.myId and "you won"
                   or (id and "another trainer won" or "nobody won"))
  end

  -- ------- outbound: local movement -> wire
  --
  -- movement.speed fires inside Player:tryMove the moment a step commits,
  -- after targetX/targetY are set and before the walk animates -- the
  -- earliest honest point to tell everyone "I am stepping there".

  mod.hooks:wrap("movement.speed", function(next, frames, ctx)
    local player = ctx and ctx.player
    if player and player.targetX and BR.stats and BR:inRound() then
      BR.stats.steps = BR.stats.steps + 1   -- the record keeps count (POK-47)
    end
    if player and player.targetX and BR.relay and BR.relay:isOpen()
       and BR.status ~= "battle" then
      local h = here()
      local map = h and h.mapId
      BR.relay:broadcast(Wire.step(player.facing, player.targetX,
                                   player.targetY, map))
      BR.sentFacing, BR.sentMap = player.facing, map
    end
    return next(frames, ctx)
  end)

  -- ------- the tick

  local function brInputTick(game, dt)
    BR.game = game
    local relay = BR.relay
    if relay then
      relay:update()
      relay = BR.relay -- update() may have closed and reset it
    end

    -- A held or toggled fast-forward would outrun the shared clock and
    -- everyone racing it, so it is taken back the frame it lands -- and,
    -- because this covers "over" too, a press that arrives late cannot
    -- surface on the win screen either (POK-83).
    if BR.baseSpeed ~= nil and BR:inSession() then
      local want = BR.baseSpeed or nil
      if game.speedOverride ~= want then
        game.speedOverride = want
        game.skinSpeedSaved = nil
      end
    end

    -- a bot walking over to fight you, one step per beat (POK-85)
    BR:tickWalkUp()

    -- the quick-play countdown: a lobby that starts itself
    if relay and relay:isOpen() and BR.phase == "lobby"
       and BR.autoStartAt and relay:isHost()
       and love.timer.getTime() >= BR.autoStartAt then
      BR.autoStartAt = nil
      BR:startMatch()
    end

    -- Spectating happens where you fell, not in a POKeMON CENTER two towns
    -- away.
    --
    -- Racing the engine's whiteout warp does not work and looks terrible:
    -- retrying until the position stuck meant a fade to the CENTER, a fade
    -- back, and the player spinning on the spot for as long as the two warps
    -- fought.  So this does not race it at all -- it WAITS to be moved, then
    -- moves back exactly once.  If nothing ever moves us (the fog, a PvP
    -- loss) there is nothing to undo and this never fires.
    if BR.fellAt and BR.status == "out" then
      local target = BR.fellAt
      local here = mod.world:current()
      local now = clock() or 0
      target.giveUpAt = target.giveUpAt or (now + 20)
      if here and here.mapId then
        local moved = here.mapId ~= target.map
          or here.x ~= target.x or here.y ~= target.y
        if moved then
          BR.fellAt = nil       -- one attempt, after the engine has had its turn
          local ok, err = mod.world:warpTo(target.map, target.x, target.y,
                                           target.facing)
          if not ok then
            mod.log:warn("could not return the spectator to %s (%s)",
                         tostring(target.map), tostring(err))
          end
        elseif now > target.giveUpAt then
          BR.fellAt = nil       -- never moved: we are already where we fell
        end
      end
    end

    -- Pending says deliver in every live phase -- the OVER banner included.
    --
    -- ABOVE THE EXIT BLOCK ON PURPOSE (POK-144), and that ordering is the
    -- only reason the win banner survives at all: resetMatch clears
    -- pendingSays, so the exit deletes anything still queued when it runs.
    -- Delivered here first, the banner puts the script runner to work,
    -- which makes screenIsQuiet() false, which is what defers the exit
    -- below until the player has read it.  Move this call under that block
    -- and the banner is silently dropped on the frame the match ends.
    if BR.phase ~= "off" then BR:tickSays() end
    if BR.phase ~= "off" then
      BR.despawns:drain(BR.game, mod.world:overworld(), BR:screenIsQuiet())
    end
    -- the Champion's parade starts once the screen is quiet (POK-47)
    if BR.pendingParade and BR.phase == "over" then
      local nowP = clock()
      if nowP and nowP >= BR.pendingParade and BR:screenIsQuiet() then
        BR.pendingParade = nil
        -- the winner parades their own save; everyone else parades what
        -- the winner sent, so the room watches one ending (POK-107)
        local fame = BR.pendingFame
        BR.pendingFame = nil
        -- the STATE, not a flag: the exit below has to be able to ask
        -- whether this parade is still on the stack, and a boolean cannot
        -- tell "running" from "was running once"
        local parade = Fame.new(game,
                                (fame and fame.party) or game.save.party or {},
                                (fame and fame.stats) or BR:matchStats(),
                                function()
                                  BR.parading = nil
                                  BR:endRun()
                                end)
        BR.parading = parade
        game.stack:push(parade)
      end
    end
    -- POK-144: every way a match can end reaches the lobby.  POK-155: a
    -- fight still on screen when it ended is over too, and is closed out
    -- here rather than waited on -- the parade's gate can never pass while
    -- a battle owns the top of the stack.
    --
    -- BELOW tickSays, and deliberately: the exit this block takes runs
    -- resetMatch, which clears pendingSays, so a banner queued but not yet
    -- delivered would go out with it.  See the note on the tickSays call
    -- above -- both ends of that ordering are documented because either one
    -- alone reads like a free choice.
    if BR.pendingEnd and BR.phase == "over" then
      local nowE = clock() or 0
      BR:closeOverBattle()
      -- The deadline is a REAL backstop, not a clock that is pushed forever
      -- (which is what "a parade that wedges still lands somewhere" used to
      -- say while doing the opposite -- every frame reset it, so it could
      -- never expire on the one route it exists for).  Three states:
      --
      --   a parade ON SCREEN owns the exit and endRun takes it when the last
      --   page closes, so both clocks are pushed and nothing is ever yanked
      --   out from under a player still reading the MATCH RECORD card (which
      --   waits for A forever, lib/fame.lua, and tickAutoResolve's watchdog
      --   cannot press it -- that is gated on the script runner, and the
      --   runner is idle under Fame);
      --
      --   a parade ARMED but not yet started holds the exit off -- the grace
      --   moves, the deadline does not -- because pendingParade is set 2.5s
      --   ahead and a late `fame` can land after the four-second grace, and
      --   a guest must not lose the ending by two tenths of a second;
      --
      --   anything else runs both clocks down.  `parading` set with no Fame
      --   on the stack is the wedge itself, and this is the only thing that
      --   can land it.
      local expired = nowE >= BR.pendingEnd.deadline
      if not expired then
        if BR.parading and game.stack:top() == BR.parading then
          BR.pendingEnd.earliest = nowE + END_GRACE_SECONDS
          BR.pendingEnd.deadline = nowE + END_DEADLINE_SECONDS
        elseif BR.pendingParade or BR.pendingFame then
          BR.pendingEnd.earliest = nowE + END_GRACE_SECONDS
        end
      end
      if expired
         or (nowE >= BR.pendingEnd.earliest and BR:screenIsQuiet()) then
        local why = BR.pendingEnd.why
        -- cleared BEFORE the exit so endMatch's own teardown cannot see a
        -- stale arm -- and put back when the exit did not happen, because
        -- one shot at a teardown is not a funnel
        BR.pendingEnd = nil
        if not BR:endMatch(why) and BR.phase == "over" then
          BR:armEnding(why)
        end
      end
    end
    -- and neither they nor the engine's own lines may hold the match:
    -- five silent seconds presses any dialog through (POK-54)
    BR:tickAutoResolve(game)

    if relay and relay:isOpen() and BR:inRound() then
      -- The mark goes out ABOVE the position block (POK-113), not inside
      -- it: everything below is skipped while status is "battle", which is
      -- precisely the state the room most needs told about.
      broadcastBusy()
      local h = here()
      if h then
        if BR.status ~= "battle" then
          if h.facing ~= BR.sentFacing then
            BR.sentFacing = h.facing
            relay:broadcast(Wire.face(h.facing, h.mapId))
          end
          if h.mapId ~= BR.sentMap then broadcastPlace() end
          BR.resync = BR.resync + 1
          if BR.resync >= RESYNC_TICKS then
            BR.resync = 0
            broadcastPlace()
            -- re-state the mark on the same beat as the position, so a peer
            -- that missed the edge is not left holding a stale one (POK-113)
            BR.sentBusy = false
          end
          BR.ghosts:sync(game, h.mapId, BR.players)
          -- Our screen paused; the match did not (POK-98).  While anything
          -- sits above the overworld -- the START menu, a dialog, a wild
          -- battle -- StateStack:update never reaches OverworldState, so
          -- the ghosts' walk animation stalls and every step the wire
          -- delivers piles up until it resolves as a teleport.  Advance
          -- them here instead, and ONLY here: when the overworld is on top
          -- its own update already does it, and doing both walks them at
          -- twice speed.
          if game.stack:top() ~= mod.world:overworld() then
            BR.ghosts:advance(h.mapId)
          end
          BR.spills:sync(h.mapId)
          -- nobody fights in the Safari (POK-21), nor at the gate on the
          -- way out of it
          if BR.phase == "match" then
            BR:tryEngage()
            BR:tryBotEngage()
          end
        end
      end
      -- the Safari opening: its clock, the buzzer's patience running out
      -- on any battle still open (POK-92), then the buzzer's work
      BR:tickSafari()
      BR:closeBuzzedBattle()
      BR:tickDrop()
      -- bots keep walking while we are in a battle or a menu: their world
      -- does not pause because ours did
      BR:tickBots()
      if BR.phase == "match" then
        BR:tickBotFights()
        BR:tickRing()
        BR:tickBotFog()
        BR:tickNpcFog()
        -- tickFog owns its own battle rules: PvP always holds it off
        -- (biting outside the lockstep is a desync; both players sit in
        -- the same fog anyway), and a bot fight only holds it thirty
        -- seconds (POK-63) before the POK-31 in-battle bite resumes.
        -- Levels own theirs too, and they are stricter: no battle of any
        -- kind is levelled through (POK-91).
        BR:tickFog()
        BR:tickLevels()
        BR:spectatorInput(game)
        BR:tickWatch()
      end
    end

    -- A released team member (POK-34) lands where you stand, once you are
    -- standing somewhere: the pick happened inside the battle screen, and
    -- the ball belongs to the overworld's loot language.  The guards are
    -- openSpill's -- on the map, not mid-warp -- so the ball never lands
    -- under a transition.
    if BR.pendingDrop and BR:inRound() then
      local ow = mod.world:overworld()
      if ow and game.stack:top() == ow and not ow.transitioning then
        local mon = BR.pendingDrop
        BR.pendingDrop = nil
        BR:spillDropped(mon)
      end
    end

    -- ...and a gift the party had no room for is pulled straight back out
    -- of the box it was just dropped into (POK-112).  Same guards, and
    -- waiting for the map also waits out the gift's own "sent to BOX" and
    -- "PLAYER got X!" boxes, so the picker opens after the announcement
    -- rather than underneath it.
    if BR.pendingGift and BR:inRound() then
      local ow = mod.world:overworld()
      if ow and game.stack:top() == ow and not ow.transitioning then
        local ctx = BR.pendingGift.ctx
        BR.pendingGift = nil
        BR:rescueBoxedGift(ctx)
      end
    end
    BR:tickCamera()
  end

  -- Everything the mod does per tick sits behind ONE pcall (POK-72): an
  -- error in any subsystem must never eat the ENGINE's input step -- that
  -- is the difference between a logged traceback and a client frozen
  -- solid until force-close.  Logged once per distinct message, so a
  -- per-tick repeat cannot flood the console either.
  mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, err = pcall(brInputTick, game, dt)
    if not ok then
      err = tostring(err)
      if err ~= BR.lastTickError then
        BR.lastTickError = err
        mod.log:warn("battle royale tick failed: %s", err)
      end
    end
    return next(game, dt)
  end)

  -- Party is health, so a whiteout is elimination however it happened -- a
  -- bot trainer, a route trainer, a wild encounter.  (A PvP link battle
  -- never blacks anyone out: cable rules leave the real party untouched,
  -- which is why link.battle_ended handles that case separately.)
  mod.events:on("world.blacked_out", function()
    -- ...unless the battle behind it never ran (POK-134).  The flag is
    -- consumed here rather than merely read: the engine's own blackout has
    -- already healed the party and warped them to the heal point, so the
    -- next one to arrive is a real whiteout and must count.
    local refused = BR.refusedBattle
    BR.refusedBattle = nil
    -- Both halves, checked where it matters: the battle never ran, AND we
    -- are still in the hunt.  The drop is what turns "no party yet" into
    -- "no party left", so a pass carried across it would make an
    -- empty-handed player immune to the elimination tickDrop owes them.
    if refused and BR:catching() then
      log:warn("a battle was refused -- blacked out, but not a loss")
      return
    end
    BR:eliminate("You whited out!\nYou are out of\nthe match.", "whiteout")
  end)

  -- A gift is about to be created (POK-112).  before_give fires ahead of
  -- Party.add, so a party that is full HERE is one this gift cannot fit
  -- into and the command is about to send it to the BOX -- which a match
  -- has locked.  The ctx the command carries is where it records what it
  -- did (ctx.boxNum), so hold on to that and let the tick read the verdict
  -- once the announcement is off the screen.
  --
  -- Note this is the ONLY seam that reaches every giver.  The dojo prize
  -- is a native map script calling Commands.give_pokemon directly, with no
  -- ScriptRunner under it, so script.command never fires for it.
  mod.events:on("pokemon.before_give", function(gift)
    if not (inMatch() and gift and gift.ctx) then return end
    local save = BR.game and BR.game.save
    if not (save and #(save.party or {}) >= 6) then return end
    BR.pendingGift = { ctx = gift.ctx }
  end)

  -- Leaving a map takes our copy of every ghost with it: they are runtime
  -- objects on the map we left, and OverworldState rebuilds its NPC list on
  -- arrival.  sync() re-places them next tick.
  mod.events:on("map.entered", function()
    BR.ghosts:despawnAll()
    BR.spills:despawnAll()
    if BR.relay and BR.relay:isOpen() and BR:inRound() then broadcastPlace() end
  end)

  -- ------- talking to another trainer
  --
  -- A ghost is a runtime object with no TEXT_* id, so the vanilla talk path
  -- has nothing to say.  We answer instead -- but the battle is forced by
  -- walking into someone, so here A just names them (and, if we are already
  -- adjacent and facing, is a second way to start the fight).

  -- ------- Kanto's lockstep walks stand down for a match
  --
  -- Started with Pewter's gym escort (POK-122) and turned out not to be a
  -- one-off: sweeping every vanilla onStep for handlers that take the
  -- player rather than talk at them also turned up CERULEAN's Rocket thief
  -- (POK-126) and, on YELLOW, four JESSIE and JAMES ambushes (POK-127).
  -- The cells and the reasoning for each live in lib/lockstep.lua, kept as
  -- data so br_test can drive the vanilla handlers they are meant to match
  -- and prove the coordinates still line up.
  --
  -- Each has to not fire AT ALL, rather than merely stop after the first
  -- time: a lockstep walk is not a cutscene here, it is a movement lock
  -- while the ring closes and other trainers hunt.  map_scripts composes
  -- onStep first-truthy-consumes with a mod's contribution ahead of base
  -- (src/script/MapScripts.lua), so returning true on a trigger cell means
  -- base never sees the step.  Outside a session every one of them returns
  -- false and vanilla is untouched, which matters: this mod is installed
  -- alongside real playthroughs.
  --
  -- Two of these arm from a conversation as well; that half is in the
  -- world.talk wrap below.
  for mapId in pairs(Lockstep.CELLS) do
    local repair = Lockstep.REPAIRS[mapId]
    mod.content.map_scripts:register(mapId, {
      onStep = function(_, _, x, y)
        if not BR:inSession() then return false end
        return Lockstep.blocks(mapId, x, y)
      end,
      -- ...and put back whatever the scene we suppressed was also doing
      -- (lib/lockstep.lua REPAIRS).  onEnter composes all-run and fires on
      -- every entry rather than only the first, so a player who reaches
      -- CERULEAN by any route gets the same city.  Writes to the match's
      -- throwaway save, never the player's.
      onEnter = repair and function(game, ow)
        if not BR:inSession() then return end
        local Commands = require("src.script.Commands")
        local ctx = { game = game, save = game.save, overworld = ow }
        for _, name in ipairs(repair.show or {}) do
          Commands.show_object(ctx, mapId, name)
        end
        for _, name in ipairs(repair.hide or {}) do
          Commands.hide_object(ctx, mapId, name)
        end
        log:say("lockstep: repaired %s after standing its scene down", mapId)
      end or nil,
    })
  end

  -- ------- NPC trainers stop engaging on sight (POK-150)
  --
  -- "I had to get thru a gauntlet of trainers which I didn't want to do.
  -- I think it actually hurts exploration."  For the length of a match a
  -- route trainer is an OPT-IN resource: walking past one costs nothing,
  -- talking to one still starts the vanilla fight -- the reward stays,
  -- the toll goes.
  --
  -- The lever is the engine's own: checkTrainerSight skips any trainer
  -- whose TEXT constant has a talk script (a scripted trainer runs its
  -- own show), and talkTo hands a Lua talk handler the overworld and the
  -- npc.  So every GENERIC trainer gets a handler that does exactly what
  -- talkTo's own trainer branch does -- engage, or the after-text -- and
  -- only the ambush is gone.  Trainers with a base talk script are left
  -- alone: those are the set pieces, and gyms stay bosses (their leader
  -- was always reached by talking).
  --
  -- The talk tables are LIVE and registered AT LOAD (the registry is
  -- frozen after it): one empty table per map that has a trainer object,
  -- filled at onStart and emptied at resetMatch, with
  -- MapScripts.invalidate flushing the per-map view cache both ways.
  -- Outside a session every contribution is an empty table, so vanilla
  -- sight is untouched in real playthroughs.
  local trainerTalk = {}   -- mapId -> the live talk table

  -- ------- press A at the world (POK-141)
  --
  -- Gen 1 makes every field move a party-menu detour, and the fog charges
  -- for each one.  Later generations ask at the obstacle instead -- walk
  -- into the tree, "CUT it down?" -- so a match does too.  The engine's
  -- side-effect-free checkers (useCutFieldMove / useSurfFieldMove) carry
  -- the party menu's own gates, badges included, and tryCut / trySurf
  -- play the vanilla scene; all this adds is the ask, on the map-script
  -- onInteract seam, which the A-press dispatch consults after NPCs and
  -- signs and before the bookshelves.  Out of a session it returns false
  -- and vanilla is untouched -- faithfulness is only bent inside a match.
  local function fieldMoveInteract(game, ow, fx, fy)
    if not BR:inSession() or BR.status ~= "alive" then return false end
    if BR.battle or BR.botFight or BR.pending then return false end
    local move, go
    if ow.useCutFieldMove and ow:useCutFieldMove() == "ok" then
      move = "CUT"
      go = function() ow:tryCut(fx, fy) end
    elseif ow.useSurfFieldMove and ow:useSurfFieldMove() == "ok" then
      move = "SURF"
      go = function() ow:trySurf(fx, fy) end
    end
    if not move then return false end
    local TextBox = require("src.render.TextBox")
    local ask = move == "CUT" and "This tree can be\nCUT down.  Cut it?"
      or "The water is calm.\nSURF across it?"
    game.stack:push(TextBox.new(game, ask, nil, {
      choice = function(yes)
        if yes then go() end
      end,
    }))
    return true
  end

  do
    -- Data loads before mods, so the map roster is enumerable here (the
    -- registry freezes after load); the per-TEXT talk choices wait for
    -- arm time, when the base scripts are certainly attached.  Every map
    -- gets the A-press field-move offer; maps with trainer objects also
    -- get their live talk table.
    local okD, EngineData = pcall(require, "src.core.Data")
    for mapId, def in pairs((okD and EngineData and EngineData.maps) or {}) do
      local contribution = { onInteract = fieldMoveInteract }
      for _, o in ipairs(def.objects or {}) do
        if o.trainerClass and o.text then
          trainerTalk[mapId] = {}
          contribution.talk = trainerTalk[mapId]
          break
        end
      end
      mod.content.map_scripts:register(mapId, contribution)
    end
  end

  local function trainerTalkHandler(game, ow, npc, onDone)
    local done = onDone or function() end
    local d = npc and npc.def
    if not (d and d.trainerClass) then return done() end
    npc:facePlayer(ow.player)
    if not ow:trainerDefeated(npc) then
      return ow:engageTrainer(npc, done)
    end
    local header = game.data:trainerHeader(ow.map.def.label, d.index)
    local after = header and header.after and game.data.text[header.after]
    if not after then return done() end
    local TextBox = require("src.render.TextBox")
    game.stack:push(TextBox.new(game, after, done))
  end

  function BR:armTrainerTalk()
    local data = self.game and self.game.data
    if not data or not data.maps then return end
    local okMS, MapScripts = pcall(require, "src.script.MapScripts")
    if not okMS then return end
    for mapId, T in pairs(trainerTalk) do
      local touched = false
      local def = data.maps[mapId]
      for _, o in ipairs((def and def.objects) or {}) do
        if o.trainerClass and o.text and not T[o.text]
           and not MapScripts.baseTalk(mapId, o.text) then
          T[o.text] = trainerTalkHandler
          touched = true
        end
      end
      if touched then MapScripts.invalidate(mapId) end
    end
  end

  function BR:disarmTrainerTalk()
    local okMS, MapScripts = pcall(require, "src.script.MapScripts")
    for mapId, T in pairs(trainerTalk) do
      if next(T) then
        for k in pairs(T) do T[k] = nil end
        if okMS then MapScripts.invalidate(mapId) end
      end
    end
  end

  -- The TOWN MAP flies during a match (POK-141's third ask).  The bag's
  -- copy is read-only in vanilla; in a session, with FLY known and the
  -- sky reachable (the party menu's own two gates), using it opens the
  -- fly picker instead -- one press from the bag to the departure,
  -- because the fog is running.  Anything short of both gates falls
  -- through to the vanilla read-only map, as does every other item.
  mod.hooks:wrap("item.use", function(next, game, battle, id, target, list,
                                      moveIndex, picker)
    if id == "TOWN_MAP" and not battle
       and BR:inSession() and BR.status == "alive" then
      local ow = mod.world:overworld()
      local okM, Map = pcall(require, "src.world.Map")
      local okF, FieldDefaults = pcall(require, "src.world.FieldDefaults")
      if ow and okM and okF and ow:partyKnows("FLY")
         and Map.isOutside(ow.map.def,
                           FieldDefaults.field(game.data, "outsideTilesets")) then
        if list and list.close then list:close() end
        local ok = pcall(function()
          require("src.ui.Screens").push(game, "TownMap", { fly = true,
            onFly = function(mapId) ow:flyTo(mapId) end })
        end)
        if ok then return end
      end
    end
    return next(game, battle, id, target, list, moveIndex, picker)
  end)

  -- Hold-to-scroll in the POKeDEX (POK-109).  ListMenu grew keyRepeat
  -- exactly so a mod could turn it on per list kind; a 151-row list is
  -- the list that needs it.  Session-gated like everything else: a real
  -- playthrough's dex paces exactly as the cart did.
  mod.hooks:wrap("ui.list_menu", function(next, opts, ctx)
    local out = next(opts, ctx)
    if BR:inSession() and ctx and ctx.kind == "POK\195\169DEX"
       and type(out) == "table" then
      if out.keyRepeat == nil then out.keyRepeat = true end
      if out.pageJump == nil then out.pageJump = true end
    end
    return out
  end)

  mod.hooks:wrap("world.talk", function(next, ow, npc)
    -- The Cable Club receptionist is the other door to the engine's link
    -- play (POK-84).  Same reason as the START row, so the same window:
    -- refused for as long as the match world exists.  The cableClub flag
    -- is the map's own TX_SCRIPT marker, which is how OverworldState
    -- picks the receptionist out of a Centre's NPCs in the first place.
    local def = npc and npc.def
    local data = BR.game and BR.game.data
    if BR:inSession() and def and def.text and data and data.textEntry
       and ow and ow.map and ow.map.def then
      local entry = data:textEntry(ow.map.def.label, def.text)
      if entry and entry.cableClub then
        say("The CABLE CLUB is\nclosed for\nthe match.")
        return
      end
      -- The nurse closes when the fog rolls in (POK-117).  A free, unlimited,
      -- full-party heal is fine while everyone is still building a team --
      -- that is what the grace phase is for, and walking to a Centre costs
      -- real time.  But once the ring starts closing the match is attrition,
      -- and a Centre that never runs out undoes it: the fog does a tenth of
      -- everyone's maximum every four seconds precisely so that damage
      -- accumulates, and a round trip to the counter erased all of it for
      -- free.  So the counter shuts at the same moment the ring does.
      --
      -- Marked by the map's own TX_SCRIPT `nurse` flag, which is how
      -- OverworldState picks the nurse out of a Centre's NPCs to begin with
      -- (OverworldController:_talk) -- so this covers all twelve Centres
      -- without naming one of them.  The PC beside her is untouched.
      --
      -- THIS Centre, not every Centre (POK-140).  The first cut asked
      -- BR:fogIsUp(), which is a question about the BOARD -- has the ring
      -- started closing anywhere -- so the moment phase 2 began all twelve
      -- counters shut at once, including the ones in towns the fog would
      -- not reach for another ten minutes.  Reported from a live match.
      --
      -- No isUp() guard any more either: the per-map answer subsumes it.
      -- Phase 1's radius is Fog.NOWHERE, which clears the grid's diagonal,
      -- so every town reads safe during the grace period and the counters
      -- stay open on the same rule rather than on a second one.
      if entry and entry.nurse and BR:inRound() and BR:nurseClosed() then
        say("Sorry -- we're\nclosed! The fog\nis coming!")
        return
      end
    end
    -- the gate worker sells no admission during a round (POK-40): the
    -- talk path could otherwise charge a second 500 and re-open the zone
    if BR:inRound() and ow and ow.map and ow.map.id == "SAFARI_ZONE_GATE"
       and not (BR.game and BR.game.save and BR.game.save.safari) then
      say("The SAFARI ZONE\nis closed for\nthe match.")
      return
    end
    -- The other half of POK-122: the youngster arms the very same escort
    -- from a conversation (story5.lua M.PEWTER_CITY.talk calls
    -- pewterGymEscort directly), so guarding the trigger cells alone
    -- leaves the walk one A press away.  He keeps a line; what he does
    -- not keep is the right to march you across town mid-match.
    if BR:inSession() and def and def.name == "PEWTERCITY_YOUNGSTER"
       and ow and ow.map and ow.map.id == "PEWTER_CITY" then
      say("BROCK is taking\non all comers\ntoday!")
      return
    end
    -- The other half of POK-126, and exactly the trap Pewter set: the
    -- thief arms the identical scene from a conversation (story5.lua
    -- M.CERULEAN_CITY.talk points TEXT_CERULEANCITY_ROCKET straight at
    -- rocketRows), so guarding his two cells alone would have left the
    -- whole cutscene one A press away.  He keeps a line; what he loses is
    -- the right to run a scene at us.  JESSIE and JAMES need no equivalent
    -- -- they are hidden objects until their own scene reveals them.
    if BR:inSession() and def and def.name == "CERULEANCITY_ROCKET"
       and ow and ow.map and ow.map.id == "CERULEAN_CITY" then
      say("Beat it, kid!\nI'm not sharing\nthis TM!")
      return
    end
    -- a spilled ball: press A to open it, like every item ball in Kanto.
    -- The engine's talk pick can answer an NPC standing ON a ball -- it
    -- landed under them before this guard existed, or a wanderer drifted
    -- onto it after it landed (POK-75) -- so the faced CELL is asked too:
    -- during a round, loot beats chatter.
    local spillKey = BR.spills:keyOf(npc)
    if not spillKey and BR:inRound() and npc and npc.cellX and ow and ow.map then
      -- mid-step, the engine's pick can carry the cell being ENTERED in
      -- targetX/Y while cellX still says the one being left -- ask both
      spillKey = BR.spills:keyAt(ow.map.id, npc.cellX, npc.cellY)
        or (npc.targetX and BR.spills:keyAt(ow.map.id, npc.targetX, npc.targetY))
    end
    if spillKey then
      if BR.status == "alive" and not BR.battle and not BR.botFight then
        BR:openSpill(spillKey)
      end
      return
    end
    local id = BR.ghosts:ownerOf(npc)
    if not id then return next(ow, npc) end
    if not (BR.game and BR.relay and BR.relay:isOpen()) then return end
    if BR.status == "out" then return end   -- a camera has nobody to face
    npc:facePlayer(ow.player)
    -- talking counts as engaging if they are alive and we are
    if BR.phase == "match" and BR.status == "alive" and BR.players[id]
       and BR.players[id].status == "alive"
       and not BR.battle and not BR.pending and not BR.botFight then
      local owE = mod.world:overworld()
      if Bots.isBot(id) then
        BR.pending = { to = id, nonce = -1, host = true }
        engageFlash(owE and owE.player, function()
          -- you walked into THIS one, so its stride is already over and
          -- Bots.approach returns nil on the first beat (POK-85)
          BR:walkUpThen(id, function()
            if BR.pending and BR.pending.to == id then BR.pending = nil end
            if BR.status == "alive" and not BR.battle and not BR.botFight then
              BR:startBotBattle(id)
            end
          end)
        end)
        return
      end
      BR.nonceSeq = BR.nonceSeq + 1
      BR.pending = { to = id, nonce = BR.nonceSeq,
                     host = Engage.isHost(BR.myId, id) }
      BR.relay:send(id, Wire.challenge(BR.nonceSeq))
      if owE then
        owE.emote = { npc = owE.player, frames = ENGAGE_FLASH_FRAMES, bubble = 1 }
      end
    end
  end)

  -- ------- the fog, drawn on the TOWN MAP
  --
  -- The ring is a circle in town-map space and the TOWN MAP draws that exact
  -- grid at eight pixels a cell, so the item you already reach for to work
  -- out where you are is also the one that shows you where it is safe to be.
  -- Squares the fog has taken are shaded over; what stays clear is the ring.
  --
  -- Done as an overlay through render.hud rather than by registering a
  -- replacement "TownMap" screen: overriding the id would mean owning the
  -- whole town map -- background, cursor, fly list, nest markers -- forever,
  -- to add one circle to it.
  local GRID = 8 -- field.townMap.gridPixelSize; TownMap draws loc.x * 8

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local out = next(game, viewport)
    if not (BR.phase == "match" and viewport) then return out end
    -- the fog needs a ring; the last-trainers markers (POK-151) need only
    -- a thin roster, which in a real match arrives ring in hand anyway
    local lastFew = BR:aliveCount() <= 4
    if not (BR.ring or lastFew) then return out end
    local top = game.stack and game.stack:top()
    if not top then return out end
    local okTM, TownMap = pcall(require, "src.ui.TownMap")
    local isTownMap = (okTM and getmetatable(top) == TownMap)
      or top.screenId == "TownMap"
    if not isTownMap then return out end

    local field = game.data and game.data.field
    local locations = field and field.townMap and field.townMap.locations
    if not locations then return out end

    -- Game Boy pixels -> screen, the mapping Renderer:endFrame hands us
    local sx = (viewport.gameWidth or 160) / 160
    local sy = (viewport.gameHeight or 144) / 144
    local ox, oy = viewport.gameX or 0, viewport.gameY or 0
    local center = BR.ring and BR.ring.center
    local radius = BR.ring and BR.ring.radius

    local g = love.graphics
    g.push("all")
    if BR.ring then
      -- one shaded square per town-map cell the fog has taken.  Walking
      -- the grid rather than the location table: several maps share a
      -- square, and shading it once per map would stack the alpha into a
      -- solid black blot.
      local all = Fog.coversAll(radius)
      g.setColor(0.25, 0.15, 0.35, 0.55)
      -- The LOCATION grid is 16x16, but the town map SCREEN is 20x18
      -- tiles and the art runs to its edges -- shading only the location
      -- grid left a bright strip down the right and along the bottom,
      -- glaring once the fog covered everything.  A cell past the grid
      -- can never be inside the ring, so walking the whole screen is
      -- correct in every phase.  Fog.shadesTile owns the
      -- screen-vs-location offset (POK-146): comparing raw screen tiles
      -- against the ring's centre drew the safe region a town up and to
      -- the left of the one the fog announced.
      for gy = 0, 17 do
        for gx = 0, 19 do
          if Fog.shadesTile(center, radius, gx, gy) then
            g.rectangle("fill", ox + gx * GRID * sx, oy + gy * GRID * sy,
                        GRID * sx, GRID * sy)
          end
        end
      end
      -- and a box round the eye of it, so the safe place is named as well
      -- as merely un-shaded.  Not once the fog has taken the eye too: a
      -- box round a shaded square would promise a safety that is not there.
      if not all then
        g.setColor(1, 1, 1, 0.9)
        g.setLineWidth(math.max(1, sx))
        g.rectangle("line", ox + (center.x + Fog.MAP_OX) * GRID * sx,
                    oy + (center.y + Fog.MAP_OY) * GRID * sy,
                    GRID * sx, GRID * sy)
      end
    end
    -- The last trainers standing, on the map (POK-151).  At four or fewer
    -- alive, every OTHER living trainer -- bot or human, they are all
    -- trainers to the roster -- gets a mark on their map's square, blinking
    -- so it reads as live intel rather than art.  Your own square is what
    -- the map's native cursor already shows.  Several trainers on one
    -- square draw once: the mark says "somebody is here", and the count box
    -- says how many are left.  An interior has no square; its trainer
    -- simply is not on the map, which is Gen 1's own answer for buildings.
    if lastFew and (math.floor((clock() or 0) * 2) % 2 == 0) then
      g.setColor(1, 0.2, 0.2, 0.95)
      local marked = {}
      for _, p in pairs(BR.players) do
        local loc = p.status == "alive" and p.map and locations[p.map]
        if loc and not marked[loc.x .. ":" .. loc.y] then
          marked[loc.x .. ":" .. loc.y] = true
          g.rectangle("fill",
            ox + ((loc.x + Fog.MAP_OX) * GRID + 2) * sx,
            oy + ((loc.y + Fog.MAP_OY) * GRID + 2) * sy,
            (GRID - 4) * sx, (GRID - 4) * sy)
        end
      end
    end
    g.pop()
    return out
  end)

  -- ------- the overworld HUD
  --
  -- Three things a match needs on screen without a menu: how many trainers
  -- are left, that you are standing in the fog, and -- once you are out --
  -- whose match you are watching.  Drawn as the small bordered boxes Gen 1
  -- draws everything in, on the font the game is already using, in the top
  -- corners where no text box ever goes.  Only over the overworld itself:
  -- a battle, a menu or the town map has its own screen.

  -- The engine's emote sheet, baked through OBP0 exactly as
  -- OverworldController's obpEmoteImage does it: the bubble is OBJ art and
  -- GBPalNormal holds OBP0 at "3100", so color 1 has to LIFT to white or
  -- the bubble's interior comes out grey (#505).  Resolved through Assets,
  -- so a mod's own emotes.png override still wins.
  --
  -- Cached on first use and never rebuilt -- this draws every frame a mark
  -- is up, and a fresh image (or Quad) per frame would churn the GC.  A
  -- failure caches as `false`: no bubbles rather than a retry every frame.
  local emoteImg, emoteQuads = nil, {}
  local function emoteSheet(game)
    local field = game and game.data and game.data.field
    local bubbles = field and field.emotionBubbles
    if not (bubbles and bubbles.path) then return nil end
    if emoteImg == nil then
      local ok, img = pcall(function()
        local Assets = require("src.render.Assets")
        if not (love.image and love.image.newImageData) then
          return love.graphics.newImage(Assets.resolve(bubbles.path))
        end
        local id = Assets.imageData(bubbles.path)
        id:mapPixel(function(_, _, r, _, _, a)
          local v = 0
          if r > 0.5 then v = 1               -- OBJ colors 0 and 1 -> shade 0
          elseif r > 0.17 then v = 170 / 255  -- OBJ color 2 -> shade 1
          end                                 -- OBJ color 3 -> shade 3
          return v, v, v, a
        end)
        return love.graphics.newImage(id)
      end)
      emoteImg = (ok and img) or false
      if not ok then
        mod.log:warn("emote sheet unavailable; no busy marks (%s)", tostring(img))
      end
    end
    if not emoteImg then return nil end
    return emoteImg, bubbles
  end

  -- By NAME rather than by index: the order is the cart's, and a mod (or a
  -- Gen 2 sheet) may not keep it.
  local function emoteQuad(bubbles, img, name)
    if emoteQuads[name] then return emoteQuads[name] end
    for _, b in ipairs((bubbles and bubbles.bubbles) or {}) do
      if b.name == name then
        local q = love.graphics.newQuad(b.x, b.y, b.w, b.h, img:getDimensions())
        emoteQuads[name] = q
        return q
      end
    end
    return nil
  end

  -- Game Boy pixels -> screen, the mapping Renderer:endFrame hands us, with
  -- the state pushed so a hook can draw in 160x144 and put everything back.
  -- The caller pops.  (The town-map fog overlay below does its own: it
  -- needs the offset and the scale as numbers rather than as a transform.)
  local function gbCanvas(viewport)
    local g = love.graphics
    g.push("all")
    g.translate(viewport.gameX or 0, viewport.gameY or 0)
    g.scale((viewport.gameWidth or 160) / 160, (viewport.gameHeight or 144) / 144)
    return g
  end

  local function hudBox(text, tx, ty)
    local Font = require("src.render.Font")
    local w = #text + 2
    Font.drawBox(tx, ty, w, 3)
    Font.draw(text, (tx + 1) * 8, (ty + 1) * 8)
    return w
  end

  -- ------- "the other one is still choosing" (POK-106)
  --
  -- A link turn is lockstep: submit() puts our action on the wire, sets
  -- `phase = "waitRemote"` and parks until the peer's arrives
  -- (src/link/LinkBattle.lua).  BattleState draws nothing for that phase --
  -- no menu, no prompt -- so a player who has picked a move sits looking at
  -- a still screen with no way to tell a thinking opponent from a hung
  -- client.  Over a relay that pause can be seconds.
  --
  -- No engine change needed: the wait is exactly "we have a pending action
  -- and no remote one yet", and both fields are on the state the stack is
  -- already holding.  The dots animate on purpose -- a static box is the
  -- one thing that would not answer the question the player is asking,
  -- which is whether anything is still happening.  Padded to a fixed width
  -- so the box does not breathe with them.
  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local out = next(game, viewport)
    if not (BR:inSession() and viewport and game.stack) then return out end
    local top = game.stack:top()
    if not (top and top.phase == "waitRemote"
            and top.pendingMyAction and not top.remoteAction) then
      return out
    end
    local okFont, Font = pcall(require, "src.render.Font")
    if not okFont or not Font.draw then return out end

    local g = gbCanvas(viewport)
    -- Into the battle's OWN message box: BattleState:drawTextArea has
    -- already put it on screen and this phase leaves it empty, so we use
    -- its exact text origin (8, 112) and its black, the same as a real
    -- "used PSYCHIC!" line.  A bordered box of our own nested inside that
    -- one read as a debug overlay rather than as the game talking.
    g.setColor(0, 0, 0, 1)
    local dots = ("."):rep(math.floor((clock() or 0) * 3) % 4)
    Font.draw(("WAITING%-3s"):format(dots), 8, 112)
    g.pop()
    return out
  end)

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local out = next(game, viewport)
    if not (BR:inRound() and viewport and game.stack) then return out end
    local ow = mod.world:overworld()
    if not ow or game.stack:top() ~= ow then return out end
    local okFont, Font = pcall(require, "src.render.Font")
    if not okFont or not Font.drawBox then return out end

    local g = gbCanvas(viewport)
    g.setColor(1, 1, 1, 1)

    -- Top-right: the count -- dropped a row while the SAFARI clock is up
    -- (POK-152).  The clock box is 13 tiles wide and the count up to 9 on
    -- a 20-tile row, so they overlapped on tiles 11-12, and the clock
    -- painted second: a full lobby read "1 LEFT" with the 3 underneath
    -- the clock's border.  The other top-left boxes (FOG!, the watched
    -- name) are 9 tiles at most, so row 0 is safe everywhere else.
    local left = ("%d LEFT"):format(BR:aliveCount())
    hudBox(left, 20 - (#left + 2), BR.phase == "safari" and 3 or 0)

    -- top-left: the fog, or who you are watching
    if BR.status == "out" then
      local p = BR.watching and BR.players[BR.watching]
      -- the bare name: the Gen 1 font has no angle brackets, and the box
      -- position already says "watching" (POK-45)
      local who = p and p.name or "---"
      hudBox(who, 0, 0)
    elseif BR.phase == "safari" then
      -- the Safari clock, blinking through its last ten seconds
      local left = BR:safariLeft()
      local t = clock() or 0
      if left > 10 or math.floor(t * 2) % 2 == 0 then
        hudBox(("SAFARI %d:%02d"):format(math.floor(left / 60), left % 60), 0, 0)
      end
    elseif BR.wasInFog then
      -- blink on the fog's own beat, so the box pulses with the bite
      local t = clock() or 0
      if math.floor(t * 2) % 2 == 0 then hudBox("FOG!", 0, 0) end
    end

    -- ------- what everyone else is doing, over their heads (POK-113)
    --
    -- The cart's own emotion bubbles, not a drawn-on plate: the sheet the
    -- trainer-sight "!" comes from ships a QUESTION bubble beside it, and
    -- a mark in the game's own art reads as part of the world instead of
    -- as a debug overlay.  So a menu is "?" and a fight is "!" -- which is
    -- already Gen 1's vocabulary for "this trainer is engaged", and closer
    -- to hand than the X the ticket sketched.
    --
    -- Drawn here rather than through the engine's emote slot even so: that
    -- slot is ONE entity's transient bubble and it HOLDS THE WORLD for its
    -- frames (fxEmote / the sight pause), which is the opposite of a
    -- standing mark over several trainers at once.
    local sheet, bubbles = emoteSheet(game)
    local cam = ow.camera
    if cam and sheet then
      local h = here()
      for id, p in pairs(BR.players) do
        -- On OUR map and actually drawn.  Both halves matter: a bot that
        -- roams away changes p.map on the wire a tick before sync gets
        -- round to despawning its ghost, and npcOf still resolved the old
        -- handle in that window -- which put a bubble over bare ground
        -- where somebody used to be standing.
        if p.busy and p.status ~= "out" and h and p.map == h.mapId
           and BR.ghosts:isSpawned(id) then
          local npc = BR.ghosts:npcOf(id)
          -- the ghost's px/py is where this screen has DRAWN them, which is
          -- the cell tryEngage reads too (POK-96); marking the wire
          -- position would float the bubble off the sprite mid-step
          if npc and npc.px and npc.py then
            local quad = emoteQuad(bubbles, sheet,
                                   p.busy == "battle" and "EXCLAMATION_BUBBLE"
                                   or "QUESTION_BUBBLE")
            -- the engine's own bubble slot, so it lands exactly where a
            -- trainer-sight "!" does (fxEmote: px + 4, py - 14)
            local mx = math.floor(npc.px - cam.x) + 4
            local my = math.floor(npc.py - cam.y) - 14
            -- only when it would land on the screen: a bubble for somebody
            -- across a big map is a smear at the edge, not information
            if quad and mx >= -16 and mx <= 160 and my >= -16 and my <= 144 then
              g.setColor(1, 1, 1, 1)
              g.draw(sheet, quad, mx, my)
            end
          end
        end
      end
    end
    g.pop()
    return out
  end)

  -- ------- reaching it from START

  mod.content.screens:register(SCREEN, BRMenu.build(mod, BR))

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    local label = BR:inSession() and "ROYALE*"
      or (BR.relay and "ROYALE." or "ROYALE")
    -- the engine's own link play has no business in a match: the mod owns
    -- the transport for PvP, and a second session from inside one is
    -- undefined at best.  Gone until the match world is (POK-84) -- the
    -- guard used to stop at inRound(), so a win handed LINK straight back.
    if BR:inSession() then
      mod.ui.removeLabel(out, "LINK")
      -- SAVE would run the whole vanilla ceremony -- confirmation, jingle,
      -- "...saved the game!" -- and write nothing (save.write is vetoed
      -- below).  A row that lies leaves the menu (POK-33); the veto stays
      -- as the guarantee for anything else that tries.
      mod.ui.removeLabel(out, "SAVE")
      -- OPTION and MODS are doors out of the match (POK-99).  The manager
      -- can disable this very mod with a live room open, and the options
      -- screen can flip BATTLE STYLE or TEXT SPEED underneath a lockstep
      -- duel -- states nothing downstream is built to survive.  Neither
      -- row is worth surfacing for the length of a match; both come back
      -- with the throwaway world.
      mod.ui.removeLabel(out, "OPTION")
      mod.ui.removeLabel(out, "MODS")
      -- The ring is drawn on the TOWN MAP, which makes the map match
      -- information rather than a keepsake -- and reaching it through the
      -- bag meant OWNING a TOWN_MAP.  A spectator reads the watched
      -- trainer's bag (POK-18), so watching someone who never picked one
      -- up left you with no way to see the fog at all.  So the map gets
      -- its own row, always, however the match is going for you (POK-100).
      mod.ui.insertBefore(out, "QUIT", {
        label = "MAP",
        onSelect = function()
          local okMap = pcall(function()
            require("src.ui.Screens").push(game, "TownMap")
          end)
          if not okMap then say("The TOWN MAP is\nunreadable here.") end
        end,
      })
    end
    -- out and watching (POK-18): POKeMON and ITEM open what the watched
    -- trainer carries, read-only, in place of our own empty screens
    if BR:inRound() and BR.status == "out" and BR.watching then
      for _, it in ipairs(out) do
        local label = type(it.label) == "string" and it.label or ""
        if label:sub(1, 3) == "POK" and label:find("MON", 1, true)
           and not label:find("DEX", 1, true) then
          it.keepOpen = false
          it.onSelect = function() BR:openWatchedParty(game) end
        elseif label == "ITEM" then
          it.keepOpen = false
          it.onSelect = function() BR:openWatchedBag(game) end
        end
      end
    end
    -- Anchored on QUIT, not OPTION: a missing anchor APPENDS, and OPTION
    -- is removed for the length of a match (POK-99), which would have put
    -- the mod's own row below QUIT.  QUIT is the one row always there.
    return mod.ui.insertBefore(out, "QUIT", {
      label = label,
      onSelect = function() mod.ui.push(game, SCREEN) end,
    })
  end)

  -- No storage in a battle royale (POK-36): the party you carry is all you
  -- have.  Boxes launder party-as-health (deposit healthy, fight with one,
  -- withdraw fresh), so every row the PC offers -- boxes, item storage,
  -- the dex rating -- is replaced with one that says so.  LOG OFF is
  -- appended by the engine AFTER this hook, so the exit cannot be orphaned.
  mod.hooks:wrap("ui.pc.items", function(next, game, items)
    if not inMatch() then return next(game, items) end
    return { {
      label = "OUT OF ORDER",
      keepOpen = true,
      onSelect = function()
        say("The storage system\nis out of bounds\nduring a match!")
      end,
    } }
  end)

  -- ...and from the title screen, because everything a match needs it makes
  -- itself.  Requiring a save first meant sitting through Oak before you
  -- could reach a mode that throws the save away.
  mod.hooks:wrap("ui.title_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    return mod.ui.insertBefore(out, "OPTION", {
      label = "BATTLE ROYALE",
      keepOpen = true,
      onSelect = function() mod.ui.push(game, SCREEN) end,
    })
  end)

  -- Restore a remembered relay address on load; a vanilla New Game also
  -- leaves the match world (the save is a real playthrough again).
  mod.events:on("save.created", function()
    local saved = mod.save:get("relay")
    if saved then BR:setRelayAddress(saved) end
    if not BR.arming then
      BR.matchWorld = false
      BR:unsuspendMods()
      BR:disarmTrainerTalk()
    end
  end)

  -- CONTINUE loads a real save; SAVE is theirs again.
  mod.events:on("save.loaded", function()
    BR.matchWorld = false
    BR:unsuspendMods()
    BR:disarmTrainerTalk()
  end)

  -- Pick up the game handle early, and rescue a career written before
  -- POK-120 moved the store.  The old keys lived in mod.storage, which the
  -- engine scopes to one playthrough, so this finds something only on the
  -- save that happened to be live when they were written -- which is
  -- exactly the save whose wins are worth keeping.  The cache wins every
  -- tie: once a field is in the career file, the old key is never read
  -- again, so this cannot walk a career backwards.
  mod.events:on("game.ready", function(ev)
    BR.game = ev.game
    local function legacy(key)
      local ok, value = pcall(function() return mod.storage:read(ev.game, key) end)
      if ok then return value end
      return nil
    end
    local rescued = false
    if not BR.myName then
      local stored = legacy("name")
      if type(stored) == "string" and stored ~= "" then
        BR.myName, rescued = Wire.cleanName(stored), true
      end
    end
    if not BR.skin then
      local skin = legacy("skin")
      if type(skin) == "string" and skin ~= "" then BR.skin, rescued = skin, true end
    end
    if BR:winCount() == 0 then
      local wins = tonumber(legacy("wins"))
      if wins and wins >= 1 then BR.wins, rescued = Career.cleanWins(wins), true end
    end
    if rescued then
      log:say("career carried over from this save's old storage")
      BR:saveCareer()
    end
  end)

  -- A match plays in a throwaway world: writing it into the player's save
  -- slot would overwrite a real playthrough, so SAVE is vetoed from the drop
  -- until a real save exists again (title -> NEW GAME or CONTINUE).
  mod.hooks:wrap("save.write", function(next, game)
    if BR.matchWorld then
      mod.log:info("SAVE is disabled during a battle royale match")
      return false
    end
    return next(game)
  end)

  -- Other mods (and the tests) can ask what the match looks like.
  mod.exports.phase = function() return BR.phase end
  mod.exports.aliveCount = function() return BR:aliveCount() end
  mod.exports.status = function() return BR.status end

  -- The same verbs the menu speaks, exposed so a companion tool, another
  -- mod, or a POKEPORT_DRIVER script can run a match without simulating
  -- menu taps.  These are the menu's own code paths, nothing extra.
  mod.exports.host = function() return BR:host() end
  mod.exports.hostSolo = function() return BR:hostSolo() end
  mod.exports.quickPlay = function() return BR:quickPlay() end
  mod.exports.setOpen = function(v) return BR:setOpen(v ~= false) end
  mod.exports.isOpen = function() return BR:isOpen() end
  mod.exports.setFill = function(n) return BR:setFill(n) end
  mod.exports.botsAtStart = function() return BR:botsAtStart() end
  mod.exports.startsIn = function() return BR:startsIn() end
  mod.exports.join = function(code) return BR:join(code) end
  mod.exports.start = function() return BR:startMatch() end
  mod.exports.leave = function() return BR:teardown() end
  -- PLAY AGAIN over the wire, exactly as a guest receives it (POK-144): the
  -- exit ARMED at "over", and TAKEN by a client still standing in a match
  -- the room has already left.  The row is gone from the match face and the
  -- host's unlock moved into endMatch, so this is the whole of what the verb
  -- still means -- and it is what the name says.  The PvP drivers used to
  -- call this and then assert that the LOBBY came back, which the funnel did
  -- for them; they assert the funnel by name now, so nothing in the repo
  -- calls this.  It stays because it is the only handle a driver has on the
  -- recovery half, which no other export can reach.
  mod.exports.playAgain = function() return BR:onAgain() end
  mod.exports.setRelay = function(addr) return BR:setRelayAddress(addr) end
  mod.exports.setName = function(name) return BR:setName(name) end
  mod.exports.setSkin = function(id) return BR:setSkin(id) end
  mod.exports.skinState = function()
    local Skins = require("mods.battle_royale.lib.skins")
    local out = { wins = BR:winCount(), skin = BR:skinId(), walk = mySprite() }
    for _, e in ipairs(Skins.LADDER) do
      out[#out + 1] = { id = e.id, wins = e.wins,
                        unlocked = Skins.isUnlocked(e, BR:winCount()) }
    end
    return out
  end
  mod.exports.statsOn = function() return BR:statsOn() end
  mod.exports.setStatsOn = function(on) return BR:setStatsOn(on) end
  mod.exports.debugSetWins = function(n)
    BR.wins = Career.cleanWins(n)
    BR:saveCareer()
    return BR.wins
  end
  mod.exports.openSkinPicker = function()
    local Skins = require("mods.battle_royale.lib.skins")
    if not BR.game then return nil, "no game" end
    BR.game.stack:push(Skins.Picker.new(BR.game, {
      wins = BR:winCount(), current = BR:skinId(),
      onPick = function(id) BR:setSkin(id) end,
    }))
    return true
  end
  mod.exports.setBots = function(n)
    BR.botCount = math.max(0, math.min(Bots.MAX, math.floor(tonumber(n) or 0)))
    return BR.botCount
  end
  -- the drivers' way to set a clock: re-declare the rows with new defaults
  -- (options:define replaces the whole set, so every row rides along)
  local function redefineOptions(fog, safari)
    mod.options:define({
      { key = "relay", label = "RELAY", type = "text",
        default = BR:relayAddress() },
      { key = "fog", label = "FOG SECONDS", type = "number",
        default = math.max(1, math.floor(tonumber(fog) or 0)), min = 1, max = 600 },
      { key = "safari", label = "SAFARI SECONDS", type = "number",
        default = math.max(0, math.floor(tonumber(safari) or 0)), min = 0, max = 600 },
    })
  end
  -- The match's two clocks, cycled from the lobby (POK-44) -- the MODS
  -- manager still works, but nobody should need four screens to find the
  -- knobs that shape a match.  Defined here so redefineOptions is above.
  local FOG_LADDER = { 60, 90, 120, 180, 240, 360, 480 }
  local SAFARI_LADDER = { 0, 60, 120, 180, 240 }
  local function nextRung(ladder, current)
    for i, v in ipairs(ladder) do
      if v == current then return ladder[i % #ladder + 1] end
    end
    return ladder[1]
  end
  -- The log's deep tier (POK-86), as a method so the lobby row and
  -- mod.exports.setDebug are one switch rather than two.
  function BR:isDebug() return log:isDeep() end

  function BR:setDebug(on)
    log:setDeep(on ~= false)
    log:say("deep logging %s", log:isDeep() and "on" or "off")
    return log:isDeep()
  end

  function BR:cycleFog()
    redefineOptions(nextRung(FOG_LADDER, self:fogSeconds()), self:safariSeconds())
  end
  function BR:cycleSafari()
    redefineOptions(self:fogSeconds(), nextRung(SAFARI_LADDER, self:safariSeconds()))
  end

  mod.exports.setFog = function(seconds)
    redefineOptions(seconds, BR:safariSeconds())
    return BR:fogSeconds()
  end
  mod.exports.setSafari = function(seconds)
    redefineOptions(BR:fogSeconds(), seconds)
    return BR:safariSeconds()
  end
  mod.exports.safariLeft = function() return BR:safariLeft() end
  -- run the Safari clock out now; the host's own tick sounds the buzzer
  mod.exports.buzz = function()
    if BR.phase == "safari" then BR.safariEndsAt = clock() or 0 end
    return BR.phase
  end
  mod.exports.ring = function()
    local r = BR.ring
    if not r then return nil end
    return { phase = r.phase, radius = r.radius,
             place = r.center and r.center.name,
             x = r.center and r.center.x, y = r.center and r.center.y }
  end
  mod.exports.level = function() return BR:level() end
  mod.exports.matchStats = function() return BR:matchStats() end
  -- A driver cannot play a match down to one survivor in the time it has,
  -- so it can declare the end instead: the same call the host makes when
  -- checkWinner finds one left, parade and all (POK-47/82).
  -- POK-86: the deep tier without restarting the game (BR_DEBUG does the
  -- same from the environment).  Returns what it is now.
  mod.exports.setDebug = function(on) return BR:setDebug(on) end
  mod.exports.isDebug = function() return BR:isDebug() end
  -- `who`: nil = you, a bot id = that trainer, "nobody" = a match with no
  -- survivors.  The last two are the routes that stranded every client
  -- (POK-144) and neither can be reached by playing.
  mod.exports.debugWin = function(who)
    -- No guard of its own any more (POK-144).  onWinner is the thing under
    -- test -- it now refuses from outside a round, because accepting from
    -- the lobby is what crowned a phantom and saved a career win for a
    -- match nobody played -- and a fixture that refuses first can only ever
    -- prove itself.  The contract a driver sees is the same one, answered
    -- by BR instead of by this function: nil and a reason when the call was
    -- refused, the new phase when it was taken.  The one shift is a SECOND
    -- call at "over", which now reports "over" rather than nil -- still
    -- refused, and no driver in the tree asks twice.
    BR:onWinner(who ~= "nobody" and (who or BR.myId) or nil)
    if BR.phase ~= "over" then return nil, "not in a round" end
    return BR.phase
  end

  -- The way IN to a match, which nothing headless can otherwise reach: the
  -- real route is a `start` from the host with a live game under it
  -- (POK-144).  Applies the message exactly as the wire handler does and
  -- reports the phase it left BR in, plus whatever the call threw.
  --
  -- A `start` carrying no drop for us is the shape a test can use: onStart
  -- tears the last match down, finds no spawn of ours, says so and returns
  -- -- which is past every line that teardown is about and short of the
  -- first line that needs a game.
  mod.exports.debugStart = function(msg)
    local ok, err = pcall(BR.onStart, BR, msg or { seed = 1, spawns = {} })
    return BR.phase, (not ok) and tostring(err) or nil
  end
  -- Whether this room is fightable, and what would have to change if not
  -- (POK-142).  Part of the same surface as the verbs above: a companion
  -- tool showing a room's health wants this before it shows anything else,
  -- because a room nobody can fight in is not a room.
  mod.exports.door = function()
    return { label = BR:buildTroubleLabel(), build = BR:buildOf(),
             -- a refusal is over in milliseconds -- the two-client run
             -- clocked 18 of them between joining and leaving -- so this
             -- is the only way anything outside can observe that it
             -- happened rather than trying to sample the window
             refused = BR.refused ~= nil,
             -- who the door turned away and what they were on.  The
             -- durable half of the same 18 milliseconds: by the time
             -- anything reads this they are already off the roster.
             turnedAway = BR:flaggedAbsent() }
  end
  mod.exports.doorTrouble = function(id) return BR:buildTrouble(id) end
  mod.exports.inFog = function() return BR.wasInFog == true end
  mod.exports.spillBalls = function()
    local out = {}
    for key, b in pairs(BR.spills.balls) do
      out[#out + 1] = { key = key, map = b.map, x = b.x, y = b.y,
                        species = b.species, level = b.level }
    end
    return out
  end
  mod.exports.watching = function() return BR.watching end
  mod.exports.watchedMap = function()
    local p = BR.watching and BR.players[BR.watching]
    return p and p.map
  end
  mod.exports.hop = function(dir) return BR:hop(dir) end
  mod.exports.spills = function()
    local out = {}
    for key, b in pairs(BR.spills.balls) do
      out[#out + 1] = { key = key, map = b.map, x = b.x, y = b.y,
                        species = b.species, level = b.level,
                        bag = b.bag ~= nil or nil }
    end
    return out
  end
  mod.exports.bagSprite = function() return Spills.BAG_SPRITE end
  mod.exports.peeked = function() return BR.peeked end
  -- a driver's way to put a bag on the ground here and now: a bag-only
  -- spill two cells from where we stand (no ball to get in the way)
  mod.exports.debugSpill = function(dx, dy, withMon)
    local here = mod.world:current()
    local data = BR.game and BR.game.data
    if not (here and data) then return nil, "no world" end
    local x, y = here.x + (dx or 0), here.y + (dy or 2)
    -- withMon: one ball too, so a driver can watch placeAround dodge an
    -- occupied cell (POK-75); default stays the bag-only spill
    local party = withMon and { { species = "RATTATA", level = 5, hp = 10 } } or {}
    local spill = Spills.build(999, here.mapId, x, y, party,
      function(cx, cy) return spillCellFree(data, here.mapId, cx, cy) end,
      { items = { { id = "POTION", n = 1 } }, money = 500, name = "DEBUG" },
      function(cx, cy) return Spawn.isWarp(data.maps, here.mapId, cx, cy) end)
    if not spill then return nil, "nothing to spill" end
    BR.spills:add(spill)
    return spill
  end
  -- what the spill table has placed, and what it could not (for drivers)
  mod.exports.spillState = function()
    local spawned, failed, balls = {}, {}, {}
    for key, npcId in pairs(BR.spills.spawned or {}) do spawned[key] = npcId end
    for key, why in pairs(BR.spills.failed or {}) do failed[key] = why end
    -- where each ball actually sits, so a driver can assert a spill landed
    -- where the fight happened and not where the bot drifted to (POK-154)
    for key, ball in pairs(BR.spills.balls or {}) do
      balls[key] = { map = ball.map, x = ball.x, y = ball.y }
    end
    return { spawned = spawned, failed = failed, balls = balls,
             here = mod.world:current(), lastSync = BR.spills.lastSync }
  end
  mod.exports.openSpill = function(key) return BR:openSpill(key) end
  -- a test hook, like debugSpill: the host drops a bot at a cell, so a
  -- smoke can stage an engage instead of praying for one
  mod.exports.debugPlaceBot = function(id, map, x, y)
    local p = BR.players[id]
    if not (p and BR.relay) then return false end
    p.map, p.x, p.y, p.facing = map, x, y, "down"
    BR.ghosts:despawn(id)
    BR.relay:broadcast(Wire.place(p.map, p.x, p.y, "down", p.status, p.sprite, id))
    return true
  end
  -- Put a mark over somebody's head from outside (POK-113).  A bot never
  -- sends `busy` -- it is simulated, not played -- so this is the only way
  -- a single-client driver can get the overlay to draw at all.
  mod.exports.debugBusy = function(id, kind)
    local p = BR.players[id]
    if not p then return false end
    p.busy = kind
    return true
  end
  -- ...and one on the walk over (POK-85): a smoke needs to know the
  -- stride began, not just that a battle eventually happened
  mod.exports.walkUp = function()
    local w = BR.walkUp
    if not w then return nil end
    return { id = w.id, steps = w.steps }
  end
  -- A driver cannot reliably get itself killed -- the fog decides that, and
  -- where you dropped decides the fog.  So it can step out (POK-72), by the
  -- same path a whiteout takes, to reach the spectator camera at all.
  mod.exports.debugOut = function(why)
    if not BR:inRound() then return nil, "not in a round" end
    BR:eliminate("You are out of\nthe match.", why or "debug")
    return BR.status
  end

  -- Put BR in a phase with no match under it, for tests and drivers.  The
  -- headless loader has no game, and every real route into a phase goes
  -- through startMatch or the wire and needs one -- so a phase-dependent
  -- rule (the POK-134 refusal guard) could not be driven through the real
  -- event bus at all without this.  A FIXTURE, not a transition: it
  -- deliberately skips setPhase's logging and side effects, and takes only
  -- the six names BR actually uses.
  local PHASES = { off = true, lobby = true, safari = true,
                   drop = true, match = true, over = true }
  mod.exports.debugPhase = function(p)
    if not PHASES[p] then return nil, "not a phase" end
    BR.phase = p
    return BR.phase
  end

  -- The other half of the same fixture (POK-145).  canOpenBattle is a
  -- phase AND a status, and every real route into a status -- the drop, a
  -- challenge, a whiteout -- needs a live game under it, so the truth table
  -- could not be driven headlessly at all without this.  Same contract as
  -- debugPhase: no side effects, no broadcast, only the names BR uses.
  local STATUSES = { lobby = true, alive = true, battle = true, out = true }
  mod.exports.debugStatus = function(s)
    if not STATUSES[s] then return nil, "not a status" end
    BR.status = s
    return BR.status
  end

  -- ...and the PvP half of it.  canOpenBattle's third term guards the frame
  -- between BR.battle being set and status following it, and nothing
  -- headless can set it -- Channel.new needs a live relay.  A stub is
  -- enough: no reader here cares what is in the record, only that there is
  -- one.  peerGone is stubbed because resetMatch calls it on the way out.
  mod.exports.debugPvp = function(on)
    BR.battle = on and { opponentId = "fixture",
                         channel = { peerGone = function() end } } or nil
    return BR.battle ~= nil
  end

  -- ...and this match's zone.  The pool itself is pure -- Safari.pool(seed,
  -- nil) needs no ROM and br_test already checks the rotation that way --
  -- but the only route that puts one ON BR is onStart, which needs a spawn
  -- of ours and a live game to start.  Without this seam the Safari's grass
  -- can only be tested one hook at a time, and the two hooks in isolation
  -- are exactly what hid the roll being switched off in the zone: the
  -- engine chains encounter.roll into encounter.species, so a test has to
  -- as well.  A fixture, like the four above: no broadcast, no clock, no
  -- phase change.  nil clears it, the way leaving a match does.
  mod.exports.debugSafariPool = function(seed)
    if seed == nil then BR.safariPool = nil return nil end
    BR.safariPool = Safari.pool(seed, BR.game and BR.game.data)
    return BR.safariPool
  end

  -- The last fixture of the same family (POK-155).  The scripted-battle wrap
  -- is armed by onStart and dropped by resetMatch, and neither runs
  -- headlessly -- onStart needs a wire message and a live game under it.  So
  -- the arm/disarm lifecycle, and any yielding command that has to survive
  -- it, could not be driven at all without this.  It arms or drops the REAL
  -- link, nothing else, and reports whether one is live.
  mod.exports.debugScriptWrap = function(on)
    if on then armScriptWrap() else disarmScriptWrap() end
    return dropScriptWrap ~= nil
  end

  -- POK-144: the un-fakeable end-of-match signal.  A driver cannot read
  -- "did the world go away" from a screenshot -- a title screen looks the
  -- same however you got there -- so the mod says which match ended and how.
  mod.exports.lastResult = function()
    local r = BR.lastResult
    if not r then return nil end
    return { won = r.won, winnerId = r.winnerId, name = r.name, at = r.at }
  end
  mod.exports.ending = function()
    local e = BR.pendingEnd
    return e and { why = e.why, earliest = e.earliest, deadline = e.deadline } or nil
  end
  mod.exports.canOpenBattle = function() return BR:canOpenBattle() end

  -- POK-72: the tick runs behind ONE pcall, so a throw in any subsystem
  -- is swallowed and only warned once.  A driver needs to see that it
  -- happened at all.
  mod.exports.tickError = function() return BR.lastTickError end

  -- ...and the spectator camera's state, which is what a freeze looks
  -- like from outside: a hidden, walk-through body with a stale pan.
  mod.exports.cameraProbe = function()
    local ow = mod.world:overworld()
    local top = BR.game and BR.game.stack and BR.game.stack:top()
    return {
      phase = BR.phase, status = BR.status, watching = BR.watching,
      cameraOwned = BR.cameraOwned or false,
      alive = BR:aliveCount(),
      hidden = (ow and ow.playerHidden) or false,
      passable = (ow and ow.player and ow.player.passable) or false,
      panned = (ow and ow.cameraPan) ~= nil,
      onOverworld = ow ~= nil and top == ow,
      moving = (ow and ow.player and ow.player.moving) or false,
      transitioning = (ow and ow.transitioning) or false,
    }
  end

  -- a diagnostic window into the fog gate, for the smokes
  mod.exports.fogProbe = function()
    local here = mod.world:current()
    return {
      phase = BR.phase, status = BR.status,
      botFight = BR.botFight, botFightAt = BR.botFightAt,
      now = clock() or 0,
      ring = BR.ring and BR.ring.phase,
      radius = BR.ring and BR.ring.radius,
      mapId = (here and here.mapId) or "nil",
      wasInFog = BR.wasInFog, lastFogTick = BR.lastFogTick,
    }
  end
  mod.exports.inFog = function()
    local here = BR.game and mod.world:current()
    if not (here and BR.ring) then return false end
    local field = BR.game.data and BR.game.data.field
    local locations = field and field.townMap and field.townMap.locations
    return not Fog.isSafe(locations, here.mapId, BR.ring.center, BR.ring.radius)
  end
  mod.exports.bots = function()
    local out = {}
    for id, p in pairs(BR.players) do
      if p.bot then
        out[#out + 1] = { id = id, name = p.name, map = p.map, x = p.x, y = p.y,
                          status = p.status,
                          -- the face it was dealt (POK-89): every bot
                          -- looking the same was invisible from outside
                          sprite = p.sprite, class = p.class,
                          -- how far through the fog's count this one is, so
                          -- a stalled sweep is diagnosable from outside
                          fogTicks = p.fogTicks or 0 }
      end
    end
    return out
  end
  -- the match's seed, so a driver can derive what every client derives
  -- from it -- a bot's tier, look, or fight brain (POK-160)
  mod.exports.matchSeed = function() return BR.matchSeed end
  -- why tickBotFights is or is not resolving, for drivers (POK-158)
  mod.exports.debugFightProbe = function()
    local now = clock() or 0
    local out = { host = (BR.relay and BR.relay:isHost()) and true or false,
                  phase = BR.phase, now = now, bots = {} }
    for id, p in pairs(BR.players) do
      if p.bot then
        out.bots[#out.bots + 1] = {
          id = id, status = p.status, map = p.map, x = p.x, y = p.y,
          sinceFight = now - (p.lastFight or 0),
          -- what it is doing with its feet, for POK-160's probes
          goal = p.goal and p.goal.kind or nil,
          hunting = (p.huntFor and true) or false,
          pathLeft = p.huntPath and #p.huntPath or nil,
          beats = p.dueBeats or 0, steps = p.stepsTaken or 0,
          dwell = (p.dwellUntil and p.dwellUntil > now)
            and (p.dwellUntil - now) or nil,
        }
      end
    end
    return out
  end

  -- a test hook, like debugPlaceBot: wound a bot's whole team to `frac`,
  -- so a driver can stage "hurt enough to want the Centre" (POK-158 M2)
  mod.exports.debugScarBot = function(id, frac)
    if not (BR.matchSeed and BR.players[id]) then return false end
    local rec = BR:botRecord(id)
    for _, m in ipairs(rec) do
      m.hpFrac = math.max(0, math.min(1, tonumber(frac) or 0))
    end
    if BR.relay then BR.relay:broadcast(Wire.botrec(id, rec)) end
    return true
  end
  -- a test hook: put a species on a bot's record, so a driver can stage
  -- a capability the seed did not deal (a SURF learner, POK-158 M4)
  mod.exports.debugBotMon = function(id, species)
    if not (BR.matchSeed and BR.players[id] and type(species) == "string") then
      return false
    end
    local rec = BR:botRecord(id)
    rec[#rec + 1] = { species = species, hpFrac = 1 }
    if BR.relay then BR.relay:broadcast(Wire.botrec(id, rec)) end
    return true
  end
  -- a bot's persistent team, for drivers (POK-158).  Reads through the
  -- lazy accessor, so asking is the same as any client's first look.
  mod.exports.botRecord = function(id)
    local rec = BR.matchSeed and BR.players[id] and BR:botRecord(id)
    if not rec then return nil end
    local out = {}
    for i, m in ipairs(rec) do
      out[i] = { species = m.species, hpFrac = m.hpFrac }
    end
    if rec.bag then
      local items = {}
      for i, it in ipairs(rec.bag.items or {}) do
        items[i] = { id = it.id, n = it.n }
      end
      out.bag = { items = items, money = rec.bag.money or 0 }
    end
    return out
  end
  mod.exports.code = function() return BR.relay and BR.relay.code end
  mod.exports.lastError = function() return BR.relay and BR.relay.error end
  mod.exports.memberCount = function()
    return BR.relay and #BR.relay.members or 0
  end
  mod.exports.players = function()
    local out = {}
    for id, p in pairs(BR.players) do
      out[#out + 1] = { id = id, name = p.name, map = p.map, x = p.x, y = p.y,
                        status = p.status,
                        -- the mark over their head (POK-113), so a driver
                        -- can read what a second client is being shown
                        busy = p.busy,
                        -- ...and the mark on their roster row (POK-142):
                        -- nil, or why they cannot be fought
                        door = BR:buildTrouble(id), build = p.build }
    end
    return out
  end

  -- What THIS client is telling the room it is doing (POK-113).  The
  -- derivation, not the last frame sent: in a solo room the frame is
  -- suppressed (POK-102) and there would be nothing to read otherwise.
  mod.exports.busy = function() return myBusy() end
end
