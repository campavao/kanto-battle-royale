-- POK-181: a bot's team evolves with the rung.
--
-- A solo match.  A bot's record is rewritten by hand -- a CATERPIE, a
-- KADABRA that changed hands, a GRIMER, a NIDORAN_M -- and read back at
-- several rungs through the same derivation the fight uses: BUTTERFREE
-- by 15, MUK by 38, ALAKAZAM at any rung, NIDOKING once the bot's seeded
-- stone rung is passed.  Then the real thing: the fog is short, so the
-- rung reaches 15 in a minute, and a fight with that bot opens on a
-- BUTTERFREE -- the engine's own battle, read off its enemy battler.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-botevo POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_evolve_smoke.lua \
--   <path to>/lovec . > bot_evolve.log 2>&1
--
-- Exit 0 with a `BOTEVO OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("BREEDER")
  E.setSafari(0)
  E.setFog(25)
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
  local Pokemon = require("src.pokemon.Pokemon")
  local lead = Pokemon.new(game.data, "MACHOP", 15)
  lead.moves = { { id = "SEISMIC_TOSS", pp = 99 } }
  game.save.party = { lead }

  local bots = E.bots() or {}
  if #bots < 1 then return C.fail("no bots") end
  for _, b in ipairs(bots) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end
  local bot = bots[1]
  local rec = E.botRecord(bot.id)
  if not rec then return C.fail("no record for bot " .. tostring(bot.id)) end
  -- the team under test, written straight into the record (solo: no wire)
  for i = #rec, 1, -1 do rec[i] = nil end
  rec[1] = { species = "CATERPIE", hpFrac = 1 }
  rec[2] = { species = "KADABRA", hpFrac = 1, traded = true }
  rec[3] = { species = "GRIMER", hpFrac = 1 }
  rec[4] = { species = "NIDORAN_M", hpFrac = 1 }
  local stone = E.botStone(bot.id)
  U.log(("BOTEVO: %s's stone rung is %s"):format(tostring(bot.name), tostring(stone)))

  local function rowsAt(rung)
    local out = {}
    for _, r in ipairs(E.botRows(bot.id, rung) or {}) do out[#out + 1] = r.species end
    return table.concat(out, ",")
  end
  local function expect(rung, want)
    local got = rowsAt(rung)
    if got ~= want then
      return C.fail(("at rung %d the rows read %s, wanted %s"):format(rung, got, want))
    end
    U.log(("BOTEVO: rung %d -> %s"):format(rung, got))
    return true
  end
  if not expect(5, "CATERPIE,ALAKAZAM,GRIMER,NIDORAN_M") then return end
  if not expect(15, "BUTTERFREE,ALAKAZAM,GRIMER,NIDORAN_M") then return end
  if not expect(37, "BUTTERFREE,ALAKAZAM,GRIMER," .. ((stone and stone <= 37) and "NIDOKING" or "NIDORINO")) then return end
  if not expect(100, "BUTTERFREE,ALAKAZAM,MUK," .. (stone and "NIDOKING" or "NIDORINO")) then return end

  -- the real thing: wait for the rung to reach 15, then fight the bot
  local t0 = love.timer.getTime()
  while (E.level() or 5) < 15 and love.timer.getTime() - t0 < 120 do U.wait(10) end
  if (E.level() or 5) < 15 then return C.fail("the rung never reached 15 (level " .. tostring(E.level()) .. ")") end
  U.log(("BOTEVO: rung %d, engaging %s"):format(E.level(), tostring(bot.name)))
  local ow = C.ow()
  local mx, my, mmap = C.x(), C.y(), C.map()
  -- park the bot on the cell ahead and ask for the fight by hand
  local fx, fy = mx, my + 1
  if ow.player.facing == "up" then fy = my - 1
  elseif ow.player.facing == "left" then fx, fy = mx - 1, my
  elseif ow.player.facing == "right" then fx, fy = mx + 1, my end
  E.debugPlaceBot(bot.id, mmap, fx, fy)
  U.wait(30)
  if not E.debugChallenge(bot.id) then
    return C.fail("debugChallenge refused (phase " .. tostring(E.phase()) .. ", status " .. tostring(E.status()) .. ")")
  end
  local enemy
  t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 60 do
    local top = game.stack:top()
    if top and top.enemy and top.enemy.mon and top.enemy.mon.species then
      enemy = top.enemy.mon.species
      break
    end
    U.tap(game, "a") U.wait(10)
  end
  if not enemy then return C.fail("no battle opened against the bot (top " .. tostring(game.stack:top()) .. ")") end
  if enemy ~= "BUTTERFREE" then
    return C.fail("the fight opened on a " .. tostring(enemy) .. ", not the BUTTERFREE the rung made")
  end
  U.log("BOTEVO: the fight opened on a BUTTERFREE at rung " .. tostring(E.level()))
  U.log("BOTEVO OK: a bot's team is what its lines have reached")
  love.event.quit(0)
  U.wait(30)
end
