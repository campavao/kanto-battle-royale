-- POK-164: Saffron is liberated for the match, and the doors open.
--
-- "Team Rocket still occupies the city and every building is locked."
-- Seven street ROCKETs stand on the cells below Saffron's doors; the
-- loadout now sets EVENT_BEAT_SILPH_CO_GIOVANNI, and M.SAFFRON_CITY.onEnter
-- hides them.  Proved in the world, not on paper:
--
--   1. in a match, Saffron has no SAFFRONCITY_ROCKET* on the map and the
--      civilians are out;
--   2. the cell below the GYM door is free to stand on, and stepping up
--      enters SAFFRON_GYM;
--   3. the same for SILPH CO;
--   4. and CELADON, the town the report named: the GAME CORNER and the
--      POKeMON CENTER doors both open (symptom (b) of the ticket).
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-saffron POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/saffron_smoke.lua \
--   <path to>/lovec . > saffron.log 2>&1
--
-- Exit 0 with a `SAFFRON OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  -- a vanilla save: the streets are occupied.  Read off the loadout's
  -- absence, since the flag is the whole lever.
  if game.save.flags.EVENT_BEAT_SILPH_CO_GIOVANNI then
    return C.fail("a vanilla new game already has Saffron liberated")
  end

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
  if not game.save.flags.EVENT_BEAT_SILPH_CO_GIOVANNI then
    return C.fail("the match loadout did not set EVENT_BEAT_SILPH_CO_GIOVANNI")
  end

  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 20) }

  local function npcNamed(prefix)
    local ow = C.ow()
    local n = 0
    for _, npc in ipairs((ow and ow.npcs) or {}) do
      local name = npc.def and npc.def.name
      if name and name:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
  end

  -- step through a door from the cell below it; true when the map changed
  local function enter(town, x, y, want)
    if not L.goTo(C, town, x, y, 200) then
      U.log(("SAFFRON: could not stand at %d,%d in %s; at %s,%s"):format(
        x, y, town, tostring(C.x()), tostring(C.y())))
      return false
    end
    for _ = 1, 30 do
      if C.map() == want then return true end
      U.hold(game, "up", 4)
      U.wait(12)
    end
    U.log(("SAFFRON: held up at %d,%d and stayed on %s"):format(x, y, tostring(C.map())))
    return false
  end

  -- ------- 1. Saffron's streets
  if not L.flyTo(C, "SAFFRON_CITY") then
    return C.fail("FLY did not land in Saffron; at " .. tostring(C.map()))
  end
  U.wait(30)
  local rockets, civilians = npcNamed("SAFFRONCITY_ROCKET"), npcNamed("SAFFRONCITY_SCIENTIST")
  U.log(("SAFFRON: %d rocket(s) on the streets, scientist out: %s"):format(
    rockets, tostring(civilians > 0)))
  if rockets > 0 then return C.fail("Team Rocket is still on Saffron's streets") end
  if civilians == 0 then return C.fail("the liberated-city civilians are missing") end

  -- ------- 2. the GYM door (34,3), from the cell ROCKET3 used to stand on.
  -- Staged by teleport: the walk from the Centre crosses the whole town
  -- and the liberated-city civilians stand in the BFS's way (the first run
  -- wedged on the SILPH WORKER at 17,30).  The door is what is under test.
  U.teleport(game, "SAFFRON_CITY", 34, 6, "up")
  U.wait(30)
  if not enter("SAFFRON_CITY", 34, 4, "SAFFRON_GYM") then
    return C.fail("the SAFFRON GYM door did not open")
  end
  U.log("SAFFRON: entered the GYM")

  -- ------- 3. SILPH CO (18,21), from the cell the two door guards stood on
  U.teleport(game, "SAFFRON_CITY", 18, 24, "up")
  U.wait(30)
  if not enter("SAFFRON_CITY", 18, 22, "SILPH_CO_1F") then
    return C.fail("the SILPH CO door did not open")
  end
  U.log("SAFFRON: entered SILPH CO")

  -- ------- 4. Celadon, the town the report named
  U.teleport(game, "CELADON_CITY", 28, 22, "up")
  U.wait(30)
  if not enter("CELADON_CITY", 28, 20, "GAME_CORNER") then
    return C.fail("Celadon's GAME CORNER door did not open")
  end
  U.log("SAFFRON: entered Celadon's GAME CORNER")
  U.teleport(game, "CELADON_CITY", 41, 12, "up")
  U.wait(30)
  if not enter("CELADON_CITY", 41, 10, "CELADON_POKECENTER") then
    return C.fail("Celadon's POKeMON CENTER door did not open")
  end
  U.log("SAFFRON: entered Celadon's POKeMON CENTER")

  U.log("SAFFRON OK: streets clear, GYM and SILPH open, Celadon's doors open")
  love.event.quit(0)
  U.wait(10)
end
