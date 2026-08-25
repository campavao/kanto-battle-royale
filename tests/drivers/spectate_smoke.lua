-- POK-72 hunt: does the client survive a wave of trainers dying while you
-- are spectating?
--
-- The playtest report: several trainers seemed to die at about the same
-- time, the camera ended up "back at my body maybe (or some body)", and
-- nothing worked — no movement, START did nothing, force-close.
--
-- Staged the way it was found rather than the way it is convenient: a short
-- fog clock and a roster of bots, standing still until the fog takes you,
-- then spectating while it takes everyone else. Bots share the ring, so
-- they cross TICKS_TO_KILL in clumps — which is the "at about the same
-- time" the report describes, and the tick that runs eliminateBot several
-- times in one pass.
--
-- What it asserts, after the wave:
--   * the mod's tick did not throw (it runs behind ONE pcall, so a throw
--     is swallowed and the tick's LAST step — releasing the camera — never
--     runs);
--   * the START menu still opens;
--   * the camera is not left owning the player: no hidden, walk-through
--     body with a stale pan once the match is over.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-spectate POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/spectate_smoke.lua \
--   <path to>/lovec . > spectate.log 2>&1
--
-- `SPEC OK` passes it; any `PVP FAIL` line fails it.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("GHOST")
  E.setSafari(0)
  E.setFog(30)          -- the whole ring cycle in half a minute
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(8)          -- enough that the fog takes them in clumps

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
  U.log(("SPEC: in the match on %s, %s alive"):format(
    tostring(C.map()), tostring(E.aliveCount())))

  -- Staged, not waited for.  Whether the fog reaches YOU depends on where
  -- you dropped -- the first attempt spent a whole match sitting safely
  -- next to the eye -- and whether it reaches several bots AT ONCE is
  -- exactly the thing under test, so neither is left to chance:
  --
  --   1. step out (debugOut) to reach the spectator camera at all;
  --   2. herd every surviving bot onto ONE map, so they share a ring
  --      verdict and cross TICKS_TO_KILL together;
  --   3. let the ring take that map, and watch the tick that runs
  --      eliminateBot several times in one pass.
  if not E.debugOut("staged") then return C.fail("debugOut refused") end
  if not L.mashUntil(C, function() return E.status() == "out" end, 200) then
    return C.fail("never went out (status " .. tostring(E.status()) .. ")")
  end
  U.log(("SPEC: out on %s; %s still up, watching %s"):format(
    tostring(C.map()), tostring(E.aliveCount()), tostring(E.watching())))
  shot("spectating")

  -- ONE BOT PER TOWN, deliberately.  The first attempt herded them all
  -- onto one map, and they simply fought each other -- tickBots hunts the
  -- nearest trainer, so a crowd resolves itself one duel at a time, which
  -- is the opposite of the tick under test.  Spread out they cannot reach
  -- each other, so the only thing that can kill them is the ring; and a
  -- shrink flips many maps from safe to fog on the SAME frame, so they
  -- start their fog clocks together and cross TICKS_TO_KILL together.
  local TOWNS = {
    "PALLET_TOWN", "VIRIDIAN_CITY", "PEWTER_CITY", "CERULEAN_CITY",
    "VERMILION_CITY", "LAVENDER_TOWN", "CELADON_CITY", "FUCHSIA_CITY",
    "SAFFRON_CITY", "CINNABAR_ISLAND",
  }
  local penned, ti = 0, 0
  for _, b in ipairs(E.bots() or {}) do
    if b.status ~= "out" then
      ti = ti + 1
      local town = TOWNS[((ti - 1) % #TOWNS) + 1]
      local def = game.data.maps[town]
      -- a cell the map actually has; the middle of any town is walkable
      local cx = def and math.floor(def.width) or 5
      local cy = def and math.floor(def.height) or 5
      if E.debugPlaceBot(b.id, town, cx, cy) then penned = penned + 1 end
    end
  end
  U.log(("SPEC: %d bots scattered one per town"):format(penned))
  if penned < 3 then
    return C.fail("could not stage a wave: only " .. penned .. " bots placed")
  end
  -- ...and now watch the ring take them, which is the tick under test
  local low = E.aliveCount() or 99
  local biggestDrop = 0        -- how many went down between two samples
  for _ = 1, 2400 do
    U.tap(game, "a")
    U.wait(8)
    local n = E.aliveCount() or 0
    if n < low then
      if (low - n) > biggestDrop then biggestDrop = low - n end
      low = n
      U.log(("SPEC: down to %d, watching %s, err %s"):format(
        n, tostring(E.watching()), tostring(E.tickError())))
    end
    if E.phase() == "over" then break end
  end
  U.log(("SPEC: the wave is through — phase %s, %d alive, biggest drop %d"):format(
    tostring(E.phase()), E.aliveCount() or -1, biggestDrop))
  if biggestDrop < 2 then
    U.log("SPEC: note — they went down one at a time, not in a wave")
  end
  shot("after-wave")
  -- ---------------------------------------------------------- the verdict
  local err = E.tickError()
  local probe = E.cameraProbe() or {}
  U.log(("SPEC: probe phase=%s status=%s watching=%s owned=%s hidden=%s "
         .. "passable=%s panned=%s onOverworld=%s moving=%s transitioning=%s"):format(
    tostring(probe.phase), tostring(probe.status), tostring(probe.watching),
    tostring(probe.cameraOwned), tostring(probe.hidden), tostring(probe.passable),
    tostring(probe.panned), tostring(probe.onOverworld), tostring(probe.moving),
    tostring(probe.transitioning)))

  if err then
    return C.fail("the mod's tick threw during the wave: " .. tostring(err))
  end

  -- can we still open a menu?  This is the user's "START does nothing".
  local rows
  for _ = 1, 20 do
    U.tap(game, "start")
    U.wait(20)
    local top = game.stack:top()
    if type(top) == "table" and type(top.items) == "table" then
      rows = #top.items
      U.tap(game, "b")
      U.wait(10)
      break
    end
    if top ~= game.overworld then U.tap(game, "b") U.wait(10) end
  end
  if not rows then
    return C.fail("START does nothing after the wave — the reported freeze")
  end

  -- and the camera must have let go of the body once the match ended
  if probe.phase ~= "match" and (probe.hidden or probe.passable or probe.panned) then
    return C.fail(("the camera still owns the body at phase %s "
                   .. "(hidden=%s passable=%s panned=%s)"):format(
      tostring(probe.phase), tostring(probe.hidden),
      tostring(probe.passable), tostring(probe.panned)))
  end

  U.log(("SPEC OK: survived the wave, START opens %d rows, camera released"):format(rows))
  love.event.quit(0)
  U.wait(10)
end
