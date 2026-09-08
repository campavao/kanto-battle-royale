-- POK-197 smoke: a match with nobody to beat is refused, not started.
--
-- A hosted room with FILL: OFF and no guests, or a solo room with BOTS: 0,
-- used to open a match of one trainer and sit at "1 LEFT" forever: the
-- winner check fires when the living fall TO one, and a roster that opens
-- at one never sees the fall.  Every start entry now asks Bots.canStart
-- first.  This drives the solo half (the pure rule in br_test covers the
-- counts; a hosted room needs a relay):
--
--   1. host a solo room, set BOTS to 0, press start: refused with the
--      reason, and the phase stays "lobby";
--   2. set BOTS to 1, press start: the match opens.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-empty-room POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/empty_room_smoke.lua \
--   <path to>/lovec . > empty.log 2>&1
--
-- Exit 0 with an `EMPTY OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("ALONE")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end

  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end

  -- 1. nobody to beat
  E.setBots(0)
  if (E.botsAtStart() or 0) ~= 0 then
    return C.fail("BOTS: 0 still fields " .. tostring(E.botsAtStart()) .. " bots")
  end
  local ok, why = E.start()
  if ok then return C.fail("a one-trainer match was allowed to start") end
  if type(why) ~= "string" or not why:find("2 trainers", 1, true) then
    return C.fail("the refusal did not say why: " .. tostring(why))
  end
  U.log("EMPTY: start refused (" .. why:gsub("\n", " ") .. ")")
  U.wait(60)
  if E.phase() ~= "lobby" then
    return C.fail("phase left the lobby on a refused start: " .. tostring(E.phase()))
  end
  for _ = 1, 6 do U.tap(game, "a") U.wait(10) end   -- the text box
  if E.phase() ~= "lobby" then
    return C.fail("phase left the lobby after the box: " .. tostring(E.phase()))
  end

  -- 2. one bot is a match
  E.setBots(1)
  ok = E.start()
  if not ok then return C.fail("a one-bot match was refused") end
  if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)
  local roster = E.players() or {}
  if #roster ~= 1 then
    return C.fail("expected one bot on the roster, got " .. tostring(#roster))
  end
  U.log("EMPTY OK: BOTS 0 refused with the reason, BOTS 1 started a match of two")
  love.event.quit(0)
  U.wait(30)
end
