-- POK-150: route trainers stop engaging on sight -- talk to them to fight.
--
-- Three checks against Pewter Gym's floor trainer:
--
--   1. OUTSIDE a session, nothing is registered: the trainer's TEXT has
--      no talk script, so vanilla sight is untouched for real playthroughs.
--   2. IN a match, standing squarely in its sight line starts nothing.
--   3. Talking to it starts the vanilla fight.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-npc-sight POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/npc_sight_smoke.lua \
--   <path to>/lovec . > npc_sight.log 2>&1
--
-- Exit 0 with a `SIGHTLESS OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local GYM = "PEWTER_GYM"

return function(game)
  local C = L.ctx(game)
  local MapScripts = require("src.script.MapScripts")

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end

  -- 1. before any session: no talk scripts registered for gym trainers
  local def = game.data.maps[GYM]
  local victimDef
  for _, o in ipairs((def and def.objects) or {}) do
    if o.trainerClass and o.text and not MapScripts.baseTalk(GYM, o.text) then
      victimDef = o
      break
    end
  end
  if not victimDef then return C.fail("no generic trainer in " .. GYM) end
  if MapScripts.talkScript(GYM, victimDef.text) then
    return C.fail("talk script registered OUTSIDE a session -- vanilla "
      .. "sight would be dead in real playthroughs")
  end
  U.log(("SIGHTLESS: %s carries no talk script before the match"):format(
    tostring(victimDef.name)))

  E.setName("SCOUT")
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

  if type(MapScripts.talkScript(GYM, victimDef.text)) ~= "function" then
    return C.fail("the match did not arm the trainer's talk script")
  end

  -- a lead that can survive being wrong about all this
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 20) }

  -- into the gym: stand at the door and step up through it
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
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

  -- find the trainer on the floor and a cell squarely in its sight line
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
  U.log(("SIGHTLESS: standing at %d,%d, two cells down %s's nose"):format(
    lx, ly, tostring(victimDef.name)))

  -- 2. stand there: nothing may happen
  for _ = 1, 120 do
    U.wait(3)
    local top = game.stack:top()
    if type(top) == "table" and top.enemyParty then
      return C.fail("it engaged on sight anyway")
    end
    if ow.engaging then
      return C.fail("the sight approach started anyway")
    end
  end
  U.log("SIGHTLESS: stood in the line; nothing moved")

  -- 3. walk up and talk: the fight must still be there for the taking
  local sx, sy = victim.cellX + vec[1], victim.cellY + vec[2]
  if not L.goTo(C, GYM, sx, sy, 200) then
    return C.fail("could not step adjacent to talk")
  end
  local face = (vec[2] == 1 and "up") or (vec[2] == -1 and "down")
    or (vec[1] == 1 and "left") or "right"
  for _ = 1, 20 do
    if ow.player.facing == face then break end
    U.hold(game, face, 2)
    U.wait(8)
  end
  local fought = false
  for _ = 1, 40 do
    U.tap(game, "a")
    for _ = 1, 20 do
      local top = game.stack:top()
      if type(top) == "table" and top.enemyParty then fought = true break end
      U.wait(3)
    end
    if fought then break end
  end
  if not fought then return C.fail("talking to it no longer starts the fight") end
  U.log("SIGHTLESS OK: no ambush, and the fight was there when asked for")
  love.event.quit(0)
  U.wait(30)
end
