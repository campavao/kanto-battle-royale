-- POK-166: the "?" over a trainer's head sits over THAT trainer.
--
-- A bot is placed a cell up and to the right of the player, marked as
-- being in a menu, and the frame is captured.  The judgement is the
-- picture (BR_SHOTS=<dir>): the bubble has to sit one tile above the bot's
-- sprite, not floating two tiles off it.  The numbers behind it are logged
-- too -- the world view's size, and where the sprite and the mark land on
-- the 160x144 canvas -- so a wrong picture comes with its arithmetic.
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   BR_SHOTS=<dir> POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bubble POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bubble_shot_smoke.lua \
--   <path to>/lovec . > bubble.log 2>&1
--
-- Exit 0 with a `BUBBLE OK` line passes; any `PVP FAIL` line fails.

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

  -- Pewter's open street, facing DOWN so no eyeline crosses the bot
  U.teleport(game, "PEWTER_CITY", 13, 19, "down")
  U.wait(30)
  local ps = E.players() or {}
  local bot = ps[1] and ps[1].id
  if not bot then return C.fail("no bot to mark") end
  E.debugPlaceBot(bot, "PEWTER_CITY", 14, 18)
  -- a bot's own roam clears a mark it did not make, so keep it on until
  -- the frame is captured
  for _ = 1, 120 do
    E.debugBusy(bot, "menu")
    U.wait(1)
  end
  E.debugBusy(bot, "menu")
  local ps2 = E.players() or {}
  if not (ps2[1] and ps2[1].busy == "menu") then
    return C.fail("the bot's mark did not hold: " .. tostring(ps2[1] and ps2[1].busy))
  end

  local probe = E.markProbe(bot)
  if not probe then return C.fail("the bot's ghost is not drawn") end
  U.log(("BUBBLE: world view %dx%d; sprite at (%.0f,%.0f) on the canvas, mark at (%.0f,%.0f)")
    :format(probe.vw, probe.vh, probe.spriteX, probe.spriteY, probe.mx, probe.my))
  -- the mark is the engine's own slot off the sprite: +4, -14
  if math.abs((probe.mx - probe.spriteX) - 4) > 0.5
     or math.abs((probe.my - probe.spriteY) + 14) > 0.5 then
    return C.fail("the mark is not the bubble slot off the sprite")
  end
  if SHOTS then
    E.debugBusy(bot, "menu")
    if not U.shot(game, SHOTS .. "/bubble.png") then
      return C.fail("the screenshot did not land")
    end
    U.log("BUBBLE: captured " .. SHOTS .. "/bubble.png")
  end
  U.log("BUBBLE OK: the mark sits in the bubble slot over the sprite on this canvas")
  love.event.quit(0)
  U.wait(10)
end
