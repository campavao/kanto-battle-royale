-- POK-64 scenario "stall", host side: same duel, but the moment the
-- lockstep battle opens this side goes SILENT.  Lockstep means the
-- guest's move cannot resolve until we submit -- so only the POK-59
-- shot clock can end this, by forfeiting us.  Assert the forfeit takes
-- clock-time (not an instant KO), then ride the loss to PLAY AGAIN.
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
  U.log("PVP host: posted; will stall the moment the battle opens")

  if not L.mashUntil(C, function() return E.status() == "battle" end, 2400) then
    return C.fail("the duel never started on the host side")
  end
  U.log("PVP host: lockstep battle open; advancing to the move menu")
  -- the clock only covers move select (the intro hole is POK-65): press
  -- through the opening text until the battle reaches the menu, THEN stall
  local atMenu = false
  for _ = 1, 1200 do
    local top = game.stack:top()
    if top and top.phase == "menu" then
      atMenu = true
      break
    end
    if E.status() ~= "battle" then break end
    U.tap(game, "a")
    U.wait(10)
  end
  if not atMenu then return C.fail("never reached the move menu to stall in") end
  U.log("PVP host: at the move menu; going silent for the shot clock")

  -- silence: no input at all; count frames until the clock forfeits us
  local frames, out = 0, false
  for _ = 1, 60 * 150 do   -- up to 150s of pure waiting
    U.wait(1)
    frames = frames + 1
    if E.status() ~= "battle" then
      out = true
      break
    end
  end
  if not out then return C.fail("the shot clock never ended the stalled fight") end
  local seconds = frames / 60
  U.log(("PVP host: the fight ended after %.1fs of silence"):format(seconds))
  if seconds < 15 then
    return C.fail(("forfeit came too fast (%.1fs) to be the clock"):format(seconds))
  end
  if not L.mashUntil(C, function() return E.status() == "out" end, 1200) then
    return C.fail("the stalled side was not the one eliminated")
  end
  U.log("PVP host: forfeited by the clock, as designed")

  if not L.mashUntil(C, function() return E.phase() == "over" end, 600) then
    return C.fail("the match never ended after the forfeit")
  end
  U.wait(300)
  E.playAgain()
  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 900) then
    return C.fail("PLAY AGAIN never returned this side to the lobby")
  end
  U.log("PVP OK host: stalled, clocked out, lobby again")
  love.event.quit(0)
  U.wait(10)
end
