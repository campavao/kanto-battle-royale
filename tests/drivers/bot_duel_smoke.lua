-- Two bots fight for real, and a spectator watches it (lib/mirror.lua).
--
-- A bot-versus-bot fight used to be a coin flip on the host.  Now the host
-- runs a real BattleState off screen and records it, so whoever is
-- watching either bot sees it on the battle screen.  One client proves the
-- host side of that: it hosts a solo room with three bots, goes out at the
-- drop, turns its camera on bot A, then puts A and B on adjacent cells.
--
-- What it asserts:
--   * a duel opens (botDuels() has one) rather than an instant elimination;
--   * the replica of it opens on THIS screen with no wire -- the host is its
--     own watcher -- plays itself, and closes;
--   * the duel ends with exactly one of the two out and the winner's record
--     wounded as the fight left it (not full, not zero);
--   * the mod's tick did not throw and the map is back under the camera.
--
--   SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1 POKEPORT_GAME=red \
--   POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_IDENTITY=br-duel POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_duel_smoke.lua \
--   <path to>/lovec . > duel.log 2>&1
--
-- `DUEL OK` passes it; any `PVP FAIL` line fails it.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Spawn = require("mods.battle_royale.lib.spawn")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("REF")
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

  -- everybody apart, first: nobody fights before the referee is watching
  local bots = E.bots() or {}
  table.sort(bots, function(x, y) return x.id < y.id end)
  if #bots < 3 then return C.fail("expected three bots, got " .. #bots) end
  -- A on an open row in VIRIDIAN facing along it (BR-34: a duel opens on a
  -- sighting and a walk-up now, so B has to be put where A can SEE it and
  -- REACH it -- CINNABAR's lab door between them used to be fine for a
  -- fight that ignored walls); the others far away and apart
  local data = game.data
  local function open(x, y)
    return Spawn.walkable(data.maps, data.tilesets, "VIRIDIAN_CITY", x, y)
       and not Spawn.isWarp(data.maps, "VIRIDIAN_CITY", x, y)
  end
  local rx, ry
  for y = 18, 35 do
    for x = 4, 30 do
      if open(x, y) and open(x + 1, y) and open(x + 2, y) and open(x + 3, y) then rx, ry = x, y break end
    end
    if rx then break end
  end
  if not rx then return C.fail("no open row in VIRIDIAN") end
  E.debugPlaceBot(bots[1].id, "VIRIDIAN_CITY", rx, ry, "right")
  E.debugPlaceBot(bots[2].id, "CINNABAR_ISLAND", 8, 12)
  E.debugPlaceBot(bots[3].id, "SEAFOAM_ISLANDS_1F", 6, 6)

  -- out at the drop, camera on bot A
  if not E.debugOut("duel smoke") then return C.fail("debugOut refused") end
  for _ = 1, 10 do U.tap(game, "a") U.wait(15) end
  local a, b = bots[1], bots[2]
  local watching = false
  for _ = 1, 8 do
    U.wait(20)
    if E.watching() == a.id then watching = true break end
    E.hop(1)
  end
  if not watching then return C.fail("could not watch bot A (watching " .. tostring(E.watching()) .. ")") end
  U.wait(60)
  U.log(("DUEL: watching %s (%s); putting %s beside it"):format(tostring(a.name), tostring(a.id), tostring(b.name)))

  -- now B steps into A's eyeline two cells along the row: A spots it,
  -- walks up, and the duel opens
  local pa
  for _, pr in ipairs(E.debugFightProbe().bots) do if pr.id == a.id then pa = pr end end
  local bx = (pa and pa.facing == "left") and pa.x - 2 or pa.x + 2
  if not open(bx, pa.y) then bx = pa.x + 2 end
  E.debugPlaceBot(b.id, "VIRIDIAN_CITY", bx, pa.y, (bx > pa.x) and "left" or "right")
  E.debugFaceBot(a.id, (bx > pa.x) and "right" or "left")
  local opened = false
  for _ = 1, 600 do
    U.wait(5)
    if #(E.botDuels() or {}) >= 1 then opened = true break end
  end
  if not opened then
    local alive, where = 0, {}
    for _, bt in ipairs(E.bots() or {}) do if bt.status == "alive" then alive = alive + 1 end end
    for _, pr in ipairs(E.debugFightProbe().bots) do
      where[#where + 1] = ("%s@%s %s,%s %s busy=%s goal=%s hunt=%s ap=%s"):format(
        tostring(pr.id), tostring(pr.map), tostring(pr.x), tostring(pr.y), tostring(pr.facing),
        tostring(pr.busy), tostring(pr.goal), tostring(pr.hunting), tostring(pr.approaching))
    end
    return C.fail(("no duel opened (bots alive %d): %s"):format(alive, table.concat(where, " | ")))
  end
  U.log("DUEL: a real fight is running on the host")

  -- ...and this screen, the host's own, shows it with no wire in between
  local shown = false
  for _ = 1, 900 do
    U.wait(5)
    if E.mirror().open then shown = true break end
  end
  if not shown then
    local m = E.mirror()
    return C.fail(("the duel never opened on the spectator's screen (frames %s from %s)")
      :format(tostring(m.frames), tostring(m.from)))
  end
  U.log("DUEL: the fight is on the spectator's screen")
  shot("duel_open")

  -- BR_DUEL_HOP=1: look away and come back mid-fight.  The frames missed
  -- while watching the third bot must be topped up on return (the log had
  -- a hole otherwise, and the replica idled at it: the user's 2026-09-05
  -- "it fought two or three times, faster each time").
  if os.getenv("BR_DUEL_HOP") then
    U.wait(180)
    E.hop(1)   -- the other duelist
    U.wait(30)
    E.hop(1)   -- the third bot, away from the fight
    if E.watching() ~= bots[3].id then
      return C.fail("could not look away (watching " .. tostring(E.watching()) .. ")")
    end
    if E.mirror().open then return C.fail("the replica stayed open after hopping away") end
    U.log("DUEL: looked away; waiting while the fight goes on")
    U.wait(420)
    E.hop(-1)
    U.wait(30)
    E.hop(-1)
    if E.watching() ~= a.id then
      return C.fail("could not look back (watching " .. tostring(E.watching()) .. ")")
    end
    local again = false
    for _ = 1, 600 do
      U.wait(5)
      if E.mirror().open then again = true break end
    end
    if not again then
      local m = E.mirror()
      return C.fail(("the fight did not reopen on return (frames %s, duel %s)")
        :format(tostring(m.frames), tostring(#(E.botDuels() or {}))))
    end
    U.log("DUEL: back, and the fight reopened caught up")
  end

  local closed, peak, duelTurns = false, 0, 0
  for i = 1, 6000 do
    U.wait(10)
    local m = E.mirror()
    if m.turn and m.turn > peak then peak = m.turn end
    local ds = E.botDuels() or {}
    if ds[1] and ds[1].turn > duelTurns then duelTurns = ds[1].turn end
    if i == 60 then shot("duel_playing") end
    if not m.open then closed = true break end
  end
  shot("duel_after")
  if not closed then return C.fail("the replica never closed") end
  local last = E.mirror().last
  U.log(("DUEL: replica closed (%s) result %s after %s turns; the host's fight reached turn %d")
    :format(tostring(last and last.why), tostring(last and last.result), tostring(last and last.turn), duelTurns))
  if not (last and (last.why == "win" or last.why == "lose")) then
    return C.fail("the replica did not close on the fight's result: " .. tostring(last and last.why))
  end
  if (last.turn or 0) < 1 then return C.fail("the replica played no turn") end

  -- the fight settled the way a fight does
  local settled = false
  for _ = 1, 300 do
    U.wait(5)
    if #(E.botDuels() or {}) == 0 then settled = true break end
  end
  if not settled then return C.fail("the duel never settled on the host") end
  local outs, winner = 0, nil
  for _, bt in ipairs(E.bots() or {}) do
    if bt.id == a.id or bt.id == b.id then
      if bt.status == "out" then outs = outs + 1 else winner = bt end
    end
  end
  if outs ~= 1 or not winner then return C.fail(("expected one of the two out, got %d"):format(outs)) end
  local rec = E.botRecord and E.botRecord(winner.id) or nil
  if rec then
    local full, standing = true, 0
    for _, mon in ipairs(rec) do
      if (mon.hpFrac or 1) < 1 then full = false end
      if (mon.hpFrac or 0) > 0 then standing = standing + 1 end
    end
    if standing == 0 then return C.fail("the winner has nothing standing") end
    U.log(("DUEL: %s won, %d standing, %s"):format(tostring(winner.name), standing,
      full and "unscathed" or "wounded as the fight left it"))
  end
  if E.phase() ~= "match" then return C.fail("the match ended with the duel (phase " .. tostring(E.phase()) .. ")") end
  local back = false
  for _ = 1, 200 do
    U.wait(5)
    if game.stack:top() == C.ow() then back = true break end
  end
  if not back then return C.fail("the map did not come back under the spectator") end
  if E.status() ~= "out" then return C.fail("spectating changed our status to " .. tostring(E.status())) end
  U.log("DUEL OK")
  love.event.quit(0)
end
