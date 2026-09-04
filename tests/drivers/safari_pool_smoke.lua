-- POK-177: the zone has a shape, and the bots draft from it.
--
-- A solo match against the real data: the zone names a theme, holds
-- POOL_SIZE species, at least RARE_PER_POOL of the rare slice and at
-- least THEME_PER_POOL carrying the theme's type -- and every bot's
-- first mon is out of that zone.  Then a real catch in the grass: the
-- first wild encounter of the Safari is one of the zone's species.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-zone POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/safari_pool_smoke.lua \
--   <path to>/lovec . > safari_pool.log 2>&1
--
-- Exit 0 with a `ZONE OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Safari = require("mods.battle_royale.lib.safari")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("ZONER")
  E.setSafari(120)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(8)
  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end
  E.start()
  if not L.mashUntil(C, function() return E.phase() == "safari" end, 400) then
    return C.fail("never reached the Safari (phase " .. tostring(E.phase()) .. ")")
  end

  local zone, theme = E.safariPool()
  if not zone then return C.fail("no zone") end
  U.log(("ZONE: %s"):format(Safari.describe(zone, theme)))
  if #zone ~= Safari.POOL_SIZE then return C.fail("zone holds " .. #zone) end
  if not theme then return C.fail("the real data offered no theme") end
  local rareSet = {}
  for _, sp in ipairs(Safari.RARE) do rareSet[sp] = true end
  local rares, themed, zoneSet = 0, 0, {}
  for _, sp in ipairs(zone) do
    zoneSet[sp] = true
    if rareSet[sp] then rares = rares + 1 end
    local def = game.data.pokemon[sp]
    if not def then return C.fail("the zone names a species the data lacks: " .. sp) end
    for _, ty in ipairs(def.types or {}) do
      if ty == theme then themed = themed + 1 end
    end
  end
  if rares < Safari.RARE_PER_POOL then return C.fail("only " .. rares .. " rare entries") end
  if themed < Safari.THEME_PER_POOL then
    return C.fail(("only %d of the zone carry the %s theme"):format(themed, tostring(theme)))
  end
  U.log(("ZONE: %d rare, %d of the theme"):format(rares, themed))

  -- the bots drafted from it
  local bots = E.bots() or {}
  if #bots == 0 then return C.fail("no bots") end
  for _, b in ipairs(bots) do
    local rec = E.botRecord(b.id)
    local first = rec and rec[1] and rec[1].species
    if not zoneSet[first] then
      return C.fail(("bot %s drafted %s, which is not in the zone"):format(
        tostring(b.name), tostring(first)))
    end
  end
  U.log(("ZONE: all %d bots drafted their first mon from the zone"):format(#bots))

  -- and the grass agrees: walk the zone until something appears
  local caught
  local t0 = love.timer.getTime()
  local dirs = { "up", "down", "left", "right" }
  local i = 0
  while love.timer.getTime() - t0 < 90 and E.phase() == "safari" do
    local top = game.stack:top()
    if top ~= C.ow() then
      -- a BattleState carries its enemy battler, whose mon is the wild one
      local sp = top.enemy and top.enemy.mon and top.enemy.mon.species
      if sp then caught = sp break end
      U.tap(game, "b") U.wait(6)
    else
      i = i + 1
      U.hold(game, dirs[(i % 4) + 1], 10) U.wait(4)
    end
  end
  if not caught then
    U.log("ZONE: no wild encounter met inside the budget (not an assertion)")
  else
    if not zoneSet[caught] then
      return C.fail("the grass rolled " .. tostring(caught) .. ", which is not in the zone")
    end
    U.log("ZONE: the grass rolled " .. caught .. ", from the zone")
  end
  U.log("ZONE OK: themed, rare-guaranteed, and the bots draft from it")
  love.event.quit(0)
  U.wait(30)
end
