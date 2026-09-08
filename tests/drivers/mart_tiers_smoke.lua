-- POK-192: the Marts climb with the fog.
--
-- A solo match, a teleport into VIRIDIAN MART, A on the clerk: at ring 1
-- the BUY list is the vanilla shelf (POKe BALL, POTION, the cures).  Then
-- the round's fog is collapsed to six seconds a phase, the ring is let run
-- to phase 5, and the same clerk sells the whole ladder -- GREAT, ULTRA
-- and MASTER BALL, SUPER, HYPER and MAX POTION -- with the MASTER BALL
-- priced.  Leaving the match gives the MASTER BALL its ROM price back.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-marts POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/mart_tiers_smoke.lua \
--   <path to>/lovec . > mart_tiers.log 2>&1
--
-- Exit 0 with a `MARTS OK` line passes; any `PVP FAIL` line fails.

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

  -- the clerk stands at 0,5 behind the counter; face him across it
  local function closeAll()
    for _ = 1, 30 do
      if game.stack:top() == C.ow() then break end
      U.tap(game, "b") U.wait(8)
    end
  end
  local function tryCounter(x, y, facing)
    U.teleport(game, "VIRIDIAN_MART", x, y, facing)
    U.wait(20)
    U.tap(game, "a") U.wait(15)
    for _ = 1, 10 do
      local top = game.stack:top()
      if top and top.items and top.items[1] and top.items[1].label == "BUY" then return top end
      U.tap(game, "a") U.wait(12)
    end
    closeAll()
    return nil
  end
  local function shelf()
    local shop = tryCounter(2, 5, "left") or tryCounter(1, 5, "left")
      or tryCounter(2, 4, "left") or tryCounter(1, 4, "left")
    if not shop then return nil, "A on the clerk did not open the shop" end
    U.tap(game, "a") U.wait(15)              -- BUY
    local list = game.stack:top()
    if not (list and list.items and list.kind == "BUY") then
      return nil, "BUY did not open its list (top kind " .. tostring(list and list.kind) .. ")"
    end
    local ids, price = {}, {}
    for _, row in ipairs(list.items) do
      ids[#ids + 1] = row.value
      price[row.value] = row.right
    end
    closeAll()
    return ids, price
  end

  -- ring 1: the vanilla shelf
  local r = E.ring()
  if not (r and r.phase == 1) then
    return C.fail("expected ring 1 at the drop, got " .. tostring(r and r.phase))
  end
  local ids, price = shelf()
  if not ids then return C.fail(price) end
  U.log("MARTS: ring 1 -- " .. table.concat(ids, ", "))
  if ids[1] ~= "POKE_BALL" or ids[2] ~= "POTION" then
    return C.fail("ring 1 should open POKE_BALL, POTION")
  end
  for _, id in ipairs(ids) do
    if id == "GREAT_BALL" or id == "SUPER_POTION" or id == "MASTER_BALL" then
      return C.fail("ring 1 already sells " .. id)
    end
  end

  -- run the ring to phase 5.  The phase is elapsed time over the phase
  -- length, so it cannot be held: lengthening the phase again would
  -- rewind the ring.  Six seconds a phase leaves the shelf a window.
  if not E.debugRoundFog(6) then return C.fail("debugRoundFog refused") end
  local reached = false
  for _ = 1, 3000 do   -- the ring keeps real seconds; the wait is frames at 3x
    U.wait(5)
    local now = E.ring()
    if now and now.phase >= 5 then reached = true break end
  end
  if not reached then
    return C.fail("the ring never reached phase 5 (at " .. tostring(E.ring() and E.ring().phase) .. ")")
  end
  if E.status() ~= "alive" then return C.fail("the fog took us before the shelf could be read") end
  closeAll()

  local ids2, price2 = shelf()
  if not ids2 then return C.fail(price2) end
  U.log(("MARTS: ring %d -- %s"):format(E.ring().phase, table.concat(ids2, ", ")))
  local have = {}
  for _, id in ipairs(ids2) do have[id] = true end
  for _, id in ipairs(Shops.BALLS) do
    if not have[id] then return C.fail("the late shelf lacks " .. id) end
  end
  for _, id in ipairs(Shops.POTIONS) do
    if not have[id] then return C.fail("the late shelf lacks " .. id) end
  end
  if not (have.ANTIDOTE) then return C.fail("the ROM's own cures fell off the shelf") end
  if price2.MASTER_BALL ~= ("¥%d"):format(Shops.MASTER_BALL_PRICE) then
    return C.fail("the MASTER BALL is priced " .. tostring(price2.MASTER_BALL))
  end
  if game.data.items.MASTER_BALL.price ~= Shops.MASTER_BALL_PRICE then
    return C.fail("the item data does not carry the match price")
  end

  -- leaving the match gives the ROM its price back
  E.leave()
  U.wait(60)
  if game.data.items.MASTER_BALL.price ~= 0 then
    return C.fail("after the match the MASTER BALL still costs " .. tostring(game.data.items.MASTER_BALL.price))
  end
  U.log("MARTS OK: the vanilla shelf at ring 1, the whole ladder at ring 5, the MASTER BALL priced and restored")
  love.event.quit(0)
  U.wait(30)
end
