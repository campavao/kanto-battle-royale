-- The cold-start batch, host side (POK-129/130/133): host a room that is
-- open from birth, run a match for the guest to find mid-flight, watch
-- them get seated into the next one, then show them the door.
--
-- The beats, synced through DIR files:
--   1. host()          -> the room must be OPEN with nobody touching a row
--   2. start match 1   -> "m1": the guest quick-plays into match_in_progress
--   3. "watching"      -> end match 1; the unlock must seat the watcher
--   4. start match 2   -> the guest must be a REAL player in it
--   5. "m2_done"       -> end match 2, kick the guest, wait for their half
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
  -- POK-129: the room is open the moment it exists, no row pressed
  if not E.isOpen() then
    return C.fail("a hosted room is still private by default")
  end
  U.log("PVP host: room " .. tostring(code) .. " open from birth")
  L.put(DIR, "code.txt", tostring(code))

  -- match 1: the thing the guest finds mid-flight
  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("never reached match 1")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  -- park the bots a region away so nothing engages the referee
  for _, b in ipairs(E.bots() or {}) do
    E.debugPlaceBot(b.id, "LAVENDER_TOWN", 5, 5)
  end
  L.put(DIR, "m1.txt", "running")

  if not L.waitFor(DIR, "watching.txt", 3600) then
    return C.fail("the guest never reached the watcher's seat")
  end
  -- end match 1; the unlock is what seats the watcher
  E.debugWin()
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    if E.phase() == "lobby" then break end
    U.tap(game, "a")   -- the Hall of Fame and MATCH RECORD want presses
    U.wait(10)
  end
  if E.phase() ~= "lobby" then return C.fail("match 1 never gave the lobby back") end

  -- the guest must now be a seated member, not a watcher
  local seated = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    for _, m in ipairs(E.members() or {}) do
      if m.name == "GUESTB" and not m.spectate then seated = true break end
    end
    if seated then break end
    U.wait(10)
  end
  if not seated then return C.fail("the unlock never seated the watcher") end
  U.log("PVP host: the watcher is seated; running match 2")

  -- match 2: they play it
  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("never reached match 2")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  for _, b in ipairs(E.bots() or {}) do
    E.debugPlaceBot(b.id, "LAVENDER_TOWN", 5, 5)
  end
  L.put(DIR, "m2.txt", "running")

  if not L.waitFor(DIR, "m2_done.txt", 3600) then
    return C.fail("the guest never confirmed playing match 2")
  end
  E.debugWin()
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    if E.phase() == "lobby" then break end
    U.tap(game, "a")
    U.wait(10)
  end
  if E.phase() ~= "lobby" then return C.fail("match 2 never gave the lobby back") end

  -- POK-130: show them the door
  local guestId
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 and not guestId do
    for _, m in ipairs(E.members() or {}) do
      if m.name == "GUESTB" then guestId = m.id break end
    end
    U.wait(10)
  end
  if not guestId then return C.fail("no guest on the roster to remove") end
  if not E.kick(guestId) then return C.fail("kick refused on the host") end
  local alone = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    if (E.memberCount() or 0) == 1 then alone = true break end
    U.wait(10)
  end
  if not alone then return C.fail("the roster still holds the removed guest") end
  L.put(DIR, "kicked.txt", "done")

  if not L.waitFor(DIR, "done.txt", 3600) then
    return C.fail("the guest never finished the ban probe")
  end
  U.log("PVP OK: open from birth, watcher seated and played, removed and kept out")
  love.event.quit(0)
  U.wait(30)
end
