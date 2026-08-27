-- Every vanilla onStep in Kanto that takes the player rather than talking at
-- them: the cells where walking on triggers a scripted walk.
--
-- The rule this encodes, which is narrower than it first looks: a forced
-- BATTLE is fine in a match.  Gyms are contested bosses (POK-26), and Mt.
-- Moon's SUPER NERD at (13,8) and the DOJO master at (4,3) are deliberately
-- left exactly where vanilla put them -- being jumped by a trainer is the
-- game.  A scripted WALK is not: it is a movement lock while the ring closes
-- and other trainers hunt, and the player cannot answer it.  Nothing in this
-- table suppresses a battle that a player could have walked away from.
--
-- Kept here as data rather than inline in main.lua so tests/br_test.lua can
-- drive VANILLA's own handlers against it and prove the coordinates still
-- match what those handlers actually trigger on.  That check is the only
-- thing standing behind the four YELLOW rows: there is no Yellow ROM in the
-- dev setup, so unlike CERULEAN they cannot be smoke-tested end to end.  It
-- also catches the failure mode a cell list has forever after -- upstream
-- moves a trigger, nothing errors, and a cutscene quietly comes back.
--
-- Every entry is consulted only while a match is running.  Outside one this
-- mod is installed alongside real playthroughs and must leave Kanto exactly
-- as it found it, so main.lua checks BR:inSession() before asking.

local Lockstep = {}

-- The three cells-per-room below are the SHOVE, and only the shove.  Note
-- the condition in data/scripts/story4.lua e4ExitSeal reads
-- `if y < 10 or x < 4 or x > 5 then return false end` -- so it fires at
-- y >= 10, x in 4..5, which is the opposite of how POK-128 described it.
-- The rooms are 10x12 cells, so that is the four-cell mouth of the south
-- entrance: exactly the tiles a trainer backing out of the room stands on.
local function e4Mouth()
  return {
    ["4,10"] = true, ["5,10"] = true, ["4,11"] = true, ["5,11"] = true,
  }
end

Lockstep.CELLS = {
  -- POK-122.  Pewter's youngster stops a trainer heading east and walks
  -- them to the gym (data/scripts/story5.lua M.PEWTER_CITY), gated on
  -- EVENT_BEAT_BROCK -- a flag that can never be set in a match, because
  -- BROCK is a contested boss and his own talk branches on it too
  -- (data/scripts/gyms.lua PEWTER_GYM.talk).  Listing the flag in
  -- STORY_FLAGS would have handed every match a gym leader nobody can
  -- fight and a TM nobody can win, so the escort is headed off at its
  -- triggers instead.  It also arms from a conversation; see main.lua.
  PEWTER_CITY = {
    ["35,17"] = true, ["36,17"] = true, ["37,18"] = true, ["37,19"] = true,
  },

  -- POK-128.  The Elite Four rooms (data/scripts/story4.lua e4ExitSeal),
  -- deferred when the POK-126/127 sweep found them and picked up here.
  --
  -- Two locks per room, and they need different answers:
  --
  --   the SHOVE     backing toward the entrance prints "Don't run away!"
  --                 and walks the player one cell north with collide set.
  --                 A scripted walk the player cannot refuse -- these
  --                 cells.
  --   the WALK-IN   entering from the south runs scriptMove(player, "up",
  --                 6) once, gated on EVENT_AUTOWALKED_INTO_<ROOM>.  That
  --                 one is an onEnter, and map_scripts composes onEnter
  --                 ALL-RUN (src/script/MapScripts.lua) -- a mod cannot
  --                 consume it the way it can consume a step.  So it is
  --                 headed off by the flag instead, in main.lua's
  --                 STORY_FLAGS: the match save says the walk already
  --                 happened.
  --
  -- The E4 members themselves stay exactly where they are.  A forced
  -- BATTLE is fine in a match, which is the rule this whole table is
  -- narrower than it looks because of.
  LORELEIS_ROOM = e4Mouth(),
  BRUNOS_ROOM   = e4Mouth(),
  AGATHAS_ROOM  = e4Mouth(),

  -- POK-126.  Cerulean's Rocket thief (data/scripts/story5.lua
  -- M.CERULEAN_CITY) runs the longest of these: it turns the player,
  -- fights an OPP_ROCKET, hands over TM_DIG, then fades the screen out to
  -- swap three NPCs.  These two cells are the east exit toward Route 9.
  --
  -- BR already sets EVENT_BEAT_CERULEAN_RIVAL, so the rival ambush ten
  -- tiles west of here is dead; the thief on the same map was not.
  -- Setting his own flag is the wrong fix twice over --
  -- EVENT_BEAT_CERULEAN_ROCKET_THIEF makes rocketRows jump to row 10,
  -- which still awards the TM, and the fade it skips is what hides GUARD2.
  -- Heading the scene off instead leaves GUARD2 standing at (27,12), one
  -- blocked tile beside the trashed house's south door: a fair price for
  -- not being marched around mid-match, and BILL's ticket opens that route
  -- anyway (story.lua notes either is enough).  He also arms from a
  -- conversation; see main.lua.
  CERULEAN_CITY = { ["30,7"] = true, ["30,9"] = true },

  -- POK-127.  JESSIE and JAMES ambush a YELLOW player four times over
  -- (data/scripts/yellow_jessie_james.lua, attached by data/scripts/
  -- init.lua whenever GameVersion.isYellow()).  The manifest ships
  -- "games": ["gen1"] with no cartridge restriction and a real match has
  -- been played on YELLOW, so these are live rather than theoretical.
  --
  -- Each stops the music, walks the player a step, and starts a forced
  -- OPP_ROCKET at LEVEL 42 -- worse than Pewter's, which only cost the
  -- walk.  Three of the four ask for nothing but the tile and "not beaten
  -- yet", and they sit in ROCKET HIDEOUT, POKeMON TOWER and SILPH:
  -- exactly where a late ring puts everyone.
  --
  -- Listed for every cartridge rather than behind GameVersion.isYellow().
  -- On RED and BLUE nothing is attached to these cells at all, so
  -- consuming a step there changes no behaviour, and the base handlers
  -- that stay do not overlap -- MT_MOON_B2F's SUPER NERD is (13,8) and
  -- SILPH_CO_11F's GIOVANNI is (6,13)/(7,12), both kept on purpose.  The
  -- mod needs no opinion about which cartridge it is running on.
  --
  -- Unlike CERULEAN, onStep is the whole job: both are hidden objects
  -- until the scene reveals them, and their talk rows only print a line.
  MT_MOON_B2F        = { ["3,5"] = true },
  ROCKET_HIDEOUT_B4F = { ["24,14"] = true, ["25,14"] = true },
  POKEMON_TOWER_7F   = { ["10,12"] = true, ["11,12"] = true },
  SILPH_CO_11F       = {
    ["0,3"] = true, ["1,3"] = true, ["2,3"] = true, ["3,3"] = true,
  },
}

-- ------- what a suppressed scene was ALSO doing
--
-- Heading a scene off means inheriting its side effects, and POK-126
-- shipped without noticing one.  CERULEAN's thief does not only fight you:
-- the fade at the end of rocketRows swaps a pair of guards, and that swap
-- is load-bearing.  data/scripts/story.lua spells it out where BILL's
-- ticket does the identical swap:
--
--   "(27,12) is the ONLY walkable neighbour of the trashed house's south
--    door at (27,11), and that house is one of the two ways through the
--    fence that splits Cerulean in half (the badge house is the other).
--    Leaving GUARD2 up forever severs the city -- the gym/mart half can
--    never reach the Route 5 exit."
--
-- The first read of this called it "one blocked tile beside a house door,
-- not a route", which was wrong, and a player was stuck against the pair
-- with "The people here were robbed." within a day of the release.
--
-- Vanilla opens the path two ways -- the thief, or BILL's ticket -- and
-- both do the SAME swap, so applying it on entry is not an invention.  It
-- is the state every real playthrough reaches, reached without the
-- cutscene.  Written to save.objectToggles, which in a match is the
-- throwaway save, so nothing here follows anybody home.
Lockstep.REPAIRS = {
  CERULEAN_CITY = {
    show = { "CERULEANCITY_GUARD1" },   -- (28,12), the post-swap guard
    hide = { "CERULEANCITY_GUARD2" },   -- (27,12), the one severing the city
  },
}

-- True when this cell would start a scripted walk that a match should not
-- have to sit through.  Callers gate on BR:inSession() first.
function Lockstep.blocks(mapId, x, y)
  local cells = Lockstep.CELLS[mapId]
  return cells ~= nil and cells[x .. "," .. y] == true
end

return Lockstep
