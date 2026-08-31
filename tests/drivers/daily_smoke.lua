-- POK-161 v2: the DAILY GAME starts itself at the hour, full.
--
-- The runner starts a local relay whose BR_DAILY is a couple of minutes
-- out; this driver presses the row, reads the card, and waits for the
-- clock to start the match with the roster filled to thirty.
--
--   (start relay with BR_DAILY="HH:MM|America/Chicago|TEST GAME")
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-daily POKEPORT_SPEED=3 BR_PVP_RELAY=127.0.0.1:7790 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/daily_smoke.lua \
--   <path to>/lovec . > daily.log 2>&1
--
-- Exit 0 with a `DAILY OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  -- No U.newGame here: a lobby probe needs no world -- the BATTLE ROYALE
  -- screen opens from the TITLE, and the match builds its own throwaway
  -- NEW GAME at the drop.  (The intro walk belongs only to drivers that
  -- stage parties or cross Kanto before the match.)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("PROMPT")
  if not E.dailyPlay() then return C.fail("dailyPlay refused") end

  -- the card: a lobby that knows the hour
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
  U.log(("DAILY: in the lobby, %ds to the hour"):format(left))

  -- The clock starts it; nobody presses anything.  Success is LEAVING
  -- the lobby: the official match opens with the stock two-minute
  -- Safari, so "match" itself is minutes away yet.  Real-time budgets
  -- throughout -- the phases run on the wall clock.
  local started = false
  local deadline = love.timer.getTime() + left + 60
  while love.timer.getTime() < deadline do
    local p = E.phase()
    if p == "safari" or p == "drop" or p == "match" then started = true break end
    U.wait(10)
  end
  if not started then
    return C.fail("the hour passed and nothing started (left "
      .. tostring(E.dailyStartsIn()) .. ", phase " .. tostring(E.phase()) .. ")")
  end
  U.log("DAILY: the clock started it (phase " .. tostring(E.phase()) .. ")")
  local t1 = love.timer.getTime()
  while love.timer.getTime() - t1 < 300 do
    local p = E.phase()
    if p == "match" then break end
    -- B through the Safari (A would wander into the START menu -- which
    -- is how this driver found the buzzer-vs-menu stall); A at the drop,
    -- where the town picker wants a commit.  Dialogs auto-resolve.
    U.tap(game, p == "drop" and "a" or "b")
    U.wait(10)
  end
  if E.phase() ~= "match" then
    return C.fail("the Safari never gave way to the match (phase "
      .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)
  local alive = E.aliveCount()
  if alive ~= 30 then
    return C.fail("the official match is not full: " .. tostring(alive) .. "/30")
  end
  U.log(("DAILY OK: started on the clock with %d trainers"):format(alive))
  love.event.quit(0)
  U.wait(30)
end
