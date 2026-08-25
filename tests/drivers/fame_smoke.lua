-- POK-82 smoke: the Hall of Fame is the END of the run.
--
-- Host a solo room, start, declare the win (mod.exports.debugWin -- a match
-- cannot be played down to one survivor in a driver's lifetime), sit through
-- the Champion's parade, then check the two things the ticket is about:
--   1. the champion is no longer standing in the finished match world, and
--   2. the room survived, so PLAY AGAIN can still run it back.
--
-- One client, no relay server: a solo room is a LocalRoom, so this needs
-- only LOVE and an imported ROM.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-fame-smoke POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/fame_smoke.lua \
--   <path to>/lovec . > fame.log 2>&1
--
-- Exit 0 with a `FAME OK` line passes; any `PVP FAIL` line fails (the
-- failure channel comes from pvplib, shared with the two-client pair).
-- Set BR_SHOTS=<dir> to also drop screenshots of the parade and of the
-- screen the champion lands on.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("CHAMP")
  E.setSafari(0)            -- skip the Safari opening: the old RATTATA drop
  E.setFog(600)             -- the fog must not end this before we do
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(1)              -- AFTER hostSolo: it forces its own count on zero,
                            -- and one bot keeps checkWinner from firing at once

  -- hosting is asynchronous even on a LocalRoom: startMatch wants isHost(),
  -- which only becomes true once the room_hosted reply lands in a tick
  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then
    return C.fail("the solo room never came up: " .. tostring(E.lastError()))
  end
  U.log("FAME: solo room up, " .. tostring(E.memberCount()) .. " in it")
  E.start()

  -- mash, not wait: the drop opens a town picker that wants an A
  if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)
  local ow = game.overworld
  local base = game.speedOverride

  -- POK-84: what the START menu offers right now, as one string.
  local function startRows()
    -- START is gated on the player standing still and the overworld owning
    -- the screen, so this presses until the menu is actually up
    local its
    for _ = 1, 20 do
      U.tap(game, "start")
      U.wait(20)
      local top = game.stack:top()
      its = type(top) == "table" and top.items or nil
      if type(its) == "table" then break end
      if top ~= game.overworld then U.tap(game, "b") U.wait(10) end
    end
    if type(its) ~= "table" then return nil end
    local out = {}
    for _, it in ipairs(its) do out[#out + 1] = tostring(it.label or "") end
    U.tap(game, "b")
    U.wait(20)
    return "|" .. table.concat(out, "|") .. "|"
  end

  -- POK-83: the touch skin's hold, straight at the engine.  The mod cannot
  -- veto it through core.logic_speed (checked after speedOverride), so the
  -- test is whether it gets taken back.
  local function heldSpeed()
    if not game.touchSkinHotkey then return nil end
    game:touchSkinHotkey("fast_forward_hold", true)
    U.wait(8)
    local during = game.speedOverride
    game:touchSkinHotkey("fast_forward_hold", false)
    U.wait(8)
    return during, game.speedOverride
  end

  -- ...checked in a live round, and again once it is over: the guards used
  -- to stop at inRound(), so a win handed both back.
  local function rulesHold(when)
    local rows = startRows()
    if not rows then return C.fail("no START menu " .. when) end
    if rows:find("|LINK|", 1, true) then
      return C.fail("LINK is reachable " .. when .. ": " .. rows)
    end
    if rows:find("|SAVE|", 1, true) then
      return C.fail("SAVE is reachable " .. when .. ": " .. rows)
    end
    local during, after = heldSpeed()
    if during ~= nil then
      if during ~= base then
        return C.fail(("fast-forward took %s -> %s"):format(
          when, tostring(during)))
      end
      if after ~= base then
        return C.fail(("fast-forward lingered %s -> %s"):format(
          when, tostring(after)))
      end
    end
    U.log(("FAME: rules hold %s (%s)"):format(when, rows))
  end
  U.log(("FAME: in the match on %s, %s alive"):format(
    tostring(C.map()), tostring(E.aliveCount())))
  shot("in-match")
  rulesHold("in a round")

  -- POK-84: the Cable Club desk, checked where it can be checked cheaply.
  -- Walking into a Centre is a whole journey; what actually decides the
  -- guard is whether data:textEntry(map.def.label, npc.def.text) still finds
  -- the cableClub marker, and that is the same call OverworldState makes to
  -- pick the receptionist out in the first place.  So exercise the lookup
  -- with a real Centre's key, and confirm the label the guard passes it is
  -- the same kind of key the map carries.
  do
    local entry = game.data.textEntry and game.data:textEntry(
      "ViridianPokecenter", "TEXT_VIRIDIANPOKECENTER_LINK_RECEPTIONIST")
    if not (entry and entry.cableClub) then
      return C.fail("the Cable Club marker the guard reads is gone")
    end
    local here = ow and ow.map and ow.map.def and ow.map.def.label
    if type(here) ~= "string" then
      return C.fail("map.def.label is not the key the guard passes: "
        .. tostring(here))
    end
    U.log("FAME: the Cable Club marker resolves; map key is " .. here)
  end

  E.debugWin()
  if not L.mashUntil(C, function() return E.phase() == "over" end, 600) then
    return C.fail("the declared win never took")
  end
  U.log("FAME: phase over; waiting on the parade")
  rulesHold("after the win")

  -- Spotting the parade: `.pages` alone is NOT enough -- a Gen 1 text box
  -- has text pages too, and the win banner is on screen first.  showPage is
  -- Fame's own method, so it comes off Fame's metatable and nothing else's.
  local function fame()
    local top = game.stack:top()
    if type(top) ~= "table" then return nil end
    if top.pages == nil or top.showPage == nil then return nil end
    return top
  end
  -- tap A, then poll finely, so a page that turns itself is not missed
  local function beat()
    U.tap(game, "a")
    for _ = 1, 12 do
      if fame() then return true end
      U.wait(2)
    end
    return fame() ~= nil
  end

  local seen
  for _ = 1, 300 do
    if beat() then seen = fame() break end
  end
  if not seen then
    return C.fail("the Hall of Fame never opened (top " .. tostring(game.stack:top()) .. ")")
  end
  U.log("FAME: parade open, " .. tostring(#seen.pages) .. " pages")
  shot("fame")

  local gone = false
  for _ = 1, 300 do
    U.tap(game, "a")
    U.wait(10)
    if not fame() then gone = true break end
  end
  if not gone then return C.fail("the parade never closed") end
  U.wait(120)
  shot("after")

  -- 1. off the finished world
  local top = game.stack:top()
  if top == ow then return C.fail("still standing in the match world") end
  if game.overworld and top == game.overworld then
    return C.fail("still on an overworld after the parade")
  end
  -- 2. the room is still theirs
  local members = E.memberCount() or 0
  if members < 1 then return C.fail("the room went away with the match") end

  U.log(("FAME OK: off the overworld, %d in the room, phase %s")
        :format(members, tostring(E.phase())))
  love.event.quit(0)
  U.wait(10)
end
