-- U.newGame lands in the overworld, fast, with a real name.
--
-- The pin exists because the helper used to do none of those three. It
-- mashed A through the splash, the title, Oak's speech and both naming
-- screens: 1483 frames (8.3s at POKEPORT_SPEED=3), it ran out of taps with
-- OakSpeech still on top, and A is a letter on the naming grid as well as
-- the confirm button, so every driver in the tree ran as a player called
-- AAAAAAA. Anything that walks the boot screens again will trip these.

local U = require("tests.drivers.util")

return function(game)
  local fails = 0
  local function check(label, ok, detail)
    U.log((ok and "PASS " or "FAIL ") .. label, detail or "")
    if not ok then fails = fails + 1 end
  end

  local f0, t0 = U.frame(), love.timer.getTime()
  U.newGame(game)
  local frames, wall = U.frame() - f0, love.timer.getTime() - t0
  local p = game.save and game.save.player

  check("lands in the overworld", game.stack:top() == game.overworld,
        tostring(game.stack:top()))
  check("under 100 frames", frames < 100, frames .. " frames")
  check("under 1s wall", wall < 1.0, ("%.2fs"):format(wall))
  check("named from field.boot, not mashed", p and p.name == "RED",
        tostring(p and p.name))
  check("rival named too", p and p.rival == "BLUE", tostring(p and p.rival))
  check("spawned at the boot cell", p and p.map == "REDS_HOUSE_2F",
        ("%s %s,%s"):format(tostring(p and p.map), tostring(p and p.x),
                            tostring(p and p.y)))

  -- save.created still fires on this path, which is what mods hang boot work
  -- on; the mod being reachable at all is the observable half of that.
  local E = game.mods and game.mods.exports and game.mods.exports.battle_royale
  check("mod exports are live", E ~= nil and E.phase() == "off",
        tostring(E and E.phase()))

  U.log(fails == 0 and "BOOT OK" or ("BOOT FAIL: " .. fails .. " checks"))
  love.event.quit(fails == 0 and 0 or 1)
end
