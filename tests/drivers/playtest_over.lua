-- POK-144 / POK-145 / POK-155, in the running game.
--
-- Every terminal route out of a match has to funnel through armEnding ->
-- endMatch and land on the BR lobby screen; the Hall of Fame has to play at
-- 1X; a battle still on screen when the match ends has to be closed out
-- rather than waited on; and nothing new may open once the match is over.
-- None of that can be seen headlessly, so this drives it.
--
--   BR_OVER_CASE=you|bot|nobody   V1  the three endings.  NO INPUT at all
--                                     after debugWin, for 25 wall seconds.
--   BR_OVER_CASE=botwin           V1  the same "a bot won" ending reached by
--                                     PLAYING it -- one bot, step out, it is
--                                     the last one standing.  The only leg
--                                     that can also be staged against the
--                                     unpatched build, where debugWin takes
--                                     no argument and always crowns you.
--   BR_OVER_CASE=speed            V2  the parade is not fast-forwarded
--   BR_OVER_CASE=inbattle         V3  winning while a bot fight is on screen
--   BR_OVER_CASE=walkup           V4  no battle opens once it is over
--   BR_OVER_CASE=nativebattle      G   a NATIVE-script battle at "over":
--                                     BR_OVER_SPOT=giovanni|marowak
--                                     the backstop, not the guard
--   BR_OVER_CASE=nativebattle_ctl  G   ...and the same walk with no win
--   BR_OVER_CASE=lobbywin          H   onWinner from the lobby banks nothing
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-over BR_OVER_CASE=bot POKEPORT_SPEED=3 \
--   BR_SHOTS=<absolute dir, already created> \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_over.lua \
--   <path to>/lovec . > over.log 2>&1
--
-- `OVER OK` passes; any `PVP FAIL` line fails.  Every measurement is on
-- love.timer.getTime (wall), never on U.wait's frame count: the mod's own
-- clock is wall time and POKEPORT_SPEED moves the two apart.
--
-- The `speed` case must run WITHOUT POKEPORT_SPEED.  It also has to undo
-- one thing main.lua does to every scripted run: Game.speedOverride is
-- forced to 1 for a driver (main.lua:443), and Game:logicSpeed returns
-- speedOverride BEFORE it ever consults the core.logic_speed hook
-- (src/core/Game.lua:345) -- so under a driver the mod's clamp is never
-- asked at all.  Clearing speedOverride every frame is what a real player's
-- session looks like (theirs is nil), and it is the only way this scenario
-- can be staged at all.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")
local Spawn = require("mods.battle_royale.lib.spawn")

local CASE = os.getenv("BR_OVER_CASE") or "you"
local NO_INPUT_SECONDS = 25      -- V1's budget, to the second

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local World = require("src.world.WorldAPI").new(game, "playtest_over")

  local function wall() return love.timer.getTime() end
  local shotN = 0
  local function shot(name)
    if not SHOTS then return end
    shotN = shotN + 1
    U.shot(game, ("%s/%s-%02d-%s.png"):format(SHOTS, CASE, shotN, name))
  end

  local function fameState()
    local top = game.stack:top()
    if type(top) ~= "table" then return nil end
    if top.pages == nil or top.showPage == nil then return nil end
    return top
  end

  local function battleState()
    local top = game.stack:top()
    if type(top) ~= "table" then return nil end
    if top.trainer ~= nil and top.enemy ~= nil then return top end
    if top.isBattle then return top end
    return nil
  end

  -- what the player is looking at, in one greppable word
  local function topName()
    local top = game.stack:top()
    if top == nil then return "nothing" end
    if type(top) ~= "table" then return tostring(top) end
    if top == C.ow() then
      local ow = C.ow()
      local busy = ow.runner and ow.runner.isRunning and ow.runner:isRunning()
      return busy and "overworld+say" or "overworld"
    end
    local f = fameState()
    if f then
      local p = f.pages[f.i]
      return ("fame[%s/%s:%s]"):format(tostring(f.i), tostring(#f.pages),
                                       tostring(p and p.kind))
    end
    if battleState() then return "BATTLE" end
    if top.screenId then return "screen:" .. tostring(top.screenId) end
    if type(top.items) == "table" then
      local labels = {}
      for _, it in ipairs(top.items) do labels[#labels + 1] = tostring(it.label or "") end
      return "menu{" .. table.concat(labels, ",") .. "}"
    end
    if top.isOverworld then return "overworld(other)" end
    return "state"
  end

  local E = nil

  -- The control build (before the fix) has none of the new seams.  Reading
  -- one there is a nil call, which would fail the control run for the wrong
  -- reason -- so every new export is asked for softly and its absence is
  -- reported rather than thrown.
  local function seam(name, ...)
    local f = E and E[name]
    if type(f) ~= "function" then return nil, false end
    return f(...), true
  end

  -- Nothing on screen but the world, and it has STAYED that way: a probe
  -- taken one frame after a say closed is measuring the say.  Twenty quiet
  -- frames, then a further wall second with nothing new arriving -- the
  -- pending-say queue delivers one line per tick, so a second of silence is
  -- an empty queue.
  local function settle(seconds)
    for _ = 1, 600 do
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
          -- ...and hold it, with no input, for the rest of the window
          local t0, held = wall(), true
          while (wall() - t0) < (seconds or 1.0) do
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

  -- ------------------------------------------------------------- staging

  local function boot(bots, name)
    U.newGame(game)
    E = C.E()
    if not E then return C.fail("no battle_royale exports") end
    E.setName(name or "OVER")
    E.setSafari(0)
    E.setFog(600)          -- nothing dies of fog while we work
    if not E.hostSolo() then return C.fail("hostSolo refused") end
    E.setBots(bots)
    E.setSafari(0)
    E.setFog(600)
    local hosted = false
    for _ = 1, 400 do
      U.wait(10)
      if (E.memberCount() or 0) >= 1 then hosted = true break end
    end
    if not hosted then
      return C.fail("the solo room never came up: " .. tostring(E.lastError()))
    end
    E.start()
    if not L.mashUntil(C, function() return E.phase() == "match" end, 600) then
      return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
    end
    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    if not settle(1.0) then
      return C.fail(("the match world never went quiet before the probe "
        .. "(top %s, status %s, phase %s, at %s %s,%s)"):format(
        topName(), tostring(E.status()), tostring(E.phase()), tostring(C.map()),
        tostring(C.x()), tostring(C.y())))
    end
    U.log(("OVER[%s]: in the match on %s at %s,%s, %s alive, top %s")
      :format(CASE, tostring(C.map()), tostring(C.x()), tostring(C.y()),
              tostring(E.aliveCount()), topName()))
    return true
  end

  -- every bot but one, sent to a corner of Cinnabar: an off-map bot cannot
  -- engage and its ghost despawns, so only the victim can start a fight
  local function banishAllBut(keepId)
    for _, b in ipairs(E.bots() or {}) do
      if b.id ~= keepId then E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end
    end
  end

  -- bot_smoke's lane recipe: a line the ENGINE agrees is clear, preferring
  -- the way we already face (a held turn also steps).
  local function stageEngage(victimId)
    if not L.flyTo(C, "PEWTER_CITY") then
      return nil, "FLY did not land in Pewter; at " .. tostring(C.map())
    end
    if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
      return nil, ("never reached the post; at %s,%s"):format(
        tostring(C.x()), tostring(C.y()))
    end
    settle(0.5)
    local ow = C.ow()
    local map = ow and ow.map
    if not map then return nil, "no map to stage on" end
    local myMap, myX, myY = C.map(), C.x(), C.y()
    local function clear(x, y)
      return map:inBounds(x, y) and map:isWalkableCell(x, y)
    end
    local DIRS = {
      { dir = "right", dx = 1,  dy = 0,  reach = 6 },
      { dir = "left",  dx = -1, dy = 0,  reach = 6 },
      { dir = "down",  dx = 0,  dy = 1,  reach = 4 },
      { dir = "up",    dx = 0,  dy = -1, reach = 4 },
    }
    local function laneFor(d, fx, fy)
      for gap = math.min(5, d.reach), 3, -1 do
        local ok = true
        for step = 1, gap do
          if not clear(fx + d.dx * step, fy + d.dy * step) then ok = false break end
        end
        if ok then return gap end
      end
      return nil
    end
    local facing = ow.player and ow.player.facing
    local lane
    for _, d in ipairs(DIRS) do
      if d.dir == facing then
        local gap = laneFor(d, myX, myY)
        if gap then lane = { d = d, gap = gap } end
      end
    end
    if not lane then
      for _, d in ipairs(DIRS) do
        if laneFor(d, myX, myY) then
          for _ = 1, 20 do
            if ow.player.facing == d.dir then break end
            U.hold(game, d.dir, 2)
            U.wait(8)
          end
          break
        end
      end
      myX, myY = C.x() or myX, C.y() or myY
      facing = ow.player and ow.player.facing
      for _, d in ipairs(DIRS) do
        if d.dir == facing then
          local gap = laneFor(d, myX, myY)
          if gap then lane = { d = d, gap = gap } end
        end
      end
    end
    if not lane then
      return nil, ("no clear eyeline from %s,%s facing %s"):format(
        tostring(myX), tostring(myY), tostring(facing))
    end
    return { map = myMap,
             x = myX + lane.d.dx * lane.gap,
             y = myY + lane.d.dy * lane.gap,
             gap = lane.gap, dir = lane.d.dir }
  end

  -- ------------------------------------------------------ the timeline

  local marks = {}
  local function mark(label, t)
    marks[#marks + 1] = { label = label, t = t or wall() }
  end
  local lastSeen = nil
  local t0 = nil
  local function trace()
    local now = ("%s|%s"):format(tostring(E.phase()), topName())
    if now ~= lastSeen then
      lastSeen = now
      U.log(("OVER[%s]: t+%.2f  phase=%s top=%s"):format(
        CASE, t0 and (wall() - t0) or 0, tostring(E.phase()), topName()))
    end
  end

  -- ------------------------------------------------------------ the runs

  -- What is actually on the stack, top last.
  local function stackNames()
    local out, states = {}, game.stack and game.stack.states or {}
    for i = 1, #states do
      local s = states[i]
      out[#out + 1] = (s.isOverworld and "OVERWORLD")
        or (s.screenId and ("screen:" .. tostring(s.screenId)))
        or (s.pages and s.showPage and "fame")
        or (s.isBattle and "battle")
        or (s.isTitle and "title")
        or "state"
    end
    return table.concat(out, " / ")
  end

  -- "No overworld under the screen", asked of the AUTHORITY.
  --
  -- NOT mod.world:current(): WorldAPI:overworld() scans the stack first and
  -- then falls back to Game.overworld (src/world/WorldAPI.lua:99-110), and
  -- Game.overworld is a module singleton that OverworldState:enter sets once
  -- (src/world/OverworldController.lua:233) and NOTHING ever clears -- its
  -- .isOverworld and .map outlive every pop.  So current() answers with the
  -- last map visited for the rest of the process however cleanly the match
  -- was torn down, and no fix could make it nil.  The stack scan is the half
  -- that means what the ticket means.
  local function overworldOnStack()
    for _, s in ipairs((game.stack and game.stack.states) or {}) do
      if s.isOverworld then return s end
    end
    return nil
  end

  local function landingChecks(what)
    local res, hasSeam = seam("lastResult")
    if not hasSeam then
      U.log(("OVER[%s]: lastResult() is ABSENT from this build -- unpatched")
        :format(CASE))
    elseif not res then
      return C.fail(what .. ": lastResult() is nil on the lobby")
    elseif res.at == nil then
      return C.fail(what .. ": lastResult().at is nil")
    end
    local onStack = overworldOnStack()
    if onStack ~= nil then
      local p = onStack.player
      return C.fail(("%s: an overworld is still on the stack -- %s at %s,%s (stack: %s)")
        :format(what, tostring(onStack.map and onStack.map.id),
                tostring(p and p.cellX), tostring(p and p.cellY), stackNames()))
    end
    if E.status() ~= "lobby" then
      return C.fail(("%s: status is %s on the lobby, not \"lobby\"")
        :format(what, tostring(E.status())))
    end
    local door = E.door()
    if not door then return C.fail(what .. ": door() stopped answering") end
    local members = E.memberCount() or 0
    local stale = World:current()
    U.log(("OVER[%s]: landed -- lastResult{won=%s winnerId=%s name=%s at=%s}, "
           .. "status=%s, no OVERWORLD on the stack [%s], door.build=%s, "
           .. "%d in the room, top %s")
      :format(CASE, tostring(res and res.won), tostring(res and res.winnerId),
              tostring(res and res.name),
              res and ("%.2f"):format(res.at) or "n/a",
              tostring(E.status()), stackNames(), tostring(door.build),
              members, topName()))
    U.log(("OVER[%s]: (for the record, mod.world:current() still answers %s -- "
           .. "Game.overworld is a never-cleared singleton, not a place we stand)")
      :format(CASE, tostring(stale and stale.mapId)))
    return true, res
  end

  -- ============================================================== V1
  if CASE == "you" or CASE == "bot" or CASE == "nobody" or CASE == "botwin" then
    -- botwin plays the ending instead of declaring it: one bot, and we step
    -- out, so checkWinner finds exactly one survivor and crowns it.  Every
    -- call it needs exists in the unpatched build too, which is what makes
    -- it the control for "a bot won".
    if boot(CASE == "botwin" and 1 or 3, "ENDER") ~= true then return end
    shot("in-match")

    local who, wantWon
    if CASE == "botwin" then
      for _, b in ipairs(E.bots() or {}) do
        if b.status == "alive" then who = b.id break end
      end
      if not who then return C.fail("no live bot to be the last one standing") end
      wantWon = false
      U.log(("OVER[botwin]: one bot (%s) and me; stepping OUT so it wins")
        :format(tostring(who)))
      t0 = wall()
      local st = E.debugOut("driver")
      if st ~= "out" then return C.fail("debugOut left status " .. tostring(st)) end
      if E.phase() ~= "over" then
        -- the host runs checkWinner on the elimination; give it a beat
        for _ = 1, 600 do
          if E.phase() == "over" then break end
          U.wait(1)
        end
      end
      if E.phase() ~= "over" then
        return C.fail("stepping out did not end the match (phase "
          .. tostring(E.phase()) .. ", alive " .. tostring(E.aliveCount()) .. ")")
      end
    else
      if CASE == "you" then
        who, wantWon = nil, true
      elseif CASE == "nobody" then
        who, wantWon = "nobody", false
      else
        for _, b in ipairs(E.bots() or {}) do
          if b.status == "alive" then who = b.id break end
        end
        if not who then return C.fail("no live bot to hand the match to") end
        wantWon = false
      end
      U.log(("OVER[%s]: declaring the win for %s"):format(CASE, tostring(who or "me")))
      t0 = wall()
      local ph = E.debugWin(who)
      mark("debugWin", t0)
      if ph == nil then return C.fail("debugWin refused: " .. tostring(ph)) end
    end

    -- NO INPUT from here.  Not one press, not a screenshot's worth.
    local tOver, tLobby, sawOver = nil, nil, false
    local seenPhases = {}
    while (wall() - t0) < NO_INPUT_SECONDS do
      local p = E.phase()
      if not seenPhases[tostring(p)] then
        seenPhases[tostring(p)] = wall() - t0
      end
      if p == "over" and not tOver then tOver = wall() sawOver = true end
      if p == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end

    local order = {}
    for k, v in pairs(seenPhases) do order[#order + 1] = ("%s@%.2f"):format(k, v) end
    table.sort(order, function(a, b)
      return tonumber(a:match("@([%d%.]+)")) < tonumber(b:match("@([%d%.]+)"))
    end)
    U.log(("OVER[%s]: phases with zero input -- %s"):format(CASE, table.concat(order, " -> ")))

    if not sawOver then return C.fail("phase never reached over") end

    if not tLobby then
      -- The one prompt the game asks for out loud: the Hall of Fame's
      -- record card draws "A: CLOSE" and waits.  Report it as its own
      -- number rather than folding it into the no-input verdict.
      local f = fameState()
      local page = f and f.pages[f.i]
      U.log(("OVER[%s]: NO LOBBY in %ds with zero input; top=%s phase=%s ending=%s")
        :format(CASE, NO_INPUT_SECONDS, topName(), tostring(E.phase()),
                tostring((seam("ending") or {}).why)))
      shot("stuck")
      if page and page.kind == "card" then
        U.log(("OVER[%s]: the record card is up and asks for A; pressing it once")
          :format(CASE))
        local tA = wall()
        for _ = 1, 400 do
          if E.phase() == "lobby" then break end
          if fameState() then U.tap(game, "a") end
          U.wait(20)
        end
        if E.phase() == "lobby" then
          tLobby = wall()
          U.log(("OVER[%s]: lobby %.2fs after that A"):format(CASE, tLobby - tA))
        end
      end
      if E.phase() ~= "lobby" then
        return C.fail(("phase never reached lobby (stuck at %s, top %s)")
          :format(tostring(E.phase()), topName()))
      end
      U.log(("OVER[%s]: PARTIAL -- the lobby needed one A on the record card")
        :format(CASE))
    else
      U.log(("OVER[%s]: over at t+%.2f, lobby at t+%.2f, zero input")
        :format(CASE, tOver - t0, tLobby - t0))
    end

    U.wait(60)
    local ok, res = landingChecks(CASE)
    if not ok then return end
    if res and res.won ~= wantWon then
      return C.fail(("lastResult().won is %s, wanted %s")
        :format(tostring(res.won), tostring(wantWon)))
    end
    if res and (CASE == "bot" or CASE == "botwin") and res.winnerId ~= who then
      return C.fail(("lastResult().winnerId is %s, wanted %s")
        :format(tostring(res.winnerId), tostring(who)))
    end
    if res and CASE == "nobody" and res.winnerId ~= nil then
      return C.fail("nobody won but winnerId is " .. tostring(res.winnerId))
    end
    shot("landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== V2
  if CASE == "speed" then
    if boot(3, "CHAMP") ~= true then return end

    -- three mon pages, so the parade is 3 x Fame.MON_SECONDS + the card
    local P = require("src.pokemon.Pokemon")
    game.save.party = {
      P.new(game.data, "NIDORINO", 20),
      P.new(game.data, "PIDGEY", 18),
      P.new(game.data, "GEODUDE", 16),
    }
    game.save.options = game.save.options or {}
    game.save.options.speedOverworld = 4
    U.log(("OVER[speed]: party of %d, save.options.speedOverworld=%s")
      :format(#game.save.party, tostring(game.save.options.speedOverworld)))

    -- The hook, live, at phase "match".  speedOverride is cleared and put
    -- back inside ONE driver step, so the engine never observes the gap.
    local function probe()
      local was = game.speedOverride
      game.speedOverride = false
      local ok, got = pcall(function() return game:logicSpeed() end)
      local ok2, vanilla = pcall(function() return game:_resolveLogicSpeed() end)
      game.speedOverride = was
      return ok and got or nil, ok2 and vanilla or nil
    end
    local inMatchSpeed, inMatchVanilla = probe()
    U.log(("OVER[speed]: phase=%s  logicSpeed()=%s  (vanilla would be %s)")
      :format(tostring(E.phase()), tostring(inMatchSpeed), tostring(inMatchVanilla)))

    t0 = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused") end

    -- From here the driver holds speedOverride clear every frame, which is
    -- what a real player's session looks like (main.lua pins it to 1 only
    -- because this is a scripted run).  Now Game:logicSpeed actually asks
    -- the mod.
    local tOver, tLobby, overSpeed, overVanilla
    local pages, lastPage = {}, nil
    local firstMon, cardAt
    local pressedCard = false
    while (wall() - t0) < 60 do
      game.speedOverride = false
      local p = E.phase()
      if p == "over" and not tOver then
        tOver = wall()
        overSpeed, overVanilla = game:logicSpeed(), game:_resolveLogicSpeed()
      end
      local f = fameState()
      if f then
        local key = tostring(f.i)
        if key ~= lastPage then
          lastPage = key
          local pg = f.pages[f.i]
          pages[#pages + 1] = { i = f.i, kind = pg and pg.kind, t = wall() }
          U.log(("OVER[speed]: parade page %s/%s (%s) at t+%.2f  logicSpeed=%s")
            :format(tostring(f.i), tostring(#f.pages), tostring(pg and pg.kind),
                    wall() - t0, tostring(game:logicSpeed())))
          if SHOTS then shot("parade-" .. tostring(f.i)) end
          if pg and pg.kind == "mon" and not firstMon then firstMon = wall() end
          if pg and pg.kind == "card" then cardAt = wall() end
        end
        -- the card draws "A: CLOSE" and waits; press it once, AFTER every
        -- mon page, so it cannot touch the measurement below
        if not pressedCard and cardAt and (wall() - cardAt) > 1.0 then
          pressedCard = true
          U.tap(game, "a")
        end
      end
      if p == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end

    U.log(("OVER[speed]: at phase over  logicSpeed()=%s  (vanilla would be %s)")
      :format(tostring(overSpeed), tostring(overVanilla)))
    if not tOver then return C.fail("phase never reached over") end
    if not tLobby then
      return C.fail(("phase never reached lobby (stuck at %s, top %s)")
        :format(tostring(E.phase()), topName()))
    end
    local monSpan = (firstMon and cardAt) and (cardAt - firstMon) or nil
    U.log(("OVER[speed]: over->lobby %.2fs; three mon pages took %s s; pages=%d")
      :format(tLobby - tOver, monSpan and ("%.2f"):format(monSpan) or "n/a", #pages))
    for _, pg in ipairs(pages) do
      U.log(("OVER[speed]:   page %s (%s) at +%.2f"):format(
        tostring(pg.i), tostring(pg.kind), pg.t - tOver))
    end
    landingChecks("speed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ==================================================== V3 and V4 staging
  if CASE == "inbattle" or CASE == "walkup" then
    if boot(3, "CLOSER") ~= true then return end
    local roster = E.bots() or {}
    local victim
    for _, b in ipairs(roster) do
      if b.status == "alive" then victim = b break end
    end
    if not victim then return C.fail("no live bot to fight") end
    banishAllBut(victim.id)
    U.log(("OVER[%s]: victim %s (%s); the rest are on Cinnabar")
      :format(CASE, tostring(victim.name), tostring(victim.id)))

    local lane, why = stageEngage(victim.id)
    if not lane then return C.fail(why) end
    U.log(("OVER[%s]: lane cell %d,%d on %s, %d away, facing %s")
      :format(CASE, lane.x, lane.y, lane.map, lane.gap, lane.dir))

    local moneyBefore = game.save.money
    local partyHpBefore = {}
    for i, m in ipairs(game.save.party or {}) do
      partyHpBefore[i] = ("%s:%s/%s"):format(tostring(m.species), tostring(m.hp),
                                             tostring(m.stats and m.stats.hp))
    end
    U.log(("OVER[%s]: money before %s; party %s")
      :format(CASE, tostring(moneyBefore), table.concat(partyHpBefore, " ")))

    -- hold the bot in the lane until the eyeline takes
    local armed, firedAt, atSteps = false, nil, nil
    if CASE == "walkup" then
      -- V4: fire the moment the walk-up is in flight and has not arrived
      for attempt = 1, 60 do
        E.debugPlaceBot(victim.id, lane.map, lane.x, lane.y)
        for _ = 1, 240 do
          local w = E.walkUp()
          if w and (w.steps or 0) >= 1 and (w.steps or 0) < Bots.WALKUP_STEPS then
            atSteps = w.steps
            armed = true
            break
          end
          if E.status() == "battle" or battleState() then
            armed = false
            break
          end
          U.wait(1)
        end
        if armed then break end
        if E.status() == "battle" or battleState() then
          return C.fail("the fight opened before the walk-up could be caught")
        end
        if attempt % 10 == 0 then
          U.log(("OVER[walkup]: still staging (%d), status %s"):format(attempt,
            tostring(E.status())))
        end
      end
      if not armed then return C.fail("never caught a walk-up in flight") end
      t0 = wall()
      U.log(("OVER[walkup]: walkUp{id=%s steps=%d} in flight; declaring the win NOW")
        :format(tostring((E.walkUp() or {}).id), atSteps))
      if E.debugWin() == nil then return C.fail("debugWin refused") end
      firedAt = t0
    else
      -- V3: wait for a real battle to be ON SCREEN, then declare the win
      local opened = false
      for attempt = 1, 60 do
        E.debugPlaceBot(victim.id, lane.map, lane.x, lane.y)
        for _ = 1, 240 do
          if battleState() then opened = true break end
          U.wait(2)
        end
        if opened then break end
        if attempt % 10 == 0 then
          U.log(("OVER[inbattle]: still staging (%d), status %s, walkUp %s")
            :format(attempt, tostring(E.status()), tostring(E.walkUp() ~= nil)))
        end
      end
      if not opened then
        return C.fail("the bot battle never reached the screen (status "
          .. tostring(E.status()) .. ")")
      end
      -- let the intro settle so the win lands mid-fight, not on the fade in
      U.wait(120)
      local b = battleState()
      U.log(("OVER[inbattle]: battle on screen -- trainer=%s kind=%s enemy=%s")
        :format(tostring(b and b.trainer and b.trainer.name), tostring(b and b.kind),
                tostring(b and b.enemy and b.enemy.species)))
      shot("battle-open")
      if not battleState() then
        return C.fail("the battle left the screen before the win could be declared")
      end
      t0 = wall()
      if E.debugWin() == nil then return C.fail("debugWin refused") end
      firedAt = t0
      U.log("OVER[inbattle]: declared the win WITH the battle on screen")
    end

    -- no input from here except the record card's own prompt and the shots
    local statusAfter = E.status()
    local shotsAt = (CASE == "walkup")
      and { 1.0, 2.0, 4.0, 6.0, 9.0, 13.0, 18.0 }
      or  { 0.5, 1.5, 2.5, 3.5, 5.0, 7.0, 9.0, 12.0, 16.0, 22.0 }
    local nextShot = 1
    local sawBattleAfter, battleAfterInfo = false, nil
    local tLobby, cardAt, pressedCard = nil, nil, false
    local BUDGET = 3 + 25 + 10   -- BUZZER_BATTLE_GRACE + 25, with headroom
    while (wall() - t0) < BUDGET do
      local el = wall() - t0
      local b = battleState()
      if b and not sawBattleAfter and E.phase() ~= "match" then
        sawBattleAfter = true
        battleAfterInfo = ("kind=%s trainer=%s enemy=%s Lv%s level()=%s")
          :format(tostring(b.kind), tostring(b.trainer and b.trainer.name),
                  tostring(b.enemy and b.enemy.species),
                  tostring(b.enemy and b.enemy.level), tostring(E.level()))
      end
      local f = fameState()
      if f then
        local pg = f.pages[f.i]
        if pg and pg.kind == "card" then
          cardAt = cardAt or wall()
          if not pressedCard and (wall() - cardAt) > 1.0 then
            pressedCard = true
            U.log(("OVER[%s]: the record card asks for A at t+%.2f; pressing once")
              :format(CASE, wall() - t0))
            U.tap(game, "a")
          end
        end
      end
      if E.phase() == "lobby" then tLobby = wall() break end
      if nextShot <= #shotsAt and el >= shotsAt[nextShot] then
        U.log(("OVER[%s]: t+%.2f top=%s phase=%s status=%s")
          :format(CASE, el, topName(), tostring(E.phase()), tostring(E.status())))
        shot(("t%04d-%s"):format(math.floor(shotsAt[nextShot] * 10), topName():gsub("[^%w]", "")))
        nextShot = nextShot + 1
      end
      trace()
      U.wait(1)
    end

    local moneyAfter = game.save.money
    local partyHpAfter = {}
    for i, m in ipairs(game.save.party or {}) do
      partyHpAfter[i] = ("%s:%s/%s"):format(tostring(m.species), tostring(m.hp),
                                            tostring(m.stats and m.stats.hp))
    end
    U.log(("OVER[%s]: status right after the win was %s; money %s -> %s; party %s")
      :format(CASE, tostring(statusAfter), tostring(moneyBefore), tostring(moneyAfter),
              table.concat(partyHpAfter, " ")))
    U.log(("OVER[%s]: walkUp() after the win = %s")
      :format(CASE, tostring(E.walkUp() ~= nil)))
    if sawBattleAfter then
      U.log(("OVER[%s]: A BATTLE WAS ON SCREEN AFTER THE WIN -- %s")
        :format(CASE, battleAfterInfo))
    else
      U.log(("OVER[%s]: no battle on screen at any poll after the win"):format(CASE))
    end

    if not tLobby then
      return C.fail(("phase never reached lobby in %ds (stuck at %s, top %s, ending %s)")
        :format(BUDGET, tostring(E.phase()), topName(),
                tostring((seam("ending") or {}).why)))
    end
    U.log(("OVER[%s]: lobby at t+%.2f"):format(CASE, tLobby - t0))

    if CASE == "inbattle" then
      if moneyAfter ~= moneyBefore then
        return C.fail(("money moved: %s -> %s (a blackout halves it)")
          :format(tostring(moneyBefore), tostring(moneyAfter)))
      end
    end

    U.wait(60)
    local ok, res = landingChecks(CASE)
    if not ok then return end
    if res and res.won ~= true then
      return C.fail("lastResult().won is " .. tostring(res.won) .. ", wanted true")
    end
    shot("landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end


  -- ================================================ the quality round
  --
  -- Everything below was added after the review that rewrote the exit tick,
  -- gave BR.parading the Fame state, moved the script wrap onto onStart /
  -- resetMatch and added clearEnding.  The seven cases above are deliberately
  -- untouched: they are the regression half.
  --
  --   BR_OVER_CASE=twice       B  two matches in a row, the second started
  --                               while the first's ending is still live
  --   BR_OVER_CASE=card        C  the MATCH RECORD card is never yanked
  --   BR_OVER_CASE=wedge       C  ...but a parade with no Fame under it lands
  --   BR_OVER_CASE=overscript  D  a Kanto scripted battle refused at "over"
  --   BR_OVER_CASE=normal      E  an ordinary Red session, no match, untouched
  --   BR_OVER_CASE=noauto      F  nothing starts itself after a win

  local Runtime = require("src.mods.Runtime")

  -- The engine's own view of the hook, not the mod's.  nil means the key is
  -- not in Hooks.chains at all (the cheap dispatch); 0 means the key is there
  -- with nothing on it, which is what unregister leaves behind.
  local function hookProbe(when)
    local chains = Runtime.hooks and Runtime.hooks.chains
    local chain = chains and chains["script.command"]
    U.log(("OVER[%s]: HOOK %s -- wantsHook(script.command)=%s chain=%s")
      :format(CASE, when, tostring(Runtime.wantsHook("script.command")),
              chain and tostring(#chain) or "absent (no key)"))
    return chain and #chain or nil
  end

  -- any battle anywhere on the stack, not merely on top
  local function anyBattle()
    for _, s in ipairs((game.stack and game.stack.states) or {}) do
      if type(s) == "table" and s.isBattle then return s end
    end
    return nil
  end

  local function battleWords(b)
    if not b then return "none" end
    local mon = b.enemy and (b.enemy.mon or b.enemy)
    return ("kind=%s enemy=%s Lv%s"):format(tostring(b.kind),
      tostring(mon and mon.species), tostring(mon and mon.level))
  end

  -- the rows of whatever menu is on the stack, top-most first
  local function menuLabels()
    local states = (game.stack and game.stack.states) or {}
    for i = #states, 1, -1 do
      local s = states[i]
      if type(s) == "table" and type(s.items) == "table" and #s.items > 0 then
        local out = {}
        for _, it in ipairs(s.items) do out[#out + 1] = tostring(it.label or "") end
        return table.concat(out, " | ")
      end
    end
    return nil
  end

  local function objXY(mapId, objName)
    local def = game.data.maps[mapId]
    for _, o in ipairs((def and def.objects) or {}) do
      if o.name == objName then return o.x, o.y end
    end
    return nil
  end

  -- Stand next to a map object and face it.  A teleport rather than a walk:
  -- the object cells here are behind ledges and water in the real game, and
  -- the walk is not what is under test in any case (the skill's own advice).
  local function faceObject(mapId, objName)
    local ox, oy = objXY(mapId, objName)
    if not ox then return nil, ("no object %s on %s"):format(objName, mapId) end
    local opts = {
      { x = ox,     y = oy + 1, facing = "up" },
      { x = ox,     y = oy - 1, facing = "down" },
      { x = ox + 1, y = oy,     facing = "left" },
      { x = ox - 1, y = oy,     facing = "right" },
    }
    for _, c in ipairs(opts) do
      if Spawn.walkable(game.data.maps, game.data.tilesets, mapId, c.x, c.y) then
        U.teleport(game, mapId, c.x, c.y, c.facing)
        U.wait(30)
        return c
      end
    end
    return nil, ("nowhere walkable beside %s at %d,%d"):format(objName, ox, oy)
  end

  -- ============================================================== B
  -- Two matches in a row on one client.  The bug: a guest still reading the
  -- MATCH RECORD card when the host's next `start` lands carries the first
  -- match's ending into the second, and armEnding is then refused by it for
  -- the rest of the session.  Solo, the same shape is reachable exactly:
  -- startMatch has no phase guard, so calling it while the parade is on the
  -- stack IS that message arriving.  Nothing is cleared by hand here.
  if CASE == "twice" then
    if boot(3, "TWICE") ~= true then return end
    shot("m1-in-match")

    -- Something of match 1's to LOOK for in match 2.  The ending fields are
    -- the half `clearEnding` used to reach; the world state -- the ring,
    -- the ghosts, the bags on the ground -- is the half only resetMatch
    -- reaches, and a bag is a count nothing else can move.
    local spill, spillWhy = E.debugSpill(0, 1, true)
    U.wait(60)
    local m1Spills = #(E.spills() or {})
    local m1Ghosts = 0
    for _, pl in ipairs(E.players() or {}) do
      if pl.map ~= nil then m1Ghosts = m1Ghosts + 1 end
    end
    U.log(("OVER[twice]: match 1 owns -- %d spill ball(s) (debugSpill %s), "
           .. "%d placed peer(s), ring=%s")
      :format(m1Spills, spill and "took" or ("refused: " .. tostring(spillWhy)),
              m1Ghosts, tostring(E.ring() and E.ring().phase)))
    local m1RingPlace = E.ring() and E.ring().place
    if m1Spills < 1 then
      return C.fail("match 1 has no spill to carry -- the check below is empty")
    end
    if m1Ghosts < 1 then
      return C.fail("match 1 has no placed peers -- the check below is empty")
    end

    t0 = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused (match 1)") end
    U.log("OVER[twice]: match 1 won; waiting for the parade")

    local paradeAt, cardAt
    while (wall() - t0) < 45 do
      local f = fameState()
      if f then
        paradeAt = paradeAt or wall()
        local pg = f.pages[f.i]
        if pg and pg.kind == "card" then cardAt = wall() break end
      end
      if E.phase() == "lobby" then
        return C.fail("match 1 ended before the parade could be caught")
      end
      trace()
      U.wait(1)
    end
    if not paradeAt then
      return C.fail(("match 1 never paraded (phase %s, top %s)")
        :format(tostring(E.phase()), topName()))
    end
    U.log(("OVER[twice]: parade up at t+%.2f, MATCH RECORD card at %s; top=%s")
      :format(paradeAt - t0, cardAt and ("t+" .. ("%.2f"):format(cardAt - t0)) or "not yet",
              topName()))
    shot("m1-parade")

    local e1 = seam("ending")
    U.log(("OVER[twice]: match 1's ending() while the parade is up = %s")
      :format(e1 and ("{why=" .. tostring(e1.why) .. "}") or "nil"))

    U.log("OVER[twice]: match 2 starts NOW, with match 1's ending still live")
    E.start()
    local t2, started = wall(), false
    while (wall() - t2) < 45 do
      local p = E.phase()
      if p == "match" or p == "safari" then started = true break end
      U.wait(1)
    end
    if not started then
      return C.fail("match 2 never started (phase " .. tostring(E.phase()) .. ")")
    end
    local e2 = seam("ending")
    local f2 = fameState()
    U.log(("OVER[twice]: match 2 up %.2fs later -- phase=%s ending()=%s fame=%s stack=%s")
      :format(wall() - t2, tostring(E.phase()),
              e2 and ("{why=" .. tostring(e2.why) .. "}") or "nil",
              tostring(f2 ~= nil), stackNames()))
    -- BR_OVER_SOFT=1 downgrades the two structural checks to notes, so a
    -- build that DOES carry the ending over can be watched all the way to
    -- whatever match 2 then does instead of stopping at the first symptom.
    local SOFT = os.getenv("BR_OVER_SOFT") == "1"
    if e2 ~= nil then
      if not SOFT then
        return C.fail("match 2 started carrying match 1's armed ending: why="
          .. tostring(e2.why))
      end
      U.log("OVER[twice]: SOFT -- match 2 carries match 1's armed ending; watching on")
    end
    if f2 ~= nil then
      if not SOFT then
        return C.fail("match 2 started with a Hall of Fame still on the stack")
      end
      U.log("OVER[twice]: SOFT -- a Hall of Fame is still on the stack; watching on")
    end

    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    if not settle(1.0) then return C.fail("match 2's world never went quiet") end
    U.log(("OVER[twice]: match 2 on %s at %s,%s, %s alive")
      :format(tostring(C.map()), tostring(C.x()), tostring(C.y()),
              tostring(E.aliveCount())))

    -- the world half, not the ending fields: onStart runs resetMatch now,
    -- and resetMatch is the only thing that clears these
    local m2Spills = E.spills() or {}
    local m2Ring = E.ring()
    local carried = {}
    for _, b2 in ipairs(m2Spills) do
      carried[#carried + 1] = ("%s@%s,%s"):format(tostring(b2.map), tostring(b2.x),
                                                  tostring(b2.y))
    end
    U.log(("OVER[twice]: match 1 carried into match 2 -- %d spill ball(s) [%s], "
           .. "ring=%s, %d peer(s) on the roster")
      :format(#m2Spills, table.concat(carried, " "),
              tostring(m2Ring and m2Ring.phase), #(E.players() or {})))
    if #m2Spills ~= 0 then
      return C.fail(("match 1's %d spill ball(s) are still on the ground in "
        .. "match 2: %s"):format(#m2Spills, table.concat(carried, " ")))
    end
    -- The ring is NOT an assertion: startMatch builds one for every match,
    -- so match 2 having one at phase 1 is correct, and under setFog(600)
    -- neither match's ever advances past 1 -- there is no phase number
    -- that could tell a carried ring from a fresh one.  The centre is
    -- drawn from the match seed, so it is reported for the record and
    -- nothing is concluded from a collision.
    U.log(("OVER[twice]: ring centre -- match 1 %s, match 2 %s (seed-drawn; "
           .. "not an assertion)"):format(tostring(m1RingPlace),
                                          tostring(m2Ring and m2Ring.place)))
    shot("m2-in-match")

    local tw = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused (match 2)") end
    local tOver2, tLobby2, pages2 = nil, nil, 0
    local lastPage2, card2, pressed2 = nil, nil, false
    while (wall() - tw) < 60 do
      if E.phase() == "over" and not tOver2 then tOver2 = wall() end
      local f = fameState()
      if f then
        local key = tostring(f.i)
        if key ~= lastPage2 then
          lastPage2 = key
          pages2 = pages2 + 1
          local pg = f.pages[f.i]
          U.log(("OVER[twice]: match 2 parade page %s/%s (%s) at t+%.2f")
            :format(tostring(f.i), tostring(#f.pages), tostring(pg and pg.kind),
                    wall() - tw))
          if pg and pg.kind == "card" then card2 = wall() end
        end
        if card2 and not pressed2 and (wall() - card2) > 1.0 then
          pressed2 = true
          U.log("OVER[twice]: match 2's record card asks for A; pressing once")
          U.tap(game, "a")
        end
      end
      if E.phase() == "lobby" then tLobby2 = wall() break end
      trace()
      U.wait(1)
    end
    if not tOver2 then return C.fail("match 2 never reached over") end
    if not tLobby2 then
      return C.fail(("match 2 never reached the lobby (stuck at %s, top %s, ending %s)")
        :format(tostring(E.phase()), topName(),
                tostring((seam("ending") or {}).why)))
    end
    U.log(("OVER[twice]: match 2 over at t+%.2f, lobby at t+%.2f (%.2fs apart), "
           .. "%d parade page(s)")
      :format(tOver2 - tw, tLobby2 - tw, tLobby2 - tOver2, pages2))
    if pages2 < 1 then
      return C.fail("match 2 ended with NO parade -- a carried-over deadline expired it")
    end
    if (tLobby2 - tOver2) < 1.0 then
      return C.fail(("match 2 went over->lobby in %.2fs -- too fast to have run its own ending")
        :format(tLobby2 - tOver2))
    end
    U.wait(60)
    local ok, res = landingChecks("twice")
    if not ok then return end
    if res and res.won ~= true then
      return C.fail("lastResult().won is " .. tostring(res.won) .. ", wanted true")
    end
    shot("m2-landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== C1
  -- A parade ON THE STACK owns the exit: a player reading the MATCH RECORD
  -- card must not be yanked off it when the fifteen-second deadline passes.
  if CASE == "card" then
    local HOLD = 20         -- five seconds past END_DEADLINE_SECONDS
    if boot(3, "READER") ~= true then return end
    t0 = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused") end
    local cardAt
    while (wall() - t0) < 45 do
      local f = fameState()
      if f then
        local pg = f.pages[f.i]
        if pg and pg.kind == "card" then cardAt = wall() break end
      end
      if E.phase() == "lobby" then
        return C.fail("the match ended before the MATCH RECORD card came up")
      end
      trace()
      U.wait(1)
    end
    if not cardAt then
      return C.fail("the MATCH RECORD card never came up (top " .. topName() .. ")")
    end
    U.log(("OVER[card]: MATCH RECORD card up at t+%.2f; NOT ONE PRESS for %ds")
      :format(cardAt - t0, HOLD))
    shot("card")
    local held = 0
    while (wall() - cardAt) < HOLD do
      local f = fameState()
      local pg = f and f.pages[f.i]
      if not (pg and pg.kind == "card") then
        return C.fail(("the card left the screen %.2fs in with no input (top %s, phase %s)")
          :format(wall() - cardAt, topName(), tostring(E.phase())))
      end
      if E.phase() ~= "over" then
        return C.fail(("phase left \"over\" %.2fs into the card (now %s)")
          :format(wall() - cardAt, tostring(E.phase())))
      end
      held = wall() - cardAt
      U.wait(1)
    end
    U.log(("OVER[card]: the card survived %.2fs untouched -- deadline is 15s -- "
           .. "phase still %s, ending %s")
      :format(held, tostring(E.phase()), tostring((seam("ending") or {}).why)))
    shot("card-held")
    local tA = wall()
    for _ = 1, 400 do
      if E.phase() == "lobby" then break end
      if fameState() then U.tap(game, "a") end
      U.wait(20)
    end
    if E.phase() ~= "lobby" then
      return C.fail("one A on the card did not reach the lobby (phase "
        .. tostring(E.phase()) .. ")")
    end
    U.log(("OVER[card]: lobby %.2fs after that A"):format(wall() - tA))
    U.wait(60)
    if not landingChecks("card") then return end
    shot("landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== C2
  -- The wedge itself: BR.parading set with NO Fame under it.  Popping the
  -- parade off the stack is exactly that -- Fame's onDone only runs when the
  -- last page closes, so nothing clears the flag and nothing calls endRun.
  -- The exit tick's third branch is the only thing that can land this, and
  -- it must land it on the clock with zero input.
  if CASE == "wedge" then
    if boot(3, "WEDGE") ~= true then return end
    t0 = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused") end
    local paradeAt
    while (wall() - t0) < 45 do
      if fameState() then paradeAt = wall() break end
      if E.phase() == "lobby" then
        return C.fail("the match ended before the parade could be wedged")
      end
      trace()
      U.wait(1)
    end
    if not paradeAt then
      return C.fail("the parade never started (top " .. topName() .. ")")
    end
    U.log(("OVER[wedge]: parade up at t+%.2f (%s); popping it -- onDone never "
           .. "runs, so parading stays set with no Fame under it")
      :format(paradeAt - t0, topName()))
    shot("parade")
    game.stack:pop()
    local tPop = wall()
    U.wait(2)
    if fameState() then return C.fail("the Fame state is still on the stack after the pop") end
    U.log(("OVER[wedge]: popped -- top is %s, phase %s, ending %s, stack %s")
      :format(topName(), tostring(E.phase()),
              tostring((seam("ending") or {}).why), stackNames()))
    shot("wedged")
    local tLobby
    while (wall() - tPop) < 30 do
      if E.phase() == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end
    if not tLobby then
      return C.fail(("the wedge never landed: %.2fs after the pop, phase %s, top %s, ending %s")
        :format(wall() - tPop, tostring(E.phase()), topName(),
                tostring((seam("ending") or {}).why)))
    end
    U.log(("OVER[wedge]: landed on the clock %.2fs after the pop with zero input "
           .. "(grace 4s, deadline 15s)"):format(tLobby - tPop))
    U.wait(60)
    if not landingChecks("wedge") then return end
    shot("landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== D
  -- The scripted-battle half of POK-145, on a real Kanto script: the Power
  -- Plant's disguised VOLTORB, whose text_asm is
  --   { show_text, check_flag, jump_if_true, static_battle }
  -- (data/scripts/flavor/power_plant.lua).  Refused at "over"; the SAME
  -- object, the same A, must fight once the match is torn down.
  if CASE == "overscript" or CASE == "overscript_ctl" then
    -- overscript_ctl is the NEGATIVE of the same run, in the same build:
    -- debugScriptWrap(false) drops the real link and nothing else changes,
    -- so the scripted battle has to open at "over".  If it opens with the
    -- wrap on AND with it off, the refusal above proved nothing.
    local NOWRAP = (CASE == "overscript_ctl")
    if boot(2, "SCRIPT") ~= true then return end
    if NOWRAP then
      local dropped = seam("debugScriptWrap", false)
      U.log(("OVER[%s]: debugScriptWrap(false) -> live=%s"):format(CASE, tostring(dropped)))
    end
    -- Recorded now, asserted at the END: a build with no wrap at all must
    -- fail this scenario on the battle it lets through, not on a missing
    -- seam -- otherwise the control proves nothing about the refusal.
    local armed = hookProbe(NOWRAP and "in the match, wrap dropped" or "in the match")
    local cell, why = faceObject("POWER_PLANT", "POWERPLANT_VOLTORB2")
    if not cell then return C.fail(why) end
    settle(0.5)
    U.log(("OVER[overscript]: standing on %s at %s,%s facing %s, next to "
           .. "POWERPLANT_VOLTORB2; canOpenBattle()=%s")
      :format(tostring(C.map()), tostring(C.x()), tostring(C.y()), cell.facing,
              tostring(seam("canOpenBattle"))))
    if anyBattle() then return C.fail("a battle was already open before the win") end

    -- a BOT wins: our own parade would own the screen and there would be
    -- nothing left to talk to
    local who
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" then who = b.id break end
    end
    if not who then return C.fail("no live bot to hand the match to") end
    t0 = wall()
    if E.debugWin(who) == nil then return C.fail("debugWin refused") end
    U.log(("OVER[overscript]: the match is over (phase %s); talking to the VOLTORB")
      :format(tostring(E.phase())))

    local sawBattle, tLobby, taps = nil, nil, 0
    while (wall() - t0) < 45 do
      local b = anyBattle()
      if b and not sawBattle then sawBattle = battleWords(b) end
      if E.phase() == "lobby" then tLobby = wall() break end
      if (wall() - t0) < 10 then
        U.tap(game, "a")
        taps = taps + 1
        U.wait(12)
      else
        U.wait(1)
      end
      trace()
    end
    U.log(("OVER[overscript]: %d A presses at the VOLTORB while the match was over")
      :format(taps))
    shot("after-refusal")
    if NOWRAP then
      if not sawBattle then
        return C.fail("CONTROL: with the wrap dropped no scripted battle opened "
          .. "either -- the refusal above proves nothing")
      end
      U.log(("OVER[%s]: CONTROL -- with the wrap dropped the SAME talk opened "
             .. "a battle at \"over\": %s"):format(CASE, sawBattle))
      U.log("OVER OK")
      love.event.quit(0)
      U.wait(30)
      return
    end
    if sawBattle then
      return C.fail("a scripted battle OPENED after the match was over -- " .. sawBattle)
    end
    if not tLobby then
      return C.fail(("phase never reached the lobby (%s, top %s)")
        :format(tostring(E.phase()), topName()))
    end
    U.log(("OVER[overscript]: no battle at any poll; lobby at t+%.2f"):format(tLobby - t0))
    U.wait(60)
    if not landingChecks("overscript") then return end
    local after = hookProbe("after the teardown")
    if armed ~= 1 then
      return C.fail("the script.command wrap was not armed in the match (chain "
        .. tostring(armed) .. ")")
    end
    if after ~= 0 then
      return C.fail("the wrap was not dropped on the way out (chain "
        .. tostring(after) .. ")")
    end

    local cell2, why2 = faceObject("POWER_PLANT", "POWERPLANT_VOLTORB2")
    if not cell2 then return C.fail("could not go back to the VOLTORB: " .. tostring(why2)) end
    U.log(("OVER[overscript]: back at the same VOLTORB out of a session "
           .. "(phase %s); the same A must fight now")
      :format(tostring(E.phase())))
    local tT, opened = wall(), nil
    while (wall() - tT) < 30 do
      opened = anyBattle()
      if opened then break end
      U.tap(game, "a")
      U.wait(12)
    end
    if not opened then
      return C.fail("the SAME scripted battle did not open after the teardown "
        .. "-- something is still refusing it")
    end
    U.log(("OVER[overscript]: after the teardown the VOLTORB fought -- %s")
      :format(battleWords(opened)))
    shot("after-teardown-battle")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== E
  -- An ordinary Red session with the mod installed and no match ever
  -- started.  Nothing may be refused and nothing may be altered -- this is
  -- the run that protects the players who never press BATTLE ROYALE.
  if CASE == "normal" then
    U.newGame(game)
    E = C.E()
    if not E then return C.fail("no battle_royale exports") end
    U.log(("OVER[normal]: mod loaded, phase=%s, status=%s -- no match will be started")
      :format(tostring(E.phase()), tostring(E.status())))
    local before = hookProbe("before any match")
    if before ~= nil then
      return C.fail("BR is linked on script.command with no match running (chain "
        .. tostring(before) .. ")")
    end

    local P = require("src.pokemon.Pokemon")
    local mon = P.new(game.data, "NIDORINO", 40)
    mon.moves = { { id = "HORN_ATTACK", pp = 35 } }
    game.save.party = { mon }
    local moneyBefore = game.save.money
    U.log(("OVER[normal]: party %s Lv%s, money %s")
      :format(tostring(mon.species), tostring(mon.level), tostring(moneyBefore)))

    local failures = {}
    local function note(name, ok, detail)
      U.log(("OVER[normal]: %s -- %s %s"):format(name, ok and "OK" or "FAILED",
                                                 tostring(detail or "")))
      if not ok then failures[#failures + 1] = name end
    end

    -- 1. a wild encounter, the engine's own roll (BR wraps encounter.roll)
    do
      local mapId = "VIRIDIAN_FOREST"
      local def = game.data.maps[mapId]
      local sx, sy
      for y = 0, (def.height * 2) - 1 do
        for x = 0, (def.width * 2) - 1 do
          if Spawn.walkable(game.data.maps, game.data.tilesets, mapId, x, y) then
            sx, sy = x, y
            break
          end
        end
        if sx then break end
      end
      if not sx then
        note("wild encounter", false, "no walkable cell on " .. mapId)
      else
        U.teleport(game, mapId, sx, sy, "down")
        U.wait(40)
        local ow = C.ow()
        local map = ow and ow.map
        local gx, gy
        if map and map.isGrassCell then
          for y = 0, (def.height * 2) - 1 do
            for x = 0, (def.width * 2) - 1 do
              if map:isGrassCell(x, y)
                 and Spawn.walkable(game.data.maps, game.data.tilesets, mapId, x, y) then
                gx, gy = x, y
                break
              end
            end
            if gx then break end
          end
        end
        if gx and not (gx == C.x() and gy == C.y()) then
          L.goTo(C, mapId, gx, gy, 120)
        end
        U.log(("OVER[normal]: in the grass at %s,%s on %s (grass cell %s,%s)")
          :format(tostring(C.x()), tostring(C.y()), tostring(C.map()),
                  tostring(gx), tostring(gy)))
        local b
        for i = 1, 160 do
          b = anyBattle()
          if b then break end
          U.hold(game, (i % 2 == 0) and "left" or "right", 14)
          U.wait(6)
        end
        note("wild encounter", b ~= nil, battleWords(b))
        if b then shot("wild") end
      end
    end

    -- 2. a scripted battle: static_battle, through ScriptRunner's dispatch
    do
      local cell, why = faceObject("POWER_PLANT", "POWERPLANT_VOLTORB1")
      if not cell then
        note("scripted battle (static_battle)", false, why)
      else
        local b
        for _ = 1, 30 do
          b = anyBattle()
          if b then break end
          U.tap(game, "a")
          U.wait(14)
        end
        note("scripted battle (static_battle)", b ~= nil, battleWords(b))
        if b then shot("static") end
      end
    end

    -- 3. an ordinary Kanto TRAINER.  Not the same seam as the two above:
    -- a trainer fight reaches the screen through trainer.before_battle,
    -- which BR also wraps, so this is the third of the mods hooks asked
    -- with no session under it.  Several candidates because a gym leader
    -- and a forest bug catcher are different code paths and only one of
    -- them has to be reachable for the question to be answered.
    do
      local CANDIDATES = {
        { map = "PEWTER_GYM",      obj = "PEWTERGYM_COOLTRAINER_M" },
        { map = "VIRIDIAN_FOREST", obj = "VIRIDIANFOREST_YOUNGSTER1" },
        { map = "PEWTER_GYM",      obj = "PEWTERGYM_BROCK" },
      }
      local b, from, tried = nil, nil, {}
      for _, c in ipairs(CANDIDATES) do
        local cell, why = faceObject(c.map, c.obj)
        if not cell then
          tried[#tried + 1] = c.obj .. "(" .. tostring(why) .. ")"
        else
          for _ = 1, 45 do
            b = anyBattle()
            if b then break end
            U.tap(game, "a")
            U.wait(14)
          end
          if b then from = c.obj break end
          local ow = C.ow()
          tried[#tried + 1] = ("%s(no battle; top %s, runner %s)"):format(
            c.obj, topName(),
            tostring(ow and ow.runner and ow.runner.isRunning
                     and ow.runner:isRunning()))
        end
      end
      note("trainer battle", b ~= nil,
           b and (from .. " " .. battleWords(b) .. " trainer="
                  .. tostring(b.trainer and b.trainer.name))
             or ("none of " .. table.concat(tried, ", ")))
      if b then shot("trainer") end
    end

    local after = hookProbe("after an ordinary session")
    if after ~= nil then
      note("no BR link on script.command", false, "chain " .. tostring(after))
    else
      note("no BR link on script.command", true, "the key was never created")
    end
    if E.phase() ~= "off" then
      note("BR stayed out of it", false, "phase " .. tostring(E.phase()))
    else
      note("BR stayed out of it", true, "phase off throughout")
    end

    if #failures > 0 then
      return C.fail("an ordinary session was altered: " .. table.concat(failures, ", "))
    end
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== F
  -- endMatch no longer arms autoStartAt: a host who wins is not pulled into
  -- a fresh match thirty seconds later, and the row says so.
  if CASE == "noauto" then
    local WATCH = 60
    if boot(2, "AGAIN") ~= true then return end
    t0 = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused") end
    local tLobby, card, pressed = nil, nil, false
    while (wall() - t0) < 60 do
      local f = fameState()
      if f then
        local pg = f.pages[f.i]
        if pg and pg.kind == "card" then
          card = card or wall()
          if not pressed and (wall() - card) > 1.0 then
            pressed = true
            U.log("OVER[noauto]: the record card asks for A; pressing once")
            U.tap(game, "a")
          end
        end
      end
      if E.phase() == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end
    if not tLobby then
      return C.fail("never reached the lobby (phase " .. tostring(E.phase()) .. ")")
    end
    U.log(("OVER[noauto]: lobby at t+%.2f, %d in the room, door=%s. NO input for %ds.")
      :format(tLobby - t0, E.memberCount() or 0,
              tostring((E.door() or {}).build), WATCH))
    shot("lobby")
    while (wall() - tLobby) < WATCH do
      local p = E.phase()
      if p ~= "lobby" then
        return C.fail(("a match started on its own %.2fs after the lobby (phase %s)")
          :format(wall() - tLobby, tostring(p)))
      end
      local n = E.startsIn()
      if n ~= nil then
        return C.fail(("startsIn() is %s %.2fs after the lobby -- a countdown nobody armed")
          :format(tostring(n), wall() - tLobby))
      end
      trace()
      U.wait(1)
    end
    local labels = menuLabels()
    U.log(("OVER[noauto]: %ds later phase=%s startsIn()=%s aliveCount=%s")
      :format(WATCH, tostring(E.phase()), tostring(E.startsIn()),
              tostring(E.aliveCount())))
    U.log(("OVER[noauto]: the lobby face reads -- %s"):format(tostring(labels)))
    if not labels then return C.fail("no menu on the stack to read the rows off") end
    if not labels:find("PLAY AGAIN", 1, true) then
      return C.fail("no PLAY AGAIN row on the lobby: " .. labels)
    end
    if labels:find("PLAY AGAIN (", 1, true) then
      return C.fail("the PLAY AGAIN row carries a countdown: " .. labels)
    end
    shot("lobby-row")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end


  -- ============================================================= B (2)
  -- The consequence, not just the flag.  `twice` proves the carried-over
  -- ending is gone; it cannot prove what the carry-over COSTS, because a
  -- local winner's parade ends the match through Fame's onDone -> endRun,
  -- which never consults pendingEnd.  Hand match 2 to a BOT and armEnding
  -- is the only route out -- and armEnding is exactly what a stale
  -- pendingEnd refuses.  Match 2 is also held open past the carried
  -- deadline (frozen when match 1's parade left the stack) so the stale
  -- arm is EXPIRED by the time match 2 ends: without the fix the exit
  -- fires on the first frame of "over", under match 1's reason, and the
  -- room never sees the banner.
  if CASE == "twicebot" then
    if boot(3, "TWICEB") ~= true then return end
    t0 = wall()
    if E.debugWin() == nil then return C.fail("debugWin refused (match 1)") end
    local paradeAt, cardAt
    while (wall() - t0) < 45 do
      local f = fameState()
      if f then
        paradeAt = paradeAt or wall()
        local pg = f.pages[f.i]
        if pg and pg.kind == "card" then cardAt = wall() break end
      end
      if E.phase() == "lobby" then
        return C.fail("match 1 ended before the parade could be caught")
      end
      trace()
      U.wait(1)
    end
    if not paradeAt then
      return C.fail(("match 1 never paraded (phase %s, top %s)")
        :format(tostring(E.phase()), topName()))
    end
    local e1 = seam("ending")
    U.log(("OVER[twicebot]: match 1 parade at t+%.2f, card at %s; ending()=%s")
      :format(paradeAt - t0, cardAt and ("t+" .. ("%.2f"):format(cardAt - t0)) or "not yet",
              e1 and ("{why=" .. tostring(e1.why) .. "}") or "nil"))

    U.log("OVER[twicebot]: match 2 starts NOW, on the record card")
    E.start()
    local t2, started = wall(), false
    while (wall() - t2) < 45 do
      local p = E.phase()
      if p == "match" or p == "safari" then started = true break end
      U.wait(1)
    end
    if not started then
      return C.fail("match 2 never started (phase " .. tostring(E.phase()) .. ")")
    end
    local tStart2 = wall()
    local e2 = seam("ending")
    U.log(("OVER[twicebot]: match 2 up -- ending()=%s")
      :format(e2 and ("{why=" .. tostring(e2.why) .. "}") or "nil"))

    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    -- somewhere with no grass and no bot within sight: nothing may happen
    -- to us for the twenty seconds below
    for _, b in ipairs(E.bots() or {}) do
      E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10)
    end
    U.log(("OVER[twicebot]: on %s at %s,%s, bots banished; holding match 2 "
           .. "open for 20s so match 1's frozen deadline expires")
      :format(tostring(C.map()), tostring(C.x()), tostring(C.y())))
    while (wall() - tStart2) < 20 do
      if E.phase() ~= "match" then
        return C.fail("match 2 left \"match\" while it was being held open (phase "
          .. tostring(E.phase()) .. ")")
      end
      U.wait(1)
    end
    -- best effort only: a wild fight or a say still up when the bot is
    -- crowned only makes the exit SLOWER, which is the direction that
    -- cannot fake the assertion below
    if not settle(1.0) then
      U.log(("OVER[twicebot]: (the screen was not quiet at the win -- top %s)")
        :format(topName()))
    end

    local who
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" then who = b.id break end
    end
    if not who then return C.fail("no live bot to win match 2") end
    U.log(("OVER[twicebot]: handing match 2 to %s, %.1fs after it started")
      :format(tostring(who), wall() - tStart2))
    local tw = wall()
    if E.debugWin(who) == nil then return C.fail("debugWin refused (match 2)") end

    local tOver, tLobby, whyAtOver = nil, nil, nil
    while (wall() - tw) < 45 do
      local p = E.phase()
      if p == "over" then
        tOver = tOver or wall()
        local e = seam("ending")
        if e and not whyAtOver then whyAtOver = e.why end
      end
      if p == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end
    if not tOver then return C.fail("match 2 never reached over") end
    if not tLobby then
      return C.fail(("match 2 never reached the lobby (%s, top %s)")
        :format(tostring(E.phase()), topName()))
    end
    U.log(("OVER[twicebot]: match 2 over at t+%.2f, lobby at t+%.2f (%.2fs apart); "
           .. "the exit it took was armed as %s")
      :format(tOver - tw, tLobby - tw, tLobby - tOver, tostring(whyAtOver)))
    if whyAtOver ~= nil and whyAtOver ~= "another trainer won" then
      return C.fail(("match 2's exit was armed as %q -- that is match 1's reason")
        :format(tostring(whyAtOver)))
    end
    if (tLobby - tOver) < 2.0 then
      return C.fail(("match 2 went over->lobby in %.2fs -- an already-expired "
                     .. "deadline fired on the first frame"):format(tLobby - tOver))
    end
    U.wait(60)
    local ok, res = landingChecks("twicebot")
    if not ok then return end
    if res and res.won ~= false then
      return C.fail("lastResult().won is " .. tostring(res.won) .. ", wanted false")
    end
    if res and res.winnerId ~= who then
      return C.fail(("lastResult().winnerId is %s, wanted %s")
        :format(tostring(res.winnerId), tostring(who)))
    end
    shot("m2-landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== G
  -- The BACKSTOP, on the routes no guard the mod owns can see.
  --
  -- Two native scripts push a BattleState onto the stack themselves, with
  -- no ScriptRunner under them, so the script.command wrap never fires --
  -- and no encounter roll, no trainer.before_battle, no startBotBattle
  -- either.  The battle OPENS at "over" and is SUPPOSED to: what has to
  -- hold instead is the battle.started listener recording localBattle at
  -- inSession() (main.lua:4534) so closeOverBattle can finish() it.
  -- Without it liveLocalBattle() is nil, screenIsQuiet() blocks to the
  -- deadline, and the exit pops the stack out from under a live
  -- BattleState with no finish(): no music restore, no battle.ended.
  --
  --   BR_OVER_SPOT=giovanni  data/scripts/story3.lua:462, ow:pushBattle,
  --                          the Rocket Hideout B4F GIOVANNI talk.  The
  --                          one of the three a PLAYER can reach inside a
  --                          real match: its only gate is
  --                          EVENT_BEAT_ROCKET_HIDEOUT_GIOVANNI, which BR
  --                          does not set, and it needs no item.
  --   BR_OVER_SPOT=marowak   data/scripts/story3.lua:183, game.stack:push,
  --                          the POKEMON_TOWER_6F onStep -- the purest
  --                          form (no engine seam of any kind), but BR
  --                          sets EVENT_BEAT_GHOST_MAROWAK at match start
  --                          (main.lua:190, POK-69) so the driver has to
  --                          clear it to reach the trigger at all.
  --
  --   BR_OVER_CASE=nativebattle       the backstop
  --   BR_OVER_CASE=nativebattle_ctl   the NEGATIVE: the same approach with
  --                                   no win declared.  The script battle
  --                                   has to run normally, which is what
  --                                   makes the refusal-free open above
  --                                   mean something.
  if CASE == "nativebattle" or CASE == "nativebattle_ctl" then
    local CTL = (CASE == "nativebattle_ctl")
    local SPOT = os.getenv("BR_OVER_SPOT") or "giovanni"
    local GRACE = 3            -- BUZZER_BATTLE_GRACE
    -- POKEMON_TOWER_6F onStep fires on (10,16).  Row 17 is SOLID for every
    -- x on this map (Spawn.walkable), so the approach is (10,15) facing
    -- down -- not (10,17) facing up.  (9,16) beside it is the stairs warp;
    -- we never step there.
    local MAP, TX, TY, FROMY = "POKEMON_TOWER_6F", 10, 16, 15
    local FLAG = (SPOT == "marowak") and "EVENT_BEAT_GHOST_MAROWAK"
                 or "EVENT_BEAT_ROCKET_HIDEOUT_GIOVANNI"

    if boot(3, "GHOST") ~= true then return end

    -- The engine's own bus, not the mod's.  BattleState:finish is the only
    -- emitter of battle.ended (src/battle/BattleState.lua:5313), so an
    -- entry here IS proof finish() ran; the stack being popped from under
    -- a live battle emits nothing at all.
    local Runtime2 = require("src.mods.Runtime")
    local started, ended = {}, {}
    local function monOf(b)
      local e = b and b.enemy
      local m = e and (e.mon or e)
      return m and m.species
    end
    Runtime2.events:on("battle.started", function(ev)
      started[#started + 1] = { at = wall(), kind = ev and ev.battle and ev.battle.kind,
                                species = monOf(ev and ev.battle) }
    end, -1000, "playtest_over")
    Runtime2.events:on("battle.ended", function(ev)
      ended[#ended + 1] = { at = wall(), result = ev and ev.result,
                            kind = ev and ev.battle and ev.battle.kind,
                            species = monOf(ev and ev.battle) }
    end, -1000, "playtest_over")

    -- A healthy party ON PURPOSE.  BattleState:finish upgrades ANY
    -- non-"lose" result to "lose" when the party has nothing healthy left
    -- (src/battle/BattleState.lua:5293-5298), which is the thin window
    -- where closeLiveBattle's "run" becomes a blackout.  Going in healthy
    -- is the only way the "run" assertion below is about the funnel.
    local P = require("src.pokemon.Pokemon")
    local mon = P.new(game.data, "NIDORINO", 30)
    mon.moves = { { id = "HORN_ATTACK", pp = 35 } }
    game.save.party = { mon }

    if SPOT == "marowak" then
      -- BR sets this at match start so the tower is walkable (POK-69), so
      -- the trigger is dead for a real player -- said out loud rather than
      -- quietly staged, because it is the reason this leg is the WEAKER of
      -- the two.
      U.log(("OVER[%s]: BR set %s at match start (main.lua:190); clearing it "
             .. "so the onStep can fire at all"):format(CASE, FLAG))
      game.save.flags[FLAG] = false
      U.teleport(game, MAP, TX, FROMY, "down")
      U.wait(30)
    else
      local cell, why = faceObject("ROCKET_HIDEOUT_B4F",
                                   "ROCKETHIDEOUTB4F_GIOVANNI")
      if not cell then return C.fail(tostring(why)) end
      U.log(("OVER[%s]: standing at %d,%d facing %s, next to "
             .. "ROCKETHIDEOUTB4F_GIOVANNI"):format(CASE, cell.x, cell.y, cell.facing))
    end
    if not settle(0.5) then
      U.log(("OVER[%s]: (the room was not quiet before the poke -- top %s)")
        :format(CASE, topName()))
    end
    local moneyBefore = game.save.money
    local flagBefore = game.save.flags[FLAG]
    U.log(("OVER[%s]: spot=%s on %s at %s,%s; money=%s %s=%s party=%s %s/%s "
           .. "canOpenBattle=%s")
      :format(CASE, SPOT, tostring(C.map()), tostring(C.x()), tostring(C.y()),
              tostring(moneyBefore), FLAG, tostring(flagBefore),
              tostring(mon.species), tostring(mon.hp),
              tostring(mon.stats and mon.stats.hp), tostring(seam("canOpenBattle"))))
    if anyBattle() then return C.fail("a battle was already open before the poke") end
    if flagBefore == true then
      return C.fail(FLAG .. " is already set -- the script is gated off")
    end

    local who
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" then who = b.id break end
    end
    if not who then return C.fail("no live bot to hand the match to") end

    t0 = wall()
    if not CTL then
      -- a BOT, so no parade of ours owns the screen
      if E.debugWin(who) == nil then return C.fail("debugWin refused") end
      if E.phase() ~= "over" then
        return C.fail("phase is " .. tostring(E.phase()) .. " after the win, not over")
      end
      U.log(("OVER[%s]: %s won at t+0.00; opening the script battle NOW (the "
             .. "winner's say lands at +0.5s and would eat the input)")
        :format(CASE, tostring(who)))
    else
      U.log(("OVER[%s]: NO win declared (phase %s); the same approach must "
             .. "open the script battle normally"):format(CASE, tostring(E.phase())))
    end

    local sawBattle, sawAt, canOpenAtBattle = nil, nil, nil
    local taps, steps, arrivedAt = 0, 0, nil
    while (wall() - t0) < 10 do
      local b = anyBattle()
      if b then
        sawBattle, sawAt = b, wall()
        canOpenAtBattle = seam("canOpenBattle")
        break
      end
      local ow = C.ow()
      local busy = ow and ow.runner and ow.runner.isRunning and ow.runner:isRunning()
      if game.stack:top() ~= ow or busy then
        U.tap(game, "a") taps = taps + 1
        U.wait(2)
      elseif SPOT ~= "marowak" then
        U.tap(game, "a") taps = taps + 1
        U.wait(3)
      elseif C.x() ~= TX or C.y() ~= TY then
        arrivedAt = nil
        U.hold(game, "down", 4) steps = steps + 1
        U.wait(2)
      else
        -- standing on the trigger with nothing happening: step off and back
        arrivedAt = arrivedAt or wall()
        if (wall() - arrivedAt) > 1.5 then
          arrivedAt = nil
          U.hold(game, "up", 6)
          U.wait(6)
        else
          U.wait(1)
        end
      end
    end

    if not sawBattle then
      return C.fail(("no battle opened at the %s script in %.2fs (at %s,%s on %s, "
        .. "top %s, %d taps, %d steps, phase %s)")
        :format(SPOT, wall() - t0, tostring(C.x()), tostring(C.y()),
                tostring(C.map()), topName(), taps, steps, tostring(E.phase())))
    end
    U.log(("OVER[%s]: a battle IS on the stack %.2fs after t0 -- %s trainer=%s; "
           .. "canOpenBattle()=%s phase=%s status=%s stack=%s")
      :format(CASE, sawAt - t0, battleWords(sawBattle),
              tostring(sawBattle.trainer and sawBattle.trainer.name),
              tostring(canOpenAtBattle), tostring(E.phase()), tostring(E.status()),
              stackNames()))
    U.log(("OVER[%s]: battle.started seen: %d (%s)"):format(CASE, #started,
      #started > 0 and ("kind=" .. tostring(started[#started].kind)
        .. " " .. tostring(started[#started].species)) or "none"))
    shot("native-open")

    if CTL then
      -- The script battle runs.  Nothing may take it away, and the phase
      -- never leaves "match".
      local HOLD = 8
      while (wall() - sawAt) < HOLD do
        if not anyBattle() then
          return C.fail(("CONTROL: the battle left the stack %.2fs in with no "
            .. "match ever over -- something else closes it"):format(wall() - sawAt))
        end
        if E.phase() ~= "match" then
          return C.fail("CONTROL: phase left match: " .. tostring(E.phase()))
        end
        U.wait(1)
      end
      shot("native-ctl-held")
      U.log(("OVER[%s]: CONTROL -- the %s battle held the screen %ds with the "
             .. "match still running (phase %s, top %s, %d battle.ended)")
        :format(CASE, SPOT, HOLD, tostring(E.phase()), topName(), #ended))
      if #ended > 0 then
        return C.fail("CONTROL: a battle.ended arrived while the match was live: "
          .. tostring(ended[1].result))
      end
      U.log("OVER OK")
      love.event.quit(0)
      U.wait(30)
      return
    end

    -- the funnel closes it
    local goneAt
    while (wall() - sawAt) < 20 do
      if not anyBattle() then goneAt = wall() break end
      trace()
      U.wait(1)
    end
    if not goneAt then
      return C.fail(("the battle was STILL on the stack %.2fs after it opened "
        .. "(phase %s, top %s) -- the backstop did not close it")
        :format(wall() - sawAt, tostring(E.phase()), topName()))
    end
    local moneyAtClose = game.save.money
    local flagAtClose = game.save.flags[FLAG]
    U.log(("OVER[%s]: the battle left the stack %.2fs after it opened (%.2fs "
           .. "after the win); money %s -> %s; %s %s -> %s")
      :format(CASE, goneAt - sawAt, goneAt - t0, tostring(moneyBefore),
              tostring(moneyAtClose), FLAG, tostring(flagBefore),
              tostring(flagAtClose)))
    shot("native-closed")

    local tLobby
    while (wall() - t0) < 25 do
      if E.phase() == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end
    for _, e in ipairs(ended) do
      U.log(("OVER[%s]: battle.ended{result=%s kind=%s enemy=%s} at t+%.2f")
        :format(CASE, tostring(e.result), tostring(e.kind), tostring(e.species),
                e.at - t0))
    end

    -- ------- the assertions, in the order they were asked for
    if (sawAt - t0) > 2.0 then
      return C.fail(("the battle took %.2fs to open -- too late to say the guard "
        .. "did not refuse it"):format(sawAt - t0))
    end
    if canOpenAtBattle ~= false then
      return C.fail("canOpenBattle() was " .. tostring(canOpenAtBattle)
        .. " with the battle on the stack, wanted false")
    end
    if (goneAt - sawAt) > (GRACE + 1) then
      return C.fail(("the battle took %.2fs to leave the stack, over the "
        .. "%ds grace + 1"):format(goneAt - sawAt, GRACE))
    end
    local ran = nil
    for _, e in ipairs(ended) do
      if e.result == "run" then ran = e break end
    end
    if not ran then
      local seen = {}
      for _, e in ipairs(ended) do seen[#seen + 1] = tostring(e.result) end
      return C.fail("no battle.ended with result \"run\" -- saw {"
        .. table.concat(seen, ",") .. "}; finish() never ran on the way out")
    end
    if moneyAtClose ~= moneyBefore then
      return C.fail(("money moved %s -> %s -- a blackout halves it and a win pays")
        :format(tostring(moneyBefore), tostring(moneyAtClose)))
    end
    if flagAtClose == true then
      return C.fail(FLAG .. " is set -- the script recorded a victory")
    end
    if not tLobby then
      return C.fail(("phase never reached the lobby in 25s (%s, top %s, ending %s)")
        :format(tostring(E.phase()), topName(), tostring((seam("ending") or {}).why)))
    end
    U.log(("OVER[%s]: lobby at t+%.2f (deadline is 15s)"):format(CASE, tLobby - t0))
    if (tLobby - t0) > 15.5 then
      return C.fail(("the lobby arrived %.2fs after the win -- past the 15s deadline")
        :format(tLobby - t0))
    end
    U.wait(60)
    local ok, res = landingChecks(CASE)
    if not ok then return end
    if res and res.won ~= false then
      return C.fail("lastResult().won is " .. tostring(res.won) .. ", wanted false")
    end
    if res and res.winnerId ~= who then
      return C.fail(("lastResult().winnerId is %s, wanted %s")
        :format(tostring(res.winnerId), tostring(who)))
    end
    shot("landed")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  -- ============================================================== H
  -- onWinner asked from the LOBBY.  debugWin has no pre-check of its own
  -- any more, so the call reaches BR:onWinner exactly as a stray `winner`
  -- off the wire would -- which is the phantom-survivor cascade's last
  -- step: a client whose `start` was dropped sat in the lobby and banked a
  -- career win for a match it never played.
  --
  -- The delta is the CAREER, not the phase: wins are pinned to 2, and LASS
  -- unlocks at exactly 3 (lib/skins.lua:18).  A banked win flips it.  The
  -- persisted file is checked from outside the run.
  if CASE == "lobbywin" then
    if boot(3, "GUARD") ~= true then return end
    local who
    for _, b in ipairs(E.bots() or {}) do
      if b.status == "alive" then who = b.id break end
    end
    if not who then return C.fail("no live bot to hand the match to") end
    t0 = wall()
    if E.debugWin(who) == nil then return C.fail("debugWin refused (the match)") end
    local tLobby
    while (wall() - t0) < 45 do
      if E.phase() == "lobby" then tLobby = wall() break end
      trace()
      U.wait(1)
    end
    if not tLobby then
      return C.fail("never reached the lobby (phase " .. tostring(E.phase()) .. ")")
    end
    U.wait(60)
    if not landingChecks("lobbywin") then return end

    local function skinLocks()
      local out, byId = {}, {}
      for _, e in ipairs(E.skinState() or {}) do
        byId[e.id] = e
        out[#out + 1] = ("%s@%s=%s"):format(tostring(e.id), tostring(e.wins),
                                            e.unlocked and "UNLOCKED" or "locked")
      end
      return table.concat(out, " "), byId
    end

    local set = E.debugSetWins(2)
    local before, byBefore = skinLocks()
    U.log(("OVER[lobbywin]: career pinned to %s -- %s"):format(tostring(set), before))
    if set ~= 2 then return C.fail("debugSetWins(2) returned " .. tostring(set)) end
    if not (byBefore.LASS and byBefore.LASS.wins == 3) then
      return C.fail("LASS is no longer the 3-win skin; pick a new boundary")
    end
    if byBefore.LASS.unlocked then
      return C.fail("LASS is unlocked at 2 wins -- the boundary is not a boundary")
    end
    if not (byBefore.YOUNGSTER and byBefore.YOUNGSTER.unlocked) then
      return C.fail("YOUNGSTER (1 win) is locked at 2 wins -- the read is wrong")
    end
    local resBefore = seam("lastResult")

    local ph, why = E.debugWin()     -- crown MYSELF, from the lobby
    U.log(("OVER[lobbywin]: debugWin() FROM THE LOBBY returned %s (%s); "
           .. "phase is now %s, status %s")
      :format(tostring(ph), tostring(why), tostring(E.phase()), tostring(E.status())))
    U.wait(120)
    local after, byAfter = skinLocks()
    local resAfter = seam("lastResult")
    U.log(("OVER[lobbywin]: career after -- %s"):format(after))
    U.log(("OVER[lobbywin]: lastResult before {won=%s at=%s} after {won=%s at=%s}")
      :format(tostring(resBefore and resBefore.won), tostring(resBefore and resBefore.at),
              tostring(resAfter and resAfter.won), tostring(resAfter and resAfter.at)))
    if E.phase() ~= "lobby" then
      return C.fail("onWinner from the lobby moved the phase to " .. tostring(E.phase()))
    end
    if byAfter.LASS.unlocked then
      return C.fail("A CAREER WIN WAS BANKED FROM THE LOBBY -- LASS (3 wins) unlocked")
    end
    if not byAfter.YOUNGSTER.unlocked then
      return C.fail("the career was reset, not held: YOUNGSTER (1 win) is locked")
    end
    if resBefore and resAfter and resAfter.at ~= resBefore.at then
      return C.fail(("lastResult was rewritten by the lobby call: at %s -> %s")
        :format(tostring(resBefore.at), tostring(resAfter.at)))
    end
    shot("lobby")
    U.log("OVER OK")
    love.event.quit(0)
    U.wait(30)
    return
  end

  C.fail("unknown BR_OVER_CASE: " .. tostring(CASE))
end
