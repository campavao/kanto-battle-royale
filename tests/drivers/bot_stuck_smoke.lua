-- POK-187 / POK-189: a bot never stands at a wall.
--
-- Two legs on one solo match, the player parked on a map of its own:
--
--   cliff  (POK-187)  two bots on ROUTE_4 either side of the Mt Moon
--          plaza's rock -- (80,10) and (81,13), four cells apart and no
--          route between them in either direction.  Each used to pick
--          the other as the nearest trainer on the map, find no path,
--          and take the greedy step at the rock for the rest of the
--          match.  Now the stalk writes the other off (`gaveUp` on the
--          bot export) and the errand list moves them on: within the
--          window both have given up and one of them has walked away.
--   lone   (POK-189)  one bot on ROUTE_1 (no Centre) with a single mon
--          at 55% and an empty bag.  Not hurt enough for the nurse, no
--          potion to drink, nobody in sight: the decision list must
--          still hand it an errand, and it must walk.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bot-stuck POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_stuck_smoke.lua \
--   <path to>/lovec . > bot_stuck.log 2>&1
--
-- Exit 0 with a `STUCK OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Spawn = require("mods.battle_royale.lib.spawn")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("REF")
  E.setSafari(0)
  E.setFog(600)
  E.setDebug(true)
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

  -- the referee stands in Cinnabar, off every bot's map
  U.teleport(game, "CINNABAR_ISLAND", 10, 10, "down")
  U.wait(30)

  local roster = E.bots() or {}
  if #roster < 3 then return C.fail("need three bots, have " .. #roster) end
  -- the fight probe carries the decision-list fields (goal, gaveUp, steps)
  local function botAt(id)
    local probe = E.debugFightProbe()
    for _, b in ipairs((probe and probe.bots) or {}) do if b.id == id then return b end end
  end
  local function far(id)
    E.debugPlaceBot(id, "PALLET_TOWN", 5, 5, "down")
  end

  -- ------- cliff
  local A, B, Z = roster[1], roster[2], roster[3]
  far(Z.id)
  E.debugPlaceBot(A.id, "ROUTE_4", 80, 10, "left")
  E.debugPlaceBot(B.id, "ROUTE_4", 81, 13, "left")
  U.wait(20)
  local t0 = love.timer.getTime()
  local gaveA, gaveB, walked = false, false, false
  while love.timer.getTime() - t0 < 40 do
    local a, b = botAt(A.id), botAt(B.id)
    if a and a.gaveUp then gaveA = true end
    if b and b.gaveUp then gaveB = true end
    if a and a.map == "ROUTE_4" and (math.abs(a.x - 80) + math.abs(a.y - 10)) >= 4 then walked = true end
    if b and b.map == "ROUTE_4" and (math.abs(b.x - 81) + math.abs(b.y - 13)) >= 4 then walked = true end
    if a and a.map ~= "ROUTE_4" then walked = true end
    if b and b.map ~= "ROUTE_4" then walked = true end
    if E.status() == "battle" then return C.fail("the referee got pulled into a fight") end
    if gaveA and gaveB and walked then break end
    U.wait(10)
  end
  local a, b = botAt(A.id), botAt(B.id)
  if not (gaveA and gaveB) then
    return C.fail(("across the cliff: gave up A=%s B=%s (A at %s,%s B at %s,%s)")
      :format(tostring(gaveA), tostring(gaveB), tostring(a and a.x), tostring(a and a.y),
              tostring(b and b.x), tostring(b and b.y)))
  end
  if not walked then
    return C.fail(("both wrote the other off but neither walked (A at %s,%s B at %s,%s)")
      :format(tostring(a and a.x), tostring(a and a.y), tostring(b and b.x), tostring(b and b.y)))
  end
  U.log(("STUCK: cliff -- both gave up; A at %s,%s B at %s,%s"):format(
    tostring(a and a.map .. " " .. a.x), tostring(a and a.y),
    tostring(b and b.map .. " " .. b.x), tostring(b and b.y)))

  -- ------- lone
  far(A.id) far(B.id)
  local data = game.data
  local sx, sy
  for y = 18, 30 do
    for x = 6, 14 do
      if not sx and Spawn.walkable(data.maps, data.tilesets, "ROUTE_1", x, y)
         and not Spawn.isWarp(data.maps, "ROUTE_1", x, y) then sx, sy = x, y end
    end
  end
  if not sx then return C.fail("no floor on ROUTE_1 to stage on") end
  E.debugBotTrim(Z.id, 1)
  E.debugScarBot(Z.id, 0.55)
  E.debugBotBag(Z.id, {}, 0)
  E.debugPlaceBot(Z.id, "ROUTE_1", sx, sy, "down")
  U.wait(20)
  local z0 = botAt(Z.id)
  local steps0 = z0 and z0.steps or 0
  t0 = love.timer.getTime()
  local goal, moved = nil, false
  while love.timer.getTime() - t0 < 30 do
    local z = botAt(Z.id)
    if z then
      goal = goal or z.goal
      if (z.steps or 0) - steps0 >= 4 then moved = true end
    end
    if goal and moved then break end
    U.wait(10)
  end
  local z = botAt(Z.id)
  local rec = E.botRecord(Z.id)
  if not (rec and #rec == 1 and (rec[1].hpFrac or 1) < 0.6) then
    return C.fail("the lone hurt mon was not staged (" .. tostring(rec and #rec) .. " mons)")
  end
  if not goal then
    return C.fail(("the lone bot picked no errand in 30s (at %s,%s, %d steps)")
      :format(tostring(z and z.x), tostring(z and z.y), (z and z.steps or 0) - steps0))
  end
  if not moved then
    return C.fail(("the lone bot chose %s but walked %d steps in 30s")
      :format(tostring(goal), (z and z.steps or 0) - steps0))
  end
  U.log(("STUCK: lone -- %s chose %s and walked %d steps"):format(
    tostring(Z.name), tostring(goal), (z and z.steps or 0) - steps0))
  U.log("STUCK OK: neither the cliff nor the lone wound left a bot standing")
  love.event.quit(0)
  U.wait(30)
end
