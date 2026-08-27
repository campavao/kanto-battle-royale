-- Scenario "door", guest side: a client that reports a DIFFERENT engine
-- release, so the room's door has something real to find (POK-142).
--
-- The skew scenario next door forces Handshake.checkCompat and so tests
-- the ENGINE's refusal.  This tests ours, which happens hours earlier in a
-- player's evening: at the join, in the lobby, before anyone has dropped.
--
-- The fake goes in through lib/seams.lua rather than through
-- src/core/Version, and BEFORE the room is opened.  main.lua's build() is
-- lazy and memoised on its first call (the join announcement), so patching
-- the source it reads is enough and nothing else in the engine is lied to
-- -- the handshake, the fingerprint and the launcher all still see the
-- real numbers.  What is being tested is whether the ROOM notices, not
-- whether the engine does.
--
--   python mods/battle_royale/tests/drivers/pvp/run_pvp.py door
--
-- Set BR_SHOTS to a PRE-CREATED directory -- U.shot's mkdir is a bash-ism
-- that silently fails under LOVE on Windows, so an absent parent means no
-- files and no error.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

-- The lobby as the player actually sees it: the ROYALE screen's own rows.
-- Reading these rather than only E.door() is the difference between "the
-- mod worked it out" and "the player was told" -- and the screenshots are
-- of this screen, so a shot with no mark in it would otherwise still pass.
local function rows(C)
  local menu = C.game.stack:top()
  if not (menu and menu.items) then return nil end
  local out = {}
  for _, it in ipairs(menu.items) do out[#out + 1] = tostring(it.label) end
  return out
end

local function hasRow(list, want)
  for _, l in ipairs(list or {}) do if l == want then return true end end
  return false
end

-- Not a version that has ever existed: a real tag would read as a real
-- install in a log, and short keeps the rendered row inside the box.
local FAKE_ENGINE = "9.9.9"

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local SHOTS = os.getenv("BR_SHOTS")

  local Seams = require("mods.battle_royale.lib.seams")
  local real = Seams.engineVersion()
  Seams.engineVersion = function() return FAKE_ENGINE end
  U.log(("PVP guest: reporting engine %s (really %s)"):format(
    FAKE_ENGINE, tostring(real)))

  local n = 0
  local function shot(tag)
    if not SHOTS then return end
    n = n + 1
    U.shot(game, ("%s/guest_%02d_%s.png"):format(SHOTS, n, tag))
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  if not E.door then return C.fail("this build has no door export") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("GUESTB")

  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(45)
  if not rows(C) then
    return C.fail("the ROYALE screen did not open")
  end

  local code = L.waitFor(DIR, "code.txt", 3000)
  if not code then return C.fail("the host never published a code") end
  code = code:gsub("%s+", "")
  U.log("PVP guest: joining " .. code)
  E.join(code)

  L.put(DIR, "joined.txt", "1")

  -- ------- the whole point: we get in, and we are put straight back out
  --
  -- Do NOT try to catch the client inside the room.  The first cut polled
  -- memberCount() >= 2 to prove it had got in, and failed every time --
  -- the relay's own log put the stay at 18 MILLISECONDS between "GUESTB
  -- joined" and "GUESTB left", far under the sampling interval.  The
  -- refusal is the durable fact, so that is what is read; the host proves
  -- the other half by seeing us arrive.
  local refused = false
  for i = 1, 900 do
    U.wait(10)
    if (E.door() or {}).refused then
      refused = true
      U.log("PVP guest: refused after " .. i .. " ticks")
      break
    end
  end
  if not refused then
    return C.fail("never refused the room (phase " .. tostring(E.phase())
                  .. ", error " .. tostring(E.lastError()) .. ")")
  end
  if E.phase() ~= "off" then
    return C.fail("refused but still in phase " .. tostring(E.phase()))
  end
  if E.memberCount() ~= 0 then
    return C.fail("still holding a roster of " .. tostring(E.memberCount()))
  end

  -- ...and the screen it landed on is the explanation
  U.wait(45)
  local list = rows(C)
  if not list then return C.fail("the ROYALE screen left the stack") end
  for _, l in ipairs(list) do U.log("PVP guest: row | " .. l) end
  if not hasRow(list, "CANNOT JOIN") then
    return C.fail("the refusal screen does not say it cannot join")
  end
  if not hasRow(list, "UPDATE THE GAME") then
    return C.fail("the refusal screen does not say what to update")
  end
  if not hasRow(list, "GAME v" .. FAKE_ENGINE) then
    return C.fail("the refusal screen does not name our own (faked) engine")
  end
  if not hasRow(list, "OK") then
    return C.fail("the refusal screen has no way out of it")
  end
  -- ...and the room's build, which is the number they have to match
  local named = false
  for _, l in ipairs(list) do
    if l:find("^GAME v") and l ~= "GAME v" .. FAKE_ENGINE then named = true end
  end
  if not named then
    return C.fail("the refusal screen never names the ROOM's engine release")
  end

  shot("refused")
  for _ = 1, 3 do U.wait(40) shot("refused") end

  L.put(DIR, "guestdone.txt", "1")
  if not L.waitFor(DIR, "hostdone.txt", 3000) then
    return C.fail("the host never finished")
  end
  U.log("PVP OK guest: refused the room, " .. tostring(n) .. " frames captured")
  love.event.quit(0)
  U.wait(10)
end
