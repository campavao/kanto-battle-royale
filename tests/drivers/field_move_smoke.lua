-- POK-141 + POK-109: the world offers the field move, and the dex scrolls.
--
-- Three probes in one match:
--
--   1. SURF at the shore: stand at Pallet's water edge with a SURF mon,
--      press A facing the water -- a prompt must open (vanilla would do
--      nothing), and YES must put the player on the water.
--   2. FLY from the bag: dispatch the item.use hook for TOWN_MAP the way
--      the bag would -- the wrap must swallow it and open the fly picker.
--   3. The dex: pushed during a match, its list must carry keyRepeat.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-field-move POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/field_move_smoke.lua \
--   <path to>/lovec . > field_move.log 2>&1
--
-- Exit 0 with a `FIELD OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

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

  -- a swimmer: SURF and FLY on its card, the badges are the match's own
  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, "GYARADOS", 30)
  mon.moves = { { id = "SURF", pp = 15 }, { id = "FLY", pp = 15 } }
  game.save.party = { mon }

  -- 1. the shore: find a walkable Pallet cell with water directly south
  if not L.flyTo(C, "PALLET_TOWN") then
    return C.fail("FLY did not land in Pallet; at " .. tostring(C.map()))
  end
  U.wait(30)
  local Map = require("src.world.Map")
  local Spawn = require("mods.battle_royale.lib.spawn")
  local def = game.data.maps.PALLET_TOWN
  local ts = game.data.tilesets[def.tileset]
  -- reachable cells only: a walkable pond edge behind a fence is exactly
  -- the POK-23 trap, and cellsOf is the escapable answer to it
  local stand
  for _, c in ipairs(Spawn.cellsOf(def, ts, game.data.maps,
                                   game.data.tilesets)) do
    if Map.defIsWaterCell(def, ts, c.x, c.y + 1) then
      stand = c
      break
    end
  end
  if not stand then return C.fail("no reachable water edge in Pallet") end
  if not L.goTo(C, "PALLET_TOWN", stand.x, stand.y, 400) then
    return C.fail(("never reached the shore at %d,%d; at %s,%s")
      :format(stand.x, stand.y, tostring(C.x()), tostring(C.y())))
  end
  local ow = C.ow()
  for _ = 1, 20 do
    if ow.player.facing == "down" then break end
    U.hold(game, "down", 2)
    U.wait(8)
  end
  U.tap(game, "a")
  local prompt = false
  for _ = 1, 60 do
    U.wait(3)
    if game.stack:top() ~= ow then prompt = true break end
  end
  if not prompt then return C.fail("A at the water's edge asked nothing") end
  U.log("FIELD: the water asked")
  -- YES: the prompt prints, then the choice takes its own press, then the
  -- mount text -- keep pressing until the water takes
  local surfing = false
  for i = 1, 300 do
    if ow.player.surfing then surfing = true break end
    if i % 8 == 1 then U.tap(game, "a") end
    U.wait(3)
  end
  if not surfing then return C.fail("said yes and never got wet") end
  U.log("FIELD: SURF mounted from the overworld ask")

  -- back to land so the later screens sit on solid ground
  for _ = 1, 30 do
    if not ow.player.surfing then break end
    U.hold(game, "up", 4)
    U.wait(10)
  end

  -- 2. the bag's TOWN MAP flies: dispatch the hook the way useItem does
  local Runtime = require("src.mods.Runtime")
  local vanilla = false
  Runtime.call("item.use", function() vanilla = true end,
               game, nil, "TOWN_MAP", nil, nil)
  U.wait(10)
  if vanilla then
    return C.fail("the TOWN_MAP use fell through to vanilla in a match")
  end
  local top = game.stack:top()
  if not (type(top) == "table" and top.fly) then
    return C.fail("the TOWN MAP did not open as the fly picker")
  end
  U.log("FIELD: the bag's TOWN MAP opened ready to FLY")
  U.tap(game, "b")   -- close it; we are not going anywhere
  U.wait(20)

  -- 3. the dex scrolls: its list must carry keyRepeat during a session
  local okPush = pcall(function()
    require("src.ui.Screens").push(game, "PokedexMenu")
  end)
  if not okPush then return C.fail("could not open the POKeDEX") end
  U.wait(10)
  local dex = game.stack:top()
  if not (type(dex) == "table" and dex.keyRepeat) then
    return C.fail("the dex list did not pick up keyRepeat")
  end
  U.log("FIELD OK: the world asks, the map flies, the dex scrolls")
  love.event.quit(0)
  U.wait(30)
end
