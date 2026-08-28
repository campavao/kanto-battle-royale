-- POK-158 M1: a bot BUILDS a team, and dies with the team it built.
--
-- A dozen bots, so the roam clock stays at its calm 25 seconds -- the
-- first cut used ONE bot, and two-alive is the endgame: an 8-second seam
-- clock that yanked the farmer off its map before any 6-second grass
-- dwell could finish.  One bot is parked on ROUTE_2 (intruders evicted),
-- its errands take it into the grass, and a grass dwell is a real catch
-- roll now.  Watch the record grow past its one drop mon, then fight it
-- and check the spill on the ground is the record -- every mon it
-- caught, plus the bag.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-career POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_career_smoke.lua \
--   <path to>/lovec . > career.log 2>&1
--
-- Exit 0 with a `CAREER OK` line passes; any `PVP FAIL` line fails.
-- The log should also carry the host's own `CAUGHT: <name> got <species>`
-- line -- the match log reading like a player's run is the whole point.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local FARM = "ROUTE_2"          -- grass, one seam from Pewter

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SCOUT")
  E.setSafari(0)
  E.setFog(600)                 -- no ring, so no hunt and no herding
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(12)                 -- alive stays over HUNT_FROM: 25s roams

  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end
  E.start()

  if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots in the match") end
  local victim = roster[1]
  local function botAt()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == victim.id then return b end
    end
    return nil
  end

  local rec0 = E.botRecord(victim.id)
  if not (rec0 and #rec0 == 1) then
    return C.fail("the record does not start at one mon (got "
      .. tostring(rec0 and #rec0) .. ")")
  end
  U.log(("CAREER: %s drops with one %s"):format(
    tostring(victim.name), tostring(rec0[1].species)))

  -- We idle in Pewter -- a different map, so the bot errands instead of
  -- stalking us -- and keep the farmer on its farm.
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  U.wait(30)
  local Spawn = require("mods.battle_royale.lib.spawn")
  local Bots = require("mods.battle_royale.lib.bots")
  -- plant it IN the grass: ROUTE_2 is split by Cut trees, and a random
  -- walkable cell can be in a pocket from which every grass goal is
  -- unreachable -- the first run farmed a fence line for four minutes
  local patch = Bots.grassCells(game.data.maps, game.data.tilesets, FARM)
  local cell = patch[math.floor(#patch / 2) + 1]
  if not cell then return C.fail("no grass to farm on " .. FARM) end
  local exile = (Spawn.pickIn(game.data.maps, game.data.tilesets, "ROUTE_13",
                              1, Spawn.rng(7)) or {})[1]
  E.debugPlaceBot(victim.id, FARM, cell.x, cell.y)

  -- the farm stays private: anybody who wanders onto it, or onto the map
  -- we idle on, is exiled before a fight or an engage can start
  local function evict()
    for _, b in ipairs(E.bots() or {}) do
      if b.id ~= victim.id and b.status == "alive" and exile
         and (b.map == FARM or b.map == C.map()) then
        E.debugPlaceBot(b.id, "ROUTE_13", exile.x, exile.y)
      end
    end
  end

  -- watch the team grow: a goal clock, a walk, six seconds in the grass
  -- and a coin per dwell -- minutes, not seconds
  local grown
  for i = 1, 480 do
    U.wait(30)
    evict()
    local b = botAt()
    if not b or b.status ~= "alive" then
      return C.fail("the farmer died farming")
    end
    if b.map ~= FARM then
      E.debugPlaceBot(victim.id, FARM, cell.x, cell.y)
    end
    local rec = E.botRecord(victim.id)
    if rec and #rec >= 2 then grown = rec break end
    if i % 60 == 0 then
      U.log(("CAREER: still hunting (%ds, %d mon)"):format(
        math.floor(i / 2), rec and #rec or 0))
    end
  end
  if not grown then
    return C.fail("four minutes in the grass and it caught nothing")
  end
  local species = {}
  for _, m in ipairs(grown) do species[#species + 1] = m.species end
  U.log(("CAREER: the team is now %s"):format(table.concat(species, ", ")))

  -- now the fight: stage it into a lane in Pewter and take it down
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 15) }
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)
  local ow = C.ow()
  local map = ow and ow.map
  if not map then return C.fail("no map to stage on") end
  local myMap, myX, myY = C.map(), C.x(), C.y()
  local function clear(x, y)
    return map:inBounds(x, y) and map:isWalkableCell(x, y)
  end
  local lane
  for _, d in ipairs({ { dx = 1, dy = 0 }, { dx = -1, dy = 0 },
                       { dx = 0, dy = 1 }, { dx = 0, dy = -1 } }) do
    for gap = 4, 3, -1 do
      local ok = true
      for step = 1, gap do
        if not clear(myX + d.dx * step, myY + d.dy * step) then ok = false break end
      end
      if ok then lane = { x = myX + d.dx * gap, y = myY + d.dy * gap } break end
    end
    if lane then break end
  end
  if not lane then return C.fail("no lane to stage the fight in") end

  local engaged = false
  for _ = 1, 60 do
    if E.status() == "battle" or E.walkUp() then engaged = true break end
    evict()
    E.debugPlaceBot(victim.id, myMap, lane.x, lane.y)
    for _ = 1, 15 do
      if E.status() == "battle" or E.walkUp() then engaged = true break end
      U.wait(4)
    end
    if engaged then break end
  end
  if not engaged then return C.fail("the fight never staged") end

  -- POK-158 M4: if the bag's TM fits anybody on the team, the fight has
  -- to open with the move already known.  (The taught mon may also know
  -- it naturally -- either way it must be on somebody's list.)
  local battle
  for _ = 1, 300 do
    local top = game.stack:top()
    if type(top) == "table" and top.enemyParty then battle = top break end
    U.wait(5)
  end
  if battle then
    local BotsLib = require("mods.battle_royale.lib.bots")
    local rec = E.botRecord(victim.id)
    local want
    for _, it in ipairs((rec and rec.bag and rec.bag.items) or {}) do
      local mv = BotsLib.tmMove(it.id)
      if mv and game.data.moves[mv] then
        for _, m in ipairs(battle.enemyParty) do
          if BotsLib.canLearn(game.data.pokemon[m.species], mv) then
            want = mv break
          end
        end
      end
      if want then break end
    end
    if want then
      local found = false
      for _, m in ipairs(battle.enemyParty) do
        for _, mv in ipairs(m.moves or {}) do
          if (type(mv) == "table" and mv.id or mv) == want then found = true end
        end
      end
      if not found then
        return C.fail(("its TM (%s) fits the team and was never taught")
          :format(want))
      end
      U.log("CAREER: it walked in knowing " .. want)
    else
      U.log("CAREER: no teachable TM this seed; teach unchecked")
    end
  end

  local doneIn
  for i = 1, 3000 do
    if E.status() ~= "battle" and not E.walkUp() and doneIn == nil then
      local b = botAt()
      if b and b.status == "out" then doneIn = i break end
    end
    U.tap(game, "a")
    U.wait(8)
  end
  local after = botAt()
  if not (after and after.status == "out") then
    return C.fail("the fight ended but the farmer is not out -- did we lose?")
  end
  for _ = 1, 40 do U.tap(game, "a") U.wait(10) end

  -- the ground holds the team it built: every mon, plus the bag
  U.wait(60)
  local S = E.spillState() or {}
  local balls, bag = 0, 0
  for key in pairs(S.balls or {}) do
    if key == victim.id .. ":bag" then bag = bag + 1
    elseif key:find("^" .. victim.id .. ":") then balls = balls + 1 end
  end
  if balls ~= #grown then
    return C.fail(("the spill has %d balls for a %d-mon record"):format(
      balls, #grown))
  end
  if bag ~= 1 then return C.fail("no bag in the spill") end
  U.log(("CAREER OK: caught its way to %d mons and dropped them all (%s)")
    :format(#grown, table.concat(species, ", ")))
  love.event.quit(0)
  U.wait(30)
end
