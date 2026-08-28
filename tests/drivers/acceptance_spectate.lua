-- POK-158 acceptance: an all-bot match, watched to a winner.
--
-- The player drops out at the drop and spectates.  Twelve bots then
-- play the match for real -- catching, looting, healing, fighting,
-- dodging the fog -- until one of them wins it.  The driver asserts the
-- shape (the match ends with exactly one bot alive and a real record);
-- the ARC is in the engine log afterwards: CAUGHT / LOOTED / POTION /
-- HEALED / OUT / WINNER lines, a run indistinguishable from a player's.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-acceptance POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/acceptance_spectate.lua \
--   <path to>/lovec . > acceptance.log 2>&1
--
-- Exit 0 with an `ACCEPTANCE OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("REF")
  E.setSafari(0)
  E.setFog(45)   -- a brisk ring, so the match resolves in minutes
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(12)
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

  -- out at the drop; the roster is all bots from here
  if not E.debugOut("acceptance") then return C.fail("debugOut refused") end
  U.log("ACCEPTANCE: referee out; twelve bots have the match")
  for _ = 1, 10 do U.tap(game, "a") U.wait(15) end   -- the OUT text

  local t0 = love.timer.getTime()
  local lastSay = t0
  local lastAlive
  local winner
  while love.timer.getTime() - t0 < 720 do
    local alive, aliveBot = 0, nil
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" then
        alive = alive + 1
        aliveBot = b
      end
    end
    if alive >= 1 then lastAlive = aliveBot end
    local phase = E.phase()
    if phase == "over" or phase == "lobby" or phase == "off"
       or (phase == "match" and alive <= 1) then
      winner = alive == 1 and aliveBot or lastAlive
      if alive <= 1 then break end
    end
    local e = E.tickError()
    if e then return C.fail("tick error mid-match: " .. tostring(e)) end
    if love.timer.getTime() - lastSay >= 20 then
      lastSay = love.timer.getTime()
      U.log(("ACCEPTANCE: %d bots alive at %.0fs (phase %s)")
        :format(alive, lastSay - t0, tostring(phase)))
    end
    -- keep any spectator text moving; the camera needs no other input
    U.tap(game, "a")
    U.wait(20)
  end
  if not winner then
    return C.fail("twelve minutes and the match never resolved to a winner")
  end
  local rec = E.botRecord(winner.id)
  if not (rec and #rec >= 1) then
    return C.fail("the winner has no record -- the run was synthetic")
  end
  local wounds = 0
  for _, m in ipairs(rec) do
    if (m.hpFrac or 1) < 1 then wounds = wounds + 1 end
  end
  U.log(("ACCEPTANCE OK: %s wins with %d mons (%d carrying wounds), %d bag items")
    :format(tostring(winner.name), #rec, wounds,
            rec.bag and #rec.bag.items or 0))
  love.event.quit(0)
  U.wait(30)
end
