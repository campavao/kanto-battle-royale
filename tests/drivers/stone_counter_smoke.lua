-- POK-178: Celadon's 4F counter sells every evolution stone in a match.
--
-- A solo match, a teleport to the counter, A on the clerk: the greeting,
-- the BUY / SELL / QUIT box, and a BUY list that carries MOON, FIRE,
-- THUNDER, WATER and LEAF STONE with the MOON STONE priced like the rest.
-- Then buy the MOON STONE and find it in the bag.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-stones POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/stone_counter_smoke.lua \
--   <path to>/lovec . > stone_counter.log 2>&1
--
-- Exit 0 with a `STONES OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Shops = require("mods.battle_royale.lib.shops")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SHOPPER")
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
  for _, b in ipairs(E.bots() or {}) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end
  game.save.money = 9000

  -- the clerk stands at 5,7 behind the counter; face him across it
  local function tryCounter(x, y)
    U.teleport(game, "CELADON_MART_4F", x, y, "up")
    U.wait(20)
    U.tap(game, "a") U.wait(15)
    -- the greeting, then the shop box
    for _ = 1, 10 do
      local top = game.stack:top()
      if top and top.items and top.items[1] and top.items[1].label == "BUY" then return top end
      U.tap(game, "a") U.wait(12)
    end
    return nil
  end
  local shop = tryCounter(5, 9) or tryCounter(5, 8)
  if not shop then
    return C.fail("A on the clerk did not open the shop (top " .. tostring(game.stack:top()) .. ")")
  end
  U.log("STONES: the counter opened")
  U.tap(game, "a") U.wait(15)              -- BUY
  local list = game.stack:top()
  if not (list and list.items and list.kind == "BUY") then
    return C.fail("BUY did not open its list (top kind " .. tostring(list and list.kind) .. ")")
  end
  local have, rows = {}, {}
  for i, row in ipairs(list.items) do
    have[row.value] = row.right
    rows[#rows + 1] = row.value .. " " .. tostring(row.right)
  end
  U.log("STONES: on sale -- " .. table.concat(rows, ", "))
  for _, id in ipairs(Shops.STONES) do
    if not have[id] then return C.fail("the counter lacks " .. id) end
  end
  if have.MOON_STONE ~= ("¥%d"):format(Shops.MOON_STONE_PRICE) then
    return C.fail("the MOON STONE is priced " .. tostring(have.MOON_STONE))
  end
  if game.data.items.MOON_STONE.price ~= Shops.MOON_STONE_PRICE then
    return C.fail("the item data does not carry the counter price")
  end

  -- buy one MOON STONE: pick the row, one of them, YES
  local at
  for i, row in ipairs(list.items) do if row.value == "MOON_STONE" then at = i end end
  list.index = at
  local before = game.save.inventory.MOON_STONE or 0
  U.tap(game, "a") U.wait(12)              -- the quantity box
  U.tap(game, "a") U.wait(12)              -- one
  U.tap(game, "a") U.wait(20)              -- YES
  for _ = 1, 6 do
    if (game.save.inventory.MOON_STONE or 0) > before then break end
    U.tap(game, "a") U.wait(12)
  end
  if (game.save.inventory.MOON_STONE or 0) ~= before + 1 then
    return C.fail("buying a MOON STONE did not put one in the bag")
  end
  if game.save.money ~= 9000 - Shops.MOON_STONE_PRICE then
    return C.fail("the MOON STONE did not cost its price (money " .. tostring(game.save.money) .. ")")
  end
  U.log("STONES: bought a MOON STONE for ¥" .. Shops.MOON_STONE_PRICE)
  for _ = 1, 30 do
    if game.stack:top() == C.ow() then break end
    U.tap(game, "b") U.wait(8)
  end
  -- leaving the match gives the ROM its price back
  E.leave()
  U.wait(60)
  if game.data.items.MOON_STONE.price ~= 0 then
    return C.fail("after the match the MOON STONE still costs " .. tostring(game.data.items.MOON_STONE.price))
  end
  U.log("STONES OK: all five stones on the counter, the MOON STONE priced and restored")
  love.event.quit(0)
  U.wait(30)
end
