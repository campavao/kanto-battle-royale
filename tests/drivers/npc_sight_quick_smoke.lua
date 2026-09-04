-- POK-163: do route trainers stay sightless through a REAL Quick Play?
--
-- npc_sight_smoke (POK-150) proves the lever on a solo room that starts
-- straight into the match.  The regression was seen in Quick Play, which
-- differs in every way that one does not: a relay room, the countdown, the
-- default Safari opening, the buzzer and the drop.  So this one takes that
-- road, and at every milestone counts how many generic trainers still
-- carry a talk handler (the lever: checkTrainerSight skips a trainer whose
-- TEXT has one) -- then goes and stands in one's sight line.
--
-- Needs the relay up on 127.0.0.1:7790 (PORT=7790 node relay/server.js).
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-npc-quick POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/npc_sight_quick_smoke.lua \
--   <path to>/lovec . > npc_sight_quick.log 2>&1
--
-- BR_QUICK_SAFARI=0 skips the Safari (the smoke's own shape, for a
-- control).  Exit 0 with a `QUICKSIGHT OK` line passes; any `PVP FAIL`
-- line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local GYM = "PEWTER_GYM"

return function(game)
  local C = L.ctx(game)
  local MapScripts = require("src.script.MapScripts")

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  local function armedReport(tag)
    local total, armed = 0, 0
    for mapId, def in pairs(game.data.maps) do
      for _, o in ipairs(def.objects or {}) do
        if o.trainerClass and o.text and not MapScripts.baseTalk(mapId, o.text) then
          total = total + 1
          if type(MapScripts.talkScript(mapId, o.text)) == "function" then
            armed = armed + 1
          end
        end
      end
    end
    U.log(("QUICK ARMED %s: %d/%d generic trainers carry a talk handler "
           .. "(phase %s, status %s, map %s)"):format(
      tag, armed, total, tostring(E.phase()), tostring(E.status()),
      tostring(C.map())))
    return armed, total
  end

  local a0, t0 = armedReport("before any room")
  if a0 ~= 0 then return C.fail("talk handlers armed outside a session") end

  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("QUICK")
  if os.getenv("BR_QUICK_SAFARI") == "0" then E.setSafari(0) end
  E.setFog(600)
  local ok, err = E.quickPlay()
  if not ok then return C.fail("quickPlay refused: " .. tostring(err)) end
  local hosted = false
  for _ = 1, 600 do
    U.wait(10)
    if E.phase() == "lobby" and (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then
    return C.fail("quick play never produced a lobby: " .. tostring(E.lastError()))
  end
  U.log(("QUICK: in the quick-play lobby; starts in %s"):format(tostring(E.startsIn())))
  armedReport("in the lobby")

  -- the countdown starts the match by itself (QUICK_START_SECONDS) -- on
  -- the WALL clock, so the wait is too: at POKEPORT_SPEED=3 a frame is a
  -- third of a wall-tick, and a frame-counted wait gave up at fifty seconds
  local function wall() return love.timer.getTime() end
  local started = false
  local t0 = wall()
  while (wall() - t0) < 200 do
    U.wait(1)
    local p = E.phase()
    if p == "safari" or p == "match" then started = true break end
    if p == "off" then break end
  end
  if not started then
    return C.fail("the countdown never started the match (phase "
                  .. tostring(E.phase()) .. ")")
  end
  U.log("QUICK: match started as " .. tostring(E.phase()))
  armedReport("at the start")

  if E.phase() == "safari" then
    -- a party, so the buzzer does not eliminate us; the zone's own
    -- catching is playtest_standard's job
    L.armParty(C, "MACHOP", 20, "KARATE_CHOP")
    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    local TownMap = require("src.ui.TownMap")
    local landed = false
    local tz = wall()
    while (wall() - tz) < 320 do   -- the Safari clock is wall time too
      local top = game.stack:top()
      if getmetatable(top) == TownMap and top.fly then
        U.tap(game, "a")
      elseif E.phase() == "match" and top == C.ow() and not C.ow().transitioning then
        landed = true
        break
      elseif E.phase() == "lobby" or E.phase() == "off" then
        break
      elseif C.busy() then
        U.tap(game, "a")
      end
      U.wait(6)
    end
    if not landed then
      return C.fail("never landed after the buzzer (phase " .. tostring(E.phase())
                    .. ", status " .. tostring(E.status()) .. ")")
    end
    U.log("QUICK: dropped at " .. tostring(C.map()))
    armedReport("after the drop")
  else
    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    U.wait(30)
  end
  if E.status() ~= "alive" then
    return C.fail("not alive after the drop: " .. tostring(E.status()))
  end

  -- a lead that can survive being wrong about all this
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 20) }

  -- into Pewter's gym, the smoke's own floor
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  armedReport("after FLY")
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail("never reached the gym door; at "
      .. tostring(C.x()) .. "," .. tostring(C.y()))
  end
  for _ = 1, 40 do
    if C.map() == GYM then break end
    U.hold(game, "up", 4)
    U.wait(10)
  end
  if C.map() ~= GYM then
    return C.fail("never entered the gym; at " .. tostring(C.map()))
  end
  U.wait(30)
  armedReport("in the gym")

  local def = game.data.maps[GYM]
  local victimDef
  for _, o in ipairs((def and def.objects) or {}) do
    if o.trainerClass and o.text and not MapScripts.baseTalk(GYM, o.text) then
      victimDef = o
      break
    end
  end
  if not victimDef then return C.fail("no generic trainer in " .. GYM) end
  U.log(("QUICK: %s talk handler is %s"):format(tostring(victimDef.name),
    type(MapScripts.talkScript(GYM, victimDef.text))))

  local ow = C.ow()
  local victim
  for _, npc in ipairs(ow.npcs or {}) do
    if npc.def and npc.def.text == victimDef.text then victim = npc break end
  end
  if not victim then return C.fail("the trainer is not on the floor") end
  local DIRVEC = { up = { 0, -1 }, down = { 0, 1 },
                   left = { -1, 0 }, right = { 1, 0 } }
  local vec = DIRVEC[victim.facing]
  if not vec then return C.fail("trainer faces " .. tostring(victim.facing)) end
  local lx, ly = victim.cellX + vec[1] * 2, victim.cellY + vec[2] * 2
  if not L.goTo(C, GYM, lx, ly, 300) then
    return C.fail(("never reached the sight line at %d,%d; at %s,%s")
      :format(lx, ly, tostring(C.x()), tostring(C.y())))
  end
  U.log(("QUICK: standing at %d,%d, two cells down %s's nose"):format(
    lx, ly, tostring(victimDef.name)))
  for _ = 1, 120 do
    U.wait(3)
    local top = game.stack:top()
    if type(top) == "table" and top.enemyParty then
      armedReport("at the ambush")
      return C.fail("it engaged on sight")
    end
    if ow.engaging then
      armedReport("at the ambush")
      return C.fail("the sight approach started")
    end
  end
  U.log("QUICK: stood in the line; nothing moved")
  U.log("QUICKSIGHT OK: no ambush through a real quick play")
  love.event.quit(0)
  U.wait(10)
end
