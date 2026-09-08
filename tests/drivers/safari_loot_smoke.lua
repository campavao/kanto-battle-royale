-- POK-195 smoke: the Safari's item balls are dealt from the match seed.
--
-- The ROM's balls are fixed; in a match every ball in the four zone maps
-- (and the zone's hidden REVIVE) holds something drawn from the seed --
-- the same on every client, different every match -- and the ROM's are
-- back the moment the match ends.  Two matches in one launch:
--
--   1. match one: the balls read the draw, not the ROM; walk up to
--      EAST's first ball and pick it up: the bag gains the drawn item;
--   2. leave: every ball reads the ROM's again;
--   3. match two (a fresh seed): a different draw.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-safari-loot POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/safari_loot_smoke.lua \
--   <path to>/lovec . > safari_loot.log 2>&1
--
-- Exit 0 with a `LOOT OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Safari = require("mods.battle_royale.lib.safari")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  local data = game.data
  local slots = Safari.slots(data.maps, data.field)
  if #slots < 12 then return C.fail("the zone has only " .. #slots .. " slots") end
  local rom = {}
  for i, s in ipairs(slots) do rom[i] = s.obj.item end
  local function reading()
    local t = {}
    for _, s in ipairs(slots) do t[#t + 1] = tostring(s.obj.item) end
    return table.concat(t, ",")
  end
  local romLine = reading()
  U.log("LOOT: the ROM's balls " .. romLine)

  local function startMatch(name)
    E.setName(name)
    E.setSafari(0)
    E.setFog(600)
    if not E.hostSolo() then return false, "hostSolo refused" end
    E.setBots(1)
    local hosted = false
    for _ = 1, 300 do
      U.wait(10)
      if (E.memberCount() or 0) >= 1 then hosted = true break end
    end
    if not hosted then return false, "the solo room never came up" end
    E.start()
    if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
      return false, "never reached the match (phase " .. tostring(E.phase()) .. ")"
    end
    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    U.wait(30)
    return true
  end

  -- ----------------------------------------------------------- 1. match one
  local ok, err = startMatch("LOOTER")
  if not ok then return C.fail(err) end
  local one = reading()
  U.log("LOOT: match one deals " .. one)
  if one == romLine then return C.fail("match one left the ROM's balls in place") end
  local masters = 0
  for _, s in ipairs(slots) do if s.obj.item == "MASTER_BALL" then masters = masters + 1 end end
  if masters > 1 then return C.fail(masters .. " MASTER BALLs dealt") end
  -- pick up EAST's first ball
  local ball
  for _, s in ipairs(slots) do
    if s.map == "SAFARI_ZONE_EAST" and s.index then ball = s break end
  end
  if not ball then return C.fail("no ball in SAFARI_ZONE_EAST") end
  local want = ball.obj.item
  local inv = game.save.inventory
  local had = inv[want] or 0
  U.teleport(game, "SAFARI_ZONE_EAST", ball.obj.x, ball.obj.y + 1, "up")
  U.wait(40)
  for _ = 1, 6 do U.tap(game, "b") U.wait(5) end
  U.tap(game, "a")
  local got = false
  for _ = 1, 120 do
    U.tap(game, "a")
    U.wait(5)
    if (inv[want] or 0) > had then got = true break end
  end
  if not got then
    return C.fail(("the ball at %d,%d did not hand over %s (bag %s)"):format(
      ball.obj.x, ball.obj.y, tostring(want), tostring(inv[want])))
  end
  U.log(("LOOT: picked up %s from EAST's ball %d"):format(tostring(want), ball.index))
  for _ = 1, 6 do U.tap(game, "a") U.wait(5) end

  -- ---------------------------------------------------------------- 2. leave
  E.leave()
  U.wait(60)
  for _ = 1, 10 do U.tap(game, "a") U.wait(10) end
  local back = reading()
  if back ~= romLine then return C.fail("after the match the balls read " .. back) end
  U.log("LOOT: the ROM's balls are back after the match")

  -- ------------------------------------------------------------ 3. match two
  ok, err = startMatch("LOOTER")
  if not ok then return C.fail(err) end
  local two = reading()
  U.log("LOOT: match two deals " .. two)
  if two == one then return C.fail("two seeds dealt the same balls") end
  if two == romLine then return C.fail("match two left the ROM's balls in place") end
  U.log("LOOT OK: dealt from the seed, picked up, restored, and different next match")
  love.event.quit(0)
  U.wait(30)
end
