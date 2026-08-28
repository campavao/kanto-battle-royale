-- POK-64 scenario "freeze", host side: total silence from the moment the
-- lockstep battle opens -- intro text included.  Without POK-65 this
-- froze the duel forever; with it the watchdog advances the text, the
-- silence drifts to the move menu, and the POK-59 shot clock forfeits us.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end

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
  U.log("PVP host: room " .. tostring(code))

  local both = false
  for _ = 1, 1800 do
    U.wait(10)
    if E.memberCount() >= 2 then
      both = true
      break
    end
  end
  if not both then return C.fail("the guest never joined") end
  U.log("PVP host: guest is in; starting the match")
  E.start()

  if not L.waitPhase(C, "match", 240) then
    return C.fail("never reached the match")
  end
  for _ = 1, 8 do
    U.tap(game, "a")
    U.wait(20)
  end
  U.wait(30)

  L.armParty(C, "RATTATA", 5, "TACKLE")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "down", 6)
  L.put(DIR, "posted.txt", "1")
  U.log("PVP host: posted; will freeze from the very first frame of battle")

  if not L.mashUntil(C, function() return E.status() == "battle" end, 2400) then
    return C.fail("the duel never started on the host side")
  end
  U.log("PVP host: battle open; total silence from here (intro included)")

  -- no input at all, from the intro on
  local frames, ended = 0, false
  for _ = 1, 60 * 150 do   -- up to 150s of pure waiting
    U.wait(1)
    frames = frames + 1
    if E.status() ~= "battle" then
      ended = true
      break
    end
  end
  if not ended then
    return C.fail("the frozen fight never ended -- the POK-65 hole is open")
  end
  local seconds = frames / 60
  U.log(("PVP host: the frozen fight ended after %.1fs"):format(seconds))
  if seconds < 15 then
    return C.fail(("it ended too fast (%.1fs) to be the clock"):format(seconds))
  end
  if not L.mashUntil(C, function() return E.status() == "out" end, 1200) then
    return C.fail("the frozen side was not the one eliminated")
  end
  U.log("PVP host: forfeited by the clock through total silence")

  if not L.mashUntil(C, function() return E.phase() == "over" end, 600) then
    return C.fail("the match never ended after the forfeit")
  end
  -- No button (POK-144).  There is nothing to press any more: every client
  -- arms its own ending when the match ends and takes it once the screen is
  -- quiet, so what this measures is the funnel, and it says so.  It said
  -- "PLAY AGAIN never returned this side" while calling an export that
  -- armed the same funnel a second time -- one thing measured, another
  -- reported.
  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 1200) then
    return C.fail("the finished match never returned this side to the lobby")
  end
  U.log("PVP OK host: froze, was clocked out anyway, lobby again")
  love.event.quit(0)
  U.wait(10)
end
