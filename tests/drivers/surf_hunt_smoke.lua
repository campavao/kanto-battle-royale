-- POK-158 M4: a bot with a SURF learner on its team crosses water.
--
-- Staged in Pallet, whose pond has no land route: the player surfs two
-- cells out and idles; the bot -- dealt a PSYDUCK via debugBotMon -- is
-- planted ashore.  Its hunt must walk it ONTO the water: the probe
-- passes when the bot stands on a swimmable cell (or has already opened
-- the fight from one).
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-surf-hunt POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/surf_hunt_smoke.lua \
--   <path to>/lovec . > surf_hunt.log 2>&1
--
-- Exit 0 with a `SURF OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("BUOY")
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

  -- a swimmer of our own, and out onto Pallet's pond
  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, "GYARADOS", 30)
  mon.moves = { { id = "SURF", pp = 15 } }
  game.save.party = { mon }
  if not L.flyTo(C, "PALLET_TOWN") then
    return C.fail("FLY did not land in Pallet; at " .. tostring(C.map()))
  end
  U.wait(30)
  local Map = require("src.world.Map")
  local Spawn = require("mods.battle_royale.lib.spawn")
  local def = game.data.maps.PALLET_TOWN
  local ts = game.data.tilesets[def.tileset]
  local shore
  for _, c in ipairs(Spawn.cellsOf(def, ts, game.data.maps,
                                   game.data.tilesets)) do
    if Map.defIsWaterCell(def, ts, c.x, c.y + 1) then shore = c break end
  end
  if not shore then return C.fail("no reachable water edge in Pallet") end
  if not L.goTo(C, "PALLET_TOWN", shore.x, shore.y, 400) then
    return C.fail(("never reached the shore at %d,%d; at %s,%s")
      :format(shore.x, shore.y, tostring(C.x()), tostring(C.y())))
  end
  local ow = C.ow()
  for _ = 1, 20 do
    if ow.player.facing == "down" then break end
    U.hold(game, "down", 2)
    U.wait(8)
  end
  U.tap(game, "a")
  local surfing = false
  for i = 1, 300 do
    if ow.player.surfing then surfing = true break end
    if i % 8 == 1 then U.tap(game, "a") end
    U.wait(3)
  end
  if not surfing then return C.fail("the shore ask never got us wet") end
  -- two cells out, so no land cell is adjacent to us
  for _ = 1, 2 do U.hold(game, "down", 6) U.wait(20) end
  if not Spawn.swimmable(game.data.maps, game.data.tilesets, "PALLET_TOWN",
                         C.x(), C.y()) then
    return C.fail(("we are not on water at %s,%s")
      :format(tostring(C.x()), tostring(C.y())))
  end
  U.log(("SURF: bait afloat at %d,%d"):format(C.x(), C.y()))

  -- the bot: a swimmer on its record, planted ashore, us for prey
  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bot in the match") end
  local target = roster[1]
  if not E.debugBotMon(target.id, "PSYDUCK") then
    return C.fail("could not deal the bot a PSYDUCK")
  end
  E.debugPlaceBot(target.id, "PALLET_TOWN", shore.x, shore.y)

  local wet, fought = false, false
  local t0 = love.timer.getTime()
  local lastSay = t0
  while love.timer.getTime() - t0 < 90 do
    if E.status() == "battle" then fought = true break end
    local b
    for _, r in ipairs(E.bots() or {}) do
      if r.id == target.id then b = r break end
    end
    if not b or b.status ~= "alive" then return C.fail("lost the bot mid-cross") end
    if b.map ~= "PALLET_TOWN" then
      E.debugPlaceBot(target.id, "PALLET_TOWN", shore.x, shore.y)
    elseif Spawn.swimmable(game.data.maps, game.data.tilesets,
                           "PALLET_TOWN", b.x, b.y) then
      wet = true
      break
    end
    local e = E.tickError()
    if e then return C.fail("tick error mid-cross: " .. tostring(e)) end
    if love.timer.getTime() - lastSay >= 15 then
      lastSay = love.timer.getTime()
      U.log(("SURF: waiting on the crossing (%.0fs, bot %s,%s us %s,%s)")
        :format(lastSay - t0, tostring(b.x), tostring(b.y),
                tostring(C.x()), tostring(C.y())))
    end
    U.wait(10)
  end
  if not (wet or fought) then
    return C.fail("ninety real seconds and the bot never took to the water")
  end
  U.log(("SURF OK: the bot %s"):format(
    fought and "crossed and opened the fight" or "stands on the water"))
  love.event.quit(0)
  U.wait(30)
end
