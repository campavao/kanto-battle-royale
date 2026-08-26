-- POK-134 smoke: another mod is stood down for the match, and GETS PUT BACK.
--
-- The unit tests in br_test.lua cover lib/coexist.lua itself.  What they
-- cannot cover is the WIRING -- that startMatch really suspends and that
-- resetMatch really restores, on a real boot, through the mod's own
-- mod.find().  That is the half where a mistake costs a player their
-- overworld until they restart the game, so it gets a real run.
--
-- "Wilds of Kanto" is not installed here, so one is faked.  mod.find only
-- asks the loader for `mods[id]` with `enabled and not failed`
-- (Loader.lua isActive) plus `exports[id]`, so a stand-in registered
-- directly on the loader is indistinguishable from the real thing at the
-- point BR touches it.  Nothing about the fake is BR-shaped: it answers
-- the three exports the real mod publishes and records the order.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-coexist POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/coexist_smoke.lua \
--   <path to>/lovec . > coexist.log 2>&1
--
-- `COEXIST OK` passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local WILDS = "overworld_wild_spawns"

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  -- ------- stand a fake Wilds of Kanto up on the loader
  local loader = game.mods
  if not (loader and loader.mods and loader.exports) then
    return C.fail("no mod loader to register against")
  end

  local calls = {}
  local function record(name)
    return function() calls[#calls + 1] = name end
  end
  loader.mods[WILDS] = {
    enabled = true, failed = false,
    manifest = { id = WILDS, version = "2.2.0" },
  }
  loader.exports[WILDS] = {
    removeHooks = record("removeHooks"),
    clearAll = record("clearAll"),
    installHooks = record("installHooks"),
  }

  local function seen(name)
    local n = 0
    for _, c in ipairs(calls) do if c == name then n = n + 1 end end
    return n
  end

  -- ------- a match starts: it should stand down
  E.setName("SCOUT")
  E.setSafari(0)          -- straight to the drop; the suspend is not phased
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(0)

  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end

  if #calls > 0 then
    return C.fail("something was suspended before the match started: "
                  .. table.concat(calls, ","))
  end

  E.start()
  if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  U.wait(30)

  if seen("removeHooks") ~= 1 then
    return C.fail(("removeHooks called %d times at match start, wanted 1 (%s)")
      :format(seen("removeHooks"), table.concat(calls, ",")))
  end
  if seen("clearAll") ~= 1 then
    return C.fail(("clearAll called %d times at match start, wanted 1")
      :format(seen("clearAll")))
  end
  if seen("installHooks") ~= 0 then
    return C.fail("the hooks went back on while the match was still running")
  end
  U.log("COEXIST: stood down at match start (" .. table.concat(calls, ",") .. ")")

  -- ------- and the way back
  E.leave()
  U.wait(60)
  for _ = 1, 40 do
    if seen("installHooks") > 0 then break end
    U.tap(game, "b")
    U.wait(10)
  end

  if seen("installHooks") ~= 1 then
    return C.fail(("installHooks called %d times after leaving, wanted 1 -- "
                   .. "the player would be left without their overworld (%s)")
      :format(seen("installHooks"), table.concat(calls, ",")))
  end
  U.log("COEXIST: restored on the way out (" .. table.concat(calls, ",") .. ")")

  -- ------- leaving twice must not double-install
  local before = seen("installHooks")
  E.leave()
  U.wait(40)
  if seen("installHooks") ~= before then
    return C.fail("a second leave installed the hooks again")
  end

  -- ------- the second net: a restore that does NOT go through resetMatch.
  -- resetMatch is this mod's own code, so a fault between the suspend and
  -- the exit would strand somebody else's game.  The save events are the
  -- engine's, so they still arrive when this mod is the thing that broke.
  -- Staged by starting a fresh match and then walking into a NEW GAME
  -- without ever leaving properly.
  do
    if not E.hostSolo() then return C.fail("second hostSolo refused") end
    E.setBots(0)
    local up = false
    for _ = 1, 300 do
      U.wait(10)
      if (E.memberCount() or 0) >= 1 then up = true break end
    end
    if not up then return C.fail("the second solo room never came up") end
    E.start()
    if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
      return C.fail("never reached the second match")
    end
    U.wait(30)

    local suspendedAgain = seen("removeHooks")
    if suspendedAgain ~= 2 then
      return C.fail(("a second match did not suspend again (removeHooks=%d)")
        :format(suspendedAgain))
    end
    local before = seen("installHooks")

    -- no E.leave(): straight into the engine's own New Game, which is what
    -- a player abandoning a match outside our menu actually reaches.
    -- Game:startNewGame is the thing that raises save.created (Game.lua);
    -- U.newGame is no good here because it drives the TITLE screen, and
    -- mid-match the stack top is the overworld, so it would just mash the
    -- START menu and prove nothing.
    game:startNewGame()
    U.wait(60)

    if seen("installHooks") ~= before + 1 then
      return C.fail(("the save-event net did not restore: installHooks %d -> %d")
        :format(before, seen("installHooks")))
    end
    U.log("COEXIST: the save-event net restored without resetMatch")
  end

  U.log("COEXIST OK")
  game.driverDone = true
end
