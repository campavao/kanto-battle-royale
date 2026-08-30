-- The cold-start batch, guest side (POK-129/130/133): quick-play into a
-- running match, take the watcher's seat, get seated into the next match
-- for real, then get removed and prove the door stays shut.
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

  -- POK-133: quick play answers with the running match, not silence
  if not E.quickPlay() then return C.fail("quickPlay refused") end
  local offer
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    offer = E.runningMatch()
    if offer then break end
    U.wait(5)
  end
  if not offer then
    return C.fail("no match_in_progress offer arrived (code "
      .. tostring(E.code()) .. ", err " .. tostring(E.lastError()) .. ")")
  end
  if hostCode and offer.code ~= hostCode then
    return C.fail("the offer names the wrong room: " .. tostring(offer.code))
  end
  U.log("PVP guest: offered the running match " .. tostring(offer.code))

  -- take the seat
  if not E.watchNext() then return C.fail("watchNext refused") end
  local watching = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    if E.phase() == "lobby" and E.isSpectating() then watching = true break end
    U.wait(5)
  end
  if not watching then
    return C.fail("never reached the watcher's seat (phase "
      .. tostring(E.phase()) .. ")")
  end
  U.log("PVP guest: watching; the next match is ours")
  L.put(DIR, "watching.txt", "yes")

  -- the unlock seats us without a single press
  local seatedAt
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 120 do
    if not E.isSpectating() then seatedAt = love.timer.getTime() break end
    U.wait(5)
  end
  if not seatedAt then return C.fail("match 1 ended and nobody seated us") end
  U.log("PVP guest: seated")

  -- ...and match 2 is ours to PLAY: a spawn, a drop, alive on the roster
  if not L.waitPhase(C, "match", 2400) then
    return C.fail("match 2 never reached us (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  local alive = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    if E.status() == "alive" then alive = true break end
    U.tap(game, "a")
    U.wait(10)
  end
  if not alive then
    return C.fail("in match 2 but not alive (status " .. tostring(E.status()) .. ")")
  end
  U.log("PVP guest: playing match 2 for real")
  L.put(DIR, "m2_done.txt", "yes")

  -- the host ends match 2 and removes us: our room closes under us
  local out = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 180 do
    if (E.memberCount() or 0) == 0 then out = true break end
    U.tap(game, "a")   -- fame cards and the OUT text want presses
    U.wait(10)
  end
  if not out then return C.fail("the removal never reached us") end
  if not L.waitFor(DIR, "kicked.txt", 1200) then
    return C.fail("the host never confirmed the kick")
  end
  U.log("PVP guest: removed; probing the ban")

  -- POK-130's other half: quick play must NOT put us back in that room --
  -- the relay skips it for our IP, answers no_open_rooms, and the
  -- fallback hosts us a room of our own
  if not E.quickPlay() then return C.fail("the post-kick quickPlay refused") end
  local landed
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    landed = E.code()
    if landed and E.memberCount() and E.memberCount() >= 1 then break end
    U.wait(5)
  end
  if not landed then return C.fail("the post-kick quickPlay never landed") end
  if hostCode and landed == hostCode then
    return C.fail("the ban is a revolving door: back in " .. tostring(landed))
  end
  U.log("PVP OK: found the match, watched, played the next, stayed removed")
  L.put(DIR, "done.txt", "yes")
  love.event.quit(0)
  U.wait(30)
end
