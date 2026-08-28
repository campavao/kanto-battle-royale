-- POK-158 M2/M3: a bot fight has a bill, the winner loots the fallen,
-- and a wrecked team walks to the Centre.
--
-- Three acts, staged with two bots while we idle a town away:
--
--   1. THE FIGHT (M3): both bots planted adjacent on ROUTE_1.  One goes
--      OUT; the winner's record must show damage -- the coin flip never
--      cost anybody anything.
--   2. THE LOOT (M2): the loser's team hit the ground where it fell, and
--      the winner is standing beside it with room in its party.  Its
--      record must grow by a looted ball.
--   3. THE NURSE (M2): the winner, scarred to 20% (debugScarBot) and
--      planted beside Pewter's Centre door, must walk over, wait, and
--      come back to full -- the HEALED line lands in the log.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-survivor POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_survivor_smoke.lua \
--   <path to>/lovec . > survivor.log 2>&1
--
-- Exit 0 with a `SURVIVOR OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SCOUT")
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

  -- idle a town away so neither bot ever has us for prey
  if not L.flyTo(C, "LAVENDER_TOWN") then
    return C.fail("FLY did not reach Lavender; at " .. tostring(C.map()))
  end
  U.wait(30)

  local Spawn = require("mods.battle_royale.lib.spawn")
  local roster = E.bots() or {}
  if #roster < 2 then return C.fail("expected two bots, got " .. #roster) end
  local one, two = roster[1], roster[2]
  local function botById(id)
    for _, b in ipairs(E.bots() or {}) do
      if b.id == id then return b end
    end
    return nil
  end

  -- act 1: two adjacent cells on ROUTE_1
  local ARENA = "ROUTE_1"
  local pair
  local cells = Spawn.pickIn(game.data.maps, game.data.tilesets, ARENA, 40,
                             Spawn.rng(11)) or {}
  for _, c in ipairs(cells) do
    if Spawn.walkable(game.data.maps, game.data.tilesets, ARENA,
                      c.x + 1, c.y) then
      pair = { a = c, b = { x = c.x + 1, y = c.y } }
      break
    end
  end
  if not pair then return C.fail("no adjacent pair on " .. ARENA) end

  local fought = false
  for i = 1, 120 do
    local a, b = botById(one.id), botById(two.id)
    if not (a and b) then return C.fail("lost a bot before the fight") end
    if a.status == "out" or b.status == "out" then fought = true break end
    E.debugPlaceBot(one.id, ARENA, pair.a.x, pair.a.y)
    E.debugPlaceBot(two.id, ARENA, pair.b.x, pair.b.y)
    U.wait(15)
    if i % 20 == 0 then
      local pr = E.debugFightProbe() or {}
      local rows = {}
      for _, r in ipairs(pr.bots or {}) do
        rows[#rows + 1] = ("%s %s %s %s,%s cool=%.1f"):format(
          tostring(r.id), tostring(r.status), tostring(r.map),
          tostring(r.x), tostring(r.y), r.sinceFight or -1)
      end
      U.log(("SURVIVOR: staging %d -- host=%s phase=%s | %s | err %s")
        :format(i, tostring(pr.host), tostring(pr.phase),
                table.concat(rows, " / "), tostring(E.tickError())))
    end
  end
  if not fought then return C.fail("adjacent for a minute and no fight") end
  local winner = (botById(one.id).status == "alive") and one or two
  local rec = E.botRecord(winner.id)
  if not rec then return C.fail("the winner has no record") end
  local hurt = false
  for _, m in ipairs(rec) do
    if (m.hpFrac or 1) < 1 then hurt = true break end
  end
  if not hurt then
    return C.fail("the fight cost the winner nothing -- the coin is back")
  end
  U.log(("SURVIVOR: %s won and its lead is at %d%%"):format(
    tostring(winner.name), math.floor((rec[1].hpFrac or 1) * 100)))

  -- act 2: the loser's spill is at the fight cell; the winner should
  -- walk over and pocket a ball.  Keep it near the arena; at two-alive
  -- the roam clock is 8s, so it map-hops -- plant it back.
  local before = #rec
  local grown
  for i = 1, 240 do
    U.wait(30)
    local b = botById(winner.id)
    if not b or b.status ~= "alive" then return C.fail("the winner died looting") end
    if b.map ~= ARENA then
      E.debugPlaceBot(winner.id, ARENA, pair.a.x, pair.a.y)
    end
    local now = E.botRecord(winner.id)
    if now and #now > before then grown = now break end
    if i % 60 == 0 then
      local S = E.spillState() or {}
      local nb, where = 0, ""
      for _, ball in pairs(S.balls or {}) do
        if ball.map == ARENA then
          nb = nb + 1
          where = where .. " " .. ball.x .. "," .. ball.y
        end
      end
      local pos = botById(winner.id)
      U.log(("SURVIVOR: still looting (%ds, %d mons; %d balls at%s; bot %s,%s; err %s)")
        :format(math.floor(i / 2), now and #now or 0, nb, where,
                tostring(pos and pos.x), tostring(pos and pos.y),
                tostring(E.tickError())))
    end
  end
  if not grown then
    return C.fail("two minutes beside the spill and it looted nothing")
  end
  U.log(("SURVIVOR: looted up to %d mons"):format(#grown))

  -- act 3: wound it and put it by Pewter's Centre
  if not E.debugScarBot(winner.id, 0.2) then
    return C.fail("could not scar the winner")
  end
  local DOOR = { x = 14, y = 26 }   -- beside the PEWTER_POKECENTER door
  local healed
  for i = 1, 240 do
    local b = botById(winner.id)
    if not b or b.status ~= "alive" then return C.fail("the winner died healing") end
    if b.map ~= "PEWTER_CITY" then
      E.debugPlaceBot(winner.id, "PEWTER_CITY", DOOR.x, DOOR.y)
    end
    U.wait(30)
    local now = E.botRecord(winner.id)
    local whole = now and #now > 0
    for _, m in ipairs(now or {}) do
      if (m.hpFrac or 0) < 1 then whole = false break end
    end
    if whole then healed = true break end
    if i % 60 == 0 then
      U.log(("SURVIVOR: still waiting on the nurse (%ds)"):format(
        math.floor(i / 2)))
    end
  end
  if not healed then
    return C.fail("two minutes at the Centre door and it never healed")
  end
  U.log("SURVIVOR OK: fought at a price, looted the fallen, healed at the Centre")
  love.event.quit(0)
  U.wait(30)
end
