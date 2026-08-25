-- The 2026-08-25 playtest batch, in-match half: POK-91, POK-94, POK-96,
-- POK-97, POK-98.
--
-- One client, no relay server (a solo room is a LocalRoom).  Run from a
-- gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-playtest-match POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_match.lua \
--   <path to>/lovec . > match.log 2>&1
--
-- Exit 0 with a `MATCH OK` line passes; any `PVP FAIL` line fails.
-- BR_SHOTS=<dir> captures the staged spill and the menu.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Engage = require("mods.battle_royale.lib.engage")
local Spawn = require("mods.battle_royale.lib.spawn")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end
  local function quiet(rounds)
    for _ = 1, rounds or 60 do
      if game.stack:top() == C.ow() then return true end
      U.tap(game, "b")
      U.wait(12)
    end
    return game.stack:top() == C.ow()
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("PROBE")
  E.setSafari(0)          -- straight to the drop
  E.setFog(600)           -- nothing dies of fog while we work
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
  quiet(60)

  -- Somewhere KNOWN and wide: Pewter's street is the clear line every
  -- other driver here stages on.
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  quiet(60)
  U.log(("MATCH: posted on %s at %s,%s"):format(
    tostring(C.map()), tostring(C.x()), tostring(C.y())))

  -- ------------------------------------------ POK-94: spills stay off doors
  --
  -- A warp tile is walkable BY DESIGN, so walkability alone let a spilled
  -- ball land on the VIRIDIAN mart's door -- and a solid ball on a warp
  -- shuts that building for the rest of the match, for everyone.
  if not L.flyTo(C, "VIRIDIAN_CITY") then
    return C.fail("FLY did not reach Viridian; at " .. tostring(C.map()))
  end
  quiet(60)
  local maps, tilesets = game.data.maps, game.data.tilesets
  local doors = (maps.VIRIDIAN_CITY or {}).warps or {}
  if #doors == 0 then return C.fail("no doors in Viridian to test against") end

  local function isWarpCell(x, y)
    for _, w in ipairs(doors) do
      if w.x == x and w.y == y then return true end
    end
    return false
  end

  -- Prove the scenario is real on THIS map before proving the fix: with a
  -- warp-blind predicate (walkability only, which is what shipped), does
  -- the placement search pick a door?
  --
  -- Aimed BESIDE each door, never at it: placeAround rings OUTWARD from
  -- its aim cell and only falls back to the cell itself when the rings
  -- cannot fill the count, so aiming at a door is the one spot that never
  -- puts a ball on it.  The real case is a trainer going down next to the
  -- mart with the door in the first ring.
  local Spills = require("mods.battle_royale.lib.spills")
  local wouldHaveHit, blindProbes = 0, 0
  for _, w in ipairs(doors) do
    for _, off in ipairs({ { 0, 1 }, { 0, 2 }, { 1, 1 }, { -1, 1 } }) do
      local ax, ay = w.x + off[1], w.y + off[2]
      if Spawn.walkable(maps, tilesets, "VIRIDIAN_CITY", ax, ay) then
        blindProbes = blindProbes + 1
        local cells = Spills.placeAround(ax, ay, 6, function(x, y)
          return Spawn.walkable(maps, tilesets, "VIRIDIAN_CITY", x, y)
        end)
        for _, c in ipairs(cells) do
          if isWarpCell(c.x, c.y) then wouldHaveHit = wouldHaveHit + 1 end
        end
      end
    end
  end
  U.log(("MATCH: a warp-blind spill lands on a door %d time(s) across %d probes")
    :format(wouldHaveHit, blindProbes))
  if wouldHaveHit == 0 then
    return C.fail("the staging never reproduces the bug, so it proves nothing")
  end

  -- ...and with the shipped predicate, the same probes place nothing on one
  local stillHits = 0
  for _, w in ipairs(doors) do
    for _, off in ipairs({ { 0, 1 }, { 0, 2 }, { 1, 1 }, { -1, 1 } }) do
      local ax, ay = w.x + off[1], w.y + off[2]
      if Spawn.walkable(maps, tilesets, "VIRIDIAN_CITY", ax, ay) then
        local cells = Spills.placeAround(ax, ay, 6, function(x, y)
          return Spawn.walkable(maps, tilesets, "VIRIDIAN_CITY", x, y)
             and not Spawn.isWarp(maps, "VIRIDIAN_CITY", x, y)
        end)
        for _, c in ipairs(cells) do
          if isWarpCell(c.x, c.y) then stillHits = stillHits + 1 end
        end
      end
    end
  end
  if stillHits > 0 then
    return C.fail(("the shipped predicate still put %d ball(s) on a door")
      :format(stillHits))
  end
  U.log("MATCH: the shipped predicate places nothing on a door across the same probes")

  -- ...and with the shipped predicate it must never happen.  Walk to each
  -- door and spill right next to it, which is the real case: somebody
  -- goes down outside the mart and their team lands around them.
  local staged, landed = 0, 0
  for i, w in ipairs(doors) do
    -- stand near the door, then aim the spill at the door's own cell so
    -- placeAround's very first ring surrounds it
    if L.goTo(C, "VIRIDIAN_CITY", w.x, w.y + 2, 240) then
      quiet(40)
      local dx, dy = w.x - (C.x() or 0), w.y - (C.y() or 0)
      local spill = E.debugSpill(dx, dy, true)
      if spill then
        staged = staged + 1
        for _, b in ipairs(E.spills() or {}) do
          if b.map == "VIRIDIAN_CITY" then
            landed = landed + 1
            if isWarpCell(b.x, b.y) then
              return C.fail(("a spill landed on the door at %d,%d (aimed at %d,%d)")
                :format(b.x, b.y, w.x, w.y))
            end
          end
        end
      end
    end
    if i >= 3 then break end   -- three doors is the point made
  end
  if staged == 0 then return C.fail("could not stage a spill by any door") end
  U.log(("MATCH: POK-94 ok -- %d spill(s) by %d door(s), %d ball placements, none on a warp")
    :format(landed, staged, landed))
  shot("11-spill-by-the-door")

  -- --------------------------------------- POK-97: ghosts walk at player pace
  --
  -- Player steps a cell in 16 frames, NPC in 32.  A ghost replays somebody
  -- else's PLAYER, so at NPC pace its queue gained a step it could not
  -- spend every other step and resolved as a teleport -- the stutter.
  -- back to Pewter's street: Viridian's mart frontage is walls and doors,
  -- and a ghost needs somewhere it can actually stand
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not return to Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail("never got back to the post")
  end
  quiet(60)

  local bots = E.bots() or {}
  if #bots == 0 then return C.fail("no bots to look at") end
  local botId = bots[1].id

  local function findGhost()
    for _, npc in ipairs(C.ow().npcs or {}) do
      local name = npc.def and npc.def.name
      if name and tostring(name):find("BR_PEER_", 1, true) then return npc end
    end
    return nil
  end

  -- Scan outward for somewhere a ghost can legally stand, and keep trying
  -- until one actually spawns: debugPlaceBot writes the peer's cell but
  -- spawnNpc still has to accept it, and a wall or a doorway is refused.
  -- Two cells clear of us at least, so the eyeline does not turn this into
  -- a fight before it is a walk.
  local ghost, placed
  local myMap, myX, myY = C.map(), C.x() or 0, C.y() or 0
  -- never in front of us: the eyeline is predatory and has no consent
  -- step, so a ghost dropped into it becomes a battle before it becomes a
  -- walk, and a battle despawns every ghost on the map.
  local facing = C.ow().player and C.ow().player.facing
  local AHEAD = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local ahead = AHEAD[facing or "down"] or { 0, 1 }
  for radius = 2, 5 do
    for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
      local bx, by = myX + d[1] * radius, myY + d[2] * radius
      local infront = (d[1] == ahead[1] and d[2] == ahead[2])
      if not infront
         and Spawn.walkable(maps, tilesets, myMap, bx, by)
         and not Spawn.isWarp(maps, myMap, bx, by)
         and E.debugPlaceBot(botId, myMap, bx, by) then
        for _ = 1, 30 do
          U.wait(6)
          ghost = findGhost()
          if ghost then placed = ("%d,%d"):format(bx, by) break end
        end
      end
      if ghost then break end
    end
    if ghost then break end
  end
  if not ghost then
    return C.fail(("no ghost NPC spawned for the bot anywhere near %d,%d on %s")
      :format(myX, myY, tostring(myMap)))
  end
  U.log("MATCH: a ghost is standing at " .. tostring(placed))
  local player = C.ow().player
  local want = player and player.stepFrames
  if ghost.stepFrames ~= want then
    return C.fail(("the ghost steps in %s frames, the player in %s")
      :format(tostring(ghost.stepFrames), tostring(want)))
  end
  U.log(("MATCH: POK-97 ok -- the ghost steps in %s frames, same as the player")
    :format(tostring(ghost.stepFrames)))

  -- ------------------------------------- POK-98: the world under a menu
  --
  -- StateStack:update only updates the TOP state, so OverworldState (and
  -- the npc:update loop that walks these ghosts) stopped dead the moment
  -- the START menu went up.  The mod's own tick never stops, so it walks
  -- them itself while anything sits above the world.
  if not quiet(120) then return C.fail("could not settle before the menu test") end
  local menu
  for _ = 1, 20 do
    U.tap(game, "start")
    U.wait(30)
    local top = game.stack:top()
    if top and top.items then menu = top break end
    if top ~= C.ow() then U.tap(game, "b") U.wait(12) end
  end
  if not menu then
    return C.fail("the START menu did not open for the pause test")
  end
  -- sample the ghost's sub-cell position across a good spread of frames
  -- while the menu is up; a frozen world never moves it at all
  local moved, samples = false, {}
  local lastX, lastY = ghost.px, ghost.py
  for i = 1, 200 do
    U.wait(6)
    if ghost.px ~= lastX or ghost.py ~= lastY then moved = true end
    lastX, lastY = ghost.px, ghost.py
    if i % 40 == 0 then
      samples[#samples + 1] = ("%s,%s"):format(tostring(ghost.px), tostring(ghost.py))
    end
    if moved then break end
  end
  if game.stack:top() ~= menu then
    return C.fail("the menu closed during the pause test")
  end
  if not moved then
    return C.fail("the ghost never moved with the menu open (" ..
                  table.concat(samples, " ") .. ")")
  end
  U.log("MATCH: POK-98 ok -- the ghost kept walking with the START menu open")
  shot("12-menu-open-world-alive")
  U.tap(game, "b")
  quiet(60)

  -- --------------------------------------- POK-96: never engage off screen
  --
  -- The tuned reach is six cells along a row, but the camera centres the
  -- player: on a faithful 160px view that is a cell past the edge.  The
  -- cap is what the frame actually shows, and never more than the tuning.
  local vw, vh = game.renderer:worldViewSize()
  local rangeX = Engage.visibleRange("right", vw)
  local rangeY = Engage.visibleRange("down", vh)
  U.log(("MATCH: view is %sx%s px -> reach %d across, %d down (tuned %d/%d)")
    :format(tostring(vw), tostring(vh), rangeX, rangeY,
            Engage.RANGE, Engage.RANGE_Y))
  if rangeX > Engage.RANGE or rangeY > Engage.RANGE_Y then
    return C.fail("a wide window bought a longer eyeline than the tuning")
  end
  local halfW = math.floor((vw or 160) / 2)
  if rangeX * 16 >= halfW + 16 then
    return C.fail(("reach %d is past the %dpx half-view"):format(rangeX, halfW))
  end
  U.log(("MATCH: POK-96 ok -- the eyeline stops inside the frame (%d cells, half-view %dpx)")
    :format(rangeX, halfW))

  -- ------------------------------------------- POK-91: no levelling mid-fight
  --
  -- The guard used to be `BR.status ~= "battle"`, and status only says
  -- "battle" for a PvP duel or a bot fight.  A WILD encounter left it
  -- "alive", so a fog shrink landing mid-battle rewrote mon.stats and the
  -- level of the thing standing on the field -- Lv5 to Lv15 between turns.
  --
  -- Staged rather than waited for: open a wild battle, then collapse the
  -- fog interval so the very next ring tick jumps several rungs.
  L.armParty(C, "NIDORINO", 5, "TACKLE")
  local before = game.save.party[1].level
  local wild
  local okWild = pcall(function()
    local ow = C.ow()
    wild = require("src.battle.BattleState").newWild(game, "RATTATA", 3)
    wild.onFinish = function(result) ow:afterBattle(result, wild) end
    ow:pushBattle(wild)
  end)
  if not (okWild and wild) then return C.fail("could not stage a wild battle") end
  local opened = false
  for _ = 1, 200 do
    U.wait(10)
    if game.stack:top() == wild then opened = true break end
  end
  if not opened then return C.fail("the staged wild battle did not open") end
  if E.status() ~= "alive" then
    return C.fail("a wild battle set status to " .. tostring(E.status())
                  .. "; the old guard would have covered this case")
  end
  U.log(("MATCH: wild battle open at Lv%d, status %s (ring phase %s, level target %s)")
    :format(before, tostring(E.status()),
            tostring(E.ring() and E.ring().phase), tostring(E.level())))

  -- collapse the interval: the next tickRing jumps to a late phase
  E.setFog(1)
  local target, jumped = nil, false
  for _ = 1, 240 do
    U.wait(15)
    target = E.level()
    if target and target > before then jumped = true break end
  end
  if not jumped then
    return C.fail("the ring never advanced, so nothing was under test")
  end
  U.log(("MATCH: the ring jumped -- phase %s wants Lv%d")
    :format(tostring(E.ring() and E.ring().phase), tostring(target)))
  shot("10-shrink-during-battle")

  -- hold in the battle a good while: this is where it used to level
  for _ = 1, 60 do
    U.wait(15)
    local lv = game.save.party[1] and game.save.party[1].level
    if lv ~= before then
      return C.fail(("levelled to Lv%s DURING the battle (entered at Lv%d)")
        :format(tostring(lv), before))
    end
  end
  U.log(("MATCH: POK-91 ok -- still Lv%d after the shrink, with the battle open")
    :format(before))

  -- Close it, and the rung is paid out.  Deliberately NOT gated on
  -- reaching a bare overworld first: collapsing the interval ran the ring
  -- all the way to the all-fog endgame, so the screen is full of the
  -- fog's own says -- and tickLevels does not care what is on top, only
  -- that no battle is open.  Waiting for quiet here would be waiting for
  -- something the staging itself made impossible.
  wild.result = "run"
  pcall(wild.finish, wild)
  local raised = false
  for _ = 1, 200 do
    U.wait(15)
    if game.stack:top() ~= C.ow() then U.tap(game, "b") end
    local lv = game.save.party[1] and game.save.party[1].level
    if lv and lv >= target then raised = true break end
  end
  if not raised then
    return C.fail(("the rung was never paid out after the battle (Lv%s, wanted %s)")
      :format(tostring(game.save.party[1] and game.save.party[1].level),
              tostring(target)))
  end
  U.log(("MATCH: POK-91 ok -- Lv%s once the battle closed")
    :format(tostring(game.save.party[1].level)))
  -- Nothing after this, deliberately.  Collapsing the interval ran the ring
  -- to the all-fog endgame, which kills every bot inside a minute and hands
  -- the match to the last one standing -- a Hall of Fame parade the world
  -- never comes back from.  That is fine for the LAST probe and ruinous
  -- for any that followed it, which is why this block sits at the end.

  U.log("MATCH OK")
  love.event.quit(0)
  U.wait(30)
end
