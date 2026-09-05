-- The lobby as a ROOM (lib/lobby.lua, the user's sketch of 2026-09-05):
-- sprites and names in a grid, outlines for the seats bots will take, a
-- cursor that walks them, OPTIONS over the room for the host, a card
-- behind every trainer.
--
-- Solo, so it needs no relay: a solo room draws itself the same way a
-- hosted one does, minus the code.  What it proves, in order:
--
--   1. the ROYALE screen becomes the room when a solo room opens
--   2. thirteen seats (me + MAX 12) page as 2 x 4, the cursor reaches the
--      last one and the button, and the room scrolls to keep up
--   3. OPTIONS opens the box with MAX / FOG / SAFARI / DEBUG / START / LEAVE
--   4. A on my own seat opens my card
--   5. START MATCH from the box closes the box AND the room and starts
--
-- Run from a gen1recomp checkout root:
--
--   SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1 \
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-room POKEPORT_SPEED=3 \
--   BR_SHOTS=<absolute dir, already created> \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/lobby_room_smoke.lua \
--   <path to>/lovec . > room.log 2>&1
--
-- `ROOM OK` passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Lobby = require("mods.battle_royale.lib.lobby")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local shotN = 0
  local function shot(name)
    if not SHOTS then return end
    shotN = shotN + 1
    U.shot(game, ("%s/room-%02d-%s.png"):format(SHOTS, shotN, name))
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

  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(30)
  local screen = game.stack:top()
  if not (screen and screen.room) then
    return C.fail("the ROYALE screen did not open (top " .. tostring(screen) .. ")")
  end
  if screen.view ~= "menu" then
    return C.fail("expected the first face, got " .. tostring(screen.view))
  end

  -- ------- 1. a solo room is the room
  local ok, err = E.hostSolo()
  if not ok then return C.fail("hostSolo refused: " .. tostring(err)) end
  E.setBots(12)
  U.wait(30)
  if game.stack:top() ~= screen then
    return C.fail("the ROYALE screen left the stack while hosting")
  end
  if screen.view ~= "lobby" then
    return C.fail("the screen is not on the lobby face: " .. tostring(screen.view))
  end
  local seats = E.lobbySeats()
  U.log(("ROOM: %d seats, header %q, button %q"):format(
    #seats, tostring(Lobby.header({ solo = true })), tostring("OPTIONS")))
  if #seats ~= 13 then
    return C.fail("expected 13 seats (me + 12 bots), got " .. #seats)
  end
  if seats[1].name ~= "HOSTY" or not seats[1].me or not seats[1].host then
    return C.fail("seat 1 is not me, the host: " .. tostring(seats[1].name))
  end
  if seats[1].sprite ~= "SPRITE_RED" then
    return C.fail("my seat does not wear my skin: " .. tostring(seats[1].sprite))
  end
  -- the bots are DEALT in the lobby (the seed is rolled at the room's
  -- first place), so every seat past mine is a named bot with a face
  if not (seats[2].bot and seats[13].bot) then
    return C.fail("the bot seats are not bots")
  end
  if not (seats[2].name and seats[2].sprite) then
    return C.fail("a bot seat has no name or face: " .. tostring(seats[2].name)
                  .. " / " .. tostring(seats[2].sprite))
  end
  if seats[2].name == seats[3].name then
    return C.fail("two bots share a name: " .. seats[2].name)
  end
  U.log(("ROOM: bots %s, %s ... %s"):format(seats[2].name, seats[3].name, seats[13].name))
  shot("top")

  -- ------- 2. the cursor walks every seat and the room scrolls
  local room = screen.room
  if room.cur ~= 0 then return C.fail("the cursor did not start on the button") end
  U.tap(game, "up")  U.wait(3)
  if room.cur ~= 13 then
    return C.fail("up from the button is not the last seat: " .. tostring(room.cur))
  end
  if room.scroll ~= 3 then
    return C.fail("the last seat did not scroll the room to its last page: "
                  .. tostring(room.scroll))
  end
  shot("bottom")
  for _ = 1, 6 do U.tap(game, "up") U.wait(3) end
  if room.cur ~= 1 then
    return C.fail("six ups from the last seat is not the first: " .. tostring(room.cur))
  end
  if room.scroll ~= 0 then
    return C.fail("the first seat did not scroll the room back up: "
                  .. tostring(room.scroll))
  end
  U.tap(game, "right") U.wait(3)
  if room.cur ~= 2 then return C.fail("right did not walk to seat 2") end
  -- a bot's card: its name, BOT, and out
  U.tap(game, "a") U.wait(10)
  local botCard = game.stack:top()
  if botCard == screen or not (botCard and botCard.items) then
    return C.fail("A on a bot did not open its card")
  end
  local botRows = labels(botCard.items)
  U.log("ROOM: bot card | " .. botRows)
  if botRows ~= seats[2].name .. "|BOT|BACK" then
    return C.fail("a bot's card is not NAME / BOT / BACK")
  end
  shot("botcard")
  U.tap(game, "b") U.wait(10)
  U.tap(game, "left") U.wait(3)
  U.log(("ROOM: cursor walks (cur=%d scroll=%d)"):format(room.cur, room.scroll))

  -- ------- 4. my own card (before the box, while the cursor is here)
  U.tap(game, "a") U.wait(10)
  local card = game.stack:top()
  if card == screen or not (card and card.items) then
    return C.fail("A on my seat did not open a card")
  end
  local rows = labels(card.items)
  U.log("ROOM: my card | " .. rows)
  if not (rows:find("HOSTY|HOST|", 1, true) and rows:find("|BACK", 1, true)) then
    return C.fail("the card does not read HOSTY / HOST / ... / BACK")
  end
  if rows:find("REMOVE", 1, true) then
    return C.fail("my own card offers to remove me")
  end
  shot("card")
  U.tap(game, "b") U.wait(10)
  if game.stack:top() ~= screen then
    return C.fail("B did not close the card back to the room")
  end

  -- ------- 3. OPTIONS -- and the wrap on the way: up off the top row is
  -- the button, down from the button is the first seat
  U.tap(game, "up") U.wait(3)
  if room.cur ~= 0 then
    return C.fail("up off the top row is not the button: " .. tostring(room.cur))
  end
  U.tap(game, "down") U.wait(3)
  if room.cur ~= 1 then
    return C.fail("down from the button is not the first seat: " .. tostring(room.cur))
  end
  for _ = 1, 7 do U.tap(game, "down") U.wait(3) end
  if room.cur ~= 0 then
    return C.fail("down off the last row did not land on the button: " .. tostring(room.cur))
  end
  U.tap(game, "a") U.wait(10)
  local box = game.stack:top()
  if box == screen or not (box and box.items) then
    return C.fail("A on OPTIONS did not open the box")
  end
  rows = labels(box.items)
  U.log("ROOM: options | " .. rows)
  if rows ~= "MAX: 12|FOG: 240s|SAFARI: 120s|DEBUG: OFF|START MATCH|LEAVE" then
    return C.fail("the solo OPTIONS box is not MAX / FOG / SAFARI / DEBUG / START / LEAVE")
  end
  shot("options")
  -- MAX steps the ladder and the room follows, live under the box
  U.tap(game, "a") U.wait(5)
  if #E.lobbySeats() ~= 17 then
    return C.fail("MAX: 12 -> 16 did not grow the room to 17 seats: " .. #E.lobbySeats())
  end
  shot("options-max16")
  U.tap(game, "b") U.wait(10)
  if game.stack:top() ~= screen then
    return C.fail("B did not close the box back to the room")
  end

  -- ------- 5. START MATCH from the box starts the match
  U.tap(game, "a") U.wait(10)
  box = game.stack:top()
  local startRow
  for i, it in ipairs(box.items or {}) do
    if tostring(it.label):find("START MATCH", 1, true) then startRow = i end
  end
  if not startRow then return C.fail("no START MATCH in the box") end
  for _ = 1, startRow - 1 do U.tap(game, "down") U.wait(3) end
  if box.index ~= startRow then
    return C.fail(("the cursor is on row %d, START MATCH is %d"):format(box.index, startRow))
  end
  U.tap(game, "a")
  local started = false
  for _ = 1, 600 do
    U.wait(5)
    if E.phase() == "safari" or E.phase() == "match" then started = true break end
  end
  if not started then
    return C.fail("START MATCH did not start (phase " .. tostring(E.phase()) .. ")")
  end
  U.wait(120)
  local top = game.stack:top()
  if top == screen or top == box then
    return C.fail("the room or the box is still on the stack after START MATCH")
  end
  U.log(("ROOM: started (phase %s, top %s)"):format(tostring(E.phase()),
        top == C.ow() and "overworld" or tostring(top)))
  shot("started")

  U.log("ROOM OK")
  love.event.quit(0)
  U.wait(20)
end
