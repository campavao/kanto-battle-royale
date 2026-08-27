-- POK-121: do bots WALK somewhere, or pace?
--
-- The complaint this answers is a spectator's, so the measurement is a
-- spectator's too: follow every bot for a minute and count the ground it
-- covers.  A bot on a random walk revisits a small pocket of cells and
-- ends up near where it started; a bot running errands crosses its route,
-- stops, and crosses again.
--
-- Reported per bot: distinct cells stood on, maps visited, and the farthest
-- it ever got from where it dropped.  The gate is deliberately loose -- the
-- point is to catch a REGRESSION to pacing, not to pin a number that a
-- balance tweak would break.
--
-- Solo room, so no relay is needed.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-botwalk POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_walk_smoke.lua \
--   <path to>/lovec . > botwalk.log 2>&1
--
-- `BOTWALK OK` passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

local SAMPLES = 90       -- ~a minute of match at POKEPORT_SPEED=3
local BOTS = 6

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("WATCHER")
  E.setBots(BOTS)
  E.setSafari(0)
  E.setFog(600)

  local ok, err = E.hostSolo()
  if not ok then return C.fail("solo host refused: " .. tostring(err)) end
  -- the options have to be set on the room, and the room has to be STARTED:
  -- hostSolo only opens a lobby of one (bot_smoke.lua's order)
  E.setBots(BOTS)
  E.setSafari(0)
  E.setFog(600)
  U.wait(60)
  E.start()
  if not L.waitPhase(C, "match", 300) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end

  -- ------- follow them
  local seen, start, far, maps = {}, {}, {}, {}
  for i = 1, SAMPLES do
    U.wait(20)
    for _, p in ipairs(E.players() or {}) do
      if p.map and p.x then
        local id = p.id
        seen[id] = seen[id] or {}
        seen[id][p.map .. ":" .. p.x .. "," .. p.y] = true
        maps[id] = maps[id] or {}
        maps[id][p.map] = true
        if not start[id] then start[id] = { map = p.map, x = p.x, y = p.y } end
        if start[id].map == p.map then
          local d = math.abs(p.x - start[id].x) + math.abs(p.y - start[id].y)
          if d > (far[id] or 0) then far[id] = d end
        else
          far[id] = math.max(far[id] or 0, 999)  -- left the map entirely
        end
      end
    end
  end

  local worstCells, movers, crossers, n = math.huge, 0, 0, 0
  for id, cells in pairs(seen) do
    local count = 0
    for _ in pairs(cells) do count = count + 1 end
    local mapCount = 0
    for _ in pairs(maps[id] or {}) do mapCount = mapCount + 1 end
    n = n + 1
    if count < worstCells then worstCells = count end
    if (far[id] or 0) >= 3 then movers = movers + 1 end
    if mapCount > 1 then crossers = crossers + 1 end
    U.log(("BOTWALK: bot %s cells=%d maps=%d farthest=%s")
      :format(tostring(id), count, mapCount, tostring(far[id])))
  end

  if n == 0 then return C.fail("no bots to watch") end
  U.log(("BOTWALK: %d bots, fewest cells %d, %d travelled 3+, %d changed map")
    :format(n, worstCells, movers, crossers))

  -- DISPLACEMENT is the gate, not cells covered.
  --
  -- The first cut required 12+ distinct cells per bot and failed on a run
  -- where every bot was working correctly: a bot that spends six seconds
  -- standing in grass covers FEWER cells than one pacing a corridor, so
  -- the cell count punishes the dwell -- the very thing that makes a bot
  -- look like a person.  Pacing is not "few cells", it is "many cells, no
  -- progress"; the signature that separates them is how far the bot ever
  -- got from where it dropped.
  -- The threshold is deliberately LOW.  Across repeated runs the per-bot
  -- displacement in this window swings between about 4 and 22 depending on
  -- how much of it a bot spent standing in grass, so a high bar would be a
  -- flaky test that says nothing.  What this catches is the state the
  -- errand system actually regressed into twice while it was being
  -- written: a bot that does not move AT ALL.  Judge the quality from the
  -- per-bot lines above, not from the gate.
  -- ALLOW ONE AMBLER.  Across repeated runs there is usually one bot
  -- boxed into a pocket where every errand is either underfoot or
  -- unreachable, and it falls through to the wander floor -- which is the
  -- floor working, not a regression.  Requiring all six made this test
  -- fail about half the time, and a test that flaky is worse than none.
  if movers < n - 1 then
    return C.fail(("%d of %d bots never got 3 cells from their drop")
      :format(n - movers, n))
  end
  -- ...and cells stays only as a frozen-solid check, low enough that a
  -- long dwell cannot trip it
  -- 3, not 5: a bot that is genuinely frozen stands on ONE cell, which is
  -- what both regressions during development looked like.  An ambler in a
  -- pocket legitimately touches four or five.
  if worstCells < 3 then
    return C.fail("a bot stood on only " .. worstCells .. " distinct cells")
  end

  U.log("BOTWALK OK")
  love.event.quit(0)
  U.wait(10)
end
