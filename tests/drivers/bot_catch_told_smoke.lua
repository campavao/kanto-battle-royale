-- POK-188: a spectator is told what the watched bot caught.
--
-- A bot's wild encounter is a roll, not a fight, so there is nothing for
-- the mirror to replay: the watcher saw the ! over its head, six seconds
-- of nothing, and the walk on.  Now the catch is said on the watcher's
-- screen -- "KAI caught PIDGEY!" -- the moment the roll lands.
--
-- The host goes out at the drop, turns the camera on one bot with a
-- single mon (room to catch), and parks it on ROUTE_1's grass.  Every
-- grass dwell is a roll; the driver waits for the first catch and reads
-- the line the spectator was shown (mod.exports.catchTold).
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-catch-told POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_catch_told_smoke.lua \
--   <path to>/lovec . > bot_catch_told.log 2>&1
--
-- Exit 0 with a `TOLD OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("REF")
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

  local roster = E.bots() or {}
  if #roster < 2 then return C.fail("need bots, have " .. #roster) end
  local X = roster[1]
  -- the others far apart from each other and from X, so no duel ends
  -- the match under the camera
  local PARK = { { "CINNABAR_ISLAND", 10, 10 }, { "LAVENDER_TOWN", 5, 8 },
                 { "FUCHSIA_CITY", 10, 10 } }
  local function park()
    for i = 2, #roster do
      local spot = PARK[((i - 2) % #PARK) + 1]
      local b
      for _, r in ipairs(E.bots() or {}) do if r.id == roster[i].id then b = r end end
      if b and b.status == "alive" and b.map ~= spot[1] then
        E.debugPlaceBot(roster[i].id, spot[1], spot[2], spot[3], "down")
      end
    end
  end
  park()
  E.debugBotTrim(X.id, 1)

  -- out, and watching X
  if not E.debugOut("told") then return C.fail("debugOut refused") end
  for _ = 1, 10 do U.tap(game, "a") U.wait(15) end
  local watching = false
  for _ = 1, 8 do
    if E.watching() == X.id then watching = true break end
    E.hop(1)
    U.wait(20)
  end
  if not watching then return C.fail("could not turn the camera on " .. tostring(X.name)) end
  U.log(("TOLD: watching %s (%d mon)"):format(tostring(X.name), #(E.botRecord(X.id) or {})))

  -- into the grass, and wait for the first catch
  local data = game.data
  local grass = Bots.grassCells(data.maps, data.tilesets, "ROUTE_1")
  if #grass == 0 then return C.fail("ROUTE_1 has no grass?") end
  local g = grass[math.floor(#grass / 2)]
  E.debugPlaceBot(X.id, "ROUTE_1", g.x, g.y, "down")
  local t0 = love.timer.getTime()
  local told
  local lastPlace = t0
  while love.timer.getTime() - t0 < 240 do
    told = E.catchTold()
    if told then break end
    -- keep it on the route: a seam walk would take it off the grass
    local b
    for _, r in ipairs(E.bots() or {}) do if r.id == X.id then b = r end end
    if b and b.map ~= "ROUTE_1" and love.timer.getTime() - lastPlace > 5 then
      E.debugPlaceBot(X.id, "ROUTE_1", g.x, g.y, "down")
      lastPlace = love.timer.getTime()
    end
    park()
    if E.phase() ~= "match" then
      return C.fail("the match ended under the camera (phase " .. tostring(E.phase()) .. ")")
    end
    local e = E.tickError()
    if e then return C.fail("tick error: " .. tostring(e)) end
    U.tap(game, "a")   -- keep the spectator's text moving
    U.wait(15)
  end
  if not told then
    return C.fail(("four minutes in the grass and no catch line was shown (%d mons)")
      :format(#(E.botRecord(X.id) or {})))
  end
  if not told:find(tostring(X.name), 1, true) then
    return C.fail("the line names someone else: " .. told:gsub("\n", " "))
  end
  U.log(("TOLD OK: the spectator was shown '%s'"):format(told:gsub("\n", " ")))
  love.event.quit(0)
  U.wait(30)
end
