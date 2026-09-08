-- POK-196 smoke: one map.  The bag starts without a TOWN MAP, and the
-- start menu's own MAP row does what the item did: the ring map, and --
-- when a party mon knows FLY and the sky is reachable -- the fly picker.
--
--   1. at the drop the bag holds no TOWN MAP; the start menu shows MAP
--      and no FLY row, and with a RATTATA MAP is the plain map;
--   2. with a PIDGEOT that knows FLY, outdoors, MAP opens the TOWN MAP in
--      fly mode; indoors it is the plain map again;
--   3. a TOWN MAP a player finds still flies from the bag (the item.use
--      branch stays).
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-map-fly POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/map_fly_smoke.lua \
--   <path to>/lovec . > map_fly.log 2>&1
--
-- Exit 0 with a `FLYROW OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("FLYER")
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

  -- the start menu's rows, the way the engine asks for them
  local Runtime = require("src.mods.Runtime")
  local function rows()
    local vanilla = { { label = "POKeDEX" }, { label = "POKeMON" },
                      { label = "ITEM" }, { label = "RED" }, { label = "SAVE" },
                      { label = "OPTION" }, { label = "LINK" },
                      { label = "MODS" }, { label = "QUIT" } }
    local out = Runtime.call("ui.start_menu.items",
                             function(_, items) return items end, game, vanilla)
    local byLabel, labels = {}, {}
    for _, it in ipairs(out or {}) do
      byLabel[it.label] = it
      labels[#labels + 1] = tostring(it.label)
    end
    return byLabel, table.concat(labels, ",")
  end

  -- --------------------------------------------------------- 1. the drop
  local inv = game.save.inventory
  if inv.TOWN_MAP then return C.fail("the bag starts with a TOWN MAP") end
  local menu, labels = rows()
  U.log("FLYROW: at the drop the menu reads " .. labels)
  if not menu.MAP then return C.fail("no MAP row") end
  if menu.FLY then return C.fail("a FLY row with nothing that flies") end
  menu.MAP.onSelect()
  U.wait(10)
  local top = game.stack:top()
  if not (type(top) == "table" and top.screenId == "TownMap" or
          (type(top) == "table" and top.fly == nil and top ~= C.ow())) then
    return C.fail("MAP did not open the TOWN MAP (top " .. tostring(top) .. ")")
  end
  if type(top) == "table" and top.fly then return C.fail("MAP opened in fly mode") end
  U.tap(game, "b")
  U.wait(20)
  U.log("FLYROW: no TOWN MAP in the bag, MAP opens the map, no FLY row")

  -- ---------------------------------------------------- 2. a flyer, outdoors
  L.armParty(C, "PIDGEOT", 50, "FLY")
  U.teleport(game, "PEWTER_CITY", 16, 18, "down")
  U.wait(40)
  for _ = 1, 6 do U.tap(game, "b") U.wait(5) end
  menu, labels = rows()
  U.log("FLYROW: with a PIDGEOT outdoors the menu reads " .. labels)
  if menu.FLY then return C.fail("a FLY row of its own (" .. labels .. ")") end
  menu.MAP.onSelect()
  U.wait(10)
  top = game.stack:top()
  if not (type(top) == "table" and top.fly) then
    return C.fail("MAP did not open the fly picker with a flyer outdoors (top " .. tostring(top) .. ")")
  end
  U.tap(game, "b")
  U.wait(20)
  U.log("FLYROW: MAP opened the TOWN MAP in fly mode")
  -- ...and not indoors
  U.teleport(game, "PEWTER_GYM", 4, 4, "down")
  U.wait(40)
  for _ = 1, 6 do U.tap(game, "b") U.wait(5) end
  menu, labels = rows()
  menu.MAP.onSelect()
  U.wait(10)
  top = game.stack:top()
  if type(top) == "table" and top.fly then return C.fail("MAP flies indoors") end
  U.tap(game, "b")
  U.wait(20)
  U.log("FLYROW: indoors MAP is the plain map")

  -- --------------------------------------------- 3. a found TOWN MAP still flies
  U.teleport(game, "PEWTER_CITY", 16, 18, "down")
  U.wait(40)
  inv.TOWN_MAP = 1
  game.save.bagOrder = nil
  local vanilla = false
  Runtime.call("item.use", function() vanilla = true end,
               game, nil, "TOWN_MAP", nil, nil)
  U.wait(10)
  if vanilla then return C.fail("a found TOWN MAP fell through to vanilla") end
  top = game.stack:top()
  if not (type(top) == "table" and top.fly) then
    return C.fail("the found TOWN MAP did not open the fly picker")
  end
  U.tap(game, "b")
  U.wait(20)
  U.log("FLYROW OK: one map -- no item at the drop, MAP flies when it can, the bag's map still flies")
  love.event.quit(0)
  U.wait(30)
end
