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

-- What the lobby's MAX row cycles through once FILL is on: the same
-- rungs without the off, topping out at a full room of thirty (Bots.MAX
-- is the bot cap and the room cap alike).  Wraps to the bottom.
Bots.MAXES = { 2, 4, 6, 8, 12, 16, 20, 26, Bots.MAX }

function Bots.nextMax(n)
  for _, step in ipairs(Bots.MAXES) do
    if step > (tonumber(n) or 0) then return step end
  end
  return Bots.MAXES[1]
end

-- Names fit the 7-character Gen 1 box and read like trainers, not robots.
-- At least Bots.MAX of them, so a full roster is dealt without the digit
-- Bots.name falls back on past the end of the list: the lobby shows
-- every seat by name now (lib/lobby.lua), and "TOBY1" read as a robot.
local NAMES = {
  "JOEY", "MIKEY", "CALVIN", "LASS", "TIANA", "DUDLEY", "SETH", "PIA",
  "RUDY", "NOLAN", "IVY", "MAX", "REN", "KIM", "TOBY", "VIC",
  "ANNA", "BEN", "CORA", "DANE", "ELLA", "FINN", "GINA", "HUGO",
  "IRIS", "JUNE", "KAI", "LEON", "MIA", "NED", "OTIS", "PAM",
  "QUINN", "ROSA", "SAM", "TESS",
}

-- A shallow common-Kanto pool: every one of these is a real Red species and
-- a fair fight for a level 5 starter.
local SPECIES = {
  "RATTATA", "PIDGEY", "SPEAROW", "ZUBAT", "MANKEY", "EKANS", "SANDSHREW",
  "MEOWTH", "CATERPIE", "WEEDLE", "NIDORAN_M", "NIDORAN_F",
}

-- What a bot that has been PLAYING would have caught by the mid game, and
-- by the end.  Everything scales to the rung anyway (Bots.party), so these
-- are about what a team LOOKS like across a battle, not about raw numbers:
-- meeting a GOLEM in the last ring should feel different from meeting a
-- fourth RATTATA.
local SPECIES_MIXED = {
  "GROWLITHE", "VULPIX", "ODDISH", "BELLSPROUT", "POLIWAG", "ABRA",
  "MACHOP", "GEODUDE", "PONYTA", "DROWZEE", "KRABBY", "VOLTORB",
  "CUBONE", "HORSEA", "GOLDEEN", "STARYU", "GASTLY", "ONIX",
}
local SPECIES_STRONG = {
  "ARCANINE", "ALAKAZAM", "MACHAMP", "GOLEM", "RAPIDASH", "DODRIO",
  "HYPNO", "ELECTRODE", "MAROWAK", "WEEZING", "RHYDON", "KANGASKHAN",
  "PINSIR", "TAUROS", "GYARADOS", "LAPRAS", "SNORLAX", "VICTREEBEL",
}

-- ---------------------------------------------------------------- TIERS
--
-- Not every trainer in a battle royale is the same trainer (POK-121).
--
-- A tier is rolled ONCE per bot from (seed, id), like its name and its
-- face, so every client agrees without a byte crossing the wire -- which
-- matters more here than anywhere else, because whoever walks into a bot
-- fights it locally and a disagreement about its team is a disagreement
-- about who won.
--
-- What a tier changes is deliberately NOT raw levels: everything already
-- rides the rung, so a bot is never over-levelled.  It changes how much
-- team a bot has BUILT by now, what that team looks like, how hard it
-- roams -- and which trainer class it fights as, which is the difficulty
-- dial Gen 1 already has and this mod had been picking for looks alone.
Bots.TIERS = {
  { id = "ROOKIE",  maxParty = 2, roamScale = 1.0, ai = false },
  { id = "REGULAR", maxParty = 4, roamScale = 0.8, ai = true },
  { id = "ACE",     maxParty = 6, roamScale = 0.6, ai = true },
}

-- Weighted, and weighted toward ROOKIE on purpose: an ACE is meant to be
-- the trainer you remember losing to, which it cannot be if half the
-- roster is one.  Out of ten.
local TIER_DECK = { 1, 1, 1, 1, 1, 2, 2, 2, 3, 3 }

-- The tier this bot has, for this match.  A stream of its own, so a bot's
-- difficulty is not tied to its name or its face.
function Bots.tier(seed, id)
  local rng = Bots.rng((tonumber(seed) or 1) + 65537, id)
  return Bots.TIERS[TIER_DECK[rng(1, #TIER_DECK)]]
end

-- How much team a bot of this tier has by the time the rung is `level`.
--
-- ONE at the drop, whatever the tier -- that is not negotiable and it is
-- why this is a curve rather than a constant.  Two mons at the drop made a
-- bot the favourite in every opening fight and broke the build-a-team arc,
-- which is the note Bots.party has carried since that was measured.  What
-- was wrong was the OTHER end: a player has six by the last ring and a bot
-- still had one, so bots got easier as a match ran.
function Bots.partySize(tier, level)
  local lv = math.max(1, math.min(100, math.floor(tonumber(level) or 5)))
  local most = (tier and tier.maxParty) or 1
  local frac = (lv - 5) / 95
  if frac < 0 then frac = 0 end
  local n = 1 + math.floor(frac * (most - 1) + 1e-9)
  return math.max(1, math.min(most, n))
end

-- The pool a tier draws from.  A ROOKIE never caught anything good; an ACE
-- has been hunting all match.
function Bots.pool(tier)
  if tier and tier.id == "ACE" then return SPECIES_STRONG end
  if tier and tier.id == "REGULAR" then return SPECIES_MIXED end
  return SPECIES
end

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
  -- the two whose CLASS carries real battle AI (X ATTACK; HYPER POTION
  -- and a switch) -- since POK-160 the brain rides the tier, not the
  -- face, so these are just two more faces (see Bots.fightAI)
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
    if haveWalk and haveClass then
      pool[#pool + 1] = e
    end
  end
  if #pool == 0 then return nil end
  -- a stream of its own: sharing the name's or the party's would tie a
  -- bot's face to its team, and every FISHER would lead the same mon
  local rng = Bots.rng((tonumber(seed) or 1) + 104729, id)
  return pool[rng(1, #pool)]
end

-- Which ai_classes record this bot FIGHTS with (POK-160).  The face used
-- to be the AI: an ai-tier bot had to wear a cooltrainer's sprite because
-- the trainer class carried both the pic and the brain, so eight of ten
-- faces meant GenericAI -- no items, no switches -- and the dangerous
-- bots were two faces deep in monotony.  The engine's own seam splits
-- them: TrainerAI.classFor reads `trainer.aiClass` before `trainer.id`,
-- so any face can fight with any brain.  nil for a tier that fights on
-- GenericAI; its own stream, like the tier's and the look's, so the
-- brain follows the bot and not its face.
function Bots.fightAI(seed, id)
  if not Bots.tier(seed, id).ai then return nil end
  local rng = Bots.rng((tonumber(seed) or 1) + 131071, id)
  return rng(1, 2) == 1 and "OPP_COOLTRAINER_M" or "OPP_COOLTRAINER_F"
end

-- The move an ai-tier bot actually clicks (POK-160 item 3, all mod-side).
-- The engine's move choice dispatches battle.enemyAIMods through the
-- MERGED ai_classes registry -- the vanilla three passes are just its
-- first registrants -- so a mod layer slots into the same additive
-- scoring the ROM ran: every usable move starts at 10, layers adjust,
-- the MINIMUM wins.  This one plays the turn a person would: never an
-- immune move, the biggest expected hit (power x full dual-type
-- effectiveness x STAB -- the vanilla layer 3 only ever reads ONE
-- matchup row) is encouraged past every vanilla nudge, and a resisted
-- filler is discouraged.  Status moves are left at par: the vanilla
-- passes already bury a dud, and an ACE that never clicked GROWL was
-- the point where "skilled" tips into "robotic".
--
-- The expected-damage sweep runs once per selection and caches on the
-- view, which chooseMove builds fresh for each pick.
local TypeChart = require("src.battle.TypeChart")
local function expectedHit(def, user, target)
  if not def or not (def.power and def.power > 0) then return nil end
  local eff = TypeChart.effectiveness(def.type, target.curTypes or {})
  local stab = 10
  for _, t in ipairs(user.curTypes or {}) do
    if t == def.type then stab = 15 break end
  end
  return def.power * eff * stab, eff
end

Bots.MOVE_LAYER = {
  kind = "layer",
  score = function(view, def, score)
    if not def then return score end
    if view.brBest == nil then
      local best = 0
      for _, mv in ipairs(view.user.curMoves or {}) do
        local exp = expectedHit(view.data.moves[mv.id], view.user, view.target)
        if exp and exp > best then best = exp end
      end
      view.brBest = best
    end
    local exp, eff = expectedHit(def, view.user, view.target)
    if not exp then return score end          -- status: the vanilla passes rule
    if eff == 0 then return score + 10 end    -- an immune move is never the pick
    if view.brBest > 0 and exp >= view.brBest then
      return score - 3                        -- the biggest hit outbids any nudge
    end
    if eff < 10 then return score + 1 end     -- resisted filler waits its turn
    return score
  end,
}

local DIRS = { "up", "down", "left", "right" }
local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

Bots.DELTA = DELTA

-- How often a bot wanders off the edge of its map into a connected one.
-- Real seconds, like their steps: this is host-side traffic too, and it is
-- what lets bots meet each other (and you) instead of pacing one route for
-- the whole match.  Movement along the SAME connections a player walks --
-- not a jump to somewhere convenient.
Bots.ROAM_SECONDS = 25

-- WHEN A BOT STARTS HUNTING ACROSS MAPS (POK-95).
--
-- Same-map hunting has always worked; the endgame did not.  With three
-- trainers left on three different routes, each one walked its own map
-- forever and the match was decided by the fog rather than by anybody
-- meeting anybody -- the survivors "just walk back and forth", which is
-- the worst possible last act.
--
-- Below this many trainers alive, a bot's seam choice stops drifting
-- toward the ring's eye and starts closing on the nearest live trainer.
-- Above it the eye is still the right pull: early on the field is wide,
-- the ring is doing the herding, and bots beelining at players from three
-- routes away would read as aimbots rather than trainers.
Bots.HUNT_FROM = 6

-- ...and it considers crossing more often as the roster shrinks.  A
-- twenty-five second seam clock is a pleasant amble with twenty trainers
-- alive and far too patient with three: the last pair could spend a whole
-- fog phase two maps apart, each politely waiting out its own timer.
-- `tier` scales it: an ACE crosses a seam sooner than a ROOKIE does, which
-- is what "plays aggressively" means for something whose only verb is
-- walking.  Floored at four seconds so no tier turns into a blur.
function Bots.roamSeconds(alive, tier)
  alive = tonumber(alive) or math.huge
  local base = Bots.ROAM_SECONDS
  if alive <= 3 then base = 8
  elseif alive <= Bots.HUNT_FROM then base = 14 end
  local scale = (tier and tier.roamScale) or 1
  return math.max(4, base * scale)
end

-- After a fight, both sides get a breather before another one, so a crowded
-- map does not resolve its whole roster in a couple of ticks.
Bots.FIGHT_COOLDOWN = 12

-- ...and so does the PLAYER (POK-174).  Bots stalking a trainer who is
-- already fighting used to park beside the fight and take the winner the
-- frame it ended -- a queue of fights with no way out of it.  For this
-- long after a fight ends nothing AUTOMATIC starts one: not a bot's
-- sight, not the player's own eyeline, and the bots do not prey on the
-- player either -- they prey on each other instead.  A deliberate bump
-- or walk-up talk still fights: the breather is a shield, not a cage.
Bots.BREATHER = 8

-- Two bots notice each other about as far off as a player would.
Bots.NOTICE = 3

-- How far a bot SEES a player down its own facing (POK-149).  Four cells
-- is the longest sight line Gen 1 gives its own trainers, and it is
-- deliberately shorter than the player's eyeline (Engage.RANGE): spotting
-- first is the player's edge, being spotted is the price of blundering
-- across a line.
Bots.SIGHT = 4

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
  local tier = Bots.tier(seed, id)
  local pool = {}
  for _, s in ipairs(Bots.pool(tier)) do
    if not data or not data.pokemon or data.pokemon[s] then pool[#pool + 1] = s end
  end
  -- a build without the tier's species degrades to the common pool, and
  -- then to RATTATA, rather than asserting mid-battle
  if #pool == 0 then
    for _, s in ipairs(SPECIES) do
      if not data or not data.pokemon or data.pokemon[s] then pool[#pool + 1] = s end
    end
  end
  if #pool == 0 then pool = { "RATTATA" } end
  local lv = math.max(1, math.min(100, math.floor(tonumber(level) or 5)))
  local out = {}
  for _ = 1, Bots.partySize(tier, lv) do
    out[#out + 1] = { species = pool[rng(1, #pool)], level = lv }
  end
  return out
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

-- ---------------------------------------------------------------- GOALS
--
-- Why bots have goals at all (POK-121).
--
-- Bots.wander below is a random walk with a sticky heading.  On its own
-- terms it is fine -- it does not beeline, it does not twitch -- but it was
-- written for a bot nobody was looking at, and the spectator camera means
-- somebody always is.  A dead player follows a bot for minutes, and a
-- random walk over a fifty-cell route reads as exactly what it is: pacing
-- back and forth.  It is the one behaviour that cannot be mistaken for a
-- person.
--
-- A player, watched from outside, is legible: they walk somewhere, they
-- stop and do something, they walk somewhere else.  So a bot gets a GOAL
-- -- a cell on this map and a reason -- walks a real path to it, stands
-- there for a beat doing the thing, and picks another.
--
-- Everything here is PURE and derived from the bot's own rng, exactly like
-- its name and party: whoever walks into a bot fights it locally, so no
-- client may need to ask another what a bot is up to.
--
-- The kinds, in the order chooseGoal prefers them:
--
--   ring    the fog is on this map, or close: leave toward the eye.  The
--           one goal that overrides everything, because a player would.
--   item    a spill on this map -- a fallen trainer's mons and bag.
--           Walking over to loot is the most player-like thing there is.
--   grass   the nearest tall grass, then STAND IN IT for a few seconds.
--           From outside this is indistinguishable from hunting for a
--           team, which is what the first two minutes of a match are.
--   seam    nothing here worth doing: cross to a neighbouring map.
--
-- Trainers are deliberately not a kind yet.  A route trainer is identified
-- through data:textEntry, which is engine data this module cannot reach
-- and stay pure; when it becomes a goal it arrives the same way `items`
-- does, as cells in ctx.

-- How long a bot stands at a goal once it arrives, in seconds.  Grass is
-- the long one on purpose: it is the beat that has to read as a battle,
-- and it is paired with the busy mark (POK-113) so a spectator sees the
-- same bubble a player in a fight wears.
--
-- `stroll` is the fallback and it is NOT optional.  The first cut of this
-- had chooseGoal return "seam" when a map offered no errand, on the
-- reasoning that a bot with nothing to do should leave.  Five of six bots
-- in the very first measured run then never moved AT ALL for a whole
-- minute: they had dropped in TOWNS, which have little or no grass, and a
-- seam goal only asks the roam clock to hurry -- while Bots.homeward
-- declines to move a bot already standing on the map nearest the ring's
-- eye.  Nothing else was left to move them.  A bot must always have an
-- errand it can perform HERE.
Bots.DWELL = { grass = 6, item = 1.5, heal = 4, stroll = 0, ring = 0, seam = 0 }

-- A bot gives up on a goal it cannot reach rather than grinding at a wall.
Bots.GOAL_SECONDS = 20

-- How far away an errand has to be to be worth walking to.
--
-- Without this a bot standing in a dense patch of grass picks the NEAREST
-- grass, which is the cell it is already beside: one step, a six-second
-- dwell, and the same choice again.  Measured, that looked like a bot
-- moving three cells in a minute -- pacing with extra steps, which is the
-- exact complaint the errands were written to fix.  A cell you are already
-- standing in is not somewhere to go.
Bots.MIN_ERRAND = 6

-- The BFS ceiling.  Kanto's biggest outdoor map is well under this; the
-- cap is here so a pathological map cannot stall the host, which walks
-- every bot on the same frame.
Bots.PATH_NODES = 3000

local Map = require("src.world.Map")

-- Is this cell tall grass?  Off the map DEFINITION, like Spawn.walkable,
-- so the host can reason about a map nobody is standing on.
function Bots.isGrass(maps, tilesets, mapId, x, y)
  local def = maps and maps[mapId]
  local ts = def and tilesets and tilesets[def.tileset]
  local grass = ts and ts.grassTile
  if not grass then return false end
  if x < 0 or y < 0 or x >= def.width * 2 or y >= def.height * 2 then return false end
  return Map.defCellTile(def, ts, x, y) == grass
end

-- Every tall-grass cell on a map.  Walked once per map and cached by the
-- caller: this is a full sweep, and it cannot change during a match.
function Bots.grassCells(maps, tilesets, mapId)
  local def = maps and maps[mapId]
  local ts = def and tilesets and tilesets[def.tileset]
  local out = {}
  if not (def and ts and ts.grassTile) then return out end
  for y = 0, def.height * 2 - 1 do
    for x = 0, def.width * 2 - 1 do
      if Map.defCellTile(def, ts, x, y) == ts.grassTile
         and Spawn.walkable(maps, tilesets, mapId, x, y) then
        out[#out + 1] = { x = x, y = y }
      end
    end
  end
  return out
end

-- Breadth-first path from `from` to `to`, as a list of directions.
--
-- Repathing from scratch every step (what the PvP driver does) is fine for
-- one client driving one character and wrong for a host walking thirty
-- bots: the path is computed once, kept on the bot, and only rebuilt when
-- a step is refused or the goal changes.
--
-- Returns nil when there is no route -- which is a real answer, not a
-- failure: a goal across water or behind a ledge should be abandoned, and
-- chooseGoal will pick another.
-- Parent pointers, not a path copied onto every node: the obvious version
-- carries a growing array through the frontier, which is quadratic in
-- memory over a map-sized search and allocates on every cell.  One table
-- per visited cell, walked backwards once at the end, is the same answer
-- for a fraction of the garbage -- and the host runs this for thirty bots.
--
-- (Also: no `unpack`.  It is a global in LuaJIT and `table.unpack` in 5.2+,
-- and the mod sandbox is not the harness -- the POK-90 lesson.  Nothing
-- here needs it.)
function Bots.path(canWalk, from, to, limit)
  if not (from and to) then return nil end
  if from.x == to.x and from.y == to.y then return {} end
  local function key(x, y) return y * 4096 + x end
  local startKey = key(from.x, from.y)
  local came = { [startKey] = false }   -- false: the root, not a parent
  local queue = { { x = from.x, y = from.y, key = startKey } }
  local head, nodes, cap = 1, 0, limit or Bots.PATH_NODES
  while queue[head] do
    local cur = queue[head]
    head = head + 1
    nodes = nodes + 1
    if nodes > cap then return nil end
    for _, dir in ipairs(DIRS) do
      local d = DELTA[dir]
      local nx, ny = cur.x + d[1], cur.y + d[2]
      local k = key(nx, ny)
      if came[k] == nil and canWalk(nx, ny) then
        came[k] = { from = cur, dir = dir }
        if nx == to.x and ny == to.y then
          local dirs, node = {}, came[k]
          while node do
            dirs[#dirs + 1] = node.dir
            node = came[node.from.key]
          end
          -- collected leaf-first; reverse in place
          for i = 1, math.floor(#dirs / 2) do
            dirs[i], dirs[#dirs - i + 1] = dirs[#dirs - i + 1], dirs[i]
          end
          return dirs
        end
        queue[#queue + 1] = { x = nx, y = ny, key = k }
      end
    end
  end
  return nil
end

-- The cells worth crossing a map for: everything at least MIN_ERRAND away.
-- Empty when they are all underfoot, which is a real answer -- the caller
-- falls through to a different kind of errand rather than shuffling.
function Bots.farEnough(from, cells, least)
  least = least or Bots.MIN_ERRAND
  local out = {}
  for _, c in ipairs(cells or {}) do
    if math.abs(c.x - from.x) + math.abs(c.y - from.y) >= least then
      out[#out + 1] = c
    end
  end
  return out
end

-- The nearest cell from a list, by walking distance approximated with
-- Manhattan -- cheap, and close enough to pick a sensible target before
-- the BFS confirms it is reachable.
function Bots.nearest(from, cells)
  local best, bestD
  for _, c in ipairs(cells or {}) do
    local d = math.abs(c.x - from.x) + math.abs(c.y - from.y)
    if not bestD or d < bestD then best, bestD = c, d end
  end
  return best
end

-- What this bot should be doing.  Pure: ctx carries everything about the
-- world, so the whole decision is testable without an engine.
--
--   ctx.inFog     this map is outside the ring
--   ctx.ringSoon  the ring is close enough to start moving
--   ctx.items     spill cells on this map
--   ctx.grass     tall-grass cells on this map
--   ctx.exits     connected map ids
--
-- Returns { kind =, x =, y = } for a cell on this map, or { kind = "seam" }
-- to leave.  nil never: a bot always has something to be doing.
function Bots.chooseGoal(bot, ctx, rng)
  ctx = ctx or {}
  -- The fog outranks everything, exactly as it does for a player: nothing
  -- else on this map matters if standing here is what kills you.
  if ctx.inFog or ctx.ringSoon then return { kind = "seam", why = "ring" } end

  -- A wrecked team walks to the Centre before it does anything else
  -- (POK-158 M2).  `heal` is the door cell, offered by the caller only
  -- when the team is hurt enough and the Centre still serves.
  if ctx.heal then return { kind = "heal", x = ctx.heal.x, y = ctx.heal.y } end

  -- Loot on the floor beats grass: it is already a team, and somebody
  -- else paid for it.
  local item = Bots.nearest(bot, ctx.items)
  if item then return { kind = "item", x = item.x, y = item.y } end

  -- Grass, most of the time -- but not always, or a bot with grass on its
  -- map would never leave it and the roster would never mix.
  local grass = Bots.farEnough(bot, ctx.grass)
  if #grass > 0 and rng() < 0.75 then
    -- not always the NEAREST patch: every bot on a route beelining to the
    -- same tuft is its own tell
    local pick = (rng() < 0.5 and Bots.nearest(bot, grass))
      or grass[rng(1, #grass)]
    return { kind = "grass", x = pick.x, y = pick.y }
  end

  -- Nowhere in particular, but somewhere: a far cell on this map.  Far on
  -- purpose -- a near one is the orbit-a-cell shuffle this replaced.
  local cells = ctx.cells
  if cells and #cells > 0 then
    local pick
    for _ = 1, 8 do
      local c = cells[rng(1, #cells)]
      pick = pick or c
      if c and (math.abs(c.x - bot.x) + math.abs(c.y - bot.y)) >= 8 then
        pick = c
        break
      end
    end
    if pick then return { kind = "stroll", x = pick.x, y = pick.y } end
  end

  return { kind = "seam", why = "roam" }
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

-- ------------------------------------------------ THE RECORD (POK-158)
--
-- A bot's PERSISTENT team.  Bots.party synthesizes a fresh, full-HP team
-- at the moment a fight opens, which is the central cheat POK-158 names:
-- a bot never catches anything, never carries a wound out of a fight,
-- never needs healing.  The record replaces that: a list of
-- { species=, hpFrac= } rows that is CREATED identically on every client
-- (derived from the seed at the floor rung, so lazy creation needs no
-- message) and then MUTATED only by broadcast events -- the host's catch
-- rolls, and the scars reported by whichever client just fought it.
--
-- Levels are deliberately not stored: every fight is at the rung, exactly
-- as before, so `hpFrac` is the only thing that has to survive a rung
-- change and it survives it by construction.

-- How often a grass dwell actually catches (M1 tuning knob).  The dwell
-- cadence -- walk, six seconds in the grass, twenty-second goal clock --
-- paces the team build the way steps pace a player's.
Bots.CATCH_CHANCE = 0.5

-- ONE mon at the drop, whatever the tier (the POK-121 rule, kept).
-- Derived at the FLOOR rung so two clients creating the record lazily at
-- different rungs still agree byte-for-byte.
--
-- From the match's own zone when there is one (POK-177): a bot was in the
-- Safari with everybody else, so its first mon is a draft from the same
-- pool -- and what a fallen bot drops carries the match's character
-- instead of being another PIDGEY off a fixed list.  The pool is
-- seed-derived on every client (Safari.pool), so the record still agrees
-- everywhere without a message.  Without a zone (an old caller, a test)
-- the tier's list stands.
function Bots.newRecord(seed, id, data, zone)
  local pool = {}
  for _, s in ipairs(zone or {}) do
    if not data or not data.pokemon or data.pokemon[s] then pool[#pool + 1] = s end
  end
  if #pool > 0 then
    local rng = Bots.rng((tonumber(seed) or 1) + 7919, id)
    return { { species = pool[rng(1, #pool)], hpFrac = 1 } }
  end
  local first = Bots.party(seed, id, data, 5)[1]
  return { { species = first.species, hpFrac = 1 } }
end

-- Every bot builds to a full six, like a player.  This was briefly the
-- tier's maxParty, but the tier caps never actually read in play -- what
-- a ROOKIE is worse AT is roaming and battle AI, and capping its team on
-- top of that just made small teams nobody could attribute to anything.
-- The catching itself is the pacing.
function Bots.recordCap()
  return 6
end

-- ---------------------------------------------------------------- EVOLUTION
--
-- A bot's team EVOLVES (POK-181).  The record stores species and no
-- level -- the rung is a bot's level -- and every read used to build the
-- row as that species at the rung, so a bot's GRIMER at level 80 was a
-- GRIMER, while a player's own party evolves on the rung tick.  Fifty
-- matches of that read as "the same ten lines": no MUK, no DUGTRIO, no
-- GENGAR, and the only evolved forms anyone met were the ACE list's.
--
-- The species is DERIVED at read time instead: what a line has reached
-- at this rung, walked off the data's own evolution table.  The moment
-- the rung lands, every read -- the fight, the spill it drops, the
-- spectator's peek -- shows the evolved form, on every client, with no
-- message and no chance of two records disagreeing.  Level evolutions
-- follow the rung as a player's do.  A stone has no bot moment, so each
-- bot gets a seeded rung at which its stone line "used a stone" (a
-- ROOKIE never gets to Celadon; an ACE was there early).  A trade rides
-- a change of hands, exactly as it does for a player (POK-179): a row a
-- bot looted out of somebody ELSE's ball is marked `traded`, and that
-- mark rides the botrec wire.

-- the rung band in which a tier's stone line evolves; nil never does
Bots.STONE_RUNG = { REGULAR = { 30, 60 }, ACE = { 16, 40 } }

-- This bot's stone rung and, for a line with several stones (EEVEE), a
-- fraction that picks one.  A stream of its own, like the tier's.
function Bots.stoneRung(seed, id)
  local tier = Bots.tier(seed, id)
  local band = tier and Bots.STONE_RUNG[tier.id]
  if not band then return nil, 0 end
  local rng = Bots.rng((tonumber(seed) or 1) + 30011, id)
  local rung = rng(band[1], band[2])
  return rung, (rng(1, 1000) - 1) / 1000
end

-- What `species` has become by `rung`.  opts: stoneRung (nil = no stone
-- ever), pick (0..1, which stone), traded (a change of hands).  A build
-- without the target species stops where it is rather than asserting.
function Bots.evolveAt(data, species, rung, opts)
  opts = opts or {}
  local mons = data and data.pokemon
  if not (mons and species) then return species end
  local lv = tonumber(rung) or 0
  local cur = species
  for _ = 1, 3 do
    local def = mons[cur]
    local evos = type(def) == "table" and def.evolutions or nil
    if not (evos and #evos > 0) then break end
    local nxt, stones = nil, {}
    for _, e in ipairs(evos) do
      if not mons[e.species] then
        -- unknown target: skip
      elseif e.method == "LEVEL" then
        if lv >= (tonumber(e.level) or 0) then nxt = e.species break end
      elseif e.method == "TRADE" then
        if opts.traded then nxt = e.species break end
      elseif e.method == "ITEM" then
        if opts.stoneRung and lv >= opts.stoneRung then stones[#stones + 1] = e.species end
      end
    end
    if not nxt and #stones > 0 then
      local i = math.floor((tonumber(opts.pick) or 0) * #stones) + 1
      nxt = stones[math.max(1, math.min(#stones, i))]
    end
    if not nxt or nxt == cur then break end
    cur = nxt
  end
  return cur
end

local function evolvedRow(m, rung, data, stone, pick)
  return Bots.evolveAt(data, m.species, rung,
                       { stoneRung = stone, pick = pick, traded = m.traded })
end

-- The rows a FIGHT is built from: healthy mons only, at the rung, in
-- record order, each line at what it has reached by now (data, stone and
-- pick from Bots.stoneRung; without data the species stands).  Also
-- returns idx -- the record index behind each row -- so the fight's
-- outcome can be carried back (Bots.scarRecord).
function Bots.fightRows(record, rung, data, stone, pick)
  local rows, idx = {}, {}
  for i, m in ipairs(record or {}) do
    if (m.hpFrac or 0) > 0 then
      rows[#rows + 1] = { species = evolvedRow(m, rung, data, stone, pick), level = rung }
      idx[#idx + 1] = i
    end
  end
  return rows, idx
end

-- The rows a SPILL is built from: the whole team, fainted included --
-- "the team hits the ground where you fell" counts the fallen -- each
-- at what it has reached, so what a bot drops is what it fought with.
function Bots.spillRows(record, rung, data, stone, pick)
  local rows = {}
  for _, m in ipairs(record or {}) do
    rows[#rows + 1] = { species = evolvedRow(m, rung, data, stone, pick), level = rung }
  end
  return rows
end

-- Carry a finished fight's damage back into the record.  `idx` is
-- fightRows' mapping; `enemyParty` the engine's post-battle mons in the
-- same order.  Fractions round to hundredths so the wire copy and the
-- local copy cannot drift.
function Bots.scarRecord(record, idx, enemyParty)
  for k, recI in ipairs(idx or {}) do
    local mon = enemyParty and enemyParty[k]
    local m = record and record[recI]
    if mon and m then
      local maxHp = (mon.stats and mon.stats.hp) or mon.maxHp
      if maxHp and maxHp > 0 then
        local frac = math.max(0, math.min(1, (tonumber(mon.hp) or 0) / maxHp))
        m.hpFrac = math.floor(frac * 100 + 0.5) / 100
      end
    end
  end
  return record
end

function Bots.recordAlive(record)
  for _, m in ipairs(record or {}) do
    if (m.hpFrac or 0) > 0 then return true end
  end
  return false
end

-- What a record can put up in a fight: each healthy mon's base-stat
-- total, scaled by how much of it is left.  Every mon fights at the same
-- rung, so base stats are the whole difference between species -- an
-- ACE's GOLEM outweighs a ROOKIE's third RATTATA, which is what the tier
-- pools were always supposed to buy.  300 is a middling total, the
-- benefit of the doubt for a species the data cannot place.
function Bots.recordPower(record, data)
  local total = 0
  for _, m in ipairs(record or {}) do
    local frac = m.hpFrac or 0
    if frac > 0 then
      local def = data and data.pokemon and data.pokemon[m.species]
      local bs = def and def.baseStats
      local stat = bs and ((bs.hp or 0) + (bs.attack or 0) + (bs.defense or 0)
                          + (bs.speed or 0) + (bs.special or 0)) or 300
      total = total + stat * frac
    end
  end
  return total
end

-- Resolve a meeting between two records (POK-158 M3): the coin flip is
-- dead.  The stronger team usually wins -- the roll is weighted by
-- power, so an upset stays possible the way it is in a real fight -- and
-- the WINNER walks away hurt: the loser's power lands on it as damage,
-- front-loaded onto its lead the way a Gen 1 fight chews through one,
-- capped so a won fight never wipes the team that won it.
--
-- Returns "a" or "b"; the winner's record is scarred in place, the
-- loser's is left for the spill.
function Bots.resolveFight(recA, recB, data, rng)
  local pa = Bots.recordPower(recA, data)
  local pb = Bots.recordPower(recB, data)
  if pa <= 0 and pb <= 0 then return (rng() < 0.5) and "a" or "b" end
  local winner = (rng() < pa / (pa + pb)) and "a" or "b"
  local wrec = (winner == "a") and recA or recB
  local wp = (winner == "a") and pa or pb
  local lp = (winner == "a") and pb or pa
  local budget = (wp > 0) and math.min(0.9, lp / wp) or 0
  local healthy, totalFrac = {}, 0
  for _, m in ipairs(wrec) do
    if (m.hpFrac or 0) > 0 then
      healthy[#healthy + 1] = m
      totalFrac = totalFrac + m.hpFrac
    end
  end
  local damage = budget * totalFrac
  for i, m in ipairs(healthy) do
    if damage <= 0 then break end
    -- the last healthy mon is the one that took the fight: it stands
    local floor_ = (i == #healthy) and 0.05 or 0
    local take = math.min(m.hpFrac - floor_, damage)
    if take > 0 then
      m.hpFrac = math.floor((m.hpFrac - take) * 100 + 0.5) / 100
      damage = damage - take
    end
  end
  return winner
end

-- What one gulp of each potion tier is worth, as a fraction of a mon.
-- The record stores fractions, not points, so the bag's medicine speaks
-- the same language: a POTION is worth about a third of a mid-match mon,
-- which is the same ballpark 20 points is against Gen 1 HP curves.
Bots.POTION_HEAL = {
  POTION = 0.3, SUPER_POTION = 0.5, HYPER_POTION = 0.8,
  MAX_POTION = 1, FULL_RESTORE = 1,
}

-- Drink from the bag between fights (POK-158 M2): the weakest potion
-- that helps, onto the most-hurt mon still standing, whenever anybody is
-- under 0.6 -- roughly when a player reaches for the bag rather than the
-- Centre.  Consumes the item.  Returns the item id used and the mon
-- healed, or nil when nothing was needed or nothing was left.
function Bots.quaff(record, bag)
  if not (record and bag and bag.items) then return nil end
  local worst
  for _, m in ipairs(record) do
    local f = m.hpFrac or 0
    if f > 0 and f < 0.6 and (not worst or f < worst.hpFrac) then worst = m end
  end
  if not worst then return nil end
  local best
  for _, it in ipairs(bag.items) do
    local heal = Bots.POTION_HEAL[it.id]
    if heal and (it.n or 0) >= 1 and (not best or heal < best.heal) then
      best = { it = it, heal = heal }
    end
  end
  if not best then return nil end
  best.it.n = best.it.n - 1
  if best.it.n <= 0 then
    for i, it in ipairs(bag.items) do
      if it == best.it then table.remove(bag.items, i) break end
    end
  end
  worst.hpFrac = math.min(1, math.floor((worst.hpFrac + best.heal) * 100 + 0.5) / 100)
  return best.it.id, worst
end

-- A looted bag folds into the bot's own (POK-158 M2): stacks merge by
-- id, money adds.
function Bots.bagMerge(bag, loot)
  if not (bag and loot) then return bag end
  for _, it in ipairs(loot.items or {}) do
    local mine
    for _, own in ipairs(bag.items) do
      if own.id == it.id then mine = own break end
    end
    if mine then mine.n = math.min(99, (mine.n or 0) + (it.n or 0))
    else bag.items[#bag.items + 1] = { id = it.id, n = it.n or 1 } end
  end
  bag.money = (bag.money or 0) + (loot.money or 0)
  return bag
end

-- The move inside a TM item id, or nil for anything else.
function Bots.tmMove(itemId)
  if type(itemId) ~= "string" then return nil end
  local move = itemId:match("^TM_(.+)$")
  return move
end

-- Can this species learn this move from a machine?  `def.tmhm` is the
-- generated per-species table of machine moves.
function Bots.canLearn(def, moveId)
  for _, m in pairs((def and def.tmhm) or {}) do
    if m == moveId then return true end
  end
  return false
end

-- Can this record cross water (POK-158 M4)?  The same rule the player
-- lives by -- somebody on the team knows SURF -- read as capability
-- from the team it built: a HEALTHY mon whose species takes HM03.  The
-- "taught ahead of time" half of the goal; a fainted swimmer carries
-- nobody, which is also the player's rule.
function Bots.canSurf(record, data)
  for _, m in ipairs(record or {}) do
    if (m.hpFrac or 0) > 0
       and Bots.canLearn(data and data.pokemon and data.pokemon[m.species],
                         "SURF") then
      return true
    end
  end
  return false
end

-- Is this record hurt enough that a trainer would walk to a Centre?
-- Half a team's worth of damage, or anything fainted -- a player limps
-- in earlier than that, but a bot that healed every scratch would never
-- be caught wounded, and being caught wounded is half the drama.
function Bots.wantsHeal(record)
  local n, total = 0, 0
  for _, m in ipairs(record or {}) do
    if (m.hpFrac or 0) <= 0 then return true end
    n = n + 1
    total = total + m.hpFrac
  end
  return n > 0 and (total / n) <= 0.5
end

-- The catch a grass dwell earns: a species off the map's own grass table
-- (data.encounters[map].grass.slots), the same table the player's
-- encounters roll on.  nil when the team is full, the map has no grass
-- table, or the roll misses -- a dwell is a hunt, not a vending machine.
function Bots.rollCatch(record, cap, slots, rng)
  if not (record and slots and #slots > 0) then return nil end
  if #record >= (cap or 1) then return nil end
  if rng() >= Bots.CATCH_CHANCE then return nil end
  local pick = slots[rng(1, #slots)]
  if not (pick and pick.species) then return nil end
  record[#record + 1] = { species = pick.species, hpFrac = 1 }
  return pick.species
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
