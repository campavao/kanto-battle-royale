-- POK-151: at four or fewer alive, the last trainers show on the town map.
--
-- A smoke, not a pixel test: a match with three bots (four trainers) is
-- under the threshold from the buzzer, so opening the town map exercises
-- the marker pass -- including the no-ring branch, since the fog is held
-- off -- and a screenshot lands in BR_SHOTS for eyes.  The driver fails
-- on any tick error or a map screen that never opens.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-map-marks POKEPORT_SPEED=3 BR_SHOTS=<dir> \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/map_marks_smoke.lua \
--   <path to>/lovec . > map_marks.log 2>&1
--
-- Exit 0 with a `MARKS OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")

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

  if (E.aliveCount() or 99) > 4 then
    return C.fail("roster too big for the threshold: " .. tostring(E.aliveCount()))
  end

  local ok, err = pcall(function()
    require("src.ui.Screens").push(game, "TownMap")
  end)
  if not ok then return C.fail("could not open the town map: " .. tostring(err)) end
  -- hold it open across several blink cycles so the marker pass runs both
  -- halves of its clock
  for i = 1, 90 do
    U.wait(3)
    local e = E.tickError()
    if e then return C.fail("tick error with the map open: " .. tostring(e)) end
    -- two shots half a blink apart, so one of them catches the markers lit
    if i == 30 and SHOTS then U.shot(game, SHOTS .. "/town_map_marks_a.png") end
    if i == 60 and SHOTS then U.shot(game, SHOTS .. "/town_map_marks_b.png") end
  end
  local top = game.stack:top()
  if not top or top == C.ow() then
    return C.fail("the town map did not stay open")
  end
  U.log(("MARKS OK: map held open at %d alive with no render errors")
    :format(E.aliveCount() or -1))
  love.event.quit(0)
  U.wait(30)
end
