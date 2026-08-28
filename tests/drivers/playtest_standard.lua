-- The STANDARD FLOW: the match a player actually gets.
--
-- Every other driver in this directory stages.  This one does not: it opens
-- the lobby, hosts, and presses START MATCH with the shipped defaults --
-- SAFARI SECONDS 120, FOG SECONDS 240, the solo room's eight bots -- and
-- then plays whatever the game hands it, Safari through the ending, with no
-- debugPhase, no debugWin, no teleport, and no clock shortened.
--
-- It exists because thirteen staged scenarios all passed against a build
-- whose Safari was completely dead: every one of them entered at "match" or
-- "over", so nothing ever walked the two minutes of grass that a player
-- begins with.
--
-- What it proves, in the order the match produces it:
--
--   1. the grass ROLLS.  encounter.roll is what the fix widened, and the
--      engine only calls encounter.species on a non-nil roll -- so an
--      encounter appearing at all is the half that was unreachable.
--   2. the roll is THIS MATCH's, not vanilla Kanto's.  Two independent
--      un-fakeable deltas, both read off the live battle:
--        * LEVEL.  encounter.species overwrites rolled.level with BR:level(),
--          the rung -- 5 at fog phase 1.  The map's own table (read here
--          from game.data.encounters, the same table the engine rolls
--          against) has nothing under level 22.
--        * SPECIES.  Safari.pick redraws from this match's twelve-species
--          pool.  The map's own table holds ten slots and nine species; a
--          catch outside that set cannot have come from it.
--      Neither is a "the box was not the overworld" probe: a level and a
--      species name are exact values with exact vanilla counterparts.
--   3. you leave the zone with a PARTY, and the buzzer does not eliminate
--      you for "caught nothing".
--   4. drop -> match -> an ending -> the BR lobby.
--   5. nothing wild rolls during "drop" or "over" (both still refused).
--
-- Run from a gen1recomp checkout root:
--
--   SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1 \
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-standard POKEPORT_SPEED=1 \
--   BR_SHOTS=<absolute dir, already created> \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_standard.lua \
--   <path to>/lovec . > std.log 2>&1
--
-- POKEPORT_SPEED=1 on purpose.  The Safari's step budget (502 steps) was
-- hand-tuned to walk out at about the same moment the 120 s clock does; at
-- SPEED=3 the driver walks three times as far per wall second and the zone
-- ends on the step budget rather than the buzzer, which is a different
-- ending to the phase.
--
-- `STD OK` passes; any `PVP FAIL` line fails.  Every clock reading is
-- love.timer.getTime (wall), because the mod's clocks are.
--
-- BR_STD_SAFARI_ONLY=1 stops after the buzzer verdict (what the negative
-- control needs: on the Safari-dead build there is no party to drop with,
-- so the run is decided long before an ending).
-- BR_STD_MATCH_BUDGET caps the wall seconds spent waiting for an ending.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Spawn = require("mods.battle_royale.lib.spawn")

local SAFARI_MAP = "SAFARI_ZONE_CENTER"

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local SAFARI_ONLY = os.getenv("BR_STD_SAFARI_ONLY") == "1"
  local MATCH_BUDGET = tonumber(os.getenv("BR_STD_MATCH_BUDGET") or "2400")

  local function wall() return love.timer.getTime() end
  local T0 = wall()
  local function el() return wall() - T0 end

  local shotN = 0
  local function shot(name)
    if not SHOTS then return end
    shotN = shotN + 1
    U.shot(game, ("%s/std-%02d-%s.png"):format(SHOTS, shotN, name))
  end

  local function say(fmt, ...)
    local n = select("#", ...)
    U.log(("STD t+%7.2f  "):format(el()) .. (n > 0 and fmt:format(...) or fmt))
  end

  -- ------------------------------------------------------------- reading

  local function topName()
    local top = game.stack:top()
    if top == nil then return "nothing" end
    if type(top) ~= "table" then return tostring(top) end
    if top == C.ow() then
      local ow = C.ow()
      local busy = ow.runner and ow.runner.isRunning and ow.runner:isRunning()
      return busy and "overworld+say" or "overworld"
    end
    if top.isBattle then
      return "BATTLE:" .. tostring(top.battleKind and top:battleKind() or "?")
    end
    if top.pages ~= nil and top.showPage ~= nil then return "fame" end
    if top.fly ~= nil and top.locs ~= nil then return "townmap" end
    if top.screenId then return "screen:" .. tostring(top.screenId) end
    if type(top.items) == "table" then
      local labels = {}
      for _, it in ipairs(top.items) do labels[#labels + 1] = tostring(it.label or "") end
      return "menu{" .. table.concat(labels, ",") .. "}"
    end
    if top.isOverworld then return "overworld(other)" end
    return "state"
  end

  local function onStack(s)
    for _, st in ipairs((game.stack and game.stack.states) or {}) do
      if st == s then return true end
    end
    return false
  end

  local function overworldOnStack()
    for _, s in ipairs((game.stack and game.stack.states) or {}) do
      if s.isOverworld then return s end
    end
    return nil
  end

  -- a WILD battle: the thing encounter.roll produces.  A trainer battle
  -- carries .trainer and is a different hook entirely.
  local function wildBattle()
    local top = game.stack:top()
    if type(top) ~= "table" or not top.isBattle then return nil end
    if top.trainer ~= nil then return nil end
    if not (top.enemy and top.enemy.mon) then return nil end
    return top
  end

  local function anyBattle()
    local top = game.stack:top()
    if type(top) == "table" and top.isBattle then return top end
    return nil
  end

  local function partyList()
    local out = {}
    for _, m in ipairs(game.save.party or {}) do
      out[#out + 1] = ("%s Lv%s"):format(tostring(m.species), tostring(m.level))
    end
    return out
  end

  local function balls()
    return game.save.safari and game.save.safari.balls
  end
  local function steps()
    return game.save.safari and game.save.safari.steps
  end

  -- The map's OWN grass, read from the very table OverworldState:rollEncounter
  -- hands to the hook.  Nothing here is hard-coded, so the comparison is
  -- against this build's data rather than against a memory of the ROM.
  local function vanillaGrass(mapId)
    local def = game.data.encounters and game.data.encounters[mapId]
    local slots = def and def.grass and def.grass.slots
    local species, levels, rows = {}, {}, {}
    for _, s in ipairs(slots or {}) do
      species[s.species] = true
      levels[s.level] = true
      rows[#rows + 1] = ("%s Lv%d"):format(tostring(s.species), s.level or -1)
    end
    return species, levels, rows, (def and def.grass and def.grass.rate)
  end

  -- ------------------------------------------------------------ settling
  --
  -- Twenty quiet frames and then a wall second with nothing new arriving:
  -- the pending-say queue delivers one line a tick, so a probe taken one
  -- frame after a box closed is measuring the box.
  local function settle(seconds, capWall)
    local tCap = wall()
    for _ = 1, 900 do
      if (wall() - tCap) > (capWall or 12) then return false end
      local ow = C.ow()
      local busy = game.stack:top() ~= ow
        or (ow and ow.runner and ow.runner.isRunning and ow.runner:isRunning())
      if busy then
        U.tap(game, "b")
        U.wait(10)
      else
        local calm = 0
        for _ = 1, 20 do
          U.wait(1)
          if game.stack:top() ~= ow
             or (ow.runner and ow.runner.isRunning and ow.runner:isRunning()) then
            calm = -1
            break
          end
          calm = calm + 1
        end
        if calm >= 20 then
          local t, held = wall(), true
          while (wall() - t) < (seconds or 1.0) do
            if game.stack:top() ~= ow
               or (ow.runner and ow.runner.isRunning and ow.runner:isRunning()) then
              held = false
              break
            end
            U.wait(1)
          end
          if held then return true end
        end
      end
    end
    return false
  end

  -- ----------------------------------------------------------- the trace

  local E

  local phaseFirst, phaseOrder = {}, {}
  local function notePhase()
    local p = E and E.phase()
    if p and phaseFirst[p] == nil then
      phaseFirst[p] = wall()
      phaseOrder[#phaseOrder + 1] = p
    end
  end

  local lastLine, lastPhaseAt = nil, T0
  local function trace(force)
    notePhase()
    local ring = E and E.ring()
    local now = ("%s|%s|alive=%s|ring=%s"):format(
      tostring(E and E.phase()), topName(), tostring(E and E.aliveCount()),
      tostring(ring and ring.phase))
    if now ~= lastLine or force then
      lastLine = now
      say("phase=%-6s top=%-22s alive=%-3s ring=%s/%s status=%s",
          tostring(E and E.phase()), topName(), tostring(E and E.aliveCount()),
          tostring(ring and ring.phase), tostring(ring and ring.radius),
          tostring(E and E.status()))
    end
  end

  local marks = {}
  local function mark(label)
    local t = wall()
    marks[#marks + 1] = { label = label, t = t, gap = t - lastPhaseAt }
    say("MARK %-22s  (+%.2fs since the last mark)", label, t - lastPhaseAt)
    lastPhaseAt = t
  end

  -- ========================================================= the lobby

  U.newGame(game)
  E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("STDFLOW")

  -- DEFAULTS.  Nothing is set here on purpose: no setSafari, no setFog, no
  -- setBots.  hostSolo() fills an empty room to SOLO_BOTS on its own, which
  -- is what a player pressing HOST gets.
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  local hosted = false
  for _ = 1, 400 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then
    return C.fail("the solo room never came up: " .. tostring(E.lastError()))
  end
  say("lobby up: %d in the room, %s bots at start (defaults, nothing set)",
      E.memberCount() or 0, tostring(E.botsAtStart()))
  mark("lobby")
  shot("lobby")

  E.start()
  if not L.waitPhase(C, "safari", 600) then
    return C.fail("never reached the SAFARI (phase " .. tostring(E.phase()) .. ")")
  end
  mark("safari")
  for _ = 1, 10 do U.tap(game, "a") U.wait(20) end
  settle(0.5)

  -- ========================================================= the Safari

  say("in the zone on %s at %s,%s -- %ss left, %s balls, %s steps, party %d, rung %s",
      tostring(C.map()), tostring(C.x()), tostring(C.y()),
      tostring(E.safariLeft()), tostring(balls()), tostring(steps()),
      #(game.save.party or {}), tostring(E.level()))
  if C.map() ~= SAFARI_MAP then
    say("(note) the zone opened on %s, not %s", tostring(C.map()), SAFARI_MAP)
  end
  local safariLeftAtStart = tonumber(E.safariLeft()) or -1
  local ballsLow = nil
  local function noteBalls()
    local b = balls()
    if b and (ballsLow == nil or b < ballsLow) then ballsLow = b end
  end
  if safariLeftAtStart < 100 then
    return C.fail(("the SAFARI clock is %s s -- that is not the shipped default")
      :format(tostring(safariLeftAtStart)))
  end
  local ballsAtStart = balls()

  local vSpecies, vLevels, vRows, vRate = vanillaGrass(C.map())
  say("this map's OWN grass (game.data.encounters[%s], rate %s): %s",
      tostring(C.map()), tostring(vRate), table.concat(vRows, ", "))

  -- every grass cell the engine agrees is grass and Spawn agrees is walkable
  local grass = {}
  do
    local mapId = C.map()
    local ow, def = C.ow(), game.data.maps[mapId]
    local map = ow and ow.map
    if map and def and map.isGrassCell then
      for y = 0, def.height * 2 - 1 do
        for x = 0, def.width * 2 - 1 do
          if map:isGrassCell(x, y)
             and Spawn.walkable(game.data.maps, game.data.tilesets, mapId, x, y) then
            grass[#grass + 1] = { x = x, y = y }
          end
        end
      end
    end
  end
  say("%d walkable grass cells on %s", #grass, tostring(C.map()))
  if #grass == 0 then return C.fail("no grass to walk on " .. tostring(C.map())) end
  shot("safari-grass")

  local encounters = {}          -- { species, level, kind, phase, caught }
  local perPhase = { safari = 0, drop = 0, match = 0, over = 0, lobby = 0, off = 0 }
  local shotEncounter = false

  -- One wild battle, played the way a player plays a Safari one: A on the
  -- BALL slot, over and over, until the screen leaves the stack.
  local function playWild(b)
    local mon = b.enemy and b.enemy.mon
    local rec = {
      species = mon and mon.species, level = mon and mon.level,
      kind = (b.battleKind and b:battleKind()) or "?",
      phase = tostring(E.phase()),
      ballsBefore = balls(), partyBefore = #(game.save.party or {}),
    }
    local ph = perPhase[rec.phase]
    perPhase[rec.phase] = (ph or 0) + 1
    encounters[#encounters + 1] = rec
    say("ENCOUNTER #%d in phase %s: %s Lv%s (%s battle), %s balls, party %d",
        #encounters, rec.phase, tostring(rec.species), tostring(rec.level),
        rec.kind, tostring(rec.ballsBefore), rec.partyBefore)
    local n = 0
    if not shotEncounter then
      shotEncounter = true
      for _ = 1, 90 do
        if b.phase == "menu" and game.stack:top() == b then break end
        U.tap(game, "a")
        U.wait(8)
        n = n + 1
      end
      say("  (the shot is taken at battle.phase=%s, top %s)",
          tostring(b.phase), topName())
      shot("safari-encounter")
    end
    while onStack(b) and n < 600 do
      U.tap(game, "a")
      U.wait(8)
      noteBalls()
      notePhase()
      n = n + 1
    end
    settle(0.3, 6)
    rec.ballsAfter = balls()
    rec.partyAfter = #(game.save.party or {})
    -- the ENGINE's own verdict (BattleState:5089 sets result = "caught"),
    -- not a party count: the Safari lends a ghost lead while the party is
    -- empty and reclaims it with the screen, so #party moves for reasons
    -- that have nothing to do with a catch
    rec.result = rec.resultOverride or b.result
    rec.caught = (rec.result == "caught")
    say("  ...%s (result=%s).  balls %s -> %s, party %s -> %s [%s]",
        rec.caught and "CAUGHT" or "got away", tostring(rec.result),
        tostring(rec.ballsBefore), tostring(rec.ballsAfter),
        tostring(rec.partyBefore), tostring(rec.partyAfter),
        table.concat(partyList(), ", "))
    return rec
  end

  local target, stuck, stepsWalked = nil, 0, 0
  local tZone = wall()
  while E.phase() == "safari" and (wall() - tZone) < 420 do
    local b = wildBattle()
    if b then
      playWild(b)
      target = nil
    else
      local other = anyBattle()
      if other then
        say("(note) a NON-wild battle opened in the zone: %s", topName())
        local n = 0
        while onStack(other) and n < 300 do U.tap(game, "a") U.wait(8) n = n + 1 end
      elseif C.map() ~= SAFARI_MAP then
        -- the gate walk has begun, or a warp took us; let the phase move
        U.tap(game, "a")
        U.wait(10)
      else
        if not target or (C.x() == target.x and C.y() == target.y) then
          target = grass[love.math.random(1, #grass)]
          stuck = 0
        end
        local px, py = C.x(), C.y()
        if not L.stepToward(C, SAFARI_MAP, target.x, target.y) then
          target = nil
          if not anyBattle() then U.tap(game, "a") U.wait(10) end
        elseif C.x() == px and C.y() == py then
          stuck = stuck + 1
          if stuck > 8 then target = nil stuck = 0 end
          if not anyBattle() then U.tap(game, "a") U.wait(6) end
        else
          stuck = 0
          stepsWalked = stepsWalked + 1
        end
        noteBalls()
      end
    end
    trace()
  end
  if E.phase() == "safari" then
    return C.fail(("the SAFARI never ended: %ss on the clock after 420 wall "
      .. "seconds, %d encounter(s)"):format(tostring(E.safariLeft()),
                                            perPhase.safari))
  end
  mark("buzzer (phase left safari)")

  local partyAtBuzzer = partyList()
  say("the buzzer: %d encounter(s) in the zone, %d step(s) walked, "
      .. "balls %s -> %s, steps left %s, party [%s]",
      perPhase.safari, stepsWalked, tostring(ballsAtStart), tostring(balls()),
      tostring(steps()), table.concat(partyAtBuzzer, ", "))
  shot("safari-party-at-the-buzzer")

  -- --------------------------------------------------------- the verdict
  --
  -- Everything below is an exact value with an exact vanilla counterpart.

  local fails = {}
  local function want(name, ok, detail)
    say("CHECK %-34s %s  %s", name, ok and "ok" or "FAILED", tostring(detail or ""))
    if not ok then fails[#fails + 1] = name end
  end

  want("the grass rolled at all", perPhase.safari > 0,
       ("%d encounter(s) in the zone"):format(perPhase.safari))

  local offLadder, offTable, atRung, sawSpecies = {}, {}, 0, {}
  for _, r in ipairs(encounters) do
    if r.phase == "safari" then
      sawSpecies[#sawSpecies + 1] = ("%s Lv%s%s"):format(
        tostring(r.species), tostring(r.level), r.caught and "*" or "")
      if r.level == E.level() then atRung = atRung + 1 end
      if not vLevels[r.level] then offLadder[#offLadder + 1] = tostring(r.level) end
      if not vSpecies[r.species] then
        offTable[#offTable + 1] = tostring(r.species)
      end
    end
  end
  say("the zone dealt: %s   (* = caught)", table.concat(sawSpecies, ", "))

  want("every roll came at the rung",
       perPhase.safari > 0 and atRung == perPhase.safari,
       ("%d/%d at Lv%s; the map's own table has only Lv{%s}")
         :format(atRung, perPhase.safari, tostring(E.level()),
                 (function()
                    local t = {} for lv in pairs(vLevels) do t[#t+1] = lv end
                    table.sort(t) return table.concat(t, ",")
                  end)()))
  want("a level this map cannot produce",
       #offLadder == perPhase.safari and perPhase.safari > 0,
       ("%d/%d off the map's ladder"):format(#offLadder, perPhase.safari))
  -- The pool is twelve species out of fifty-five candidates and the map's
  -- own table holds nine, so an overlap-only run is possible in principle
  -- and vanishingly unlikely past a couple of rolls.  Asserted only once
  -- there are enough rolls for "all of them overlapped" to mean something.
  want("a species this map cannot produce",
       #offTable > 0 or perPhase.safari < 3,
       #offTable > 0 and ("saw " .. table.concat(offTable, ", "))
         or ("every one of %d species drawn was also in the map's own slots")
              :format(perPhase.safari))

  local caughtN = 0
  for _, r in ipairs(encounters) do
    if r.phase == "safari" and r.caught then caughtN = caughtN + 1 end
  end
  want("the engine says a ball CAUGHT one", caughtN > 0,
       ("%d of %d rolls ended result=\"caught\""):format(caughtN, perPhase.safari))
  want("balls were thrown",
       (ballsAtStart and ballsLow and ballsLow < ballsAtStart) and true or false,
       ("%s -> %s (save.safari is cleared at the buzzer, so this is the "
        .. "lowest reading taken inside the zone)")
         :format(tostring(ballsAtStart), tostring(ballsLow)))
  want("a party to drop with", #partyAtBuzzer > 0,
       ("%d mon: %s"):format(#partyAtBuzzer, table.concat(partyAtBuzzer, ", ")))

  -- ============================================================ the drop

  local dropEncounters0 = perPhase.drop
  local picker, pickerName = nil, nil
  local TownMap = require("src.ui.TownMap")
  local tDrop = wall()
  while (wall() - tDrop) < 180 do
    local b = wildBattle()
    if b then playWild(b) end
    local top = game.stack:top()
    if getmetatable(top) == TownMap and top.fly then picker = top break end
    if E.phase() == "match" then break end
    if E.phase() == "lobby" or E.phase() == "off" then break end
    if C.busy() then U.tap(game, "a") end
    U.wait(12)
    trace()
  end
  if picker then
    pickerName = picker.flyMapIds and picker.flyMapIds[picker.sel]
    say("the drop picker is up: %d towns, cursor on %s",
        #(picker.locs or {}), tostring(pickerName))
    shot("drop-picker")
    U.tap(game, "a")
  else
    say("(note) no TOWN MAP picker was seen; phase is %s, top %s",
        tostring(E.phase()), topName())
  end

  if not L.waitPhase(C, "match", 400) then
    -- eliminated at the buzzer is a legitimate end to the Safari for a
    -- build whose grass is dead -- report it as the verdict, not a hang
    say("never reached \"match\": phase %s, status %s",
        tostring(E.phase()), tostring(E.status()))
  end
  mark("match")
  want("nothing wild rolled during \"drop\"", perPhase.drop == dropEncounters0,
       ("%d wild battle(s) between the buzzer and the landing"):format(
         perPhase.drop - dropEncounters0))

  want("not eliminated at the buzzer", E.status() == "alive",
       ("status=%s, party [%s]"):format(tostring(E.status()),
                                        table.concat(partyList(), ", ")))

  if #fails > 0 then
    return C.fail("the standard flow broke: " .. table.concat(fails, "; "))
  end
  if SAFARI_ONLY then
    say("BR_STD_SAFARI_ONLY -- stopping at the verdict")
    U.log("STD OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- =========================================================== the match

  for _ = 1, 10 do U.tap(game, "a") U.wait(20) end
  settle(0.5)
  local ring = E.ring()
  do
    -- the team the zone produced, on the screen a player would look at it
    U.tap(game, "start")
    U.wait(40)
    say("START menu: top %s", topName())
    U.tap(game, "down")
    U.wait(20)
    U.tap(game, "a")
    U.wait(60)
    say("party screen: top %s", topName())
    shot("party-from-the-safari")
    for _ = 1, 6 do U.tap(game, "b") U.wait(20) end
    settle(0.5, 8)
  end
  say("landed on %s at %s,%s -- %s alive, ring %s r=%s eye %s, party [%s]",
      tostring(C.map()), tostring(C.x()), tostring(C.y()),
      tostring(E.aliveCount()), tostring(ring and ring.phase),
      tostring(ring and ring.radius), tostring(ring and ring.place),
      table.concat(partyList(), ", "))
  shot("match-landing")

  local matchEnc0 = perPhase.match
  local tMatch = wall()
  local walkTarget, walkStuck = nil, 0
  local lastFogRun = 0
  -- A screen that is neither the world nor a battle and will not go away is
  -- the one shape this loop cannot walk out of.  Watched rather than merely
  -- survived: if it lasts, the stack and the party go in the log, because a
  -- match that cannot be left is a finding.
  local sameTop, sameTopAt, wedgeShot = nil, wall(), false
  while E.phase() == "match" and (wall() - tMatch) < MATCH_BUDGET do
    do
      local nm = topName()
      if nm ~= sameTop then
        sameTop, sameTopAt, wedgeShot = nm, wall(), false
      elseif (wall() - sameTopAt) > 45 and not nm:match("^overworld") then
        local hp = {}
        for _, m in ipairs(game.save.party or {}) do
          hp[#hp + 1] = ("%s %s/%s"):format(tostring(m.species), tostring(m.hp),
                                            tostring(m.stats and m.stats.hp))
        end
        local names = {}
        for _, st in ipairs((game.stack and game.stack.states) or {}) do
          names[#names + 1] = (st.isOverworld and "OVERWORLD")
            or (st.isBattle and "battle")
            or (st.screenId and ("screen:" .. tostring(st.screenId)))
            or (st.pages and "fame") or "state"
        end
        say("WEDGED: top %s for %.0fs -- stack [%s], BR status %s, party [%s]",
            nm, wall() - sameTopAt, table.concat(names, " / "),
            tostring(E.status()), table.concat(hp, ", "))
        if not wedgeShot then wedgeShot = true shot("wedged-" .. nm:gsub("[^%w]", "")) end
        -- try to back out the way a player would before giving up on it
        for _ = 1, 12 do U.tap(game, "b") U.wait(12) end
        for _ = 1, 6 do U.tap(game, "a") U.wait(12) end
        sameTopAt = wall()
      end
    end
    local b = anyBattle()
    if b then
      if not b.trainer and b.enemy and b.enemy.mon then
        playWild(b)
      else
        local n = 0
        while onStack(b) and n < 900 do U.tap(game, "a") U.wait(8) n = n + 1 end
        settle(0.3)
        say("a battle closed; party [%s], status %s",
            table.concat(partyList(), ", "), tostring(E.status()))
      end
    elseif E.status() ~= "alive" then
      -- a spectator: no input, just watch the roster drain
      U.wait(60)
    elseif E.inFog() and (wall() - lastFogRun) > 20 then
      lastFogRun = wall()
      local r = E.ring()
      if r and r.place then
        say("in the fog on %s -- running for %s", tostring(C.map()), tostring(r.place))
        L.flyTo(C, r.place)
      end
      walkTarget = nil
    else
      -- an ordinary walk: a random walkable cell on this map, repathed
      local mapId = C.map()
      local def = mapId and game.data.maps[mapId]
      if not def then
        U.tap(game, "a")
        U.wait(20)
      else
        if not walkTarget or walkTarget.map ~= mapId
           or (C.x() == walkTarget.x and C.y() == walkTarget.y) then
          local w, h = def.width * 2, def.height * 2
          local pick = nil
          for _ = 1, 60 do
            local x, y = love.math.random(0, w - 1), love.math.random(0, h - 1)
            if Spawn.walkable(game.data.maps, game.data.tilesets, mapId, x, y) then
              pick = { map = mapId, x = x, y = y }
              break
            end
          end
          walkTarget = pick
          walkStuck = 0
        end
        if walkTarget then
          local px, py = C.x(), C.y()
          if not L.stepToward(C, mapId, walkTarget.x, walkTarget.y) then
            walkTarget = nil
            if not anyBattle() then U.tap(game, "a") U.wait(10) end
          elseif C.x() == px and C.y() == py then
            walkStuck = walkStuck + 1
            if walkStuck > 8 then walkTarget = nil walkStuck = 0 end
            if not anyBattle() then U.tap(game, "a") U.wait(6) end
          else
            walkStuck = 0
          end
        else
          U.wait(20)
        end
      end
    end
    trace()
  end
  if E.phase() == "match" then
    return C.fail(("the match did not end inside %ds: %s alive, ring %s, status %s")
      :format(MATCH_BUDGET, tostring(E.aliveCount()),
              tostring(E.ring() and E.ring().phase), tostring(E.status())))
  end
  mark("over (phase left match)")
  say("the match ended: phase %s, status %s, %s alive, top %s, ending %s",
      tostring(E.phase()), tostring(E.status()), tostring(E.aliveCount()),
      topName(), tostring(E.ending and E.ending()))
  say("%d wild battle(s) during the match", perPhase.match - matchEnc0)

  -- ========================================================== the ending

  local overEnc0 = perPhase.over
  local sawFame, sawBanner, sawOverworld = false, false, false
  local tOver = wall()
  local overShots = 0
  local lastOverTop, nudged = nil, false
  while (wall() - tOver) < 420 do
    local top = game.stack:top()
    local name = topName()
    if name ~= lastOverTop then
      lastOverTop = name
      say("ending: top=%s phase=%s status=%s", name, tostring(E.phase()),
          tostring(E.status()))
      if overShots < 4 and SHOTS then
        overShots = overShots + 1
        shot("ending-" .. tostring(overShots) .. "-" .. name:gsub("[^%w]", ""))
      end
    end
    if name == "fame" then sawFame = true end
    if name:match("^overworld") then sawOverworld = true end
    if type(top) == "table" and top.isBattle and E.phase() == "over" then
      say("(note) a BATTLE is on screen at \"over\": %s", name)
      if not top.trainer and top.enemy and top.enemy.mon then playWild(top) end
    end
    if E.status() == "lobby" and overworldOnStack() == nil then break end
    -- NO INPUT.  The ending is meant to walk itself from the winner to the
    -- lobby -- playtest_over's V1 legs prove it does with 25 seconds of
    -- silence -- and mashing A at the result card would press a row on it.
    -- Only if it stalls past three minutes does this start pressing, and
    -- that is a finding rather than a nudge.
    if (wall() - tOver) > 180 then
      if not nudged then
        nudged = true
        say("(note) three minutes at \"over\" with no input and still not "
            .. "landed -- pressing A from here")
      end
      U.tap(game, "a")
    end
    U.wait(14)
    notePhase()
  end
  mark("landed")

  local res = E.lastResult and E.lastResult()
  say("the landing: phase=%s status=%s top=%s stack-has-overworld=%s",
      tostring(E.phase()), tostring(E.status()), topName(),
      tostring(overworldOnStack() ~= nil))
  if res then
    say("lastResult{won=%s winnerId=%s name=%s why=%s at=%s}",
        tostring(res.won), tostring(res.winnerId), tostring(res.name),
        tostring(res.why), tostring(res.at))
  else
    say("lastResult() is nil")
  end
  shot("lobby-landing")

  want("nothing wild rolled at \"over\"", perPhase.over == overEnc0,
       ("%d wild battle(s) after the winner"):format(perPhase.over - overEnc0))
  want("no OVERWORLD left on the stack", overworldOnStack() == nil, topName())
  want("back in the lobby", E.status() == "lobby",
       ("status=%s phase=%s"):format(tostring(E.status()), tostring(E.phase())))
  want("the lobby has a result to show", res ~= nil and res.at ~= nil,
       res and tostring(res.name) or "nil")

  -- ============================================================ the tape

  say("---- the tape ----")
  for i, m in ipairs(marks) do
    say("  %2d  %-28s  t+%7.2f  (+%.2fs)", i, m.label, m.t - T0, m.gap)
  end
  say("---- the phases, first frame each was seen ----")
  for i, p in ipairs(phaseOrder) do
    local nextT = phaseOrder[i + 1] and phaseFirst[phaseOrder[i + 1]]
    say("  %-8s t+%7.2f%s", p, phaseFirst[p] - T0,
        nextT and ("   lasted %.2fs"):format(nextT - phaseFirst[p]) or "")
  end
  say("---- the zone ----")
  for i, r in ipairs(encounters) do
    say("  %2d  [%s] %s Lv%s  %-9s balls %s->%s  party %s->%s", i, r.phase,
        tostring(r.species), tostring(r.level),
        tostring(r.result), tostring(r.ballsBefore),
        tostring(r.ballsAfter), tostring(r.partyBefore), tostring(r.partyAfter))
  end
  say("encounters by phase: safari=%d drop=%d match=%d over=%d",
      perPhase.safari, perPhase.drop, perPhase.match, perPhase.over)

  if #fails > 0 then
    return C.fail("the standard flow broke: " .. table.concat(fails, "; "))
  end
  U.log("STD OK")
  love.event.quit(0)
  U.wait(30)
end
