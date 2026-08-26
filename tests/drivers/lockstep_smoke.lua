-- POK-126 smoke: CERULEAN's Rocket thief does not get to grab a match.
--
-- Two runs, because a check that only ever sees "nothing happened" cannot
-- tell a working guard from a trigger that was never there:
--
--   BR_LOCKSTEP_CONTROL=1   no match.  Stepping on (30,7) MUST start the
--                           vanilla scene -- that proves the trap is real,
--                           that this driver can see it, and that the mod
--                           leaves ordinary playthroughs alone.
--   (unset)                 in a match.  The same step must do nothing at
--                           all: we keep walking, no textbox, no runner.
--
-- YELLOW's JESSIE and JAMES (POK-127) cannot be smoked from here -- there
-- is no Yellow ROM in this setup -- so their cells are pinned against the
-- vanilla handlers by the coupling block in tests/br_test.lua instead.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-lockstep POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/lockstep_smoke.lua \
--   <path to>/lovec . > lockstep.log 2>&1
--
-- A `LOCKSTEP OK` line passes; any `PVP FAIL` line fails (the failure
-- channel is pvplib's, shared with the rest of the drivers).

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local THIEF = { { 30, 7 }, { 30, 9 } }

return function(game)
  local C = L.ctx(game)
  local control = os.getenv("BR_LOCKSTEP_CONTROL") == "1"

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  if not control then
    -- A solo room with nothing else going on: no SAFARI phase to sit
    -- through, no bots to wander into, and the fog kept far enough out
    -- that it cannot be what moves us.
    E.setName("SCOUT")
    E.setSafari(0)
    E.setFog(600)
    if not E.hostSolo() then return C.fail("hostSolo refused") end
    E.setBots(0)

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
  end

  U.log(("LOCKSTEP: %s"):format(control and "control run (no match)"
                                        or "in a match"))

  -- Walk onto each trigger cell from the tile between them.  Approaching on
  -- foot matters: onStep is what we are testing, and a teleport straight
  -- onto the cell would never fire it.
  for _, cell in ipairs(THIEF) do
    local cx, cy = cell[1], cell[2]
    U.teleport(game, "CERULEAN_CITY", 30, 8, cy < 8 and "up" or "down")
    U.wait(24)
    if C.map() ~= "CERULEAN_CITY" then
      return C.fail("teleport did not land in CERULEAN; at " .. tostring(C.map()))
    end
    if C.busy() then
      return C.fail(("something was already up before the step at %d,%d"):format(cx, cy))
    end

    U.tap(game, cy < 8 and "up" or "down")
    U.wait(28)

    local ow = C.ow()
    local running = ow and ow.runner and ow.runner:isRunning()
    local grabbed = C.busy() or running == true

    if control then
      -- Vanilla must still do the thing we are suppressing.  If this stops
      -- being true the cell moved, and the guard in lib/lockstep.lua is
      -- aimed at nothing.
      if not grabbed then
        return C.fail(("control: (%d,%d) did NOT start the thief scene -- "
                       .. "the trigger moved, so the match guard is aimed at "
                       .. "nothing"):format(cx, cy))
      end
      U.log(("LOCKSTEP: control (%d,%d) fired, as it should"):format(cx, cy))
      -- one cell is proof enough; the scene is running and there is no
      -- clean way back out of it mid-run
      break
    end

    if grabbed then
      return C.fail(("(%d,%d) still grabbed us mid-match (busy=%s running=%s)")
        :format(cx, cy, tostring(C.busy()), tostring(running)))
    end
    if C.x() ~= cx or C.y() ~= cy then
      return C.fail(("the step onto (%d,%d) did not happen; at %s,%s")
        :format(cx, cy, tostring(C.x()), tostring(C.y())))
    end
    U.log(("LOCKSTEP: walked (%d,%d) clean"):format(cx, cy))
  end

  -- ------- the talk half.  He arms the identical scene from a
  -- conversation (story5.lua points TEXT_CERULEANCITY_ROCKET straight at
  -- rocketRows), so guarding the two cells is only half the fix -- without
  -- the world.talk branch the whole cutscene is one A press away.
  if not control then
    local ow = C.ow()
    local rocket
    for _, npc in ipairs((ow and ow.npcs) or {}) do
      if npc.def and npc.def.name == "CERULEANCITY_ROCKET" then rocket = npc end
    end
    if not rocket then
      return C.fail("no CERULEANCITY_ROCKET on the map to talk to")
    end

    local rx, ry = rocket.cellX, rocket.cellY
    U.teleport(game, "CERULEAN_CITY", rx, ry + 1, "up")
    U.wait(24)

    U.tap(game, "a")
    U.wait(24)
    -- He is SUPPOSED to answer -- the guard replaces his scene with a line,
    -- it does not make him mute -- so a textbox here is the pass, not the
    -- failure.  What must not be behind it is the battle.
    local spoke = C.busy()

    -- Close it by asking each time instead of mashing a fixed count: every
    -- A press while still facing him just re-opens the conversation, so a
    -- blind mash always ends holding a box open and looks like a hang.
    local top = game.stack:top()
    for _ = 1, 30 do
      if not C.busy() then break end
      top = game.stack:top()
      if top and top.enemy then
        return C.fail("talking to the thief started a BATTLE -- the scene ran")
      end
      U.tap(game, "a")
      U.wait(12)
    end
    U.wait(24)

    if not spoke then
      return C.fail("the thief said nothing at all -- the talk guard never ran")
    end
    if C.map() ~= "CERULEAN_CITY" then
      return C.fail("talking to the thief moved us to " .. tostring(C.map()))
    end
    if C.busy() then
      top = game.stack:top()
      return C.fail(("talking to the thief left %s on screen"):format(
        tostring(top and (top.phase or top.name) or top)))
    end
    if ow.runner and ow.runner:isRunning() then
      return C.fail("talking to the thief started a script")
    end
    U.log(("LOCKSTEP: talked to the thief at (%d,%d), a line and no scene")
      :format(rx, ry))
  end

  U.log("LOCKSTEP OK")
  game.driverDone = true
end
