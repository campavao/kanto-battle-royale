-- Scenario "skew", guest side: join, walk into the host's eyeline, and try
-- to start a duel the handshake has already refused.  See host_skew.lua for
-- what this is reproducing and why the verdict is forced rather than staged
-- with two real engine builds.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local SHOTS = os.getenv("BR_SHOTS")

  -- both sides compute the same verdict off the same pair of hellos, so
  -- both sides refuse; patching only one would test a case that cannot
  -- happen in the wild
  local Handshake = require("src.link.Handshake")
  Handshake.checkCompat = function()
    return "engine_skew", "engine_release_mismatch"
  end

  local n = 0
  local function shot(tag)
    if not SHOTS then return end
    n = n + 1
    U.shot(game, ("%s/guest_%02d_%s.png"):format(SHOTS, n, tag))
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("GUESTB")

  local code = L.waitFor(DIR, "code.txt", 3600)
  if not code then return C.fail("no room code ever appeared") end
  code = code:gsub("%s", "")
  local joined = false
  for _ = 1, 10 do
    E.join(code)
    for _ = 1, 120 do
      U.wait(10)
      if E.memberCount() >= 2 then joined = true break end
    end
    if joined then break end
  end
  if not joined then
    return C.fail("could not join " .. code .. ": " .. tostring(E.lastError()))
  end

  if not L.waitPhase(C, "match", 360) then
    return C.fail("never reached the match")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")

  if not L.waitFor(DIR, "posted.txt", 3600) then
    return C.fail("the host never posted")
  end
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  -- Teleport rather than walk.  The walk is not what is under test here and
  -- the first cut spent so long on it that the host quit first; U.teleport
  -- is fine mid-match and puts the challenge inside the engage's column
  -- sight-line (4 cells) straight away.
  U.teleport(game, "PEWTER_CITY", 16, 21, "up")
  U.wait(24)
  shot("inposition")
  L.put(DIR, "inplace.txt", "1")

  for i = 1, 60 do
    U.hold(game, "up", 3)
    U.wait(14)
    if i % 3 == 0 then shot("step" .. i) end
    if E.status() == "battle" then
      U.log("PVP guest: a battle OPENED despite the refusal")
      for j = 1, 8 do U.wait(20) shot("battle" .. j) end
      break
    end
    if C.busy() and i > 4 then
      U.log("PVP guest: something is on screen at tick " .. i)
      for j = 1, 8 do U.wait(20) shot("onscreen" .. j) end
      break
    end
  end
  L.waitFor(DIR, "hostdone.txt", 600)

  U.wait(30)
  shot("final")
  U.log("PVP guest: status=" .. tostring(E.status())
        .. " phase=" .. tostring(E.phase())
        .. " busy=" .. tostring(C.busy()))
  U.log("PVP OK guest: skew staged, " .. tostring(n) .. " frames captured")
  love.event.quit(0)
  U.wait(10)
end
