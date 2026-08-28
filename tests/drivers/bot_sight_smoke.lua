-- POK-149: a bot can spot YOU, and the walk-up finally has room to show.
--
-- Every bot fight used to start from the player's own eyeline only, which
-- needs the player standing still and facing the bot -- and a hunting bot
-- has closed to adjacent by the time that is true, so the walk-up beat
-- (POK-85) was built for a range nobody ever engaged at.  Now a bot whose
-- facing crosses the player calls the fight like a route trainer.
--
-- Staged so OUR eyeline cannot be the trigger: the player faces one way,
-- the bot is planted off that axis with its own sight line crossing us.
-- The engage that follows can only be the bot's.  Then the stride has to
-- actually happen: steps counted, distance closed, battle opened.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bot-sight POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_sight_smoke.lua \
--   <path to>/lovec . > bot_sight.log 2>&1
--
-- Exit 0 with a `SIGHT OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")

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

  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  U.wait(30)
  local ow = C.ow()
  local map = ow and ow.map
  if not map then return C.fail("no map to stage on") end

  -- Find a post with a clear column ABOVE it: the bot lands up there
  -- facing down (the only facing debugPlaceBot deals), so ITS line
  -- crosses us and ours -- facing east -- misses it.
  local post, gap
  for _, x in ipairs({ 16, 15, 17, 14, 18, 13, 19, 12, 20, 11, 21 }) do
    for g = 3, 2, -1 do
      local ok = map:inBounds(x, 18) and map:isWalkableCell(x, 18)
      for step = 1, g do
        if not (map:inBounds(x, 18 - step)
                and map:isWalkableCell(x, 18 - step)) then
          ok = false break
        end
      end
      if ok then post, gap = x, g break end
    end
    if post then break end
  end
  if not post then return C.fail("no post with a clear column above it") end
  if not L.goTo(C, "PEWTER_CITY", post, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)

  -- face EAST, then take our real position: a held direction can also step
  for _ = 1, 20 do
    if ow.player.facing == "right" then break end
    U.hold(game, "right", 2)
    U.wait(8)
  end
  if ow.player.facing ~= "right" then
    return C.fail("could not face east (facing " .. tostring(ow.player.facing) .. ")")
  end
  local myMap, myX, myY = C.map(), C.x(), C.y()
  local bx, by = myX, myY - gap
  U.log(("SIGHT: posted at %d,%d facing right; bot goes to %d,%d looking down")
    :format(myX, myY, bx, by))

  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots in the match") end
  local victim = roster[1]
  local function botAt()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == victim.id then return b end
    end
    return nil
  end

  -- hold it on the spot until its sight takes; the roam can walk it off
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
    local b = botAt()
    return C.fail(("its sight never took (bot %s,%s me %s,%s facing %s)")
      :format(tostring(b and b.x), tostring(b and b.y),
              tostring(C.x()), tostring(C.y()), tostring(ow.player.facing)))
  end
  if ow.player.facing == "up" then
    return C.fail("we ended up facing it -- the test proved nothing")
  end
  U.log(("SIGHT: %s spotted us from %d away while we faced %s"):format(
    tostring(victim.name), gap, tostring(ow.player.facing)))

  -- the stride: steps counted, distance closed, fight opened
  local sawStride, started, closest = false, false, gap
  for _ = 1, 600 do
    local w = E.walkUp()
    if w and (w.steps or 0) > 0 then sawStride = true end
    local b = botAt()
    if b and b.map == myMap then
      local d = math.abs(b.x - (C.x() or myX)) + math.abs(b.y - (C.y() or myY))
      if d < closest then closest = d end
    end
    if E.status() == "battle" then started = true break end
    U.wait(3)
  end
  if not started then
    return C.fail(("it saw us but the fight never started (closest %d, stride %s)")
      :format(closest, tostring(sawStride)))
  end
  if gap > 1 and not sawStride then
    return C.fail(("no walk over: it fought from range %d"):format(gap))
  end
  U.log(("SIGHT OK: %s called it from %d, walked in to %d, and the fight opened")
    :format(tostring(victim.name), gap, closest))
  love.event.quit(0)
  U.wait(30)
end
