-- The 2026-08-25 playtest batch, endgame half: POK-95.
--
-- "I'm watching a game where 3 are left and they still just walk back and
-- forth."  Same-map hunting always worked; nothing pulled a bot ACROSS a
-- seam toward anybody, so the last few survivors each paced their own map
-- until the fog decided the match.
--
-- Staged rather than played: a two-bot room is already the thin roster,
-- and the bots are then EXILED to far corners of Kanto.  If the hunt
-- works they close on the nearest trainer -- me, or each other -- without
-- the ring having to squeeze them together.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-playtest-hunt POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_hunt.lua \
--   <path to>/lovec . > hunt.log 2>&1
--
-- Exit 0 with a `HUNT OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")
local Spawn = require("mods.battle_royale.lib.spawn")

return function(game)
  local C = L.ctx(game)
  local function quiet(rounds)
    for _ = 1, rounds or 60 do
      if game.stack:top() == C.ow() then return true end
      U.tap(game, "b")
      U.wait(12)
    end
    return game.stack:top() == C.ow()
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("HUNTED")
  E.setSafari(0)
  E.setFog(600)      -- the ring must not be what herds them
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(2)       -- me + 2 = the three-left endgame the playtest watched

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
  quiet(60)

  local alive = E.aliveCount()
  U.log(("HUNT: %d alive, hunting starts at %d or fewer, seam clock %ds")
    :format(alive, Bots.HUNT_FROM, Bots.roamSeconds(alive)))
  if alive > Bots.HUNT_FROM then
    return C.fail("the roster is too full to be the endgame case")
  end

  -- Post up somewhere fixed, so "closer" means closer to a known square.
  if not L.flyTo(C, "CELADON_CITY") then
    return C.fail("FLY did not reach Celadon; at " .. tostring(C.map()))
  end
  quiet(60)
  local myMap = C.map()

  local locations = game.data.field.townMap.locations
  local mine = locations[myMap]
  if not mine then return C.fail("Celadon is not on the town map") end

  -- Exile the bots to opposite far corners: nowhere near me, nowhere near
  -- each other.  A random walkable cell, so the landing is legal.
  local roster = E.bots() or {}
  if #roster < 2 then return C.fail("expected two bots, got " .. #roster) end
  local corners = { "PALLET_TOWN", "LAVENDER_TOWN" }
  for i, b in ipairs(roster) do
    local dest = corners[i]
    if dest then
      local spot = Spawn.pickIn(game.data.maps, game.data.tilesets, dest, 1,
                                Spawn.rng(1000 + i))
      local cell = spot and spot[1]
      if not cell then return C.fail("no landing cell on " .. dest) end
      if not E.debugPlaceBot(b.id, dest, cell.x, cell.y) then
        return C.fail("could not exile bot " .. tostring(b.name))
      end
      U.log(("HUNT: exiled %s to %s at %d,%d"):format(
        tostring(b.name), dest, cell.x, cell.y))
    end
  end
  U.wait(60)

  -- Squared town-map distance from a bot's map to the nearest OTHER live
  -- trainer -- the same measure the hunt itself ranks seams by.
  local function nearestDist(bot, all)
    local l = locations[bot.map]
    if not l then return nil end
    local best
    local function consider(t)
      if not t then return end
      local dx, dy = l.x - t.x, l.y - t.y
      local d = dx * dx + dy * dy
      if not best or d < best then best = d end
    end
    consider(mine)
    for _, o in ipairs(all) do
      if o.id ~= bot.id and o.status == "alive" then consider(locations[o.map]) end
    end
    return best
  end

  local function snapshot()
    local all = E.bots() or {}
    local out = {}
    for _, b in ipairs(all) do
      if b.status == "alive" then
        out[b.id] = { map = b.map, d = nearestDist(b, all), name = b.name }
      end
    end
    return out
  end

  local start = snapshot()
  local total0, n = 0, 0
  for _, s in pairs(start) do
    if s.d then total0 = total0 + s.d n = n + 1 end
    U.log(("HUNT: %s starts on %s, %.2f squares from the nearest trainer")
      :format(tostring(s.name), tostring(s.map), math.sqrt(s.d or 0)))
  end
  if n == 0 then return C.fail("no placeable bots to watch") end

  -- Watch.  A seam crossing is a teleport to the next map, so this moves in
  -- jumps; two minutes of wall time is many seam clocks at 8s.
  local closed, arrived, best = false, false, total0
  for _ = 1, 240 do
    U.wait(30)
    if game.stack:top() ~= C.ow() then U.tap(game, "b") end
    local now = snapshot()
    local total = 0
    for id, s in pairs(now) do
      if s.d then total = total + s.d end
      if s.map == myMap then arrived = true end
      local was = start[id]
      if was and s.map ~= was.map then
        U.log(("HUNT: %s moved %s -> %s (%.2f -> %.2f squares)")
          :format(tostring(s.name), tostring(was.map), tostring(s.map),
                  math.sqrt(was.d or 0), math.sqrt(s.d or 0)))
        start[id] = s
      end
    end
    if total < best then best = total end
    if best < total0 then closed = true end
    if arrived then break end
  end

  if not (closed or arrived) then
    return C.fail(("the bots never closed on anybody: distance sum %.0f -> %.0f")
      :format(total0, best))
  end
  U.log(("HUNT: POK-95 ok -- %s (distance sum %.0f -> %.0f)")
    :format(arrived and "a bot reached my map" or "the gap closed",
            total0, best))

  U.log("HUNT OK")
  love.event.quit(0)
  U.wait(30)
end
