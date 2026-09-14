-- The lobby list (2026-09-13), host side: open a room, be found on the
-- LOBBIES list, put a passcode on the door, and be joined by somebody who
-- typed it.
--
-- The beats, synced through DIR files:
--   1. host()          -> code.txt: the room, open from birth
--   2. "listed"        -> the guest saw us on the list; lock the door
--                          with PASS 1234 -> passed.txt
--   3. "joined"        -> the guest got in with the passcode; check the
--                          roster has them, then PVP OK
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
  if not E.isOpen() then
    return C.fail("a hosted room is still private by default")
  end
  U.log("PVP host: room " .. tostring(code) .. " open, waiting to be listed")
  L.put(DIR, "code.txt", tostring(code))

  if not L.waitFor(DIR, "listed.txt", 1800) then
    return C.fail("the guest never saw the room on the list")
  end

  -- lock the door
  if not E.setPass("1234") then return C.fail("setPass refused on the host") end
  if E.passcode() ~= "1234" then
    return C.fail("passcode() reads " .. tostring(E.passcode()) .. " after setPass")
  end
  U.log("PVP host: passcode set")
  L.put(DIR, "passed.txt", "1234")

  if not L.waitFor(DIR, "joined.txt", 1800) then
    return C.fail("the guest never got through the passcoded door")
  end
  local seated = false
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    for _, m in ipairs(E.members() or {}) do
      if m.name == "GUESTB" and not m.spectate then seated = true break end
    end
    if seated then break end
    U.wait(10)
  end
  if not seated then return C.fail("GUESTB is not on the host's roster") end
  U.log("PVP host: GUESTB seated through the passcode; members "
    .. tostring(E.memberCount()))
  U.log("PVP OK: host")
  love.event.quit(0)
  U.wait(10)
end
