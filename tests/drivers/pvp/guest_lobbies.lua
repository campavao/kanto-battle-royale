-- The lobby list (2026-09-13), guest side: open LOBBIES, find the host's
-- room on it as a row (their name, 1 trainer over the seats, no lock),
-- watch the lock appear when the host sets a passcode, knock with the
-- wrong passcode and stay on the list with WRONG PASSCODE under it, then
-- knock with the right one and land in the room.
--
-- The list is read two ways: E.rooms() is the data; the ROYALE screen's
-- list state is what a player sees, and BR_SHOTS photographs it.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local SHOTS = os.getenv("BR_SHOTS")
  local shotN = 0
  local function shot(name)
    if not SHOTS then return end
    shotN = shotN + 1
    U.shot(game, ("%s/guest-%02d-%s.png"):format(SHOTS, shotN, name))
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("GUESTB")
  E.setSafari(0)

  if not L.waitFor(DIR, "code.txt", 1800) then
    return C.fail("the host never posted a code")
  end
  local hostCode = (L.get(DIR, "code.txt") or ""):gsub("%s+", "")

  -- open the ROYALE screen, then LOBBIES, the way a player does
  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(30)
  local screen = game.stack:top()
  if not (screen and screen.list) then
    return C.fail("the ROYALE screen did not open")
  end
  local ok, err = E.browse()
  if not ok then return C.fail("browse refused: " .. tostring(err)) end

  local function findRow()
    for _, r in ipairs(E.rooms() or {}) do
      if r.code == hostCode then return r end
    end
    return nil
  end
  local function rowLine(r)
    return ("host=%s skin=%s players=%s seats=%s pass=%s"):format(
      tostring(r.host), tostring(r.skin), tostring(r.players),
      tostring(r.seats), tostring(r.pass))
  end

  -- 0. the DAILY GAME's row, when the relay was given a BR_DAILY inside
  -- the half hour: top of the list with a countdown; picking it is the
  -- daily lobby, with the official clock in the header
  if os.getenv("BR_DAILY") then
    local drow
    local t0 = love.timer.getTime()
    while love.timer.getTime() - t0 < 60 do
      local rows = E.rooms() or {}
      if rows[1] and rows[1].daily then drow = rows[1] break end
      U.wait(5)
    end
    if not drow then return C.fail("no DAILY row at the top of the list") end
    local Browse = require("mods.battle_royale.lib.browse")
    local text = Browse.count(drow)
    U.log("PVP guest: daily row " .. tostring(drow.host) .. " " .. text
      .. " (secs " .. tostring(drow.secs) .. ")")
    if not text:match("^IN %d+M$") then return C.fail("the daily row reads " .. text) end
    U.tap(game, "down")
    U.wait(10)
    shot("daily-row")
    if not E.joinDaily() then return C.fail("joinDaily returned false") end
    local inDaily = false
    t0 = love.timer.getTime()
    while love.timer.getTime() - t0 < 60 do
      if E.phase() == "lobby" and E.isDailyLobby() and E.code() then inDaily = true break end
      U.wait(5)
    end
    if not inDaily then
      return C.fail("the daily row did not seat us (phase " .. tostring(E.phase())
        .. ", daily " .. tostring(E.isDailyLobby()) .. ")")
    end
    local Lobby = require("mods.battle_royale.lib.lobby")
    local header
    t0 = love.timer.getTime()
    while love.timer.getTime() - t0 < 90 do
      header = Lobby.header(screen.list.BR)
      if header and header:match("^STARTS IN") then break end
      U.wait(10)
    end
    U.log("PVP guest: in the daily room " .. tostring(E.code()) .. "; header "
      .. tostring(header))
    if not (header and header:match("^STARTS IN")) then
      return C.fail("the daily header reads " .. tostring(header))
    end
    shot("daily-room")
    E.leave()
    U.wait(30)
    ok, err = E.browse()
    if not ok then return C.fail("browse (again) refused: " .. tostring(err)) end
    U.wait(10)
    screen = game.stack:top()
    if not (screen and screen.list) then
      require("src.ui.Screens").push(game, "BattleRoyaleMenu")
      U.wait(30)
      screen = game.stack:top()
    end
    if not (screen and screen.list) then return C.fail("the ROYALE screen did not come back") end
  end

  -- 1. the host's room is a row
  local row
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    row = findRow()
    if row then break end
    U.wait(5)
  end
  if not row then
    return C.fail("the host's room " .. hostCode .. " never appeared on the list ("
      .. #(E.rooms() or {}) .. " rows, view " .. tostring(screen.view) .. ")")
  end
  U.log("PVP guest: listed " .. rowLine(row))
  if screen.view ~= "browse" then
    return C.fail("the ROYALE screen is on face " .. tostring(screen.view) .. ", not browse")
  end
  if row.host ~= "HOSTA" then return C.fail("the row names " .. tostring(row.host)) end
  if tonumber(row.players) ~= 1 then
    return C.fail("the row counts " .. tostring(row.players) .. " trainers, not 1")
  end
  if row.pass then return C.fail("the row has a lock before any passcode was set") end
  -- the cursor onto the row, so the shot shows a pick
  U.tap(game, "down")
  U.wait(10)
  shot("listed")

  L.put(DIR, "listed.txt", "yes")

  -- 2. the lock appears when the host sets a passcode
  if not L.waitFor(DIR, "passed.txt", 1800) then
    return C.fail("the host never set a passcode")
  end
  local locked
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    local r = findRow()
    if r and r.pass then locked = r break end
    U.wait(5)
  end
  if not locked then return C.fail("the row never grew a lock after set_pass") end
  U.log("PVP guest: locked " .. rowLine(locked))
  shot("locked")

  -- 3. the wrong passcode is refused on the list, not the connection
  if not E.joinListed(hostCode, "9999") then
    return C.fail("joinListed(wrong) returned false")
  end
  local refused
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    local relay = screen.list and screen.list.BR and screen.list.BR.relay
    if relay and relay.joinReason then refused = relay.joinReason break end
    if E.code() == hostCode then
      return C.fail("the wrong passcode opened the door")
    end
    U.wait(5)
  end
  if refused ~= "passcode" then
    return C.fail("expected a passcode refusal, got " .. tostring(refused))
  end
  local Browse = require("mods.battle_royale.lib.browse")
  local status = Browse.status(screen.list.BR)
  U.log("PVP guest: refused " .. tostring(refused) .. "; status line " .. tostring(status))
  if status ~= "WRONG PASSCODE" then
    return C.fail("the status line reads " .. tostring(status))
  end
  if screen.view ~= "browse" then
    return C.fail("the refusal left the list: face " .. tostring(screen.view))
  end
  if #(E.rooms() or {}) == 0 then
    return C.fail("the refusal emptied the list")
  end
  shot("refused")

  -- 4. the right passcode is the room
  if not E.joinListed(hostCode, "1234") then
    return C.fail("joinListed(right) returned false")
  end
  local joined = false
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    if E.code() == hostCode and E.memberCount() >= 2 and E.phase() == "lobby" then
      joined = true break
    end
    U.wait(5)
  end
  if not joined then
    return C.fail("the right passcode did not seat us (code " .. tostring(E.code())
      .. ", members " .. tostring(E.memberCount()) .. ", phase " .. tostring(E.phase())
      .. ", err " .. tostring(E.lastError()) .. ")")
  end
  U.wait(20)
  if screen.view ~= "lobby" then
    return C.fail("seated, but the screen is on face " .. tostring(screen.view))
  end
  U.log("PVP guest: in room " .. hostCode .. " with " .. E.memberCount() .. " members")
  shot("room")
  L.put(DIR, "joined.txt", "yes")

  U.wait(60)
  U.log("PVP OK: guest")
  love.event.quit(0)
  U.wait(10)
end
