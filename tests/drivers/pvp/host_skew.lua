-- Scenario "skew", host side: two clients that CANNOT lockstep together.
--
-- A live playtest hit this for real -- one player on a source checkout
-- (Version.engine is the "0.0.0-dev" placeholder; CI stamps the real
-- number into the packed game.love only) and one on a packed build.  The
-- handshake returns engine_skew, Handshake.battleAllowed refuses it, and
-- LinkBattle.new hands back nil plus "Link battle needs the same version
-- and mods."  That is a clean message.  What the player actually SAW was a
-- debug screen, so something between that return and the screen is not
-- handling it.
--
-- Rather than guess which path swallowed it, this stages the refusal and
-- photographs whatever comes up.  The verdict is forced rather than faked
-- with two real builds: checkCompat is the one function every caller goes
-- through (LinkState:225), so overriding it produces the same refusal a
-- genuine version gap does, without needing two engines installed.
--
--   python mods/battle_royale/tests/drivers/pvp/run_pvp.py skew
--
-- Set BR_SHOTS to a PRE-CREATED directory -- U.shot's mkdir is a bash-ism
-- that silently fails under LOVE on Windows, so an absent parent means no
-- files and no error.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local SHOTS = os.getenv("BR_SHOTS")

  -- ------- make the two builds incompatible, before anything links
  local Handshake = require("src.link.Handshake")
  Handshake.checkCompat = function()
    return "engine_skew", "engine_release_mismatch"
  end
  U.log("PVP host: verdict forced to engine_skew")

  local n = 0
  local function shot(tag)
    if not SHOTS then return end
    n = n + 1
    U.shot(game, ("%s/host_%02d_%s.png"):format(SHOTS, n, tag))
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("HOSTA")
  E.setBots(0)
  E.setSafari(0)
  E.setFog(600)
  E.host()

  local code = nil
  for _ = 1, 600 do
    U.wait(10)
    code = E.code()
    if code then break end
  end
  if not code then
    return C.fail("hosting never produced a code: " .. tostring(E.lastError()))
  end
  L.put(DIR, "code.txt", tostring(code))

  local both = false
  for _ = 1, 1800 do
    U.wait(10)
    if E.memberCount() >= 2 then both = true break end
  end
  if not both then return C.fail("the guest never joined") end
  E.start()

  if not L.waitPhase(C, "match", 240) then
    return C.fail("never reached the match")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  L.armParty(C, "RATTATA", 5, "TACKLE")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s")
      :format(tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "down", 6)
  U.wait(20)
  shot("posted")
  L.put(DIR, "posted.txt", "1")
  U.log("PVP host: posted, awaiting a challenger who cannot lockstep")

  -- ------- the whole point: photograph whatever the refusal produces.
  --
  -- The first cut of this quit while the guest was still walking over, and
  -- the only thing it proved was that "The host left." renders correctly.
  -- So the host now waits on a file the guest writes when it is IN POSITION
  -- and holds station long past it.
  if not L.waitFor(DIR, "inplace.txt", 6000) then
    return C.fail("the guest never got into position")
  end
  U.log("PVP host: challenger in position; watching for the refusal")

  local sawBattle = false
  for i = 1, 200 do
    U.wait(15)
    if i % 4 == 0 then shot("wait" .. i) end
    if E.status() == "battle" then
      sawBattle = true
      U.log("PVP host: a battle OPENED despite the refusal -- verdict ignored")
      for j = 1, 8 do U.wait(20) shot("battle" .. j) end
      break
    end
    if C.busy() and i > 8 then
      U.log("PVP host: something is on screen at tick " .. i)
      for j = 1, 8 do U.wait(20) shot("onscreen" .. j) end
      break
    end
  end
  if not sawBattle then
    U.log("PVP host: no battle opened (which is the refusal working)")
  end
  L.put(DIR, "hostdone.txt", "1")

  U.wait(30)
  shot("final")
  U.log("PVP host: status=" .. tostring(E.status())
        .. " phase=" .. tostring(E.phase())
        .. " busy=" .. tostring(C.busy()))
  U.log("PVP OK host: skew staged, " .. tostring(n) .. " frames captured")
  love.event.quit(0)
  U.wait(10)
end
