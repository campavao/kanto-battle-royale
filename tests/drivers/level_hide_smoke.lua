-- RFC 0019 in the mod: no level on any screen during a round.
--
-- Asks the engine's own seam (src/ui/LevelDisplay.visible) directly --
-- the same call every printing surface makes -- outside a session and
-- then inside a match, for all four surfaces.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-level-hide POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/level_hide_smoke.lua \
--   <path to>/lovec . > level_hide.log 2>&1
--
-- Exit 0 with a `LEVELS OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local WHERE = { "battle.enemy", "battle.player", "party", "summary" }

return function(game)
  local C = L.ctx(game)
  local LevelDisplay = require("src.ui.LevelDisplay")
  local mon = { level = 5 }

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  for _, w in ipairs(WHERE) do
    if LevelDisplay.visible(mon, w, game) ~= true then
      return C.fail("level hidden OUTSIDE a session on " .. w)
    end
  end
  U.log("LEVELS: all four surfaces print outside a session")

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

  for _, w in ipairs(WHERE) do
    if LevelDisplay.visible(mon, w, game) ~= false then
      return C.fail("level still printing IN a match on " .. w)
    end
  end
  U.log("LEVELS OK: all four surfaces blank during the match")
  love.event.quit(0)
  U.wait(30)
end
