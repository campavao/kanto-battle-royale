-- Scenario "spectate", host side: lose the duel, then WATCH the winner
-- fight -- on the battle screen, not from the grass (lib/mirror.lua).
--
-- The duel is the "duel" scenario's (host posts in Pewter with a RATTATA,
-- the guest walks in with a MEWTWO), with one bot in the room so the match
-- outlives the host's elimination.  Once out, this side turns its camera
-- on the guest and waits: the guest stages a wild fight, and this screen
-- must open a replica of it over the relay, play it through with no input,
-- and close with the result the guest's own fight came to.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("HOSTA")
  E.setBots(1)          -- somebody has to be left standing with the winner
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
  U.log("PVP host: guest is in; starting the match")
  E.start()

  if not L.waitPhase(C, "match", 240) then return C.fail("never reached the match") end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  -- the bot is scenery: off the map, where it can engage nobody
  for _, b in ipairs(E.bots() or {}) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end

  -- the sacrificial lamb: this side is here to lose the duel
  L.armParty(C, "RATTATA", 5, "TACKLE")
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "down", 6)
  L.put(DIR, "posted.txt", "1")
  U.log("PVP host: posted at 16,18 facing down; awaiting the challenger")

  if not L.mashUntil(C, function() return E.status() == "battle" end, 2400) then
    return C.fail("the duel never started on the host side")
  end
  U.log("PVP host: lockstep battle open")
  if not L.mashUntil(C, function() return E.status() == "out" end, 4800) then
    return C.fail("the host never went out (it should have lost)")
  end
  U.log("PVP host: eliminated as planned; now a spectator")
  for _ = 1, 12 do U.tap(game, "a") U.wait(15) end   -- the OUT text
  if E.phase() ~= "match" then
    return C.fail("the match ended with the host; the bot should have kept it open (phase "
                  .. tostring(E.phase()) .. ")")
  end

  -- turn the camera on the guest
  local guestId
  for _, p in ipairs(E.players() or {}) do
    if p.name == "GUESTB" then guestId = p.id end
  end
  if not guestId then return C.fail("the guest is not on the roster") end
  local watching = false
  for _ = 1, 8 do
    U.wait(30)
    if E.watching() == guestId then watching = true break end
    E.hop(1)
  end
  if not watching then
    return C.fail("could not turn the camera on the guest (watching " .. tostring(E.watching()) .. ")")
  end
  U.wait(120)   -- a peek goes out; the guest sees a watcher
  L.put(DIR, "spectating.txt", "1")
  U.log("PVP host: watching " .. tostring(guestId) .. "; waiting for their fight")

  -- the guest's fight must arrive here as a replica, opened with no input
  local opened = false
  for _ = 1, 1800 do
    U.wait(10)
    local m = E.mirror()
    if m.open then opened = true break end
  end
  if not opened then
    local m = E.mirror()
    return C.fail(("the guest's fight never opened here (frames %s from %s)")
      :format(tostring(m.frames), tostring(m.from)))
  end
  U.log("PVP host: the guest's fight is on this screen")
  shot("spectate_open")
  local closed, peak = false, 0
  for i = 1, 2400 do
    U.wait(10)
    local m = E.mirror()
    if m.turn and m.turn > peak then peak = m.turn end
    if i == 40 then shot("spectate_playing") end
    if not m.open then closed = true break end
  end
  shot("spectate_after")
  if not closed then return C.fail("the replica never closed") end
  local last = E.mirror().last
  if not last then return C.fail("the replica left no record of how it closed") end
  U.log(("PVP host: replica closed (%s) result %s after %s turns")
    :format(tostring(last.why), tostring(last.result), tostring(last.turn)))
  L.put(DIR, "replica.txt", ("%s %s %s"):format(tostring(last.why), tostring(last.result), tostring(last.turn)))
  local theirs = L.waitFor(DIR, "fought.txt", 1200)
  if not theirs then return C.fail("the guest never reported its fight") end
  local gResult, gTurns = theirs:match("(%S+)%s+(%S+)")
  if last.why ~= gResult or last.result ~= gResult then
    return C.fail(("the replica ended %s/%s, the guest's fight %s")
      :format(tostring(last.why), tostring(last.result), tostring(gResult)))
  end
  if tostring(last.turn) ~= gTurns then
    return C.fail(("the replica played %s turns, the guest's fight %s"):format(tostring(last.turn), gTurns))
  end
  -- the camera is back on the map, and this side is still a spectator
  local back = false
  for _ = 1, 200 do
    U.wait(5)
    if game.stack:top() == C.ow() then back = true break end
  end
  if not back then return C.fail("the map did not come back under the spectator") end
  if E.status() ~= "out" then return C.fail("spectating changed our status to " .. tostring(E.status())) end
  U.log("PVP OK host: watched the guest's fight on the battle screen, to the same ending")
  love.event.quit(0)
  U.wait(10)
end
