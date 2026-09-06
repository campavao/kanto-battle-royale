-- POK-186 as pictures: the lobby's OPTIONS box with its MATCH OPTIONS row,
-- the box that row opens, and each of its rows pressed once.  Nothing is
-- asserted beyond "the boxes opened"; this is for looking at.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-shots POKEPORT_SPEED=3 \
--   BR_SHOTS=<absolute dir, already created> \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/pace_shots.lua \
--   <path to>/lovec . > pace_shots.log 2>&1

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local shotN = 0
  local function shot(name)
    if not SHOTS then return end
    shotN = shotN + 1
    U.shot(game, ("%s/pace-%02d-%s.png"):format(SHOTS, shotN, name))
  end
  local function labels(items)
    local out = {}
    for _, it in ipairs(items or {}) do out[#out + 1] = tostring(it.label) end
    return table.concat(out, "|")
  end
  local function rowOf(box, text)
    for i, it in ipairs(box.items or {}) do
      if tostring(it.label):find(text, 1, true) then return i end
    end
    return nil
  end
  local function press(box, text)
    local i = rowOf(box, text)
    if not i then return C.fail("no row " .. text .. " in " .. labels(box.items)) end
    box.index = i
    U.wait(5)
    U.tap(game, "a")
    U.wait(15)
    return true
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("HOSTY")
  E.revertPace()

  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(30)
  local screen = game.stack:top()
  local ok, err = E.hostSolo()
  if not ok then return C.fail("hostSolo refused: " .. tostring(err)) end
  E.setBots(3)
  U.wait(40)
  shot("lobby")

  -- the button is cursor 0 on a fresh room; A opens the host's box
  screen.room.cur = 0
  U.wait(5)
  U.tap(game, "a") U.wait(15)
  local box = game.stack:top()
  if box == screen or not (box and box.items) then
    return C.fail("A on OPTIONS did not open the box")
  end
  U.log("SHOTS: options | " .. labels(box.items))
  box.index = rowOf(box, "MATCH OPTIONS") or 1
  U.wait(5)
  shot("options")

  if not press(box, "MATCH OPTIONS") then return end
  local sub = game.stack:top()
  if sub == box or not (sub and sub.items) then
    return C.fail("MATCH OPTIONS did not open its box")
  end
  U.log("SHOTS: match options | " .. labels(sub.items))
  shot("match-options")

  if not press(sub, "TEXT:") then return end
  U.log("SHOTS: after TEXT | " .. labels(sub.items))
  shot("text-slow")
  if not press(sub, "TEXT:") then return end
  shot("text-fast")
  if not press(sub, "ANIMATION:") then return end
  U.log("SHOTS: after ANIMATION | " .. labels(sub.items))
  shot("animation-off")
  if not press(sub, "DEBUG:") then return end
  shot("debug-on")
  if not press(sub, "REVERT") then return end
  U.log("SHOTS: after REVERT | " .. labels(sub.items))
  shot("reverted")
  if not press(sub, "BACK") then return end
  if game.stack:top() ~= box then
    return C.fail("BACK did not return to the OPTIONS box")
  end
  shot("back")

  U.log("SHOTS OK")
  love.event.quit(0)
  U.wait(10)
end
