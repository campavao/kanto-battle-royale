-- A bot moves the way a player moves, watched from outside (BR-32..35).
--
-- Four legs, each staged with debugPlaceBot in a solo room the referee is
-- spectating, so every assertion is what a spectator's camera would see:
--
--   seam    a bot leaves ROUTE_1 by WALKING to its edge and lands on the
--           neighbour's edge (BR-32) -- no in-map jump ever exceeds one
--           cell, the crossing counts as a seam walked, and the camera
--           follows it across;
--   centre  a wounded bot in VIRIDIAN walks to the Centre door, goes IN
--           (its map is the interior), heals at the counter, and comes
--           back out onto the door facing down (BR-35) -- the spectator
--           stands in the Centre while it heals;
--   walkup  two bots four cells apart on a row: the one facing the other
--           spots it, walks up until adjacent, both face, and only then
--           does a duel open (BR-34);
--   surf    a bot with a SURF learner standing on PALLET's sea is drawn on
--           the surf sheet, and on the walk sheet ashore (BR-33);
--   endgame the last two, both with a wrecked lead and no Centre on their
--           route, walk at each other and fight rather than pacing until
--           the fog decides it (BR-29);
--   fly     a wrecked bot with a FLY learner, an empty bag and no Centre
--           on its route flies to the nearest Centre town in one hop, on
--           the engine's own fly landing (BR-30).
--
-- BR_LEG=seam|centre|walkup|surf|fly|endgame runs one; unset runs all six
-- (endgame last: its duel can crown a winner and end the match).
--
--   SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1 POKEPORT_GAME=red \
--   POKEPORT_IMPORT_ROM=<rom.gb> POKEPORT_IDENTITY=br-legs POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_legs_smoke.lua \
--   <path to>/lovec . > legs.log 2>&1
--
-- `LEGS OK` passes it; any `PVP FAIL` line fails it.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Spawn = require("mods.battle_royale.lib.spawn")

-- two cells apart, or the banished pair spot each other and fight
local FAR = { { map = "CINNABAR_ISLAND", x = 8, y = 12 },
              { map = "SEAFOAM_ISLANDS_1F", x = 6, y = 6 } }

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end
  local only = os.getenv("BR_LEG")

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

  local bots = E.bots() or {}
  table.sort(bots, function(x, y) return x.id < y.id end)
  if #bots < 3 then return C.fail("expected three bots, got " .. #bots) end
  local A, B, Z = bots[1], bots[2], bots[3]
  local data = game.data

  local function botAt(id)
    for _, b in ipairs(E.bots() or {}) do if b.id == id then return b end end
  end
  local function probe(id)
    for _, b in ipairs(E.debugFightProbe().bots) do if b.id == id then return b end end
  end
  local function banish(...)
    for i, b in ipairs({ ... }) do
      local f = FAR[(i - 1) % #FAR + 1]
      E.debugPlaceBot(b.id, f.map, f.x, f.y)
    end
  end
  local function alive(id)
    local b = botAt(id)
    return b and b.status == "alive"
  end
  -- a bot that is alive and not in a duel: a duel at a person's pace can
  -- outlast a leg, and a duelist stands frozen for all of it
  local function freeBot()
    local busy = {}
    for _, d in ipairs(E.botDuels() or {}) do busy[d.a], busy[d.b] = true, true end
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" and not busy[b.id] then return b end
    end
    return nil
  end
  local function walkable(map, x, y)
    return Spawn.walkable(data.maps, data.tilesets, map, x, y)
       and not Spawn.isWarp(data.maps, map, x, y)
  end
  -- the first cell of an open ROW of `n` walkable cells, scanned down
  -- from (x0, y0); nil if the map has none nearby
  local function openRow(map, x0, y0, n)
    local def = data.maps[map]
    for y = y0, def.height * 2 - 1 do
      for x = x0, def.width * 2 - n do
        local all = true
        for i = 0, n - 1 do if not walkable(map, x + i, y) then all = false break end end
        if all then return x, y end
      end
    end
  end

  -- out at the drop, camera on A
  if not E.debugOut("legs smoke") then return C.fail("debugOut refused") end
  for _ = 1, 10 do U.tap(game, "a") U.wait(15) end
  local function watch(id)
    for _ = 1, 8 do
      if E.watching() == id then return true end
      E.hop(1)
      U.wait(20)
    end
    return false
  end
  if not watch(A.id) then return C.fail("could not watch bot A (" .. tostring(E.watching()) .. ")") end

  local function leg(name) return not only or only == name end

  -- ------------------------------------------------------------ seam
  if leg("seam") then
    banish(B, Z)
    -- the middle of ROUTE_1: both seams are a walk away
    local sx, sy = openRow("ROUTE_1", 6, 16, 1)
    if not sx then return C.fail("no cell on ROUTE_1") end
    E.debugPlaceBot(A.id, "ROUTE_1", sx, sy)
    U.wait(30)
    U.log(("SEAM: %s placed on ROUTE_1 %d,%d; waiting for it to leave"):format(A.name, sx, sy))
    local last, jumped, crossed = nil, nil, nil
    for _ = 1, 3000 do
      U.wait(3)
      local b = botAt(A.id)
      if b and b.map and last then
        if b.map == last.map then
          local d = math.abs(b.x - last.x) + math.abs(b.y - last.y)
          if d > 1 then jumped = ("%s %d,%d -> %d,%d"):format(b.map, last.x, last.y, b.x, b.y) end
        else
          crossed = { from = last, to = b }
        end
      end
      last = b
      if crossed or jumped then break end
    end
    if jumped then return C.fail("the bot jumped inside a map: " .. jumped) end
    if not crossed then return C.fail("the bot never left ROUTE_1 (at " .. tostring(last and last.x) .. "," .. tostring(last and last.y) .. ")") end
    local f, t = crossed.from, crossed.to
    local def = data.maps.ROUTE_1
    local onEdge = f.map == "ROUTE_1" and (f.y == 0 or f.y == def.height * 2 - 1
                                            or f.x == 0 or f.x == def.width * 2 - 1)
    if not onEdge then
      return C.fail(("left ROUTE_1 from %d,%d, not an edge cell"):format(f.x, f.y))
    end
    local ddef = data.maps[t.map]
    local landed = ddef and (t.y == 0 or t.y == ddef.height * 2 - 1
                             or t.x == 0 or t.x == ddef.width * 2 - 1)
    if not landed then
      return C.fail(("landed on %s %d,%d, not its edge"):format(tostring(t.map), t.x, t.y))
    end
    local pr = probe(A.id)
    if not (pr and pr.seams >= 1) then return C.fail("the crossing was not counted as a seam walked") end
    U.log(("SEAM: %s walked off ROUTE_1 at %d,%d and onto %s at %d,%d"):format(A.name, f.x, f.y, t.map, t.x, t.y))
    -- ...and the camera follows it across
    local followed = false
    for _ = 1, 400 do
      U.wait(5)
      if C.map() == t.map then followed = true break end
    end
    if not followed then return C.fail("the spectator did not follow across (on " .. tostring(C.map()) .. ")") end
    shot("seam_after")
    U.log("SEAM: the spectator followed it onto " .. t.map)
  end

  -- ------------------------------------------------------------ centre
  if leg("centre") then
    banish(B, Z)
    -- a cell a few rows below the VIRIDIAN Centre door (23,25)
    local cx, cy = openRow("VIRIDIAN_CITY", 20, 29, 1)
    if not cx then return C.fail("no cell below VIRIDIAN's Centre") end
    E.debugPlaceBot(A.id, "VIRIDIAN_CITY", cx, cy)
    E.debugScarBot(A.id, 0.2)
    U.wait(30)
    U.log(("CENTRE: %s wounded and placed at VIRIDIAN %d,%d"):format(A.name, cx, cy))
    local inside, atCounter, healed, out, watcherIn = false, false, false, nil, false
    local last
    for _ = 1, 4000 do
      U.wait(3)
      local b = botAt(A.id)
      if b and b.map == "VIRIDIAN_POKECENTER" then
        inside = true
        if b.x == 3 and b.y == 3 then atCounter = true end
        if C.map() == "VIRIDIAN_POKECENTER" then watcherIn = true end
        local rec = E.botRecord(A.id) or {}
        local full = #rec > 0
        for _, m in ipairs(rec) do if (m.hpFrac or 0) < 1 then full = false end end
        if full then healed = true end
      elseif inside and b and b.map == "VIRIDIAN_CITY" then
        out = b
        break
      end
      if b and last and b.map == last.map and b.map == "VIRIDIAN_CITY"
         and (math.abs(b.x - last.x) + math.abs(b.y - last.y)) > 1 then
        return C.fail(("the bot jumped in VIRIDIAN: %d,%d -> %d,%d"):format(last.x, last.y, b.x, b.y))
      end
      last = b
    end
    if not inside then
      local pr = probe(A.id)
      return C.fail(("the bot never went into the Centre (goal %s at %s, map %s %s,%s)"):format(
        tostring(pr and pr.goal), pr and pr.goalAt and (pr.goalAt.x .. "," .. pr.goalAt.y) or "?",
        tostring(pr and pr.map), tostring(pr and pr.x), tostring(pr and pr.y)))
    end
    if not atCounter then return C.fail("the bot never stood at the counter") end
    if not healed then return C.fail("the team was not healed inside") end
    if not watcherIn then return C.fail("the spectator never stood in the Centre (on " .. tostring(C.map()) .. ")") end
    if not out then return C.fail("the bot never came back out") end
    if not (out.x == 23 and out.y == 25) then
      return C.fail(("came out at %d,%d, not on the door"):format(out.x, out.y))
    end
    local pr = probe(A.id)
    if pr.facing ~= "down" then return C.fail("came out facing " .. tostring(pr.facing)) end
    shot("centre_out")
    U.log(("CENTRE: %s went in, healed at the counter, and came out on the door facing down"):format(A.name))
  end

  -- ------------------------------------------------------------ walkup
  if leg("walkup") then
    if not (alive(A.id) and alive(B.id)) then return C.fail("a bot fell before the walk-up leg") end
    banish(Z)
    local rx, ry = openRow("VIRIDIAN_CITY", 4, 18, 7)
    if not rx then return C.fail("no open row in VIRIDIAN") end
    E.debugPlaceBot(A.id, "VIRIDIAN_CITY", rx, ry, "right")
    E.debugPlaceBot(B.id, "VIRIDIAN_CITY", rx + 4, ry, "left")
    U.wait(2)
    U.log(("WALKUP: %s at %d,%d facing right, %s four cells right of it"):format(A.name, rx, ry, B.name))
    local spotted, seer, seen
    local trace = {}
    for i = 1, 200 do
      U.wait(2)
      local aps = E.botApproaches() or {}
      local a, b = botAt(A.id), botAt(B.id)
      trace[#trace + 1] = ("%d:%d,%d/%d,%d ap%d d%d"):format(i, a.x, a.y, b.x, b.y, #aps, #(E.botDuels() or {}))
      if aps[1] then spotted = aps[1] break end
      if #(E.botDuels() or {}) > 0 then
        return C.fail("a duel opened before anybody walked up: " .. table.concat(trace, " "))
      end
    end
    if not spotted then return C.fail("nobody spotted anybody") end
    seer, seen = spotted.seer, spotted.to
    local seerBot, seenBot = botAt(seer), botAt(seen)
    U.log(("WALKUP: %s spotted %s"):format(seerBot.name, seenBot.name))
    local seenStart = { x = seenBot.x, y = seenBot.y }
    local dueled = false
    for _ = 1, 1500 do
      U.wait(3)
      local s = botAt(seen)
      if s.x ~= seenStart.x or s.y ~= seenStart.y then
        return C.fail("the one seen moved while being walked up to")
      end
      if #(E.botDuels() or {}) > 0 then dueled = true break end
    end
    if not dueled then
      local pa, pb = probe(seer), probe(seen)
      return C.fail(("no duel opened; seer at %s,%s facing %s, seen at %s,%s"):format(
        tostring(pa.x), tostring(pa.y), tostring(pa.facing), tostring(pb.x), tostring(pb.y)))
    end
    local a, b = botAt(seer), botAt(seen)
    if math.abs(a.x - b.x) + math.abs(a.y - b.y) ~= 1 then
      return C.fail(("the duel opened at distance %d, not adjacent"):format(math.abs(a.x - b.x) + math.abs(a.y - b.y)))
    end
    local pa, pb = probe(seer), probe(seen)
    local want = a.x < b.x and "right" or "left"
    if pa.facing ~= want then return C.fail("the seer is not facing its opponent (" .. tostring(pa.facing) .. ")") end
    if pb.facing ~= (want == "right" and "left" or "right") then
      return C.fail("the one seen is not facing back (" .. tostring(pb.facing) .. ")")
    end
    if not (pa.busy == "battle" and pb.busy == "battle") then
      return C.fail("the fighting marks are not up")
    end
    shot("walkup_duel")
    U.log(("WALKUP: %s walked up to %s; they face each other and the duel is open"):format(a.name, b.name))
    U.log("WALKUP: the duel runs on; the next legs use a bot that is not in it")
  end

  -- ------------------------------------------------------------ surf
  if leg("surf") then
    -- A may have fallen in the duel: the surfer is whichever is standing
    local swimmer = freeBot()
    if not swimmer then return C.fail("no free bot left to swim") end
    if not watch(swimmer.id) then return C.fail("could not watch the swimmer") end
    local others = {}
    for _, b in ipairs(E.bots() or {}) do
      if b.id ~= swimmer.id then others[#others + 1] = b end
    end
    banish(unpack(others))
    E.debugBotMon(swimmer.id, "LAPRAS")
    -- a sea cell on PALLET's south shore
    local wx, wy
    local def = data.maps.PALLET_TOWN
    for y = def.height * 2 - 1, 0, -1 do
      for x = 0, def.width * 2 - 1 do
        if Spawn.swimmable(data.maps, data.tilesets, "PALLET_TOWN", x, y) then wx, wy = x, y break end
      end
      if wx then break end
    end
    if not wx then return C.fail("no water in PALLET") end
    E.debugPlaceBot(swimmer.id, "PALLET_TOWN", wx, wy)
    local sheet
    for _ = 1, 300 do
      U.wait(5)
      if C.map() == "PALLET_TOWN" then
        sheet = E.ghostSheet(swimmer.id)
        if sheet == "surf" then break end
      end
    end
    if sheet ~= "surf" then return C.fail("a bot on the sea is drawn on " .. tostring(sheet)) end
    shot("surf_on")
    U.log(("SURF: %s on PALLET's sea at %d,%d is drawn on the surf sheet"):format(swimmer.name, wx, wy))
    local lx, ly = openRow("PALLET_TOWN", 4, 4, 1)
    E.debugPlaceBot(swimmer.id, "PALLET_TOWN", lx, ly)
    for _ = 1, 300 do
      U.wait(5)
      sheet = E.ghostSheet(swimmer.id)
      if sheet == "walk" then break end
    end
    if sheet ~= "walk" then return C.fail("a bot ashore is drawn on " .. tostring(sheet)) end
    U.log("SURF: and on the walk sheet ashore")
  end

  -- ------------------------------------------------------------ fly
  if leg("fly") then
    local flier = freeBot()
    if not flier then return C.fail("no free bot left to fly") end
    if not watch(flier.id) then return C.fail("could not watch the flier") end
    local others = {}
    for _, b in ipairs(E.bots() or {}) do
      if b.id ~= flier.id then others[#others + 1] = b end
    end
    banish(unpack(others))
    -- heal it first so the scar is the whole story, then a FLY learner,
    -- an empty bag, a lead at a sliver, and a route with no Centre
    E.debugScarBot(flier.id, 1)
    E.debugBotMon(flier.id, "PIDGEOT")
    E.debugBotBag(flier.id, {}, 0)
    local fx, fy = openRow("ROUTE_1", 6, 16, 1)
    local before = probe(flier.id)
    local seams0, flights0 = before.seams or 0, before.flights or 0
    E.debugPlaceBot(flier.id, "ROUTE_1", fx, fy)
    E.debugScarBot(flier.id, 0.3)
    U.log(("FLY: %s wounded on ROUTE_1 %d,%d with PIDGEOT and no potion"):format(flier.name, fx, fy))
    local landed, last
    for _ = 1, 3000 do
      U.wait(3)
      local b = botAt(flier.id)
      if b.map ~= "ROUTE_1" then landed = { from = last, to = b } break end
      last = b
    end
    if not landed then
      local pr = probe(flier.id)
      return C.fail(("the bot never flew (goal %s at %s,%s, flights %s)"):format(
        tostring(pr.goal), tostring(pr.x), tostring(pr.y), tostring(pr.flights)))
    end
    local spot = data.field.flyWarps[landed.to.map]
    if not spot then return C.fail("landed on " .. tostring(landed.to.map) .. ", not a fly town") end
    -- the landing is the Centre's doorstep, so a wounded bot may already
    -- have taken its first step up onto the door by the sample
    if math.abs(landed.to.x - spot.x) + math.abs(landed.to.y - spot.y) > 1 then
      return C.fail(("landed at %d,%d, not the fly landing %d,%d"):format(landed.to.x, landed.to.y, spot.x, spot.y))
    end
    if landed.to.map ~= "VIRIDIAN_CITY" then
      return C.fail("flew to " .. landed.to.map .. ", not the nearest Centre town")
    end
    local pr = probe(flier.id)
    if (pr.flights or 0) ~= flights0 + 1 then return C.fail("the hop was not counted as a flight") end
    if (pr.seams or 0) ~= seams0 then return C.fail("the bot walked a seam instead of flying") end
    shot("fly_landed")
    U.log(("FLY: %s flew from ROUTE_1 to %s and landed before its Centre"):format(flier.name, landed.to.map))
  end

  -- ------------------------------------------------------------ endgame
  if leg("endgame") then
    -- the walk-up's duel has to be over first: it can run minutes
    local t0 = love.timer.getTime()
    while #(E.botDuels() or {}) > 0 and love.timer.getTime() - t0 < 480 do U.wait(10) end
    if #(E.botDuels() or {}) > 0 then return C.fail("the walk-up's duel never settled") end
    local standing = {}
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" then standing[#standing + 1] = b end
    end
    if #standing < 2 then return C.fail("fewer than two bots left for the endgame leg") end
    local P, Q = standing[1], standing[2]
    for i = 3, #standing do banish(standing[i]) end
    if not watch(P.id) then return C.fail("could not watch the endgame pair") end
    -- opposite ends of ROUTE_1, no Centre on it, each with a lead at a
    -- sliver: the old wantsHeal gate kept both from ever stalking
    local px, py = openRow("ROUTE_1", 6, 2, 1)
    local qx, qy = openRow("ROUTE_1", 6, 30, 1)
    E.debugPlaceBot(P.id, "ROUTE_1", px, py)
    E.debugPlaceBot(Q.id, "ROUTE_1", qx, qy)
    E.debugScarBot(P.id, 0.3)
    E.debugScarBot(Q.id, 0.3)
    U.log(("ENDGAME: %s at ROUTE_1 %d,%d and %s at %d,%d, both wounded, %d alive"):format(
      P.name, px, py, Q.name, qx, qy, E.aliveCount() or -1))
    local met, left = false, nil
    for _ = 1, 4000 do
      U.wait(3)
      local a, b = botAt(P.id), botAt(Q.id)
      if a.map ~= "ROUTE_1" or b.map ~= "ROUTE_1" then left = a.map ~= "ROUTE_1" and a or b break end
      if #(E.botApproaches() or {}) > 0 or #(E.botDuels() or {}) > 0 then met = true break end
    end
    if left then return C.fail(("%s left the route instead of hunting"):format(left.name)) end
    if not met then
      local pa, pb = probe(P.id), probe(Q.id)
      return C.fail(("the last two never met: %s at %s,%s goal %s hunting %s; %s at %s,%s goal %s hunting %s"):format(
        P.name, tostring(pa.x), tostring(pa.y), tostring(pa.goal), tostring(pa.hunting),
        Q.name, tostring(pb.x), tostring(pb.y), tostring(pb.goal), tostring(pb.hunting)))
    end
    shot("endgame_met")
    U.log("ENDGAME: the last two walked at each other and met")
  end

  local err = E.tickError and E.tickError()
  if err then return C.fail("the mod's tick threw: " .. tostring(err)) end
  U.log("LEGS OK")
  love.event.quit(0)
end
