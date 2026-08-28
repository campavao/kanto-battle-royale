-- POK-154: a beaten bot's loot drops where you fought it.
--
-- The bot you were fighting kept roaming behind the battle screen -- the
-- walk-up exclusion let go the moment the battle opened -- so by the win
-- its tracked position was a seam away and the spill landed on a map the
-- winner was not on.  ("I was in Saffron ... found this bag from CALVIN1"
-- on the route toward Lavender.)
--
-- Stage an engage the way bot_smoke does, then check three things:
--
--   1. the bot HOLDS STILL for the whole battle (the roam exclusion),
--   2. beating it leaves its spill on the fight's own map, beside us, and
--   3. the elimination writes the OUT log line the inlined player-win
--      path used to drop (grep the log for `OUT:` after the run).
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-spill-place POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/spill_place_smoke.lua \
--   <path to>/lovec . > spill_place.log 2>&1
--
-- Exit 0 with a `SPILL OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SCOUT")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(3)

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

  -- The test is where the loot lands, not whether we can win a coin flip:
  -- a rung-level lead lost the first run to a rung-level RATTATA and the
  -- spill assertion never ran.  Stage a lead that wins on stats (the
  -- gc_grunt_freeze_probe precedent) -- the spill is seeded from the BOT,
  -- so our own party changes nothing being measured.
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 15) }

  -- Pewter's street: the same clear eyeline bot_smoke borrows.
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)
  local ow = C.ow()
  local myMap, myX, myY = C.map(), C.x(), C.y()

  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots in the match") end
  local victim = roster[1]
  local function botAt()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == victim.id then return b end
    end
    return nil
  end

  -- the lane staging, straight from bot_smoke
  local map = ow and ow.map
  if not map then return C.fail("no map to stage on") end
  local function clear(x, y)
    return map:inBounds(x, y) and map:isWalkableCell(x, y)
  end
  local DIRS = {
    { dir = "right", dx = 1,  dy = 0,  reach = 6 },
    { dir = "left",  dx = -1, dy = 0,  reach = 6 },
    { dir = "down",  dx = 0,  dy = 1,  reach = 4 },
    { dir = "up",    dx = 0,  dy = -1, reach = 4 },
  }
  local function laneFor(d, fx, fy)
    for gap = math.min(5, d.reach), 3, -1 do
      local ok = true
      for step = 1, gap do
        if not clear(fx + d.dx * step, fy + d.dy * step) then ok = false break end
      end
      if ok then return gap end
    end
    return nil
  end
  local facing = ow.player and ow.player.facing
  local lane
  for _, d in ipairs(DIRS) do
    if d.dir == facing then
      local gap = laneFor(d, myX, myY)
      if gap then lane = { d = d, gap = gap } end
    end
  end
  if not lane then
    for _, d in ipairs(DIRS) do
      if laneFor(d, myX, myY) then
        for _ = 1, 20 do
          if ow.player.facing == d.dir then break end
          U.hold(game, d.dir, 2)
          U.wait(8)
        end
        break
      end
    end
    myX, myY = C.x() or myX, C.y() or myY
    facing = ow.player and ow.player.facing
    for _, d in ipairs(DIRS) do
      if d.dir == facing then
        local gap = laneFor(d, myX, myY)
        if gap then lane = { d = d, gap = gap } end
      end
    end
  end
  if not lane then
    return C.fail(("no clear eyeline from %s,%s facing %s on %s"):format(
      tostring(myX), tostring(myY), tostring(facing), tostring(myMap)))
  end
  local bx = myX + lane.d.dx * lane.gap
  local by = myY + lane.d.dy * lane.gap

  local engaged = false
  for _ = 1, 40 do
    if E.status() == "battle" or E.walkUp() then engaged = true break end
    E.debugPlaceBot(victim.id, myMap, bx, by)
    for _ = 1, 15 do
      if E.status() == "battle" or E.walkUp() then engaged = true break end
      U.wait(4)
    end
    if engaged then break end
  end
  if not engaged then
    return C.fail(("the eyeline never caught it (status %s)"):format(
      tostring(E.status())))
  end

  -- let the walk-up finish and the battle open
  local opened = false
  for _ = 1, 600 do
    if E.status() == "battle" then opened = true break end
    U.wait(3)
  end
  if not opened then return C.fail("the fight never started") end

  -- 1. the freeze: the bot we are fighting stands its ground.  Pre-fix it
  -- resumed roaming the moment the battle opened -- several steps inside
  -- five seconds -- because only the walk-up was excluded from the roam.
  local at0 = botAt()
  if not at0 then return C.fail("the victim vanished at the gong") end
  local fightMap, fightX, fightY = at0.map, at0.x, at0.y
  U.log(("SPILL: fighting %s at %s %d,%d"):format(
    tostring(victim.name), tostring(fightMap), fightX, fightY))
  for _ = 1, 10 do
    U.wait(30)
    if E.status() ~= "battle" then break end   -- the fight can end quickly
    local b = botAt()
    if b and (b.map ~= fightMap or b.x ~= fightX or b.y ~= fightY) then
      return C.fail(("it wandered mid-battle: %s %d,%d -> %s %d,%d"):format(
        tostring(fightMap), fightX, fightY, tostring(b.map), b.x, b.y))
    end
  end

  -- 2. win it.  Mash A: FIGHT, first move, every text box.  Rung-level
  -- starter versus a rung-level common mon; if we somehow white out, say
  -- so plainly rather than passing on nothing.
  local doneIn
  for i = 1, 2000 do
    if E.status() ~= "battle" then doneIn = i break end
    U.tap(game, "a")
    U.wait(8)
  end
  if not doneIn then return C.fail("the battle never resolved") end
  local after = botAt()
  if not (after and after.status == "out") then
    return C.fail(("the battle ended but %s is not out (status %s) -- "
      .. "did we lose?"):format(tostring(victim.name),
                                tostring(after and after.status)))
  end
  for _ = 1, 40 do U.tap(game, "a") U.wait(10) end   -- the You beat X! box

  -- 3. the spill sits where the fight was, on OUR map, beside us
  U.wait(60)
  local S = E.spillState() or {}
  local ours, strays, sample = 0, 0, nil
  for key, ball in pairs(S.balls or {}) do
    if key:find("^" .. victim.id .. ":") then
      ours = ours + 1
      sample = sample or ball
      local d = math.abs(ball.x - fightX) + math.abs(ball.y - fightY)
      if ball.map ~= fightMap or d > 4 then
        strays = strays + 1
        U.log(("SPILL: stray ball %s at %s %d,%d (fight was %s %d,%d)")
          :format(key, tostring(ball.map), ball.x, ball.y,
                  tostring(fightMap), fightX, fightY))
      end
    end
  end
  if ours == 0 then return C.fail("no spill at all from the beaten bot") end
  if strays > 0 then
    return C.fail(("%d of %d spill pieces landed away from the fight"):format(
      strays, ours))
  end
  local spawnedHere = 0
  for key in pairs(S.spawned or {}) do
    if key:find("^" .. victim.id .. ":") then spawnedHere = spawnedHere + 1 end
  end
  if spawnedHere == 0 then
    return C.fail("the spill exists but nothing spawned on the map we stand on")
  end
  U.log(("SPILL OK: %s's %d pieces on %s around %d,%d (%d spawned in view)")
    :format(tostring(victim.name), ours, tostring(sample and sample.map),
            fightX, fightY, spawnedHere))
  love.event.quit(0)
  U.wait(30)
end
