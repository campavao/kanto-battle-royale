-- POK-64 scenario "duel", host side: host the room, publish the code,
-- start the match with zero bots, take a post in Pewter, and LOSE the
-- duel on purpose -- the guest asserts the spill; this side asserts the
-- elimination and that PLAY AGAIN brings the lobby back.
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

  -- the sacrificial lamb: this side is here to lose the duel
  L.armParty(C, "RATTATA", 5, "TACKLE")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "down", 6)   -- face the street the guest walks up
  L.put(DIR, "posted.txt", "1")
  U.log("PVP host: posted at 16,18 facing down; awaiting the challenger")

  if not L.mashUntil(C, function() return E.status() == "battle" end, 2400) then
    return C.fail("the duel never started on the host side")
  end
  U.log("PVP host: lockstep battle open")

  if not L.mashUntil(C, function() return E.status() == "out" end, 4800) then
    return C.fail("the host never went out (it should have lost)")
  end
  U.log("PVP host: eliminated as planned")

  if not L.mashUntil(C, function() return E.phase() == "over" end, 600) then
    return C.fail("the match never ended after the elimination")
  end
  U.wait(300)   -- let the guest read the board before the reset
  E.playAgain()
  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 900) then
    return C.fail("PLAY AGAIN never returned this side to the lobby")
  end
  U.log("PVP OK host: duel fought, loss recorded, lobby again")
  love.event.quit(0)
  U.wait(10)
end
