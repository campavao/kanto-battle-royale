-- POK-176: A on a bag opens the bag; USE / TAKE / CANCEL per item.
--
-- Two bags, both dropped by debugSpill (a POTION and 500 yen each):
--
--   1. A on the bag opens a list of THAT bag (kind "loot", one item row
--      and a money row), no text box first.  TAKE the POTION: it lands
--      in our inventory, the bag on the ground is lighter by one row.
--      TAKE the money: the bag is empty, so the list closes and the
--      piece is gone from the ground.
--   2. USE the POTION on a MACHOP at 1 HP: the item is taken, the PACK
--      opens on it with USE already chosen, the party picker takes the
--      MACHOP, and the potion is consumed -- the engine's own flow.
--      Back out to the loot list, which still holds the money.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-loot POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/loot_bag_smoke.lua \
--   <path to>/lovec . > loot_bag.log 2>&1
--
-- Exit 0 with a `LOOT OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("LOOTER")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(3)
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
  local machop = Pokemon.new(game.data, "MACHOP", 15)
  game.save.party = { machop }
  for _, b in ipairs(E.bots() or {}) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)

  local function myBag()
    for _, p in ipairs(E.spills() or {}) do
      if p.key == "999:bag" then return p end
    end
    return nil
  end
  local function top() return game.stack:top() end
  local function settle()
    for _ = 1, 60 do
      if top() == C.ow() then return true end
      U.tap(game, "b") U.wait(8)
    end
    return top() == C.ow()
  end
  local function dropBag()
    local spill, why = E.debugSpill(0, 2)
    if not spill then return C.fail("debugSpill refused: " .. tostring(why)) end
    U.wait(30)
    local bag = myBag()
    if not bag then return C.fail("no bag on the ground after debugSpill") end
    if not L.goTo(C, "PEWTER_CITY", bag.x, bag.y, 200) then
      return C.fail(("could not reach the bag at %d,%d"):format(bag.x, bag.y))
    end
    -- face away from anything: the press must fall through to the tile
    for _ = 1, 10 do
      if C.ow().player.facing == "down" then break end
      U.hold(game, "down", 1) U.wait(6)
    end
    U.tap(game, "a") U.wait(15)
    local t = top()
    if not (t and t.kind == "loot") then
      return C.fail("A on the bag did not open the loot list (top " .. tostring(t and t.kind or t) .. ")")
    end
    return t
  end

  -- ------- 1. TAKE, item by item
  local list = dropBag()
  if not list then return end
  if #list.items ~= 2 or list.items[1].value ~= "POTION" or list.items[2].value ~= "money" then
    return C.fail(("the list is not POTION + money: %d rows, first %s")
      :format(#list.items, tostring(list.items[1] and list.items[1].value)))
  end
  U.log("LOOT: A on the bag opened its own list, POTION x1 and the money, no text first")
  local potions0 = game.save.inventory.POTION or 0
  local money0 = game.save.money or 0
  U.tap(game, "a") U.wait(10)            -- USE / TAKE / CANCEL
  local menu = top()
  if not (menu and menu.items and #menu.items == 3 and menu.items[2].label == "TAKE") then
    return C.fail("the row did not offer USE / TAKE / CANCEL")
  end
  U.tap(game, "down") U.wait(6)
  U.tap(game, "a") U.wait(15)            -- TAKE
  if (game.save.inventory.POTION or 0) ~= potions0 + 1 then
    return C.fail("TAKE did not put the POTION in the inventory")
  end
  if not (top() == list and #list.items == 1 and list.items[1].value == "money") then
    return C.fail("after TAKE the list is not back with only the money row")
  end
  local ground = myBag()
  if not ground then return C.fail("the bag left the ground with money still in it") end
  U.log("LOOT: took the POTION; the bag on the ground kept the money")
  U.tap(game, "a") U.wait(10)            -- TAKE / CANCEL
  menu = top()
  if not (menu and menu.items and #menu.items == 2 and menu.items[1].label == "TAKE") then
    return C.fail("the money row did not offer TAKE / CANCEL")
  end
  U.tap(game, "a") U.wait(15)            -- TAKE
  if (game.save.money or 0) ~= money0 + 500 then
    return C.fail("TAKE did not add the money")
  end
  if not settle() then return C.fail("could not get back to the overworld") end
  if myBag() then return C.fail("an emptied bag is still on the ground") end
  U.log("LOOT: took the money; the empty bag is gone and the list closed")

  -- ------- 2. USE
  machop.hp = 1
  list = dropBag()
  if not list then return end
  potions0 = game.save.inventory.POTION or 0
  U.tap(game, "a") U.wait(10)            -- USE / TAKE / CANCEL
  U.tap(game, "a") U.wait(20)            -- USE: the PACK opens on it, the party picker follows
  -- the potion wants a target: A on the first party row, then read out
  local t0 = love.timer.getTime()
  while machop.hp <= 1 and love.timer.getTime() - t0 < 15 do
    U.tap(game, "a") U.wait(12)
  end
  if machop.hp <= 1 then
    return C.fail("USE did not heal the MACHOP (hp " .. tostring(machop.hp) .. ", top " .. tostring(top() and top().kind) .. ")")
  end
  if (game.save.inventory.POTION or 0) ~= potions0 then
    return C.fail(("the used POTION was not consumed (%d, was %d)")
      :format(game.save.inventory.POTION or 0, potions0))
  end
  U.log("LOOT: USE healed the MACHOP through the PACK's own flow and consumed the POTION")
  -- B out of the PACK lands back on the loot list, money still there
  for _ = 1, 40 do
    if top() == list then break end
    U.tap(game, "b") U.wait(8)
  end
  if top() ~= list or #list.items ~= 1 or list.items[1].value ~= "money" then
    return C.fail("after USE the loot list is not back with the money row (top " .. tostring(top() and top().kind) .. ")")
  end
  U.log("LOOT: back on the loot list, the money still on the ground")
  if not settle() then return C.fail("could not leave the loot list") end
  if not myBag() then return C.fail("a bag with money left in it vanished") end
  U.log("LOOT OK: the bag is a list, TAKE is per item, USE runs the engine's own use")
  love.event.quit(0)
  U.wait(30)
end
