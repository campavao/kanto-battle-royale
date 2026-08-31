-- Not a test: quick-joins whatever room the local relay has open and then
-- stands there, so a person in another window has a live guest to point
-- at (e.g. to try the POK-130 REMOVE row on).  Exits on its own when the
-- room closes under it or after ten minutes, whichever comes first.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local E = C.E()
  if not E then return end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7791")
  E.setName("GUESTB")
  -- keep trying until the person's room appears
  local joined = false
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 300 do
    if (E.memberCount() or 0) >= 2 then joined = true break end
    if (E.memberCount() or 0) == 0 and E.phase() == "off" then
      E.quickPlay()
    end
    U.wait(30)
    -- a solo fallback room of our own is not the point; leave and retry
    if E.code() and (E.memberCount() or 0) == 1
       and love.timer.getTime() - t0 > 10 then
      E.leave()
      U.wait(60)
    end
  end
  if not joined then
    U.log("GUEST: never found a room to join")
    love.event.quit(0)
    return
  end
  U.log("GUEST: in the room; kick me")
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 600 do
    if (E.memberCount() or 0) == 0 then
      U.log("GUEST: the room let go of me (kicked or closed)")
      break
    end
    coroutine.yield()
  end
  love.event.quit(0)
end
