-- POK-172: the rung never takes a TM move away.
--
-- A RATTATA with two level-up moves and two taught ones rides the fog's
-- first shrink to rung 15.  The rung teaches QUICK ATTACK (7) and HYPER
-- FANG (14); the engine's own routine would have dropped the oldest slots
-- -- one of them THUNDERBOLT.  Now the level-up moves give way and the
-- taught ones stay.
--
-- Solo room, no relay, a ten-second fog so the rung climbs fast.  Run
-- from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-levels-tm POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/levels_tm_smoke.lua \
--   <path to>/lovec . > levels_tm.log 2>&1
--
-- Exit 0 with a `LEVELS OK` line passes; any `PVP FAIL` line fails.

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
  E.setFog(10)
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

  for _, id in ipairs({ "TACKLE", "TAIL_WHIP", "THUNDERBOLT", "BLIZZARD", "HYPER_FANG" }) do
    if not game.data.moves[id] then return C.fail("no such move in the data: " .. id) end
  end
  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, "RATTATA", 5)
  mon.moves = { { id = "TACKLE", pp = 35 }, { id = "TAIL_WHIP", pp = 30 },
                { id = "THUNDERBOLT", pp = 15 }, { id = "BLIZZARD", pp = 5 } }
  game.save.party = { mon }
  local function ids()
    local out = {}
    for _, m in ipairs(mon.moves) do out[#out + 1] = m.id end
    return table.concat(out, ",")
  end
  U.log(("LEVELS: Lv%d RATTATA with %s; fog %ss"):format(mon.level, ids(),
    tostring(E.fogSeconds and E.fogSeconds())))

  -- the rung climbs with the first shrink, and tickLevels pays it out on
  -- its own beat -- never mid-fight, which is why nothing here fights
  local t0 = wall()
  while (wall() - t0) < 90 do
    if mon.level >= 15 then break end
    if C.busy() then U.tap(game, "a") end
    U.wait(10)
  end
  if mon.level < 15 then
    return C.fail(("the party never reached rung 15 (rung %s, Lv%d after %.0fs)")
      :format(tostring(E.level()), mon.level, wall() - t0))
  end
  local have = ids()
  U.log(("LEVELS: at Lv%d the moves are %s"):format(mon.level, have))
  local function has(id) return have:find(id, 1, true) ~= nil end
  if not (has("THUNDERBOLT") and has("BLIZZARD")) then
    return C.fail("a taught move was displaced by the rung: " .. have)
  end
  if not has("HYPER_FANG") then
    return C.fail("the rung's own move was not learned: " .. have)
  end
  if has("TACKLE") then
    return C.fail("the level-up move should have given way first: " .. have)
  end
  U.log("LEVELS OK: THUNDERBOLT and BLIZZARD survived the rung; HYPER FANG came in over TACKLE")
  love.event.quit(0)
  U.wait(10)
end
