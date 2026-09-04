-- POK-174: the bots do not queue up on the player.
--
-- Three bots on Pewter's street with the player.  The player fights bot
-- A (the eyeline).  While that fight is on, B and C -- who used to pick A
-- as the nearest trainer and park beside the fight -- must fight EACH
-- OTHER (an OUT line naming a bot as the beater, with the player still in
-- the battle).  When the player's fight ends, nothing may engage them for
-- Bots.BREATHER seconds even with the survivor standing next to them; and
-- once the breather is over, facing that survivor starts the next fight.
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-gangup POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/gangup_smoke.lua \
--   <path to>/lovec . > gangup.log 2>&1
--
-- Exit 0 with a `GANGUP OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")

return function(game)
  local C = L.ctx(game)
  local function wall() return love.timer.getTime() end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SCOUT")
  E.setSafari(0)
  E.setFog(600)
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
  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")

  local function battleTop()
    local top = game.stack:top()
    return type(top) == "table" and top.enemyParty and top or nil
  end
  local function aliveBots()
    local n = 0
    for _, p in ipairs(E.players() or {}) do if p.status == "alive" then n = n + 1 end end
    return n
  end

  -- the street: A two cells right of the player; B and C far apart on
  -- the same map, out of every eyeline, so the only way they meet is by
  -- stalking each other while we are busy
  U.teleport(game, "PEWTER_CITY", 12, 18, "right")
  U.wait(30)
  local ps = E.players() or {}
  if #ps < 3 then return C.fail("expected three bots, got " .. #ps) end
  table.sort(ps, function(a, b) return a.id < b.id end)
  local A, B, Cb = ps[1].id, ps[2].id, ps[3].id
  E.debugPlaceBot(A, "PEWTER_CITY", 14, 18)
  E.debugPlaceBot(B, "PEWTER_CITY", 9, 19)
  E.debugPlaceBot(Cb, "PEWTER_CITY", 16, 26)
  U.wait(30)
  U.hold(game, "right", 4)
  local t0 = wall()
  while (wall() - t0) < 40 and not battleTop() do U.wait(1) end
  if not battleTop() then return C.fail("the first fight never opened") end
  local function othersAlive()
    local n = 0
    for _, p in ipairs(E.players() or {}) do
      if p.status == "alive" and p.id ~= A then n = n + 1 end
    end
    return n
  end
  if othersAlive() < 2 then
    return C.fail("staging: the other two resolved before our fight opened")
  end
  U.log(("GANGUP: fighting %s; the other two are both alive"):format(tostring(ps[1].name)))

  -- ------- 1. while we fight, the other two fight each other.  We STALL
  -- at the move menu (a bot fight has no shot clock) so the fight is
  -- still on when they meet.
  local resolved = false
  t0 = wall()
  while battleTop() and (wall() - t0) < 90 do
    if othersAlive() < 2 then resolved = true break end
    local b = battleTop()
    if b and b.phase ~= "menu" then U.tap(game, "b") end
    U.wait(5)
  end
  if not resolved then
    return C.fail(("the two idle bots never fought each other while we were busy (%d alive)")
      :format(othersAlive()))
  end
  U.log("GANGUP: a bot-vs-bot fight resolved while our fight was still on")
  -- now finish ours
  t0 = wall()
  while battleTop() and (wall() - t0) < 120 do
    U.tap(game, "a")
    U.wait(3)
  end
  if battleTop() then return C.fail("our fight never ended") end
  t0 = wall()
  while (wall() - t0) < 20 and game.stack:top() ~= C.ow() do
    U.tap(game, "a")
    U.wait(3)
  end
  local ended = wall()
  U.log(("GANGUP: our fight is over; status %s, %d other bot(s) alive"):format(
    tostring(E.status()), othersAlive()))
  if E.status() ~= "alive" then return C.fail("we lost the first fight; cannot test the breather") end

  -- ------- 2. the breather: the survivor stands next to us; nothing fires.
  -- Re-placed every second: a bot with no prey walks a seam on its roam
  -- clock, which is the point of the breather, not what this measures.
  local survivor
  for _, p in ipairs(E.players() or {}) do if p.status == "alive" then survivor = p.id end end
  if not survivor then return C.fail("no survivor left to test the breather with") end
  local function park()
    E.debugPlaceBot(survivor, "PEWTER_CITY", C.x() + 2, C.y())
  end
  park()
  U.hold(game, "right", 4)   -- face it: the eyeline would fire outside a breather
  local lastPark = wall()
  while (wall() - ended) < (Bots.BREATHER - 1) do
    if battleTop() or E.status() == "battle" or E.pending() then
      return C.fail(("a fight started %.1fs after the last one ended"):format(wall() - ended))
    end
    if (wall() - lastPark) >= 1 then park() lastPark = wall() end
    U.wait(1)
  end
  U.log(("GANGUP: nothing engaged for %.1fs after the fight"):format(wall() - ended))

  -- ------- 3. ...and the breather ends: the eyeline fires again
  while (wall() - ended) < (Bots.BREATHER + 1) do
    if (wall() - lastPark) >= 1 then park() lastPark = wall() end
    U.wait(1)
  end
  park()
  U.wait(20)
  U.hold(game, "left", 2)
  U.hold(game, "right", 4)
  t0 = wall()
  while (wall() - t0) < 30 and not (battleTop() or E.pending()) do
    if (wall() - lastPark) >= 2 and not E.pending() then park() lastPark = wall() end
    U.wait(1)
  end
  if not (battleTop() or E.pending()) then
    return C.fail("no fight after the breather with a bot in the eyeline")
  end
  U.log("GANGUP OK: bots fought each other, the breather held, and the eyeline came back")
  love.event.quit(0)
  U.wait(10)
end
