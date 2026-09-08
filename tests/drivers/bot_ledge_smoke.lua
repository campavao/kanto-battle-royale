-- POK-191: a bot above a ledge hops down to a player below it.
--
-- Seen live: the player directly beneath a one-way ledge, a bot on the
-- shelf above, and the bot stood there.  Two things stopped it -- the
-- ledge tile blocked its eye (not walkable, so "terrain"), and the BFS
-- it walks with only expands walkable cells, so the drop was a wall.
-- Now Bots.seeOver lets the eye down a ledge the seer could hop, and
-- Bots.landing puts the hop into every path and stride.
--
-- Staged on Viridian's ledge row (24..27, 8 -> 10): the player stands
-- THREE cells below the shelf facing east, so our own eyeline cannot be
-- the trigger; the bot is planted on the shelf looking down.  Its sight
-- has to pass the ledge, its stride has to take the hop (one step that
-- moves it two cells), and the fight has to open beside us.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bot-ledge POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_ledge_smoke.lua \
--   <path to>/lovec . > bot_ledge.log 2>&1
--
-- Exit 0 with a `LEDGE OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Spawn = require("mods.battle_royale.lib.spawn")

local TOWN = "VIRIDIAN_CITY"

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("LEDGE")
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

  if not L.flyTo(C, TOWN) then
    return C.fail("FLY did not land in Viridian; at " .. tostring(C.map()))
  end
  U.wait(30)

  -- the shelf: a standing cell whose hop lands on floor with floor below
  local data = game.data
  local maps, tilesets = data.maps, data.tilesets
  local ledges = data.field and data.field.ledges
  local sx, sy, lx, ly
  for _, x in ipairs({ 25, 26, 24, 27 }) do
    local hx, hy = Spawn.hopLanding(maps, tilesets, ledges, TOWN, x, 8, "down")
    if hx and Spawn.walkable(maps, tilesets, TOWN, x, 8)
       and Spawn.walkable(maps, tilesets, TOWN, hx, hy)
       and Spawn.walkable(maps, tilesets, TOWN, hx, hy + 1) then
      sx, sy, lx, ly = x, 8, hx, hy
      break
    end
  end
  if not sx then return C.fail("no hoppable shelf cell on Viridian's ledge row") end
  local myX, myY = lx, ly + 1
  if not L.goTo(C, TOWN, myX, myY, 400) then
    return C.fail(("never reached the foot of the ledge; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)
  local ow = C.ow()
  for _ = 1, 20 do
    if ow.player.facing == "right" then break end
    U.hold(game, "right", 2)
    U.wait(8)
  end
  if ow.player.facing ~= "right" then
    return C.fail("could not face east (facing " .. tostring(ow.player.facing) .. ")")
  end
  if C.x() ~= myX or C.y() ~= myY then
    return C.fail(("the turn moved us to %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  U.log(("LEDGE: at %d,%d facing right; shelf %d,%d drops to %d,%d")
    :format(myX, myY, sx, sy, lx, ly))

  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots in the match") end
  local victim = roster[1]
  local function botAt()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == victim.id then return b end
    end
    return nil
  end

  -- hold it on the shelf until its sight takes
  local engaged = false
  for _ = 1, 40 do
    if E.status() == "battle" or E.walkUp() then engaged = true break end
    E.debugPlaceBot(victim.id, TOWN, sx, sy, "down")
    for _ = 1, 15 do
      if E.status() == "battle" or E.walkUp() then engaged = true break end
      U.wait(4)
    end
    if engaged then break end
  end
  if not engaged then
    local b = botAt()
    return C.fail(("its sight never crossed the ledge (bot %s,%s me %s,%s facing %s)")
      :format(tostring(b and b.x), tostring(b and b.y),
              tostring(C.x()), tostring(C.y()), tostring(ow.player.facing)))
  end
  if ow.player.facing == "up" then
    return C.fail("we ended up facing it -- the test proved nothing")
  end
  U.log(("LEDGE: %s saw us down the ledge from %d,%d"):format(
    tostring(victim.name), sx, sy))

  -- the stride: one step that covers two cells, then the fight
  local hopped, started, lastY, closest = false, false, sy, 99
  for _ = 1, 600 do
    local b = botAt()
    if b and b.map == TOWN then
      if b.y - lastY == 2 and b.x == sx then hopped = true end
      lastY = b.y
      local d = math.abs(b.x - (C.x() or myX)) + math.abs(b.y - (C.y() or myY))
      if d < closest then closest = d end
    end
    if E.status() == "battle" then started = true break end
    U.wait(2)
  end
  if not started then
    return C.fail(("it saw us but the fight never started (closest %d, hopped %s)")
      :format(closest, tostring(hopped)))
  end
  if not hopped then
    return C.fail(("the fight opened without the hop (closest %d, last y %d)")
      :format(closest, lastY))
  end
  U.log(("LEDGE OK: %s saw us over the ledge, hopped %d,%d -> %d,%d, and the fight opened")
    :format(tostring(victim.name), sx, sy, lx, ly))
  love.event.quit(0)
  U.wait(30)
end
