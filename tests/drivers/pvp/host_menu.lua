-- POK-199 scenario "menu", host side: the challenger.
--
-- The guest stands three cells down the row from this post, in the START
-- menu.  Facing straight at them must FIRE the eyeline -- a trainer in a
-- menu is a target now, not a shielded one -- and the lockstep must open
-- on both screens: theirs pops the menu for it.  Then this side loses
-- the duel on purpose and rides the funnel back to the lobby, which
-- proves the match still resolves.
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
  -- The post: (14,18), three cells east of the guest's (11,18).  Faced UP
  -- first -- (14,17) is a wall, so the eyeline is blocked on its first
  -- cell and nothing can fire while the guest walks in.
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

  -- ------- the eyeline fires at a trainer in a menu
  if not L.waitFor(DIR, "menu.txt", 3600) then
    return C.fail("the guest never opened its menu at the sign")
  end
  if not awaitBusy("menu", 300) then
    return C.fail("the guest's menu never reached this screen, got "
                  .. tostring(guest() and guest().busy))
  end
  U.hold(game, "left", 6)   -- straight at them, three cells away
  local fired = false
  for _ = 1, 300 do
    if E.status() == "battle" or E.pending() then fired = true break end
    U.wait(1)
  end
  if not fired then
    return C.fail("the eyeline did not fire at a trainer in a menu (status "
                  .. tostring(E.status()) .. ")")
  end
  U.log("PVP host: the eyeline fired at a trainer in a menu")
  -- their menu comes down for it, and the lockstep opens here too
  local opened = false
  for _ = 1, 900 do
    if E.status() == "battle" then
      opened = true
      break
    end
    U.wait(1)
  end
  if not opened then
    return C.fail("the challenge never opened a battle here (status "
                  .. tostring(E.status()) .. ", pending "
                  .. tostring(E.pending() and E.pending().to) .. ")")
  end
  U.log("PVP host: lockstep battle open against a trainer who was in a menu (POK-199)")

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
  U.log("PVP OK host: challenged a trainer in a menu, fought, lobby again")
  love.event.quit(0)
  U.wait(10)
end
