-- POK-182: a gift lands at the rung.
--
-- The engine's own giver, Commands.give_pokemon, is called the way the
-- Celadon mansion's script calls it: an EEVEE at level 25.  Outside a
-- match it arrives at 25, as the story wants.  Inside a match, at rung
-- 5, it arrives at 5 -- and so does an AERODACTYL at 30, the fossil
-- revival's level.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-gift POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/gift_rung_smoke.lua \
--   <path to>/lovec . > gift_rung.log 2>&1
--
-- Exit 0 with a `GIFT OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  local Commands = require("src.script.Commands")
  local function give(species, level)
    local ow = C.ow()
    local ctx = { game = game, save = game.save, overworld = ow }
    Commands.give_pokemon(ctx, species, level, true)
    local mon = game.save.party[#game.save.party]
    return mon and mon.species, mon and mon.level, ctx.addedToParty
  end

  -- outside a match: the story's level stands
  local sp, lv = give("EEVEE", 25)
  if sp ~= "EEVEE" or lv ~= 25 then
    return C.fail(("outside a match the EEVEE came at %s %s, wanted EEVEE 25"):format(tostring(sp), tostring(lv)))
  end
  U.log("GIFT: outside a match the Celadon EEVEE is level 25, as the story wants")

  E.setName("GIFTED")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(2)
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
  game.save.party = { Pokemon.new(game.data, "MACHOP", 5) }
  local rung = E.level()
  U.log(("GIFT: in the match at rung %d"):format(rung))

  sp, lv = give("EEVEE", 25)
  if sp ~= "EEVEE" or lv ~= rung then
    return C.fail(("in the match the EEVEE came at %s %s, wanted EEVEE %d"):format(tostring(sp), tostring(lv), rung))
  end
  U.log("GIFT: the EEVEE landed at the rung")
  sp, lv = give("AERODACTYL", 30)
  if sp ~= "AERODACTYL" or lv ~= rung then
    return C.fail(("the revived AERODACTYL came at %s %s, wanted %d"):format(tostring(sp), tostring(lv), rung))
  end
  U.log("GIFT: the AERODACTYL landed at the rung")
  -- a gift below the rung is left alone: the rung tick pulls it up itself
  sp, lv = give("MAGIKARP", 3)
  if sp ~= "MAGIKARP" or lv ~= 3 then
    return C.fail(("a level-3 MAGIKARP came at %s %s"):format(tostring(sp), tostring(lv)))
  end
  U.log("GIFT: a gift below the rung is untouched (the tick raises it)")
  U.log("GIFT OK: gifts land at the rung inside a match and at their level outside one")
  love.event.quit(0)
  U.wait(30)
end
