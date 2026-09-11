-- v0.50.1: a flight cannot be interrupted.
--
-- A player reported being challenged mid-FLY and landing in a broken
-- state.  The bird's lead-in, the warp and the swoop down all run inside
-- the overworld state with nothing on top, so `top == ow` read them as a
-- quiet screen: a challenge was answered, a battle opened over a player
-- who was between two maps.  Now every frame of a flight reads busy
-- ("menu" on the wire), refuses the yank, and a bot planted in sight at
-- the departure cell gets no fight -- not during, and not after, since we
-- are gone.
--
--   tools/drive.sh fly_busy_smoke
--
-- Exit 0 with a `FLYBUSY OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("FLIER")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(2)
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
  L.armParty(C, "PIDGEOT", 50, "FLY")
  for _, b in ipairs(E.bots() or {}) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end

  -- Pewter's street, facing east; a bot planted north of us looking down,
  -- its sight crossing ours the moment it lands (bot_sight_smoke's stage)
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  local ow = C.ow()
  for _ = 1, 20 do
    if ow.player.facing == "right" then break end
    U.hold(game, "right", 2) U.wait(8)
  end
  U.wait(20)
  if E.busy() ~= nil then return C.fail("busy before the flight: " .. tostring(E.busy())) end

  -- take off, and plant the bot the same frame
  local victim = (E.bots() or {})[1]
  if not victim then return C.fail("no bot") end
  ow:flyTo("VIRIDIAN_CITY")
  E.debugPlaceBot(victim.id, "PEWTER_CITY", 16, 15)
  local frames, busyFrames, yanks = 0, 0, 0
  local phases = {}
  for _ = 1, 2400 do
    local o = C.ow()
    local air = o and (o.flyAnim or o.flyArrive or o.transitioning)
    if not air and C.map() == "VIRIDIAN_CITY" then break end
    if air then
      frames = frames + 1
      if E.busy() == "menu" then busyFrames = busyFrames + 1 end
      if E.yankScreen() then yanks = yanks + 1 end
      phases[o.flyAnim and "depart" or o.flyArrive and "arrive" or "warp"] = true
    end
    if E.status() == "battle" then return C.fail("a battle opened mid-flight") end
    U.wait(1)
  end
  if C.map() ~= "VIRIDIAN_CITY" then return C.fail("never landed; at " .. tostring(C.map())) end
  if frames == 0 then return C.fail("the flight had no frames to watch") end
  if busyFrames ~= frames then
    return C.fail(("busy on %d of %d frames in the air"):format(busyFrames, frames))
  end
  if yanks > 0 then return C.fail("the yank went through mid-flight") end
  local seen = {}
  for k in pairs(phases) do seen[#seen + 1] = k end
  table.sort(seen)
  U.log(("FLYBUSY: %d frames in the air (%s), every one busy, none yanked")
    :format(frames, table.concat(seen, "+")))
  U.wait(60)
  if E.status() == "battle" then return C.fail("the bot got its fight after the landing") end
  if E.busy() ~= nil then return C.fail("still busy after landing: " .. tostring(E.busy())) end
  U.log("FLYBUSY OK: a flight is never interrupted, and the bot never got its fight")
  love.event.quit(0)
  U.wait(30)
end
