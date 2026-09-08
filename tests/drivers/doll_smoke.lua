-- POK-194 smoke: the POKe DOLL is the way out of a bot fight.
--
-- Everyone starts with one.  A fight against a bot is an engine trainer
-- battle, where RUN is refused outright -- so the doll is the bail: from
-- the bag (the engine's ItemEffects would say "not the time") or from the
-- RUN row, the fight ends as a run, nobody beaten, the doll spent, and the
-- bot does not call the fight again inside the flee grace.  Three fights,
-- one bot each:
--
--   1. the starting doll, used from the bag: back on the overworld, the
--      bag empty of dolls, the bot still alive, and no re-engage inside
--      the grace;
--   2. a second doll, spent by RUN;
--   3. no doll: RUN is the engine's own refusal and the fight stays open.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-doll POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/doll_smoke.lua \
--   <path to>/lovec . > doll.log 2>&1
--
-- Exit 0 with a `DOLL OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

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
  E.setName("DOLLY")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(3)
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

  local inv = game.save.inventory
  if (inv.POKE_DOLL or 0) ~= 1 then
    return C.fail("the drop did not hand over one POKe DOLL (got " .. tostring(inv.POKE_DOLL) .. ")")
  end
  U.log("DOLL: one POKe DOLL in the bag at the drop")

  local roster = E.bots() or {}
  if #roster < 3 then return C.fail("need three bots, have " .. #roster) end
  local function botAt(id)
    for _, b in ipairs(E.bots() or {}) do if b.id == id then return b end end
  end

  -- Put the player on Pewter's street facing a clear lane and park the
  -- bot at its end; the eyeline does the rest.  A teleport carries a
  -- facing, so no held direction can walk us out of the lane.
  local function stageFight(bot)
    for _, d in ipairs(DIRS) do
      U.teleport(game, ARENA, AX, AY, d.dir)
      U.wait(20)
      local ow = C.ow()
      local map = ow and ow.map
      if not (map and map.id == ARENA) then return nil, "not on the arena" end
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
        local bx, by = AX + d.dx * gap, AY + d.dy * gap
        for _ = 1, 40 do
          if E.status() == "battle" then break end
          E.debugPlaceBot(bot.id, ARENA, bx, by)
          for _ = 1, 15 do
            if E.status() == "battle" then break end
            U.wait(4)
          end
          if E.status() == "battle" then break end
        end
        if E.status() ~= "battle" then
          return nil, ("the eyeline never caught %s in the %s lane"):format(
            tostring(bot.name), d.dir)
        end
        local battle
        for _ = 1, 1000 do
          local top = game.stack:top()
          if type(top) == "table" and top.trainer and top.enemy then battle = top break end
          U.wait(1)
        end
        if not battle then return nil, "the bot battle never reached the stack" end
        -- through the intro to the menu
        for _ = 1, 600 do
          if battle.phase == "menu" then break end
          U.tap(game, "a")
          U.wait(5)
        end
        if battle.phase ~= "menu" then
          return nil, "the battle never reached the menu (phase " .. tostring(battle.phase) .. ")"
        end
        return battle
      end
    end
    return nil, "no clear lane on the arena"
  end

  local function backOut(ticks)
    for _ = 1, ticks do
      if game.stack:top() == C.ow() and E.status() ~= "battle" then return true end
      U.tap(game, "a")
      U.wait(5)
    end
    return false
  end

  -- ------------------------------------------------------ 1. from the bag
  local victim = roster[1]
  local battle, err = stageFight(victim)
  if not battle then return C.fail(err) end
  U.log("DOLL: fight 1 open against " .. tostring(victim.name))
  battle:chooseMenu("item")
  local bag
  for _ = 1, 200 do
    local top = game.stack:top()
    if type(top) == "table" and top.kind == "bag" and top.items then bag = top break end
    U.wait(1)
  end
  if not bag then return C.fail("ITEM did not open the bag (top " .. tostring(game.stack:top()) .. ")") end
  local at
  for i, row in ipairs(bag.items) do
    if row.value == "POKE_DOLL" then at = i break end
  end
  if not at then return C.fail("no POKe DOLL row in the battle bag") end
  bag.index = at
  U.wait(2)
  U.tap(game, "a")
  if not backOut(600) then
    return C.fail("the doll from the bag did not end the fight (top " .. tostring(game.stack:top()) .. ")")
  end
  if inv.POKE_DOLL then return C.fail("the doll was not spent (" .. tostring(inv.POKE_DOLL) .. ")") end
  if E.status() ~= "alive" then return C.fail("status after the bail is " .. tostring(E.status())) end
  local b1 = botAt(victim.id)
  if not (b1 and b1.status == "alive") then return C.fail("the fled bot is not alive") end
  if not battle.pokeDollEscape then return C.fail("the battle is not flagged as a doll escape") end
  U.log("DOLL: from the bag, back on the overworld, doll spent, " .. tostring(victim.name) .. " alive")
  -- inside the grace the same bot does not call it again
  E.debugPlaceBot(victim.id, ARENA, AX + 3, AY, "left")
  for _ = 1, 40 do
    if E.status() == "battle" then return C.fail("the fled bot re-engaged inside the grace") end
    U.wait(3)
  end
  U.log("DOLL: no re-engage inside the grace")

  -- --------------------------------------------------------- 2. from RUN
  inv.POKE_DOLL = 1
  game.save.bagOrder = nil
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 5 do U.wait(10) end   -- past the grace
  victim = roster[2]
  battle, err = stageFight(victim)
  if not battle then return C.fail(err) end
  U.log("DOLL: fight 2 open against " .. tostring(victim.name))
  battle:chooseMenu("run")
  if not backOut(600) then
    return C.fail("RUN with a doll did not end the fight (top " .. tostring(game.stack:top()) .. ")")
  end
  if inv.POKE_DOLL then return C.fail("RUN did not spend the doll") end
  if E.status() ~= "alive" then return C.fail("status after RUN is " .. tostring(E.status())) end
  U.log("DOLL: RUN spent the second doll and got away")

  -- ---------------------------------------------------- 3. without one
  victim = roster[3]
  battle, err = stageFight(victim)
  if not battle then return C.fail(err) end
  U.log("DOLL: fight 3 open against " .. tostring(victim.name))
  battle:chooseMenu("run")
  for _ = 1, 60 do U.tap(game, "a") U.wait(5) end
  if game.stack:top() == C.ow() or battle.result then
    return C.fail("RUN without a doll ended the fight (result " .. tostring(battle.result) .. ")")
  end
  U.log("DOLL: without a doll RUN is refused and the fight stays open")
  U.log("DOLL OK: bag and RUN both spend the doll to leave a bot fight; none, no exit")
  love.event.quit(0)
  U.wait(30)
end
