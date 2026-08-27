-- POK-135 smoke: CERULEAN stays walkable when the thief scene is stood down.
--
-- POK-126 headed off the Rocket thief and did not notice that the scene it
-- suppressed was ALSO doing something load-bearing.  The fade at the end of
-- rocketRows swaps a pair of guards, and per data/scripts/story.lua:
--
--   "(27,12) is the ONLY walkable neighbour of the trashed house's south
--    door at (27,11) ... Leaving GUARD2 up forever severs the city -- the
--    gym/mart half can never reach the Route 5 exit."
--
-- A player hit it within a day: stuck against the pair, "The people here
-- were robbed."  That was reasoned about and got the wrong answer, so this
-- one is a real run rather than an argument.
--
-- Two directions, because "the tile is walkable" proves nothing on its own
-- unless the tile is genuinely blocked without the fix:
--
--   BR_CERULEAN_CONTROL=1  no match.  GUARD2 MUST still be standing on
--                          (27,12) -- vanilla is untouched, and the trap
--                          this repairs is real.
--   (unset)                in a match.  (27,12) must be clear and the
--                          player must be able to stand on it.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-cerulean POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/cerulean_smoke.lua \
--   <path to>/lovec . > cerulean.log 2>&1

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local GUARD2_X, GUARD2_Y = 27, 12          -- the one that severs the city
local DOOR_X, DOOR_Y = 27, 11              -- the trashed house's south door

return function(game)
  local C = L.ctx(game)
  local control = os.getenv("BR_CERULEAN_CONTROL") == "1"

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  if not control then
    E.setName("SCOUT")
    E.setSafari(0)
    E.setFog(600)
    if not E.hostSolo() then return C.fail("hostSolo refused") end
    E.setBots(0)
    local up = false
    for _ = 1, 300 do
      U.wait(10)
      if (E.memberCount() or 0) >= 1 then up = true break end
    end
    if not up then return C.fail("the solo room never came up") end
    E.start()
    if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
      return C.fail("never reached the match (" .. tostring(E.phase()) .. ")")
    end
    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    U.wait(30)
  end

  -- Land next to the pair.  (27,13) is directly below GUARD2's cell, which
  -- is the approach a player coming from the south half of the city takes.
  U.teleport(game, "CERULEAN_CITY", GUARD2_X, GUARD2_Y + 1, "up")
  U.wait(30)
  if C.map() ~= "CERULEAN_CITY" then
    return C.fail("teleport did not land in CERULEAN; at " .. tostring(C.map()))
  end

  local ow = C.ow()
  local function guardAt(x, y)
    for _, npc in ipairs((ow and ow.npcs) or {}) do
      if npc.cellX == x and npc.cellY == y then return npc end
    end
    return nil
  end

  local blocker = guardAt(GUARD2_X, GUARD2_Y)

  if control then
    -- vanilla must still be severed, or this repair is aimed at nothing
    if not blocker then
      return C.fail(("control: (%d,%d) was ALREADY clear with no match "
                     .. "running -- the repair is aimed at nothing")
        :format(GUARD2_X, GUARD2_Y))
    end
    U.log(("CERULEAN: control -- %s still holds (%d,%d), as vanilla should")
      :format(tostring(blocker.def and blocker.def.name), GUARD2_X, GUARD2_Y))
    U.log("CERULEAN OK")
    game.driverDone = true
    return
  end

  if blocker then
    return C.fail(("(%d,%d) is still held by %s -- the city is severed")
      :format(GUARD2_X, GUARD2_Y,
              tostring(blocker.def and blocker.def.name or "someone")))
  end

  -- and the swap's other half: GUARD1 should have taken (28,12)
  if not guardAt(28, 12) then
    U.log("CERULEAN: note -- GUARD1 is not on (28,12); the swap was half done")
  end

  -- Not just "no NPC there" -- actually walk onto it, then on to the door.
  U.tap(game, "up")
  U.wait(28)
  if C.x() ~= GUARD2_X or C.y() ~= GUARD2_Y then
    return C.fail(("could not step onto (%d,%d); at %s,%s")
      :format(GUARD2_X, GUARD2_Y, tostring(C.x()), tostring(C.y())))
  end
  U.log(("CERULEAN: walked onto (%d,%d)"):format(GUARD2_X, GUARD2_Y))

  U.tap(game, "up")
  U.wait(28)
  if C.y() ~= DOOR_Y and C.map() == "CERULEAN_CITY" then
    return C.fail(("reached (%d,%d) but could not go on to the door at (%d,%d)")
      :format(GUARD2_X, GUARD2_Y, DOOR_X, DOOR_Y))
  end
  U.log("CERULEAN: the house door is reachable -- the city is whole")

  U.log("CERULEAN OK")
  game.driverDone = true
end
