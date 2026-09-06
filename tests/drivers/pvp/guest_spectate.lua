-- Scenario "spectate", guest side: win the duel, then fight a wild mon
-- while the loser watches -- and prove the fight was recorded for them
-- (lib/mirror.lua).
--
-- Joins by the published code, walks into the host's eyeline in Pewter and
-- wins the lockstep duel (the "duel" scenario's guest).  With the host out
-- and watching, this side stages a wild fight and plays it with A: the
-- recorder must see a watcher, and the fight's result and turn count go
-- to the host through the handshake files to be checked against its
-- replica.
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
  E.setName("GUESTB")

  local code = L.waitFor(DIR, "code.txt", 3600)
  if not code then return C.fail("no room code ever appeared") end
  code = code:gsub("%s", "")
  local joined = false
  for _ = 1, 10 do
    E.join(code)
    for _ = 1, 120 do
      U.wait(10)
      if E.memberCount() >= 2 then joined = true break end
    end
    if joined then break end
  end
  if not joined then
    return C.fail("could not join " .. code .. ": " .. tostring(E.lastError()))
  end
  U.log("PVP guest: in room " .. code)

  if not L.waitPhase(C, "match", 360) then return C.fail("never reached the match") end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  -- the champion: this side is here to win the duel
  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.waitFor(DIR, "posted.txt", 3600) then return C.fail("the host never posted") end
  if not L.goTo(C, "PEWTER_CITY", 16, 20, 300) then
    return C.fail(("never reached the approach; at %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  U.log("PVP guest: below the post; stepping into the eyeline")
  local fought = false
  for _ = 1, 60 do
    if C.E().status() == "battle" then fought = true break end
    U.hold(game, "up", 12)
    U.wait(10)
    U.tap(game, "a")
    U.wait(10)
  end
  if not fought then
    fought = L.mashUntil(C, function() return E.status() == "battle" end, 1200)
  end
  if not fought then return C.fail("the duel never started on the guest side") end
  U.log("PVP guest: lockstep battle open")
  if not L.mashUntil(C, function() return E.status() == "alive" and game.stack:top() == C.ow() end, 4800) then
    return C.fail("the duel never ended with this side back on the map")
  end
  if E.phase() ~= "match" then
    return C.fail("the match ended with the duel; the bot should have kept it open (phase "
                  .. tostring(E.phase()) .. ")")
  end
  U.log("PVP guest: duel won; waiting for the host to watch")
  if not L.waitFor(DIR, "spectating.txt", 3600) then
    return C.fail("the host never said it was watching")
  end
  -- let the breather after the duel pass, and the first peek land
  U.wait(240)

  -- a fight worth a few turns, staged like a grass encounter
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
  if not m.recording then return C.fail("the fight is not being recorded") end
  if (m.watchers or 0) < 1 then return C.fail("nobody is counted as watching this fight") end
  U.log(("PVP guest: fighting, recorded for %d watcher(s)"):format(m.watchers))
  local ended = L.mashUntil(C, function()
    local log = E.mirrorLog()
    return game.stack:top() ~= wild and log and log[1] and log[#log].k == "end"
  end, 900)
  if not ended then return C.fail("the wild fight never ended") end
  for _ = 1, 10 do U.tap(game, "a") U.wait(10) end
  local log = E.mirrorLog()
  local turns = 0
  for _, f in ipairs(log) do
    if f.k == "move" or f.k == "struggle" or f.k == "locked" then turns = turns + 1 end
  end
  U.log(("PVP guest: fight over, %d frames, %d turns, result %s"):format(#log, turns, tostring(log[#log].result)))
  L.put(DIR, "fought.txt", ("%s %d"):format(tostring(log[#log].result), turns))

  -- stay in the room until the host has checked its replica
  if not L.waitFor(DIR, "replica.txt", 2400) then
    return C.fail("the host never reported its replica")
  end
  U.log("PVP OK guest: duel won, wild fight recorded for the watcher")
  love.event.quit(0)
  U.wait(10)
end
