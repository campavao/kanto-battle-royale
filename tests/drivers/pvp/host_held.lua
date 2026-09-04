-- POK-162 scenario "held", host side: the challenger.
--
-- The guest stands three cells down the row from this post, first in the
-- START menu and then reading the GYM sign.  Two things are asserted:
--
--   1. the eyeline HOLDS OFF a trainer in a menu -- facing straight at
--      them opens nothing while their mark is up (the mark now covers a
--      dialog too, which is the nurse);
--   2. a challenge that LANDS while they are reading is queued on their
--      side and answered the moment the dialog closes -- the lockstep
--      opens on both screens, instead of half-opening under their dialog
--      and wedging both clients for the rest of the match.
--
-- The challenge in (2) is sent through debugChallenge, because after (1)
-- the eyeline will not fire one at a busy trainer any more.  Then this
-- side loses the duel on purpose and rides the funnel back to the lobby,
-- which proves the match still resolves.
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
  -- The post: (14,18), three cells east of where the guest reads the GYM
  -- sign at (11,18).  Faced UP first -- (14,17) is a wall, so the eyeline
  -- is blocked on its first cell and nothing can fire while the guest
  -- walks in; every turn toward them below is deliberate.
  if not L.goTo(C, "PEWTER_CITY", 14, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "up", 6)
  L.put(DIR, "posted.txt", "1")
  U.log("PVP host: posted at 14,18 facing the wall")

  local function guest()
    local ps = E.players() or {}
    return ps[1]
  end
  local function awaitBusy(want, ticks)
    for _ = 1, ticks or 400 do
      local g = guest()
      if g and g.busy == want then return true end
      U.wait(10)
    end
    return false
  end

  -- ------- 1. the eyeline holds off a trainer in a menu
  if not L.waitFor(DIR, "menu.txt", 3600) then
    return C.fail("the guest never opened its menu at the sign")
  end
  if not awaitBusy("menu", 300) then
    return C.fail("the guest's menu never reached this screen, got "
                  .. tostring(guest() and guest().busy))
  end
  U.hold(game, "left", 6)   -- straight at them, three cells away
  for _ = 1, 240 do         -- four seconds of staring
    if E.status() == "battle" or E.pending() then
      return C.fail("the eyeline fired at a trainer in a menu (status "
                    .. tostring(E.status()) .. ", pending "
                    .. tostring(E.pending() and E.pending().to) .. ")")
    end
    U.wait(1)
  end
  U.log("PVP host: stared at a trainer in a menu for 4s; nothing fired")
  U.hold(game, "up", 6)     -- back to the wall before they close it
  U.wait(20)
  L.put(DIR, "facedaway.txt", "1")

  -- ------- 2. a challenge that lands mid-dialog is queued, then answered
  if not L.waitFor(DIR, "reading.txt", 3600) then
    return C.fail("the guest never started reading the sign")
  end
  if not awaitBusy("menu", 120) then
    return C.fail("a trainer reading a sign should be marked busy, got "
                  .. tostring(guest() and guest().busy))
  end
  U.log("PVP host: the guest is marked busy while reading a sign")
  local g = guest()
  if not (g and g.id) then return C.fail("no guest to challenge") end
  if not E.debugChallenge(g.id) then
    return C.fail("debugChallenge refused (status " .. tostring(E.status())
                  .. ", pending " .. tostring(E.pending() and E.pending().to) .. ")")
  end
  local pend = E.pending()
  if not (pend and pend.to == g.id) then
    return C.fail("the challenge left no pending on this side")
  end
  L.put(DIR, "challenged.txt", "1")
  U.log("PVP host: challenged the reader (nonce " .. tostring(pend.nonce) .. ")")

  -- No mashing while we wait: an A here could open something of our own,
  -- and this side's screen is meant to be quiet so the accept opens the
  -- battle directly.  Ten seconds is generous -- the dialog closes on
  -- its own inside five, and the flash is under one.
  local opened = false
  for _ = 1, 600 do
    if E.status() == "battle" then
      opened = true
      break
    end
    U.wait(1)
  end
  if not opened then
    return C.fail("the queued challenge never opened a battle here (status "
                  .. tostring(E.status()) .. ", pending "
                  .. tostring(E.pending() and E.pending().to) .. ")")
  end
  U.log("PVP host: lockstep battle open, from a challenge that landed mid-dialog")

  -- ...and the match still resolves: lose it, watch the funnel
  if not L.mashUntil(C, function() return E.status() == "out" end, 4800) then
    return C.fail("the host never went out (it should have lost)")
  end
  U.log("PVP host: eliminated as planned")
  if not L.mashUntil(C, function() return E.phase() == "over" end, 600) then
    return C.fail("the match never ended after the elimination")
  end
  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 1200) then
    return C.fail("the finished match never returned this side to the lobby")
  end
  U.log("PVP OK host: held off a menu, queued a mid-dialog challenge, fought, lobby again")
  love.event.quit(0)
  U.wait(10)
end
