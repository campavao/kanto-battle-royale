-- A watcher arrives mid-match, host side (2026-09-07).  Host a match with
-- two bots, let the guest quick-play into it as a watcher, and prove two
-- things from this chair: the watcher is shown the match (they say so),
-- and the watcher is never counted -- N LEFT stays at three (me and the
-- two bots) with them in the room, exactly as it was without them.
--
-- The beats, synced through DIR files:
--   1. host(), start        -> "m1": the guest quick-plays into the offer
--   2. "camera"             -> the guest is watching; recount, then end it
--   3. the unlock seats them; "seated" is the guest's word for it
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
  E.setBots(2)
  E.setFill(0)
  E.setSafari(0)
  E.setFog(600)
  E.host()

  local code
  for _ = 1, 600 do
    U.wait(10)
    code = E.code()
    if code then break end
  end
  if not code then
    return C.fail("hosting never produced a code: " .. tostring(E.lastError()))
  end
  L.put(DIR, "code.txt", tostring(code))

  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("never reached match 1")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  -- park the bots a region away so nothing engages the referee
  for _, b in ipairs(E.bots() or {}) do
    E.debugPlaceBot(b.id, "LAVENDER_TOWN", 5, 5)
  end
  U.wait(60)
  local before = E.aliveCount()
  U.log(("PVP host: match %s running, %d left before any watcher"):format(
    tostring(code), before))
  if before ~= 3 then
    return C.fail("expected 3 left (me and two bots), got " .. tostring(before))
  end
  L.put(DIR, "m1.txt", "running")

  if not L.waitFor(DIR, "camera.txt", 3600) then
    return C.fail("the guest never reported watching")
  end
  -- give their place a moment to land, then recount
  U.wait(120)
  local after = E.aliveCount()
  local watcherSeen = false
  for _, m in ipairs(E.members() or {}) do
    if m.name == "GUESTB" and m.spectate then watcherSeen = true end
  end
  if not watcherSeen then return C.fail("the roster does not show GUESTB watching") end
  U.log(("PVP host: watcher in the room; %d left"):format(after))
  if after ~= 3 then
    return C.fail(("the watcher is being counted: %d left with them, %d without")
      :format(after, before))
  end

  -- end it; the unlock seats the watcher
  E.debugWin()
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    if E.phase() == "lobby" then break end
    U.tap(game, "a")   -- the Hall of Fame and MATCH RECORD want presses
    U.wait(10)
  end
  if E.phase() ~= "lobby" then return C.fail("match 1 never gave the lobby back") end
  -- the guest's own word is the proof: they are seated the moment the
  -- relay unlocks, and may have left again before this chair is off its
  -- MATCH RECORD card -- so the roster is a bonus, not the test
  local seated = L.get(DIR, "seated.txt") ~= nil
  t0 = love.timer.getTime()
  while not seated and love.timer.getTime() - t0 < 120 do
    for _, m in ipairs(E.members() or {}) do
      if m.name == "GUESTB" and not m.spectate then seated = true break end
    end
    if L.get(DIR, "seated.txt") then seated = true end
    if seated then break end
    U.wait(10)
  end
  if not seated then return C.fail("the unlock never seated the watcher") end
  U.log("PVP OK: the watcher saw the match, was never counted, and is seated for the next")
  love.event.quit(0)
  U.wait(30)
end
