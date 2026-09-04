-- POK-169/170: text never parks a match -- three seconds a box, no input.
--
-- Two surfaces, both measured with NO button pressed after the first A:
--
--   1. a sign on the overworld (the runner): A opens it, and the text
--      has to close by itself within a few boxes' worth of three seconds;
--   2. a bot battle's intro text: the "!" walk-up opens the fight, and the
--      battle has to reach the move menu on its own -- the intro's boxes
--      pressed through with B by the watchdog, never A (POK-66).
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-autoadvance POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/autoadvance_smoke.lua \
--   <path to>/lovec . > autoadvance.log 2>&1
--
-- Exit 0 with an `AUTO OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local function wall() return love.timer.getTime() end

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
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 20) }

  -- ------- 1. the sign
  U.teleport(game, "PEWTER_CITY", 11, 18, "up")
  U.wait(30)
  local ow = C.ow()
  local function reading()
    return (ow.runner and ow.runner.isRunning and ow.runner:isRunning()) or C.busy()
  end
  U.tap(game, "a")
  U.wait(5)
  if not reading() then return C.fail("A on the sign opened nothing") end
  local t0 = wall()
  local closed = false
  while (wall() - t0) < 20 do
    if not reading() then closed = true break end
    U.wait(1)
  end
  local took = wall() - t0
  if not closed then return C.fail("the sign text never advanced by itself") end
  U.log(("AUTO: the sign closed after %.1fs with no input"):format(took))
  if took < 2.5 then return C.fail("too fast to be the three-second ceiling") end
  if took > 10 then return C.fail("too slow: more than three boxes' worth") end

  -- ------- 2. a bot battle's intro
  local ps = E.players() or {}
  local bot = ps[1] and ps[1].id
  if not bot then return C.fail("no bot to fight") end
  E.debugPlaceBot(bot, C.map(), C.x() + 2, C.y())
  U.wait(30)
  U.hold(game, "right", 4)   -- face it: the eyeline calls the fight
  local opened = false
  t0 = wall()
  while (wall() - t0) < 40 do
    local top = game.stack:top()
    if type(top) == "table" and top.enemyParty then opened = true break end
    U.wait(1)
  end
  if not opened then
    return C.fail("the bot fight never opened (status " .. tostring(E.status()) .. ")")
  end
  U.log("AUTO: the bot fight is open; waiting for the move menu with no input")
  local atMenu = false
  t0 = wall()
  while (wall() - t0) < 45 do
    local top = game.stack:top()
    if type(top) == "table" and top.enemyParty and top.phase == "menu" then
      atMenu = true
      break
    end
    U.wait(1)
  end
  took = wall() - t0
  if not atMenu then
    local top = game.stack:top()
    return C.fail(("the intro never reached the move menu by itself (phase %s after %.0fs)")
      :format(tostring(type(top) == "table" and top.phase), took))
  end
  U.log(("AUTO: the move menu came up %.1fs after the fight opened, unaided"):format(took))
  U.log("AUTO OK: a sign and a battle intro both advanced on their own")
  love.event.quit(0)
  U.wait(10)
end
