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
local Shim = require("mods.battle_royale.lib.shim")
local Bots = require("mods.battle_royale.lib.bots")
local Fog = require("mods.battle_royale.lib.fog")
local Levels = require("mods.battle_royale.lib.levels")
local Spills = require("mods.battle_royale.lib.spills")
local BRMenu = require("mods.battle_royale.lib.menu")

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

-- The trainer class a bot fights as.  The class only supplies the sprite,
-- the name banner and the AI temperament -- the party comes from
-- Bots.party through the trainer.party hook below.
local BOT_TRAINER_CLASS = "OPP_YOUNGSTER"

-- What beating a bot is worth.  Bots do not carry a real bag, so this is
-- authored rather than transferred: enough to be worth the fight.
local BOT_LOOT = { items = { { id = "POKE_BALL", n = 2 }, { id = "POTION", n = 1 } },
                   money = 500 }

-- The starting loadout, all in one place (docs/DESIGN.md D7).
local START_SPECIES = "RATTATA"
local START_LEVEL = 5
local START_ITEMS = { POKE_BALL = 6, POTION = 1 }
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
-- the two south warps out of the centre, to the gate: there is no leaving
-- early -- the buzzer is the only way out
local SAFARI_EXIT_WARPS = { { x = 14, y = 25 }, { x = 15, y = 25 } }
-- the gate's door on FUCHSIA CITY: shut for the rest of the match
local SAFARI_DOOR = { map = "FUCHSIA_CITY", x = 18, y = 3 }

-- Story flags a fresh Kanto save normally earns in Pallet/Oak's lab.  Set
-- at match start so the intro scripts never fire and the towns are free to
-- walk, while every route/gym trainer stays live as PvE.
local STORY_FLAGS = {
  "EVENT_FOLLOWED_OAK_INTO_LAB", "EVENT_GOT_STARTER", "EVENT_GOT_POKEDEX",
  "EVENT_GOT_POKEBALLS_FROM_OAK", "EVENT_PALLET_AFTER_GETTING_POKEBALLS",
  "EVENT_GOT_OAKS_PARCEL", "EVENT_OAK_GOT_PARCEL",
}

return function(mod)
  -- On an engine that already has the seams (RFC 0014) this does nothing.
  -- On one that does not, it installs them from outside so the same mod
  -- folder runs on a stock build.  First, because everything below assumes
  -- they exist.
  Shim.apply()
  mod.log:info("battle royale: %s", Shim.summary())

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
    arming = nil,         -- { map, x, y } while save.new_game reshapes the skeleton
    started = false,      -- have I dropped into the world yet this match
    myName = nil,         -- chosen on the NAME row; nil falls back to the save
    matchWorld = false,   -- in a BR world: SAVE stays vetoed until a real save
    pendingLoot = {},     -- loot that arrived before our own battle result did
    lootFrom = nil,       -- who we just beat (their loot is expected)
    -- Who the last battle was against, kept OUTSIDE self.battle on purpose:
    -- the channel (and with it self.battle) is torn down by LinkState before
    -- link.battle_ended reaches us, so reading the opponent off self.battle
    -- in that handler finds nil and the loot goes nowhere.
    lastOpponent = nil,
    botCount = 0,         -- how many bots the host will add at start
    fillTo = 0,           -- ...or top the roster up to this many, 0 = off
    solo = false,         -- hosting a room of one, with no server
    quick = false,        -- came in through QUICK PLAY, so it self-starts
    fellAt = nil,         -- where a whiteout caught us, to spectate from
    autoStartAt = nil,    -- quick play starts itself at this clock time
    lastRoster = 0,       -- to notice an arrival and hold the countdown open
    matchSeed = nil,      -- every client derives bot names/parties from this
    botFight = nil,       -- the bot id we are locally fighting right now
    botParty = nil,       -- handed to the trainer.party hook for one battle
    ring = nil,           -- { phase, center = {x,y,id,name}, radius }
    matchStartedAt = nil, -- host only: when the shared clock started
    lastFogTick = nil,    -- when the fog last took its bite out of us
    wasInFog = false,     -- so entering the fog is announced once
  }

  local function say(text) BRMenu.say(mod, text) end

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
    -- remembered across sessions where durable storage is available
    pcall(function() mod.storage:write(self.game, "name", self.myName) end)
    return self.myName
  end

  local function mySprite()
    local field = BR.game and BR.game.data and BR.game.data.field
    return field and field.playerSprites and field.playerSprites.walk
  end

  local function here()
    return BR.game and mod.world:current()
  end

  local function broadcastPlace()
    if not (BR.relay and BR.relay:isOpen()) then return end
    local h = here()
    BR.relay:broadcast(Wire.place(h and h.mapId, h and h.x, h and h.y,
                                  h and h.facing, BR.status, mySprite()))
    if h then BR.sentMap, BR.sentFacing = h.mapId, h.facing end
  end

  -- ------- room lifecycle

  -- the fallen trainer's bag lands in ours (the first slice of the loot
  -- spill, DESIGN D8 -- the team-as-catchables half comes later)
  local function applyLoot(fromId, msg)
    local save = BR.game and BR.game.save
    if not save then return end
    for _, it in ipairs(msg.items) do
      save.inventory[it.id] = math.min(99, (save.inventory[it.id] or 0) + it.n)
    end
    save.bagOrder = nil -- rebuilt from the inventory on the next PACK open
    save.money = math.min(999999, (save.money or 0) + (msg.money or 0))
    local name = BR.relay and BR.relay:nameOf(fromId) or "their"
    say(("You took %s's\nitems!"):format(name))
  end

  local function wireRelay(relay)
    relay:on("joined", function()
      BR.myId = relay.id
      BR.phase = "lobby"
      -- a quick-play host is the only one who counts down: whoever opened
      -- the room owns the clock, exactly as they own the start
      if BR.quick and relay:isHost() then
        BR.autoStartAt = love.timer.getTime() + QUICK_START_SECONDS
      end
    end)
    relay:on("roster", function(members)
      -- someone arriving with seconds left would be dropped into a match
      -- they never saw the lobby for; give them a moment
      if BR.autoStartAt and #members > (BR.lastRoster or 0) then
        local floor = love.timer.getTime() + QUICK_START_GRACE
        if BR.autoStartAt < floor then BR.autoStartAt = floor end
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
      if BR:inRound() then BR:checkWinner() end
    end)
    relay:on("message", function(fromId, m) BR:onMessage(fromId, m) end)
    relay:on("closed", function(reason)
      if reason then say(reason) end
      BR:reset()
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

  -- Back to a clean slate without leaving the world (a closed relay, a
  -- cancelled lobby).  teardown() is the deliberate exit that also tells the
  -- relay goodbye.
  function BR:reset()
    self.ghosts:despawnAll()
    self.spills:clear()
    if self.battle then
      self.battle.channel:peerGone()
      self.battle = nil
    end
    self.relay = nil
    self.solo = false
    self.quick = false
    self.fellAt = nil
    self.autoStartAt = nil
    self.lastRoster = 0
    self.players = {}
    self.pending = nil
    self.phase = "off"
    self.status = "lobby"
    self.myId = nil
    self.started = false
    self.pendingLoot = {}
    self.lootFrom = nil
    self.lastOpponent = nil
    self.pendingDrop = nil   -- a release that never landed (POK-34)
    self.claimedCatch = nil  -- custody taken on a shimmed engine, unconsumed
    self.dropSeq = nil
    self.safariEndsAt = nil  -- the Safari opening's clock (POK-21)
    self.lastSafariBeat = nil
    self.safariGhost = nil
    self.buzzed = nil
    self.pickingTown = nil
    self.matchSeed = nil
    self.botFight = nil
    self.botParty = nil
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

  -- Leaving has to actually leave.  A match runs in a throwaway world, so
  -- dropping the relay while standing in it left the player in a Kanto that
  -- was no longer a match and no longer a save -- the menu said "you left"
  -- and nothing else changed.  If we are in that world, go back to the title.
  function BR:teardown(message)
    local wasMatchWorld = self.matchWorld
    if self.relay then self.relay:leave() end
    self:reset()
    if wasMatchWorld and self.game then
      self.matchWorld = false   -- the throwaway world is gone; SAVE is theirs again
      local ok, err = pcall(function()
        while self.game.stack:top() do self.game.stack:pop() end
        self.game.stack:push(self.game:makeTitleState())
      end)
      if not ok then
        mod.log:warn("could not return to the title: %s", tostring(err))
      end
      return
    end
    if message then say(message) end
  end

  -- ------- starting a match
  --
  -- The host picks every drop point and sends them; nobody else has to agree
  -- on the algorithm, only on the answer.  Host and guests both apply the
  -- same `start` message through onStart.

  function BR:startMatch()
    local relay = self.relay
    if not (relay and relay:isHost()) then return end
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
    relay:broadcast(Wire.start(seed, spawns, safari))
    self:onStart({ seed = seed, spawns = spawns, safari = safari })
  end

  function BR:onStart(msg)
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
    self.players = {}
    for _, s in ipairs(msg.spawns) do
      if s.id ~= self.myId then
        local bot = Bots.isBot(s.id)
        self.players[s.id] = {
          name = bot and Bots.name(msg.seed, s.id) or self.relay:nameOf(s.id),
          map = bot and s.map or nil,   -- a bot is where the host says at once
          x = s.x, y = s.y, facing = "down",
          status = "alive", bot = bot or nil,
        }
      end
    end
    -- arm the loadout hook, then start a fresh game straight into the world
    local safari = tonumber(msg.safari) or 0
    self.arming = { map = mine.map, x = mine.x, y = mine.y, safari = safari > 0 }
    self.phase = safari > 0 and "safari" or "match"
    self.status = "alive"
    self.started = true
    self.matchWorld = true
    if safari > 0 then
      -- the host's beats correct this; until the first lands it is the
      -- announced length from now, which is close enough for a clock
      local now = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
      self.safariEndsAt = now + safari
      self.lastSafariBeat = nil
    end
    self.game:startNewGame({ intro = false })
    self.arming = nil
    self.sentMap, self.sentFacing, self.resync = nil, nil, 0
    broadcastPlace()
    if safari > 0 then
      say(("Catch what you can!\nThe PA calls time\nin %d:%02d."):format(
        math.floor(safari / 60), safari % 60))
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
      save.safari = { balls = SAFARI_BALLS, steps = SAFARI_STEPS }
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
    save.bagOrder = nil            -- rebuilt from inventory on next open
    save.pcItems = {}
    save.money = START_MONEY
    save.flags = save.flags or {}
    for _, f in ipairs(STORY_FLAGS) do save.flags[f] = true end
    save.player.name = Wire.cleanName(BR.myName or save.player.name)
    save.player.map = BR.arming.map
    save.player.x, save.player.y = BR.arming.x, BR.arming.y
    save.player.facing = "down"
    -- a whiteout should return here, not to a Pallet that never happened
    save.lastHeal = { map = BR.arming.map, x = BR.arming.x, y = BR.arming.y }
    save.lastOutdoor = { id = BR.arming.map, x = BR.arming.x, y = BR.arming.y }
    return save
  end)

  -- ------- inbound room messages

  function BR:onMessage(fromId, raw)
    local msg, why = Wire.decode(raw)
    if not msg then
      mod.log:warn("battle royale dropped a message: %s", tostring(why))
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

    elseif msg.t == "start" then
      -- only the host is a legitimate author; ignore a forged one
      if fromId == self.relay.hostId and not self.started then
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

    elseif msg.t == "loot" then
      -- ours only if we actually beat them; their message can outrun our
      -- own battle result, so an early arrival waits in pendingLoot
      if fromId == self.lootFrom then
        self.lootFrom = nil
        applyLoot(fromId, msg)
      else
        self.pendingLoot[fromId] = msg
      end

    elseif msg.t == "spill" then
      self.spills:add(msg)

    elseif msg.t == "npcout" then
      -- somebody beat one of Kanto's own; the sprite goes away here too
      pcall(function() mod.world:toggleObject(msg.map, msg.obj, false) end)

    elseif msg.t == "took" then
      self.spills:take(msg.key)

    elseif msg.t == "safari" then
      -- the Safari clock is the host's too
      if fromId == self.relay.hostId then self:onSafariBeat(msg.left) end

    elseif msg.t == "ring" then
      -- the fog is the host's to declare, like the winner
      if fromId == self.relay.hostId then
        self:applyRing(msg.phase, msg.cx, msg.cy, msg.r, msg.place)
      end

    elseif msg.t == "winner" then
      if fromId == self.relay.hostId then self:onWinner(msg.id) end
    end
  end

  -- ------- forced battles
  --
  -- The challenge/accept exchange settles who fights whom; the battle itself
  -- rides a Channel handed to LinkState (LinkState.newFromSession), which
  -- owns every link mode the game has.  The lower room id hosts the lockstep
  -- so both machines start it the same way round.

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
      { status = self.status, inBattle = self.battle ~= nil }, fromId, self.pending)
    if decision ~= "accept" then
      self.relay:send(fromId, Wire.decline(nonce, "busy"))
      return
    end
    self.relay:send(fromId, Wire.accept(nonce))
    self:beginBattle(fromId, Engage.isHost(self.myId, fromId), nonce)
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
      others[#others + 1] = { id = id, map = p.map, x = p.x, y = p.y,
                              facing = p.facing, moving = false,
                              status = p.status,
                              busy = p.status == "battle" }
    end
    -- terrain stops the eyeline; the other trainers on it do not, since they
    -- are entities rather than map tiles (a body in the way is exactly the
    -- nearest-first case Engage.target already resolves)
    local map = ow.map
    local target = Engage.target(me, others, {
      blocked = function(x, y)
        return not (map:inBounds(x, y) and map:isWalkableCell(x, y))
      end,
    })
    if not target then return end
    -- A bot has no client to lockstep with, so its fight is a local trainer
    -- battle against the party every client derives from the seed.  No
    -- challenge/accept: there is nobody to ask.
    if Bots.isBot(target) then
      self:startBotBattle(target)
      return
    end
    self.nonceSeq = self.nonceSeq + 1
    self.pending = { to = target, nonce = self.nonceSeq,
                     host = Engage.isHost(self.myId, target) }
    self.relay:send(target, Wire.challenge(self.nonceSeq))
  end

  -- ------- bots
  --
  -- The host walks them and relays each step with `as`; every client renders
  -- them through the same ghost driver a human gets.  Anyone may fight one.

  local function canWalk(mapId, x, y)
    local data = BR.game and BR.game.data
    return Spawn.walkable(data and data.maps, data and data.tilesets, mapId, x, y)
  end

  local function clock()
    if love and love.timer and love.timer.getTime then return love.timer.getTime() end
    return nil
  end

  local cellCache = {}
  local function walkableCells(mapId)
    if cellCache[mapId] then return cellCache[mapId] end
    local data = BR.game and BR.game.data
    local def = data and data.maps[mapId]
    if not def then return {} end
    local cells = Spawn.cellsOf(def, data.tilesets[def.tileset])
    cellCache[mapId] = cells
    return cells
  end

  local function roamBot(id, p, now)
    local data = BR.game and BR.game.data
    local exits = Bots.exits(data and data.maps[p.map])
    if #exits == 0 then return end
    p.rng = p.rng or Bots.rng(BR.matchSeed, id)
    local dest = exits[p.rng(1, #exits)]
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

  function BR:tickBots()
    if not (self.relay and self.relay:isHost() and self:inRound()) then return end
    local now = clock()
    for id, p in pairs(self.players) do
      if p.bot and p.status == "alive" and p.map then
        -- every so often, walk a seam into a connected map
        if now and (now - (p.lastRoam or 0)) >= Bots.ROAM_SECONDS then
          roamBot(id, p, now)
        end
        local due = now == nil or (now - (p.lastStep or 0)) >= BOT_STEP_SECONDS
        if due then
          p.lastStep = now or 0
          -- one stream per bot, kept on the bot so its walk does not depend
          -- on how many other bots are in the table or what order pairs()
          -- happens to hand them back
          p.rng = p.rng or Bots.rng(self.matchSeed, id)
          -- hunt the nearest trainer sharing this map, bot or human, so a
          -- crowded route resolves itself instead of two strangers pacing
          -- opposite ends of it forever
          -- (not in the Safari: nobody fights there, and a ghost body
          -- closing in on you is a wall in a phase with no way past it)
          local prey
          for otherId, o in pairs(self.phase == "match" and self.players or {}) do
            if otherId ~= id and o.status == "alive" and o.map == p.map then
              if not prey or (math.abs(o.x - p.x) + math.abs(o.y - p.y))
                 < (math.abs(prey.x - p.x) + math.abs(prey.y - p.y)) then
                prey = o
              end
            end
          end
          local dir = Bots.wander(p, p.rng, canWalk, prey)
          if dir then
            local d = Bots.DELTA[dir]
            p.facing = dir
            p.x, p.y = p.x + d[1], p.y + d[2]
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

  -- the named places worth closing the ring on
  local function townList()
    local locations = townLocations()
    local maps = BR.game and BR.game.data and BR.game.data.maps
    if not (locations and maps) then return {} end
    local Map = require("src.world.Map")
    local out = {}
    for id, def in pairs(maps) do
      if Map.isOutdoor(def) and Map.isFlyTown(def) and locations[id] then
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

  function BR:inRound()
    return self.phase == "safari" or self.phase == "drop" or self.phase == "match"
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
    self.phase = "drop"
    self.buzzed = true
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

  -- host only: at the buzzer every bot picks a town like everyone else
  function BR:dropBots()
    if not (self.relay and self.relay:isHost()) then return end
    local towns = self:dropTowns()
    if #towns == 0 then return end
    local now = clock() or 0
    for id, p in pairs(self.players) do
      if p.bot and p.status == "alive" then
        p.rng = p.rng or Bots.rng(self.matchSeed, id)
        local town = towns[p.rng(1, #towns)]
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
  end

  -- The buzzer's work, once we are standing on the overworld with no battle
  -- open (a catch in flight finishes first; the PA is patient).  Caught
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
        self:eliminate("PA: Ding-dong!\nTime's up!\fYou caught nothing.\nYou are out of\nthe match.")
        self.phase = "match"      -- a spectator from here on
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

  function BR:openTownPicker()
    local game = self.game
    local towns = self:dropTowns()
    if #towns == 0 then
      -- no town data to choose from: land where we stand
      self:landIn(nil)
      return
    end
    local items = {}
    for _, town in ipairs(towns) do
      items[#items + 1] = { label = town.name, value = town.id }
    end
    -- B closes the list like any other; the tick opens it again, because
    -- there is no staying at the gate
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
    self.phase = "match"
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

  function BR:fogSeconds()
    return tonumber(mod.options:get("fog")) or Fog.DEFAULT_PHASE_SECONDS
  end

  function BR:safariSeconds()
    local n = tonumber(mod.options:get("safari"))
    if n == nil then return DEFAULT_SAFARI_SECONDS end
    return math.max(0, math.floor(n))
  end


  function BR:applyRing(phase, cx, cy, radius, place)
    local was = self.ring and self.ring.phase
    self.ring = { phase = phase, center = { x = cx, y = cy, name = place },
                  radius = radius }
    if was ~= phase and phase > 1 then
      if Fog.coversAll(radius) then
        say("The fog covers\nall of KANTO!")
      else
        say(("The fog closes in\non %s!"):format(place or "KANTO"))
      end
    end
  end

  -- host only: advance the shared clock and tell the room
  function BR:tickRing()
    if not (self.relay and self.relay:isHost() and self.phase == "match") then return end
    local now = clock()
    if not now then return end
    self.matchStartedAt = self.matchStartedAt or now
    local phase = Fog.phaseAt(now - self.matchStartedAt, self:fogSeconds())
    if self.ring and self.ring.phase == phase then return end

    local center = self.ringCenter or Fog.center(self.matchSeed, townList())
    self.ringCenter = center
    if not center then return end
    local radius = Fog.radius(phase)
    self.relay:broadcast(Wire.ring(phase, center.x, center.y, radius, center.name))
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
    for _, mapId in ipairs(died) do
      local took = 0
      for _, obj in ipairs((data.maps[mapId] and data.maps[mapId].objects) or {}) do
        if obj.trainerClass and obj.name then
          took = took + 1
          pcall(function() mod.world:toggleObject(mapId, obj.name, false) end)
          if self.relay then self.relay:broadcast(Wire.npcout(mapId, obj.name)) end
        end
      end
      if took > 0 then
        -- the measurement POK-35 asks for: how much PvE each phase removes
        mod.log:info("the fog took %d trainer(s) on %s", took, tostring(mapId))
      end
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
    if not (self.phase == "match" and self.status == "alive" and self.ring) then return end
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
      self:eliminate("The fog took your\nlast POKeMON!")
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
    return true
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
      elseif (BR.phase == "drop" or BR.phase == "match") and mapId == SAFARI_DOOR.map
             and ctx.toX == SAFARI_DOOR.x and ctx.toY == SAFARI_DOOR.y then
        ctx.reason = "closed"
        local now = clock() or 0
        if now - (BR.lastClosedSay or -10) > 3 then
          BR.lastClosedSay = now
          say("The SAFARI ZONE\nis closed for\nthe match.")
        end
        return false
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
  -- healed by the clock.
  local function scaleMon(game, mon, target)
    local Pokemon = require("src.pokemon.Pokemon")
    local Stats = require("src.pokemon.Stats")
    local Growth = require("src.pokemon.Growth")
    local Evolution = require("src.pokemon.Evolution")
    local def = game.data.pokemon[mon.species]
    if not def then return false end

    local from = mon.level
    local hpLost = math.max(0, (mon.stats and mon.stats.hp or 0) - (mon.hp or 0))
    mon.level = target
    Pokemon.learnMovesFromDayCare(game.data, mon, def, from, target)
    mon.stats = Stats.calc(def, target, mon.dvs, mon.statExp)
    mon.hp = math.max(1, mon.stats.hp - hpLost)
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
  function BR:tickLevels()
    if not (self.phase == "match" and self.game) then return end
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
      if evolved then
        say(("Your POKeMON grew\nto Lv%d, and one\nevolved!"):format(target))
      else
        say(("Your POKeMON grew\nto Lv%d!"):format(target))
      end
    end
  end

  -- One way out of a match, however it happened: a battle whiteout, or the
  -- fog finishing the job outside one.
  function BR:eliminate(message)
    if self.status == "out" or not self:inRound() then return end
    self.status = "out"
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
    -- is worth converging on rather than only paying whoever landed the hit
    if save then self:spillParty() end
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

  function BR:spillParty()
    local game, relay = self.game, self.relay
    local here = game and mod.world:current()
    if not (game and here and relay) then return end
    local data = game.data
    local spill = Spills.build(self.myId or 0, here.mapId, here.x, here.y,
                               game.save.party,
                               function(x, y)
                                 return Spawn.walkable(data.maps, data.tilesets,
                                                       here.mapId, x, y)
                               end)
    if not spill then return end
    relay:broadcast(Wire.spill(spill.map, spill.mons))
    self.spills:add(spill)
    say("Your POKeMON\nscattered!")
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
      if p.bot and p.status == "alive" and p.map
         and (now - (p.lastFight or 0)) >= Bots.FIGHT_COOLDOWN then
        live[#live + 1] = { id = id, p = p }
      end
    end
    table.sort(live, function(a, b) return a.id < b.id end)
    for i = 1, #live do
      for j = i + 1, #live do
        local a, b = live[i], live[j]
        if Bots.near(a.p, b.p) then
          a.p.lastFight, b.p.lastFight = now, now
          -- a coin flip: both sides are one mon at the same rung, so there
          -- is nothing to weigh.  When bots carry real teams this is where
          -- the comparison goes.
          local loser = (love.math.random() < 0.5) and a or b
          local winner = (loser == a) and b or a
          self:eliminateBot(loser.id, loser.p, winner.p.name)
          return
        end
      end
    end
  end

  -- A bot is out: its team spills where it fell, exactly as a player's does.
  function BR:eliminateBot(id, p, killerName)
    local data = BR.game and BR.game.data
    p.status = "out"
    if self.relay then self.relay:broadcast(Wire.botout(id)) end
    self.ghosts:despawn(id)
    if data and p.map then
      local party = Bots.party(self.matchSeed, id, data, self:level())
      local spill = Spills.build(id, p.map, p.x, p.y, party, function(x, y)
        return Spawn.walkable(data.maps, data.tilesets, p.map, x, y)
      end)
      if spill and self.relay then
        self.relay:broadcast(Wire.spill(spill.map, spill.mons))
        self.spills:add(spill)
      end
    end
    if killerName then
      mod.log:info("%s beat %s", tostring(killerName), tostring(p.name))
    end
    self:checkWinner()
  end

  -- Beating a bot is worth a small authored drop rather than a transfer:
  -- a bot carries no real bag to hand over.
  local function giveBotLoot(botId)
    local save = BR.game and BR.game.save
    if not save then return end
    for _, it in ipairs(BOT_LOOT.items) do
      save.inventory[it.id] = math.min(99, (save.inventory[it.id] or 0) + it.n)
    end
    save.bagOrder = nil
    save.money = math.min(999999, (save.money or 0) + BOT_LOOT.money)
    say(("You beat %s!"):format((BR.players[botId] or {}).name or "them"))
  end

  function BR:startBotBattle(botId)
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
    self.pending = nil
    broadcastPlace()

    -- the party is handed to BattleState through the trainer.party hook
    -- below, which is the engine's own seam for exactly this
    self.botParty = Bots.party(self.matchSeed, botId, game.data, self:level())
    local ok, battle = pcall(function()
      return require("src.battle.BattleState")
        .newTrainer(game, BOT_TRAINER_CLASS, 1)
    end)
    self.botParty = nil
    if not ok or not battle then
      mod.log:warn("couldn't start a bot battle: %s", tostring(battle))
      self.status = "alive"
      self.botFight = nil
      return
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
    local scaled = {}
    for i, slot in ipairs(party) do
      if type(slot) == "table" and slot.species then
        local copy = {}
        for k, v in pairs(slot) do copy[k] = v end
        copy.level = rung
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

  mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
    if BR.status == "out" then return nil end
    return next(encDef, ctx)
  end)

  mod.hooks:wrap("trainer.before_battle", function(next, game, context, continue)
    if BR.status == "out" then
      continue({ cancel = true })
      return true
    end
    return next(game, context, continue)
  end)

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
      rolled.level = BR:level()
      BR:lendGhostLead()
    end
    return rolled
  end)

  -- ...and a bite is a wild encounter by another rod.  The chain hands back
  -- the catch ({ species, level }) from the candidate list; the list itself
  -- is not touched, so Old Rod still hooks its MAGIKARP, just at the rung.
  mod.hooks:wrap("encounter.fishing", function(next, rod, mapId, candidates)
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

  -- No nickname prompt on a catch.  A match team is disposable and you may
  -- catch a dozen under fog pressure; the naming grid is friction with
  -- nothing behind it.  false keeps the species name with no prompt.
  mod.hooks:wrap("catch.nickname", function(next, mon, ctx)
    if inMatch() then return false end
    return next(mon, ctx)
  end)

  -- A full party never sends a catch to the box -- there is no box in a
  -- match (POK-36) -- so the decision is the player's: release a team
  -- member for it, or let the catch go (POK-34).  On an engine with the
  -- seam the hook carries the battle and the picker opens right here; on a
  -- shimmed one it carries only the mon, so custody is taken now and the
  -- pokemon.caught event (which has the battle) drives the same picker.
  mod.hooks:wrap("catch.party_full", function(next, ctx)
    if not inMatch() then return next(ctx) end
    if ctx.battle then
      BR:offerDropForCatch(ctx.battle, ctx.mon)
      return true
    end
    BR.claimedCatch = ctx.mon
    return true
  end)

  -- 1X, whatever the speed rows say.  A match has a shared clock (the fog),
  -- other people, and a lockstep battle at the end of a walk; fast-forward
  -- through any of it is cheating, and slow-motion in a fight is too.  The
  -- engine asks this hook AFTER its own link-play and --speed overrides, so
  -- a scripted run (POKEPORT_SPEED) still works and the touch skin's hold
  -- button is the one control this cannot reach.
  mod.hooks:wrap("core.logic_speed", function(next, game)
    if inMatch() then return 1 end
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
      return Spawn.walkable(data.maps, data.tilesets, npc.map, x, y)
    end)
    -- the toggle store is the engine's own "this object is gone" switch; a
    -- reload mid-fade can refuse, and then the sprite lingers until the map
    -- is next entered, which is the acceptable failure
    pcall(function() mod.world:toggleObject(npc.map, npc.obj, false) end)
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
    if BR:inRound() and ev and ev.battle then BR.localBattle = ev.battle end
  end)

  -- Custody taken on a shimmed engine (catch.party_full above): the deposit
  -- was refused, the box text lied, and the mon is only in this payload.
  -- On a seam engine the destination is "mod" and this never matches.
  mod.events:on("pokemon.caught", function(ev)
    local claimed = BR.claimedCatch
    BR.claimedCatch = nil
    if not (claimed and ev and ev.mon and claimed == ev.mon) then return end
    if not (BR:inRound() and ev.battle) then return end
    BR:offerDropForCatch(ev.battle, ev.mon)
  end)

  -- A bot battle is an ordinary engine battle, so its outcome arrives on
  -- battle.ended rather than link.battle_ended.  A loss blacks the player
  -- out, which world.blacked_out below turns into elimination.
  mod.events:on("battle.ended", function(ev)
    BR.localBattle = nil
    BR.claimedCatch = nil   -- custody never consumed: nothing is pending
    BR:reclaimGhostLead()   -- the Safari's stand-in leaves with the screen
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
    end
    local botId = BR.botFight
    if not botId then return end
    BR.botFight = nil
    if BR.status == "battle" then BR.status = "alive" end
    if ev.result == "win" then
      local bot = BR.players[botId]
      if bot then bot.status = "out" end
      if BR.relay then BR.relay:broadcast(Wire.botout(botId)) end
      giveBotLoot(botId)
      BR:checkWinner()
    end
    broadcastPlace()
  end)

  function BR:beginBattle(opponentId, isHost, _nonce)
    if self.battle then return end
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
    if ev.result == "lose" then
      -- the victor takes the bag, so it has to go out while it still has
      -- anything in it: eliminate() empties it (and spills the team) below
      if opponent and BR.relay then
        local items = {}
        for id, n in pairs(save.inventory) do
          items[#items + 1] = { id = id, n = n }
        end
        BR.relay:send(opponent, Wire.loot(items, save.money))
      end
      -- one elimination path for every way of losing, so a PvP defeat
      -- spills the team exactly as a whiteout or the fog does
      BR:eliminate("You whited out!\nYou are out of\nthe match.")
    else
      BR.status = "alive"
      if ev.result == "win" and opponent then
        -- their loot may already be waiting, or still on the wire
        local waiting = BR.pendingLoot[opponent]
        BR.pendingLoot[opponent] = nil
        if waiting then
          applyLoot(opponent, waiting)
        else
          BR.lootFrom = opponent
        end
      end
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

  function BR:onWinner(id)
    if self.phase == "over" then return end
    self.phase = "over"
    self.ghosts:despawnAll()
    self.pendingDrop = nil   -- the match ended before the release could land
    self.buzzed, self.pickingTown = nil, nil
    if id == self.myId then
      say("You are the last\ntrainer standing!\nYou win!")
    elseif id then
      say((self.relay:nameOf(id)) .. " wins\nthe match!")
    else
      say("The match is\nover.")
    end
  end

  -- ------- outbound: local movement -> wire
  --
  -- movement.speed fires inside Player:tryMove the moment a step commits,
  -- after targetX/targetY are set and before the walk animates -- the
  -- earliest honest point to tell everyone "I am stepping there".

  mod.hooks:wrap("movement.speed", function(next, frames, ctx)
    local player = ctx and ctx.player
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

  mod.hooks:wrap("input.step", function(next, game, dt)
    BR.game = game
    local relay = BR.relay
    if relay then
      relay:update()
      relay = BR.relay -- update() may have closed and reset it
    end

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

    if relay and relay:isOpen() and BR:inRound() then
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
          end
          BR.ghosts:sync(game, h.mapId, BR.players)
          BR.spills:sync(h.mapId)
          -- nobody fights in the Safari (POK-21), nor at the gate on the
          -- way out of it
          if BR.phase == "match" then BR:tryEngage() end
        end
      end
      -- the Safari opening: its clock, then the buzzer's work
      BR:tickSafari()
      BR:tickDrop()
      -- bots keep walking while we are in a battle or a menu: their world
      -- does not pause because ours did
      BR:tickBots()
      if BR.phase == "match" then
        BR:tickBotFights()
        BR:tickRing()
        BR:tickBotFog()
        BR:tickNpcFog()
        -- status == "battle" is PvP or a bot fight: either machine biting
        -- HP outside the lockstep is a desync (both players sit in the
        -- same fog anyway, so it stays fair).  A LOCAL battle the fog
        -- reaches into, both sides -- see tickFog (POK-31).
        if BR.status ~= "battle" then
          BR:tickFog()
          BR:tickLevels()
        end
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
    BR:tickCamera()
    return next(game, dt)
  end)

  -- Party is health, so a whiteout is elimination however it happened -- a
  -- bot trainer, a route trainer, a wild encounter.  (A PvP link battle
  -- never blacks anyone out: cable rules leave the real party untouched,
  -- which is why link.battle_ended handles that case separately.)
  mod.events:on("world.blacked_out", function()
    BR:eliminate("You whited out!\nYou are out of\nthe match.")
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

  mod.hooks:wrap("world.talk", function(next, ow, npc)
    -- a spilled ball: press A to open it, like every item ball in Kanto
    local spillKey = BR.spills:keyOf(npc)
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
      if Bots.isBot(id) then
        BR:startBotBattle(id)
        return
      end
      BR.nonceSeq = BR.nonceSeq + 1
      BR.pending = { to = id, nonce = BR.nonceSeq,
                     host = Engage.isHost(BR.myId, id) }
      BR.relay:send(id, Wire.challenge(BR.nonceSeq))
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
    if not (BR.ring and BR.phase == "match" and viewport) then return out end
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
    local center, radius = BR.ring.center, BR.ring.radius

    local g = love.graphics
    g.push("all")
    -- one shaded square per town-map cell the fog has taken.  Walking the
    -- grid rather than the location table: several maps share a square, and
    -- shading it once per map would stack the alpha into a solid black blot.
    local all = Fog.coversAll(radius)
    g.setColor(0.25, 0.15, 0.35, 0.55)
    -- the LOCATION grid is 16x16, but the town map SCREEN is 20x18 tiles
    -- and the art runs to its edges -- shading only the location grid left
    -- a bright strip down the right and along the bottom, glaring once the
    -- fog covered everything.  A cell past the grid can never be inside the
    -- ring, so walking the whole screen is correct in every phase.
    for gy = 0, 17 do
      for gx = 0, 19 do
        local dx, dy = gx - center.x, gy - center.y
        if all or (dx * dx + dy * dy) > (radius * radius) then
          g.rectangle("fill", ox + gx * GRID * sx, oy + gy * GRID * sy,
                      GRID * sx, GRID * sy)
        end
      end
    end
    -- and a box round the eye of it, so the safe place is named as well as
    -- merely un-shaded.  Not once the fog has taken the eye too: a box round
    -- a shaded square would promise a safety that is not there.
    if not all then
      g.setColor(1, 1, 1, 0.9)
      g.setLineWidth(math.max(1, sx))
      g.rectangle("line", ox + center.x * GRID * sx, oy + center.y * GRID * sy,
                  GRID * sx, GRID * sy)
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

  local function hudBox(text, tx, ty)
    local Font = require("src.render.Font")
    local w = #text + 2
    Font.drawBox(tx, ty, w, 3)
    Font.draw(text, (tx + 1) * 8, (ty + 1) * 8)
    return w
  end

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local out = next(game, viewport)
    if not (BR:inRound() and viewport and game.stack) then return out end
    local ow = mod.world:overworld()
    if not ow or game.stack:top() ~= ow then return out end
    local okFont, Font = pcall(require, "src.render.Font")
    if not okFont or not Font.drawBox then return out end

    local sx = (viewport.gameWidth or 160) / 160
    local sy = (viewport.gameHeight or 144) / 144
    local g = love.graphics
    g.push("all")
    g.translate(viewport.gameX or 0, viewport.gameY or 0)
    g.scale(sx, sy)
    g.setColor(1, 1, 1, 1)

    -- top-right: the count
    local left = ("%d LEFT"):format(BR:aliveCount())
    hudBox(left, 20 - (#left + 2), 0)

    -- top-left: the fog, or who you are watching
    if BR.status == "out" then
      local p = BR.watching and BR.players[BR.watching]
      local who = p and p.name or "<  >"
      hudBox(("<%s>"):format(who), 0, 0)
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
    g.pop()
    return out
  end)

  -- ------- reaching it from START

  mod.content.screens:register(SCREEN, BRMenu.build(mod, BR))

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    local label = (BR:inRound() or BR.phase == "over") and "ROYALE*"
      or (BR.relay and "ROYALE." or "ROYALE")
    -- the engine's own link play has no business in a match: the mod owns
    -- the transport for PvP, and a second session from inside one is
    -- undefined at best.  Back the moment the match is over.
    if BR:inRound() then
      mod.ui.removeLabel(out, "LINK")
      -- SAVE would run the whole vanilla ceremony -- confirmation, jingle,
      -- "...saved the game!" -- and write nothing (save.write is vetoed
      -- below).  A row that lies leaves the menu (POK-33); the veto stays
      -- as the guarantee for anything else that tries.
      mod.ui.removeLabel(out, "SAVE")
    end
    return mod.ui.insertBefore(out, "OPTION", {
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
    if not BR.arming then BR.matchWorld = false end
  end)

  -- CONTINUE loads a real save; SAVE is theirs again.
  mod.events:on("save.loaded", function()
    BR.matchWorld = false
  end)

  -- pick up the game handle early and any remembered name
  mod.events:on("game.ready", function(ev)
    BR.game = ev.game
    local ok, stored = pcall(function() return mod.storage:read(ev.game, "name") end)
    if ok and type(stored) == "string" and stored ~= "" then
      BR.myName = Wire.cleanName(stored)
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
  mod.exports.setRelay = function(addr) return BR:setRelayAddress(addr) end
  mod.exports.setName = function(name) return BR:setName(name) end
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
                        species = b.species, level = b.level }
    end
    return out
  end
  mod.exports.openSpill = function(key) return BR:openSpill(key) end
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
                          -- how far through the fog's count this one is, so
                          -- a stalled sweep is diagnosable from outside
                          fogTicks = p.fogTicks or 0 }
      end
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
                        status = p.status }
    end
    return out
  end
end
