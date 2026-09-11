-- POK-199 scenario "menu", guest side: the trainer in the PACK.
--
-- Stand at (11,18) in Pewter, under the GYM sign, three cells down the
-- row from the host's post, and open the START menu.  The host turns and
-- stares: the eyeline fires at a trainer in a menu now, and on THIS side
-- the menu has to come down for the challenge -- popped, not queued --
-- and the lockstep open over the bare overworld.  Then win the duel and
-- ride the funnel back to the lobby.
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

  -- the champion: this side is here to win the duel
  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")
  if not L.waitFor(DIR, "posted.txt", 3600) then
    return C.fail("the host never posted")
  end
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  -- From the SOUTH, in two legs, so our own eyeline never crosses the
  -- host on the way in (see guest_held.lua)
  if not L.goTo(C, "PEWTER_CITY", 11, 20, 300) then
    return C.fail(("never reached the approach; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  if not L.goTo(C, "PEWTER_CITY", 11, 18, 60) then
    return C.fail(("never reached the sign; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "up", 6)     -- face the sign at (11,17), not the host
  U.wait(30)
  if E.status() ~= "alive" or E.pending() then
    return C.fail("staging: something fired on the walk in (status "
                  .. tostring(E.status()) .. ", pending "
                  .. tostring(E.pending() and E.pending().to) .. ")")
  end

  -- ------- in the START menu, in their eyeline
  U.tap(game, "start")
  U.wait(60)
  if game.stack:top() == C.ow() then return C.fail("START did not open the menu") end
  if E.busy() ~= "menu" then
    return C.fail("the START menu should read as a menu, got " .. tostring(E.busy()))
  end
  L.put(DIR, "menu.txt", "1")
  -- the host stares; the challenge lands; the menu has to come down and
  -- the lockstep open -- with nothing pressed on this side
  local opened, popped = false, nil
  for _ = 1, 900 do
    if game.stack:top() == C.ow() and not popped then popped = U.frame() end
    if E.status() == "battle" then
      opened = true
      break
    end
    U.wait(1)
  end
  if not opened then
    return C.fail("no battle opened while the menu was up (status "
                  .. tostring(E.status()) .. ", queued " .. tostring(E.queued())
                  .. ", top " .. tostring(game.stack:top() == C.ow() and "map" or "menu") .. ")")
  end
  if E.queued() > 0 then
    return C.fail("the challenge was queued rather than answered (queued "
                  .. tostring(E.queued()) .. ")")
  end
  U.log(("PVP guest: the START menu came down%s and the lockstep opened (POK-199)")
        :format(popped and " at frame " .. popped or ""))

  if not L.mashUntil(C, function() return E.phase() == "over" end, 4800) then
    return C.fail("the match never ended (the guest should have won)")
  end
  U.log("PVP guest: match over")
  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 1200) then
    return C.fail("the finished match never returned the guest to the lobby")
  end
  U.log("PVP OK guest: challenged in a menu, menu popped, fought, won, lobby again")
  love.event.quit(0)
  U.wait(10)
end
