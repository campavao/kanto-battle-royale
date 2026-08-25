-- Bot trainers: the roster, their parties, and how they wander.
--
-- Pure logic -- no love.*, no socket, no engine module -- so all of it is
-- exercised headless by tests/br_test.lua.  The host owns bot movement and
-- relays it like its own; everything else about a bot is DERIVED from the
-- match seed and the bot's id, so every client computes the same name and
-- the same party without a byte of it crossing the wire.  That matters
-- because whoever walks into a bot fights it locally: if two clients
-- disagreed about its team, they would disagree about who won.
--
-- Ids start at ID_BASE, far above anything the relay hands a real
-- connection (room ids count up from 1 and a room holds at most 16), so a
-- bot can share the players table with humans and be told apart by id alone.

local Spawn = require("mods.battle_royale.lib.spawn")

local Bots = {}

Bots.ID_BASE = 1000

-- Kanto has 34 outdoor maps, so up to ~34 bots each get a route of their
-- own and the drop stays spread out.  The binding limit above that is not
-- the world, it is the wire: the host broadcasts one step per bot per beat,
-- which at BOT_STEP_SECONDS works out around 1.4 messages a second per bot
-- against the relay's 120-a-second flood guard.  Thirty leaves comfortable
-- room for that plus everyone's own movement and a battle in flight; sixty
-- would sit at roughly three quarters of the cap before a fight starts.
Bots.MAX = 30

-- What the lobby's BOTS row cycles through.  A row that stepped one at a
-- time would take thirty presses to fill a match.
Bots.LADDER = { 0, 1, 2, 3, 5, 8, 12, 16, 20, 25, 30 }

-- the next rung up from `n`, wrapping back to none
function Bots.nextCount(n)
  for _, step in ipairs(Bots.LADDER) do
    if step > (tonumber(n) or 0) then return step end
  end
  return 0
end

-- The same idea counted in whole trainers rather than bots, for the FILL TO
-- row: a target for the roster that bots make up the shortfall in.  Zero is
-- off, and one is pointless (a match of one is already over), so the ladder
-- starts at two.
Bots.FILL = { 0, 2, 4, 6, 8, 12, 16, 20, 26, Bots.MAX + 1 }

function Bots.nextFill(n)
  for _, step in ipairs(Bots.FILL) do
    if step > (tonumber(n) or 0) then return step end
  end
  return 0
end

-- Names fit the 7-character Gen 1 box and read like trainers, not robots.
local NAMES = {
  "JOEY", "MIKEY", "CALVIN", "LASS", "TIANA", "DUDLEY", "SETH", "PIA",
  "RUDY", "NOLAN", "IVY", "MAX", "REN", "KIM", "TOBY", "VIC",
}

-- A shallow common-Kanto pool: every one of these is a real Red species and
-- a fair fight for a level 5 starter.
local SPECIES = {
  "RATTATA", "PIDGEY", "SPEAROW", "ZUBAT", "MANKEY", "EKANS", "SANDSHREW",
  "MEOWTH", "CATERPIE", "WEEDLE", "NIDORAN_M", "NIDORAN_F",
}

-- What a bot LOOKS like (POK-89): an overworld sheet and the trainer class whose
-- front pic goes with it, derived from the seed exactly as the name and
-- the party are, so every client draws the same bot without a byte of it
-- crossing the wire.
--
-- Deliberately NOT the player wardrobe (lib/skins.lua).  Those are earned
-- with career wins, and a bot in GIOVANNI would advertise a rank nobody
-- standing there had -- the same confusion that made every bot look like
-- YOUNGSTER, which is the one-win skin.  These are Kanto's own trainer
-- types instead, and every pair has BOTH a sheet and a class in the
-- extracted data (br_test pins that, since a missing sheet asserts inside
-- NPC.new and a missing class inside BattleState).
Bots.LOOKS = {
  { walk = "SPRITE_FISHER",        class = "OPP_FISHER" },
  { walk = "SPRITE_SUPER_NERD",    class = "OPP_SUPER_NERD" },
  { walk = "SPRITE_BIKER",         class = "OPP_BIKER" },
  { walk = "SPRITE_BEAUTY",        class = "OPP_BEAUTY" },
  { walk = "SPRITE_SWIMMER",       class = "OPP_SWIMMER" },
  { walk = "SPRITE_COOLTRAINER_M", class = "OPP_COOLTRAINER_M" },
  { walk = "SPRITE_COOLTRAINER_F", class = "OPP_COOLTRAINER_F" },
  { walk = "SPRITE_GAMBLER",       class = "OPP_GAMBLER" },
  { walk = "SPRITE_SCIENTIST",     class = "OPP_SCIENTIST" },
  { walk = "SPRITE_ROCKER",        class = "OPP_ROCKER" },
}

-- `data` filters to what this build actually has, the way Bots.party does
-- with species.  nil means this build has none of them, and the caller
-- keeps whatever default it had.
function Bots.look(seed, id, data)
  local pool = {}
  for _, e in ipairs(Bots.LOOKS) do
    local haveWalk = not (data and data.sprites) or data.sprites[e.walk]
    local haveClass = not (data and data.trainers) or data.trainers[e.class]
    if haveWalk and haveClass then pool[#pool + 1] = e end
  end
  if #pool == 0 then return nil end
  -- a stream of its own: sharing the name's or the party's would tie a
  -- bot's face to its team, and every FISHER would lead the same mon
  local rng = Bots.rng((tonumber(seed) or 1) + 104729, id)
  return pool[rng(1, #pool)]
end

local DIRS = { "up", "down", "left", "right" }
local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

Bots.DELTA = DELTA

-- How often a bot wanders off the edge of its map into a connected one.
-- Real seconds, like their steps: this is host-side traffic too, and it is
-- what lets bots meet each other (and you) instead of pacing one route for
-- the whole match.  Movement along the SAME connections a player walks --
-- not a jump to somewhere convenient.
Bots.ROAM_SECONDS = 25

-- After a fight, both sides get a breather before another one, so a crowded
-- map does not resolve its whole roster in a couple of ticks.
Bots.FIGHT_COOLDOWN = 12

-- Two bots notice each other about as far off as a player would.
Bots.NOTICE = 3

function Bots.isBot(id)
  return type(id) == "number" and id >= Bots.ID_BASE
end

-- The maps this one opens onto (north/south/east/west seams), sorted so the
-- choice never depends on pairs() order.
function Bots.exits(mapDef)
  local out = {}
  for _, dest in pairs((mapDef and mapDef.connections) or {}) do
    local id = type(dest) == "table" and (dest.map or dest.to or dest[1]) or dest
    if type(id) == "string" then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

-- Are these two close enough to have noticed each other?
function Bots.near(a, b, range)
  if not (a and b) or a.map ~= b.map then return false end
  local dx, dy = math.abs(a.x - b.x), math.abs(a.y - b.y)
  return math.max(dx, dy) <= (range or Bots.NOTICE)
end

function Bots.idFor(index) return Bots.ID_BASE + index end

-- One deterministic stream per bot, so name/party/wander never depend on
-- call order or on which machine is asking.
function Bots.rng(seed, id)
  return Spawn.rng((tonumber(seed) or 1) + (tonumber(id) or 0) * 7919)
end

-- Names are DEALT, not rolled.  Drawing each one independently collides by
-- the pigeonhole principle long before the roster is full -- a thirty-bot
-- match produced two SETHs and two KIMs -- and "SETH beat you" has to name
-- one trainer.  So the list is rotated by a per-match amount and then
-- indexed by the bot's position, which is unique by construction and still
-- varies from match to match.  Past the end of the list the rotation wraps
-- and a digit distinguishes the lap, inside the 7-character name box.
function Bots.name(seed, id)
  local n = (id - Bots.ID_BASE) - 1 -- 0-based position in the roster
  if n < 0 then n = 0 end
  local offset = Spawn.rng(seed)(0, #NAMES - 1)
  local base = NAMES[(n + offset) % #NAMES + 1]
  local lap = math.floor(n / #NAMES)
  if lap > 0 then return base:sub(1, 6) .. tostring(lap) end
  return base
end

-- The bot's team as a trainer partyDef ({species, level} rows) -- exactly
-- the shape BattleState.newTrainer's `trainer.party` hook expects, so the
-- engine builds the mons and we never touch Pokemon.new ourselves.
--
-- `species` is filtered against the live data so a pool entry this build
-- does not have degrades to RATTATA instead of asserting mid-battle.
-- `level` is the match's current rung (lib/levels.lua): a bot scales on the
-- same clock the players do, so a fight in the last ring is a fight between
-- two level 100 teams and not an ambush by something that never grew.
function Bots.party(seed, id, data, level)
  local rng = Bots.rng(seed, id)
  local pool = {}
  for _, s in ipairs(SPECIES) do
    if not data or not data.pokemon or data.pokemon[s] then pool[#pool + 1] = s end
  end
  if #pool == 0 then pool = { "RATTATA" } end
  -- ONE mon, because that is what a player has when they drop.  Two mons
  -- made a bot the favourite in every opening fight, so the first trainer
  -- you met usually ended your match before you could catch anything --
  -- the opposite of a battle royale's build-a-team arc.
  local lv = math.max(1, math.min(100, math.floor(tonumber(level) or 5)))
  return { { species = pool[rng(1, #pool)], level = lv } }
end

-- Where a bot tries to step next.  Returns a direction, or nil to stand
-- still this beat.  canWalk(mapId, x, y) is supplied by the caller so this
-- stays free of the engine.
--
-- Bots keep their heading until it stops working, which reads as walking
-- somewhere rather than twitching in place.
--
-- `toward` (a cell) makes them hunt.  Without it two bots sharing a map
-- would each random-walk a fifty-cell route and essentially never meet, so
-- bot-versus-bot fights would be a feature that exists and never happens.
-- With it they close on each other, which is both what makes the roster
-- thin itself and the same predatory behaviour the players are under.
function Bots.wander(bot, rng, canWalk, toward)
  if rng() < 0.2 then return nil end -- a pause, so they are not machines

  local function ok(dir)
    local d = DELTA[dir]
    return d and canWalk(bot.map, bot.x + d[1], bot.y + d[2])
  end

  if toward then
    -- close the bigger gap first; fall through to a stroll if boxed in
    local dx, dy = toward.x - bot.x, toward.y - bot.y
    local wants = {}
    if math.abs(dx) >= math.abs(dy) then
      wants[1] = dx > 0 and "right" or (dx < 0 and "left" or nil)
      wants[2] = dy > 0 and "down" or (dy < 0 and "up" or nil)
    else
      wants[1] = dy > 0 and "down" or (dy < 0 and "up" or nil)
      wants[2] = dx > 0 and "right" or (dx < 0 and "left" or nil)
    end
    for _, dir in ipairs(wants) do
      if ok(dir) then return dir end
    end
  end

  if bot.facing and ok(bot.facing) and rng() < 0.7 then return bot.facing end

  -- try the others in a rotated order so no direction is systematically
  -- preferred across the roster
  local start = rng(1, #DIRS)
  for i = 0, #DIRS - 1 do
    local dir = DIRS[(start + i - 1) % #DIRS + 1]
    if ok(dir) then return dir end
  end
  return nil
end

-- The stride (POK-85): ONE step toward `toward`, no pause and no
-- wandering.  Bots.wander is a roam -- it pauses a fifth of the time, it
-- keeps its heading, it strolls off when boxed in -- which is right for a
-- bot with nowhere to be and wrong for one that has just spotted you and
-- is walking over.  nil means it cannot get closer: already adjacent, or
-- walled off.
function Bots.approach(bot, canWalk, toward)
  if not (bot and toward and bot.x and bot.y and toward.x and toward.y) then
    return nil
  end
  local dx, dy = toward.x - bot.x, toward.y - bot.y
  -- adjacent is as close as a trainer gets; standing ON you is not a beat
  if math.abs(dx) + math.abs(dy) <= 1 then return nil end
  local wants = {}
  if math.abs(dx) >= math.abs(dy) then
    wants[1] = dx > 0 and "right" or (dx < 0 and "left" or nil)
    wants[2] = dy > 0 and "down" or (dy < 0 and "up" or nil)
  else
    wants[1] = dy > 0 and "down" or (dy < 0 and "up" or nil)
    wants[2] = dx > 0 and "right" or (dx < 0 and "left" or nil)
  end
  for _, dir in ipairs(wants) do
    local d = DELTA[dir]
    if d and canWalk(bot.map, bot.x + d[1], bot.y + d[2]) then return dir end
  end
  return nil
end

-- How far, and how fast, that stride goes.  A walk across the road, not a
-- trek across the route: past the cap the fight starts anyway, because a
-- bot picking its way around a ledge reads as a fight that hung.
Bots.WALKUP_STEPS = 8
Bots.WALKUP_SECONDS = 0.14   -- brisker than a roam beat; they are coming for you

-- The homeward seam (POK-42).  exits: connected map ids; distOf(id) -> a
-- distance to the ring's eye, or nil for a map the Town Map cannot place;
-- hereDist: the current map's own distance (nil if unplaced).  Returns the
-- exit to walk, or nil to stay put.  Unplaced maps rank last; when nothing
-- can be placed at all the walk falls back to the old aimless stroll.
function Bots.homeward(exits, distOf, hereDist, rng)
  if #exits == 0 then return nil end
  local INF = math.huge
  local bestDist, ties = INF, {}
  for _, id in ipairs(exits) do
    local d = (distOf and distOf(id)) or INF
    if d < bestDist then
      bestDist, ties = d, { id }
    elseif d == bestDist and d < INF then
      ties[#ties + 1] = id
    end
  end
  if bestDist == INF then return exits[rng(1, #exits)] end
  if hereDist and hereDist < bestDist then return nil end
  return ties[rng(1, #ties)]
end

-- The deck, not the dice (POK-43).  Deal `n` bots across `count` towns so
-- no two share one while towns remain; past the count the deal wraps.
function Bots.dealTowns(count, n, rng)
  local deck = {}
  for i = 1, count do deck[i] = i end
  for i = count, 2, -1 do
    local j = rng(1, i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  local out = {}
  for k = 1, n do out[k] = deck[(k - 1) % count + 1] end
  return out
end

-- The TM in a bot's bag (POK-62).  Machine moves are only teachable FROM
-- the bag (POK-58), and nothing in a match sold TMs -- so a fallen bot is
-- where they enter the economy at all.  Mostly utility, one time in four
-- a prize; derived from the match seed so every client would agree, and
-- spent by teaching, so a found TM is a real decision.
Bots.TM_COMMON = {
  "TM_BODY_SLAM", "TM_BUBBLEBEAM", "TM_WATER_GUN", "TM_DIG", "TM_MIMIC",
  "TM_DOUBLE_TEAM", "TM_SWIFT", "TM_REST", "TM_THUNDER_WAVE",
  "TM_ROCK_SLIDE", "TM_TRI_ATTACK",
}
Bots.TM_PRIZE = {
  "TM_EARTHQUAKE", "TM_BLIZZARD", "TM_THUNDER", "TM_FIRE_BLAST",
  "TM_HYPER_BEAM", "TM_ICE_BEAM", "TM_THUNDERBOLT",
}

function Bots.lootTM(seed, id)
  local rng = Spawn.rng((tonumber(seed) or 1) + (tonumber(id) or 0) * 104729)
  local pool = (rng(1, 4) == 1) and Bots.TM_PRIZE or Bots.TM_COMMON
  return pool[rng(1, #pool)]
end

return Bots
