-- POK-175: a spill is walked through, and A on the tile takes it.
--
-- Pickups used to be solid, and a pile of thirty trainers' loot walled
-- the player in.  Stage a solo match, drop a bag two cells ahead with a
-- ball beside it, then: walk ONTO the bag (a step a solid object would
-- have refused), press A there and take it; walk onto the ball, press A
-- there and take that too.  Both pieces gone from the ground, the mon in
-- the party, the items in the bag.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-pickup POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/walkable_pickup_smoke.lua \
--   <path to>/lovec . > walkable_pickup.log 2>&1
--
-- Exit 0 with a `PICKUP OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("WADER")
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
  game.save.party = { Pokemon.new(game.data, "MACHOP", 15) }

  -- Pewter's street, the clear lane the spill drivers share; the bots go
  -- to Cinnabar so nobody walks up mid-test
  for _, b in ipairs(E.bots() or {}) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)

  local spill, why = E.debugSpill(0, 2, true)
  if not spill then return C.fail("debugSpill refused: " .. tostring(why)) end
  U.wait(30)
  -- ours only: the bots fight each other from the drop, and a fallen
  -- bot's spill is on the ground somewhere too.  debugSpill keys as 999.
  local function mine()
    local out = {}
    for _, p in ipairs(E.spills() or {}) do
      if tostring(p.key):sub(1, 4) == "999:" then out[#out + 1] = p end
    end
    return out
  end
  local pieces = mine()
  if #pieces ~= 2 then return C.fail("expected a bag and a ball, got " .. #pieces) end
  local bag, ball
  for _, p in ipairs(pieces) do if p.bag then bag = p else ball = p end end
  if not (bag and ball) then return C.fail("the spill is not a bag plus a ball") end
  U.log(("PICKUP: bag at %d,%d, ball at %d,%d; we stand at %d,%d")
    :format(bag.x, bag.y, ball.x, ball.y, C.x(), C.y()))

  local function count() return #mine() end
  local function takeUnderfoot(piece, other, label)
    -- ONTO the cell: the step a solid object refused
    if not L.goTo(C, "PEWTER_CITY", piece.x, piece.y, 200) then
      return C.fail(("could not step onto the %s at %d,%d; stuck at %d,%d")
        :format(label, piece.x, piece.y, C.x(), C.y()))
    end
    if not (C.x() == piece.x and C.y() == piece.y) then
      return C.fail(("not standing on the %s: at %d,%d"):format(label, C.x(), C.y()))
    end
    U.log(("PICKUP: standing on the %s at %d,%d"):format(label, C.x(), C.y()))
    -- facing wins, so face away from the other piece: the press must
    -- resolve to nothing and fall through to the cell under our feet
    local away = "down"
    if other and other.y > piece.y then away = "up"
    elseif other and other.y == piece.y then away = other.x > piece.x and "left" or "right" end
    local before = count()
    local ow = C.ow()
    for _ = 1, 10 do
      if ow.player.facing == away then break end
      U.hold(game, away, 1) U.wait(6)
    end
    if ow.player.facing ~= away then
      return C.fail("could not face " .. away .. " (facing " .. tostring(ow.player.facing) .. ")")
    end
    if C.x() ~= piece.x or C.y() ~= piece.y then
      return C.fail(("turning walked us off the %s to %d,%d"):format(label, C.x(), C.y()))
    end
    if piece.bag then
      -- the bag is a list (POK-176): TAKE the POTION row, then the money
      U.tap(game, "a") U.wait(15)                       -- the loot list
      U.tap(game, "a") U.wait(10)                       -- USE / TAKE / CANCEL
      U.tap(game, "down") U.wait(6) U.tap(game, "a") U.wait(15)   -- TAKE
      U.tap(game, "a") U.wait(10)                       -- TAKE / CANCEL
      U.tap(game, "a") U.wait(15)                       -- TAKE the money
    else
      -- the ball asks; YES
      local t0 = love.timer.getTime()
      while count() == before and love.timer.getTime() - t0 < 20 do
        U.tap(game, "a") U.wait(12)
      end
    end
    if count() ~= before - 1 then
      return C.fail(("A on the %s took nothing (%d pieces, was %d)"):format(label, count(), before))
    end
    -- B until the overworld is back on top: the take is followed by a
    -- "joined your party" or an "Open the PACK now?" that eats the walk
    for _ = 1, 60 do
      if game.stack:top() == C.ow() then break end
      U.tap(game, "b") U.wait(8)
    end
    if game.stack:top() ~= C.ow() then
      return C.fail(("after the %s something is still on top: %s")
        :format(label, tostring(game.stack:top())))
    end
    U.log(("PICKUP: took the %s from on top of it"):format(label))
    return true
  end

  if not takeUnderfoot(bag, ball, "bag") then return end
  if (game.save.inventory.POTION or 0) < 1 then
    return C.fail("the bag's POTION did not land in the inventory")
  end
  if not takeUnderfoot(ball, nil, "ball") then return end
  if #game.save.party ~= 2 then
    return C.fail("the ball's mon did not join the party (" .. #game.save.party .. ")")
  end
  if count() ~= 0 then return C.fail("pieces still on the ground: " .. count()) end
  U.log("PICKUP OK: waded onto both pieces and took them with A")
  love.event.quit(0)
  U.wait(30)
end
