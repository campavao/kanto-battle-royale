-- POK-207 scenario "items", host side: host the room, start a two-player
-- match with no bots, take the post in Pewter, and WATCH the guest use a
-- POTION in the duel.
--
-- What this side proves is the half a unit test cannot: that the OTHER
-- machine resolves an item it never chose.  The guest walks in with a
-- wounded lead and heals it mid-fight; from here the enemy's HP must go
-- UP between turns, the enemy's bench copy must go up with it, and the
-- fight must carry on in lockstep afterwards (no desync, no bye).
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("HOSTI")
  E.setBots(0)
  E.setSafari(0)
  E.setFog(600)
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
  L.put(DIR, "code.txt", tostring(code))
  U.log("PVP host: room " .. tostring(code))

  local both = false
  for _ = 1, 1800 do
    U.wait(10)
    if E.memberCount() >= 2 then both = true break end
  end
  if not both then return C.fail("the guest never joined") end
  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("never reached the match")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  -- A lead that cannot end the fight in a turn: the guest needs a menu to
  -- come back to after the POTION, and the item turn costs it an attack.
  L.armParty(C, "RATTATA", 5, "TACKLE")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "down", 6)
  L.put(DIR, "posted.txt", "1")
  U.log("PVP host: posted at 16,18 facing down; awaiting the challenger")

  if not L.mashUntil(C, function() return E.status() == "battle" end, 2400) then
    return C.fail("the duel never started on the host side")
  end
  -- the LinkBattle itself lands a moment after status says "battle"
  local lb
  for _ = 1, 900 do
    local top = game.stack:top()
    if type(top) == "table" and top.kind == "link" and top.enemy then lb = top break end
    U.wait(2)
  end
  if not lb then return C.fail("no link battle on the stack") end
  U.log("PVP host: lockstep battle open")
  if not lb.itemUsed or lb.openItems == nil then
    return C.fail("the link battle has no bag hooks at all")
  end
  local BattleState = require("src.battle.BattleState")
  if lb.openItems ~= BattleState.openItems then
    return C.fail("the match duel did not opt into items (opts.items)")
  end
  U.log("PVP host: the duel opened with the bag allowed")

  -- Watch the enemy's HP across the fight.  A heal is the one thing that
  -- can raise it, and only the guest's POTION can do that here.
  local healed, peak, before, why = false, nil, nil, "ran out of ticks"
  local last   -- the HP series, in the log, for when this fails
  for _ = 1, 12000 do
    local hp = lb.enemy and lb.enemy.mon and lb.enemy.mon.hp
    if hp then
      if hp ~= last then
        U.log(("PVP host: enemy HP %s -> %d (turn %s, phase %s)")
              :format(tostring(last), hp, tostring(lb.turnCount), tostring(lb.phase)))
        last = hp
      end
      if peak and hp > peak then
        healed, before = true, peak
        break
      end
      peak = (peak == nil or hp < peak) and hp or peak
    end
    if E.status() ~= "battle" then why = "the fight ended first" break end
    U.tap(game, "a")
    U.wait(4)
  end
  if not healed then
    return C.fail("the enemy's HP never went up (" .. why ..
                  "); the POTION did not cross the cable")
  end
  U.log(("PVP host: the guest's POTION healed their lead here too (%d -> %d)")
        :format(before, lb.enemy.mon.hp))
  -- the battler and the bench copy are the same mon, so the heal must be
  -- on the party the spill and the next fight will read
  if lb.enemyParty and lb.enemyParty[1] and lb.enemyParty[1].hp ~= lb.enemy.mon.hp then
    return C.fail("the heal landed on the battler but not the bench copy")
  end
  L.put(DIR, "host_saw_potion.txt", "1")

  -- ...and the fight carries on in lockstep: turns keep resolving after
  -- the item, which is what a desync would stop
  local turnsAfter = lb.turnCount or 0
  local wentOn = false
  for _ = 1, 4000 do
    if (lb.turnCount or 0) > turnsAfter + 1 then wentOn = true break end
    if E.status() ~= "battle" then wentOn = true break end
    U.tap(game, "a")
    U.wait(4)
  end
  if not wentOn then
    return C.fail("the fight stalled after the item (turn " .. tostring(lb.turnCount) .. ")")
  end
  U.log("PVP host: the duel kept resolving turns after the item")

  if not L.waitFor(DIR, "guest_done.txt", 3600) then
    return C.fail("the guest never finished")
  end
  U.log("PVP OK host: an item crossed the cable and the duel stayed in step")
  love.event.quit(0)
  U.wait(10)
end
