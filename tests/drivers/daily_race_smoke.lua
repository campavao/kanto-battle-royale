-- POK-180: the daily host's clock survives a poll answered after the hour.
--
-- The lone host of the 2026-09-04 daily sat through 00:00Z: the start is
-- armed from the relay's whole-second countdown a round trip late, and a
-- poll answered inside that sliver reported the NEXT day's seconds, which
-- the naive re-arm took.  The sliver is too narrow to hit on purpose, so
-- this driver hands the info handler a "tomorrow" answer every frame
-- across the hour, through the relay's own event, and expects the match
-- to start on the clock regardless.
--
--   (start relay with BR_DAILY="HH:MM|America/Chicago|TEST GAME")
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-daily POKEPORT_SPEED=3 BR_PVP_RELAY=127.0.0.1:7790 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/daily_race_smoke.lua \
--   <path to>/lovec . > daily_race.log 2>&1
--
-- Exit 0 with a `DAILY RACE OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("RACER")
  if not E.dailyPlay() then return C.fail("dailyPlay refused") end

  local left
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    if E.isDailyLobby() and E.phase() == "lobby" then
      left = E.dailyStartsIn()
      if left then break end
    end
    U.wait(10)
  end
  if not left then
    return C.fail("the daily lobby never learned its hour (err "
      .. tostring(E.lastError()) .. ")")
  end
  if left > 300 then
    return C.fail("the hour is too far out for this run: " .. left .. "s")
  end
  U.log(("DAILY RACE: in the lobby, %ds to the hour"):format(left))

  -- sit until the last three seconds, on the wall clock
  while (E.dailyStartsIn() or 0) > 3 and E.phase() == "lobby" do U.wait(10) end
  if E.phase() ~= "lobby" then
    return C.fail("left the lobby before the hour (phase " .. tostring(E.phase()) .. ")")
  end
  U.log(("DAILY RACE: %ds out, feeding tomorrow's answer"):format(E.dailyStartsIn() or -1))

  -- THE RACE, every frame across the hour: an answer that rolled over
  local hour = love.timer.getTime() + (E.dailyStartsIn() or 0)
  local fed, startedAt = 0, nil
  while love.timer.getTime() < hour + 8 do
    if not E.debugDailyInfo(86400) then return C.fail("debugDailyInfo refused") end
    fed = fed + 1
    local p = E.phase()
    if p ~= "lobby" then startedAt = love.timer.getTime() break end
    U.wait(1)
  end
  if not startedAt then
    return C.fail(("the hour passed under %d tomorrow-answers and nothing started (phase %s, startsIn %s)")
      :format(fed, tostring(E.phase()), tostring(E.startsIn())))
  end
  local late = startedAt - hour
  U.log(("DAILY RACE: started %.2fs after the hour, %d answers refused, phase %s")
    :format(late, fed, tostring(E.phase())))
  if late > 5 then
    return C.fail(("started, but %.1fs late"):format(late))
  end
  U.log(("DAILY RACE OK: the clock fired through %d late answers"):format(fed))
  love.event.quit(0)
  U.wait(30)
end
