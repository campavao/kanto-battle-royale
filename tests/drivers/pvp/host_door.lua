-- Scenario "door", host side: the room notices, in the LOBBY, that the
-- trainer who just walked in cannot be fought (POK-142).
--
-- The guest reports a different engine release (see guest_door.lua).  This
-- side asserts the three things the door promises and photographs the
-- lobby that carries them:
--
--   1. it fires at the JOIN, with nobody dropped and no match started --
--      which is the whole point, and which needed the join announcement
--      that PROTOCOL 9 added, because until then no place travelled in a
--      lobby at all
--   2. it names the RIGHT number: the engine differs and the mod does not,
--      so "! UPDATE THE GAME" and not "! UPDATE BOTH"
--   3. it marks the TRAINER, not just the room
--
--   python mods/battle_royale/tests/drivers/pvp/run_pvp.py door
--
-- Set BR_SHOTS to a PRE-CREATED directory -- U.shot's mkdir is a bash-ism
-- that silently fails under LOVE on Windows, so an absent parent means no
-- files and no error.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

-- The lobby as the player actually sees it: the ROYALE screen's own rows.
-- Reading these rather than only E.door() is the difference between "the
-- mod worked it out" and "the player was told" -- and the screenshots are
-- of this screen, so a shot with no mark in it would otherwise still pass.
local function rows(C)
  local menu = C.game.stack:top()
  if not (menu and menu.items) then return nil end
  local out = {}
  for _, it in ipairs(menu.items) do out[#out + 1] = tostring(it.label) end
  return out
end

local function hasRow(list, want)
  for _, l in ipairs(list or {}) do if l == want then return true end end
  return false
end

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local SHOTS = os.getenv("BR_SHOTS")

  local n = 0
  local function shot(tag)
    if not SHOTS then return end
    n = n + 1
    U.shot(game, ("%s/host_%02d_%s.png"):format(SHOTS, n, tag))
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  if not E.door then return C.fail("this build has no door export") end

  local mine = (E.door() or {}).build or {}
  U.log(("PVP host: running GAME %s / ROYALE %s"):format(
    tostring(mine.engine), tostring(mine.mod)))

  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("HOSTA")
  E.setBots(0)
  E.setSafari(0)
  E.setFog(600)

  -- open the mod's own screen, so the shots are of the LOBBY and the rows
  -- can be read back (lobby_fit_smoke.lua's recipe)
  require("src.ui.Screens").push(game, "BattleRoyaleMenu")
  U.wait(45)
  if not rows(C) then
    return C.fail("the ROYALE screen did not open")
  end
  E.host()

  local code = nil
  for _ = 1, 600 do
    U.wait(10)
    code = E.code()
    if code then break end
  end
  if not code then
    return C.fail("hosting never produced a code: " .. tostring(E.lastError()))
  end
  U.log("PVP host: room " .. tostring(code))

  -- A clean lobby first, so the pair of screenshots is a before/after --
  -- and BEFORE the code is published, which is the only thing that makes
  -- this deterministic.  The first cut published first and waited 60
  -- ticks, and the guest was in the room and flagged before the assertion
  -- ran: it failed on "the door flagged an empty room" while the door was
  -- working perfectly.  Nobody can join a code nobody has.
  U.wait(60)
  shot("lobby-alone")
  for _, l in ipairs(rows(C) or {}) do U.log("PVP host: alone row | " .. l) end
  if (E.door() or {}).label then
    return C.fail("the door flagged an empty room: "
                  .. tostring((E.door() or {}).label))
  end
  if E.memberCount() > 1 then
    return C.fail("somebody joined before the code was published")
  end
  L.put(DIR, "code.txt", tostring(code))

  if not L.waitFor(DIR, "joined.txt", 3000) then
    return C.fail("the guest never joined")
  end
  U.log("PVP host: the guest is in the room")

  -- ------- 1. it fires at the join, with no match started
  local label, ticks
  for i = 1, 300 do
    U.wait(10)
    label = (E.door() or {}).label
    if label then ticks = i break end
  end
  if not label then
    return C.fail("the door never flagged the guest in the lobby")
  end
  if E.phase() ~= "lobby" then
    return C.fail("the door only fired once the phase left the lobby: "
                  .. tostring(E.phase()))
  end
  U.log(("PVP host: door fired in the LOBBY after %d ticks: %s")
        :format(ticks, label))

  -- ------- 2. it names the right number, and states it as a FACT: the
  -- host is not the one who has to change anything and must not be told to
  if label ~= "! GAME MISMATCH" then
    return C.fail("door said " .. tostring(label)
                  .. ", expected ! GAME MISMATCH (only the engine differs)")
  end

  -- ------- 3. the trainer is named, and they are GONE
  --
  -- Read the DURABLE record, not the live roster: the guest is off it
  -- within milliseconds of arriving (the relay clocked 18 of them), so
  -- iterating E.players() here is a race that mostly loses.  That the host
  -- still knows who tried is the half a warning-only door never had --
  -- without it, a host running something nobody else has just watches
  -- people fail to appear.
  local marked
  for _ = 1, 400 do
    U.wait(10)
    local away = (E.door() or {}).turnedAway or {}
    if away[1] and E.memberCount() <= 1 then marked = away[1] break end
  end
  if not marked then
    return C.fail("the host kept no record of the trainer it turned away "
                  .. "(roster " .. tostring(E.memberCount()) .. ")")
  end
  U.log(("PVP host: turned away %s on GAME %s / ROYALE %s"):format(
    tostring(marked.name), tostring(marked.build and marked.build.engine),
    tostring(marked.build and marked.build.mod)))
  if marked.build and marked.build.mod ~= (mine.mod or "?") then
    return C.fail("the guest's MOD version differs too, so this run cannot "
                  .. "prove the label picked the engine on purpose")
  end

  -- ------- 4. and the player is actually TOLD: the rendered rows
  U.wait(45)
  local list = rows(C)
  if not list then return C.fail("the ROYALE screen left the stack") end
  for _, l in ipairs(list) do U.log("PVP host: row | " .. l) end
  if not hasRow(list, "! GUESTB") then
    return C.fail("the lobby keeps no trace of the trainer it turned away")
  end
  -- states a FACT: the host is not the one who has to change anything, and
  -- may not be told to
  if not hasRow(list, "! GAME MISMATCH") then
    return C.fail("the lobby shows no mismatch row")
  end
  for _, l in ipairs(list) do
    if l:find("UPDATE") then
      return C.fail("the host is being told to update: " .. l)
    end
  end
  if not hasRow(list, "YOU ARE ON:") then
    return C.fail("the lobby does not show our own numbers")
  end
  if not hasRow(list, "GAME v" .. tostring(mine.engine)) then
    return C.fail("the lobby does not name our engine release")
  end

  -- ...and photograph the lobby that says all of it
  shot("lobby-flagged")
  for _ = 1, 3 do U.wait(40) shot("lobby-flagged") end

  L.put(DIR, "hostdone.txt", "1")
  if not L.waitFor(DIR, "guestdone.txt", 3000) then
    return C.fail("the guest never finished")
  end
  U.log("PVP OK host: door fired at the join, " .. tostring(n) .. " frames captured")
  love.event.quit(0)
  U.wait(10)
end
