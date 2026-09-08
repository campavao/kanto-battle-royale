-- POK-143: an Elite Four room does not seal you in during a match.
--
-- Vanilla's e4ExitSeal shuts the block above the exit warp on every
-- entry until the room's leader is beaten -- and on a match's throwaway
-- save nobody has been beaten, so LORELEI's room was a trap: walk in,
-- and the only way out was to beat her at the rung or die to the ring.
-- Now the mod hears the seal land (world.block_replaced) and puts the
-- open block back.  The leader stays where she is and stays fightable.
--
-- A solo match, a teleport into LORELEIS_ROOM below the exit, the block
-- read straight off the map, and a walk north that has to land in
-- BRUNOS_ROOM.  Then the same room OUTSIDE a session, where the seal must
-- hold: the mod is installed beside real playthroughs.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-e4-door POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/e4_door_smoke.lua \
--   <path to>/lovec . > e4_door.log 2>&1
--
-- Exit 0 with a `DOOR OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Lockstep = require("mods.battle_royale.lib.lockstep")

local ROOM = "LORELEIS_ROOM"
local NEXT = "BRUNOS_ROOM"

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("CLIMBER")
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

  local door = Lockstep.E4_DOORS[ROOM]
  local function blockAt()
    local ow = C.ow()
    return ow and ow.map and ow.map.id == ROOM and ow.map:blockAt(door.bx, door.by) or nil
  end

  -- in: below the exit, facing it.  LORELEI stands at (5,2); the exit
  -- block covers (4..5, 0..1), so the walk goes up the west column.
  U.teleport(game, ROOM, 4, 6, "up")
  U.wait(40)
  for _ = 1, 6 do U.tap(game, "a") U.wait(10) end   -- any entry text
  if C.map() ~= ROOM then return C.fail("the teleport did not land in " .. ROOM .. " (at " .. tostring(C.map()) .. ")") end
  local b = blockAt()
  U.log(("DOOR: in the match the exit block reads 0x%02x (open 0x%02x, closed 0x%02x)")
    :format(b or 0, door.open, door.closed))
  if b ~= door.open then
    return C.fail(("the exit is sealed in a match: block 0x%02x"):format(b or 0))
  end
  -- and the walk out
  local left = false
  for _ = 1, 40 do
    U.hold(game, "up", 8)
    U.wait(10)
    if C.map() == NEXT then left = true break end
    if C.map() ~= ROOM then break end
  end
  if not left then
    return C.fail(("walked north and never left: at %s %s,%s"):format(
      tostring(C.map()), tostring(C.x()), tostring(C.y())))
  end
  U.log("DOOR: walked out of LORELEI's room into BRUNO's")

  -- LORELEI is still there to fight: her trainer is not marked beaten
  do
    U.teleport(game, ROOM, 4, 6, "up")
    U.wait(30)
    local ow = C.ow()
    local lorelei
    for _, npc in ipairs((ow and ow.npcs) or {}) do
      if npc.def and npc.def.name == "LORELEISROOM_LORELEI" then lorelei = npc end
    end
    if not lorelei then return C.fail("LORELEI is not in her room") end
    if ow:trainerDefeated(lorelei) then return C.fail("LORELEI reads as beaten -- the flag lever was pulled") end
    U.log("DOOR: LORELEI is still fightable")
  end

  -- out of the match: vanilla's seal must hold
  E.leave()
  U.wait(60)
  for _ = 1, 10 do U.tap(game, "a") U.wait(10) end
  U.teleport(game, ROOM, 4, 6, "up")
  U.wait(40)
  for _ = 1, 6 do U.tap(game, "a") U.wait(10) end
  local v = blockAt()
  U.log(("DOOR: outside a session the exit block reads 0x%02x"):format(v or 0))
  if v ~= door.closed then
    return C.fail(("outside a session the seal did not hold: block 0x%02x"):format(v or 0))
  end
  U.log("DOOR OK: open for the match, LORELEI fightable, sealed again outside it")
  love.event.quit(0)
  U.wait(30)
end
