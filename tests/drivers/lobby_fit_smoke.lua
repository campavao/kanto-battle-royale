-- POK-104, restated for the ROOM (lib/lobby.lua, 2026-09-05): every
-- trainer in a hosted lobby is reachable, and nothing the host needs is
-- ever off the screen.
--
-- The first version of this driver walked a text list that grew a row
-- per trainer and had once pushed START MATCH and LEAVE off the canvas.
-- The lobby draws seats now, eight a page, and the host's rows live in an
-- OPTIONS box of fixed length -- so the assertion is that the room pages
-- to its last seat, the box fits without scrolling, and FILL / MAX / OPEN
-- are what a hosted room offers.
--
-- Needs a relay, because the shape under test is the HOSTED lobby -- a
-- solo room has no code, no FILL and no OPEN:
--
--   node mods/battle_royale/relay/server.js &        # PORT=7790
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_SPEED=3 \
--     POKEPORT_IDENTITY=br-lobby-fit BR_RELAY=127.0.0.1:7790 \
--     POKEPORT_DRIVER=mods/battle_royale/tests/drivers/lobby_fit_smoke.lua \
--     lovec . > lobby.log 2>&1
--
-- `LOBBY OK` passes; any `PVP FAIL` line fails.  BR_SHOTS captures the
-- room with FILL off, with FILL on at its last page, and the box.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Lobby = require("mods.battle_royale.lib.lobby")

-- the Gen 1 canvas, in Font tiles: what a box may never exceed
local CANVAS_ROWS = 18

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end
  local function labels(items)
    local out = {}
    for _, it in ipairs(items or {}) do out[#out + 1] = tostring(it.label) end
    return table.concat(out, "|")
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("HOSTY")
  local relay = os.getenv("BR_RELAY") or "127.0.0.1:7790"
  E.setRelay(relay)

  -- open the mod's own screen and host a real (non-solo) room from it
  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(45)
  local screen = game.stack:top()
  if not (screen and screen.room) then
    return C.fail("the ROYALE screen did not open (top " .. tostring(screen) .. ")")
  end

  local ok, err = E.host()
  if not ok then return C.fail("host refused: " .. tostring(err)) end
  local hosted = false
  for _ = 1, 400 do
    U.wait(15)
    if E.code() then hosted = true break end
  end
  if not hosted then
    return C.fail("never got a room code (relay at " .. relay .. "? "
                  .. tostring(E.lastError()) .. ")")
  end
  U.wait(30)
  if game.stack:top() ~= screen or screen.view ~= "lobby" then
    return C.fail("the ROYALE screen is not showing the lobby")
  end
  local room = screen.room

  -- ------- FILL off: the room is who is here, and MAX 30 open seats
  local seats = E.lobbySeats()
  U.log(("LOBBY: %d seats with FILL off"):format(#seats))
  if #seats ~= 30 then return C.fail("expected my seat and 29 open ones, got " .. #seats) end
  if not (seats[1].me and seats[1].host and seats[1].name == "HOSTY") then
    return C.fail("seat 1 is not me, the host")
  end
  if not (seats[2].empty and seats[30].empty) then
    return C.fail("with FILL off the open seats are not open")
  end
  shot("30-lobby-alone")

  -- ------- the box: fixed, fitting, and the hosted rows
  U.tap(game, "a") U.wait(10)
  local box = game.stack:top()
  if box == screen or not (box and box.items) then
    return C.fail("A on OPTIONS did not open the box")
  end
  local rows = labels(box.items)
  U.log("LOBBY: options | " .. rows)
  U.log(("LOBBY: box th=%s maxVisible=%s scroll=%s")
    :format(tostring(box.th), tostring(box.maxVisible), tostring(box.scroll)))
  if (box.ty or 0) + box.th > CANVAS_ROWS then
    return C.fail(("the box is %d tiles tall at y=%d -- past the %d-tile canvas")
      :format(box.th, box.ty or 0, CANVAS_ROWS))
  end
  if #box.items > (box.maxVisible or math.huge) then
    return C.fail("the OPTIONS box scrolls: something is hidden under a room")
  end
  if not rows:find("^FILL: OFF|MAX: 30|OPEN: ") then
    return C.fail("a hosted box does not start FILL / MAX / OPEN")
  end
  if not (rows:find("START MATCH", 1, true) and rows:find("|LEAVE$")) then
    return C.fail("the box is missing START MATCH / LEAVE")
  end
  shot("31-lobby-box")

  -- ------- FILL on: the same thirty seats become bots
  U.tap(game, "a") U.wait(5)   -- FILL: OFF -> ON
  rows = labels(box.items)
  U.log("LOBBY: options | " .. rows)
  if not rows:find("^FILL: ON|MAX: 30|OPEN: ") then
    return C.fail("FILL on changed more than FILL")
  end
  if #box.items > (box.maxVisible or math.huge)
     or (box.ty or 0) + box.th > CANVAS_ROWS then
    return C.fail("the box with MAX no longer fits")
  end
  seats = E.lobbySeats()
  if #seats ~= 30 then return C.fail("FILL to 30 is not 30 seats: " .. #seats) end
  if not (seats[2].bot and seats[30].bot and seats[30].name) then
    return C.fail("with FILL on the open seats did not become bots")
  end
  U.log(("LOBBY: FILL on deals %s ... %s"):format(seats[2].name, seats[30].name))
  U.tap(game, "b") U.wait(10)
  if game.stack:top() ~= screen then
    return C.fail("B did not close the box back to the room")
  end

  -- ...and every seat is actually reachable: walk the cursor to the last
  -- one and check the room scrolled to keep it on screen
  U.tap(game, "up") U.wait(3)
  if room.cur ~= 30 then
    return C.fail("up from the button is not the last seat: " .. tostring(room.cur))
  end
  local lastRow = math.floor((30 - 1) / Lobby.COLS)
  if not (room.scroll <= lastRow and lastRow < room.scroll + Lobby.ROWS) then
    return C.fail(("the last seat is off screen: row %d, window %d..%d")
      :format(lastRow, room.scroll, room.scroll + Lobby.ROWS - 1))
  end
  U.log(("LOBBY: reached seat %d, window rows %d..%d")
    :format(room.cur, room.scroll, room.scroll + Lobby.ROWS - 1))
  shot("32-lobby-bottom")
  for _ = 1, 14 do U.tap(game, "up") U.wait(2) end
  if room.cur ~= 2 then
    return C.fail("fourteen ups did not climb back to the top row: " .. tostring(room.cur))
  end
  if room.scroll ~= 0 then
    return C.fail("the top row did not scroll the room back up")
  end
  -- ...and one more wraps to the button, and down from it is seat 1
  U.tap(game, "up") U.wait(3)
  if room.cur ~= 0 then return C.fail("up off the top row is not the button") end
  U.tap(game, "down") U.wait(3)
  if room.cur ~= 1 then return C.fail("down from the button is not the first seat") end

  U.log("LOBBY OK")
  love.event.quit(0)
  U.wait(20)
end
