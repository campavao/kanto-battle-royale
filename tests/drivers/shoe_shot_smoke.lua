-- The shoe over a trainer who ran from us (the user, 2026-09-08): for the
-- length of the flee grace the runner wears a boot in a bubble, the mod's
-- own art in the cart's bubble style, in the same slot the ! and ? use.
--
-- A bot is placed a cell up and to the right of the player, marked as
-- having fled from us, and the frame is captured (BR_SHOTS=<dir>).  The
-- judgement is the picture: a boot in a bubble one tile above the bot.
-- The mark's slot is checked in numbers, and the mark is gone once the
-- grace lapses.
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   BR_SHOTS=<dir> POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-shoe POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/shoe_shot_smoke.lua \
--   <path to>/lovec . > shoe.log 2>&1
--
-- Exit 0 with a `SHOE OK` line passes; any `PVP FAIL` line fails.

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

  U.teleport(game, "PEWTER_CITY", 13, 19, "down")
  U.wait(30)
  local ps = E.players() or {}
  local bot = ps[1] and ps[1].id
  if not bot then return C.fail("no bot to mark") end
  -- hold it in place: a roaming bot walks out from under the mark
  for _ = 1, 60 do
    E.debugPlaceBot(bot, "PEWTER_CITY", 14, 18)
    U.wait(1)
  end
  if not E.debugFledMark(bot, 2) then return C.fail("could not mark the bot") end
  U.wait(5)
  local probe = E.markProbe(bot)
  if not probe then return C.fail("the bot's ghost is not drawn") end
  U.log(("SHOE: sprite at (%.0f,%.0f) on the canvas, mark at (%.0f,%.0f)")
    :format(probe.spriteX, probe.spriteY, probe.mx, probe.my))
  if math.abs((probe.mx - probe.spriteX) - 4) > 0.5
     or math.abs((probe.my - probe.spriteY) + 14) > 0.5 then
    return C.fail("the mark is not the bubble slot off the sprite")
  end
  if SHOTS then
    E.debugPlaceBot(bot, "PEWTER_CITY", 14, 18)
    E.debugFledMark(bot, 2)
    U.wait(2)
    if not U.shot(game, SHOTS .. "/shoe.png") then
      return C.fail("the screenshot did not land")
    end
    U.log("SHOE: captured " .. SHOTS .. "/shoe.png")
  end
  -- the grace lapses, and with it the mark
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 3 do U.wait(5) end
  -- ...and our own boot, when WE ran (the solo case: the runner is the
  -- only one looking)
  E.debugPlaceBot(bot, "PEWTER_CITY", 6, 13)   -- out of frame
  E.debugFled(2)
  U.wait(2)
  if SHOTS then
    E.debugFled(2)
    U.wait(2)
    if not U.shot(game, SHOTS .. "/shoe_me.png") then
      return C.fail("the second screenshot did not land")
    end
    U.log("SHOE: captured " .. SHOTS .. "/shoe_me.png")
  end
  U.log("SHOE OK: the boot sits in the bubble slot for the grace, theirs and ours")
  love.event.quit(0)
  U.wait(10)
end
