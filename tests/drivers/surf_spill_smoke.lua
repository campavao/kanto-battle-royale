-- A spill on open water (2026-09-14): "if you battle over the water far
-- enough from land, the POKeMON don't land".
--
-- Stage a surfer well out on VERMILION's harbour (654 water cells, no
-- seam to cross), put a one-ball spill on the cell in front of them the
-- way a fallen trainer's team would land, and report what the spill table
-- did with it: where the ball sits, whether its sprite spawned or the
-- spawn was refused, and whether facing it and pressing A opens anything.
--
--   tools/drive.sh surf_spill_smoke
--
-- Exit 0 with a `SPILL OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local shots = os.getenv("BR_SHOTS")
  local function shot(name)
    if shots then U.shot(game, shots .. "/" .. name .. ".png") end
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SWIM")
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

  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, "GYARADOS", 30)
  mon.moves = { { id = "SURF", pp = 15 }, { id = "FLY", pp = 15 } }
  game.save.party = { mon }

  -- straight onto deep water: a SEA ROUTE 20 cell with no land within six
  -- cells, the player placed there and marked surfing, the way the engine
  -- leaves them after a long swim
  local Map = require("src.world.Map")
  local Spawn = require("mods.battle_royale.lib.spawn")
  local d = game.data
  local function landNear(mapId, x, y, r)
    for dy = -r, r do
      for dx = -r, r do
        if Spawn.walkable(d.maps, d.tilesets, mapId, x + dx, y + dy) then return true end
      end
    end
    return false
  end
  local def = d.maps.ROUTE_20
  local ts = d.tilesets[def.tileset]
  local deep
  for y = 6, def.height * 2 - 7 do
    for x = 6, def.width * 2 - 7 do
      if Map.defIsWaterCell(def, ts, x, y) and not landNear("ROUTE_20", x, y, 6) then
        deep = { x = x, y = y }
        break
      end
    end
    if deep then break end
  end
  if not deep then return C.fail("no deep-water cell on ROUTE 20") end
  U.teleport(game, "ROUTE_20", deep.x, deep.y, "down")
  U.wait(30)
  local ow = C.ow()
  ow.player.surfing = true
  U.wait(30)
  if C.map() ~= "ROUTE_20" then return C.fail("teleport landed on " .. tostring(C.map())) end
  U.log(("SPILL: on open water at %s %d,%d"):format(C.map(), C.x(), C.y()))
  shot("open_water")

  -- the fallen team lands on the cell in front of us, as a foe's would
  local spill, why = E.debugSpill(0, 1, "RATTATA", 999)
  if not spill then return C.fail("debugSpill refused: " .. tostring(why)) end
  U.wait(90)
  local st = E.spillState()
  for key, b in pairs(st.balls or {}) do
    U.log(("SPILL: ball %s at %s %d,%d spawned=%s failed=%s"):format(
      key, tostring(b.map), b.x, b.y, tostring(st.spawned[key] ~= nil), tostring(st.failed[key])))
  end
  shot("spilled")
  -- Each piece in turn: the bag on the aim cell, the ball on the ring
  -- around it (on the water now).  Reach it -- one step to its row on
  -- open water, then face it -- and press A: the bag is TAKE ALL with no
  -- screen, the ball puts a mon in the party.  Let the fog's
  -- announcement clear before the first press.
  U.wait(240)
  local function keysLeft()
    local out = {}
    for _, b in ipairs(E.spills() or {}) do out[b.key] = { x = b.x, y = b.y } end
    return out
  end
  local function faceAndPress(bx, by)
    for _ = 1, 6 do
      local dx, dy = bx - C.x(), by - C.y()
      if math.abs(dx) + math.abs(dy) == 1 then
        local dir = dy == 1 and "down" or dy == -1 and "up" or dx == 1 and "right" or "left"
        for _ = 1, 20 do
          if C.ow().player.facing == dir then break end
          U.hold(game, dir, 1)
          U.wait(6)
        end
        U.tap(game, "a")
        U.wait(90)
        for _ = 1, 8 do U.tap(game, "a") U.wait(15) end
        for _ = 1, 4 do U.tap(game, "b") U.wait(15) end
        return true
      end
      -- not beside it: one step along the longer axis
      local dir
      if dy ~= 0 and (dx == 0 or math.abs(dy) >= math.abs(dx)) then
        dir = dy > 0 and "down" or "up"
      else
        dir = dx > 0 and "right" or "left"
      end
      U.hold(game, dir, 4)
      U.wait(12)
    end
    return false
  end
  local anySpawned = false
  for key in pairs(st.balls or {}) do if st.spawned[key] then anySpawned = true end end
  if not anySpawned then return C.fail("no ball sprite reached the water") end
  for _, key in ipairs({ "999:bag", "999:1" }) do
    local at = keysLeft()[key]
    if not at then return C.fail(key .. " is not on the ground") end
    if not faceAndPress(at.x, at.y) then
      return C.fail(("could not reach %s at %d,%d from %s,%s"):format(
        key, at.x, at.y, tostring(C.x()), tostring(C.y())))
    end
    local left = keysLeft()
    U.log(("SPILL: A on %s at %d,%d: %s"):format(key, at.x, at.y,
      left[key] and "still there" or "taken"))
    if left[key] then return C.fail(key .. " on the water was not taken by A") end
  end
  shot("pressed_a")
  if #game.save.party < 2 then return C.fail("the ball was taken but no mon joined the party") end
  U.log("SPILL OK")
  return true
end
