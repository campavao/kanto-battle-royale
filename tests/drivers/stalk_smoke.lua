-- POK-153: same-map prey is walked down at cell grain.
--
-- The hunt used to hand same-map prey to the greedy Bots.wander(toward),
-- which paces at the first ledge or fence -- a spectator at three-left
-- watched a bot cycle one patch of route indefinitely.  stepBotHunt walks
-- a real BFS path now, so a bot planted far away on our map must close
-- the whole distance and end adjacent or in a fight.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-stalk POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/stalk_smoke.lua \
--   <path to>/lovec . > stalk.log 2>&1
--
-- Exit 0 with a `STALK OK` line passes; any `PVP FAIL` line fails.

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
  E.setBots(1)

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

  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)
  local ow = C.ow()
  local map = ow and ow.map
  if not map then return C.fail("no map to stage on") end
  local myMap, myX, myY = C.map(), C.x(), C.y()

  -- somewhere FAR on this map: past every eyeline, so the whole approach
  -- runs on the stalk and nothing else
  local far
  for r = 14, 8, -1 do
    for _, c in ipairs({ { myX + r, myY }, { myX - r, myY },
                         { myX + r, myY - 2 }, { myX - r, myY - 2 },
                         { myX, myY + r }, { myX, myY - r } }) do
      if map:inBounds(c[1], c[2]) and map:isWalkableCell(c[1], c[2]) then
        far = { x = c[1], y = c[2], d = r }
        break
      end
    end
    if far then break end
  end
  if not far then return C.fail("nowhere far to plant the bot") end

  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots in the match") end
  local victim = roster[1]
  if not E.debugPlaceBot(victim.id, myMap, far.x, far.y) then
    return C.fail("could not plant the bot")
  end
  U.log(("STALK: %s planted %d cells out at %d,%d; standing still"):format(
    tostring(victim.name), far.d, far.x, far.y))

  local function botAt()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == victim.id then return b end
    end
    return nil
  end

  -- Watch it come.  BOT_STEP_SECONDS is well under a second, so even with
  -- the wobble the whole walk is half a minute; three minutes is a pace
  -- verdict, not a patience problem.
  local closest, arrived = far.d, false
  for _ = 1, 360 do
    U.wait(30)
    if E.status() == "battle" or E.walkUp() then arrived = true break end
    local b = botAt()
    if b and b.map == myMap then
      local d = math.abs(b.x - (C.x() or myX)) + math.abs(b.y - (C.y() or myY))
      if d < closest then closest = d end
      if d <= 2 then arrived = true break end
    end
  end
  if not arrived then
    return C.fail(("it paced: started %d out, never got past %d"):format(
      far.d, closest))
  end
  U.log(("STALK OK: closed from %d to %s"):format(far.d,
    E.status() == "battle" and "a fight" or "adjacent"))
  love.event.quit(0)
  U.wait(30)
end
