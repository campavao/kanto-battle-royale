-- POK-64 scenario "duel", guest side: join by the published code, walk
-- into the host's eyeline in Pewter, WIN the lockstep duel, and assert
-- the loser's spill hit the ground and the finished match brought the lobby
-- back on its own (POK-144).
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

  -- ------- POK-113: this trainer's mark, for the other screen.
  --
  -- Deliberately BEFORE the walk to Pewter, and so on a different map from
  -- the post.  The engage sight-line has no consent step, so probing next
  -- to a posted trainer opens the duel instead -- which is exactly what the
  -- first run of this did, reporting "battle" where a menu was expected.
  -- The mark is wire state, not screen state, so distance costs nothing.
  --
  -- watching.txt is the handshake: the host writes it when it is ready to
  -- read, so each state is held while somebody is actually looking.
  if not L.waitFor(DIR, "watching.txt", 3600) then
    return C.fail("the host never said it was watching")
  end

  local function backOnTheMap(ticks)
    for _ = 1, ticks or 200 do
      if game.stack:top() == C.ow() then return true end
      U.tap(game, "b")
      U.wait(12)
    end
    return game.stack:top() == C.ow()
  end

  if not backOnTheMap(200) then
    return C.fail("could not get back to the map to start the mark probe")
  end
  if E.busy() ~= nil then
    return C.fail("walking should carry no mark, got " .. tostring(E.busy()))
  end
  L.put(DIR, "busy_map.txt", "1")
  U.wait(180)

  U.tap(game, "start")
  U.wait(60)
  if E.busy() ~= "menu" then
    return C.fail("the START menu should read as a menu, got " .. tostring(E.busy()))
  end
  L.put(DIR, "busy_menu.txt", "1")
  U.wait(420)             -- hold it open long enough to be seen from there

  if not backOnTheMap(200) then
    return C.fail("the START menu would not close")
  end
  if E.busy() ~= nil then
    return C.fail("putting it away should clear the mark, got " .. tostring(E.busy()))
  end
  L.put(DIR, "busy_clear.txt", "1")
  U.wait(240)
  U.log("PVP guest: mark probe done (map / menu / map)")

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
    if C.E().status() == "battle" then
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
  U.log("PVP guest: lockstep battle open")

  if not L.mashUntil(C, function() return E.phase() == "over" end, 4800) then
    return C.fail("the match never ended (the guest should have won)")
  end
  U.log("PVP guest: match over; checking the ground")
  local sp = E.spills() or {}
  U.log("PVP guest: spills visible after the win: " .. tostring(#sp))
  if #sp < 1 then return C.fail("the loser spilled nothing") end

  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 1200) then
    return C.fail("the finished match never returned the guest to the lobby")
  end
  U.log("PVP OK guest: duel won, spill seen, lobby again")
  love.event.quit(0)
  U.wait(10)
end
