-- POK-167: a Quick Play room must NOT roll straight into the next match.
--
-- The bug: startMatch never cleared the quick-play countdown, so a host
-- who pressed START ahead of the sixty seconds carried the armed clock
-- through the match, and the frame the room came back to the lobby the
-- tick found it expired and started match 2 on the spot.  This drives
-- exactly that: quick play, START before the countdown, crown ourselves,
-- ride the funnel to the lobby -- and then the lobby has to HOLD, with
-- nothing counting, until READY UP arms the next one.
--
-- Needs the relay up (PORT=7792 node mods/battle_royale/relay/server.js,
-- from the repo root -- never `cd` into mods/, see br_load's cwd lock).
--
--   BR_PVP_RELAY=127.0.0.1:7792 POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-quick-again POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/quick_again_smoke.lua \
--   <path to>/lovec . > quick_again.log 2>&1
--
-- Exit 0 with a `QUICKAGAIN OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local function wall() return love.timer.getTime() end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7792")
  E.setName("QUICK")
  E.setSafari(0)
  E.setFog(600)
  local ok, err = E.quickPlay()
  if not ok then return C.fail("quickPlay refused: " .. tostring(err)) end
  local hosted = false
  for _ = 1, 600 do
    U.wait(10)
    if E.phase() == "lobby" and (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then
    return C.fail("quick play never produced a lobby: " .. tostring(E.lastError()))
  end
  local first = E.startsIn()
  U.log(("QUICKAGAIN: quick lobby up; the first countdown reads %s"):format(tostring(first)))
  if not (first and first > 0) then
    return C.fail("the first quick lobby should count itself down")
  end

  -- START ahead of the clock: the exact press that used to leave it armed
  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("START did not open match 1 (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)
  U.log("QUICKAGAIN: match 1 up, started by hand before the countdown")
  if E.startsIn() ~= nil then
    return C.fail("the countdown survived the start (" .. tostring(E.startsIn()) .. "s)")
  end

  -- crown ourselves and ride the funnel back to the lobby
  local phase = E.debugWin()
  if phase ~= "over" then return C.fail("debugWin did not end match 1") end
  local t0 = wall()
  local back = false
  while (wall() - t0) < 90 do
    if E.phase() == "lobby" then back = true break end
    if C.busy() then U.tap(game, "a") end
    U.wait(10)
  end
  if not back then
    return C.fail("match 1 never returned to the lobby (phase " .. tostring(E.phase()) .. ")")
  end
  local tLobby = wall()
  U.log(("QUICKAGAIN: back in the lobby %.1fs after the win"):format(tLobby - t0))

  -- ------- the lobby HOLDS: no countdown, no match 2, for twelve seconds
  while (wall() - tLobby) < 12 do
    if E.phase() ~= "lobby" then
      return C.fail(("the room rolled into the next match %.1fs after the lobby (phase %s)")
        :format(wall() - tLobby, tostring(E.phase())))
    end
    if E.startsIn() ~= nil then
      return C.fail("a countdown armed itself after the match (" .. tostring(E.startsIn()) .. "s)")
    end
    U.wait(3)
  end
  U.log("QUICKAGAIN: the lobby held 12s with nothing counting")

  -- ------- READY UP arms the next one, with the full window
  if not E.readyUp() then return C.fail("READY UP refused") end
  local left = E.startsIn()
  U.log(("QUICKAGAIN: READY UP armed %ss"):format(tostring(left)))
  if not (left and left >= 50 and left <= 60) then
    return C.fail("READY UP should arm the sixty-second window, got " .. tostring(left))
  end
  if E.readyUp() then return C.fail("a second READY UP should be a no-op while counting") end
  U.wait(120)
  if E.phase() ~= "lobby" then
    return C.fail("the armed lobby started early (phase " .. tostring(E.phase()) .. ")")
  end

  -- ...and the armed row starts now when pressed
  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("PLAY AGAIN did not open match 2 (phase " .. tostring(E.phase()) .. ")")
  end
  U.log("QUICKAGAIN OK: no roll-over, READY UP armed the window, match 2 on the press")
  love.event.quit(0)
  U.wait(10)
end
