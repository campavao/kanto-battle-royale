-- The bot fight's shot clock (the user, 2026-09-08): a player who sits
-- in the FIGHT menu is not a roof.  The clock runs while the menu is
-- theirs; at zero their mon does nothing, the bot's move runs, and the
-- menu returns with a fresh clock.  Never a forfeit.
--
--   1. open a bot fight on Pewter's street; at the menu the clock is
--      armed at Bots.TURN_SECONDS;
--   2. press nothing, with the clock wound down to a second: the bot's
--      move runs on its own, the fight stays open, and the menu is back
--      with the clock rearmed.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bot-clock POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_clock_smoke.lua \
--   <path to>/lovec . > bot_clock.log 2>&1
--
-- Exit 0 with a `CLOCK OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")

local ARENA = "PEWTER_CITY"
local AX, AY = 16, 18
local DIRS = {
  { dir = "right", dx = 1,  dy = 0 },
  { dir = "left",  dx = -1, dy = 0 },
  { dir = "down",  dx = 0,  dy = 1 },
  { dir = "up",    dx = 0,  dy = -1 },
}

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("IDLER")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(1)
  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end
  E.start()
  if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)
  -- a party that survives a turn of doing nothing
  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")

  -- ------------------------------------------------- 0. a wild battle too
  -- every local battle in a session runs the clock (the user, 2026-09-08)
  U.teleport(game, ARENA, AX, AY, "down")
  U.wait(30)
  local okW, whyW = E.debugWild("PIDGEY", 5)
  if not okW then return C.fail("no wild battle: " .. tostring(whyW)) end
  local wild
  for _ = 1, 1000 do
    local top = game.stack:top()
    if type(top) == "table" and top.kind == "wild" and top.enemy then wild = top break end
    U.wait(1)
  end
  if not wild then return C.fail("the wild battle never reached the stack") end
  for _ = 1, 600 do
    if wild.phase == "menu" then break end
    U.tap(game, "a")
    U.wait(5)
  end
  if wild.phase ~= "menu" then return C.fail("the wild battle never reached the menu") end
  U.wait(3)
  if not wild.turnClockActive then return C.fail("a wild battle's menu opened with no clock") end
  local wildMoves = 0
  local baseWild = wild.enemyAction
  wild.enemyAction = function(s) wildMoves = wildMoves + 1 return baseWild(s) end
  wild.turnClock = 1
  local wildFired = false
  for _ = 1, 600 do
    if wild.phase ~= "menu" then wildFired = true break end
    U.wait(2)
  end
  if not wildFired then return C.fail("the wild clock never ran out") end
  for _ = 1, 1500 do
    if wild.phase == "menu" then break end
    if game.stack:top() == C.ow() then return C.fail("the wild battle ended on the timeout") end
    U.tap(game, "a")
    U.wait(4)
  end
  if wild.phase ~= "menu" then return C.fail("the wild menu never came back") end
  if wildMoves < 1 then return C.fail("the wild mon did not move on the timeout") end
  U.log(("CLOCK: a wild battle ran the clock; the wild mon moved %d time(s) unanswered"):format(wildMoves))
  wild:chooseMenu("run")
  for _ = 1, 600 do
    if game.stack:top() == C.ow() then break end
    U.tap(game, "a")
    U.wait(4)
  end
  if game.stack:top() ~= C.ow() then return C.fail("could not run from the wild battle") end
  U.wait(30)

  local bot = (E.bots() or {})[1]
  if not bot then return C.fail("no bot") end

  local battle
  for _, d in ipairs(DIRS) do
    U.teleport(game, ARENA, AX, AY, d.dir)
    U.wait(20)
    local ow = C.ow()
    local map = ow and ow.map
    if not (map and map.id == ARENA) then return C.fail("not on the arena") end
    local gap
    for g = 4, 3, -1 do
      local clear = true
      for s = 1, g do
        if not (map:inBounds(AX + d.dx * s, AY + d.dy * s)
                and map:isWalkableCell(AX + d.dx * s, AY + d.dy * s)) then
          clear = false break
        end
      end
      if clear then gap = g break end
    end
    if gap then
      for _ = 1, 40 do
        if E.status() == "battle" then break end
        E.debugPlaceBot(bot.id, ARENA, AX + d.dx * gap, AY + d.dy * gap)
        for _ = 1, 15 do
          if E.status() == "battle" then break end
          U.wait(4)
        end
      end
      if E.status() == "battle" then
        for _ = 1, 1000 do
          local top = game.stack:top()
          if type(top) == "table" and top.trainer and top.enemy then battle = top break end
          U.wait(1)
        end
        break
      end
    end
  end
  if not battle then return C.fail("no bot fight opened") end
  for _ = 1, 600 do
    if battle.phase == "menu" then break end
    U.tap(game, "a")
    U.wait(5)
  end
  if battle.phase ~= "menu" then return C.fail("never reached the menu") end
  U.wait(3)
  if not battle.turnClockActive then return C.fail("the menu opened with no clock") end
  if not (battle.turnClock and battle.turnClock <= Bots.TURN_SECONDS and battle.turnClock > 0) then
    return C.fail("the clock reads " .. tostring(battle.turnClock))
  end
  U.log(("CLOCK: the menu opened with %.1fs on the clock"):format(battle.turnClock))

  -- count the bot's moves; then wait, pressing nothing
  local moves = 0
  local baseEnemy = battle.enemyAction
  battle.enemyAction = function(s) moves = moves + 1 return baseEnemy(s) end
  battle.turnClock = 1
  local fired = false
  for _ = 1, 600 do
    if battle.phase ~= "menu" then fired = true break end
    U.wait(2)
  end
  if not fired then return C.fail("the clock never ran out (reads " .. tostring(battle.turnClock) .. ")") end
  -- through the bot's turn to the menu again
  local back = false
  for _ = 1, 1500 do
    if battle.phase == "menu" then back = true break end
    if game.stack:top() == C.ow() then return C.fail("the fight ended on the timeout") end
    U.tap(game, "a")
    U.wait(4)
  end
  if not back then return C.fail("the menu never came back (phase " .. tostring(battle.phase) .. ")") end
  if moves < 1 then return C.fail("the bot did not move on the timeout") end
  if battle.result then return C.fail("the timeout set a result: " .. tostring(battle.result)) end
  U.wait(3)
  if not (battle.turnClockActive and battle.turnClock and battle.turnClock > 1) then
    return C.fail("the clock did not rearm (reads " .. tostring(battle.turnClock) .. ")")
  end
  U.log(("CLOCK OK: the bot moved %d time(s) while the player did nothing; menu back with %.1fs"):format(
    moves, battle.turnClock))
  love.event.quit(0)
  U.wait(30)
end
