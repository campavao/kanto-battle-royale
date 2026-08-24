-- POK-64 scenario "stall", guest side: play honestly against a host who
-- goes silent -- submit moves, wait, and win when the shot clock
-- forfeits them.  Assert the win arrived and the lobby came back.
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
  E.setName("GUESTB")

  local code = L.waitFor(DIR, "code.txt", 3600)
  if not code then return C.fail("no room code ever appeared") end
  code = code:gsub("%s", "")
  local joined = false
  for _ = 1, 10 do
    E.join(code)
    for _ = 1, 120 do
      U.wait(10)
      if E.memberCount() >= 2 then
        joined = true
        break
      end
    end
    if joined then break end
  end
  if not joined then
    return C.fail("could not join " .. code .. ": " .. tostring(E.lastError()))
  end
  U.log("PVP guest: in room " .. code)

  if not L.waitPhase(C, "match", 360) then
    return C.fail("never reached the match")
  end
  for _ = 1, 8 do
    U.tap(game, "a")
    U.wait(20)
  end
  U.wait(30)

  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.waitFor(DIR, "posted.txt", 3600) then
    return C.fail("the host never posted")
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 20, 300) then
    return C.fail(("never reached the approach; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.log("PVP guest: below the post; stepping into the eyeline")

  local fought = false
  for _ = 1, 60 do
    if E.status() == "battle" then
      fought = true
      break
    end
    U.hold(game, "up", 12)
    U.wait(10)
    U.tap(game, "a")
    U.wait(10)
  end
  if not fought then
    fought = L.mashUntil(C, function() return E.status() == "battle" end, 1200)
  end
  if not fought then return C.fail("the duel never started on the guest side") end
  U.log("PVP guest: lockstep battle open; playing honestly vs the stall")

  if not L.mashUntil(C, function() return E.phase() == "over" end, 9600) then
    return C.fail("the stalled host was never forfeited")
  end
  U.log("PVP guest: won when the clock forfeited them")

  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 1200) then
    return C.fail("PLAY AGAIN never reached the guest")
  end
  U.log("PVP OK guest: honest side won by forfeit, lobby again")
  love.event.quit(0)
  U.wait(10)
end
