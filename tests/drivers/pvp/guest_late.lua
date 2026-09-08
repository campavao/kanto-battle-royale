-- A watcher arrives mid-match, guest side (2026-09-07).  Quick-play into
-- the running match, take WATCH, PLAY NEXT, and land IN the match as a
-- camera: phase match, status out, a trainer picked to follow, their map
-- under our feet, and a count that does not include us.  Then the unlock
-- seats us for the next one.
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
  E.setSafari(0)

  if not L.waitFor(DIR, "m1.txt", 3600) then
    return C.fail("match 1 never started")
  end
  local hostCode = L.get(DIR, "code.txt")

  if not E.quickPlay() then return C.fail("quickPlay refused") end
  local offer
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    offer = E.runningMatch()
    if offer then break end
    U.wait(5)
  end
  if not offer then
    return C.fail("no match_in_progress offer arrived (err " .. tostring(E.lastError()) .. ")")
  end
  if hostCode and offer.code ~= hostCode then
    return C.fail("the offer names the wrong room: " .. tostring(offer.code))
  end
  if not E.watchNext() then return C.fail("watchNext refused") end

  -- the host shows us the match: we land in it as a camera
  local landed = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    if E.phase() == "match" and E.status() == "out" then landed = true break end
    if C.busy() then U.tap(game, "a") end
    U.wait(5)
  end
  if not landed then
    return C.fail(("never landed in the running match (phase %s, status %s, spectating %s)")
      :format(tostring(E.phase()), tostring(E.status()), tostring(E.isSpectating())))
  end
  if not E.isSpectating() then return C.fail("in the match but not marked a watcher") end
  U.log("PVP guest: in the match as a camera")

  -- somebody to follow, and their map under our feet
  local following
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    local w = E.watching()
    local wm = E.watchedMap()
    if w and wm and C.map() == wm and not C.ow().transitioning then
      following = w
      break
    end
    if C.busy() then U.tap(game, "a") end
    U.wait(5)
  end
  if not following then
    return C.fail(("never settled on a trainer (watching %s, their map %s, ours %s)")
      :format(tostring(E.watching()), tostring(E.watchedMap()), tostring(C.map())))
  end
  U.log(("PVP guest: following %s on %s"):format(tostring(following), tostring(C.map())))
  -- a watcher is not a body: the count is theirs, not ours
  local left = E.aliveCount()
  if left ~= 3 then
    return C.fail("a watcher counting themself: " .. tostring(left) .. " left")
  end
  -- ...and hopping works from the first press
  E.hop(1)
  U.wait(30)
  if not E.watching() then return C.fail("the hop lost the camera") end
  L.put(DIR, "camera.txt", "yes")

  -- the host ends it; the ending lands us in the lobby, seated
  local seated = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 180 do
    if E.phase() == "lobby" and not E.isSpectating() then seated = true break end
    U.tap(game, "a")   -- result cards want presses
    U.wait(10)
  end
  if not seated then
    return C.fail(("the ending never seated us (phase %s, spectating %s)")
      :format(tostring(E.phase()), tostring(E.isSpectating())))
  end
  U.log("PVP OK: watched a match in progress from inside it, then took a seat")
  L.put(DIR, "seated.txt", "yes")
  love.event.quit(0)
  U.wait(30)
end
