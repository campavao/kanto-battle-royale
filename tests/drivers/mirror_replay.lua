-- The fight a spectator is shown (lib/mirror.lua), proved on one client.
--
-- A spectator's view of somebody else's battle is a REPLAY: the watched
-- client records its fight as a seed plus every choice, and the replica
-- runs the engine's own BattleState from that.  The claim is that the
-- replica reaches the same ending the real fight did.  One client can
-- prove it: fight a staged wild battle while recording, then open a
-- replica of the recording on the same client -- through the wire's own
-- encode/decode -- and let it play to its end with no input at all.
--
-- What it asserts:
--   * the fight was recorded: a start frame, at least one move frame,
--     and an end frame carrying the result;
--   * the replica opens, plays itself (a page turns without a press), and
--     closes on its own;
--   * the replica's result and turn count match the recording's;
--   * the map is back on top afterwards and the mod's tick did not throw.
--
--   SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1 POKEPORT_GAME=red \
--   POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_IDENTITY=br-mirror POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/mirror_replay.lua \
--   <path to>/lovec . > mirror.log 2>&1
--
-- `MIRROR OK` passes it; any `PVP FAIL` line fails it.  BR_SHOTS=<abs dir>
-- takes screenshots of the replica as it plays.

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
  E.setName("REC")
  E.setSafari(0)
  E.setFog(300)
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

  -- a fight worth a few turns: one mon, one damaging move, a foe that
  -- takes two or three hits
  L.armParty(C, "NIDORINO", 18, "TACKLE")
  local wild
  local okWild = pcall(function()
    local ow = C.ow()
    wild = require("src.battle.BattleState").newWild(game, "RATTATA", 12)
    wild.onFinish = function(result) ow:afterBattle(result, wild) end
    ow:pushBattle(wild)
  end)
  if not (okWild and wild) then return C.fail("could not stage a wild battle") end
  local opened = false
  for _ = 1, 200 do
    U.wait(10)
    if game.stack:top() == wild then opened = true break end
  end
  if not opened then return C.fail("the staged wild battle did not open") end
  U.wait(30)
  local m = E.mirror()
  if not (m and m.recording) then return C.fail("the fight is not being recorded") end
  U.log("MIRROR: recording the real fight")

  -- fight it: A picks FIGHT, then the first move, then turns the pages
  local ended = L.mashUntil(C, function()
    return game.stack:top() ~= wild and (E.mirrorLog() or {})[1] ~= nil
           and (E.mirrorLog())[#E.mirrorLog()].k == "end"
  end, 900)
  if not ended then return C.fail("the real fight never ended") end
  for _ = 1, 10 do U.tap(game, "a") U.wait(10) end   -- the return fade
  U.wait(30)

  local log = E.mirrorLog()
  if not (log and log[1] and log[1].k == "start") then return C.fail("no start frame recorded") end
  local moves, last = 0, log[#log]
  for _, f in ipairs(log) do
    if f.k == "move" or f.k == "struggle" or f.k == "locked" then moves = moves + 1 end
  end
  if last.k ~= "end" then return C.fail("the recording does not end with an end frame") end
  if moves < 1 then return C.fail("no move frame recorded") end
  U.log(("MIRROR: recorded %d frames, %d turns, result %s, seed %s")
    :format(#log, moves, tostring(last.result), tostring(log[1].seed)))
  if E.status() ~= "alive" then return C.fail("the real fight left status " .. tostring(E.status())) end

  -- now the replica, from the same recording, on this client
  local okOpen, why = E.replayMirror(log)
  if not okOpen then return C.fail("replayMirror refused: " .. tostring(why)) end
  local shown = false
  for _ = 1, 300 do
    U.wait(5)
    local st = E.mirror()
    if st.open then shown = true break end
  end
  if not shown then return C.fail("the replica never opened") end
  U.log("MIRROR: replica open")
  shot("mirror_open")
  -- no input from here: the replica must turn its own pages and close
  local closed, peakTurn = false, 0
  for i = 1, 1200 do
    U.wait(10)
    local st = E.mirror()
    if st.turn and st.turn > peakTurn then peakTurn = st.turn end
    if i == 30 then shot("mirror_playing") end
    if not st.open then closed = true break end
  end
  shot("mirror_after")
  if not closed then
    local st = E.mirror()
    return C.fail(("the replica never closed (turn %s, pending %s, phase %s)")
      :format(tostring(st.turn), tostring(st.pending), tostring(game.stack:top() and game.stack:top().phase)))
  end
  local lastM = E.mirror().last
  if not lastM then return C.fail("the replica left no record of how it closed") end
  U.log(("MIRROR: replica closed (%s) result %s after %s turns")
    :format(tostring(lastM.why), tostring(lastM.result), tostring(lastM.turn)))
  if lastM.why ~= last.result then
    return C.fail(("the replica closed for %s, the recording ended %s")
      :format(tostring(lastM.why), tostring(last.result)))
  end
  if lastM.result ~= last.result then
    return C.fail(("the replica's own result was %s, the real fight's %s")
      :format(tostring(lastM.result), tostring(last.result)))
  end
  if (lastM.turn or 0) ~= moves then
    return C.fail(("the replica played %s turns, the recording has %d")
      :format(tostring(lastM.turn), moves))
  end
  -- the map comes back under the fade
  local back = false
  for _ = 1, 120 do
    U.wait(5)
    if game.stack:top() == C.ow() then back = true break end
  end
  if not back then return C.fail("the map did not come back after the replica") end
  if E.status() ~= "alive" then return C.fail("the replica touched our status: " .. tostring(E.status())) end
  U.log("MIRROR OK")
  love.event.quit(0)
end
