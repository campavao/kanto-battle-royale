-- POK-104: the ROYALE screen must never grow taller than the screen.
--
-- The box height was `#items * rowStep + 2` flat, and the lobby's row count
-- is not fixed -- it grows a row per trainer in the room on top of the
-- host's settings.  A hosted room therefore pushed START MATCH and LEAVE
-- off the bottom of the canvas with no way to reach them: the screen that
-- starts matches could not start one.
--
-- Needs a relay, because the overflowing face is the HOSTED lobby -- a solo
-- room hides the code and the roster, which is most of what overflows:
--
--   node mods/battle_royale/relay/server.js &        # PORT=7790
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_SPEED=3 \
--     POKEPORT_IDENTITY=br-lobby-fit BR_RELAY=127.0.0.1:7790 \
--     POKEPORT_DRIVER=mods/battle_royale/tests/drivers/lobby_fit_smoke.lua \
--     lovec . > lobby.log 2>&1
--
-- `LOBBY OK` passes; any `PVP FAIL` line fails.  BR_SHOTS captures the
-- lobby at the top of its list and scrolled to the bottom.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

-- the Gen 1 canvas, in Font tiles: what the box may never exceed
local CANVAS_ROWS = 18

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
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
  local menu = game.stack:top()
  if not (menu and menu.items) then
    return C.fail("the ROYALE screen did not open (top " .. tostring(menu) .. ")")
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
  -- bots do not add rows, but the host's settings do; give it the fullest
  -- lobby a single client can produce
  E.setBots(8)
  E.setFill(8)
  U.wait(60)

  menu = game.stack:top()
  if not (menu and menu.items) then
    return C.fail("the ROYALE screen left the stack while hosting")
  end
  local labels = {}
  for i, it in ipairs(menu.items) do labels[i] = tostring(it.label) end
  U.log(("LOBBY: %d rows = %s"):format(#labels, table.concat(labels, "|")))
  U.log(("LOBBY: box th=%s maxVisible=%s scroll=%s")
    :format(tostring(menu.th), tostring(menu.maxVisible), tostring(menu.scroll)))

  -- the bug, stated as the screen's own geometry
  if (menu.ty or 0) + menu.th > CANVAS_ROWS then
    return C.fail(("the box is %d tiles tall at y=%d -- past the %d-tile canvas")
      :format(menu.th, menu.ty or 0, CANVAS_ROWS))
  end
  if #labels <= (menu.maxVisible or math.huge) then
    U.log("LOBBY: (note) this lobby fits without scrolling; the cap is still asserted")
  else
    if not menu.maxVisible then
      return C.fail("more rows than fit and no maxVisible: nothing will scroll")
    end
  end
  shot("30-lobby-top")

  -- ...and every row is actually reachable.  Walk the cursor to the last
  -- row and check the list scrolled to keep it on screen.
  local last = #labels
  for _ = 1, last + 4 do
    if menu.index >= last then break end
    U.tap(game, "down")
    U.wait(8)
  end
  if menu.index ~= last then
    return C.fail(("the cursor stopped at row %d of %d"):format(menu.index, last))
  end
  local firstVisible = (menu.scroll or 0) + 1
  local lastVisible = (menu.scroll or 0) + (menu.maxVisible or last)
  if menu.index < firstVisible or menu.index > lastVisible then
    return C.fail(("the last row is off screen: index %d, window %d..%d")
      :format(menu.index, firstVisible, lastVisible))
  end
  if (menu.ty or 0) + menu.th > CANVAS_ROWS then
    return C.fail("the box grew past the canvas once scrolled")
  end
  U.log(("LOBBY: reached row %d (%s), window %d..%d, box still %d tiles")
    :format(menu.index, tostring(labels[last]), firstVisible, lastVisible, menu.th))
  shot("31-lobby-bottom")

  -- the rows that matter are the ones that were falling off the bottom
  local sawStart, sawLeave = false, false
  for _, l in ipairs(labels) do
    if l:find("START MATCH", 1, true) then sawStart = true end
    if l == "LEAVE" then sawLeave = true end
  end
  if not (sawStart and sawLeave) then
    return C.fail("the lobby is missing START MATCH / LEAVE entirely")
  end

  U.log("LOBBY OK")
  love.event.quit(0)
  U.wait(20)
end
