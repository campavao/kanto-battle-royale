-- A guest for somebody else's lobby: join the room BR_CODE names on the
-- relay BR_RELAY names -- or, with no BR_CODE, QUICK PLAY into whatever
-- open room the relay has (the host must already be in theirs, or this
-- client becomes the host of an open room instead and fails on it) --
-- and sit in it -- so the host, at their own
-- screen, can watch a seat fill in and a bot give it up (the room's
-- open seats are MAX less the humans, lib/lobby.lua).
--
-- What it logs, so the host's report can be checked against it: the room
-- as this client draws it on arrival and every few seconds after, and
-- the phase the room moves to.  It leaves when the match starts (a guest
-- of a two-client PvP match on this checkout cannot fight anyway: the
-- door refuses engine_skew on a dev build) or after BR_GUEST_SECONDS.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_SPEED=1 \
--     POKEPORT_IDENTITY=br-guest BR_RELAY=<host:port> BR_CODE=<code> \
--     BR_SHOTS=<dir> \
--     POKEPORT_DRIVER=mods/battle_royale/tests/drivers/guest_join_smoke.lua \
--     lovec . > guest.log 2>&1
--
-- `GUEST OK` passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local CODE = (os.getenv("BR_CODE") or ""):gsub("%s+", ""):upper()
  local HOLD = tonumber(os.getenv("BR_GUEST_SECONDS") or "150")
  local shotN = 0
  local function shot(name)
    if not SHOTS then return end
    shotN = shotN + 1
    U.shot(game, ("%s/guest-%02d-%s.png"):format(SHOTS, shotN, name))
  end
  local function roomLine(seats)
    local out = {}
    for i, s in ipairs(seats or {}) do
      out[i] = s.empty and "_" or (tostring(s.name) .. (s.bot and "(bot)" or "")
                                     .. (s.me and "(me)" or "") .. (s.host and "(host)" or ""))
    end
    return table.concat(out, " ")
  end

  -- from the TITLE, the way a player does (BATTLE ROYALE is a title row):
  -- no NEW GAME, no Oak, no save
  U.wait(5)
  U.tap(game, "start")   -- skip the intro movie
  U.wait(15)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName(os.getenv("BR_GUEST_NAME") or "CLAUDE")
  E.setRelay(os.getenv("BR_RELAY") or "127.0.0.1:7790")

  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(30)
  local screen = game.stack:top()
  if not (screen and screen.room) then
    return C.fail("the ROYALE screen did not open")
  end

  local ok, err
  if CODE ~= "" then
    U.log("GUEST: joining " .. CODE)
    ok, err = E.join(CODE)
  else
    U.log("GUEST: quick play")
    ok, err = E.quickPlay()
  end
  if not ok then return C.fail("join refused: " .. tostring(err)) end
  local joined = false
  for _ = 1, 600 do
    U.wait(10)
    local code = E.code()
    if code and (CODE == "" or code == CODE) and E.memberCount() >= 2 then
      joined = true break
    end
    if E.phase() == "off" and (E.lastError() or not E.code()) and _ > 30 then break end
  end
  if not joined then
    if CODE == "" and E.code() and E.memberCount() == 1 then
      E.leave()
      return C.fail("quick play found no open room and hosted one instead "
                    .. "(left it) -- was the host in their room yet?")
    end
    return C.fail(("never joined %s (phase %s, %d members, error %s)"):format(
      CODE ~= "" and CODE or "any room", tostring(E.phase()), E.memberCount(),
      tostring(E.lastError())))
  end
  CODE = E.code()
  U.wait(60)   -- the host's place, with the seed and FILL, lands
  local seats = E.lobbySeats()
  U.log(("GUEST: in %s with %d members, %d seats: %s"):format(
    CODE, E.memberCount(), #seats, roomLine(seats)))
  shot("joined")
  local mine
  for i, s in ipairs(seats) do if s.me then mine = i end end
  if not mine then return C.fail("my own seat is not in the room") end
  U.log(("GUEST: my seat is %d (%s)"):format(mine, tostring(seats[mine].sprite)))

  -- hold the seat, saying what the room looks like every five seconds
  local t0 = love.timer.getTime()
  local lastSay = 0
  while love.timer.getTime() - t0 < HOLD do
    U.wait(30)
    local phase = E.phase()
    if phase ~= "lobby" then
      U.log("GUEST: the room moved to " .. tostring(phase))
      shot("moved")
      -- a few seconds in, then leave: the host's match must go on with
      -- the bots still standing (the bug the first run found)
      U.wait(300)
      U.log(("GUEST: leaving the %s with %d alive"):format(tostring(E.phase()), E.aliveCount()))
      break
    end
    local now = love.timer.getTime()
    if now - lastSay >= 5 then
      lastSay = now
      seats = E.lobbySeats()
      U.log(("GUEST: t+%3ds %d members, %d seats: %s"):format(
        math.floor(now - t0), E.memberCount(), #seats, roomLine(seats)))
    end
  end

  U.log("GUEST OK")
  E.leave()
  U.wait(30)
  love.event.quit(0)
  U.wait(20)
end
