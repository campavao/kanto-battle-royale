-- Evidence probe: CELADON GAME CORNER grunt, post-win freeze.
--
-- One file, two runs.  If game.mods.exports.battle_royale is present it
-- stages a live BR match first (phase "match" / status "alive", which is
-- what arms BR.npcFight in the world.trainer_engaged handler).  If it is
-- absent it runs the identical sequence as a plain playthrough, which is
-- the control.
--
--   BR:      POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom> \
--            POKEPORT_IDENTITY=br-gc-freeze POKEPORT_SPEED=3 \
--            POKEPORT_DRIVER=mods/battle_royale/tests/drivers/gc_grunt_freeze_probe.lua \
--            lovec .
--   control: same, with an identity whose options.lua disables the mod.
--
-- GC_LOG=<abs path> mirrors every line into a flushed side file, because a
-- LOVE process that has to be killed eats its buffered stdout.

local U = require("tests.drivers.util")

return function(game)
  pcall(function() io.stdout:setvbuf("line") end)
  local sidecar
  do
    local p = os.getenv("GC_LOG")
    if p then sidecar = io.open(p, "w") end
  end
  local function say(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[gc]", msg)
    if sidecar then sidecar:write(msg, "\n") sidecar:flush() end
  end
  local function wall() return love.timer.getTime() end
  local function quit(code)
    say("== probe done ==")
    if sidecar then sidecar:flush() sidecar:close() end
    love.event.quit(code or 0)
    U.wait(20)
  end

  local MAP, NAME = "GAME_CORNER", "GAMECORNER_ROCKET"
  local GX, GY = 9, 5
  local STAND = { x = 10, y = 5, facing = "left" }

  local Pokemon = require("src.pokemon.Pokemon")
  local TextBox = require("src.render.TextBox")
  local BattleState = require("src.battle.BattleState")

  local E = game.mods and game.mods.exports and game.mods.exports.battle_royale
  -- GC_ARM=0: the mod is loaded but no match is staged and the phase is
  -- forced "off", so world.trainer_engaged never arms BR.npcFight and
  -- battle.ended never reaches npcDefeated.  Isolates the toggle from the
  -- mere presence of the mod.
  local ARM = os.getenv("GC_ARM") ~= "0"
  if E and not ARM then E = nil end
  local BRLOADED = game.mods and game.mods.exports
                   and game.mods.exports.battle_royale
  local MODE = E and "BR" or (BRLOADED and "BR-IDLE" or "CONTROL")
  say("== probe start: mode=%s ==", MODE)
  do
    local ids = {}
    local loader = game.mods
    if loader and loader.status then
      local st = loader:status() or {}
      for _, m in ipairs(st.available or {}) do
        ids[#ids + 1] = string.format("%s(enabled=%s,state=%s)",
          tostring(m.id), tostring(m.enabled), tostring(m.state))
      end
    end
    say("mods loaded: %s", #ids > 0 and table.concat(ids, " ") or "(none)")
  end

  ------------------------------------------------------------------ staging
  U.newGame(game)

  local function ow() return game.overworld end
  local function top() return game.stack:top() end
  local function quiet(rounds)
    for _ = 1, rounds or 60 do
      if top() == ow() then return true end
      U.tap(game, "b")
      U.wait(10)
    end
    return top() == ow()
  end

  if E then
    E.setName("PROBE")
    E.setSafari(0)
    E.setFog(900)
    local hosted = E.hostSolo()
    say("hostSolo -> %s", tostring(hosted))
    if hosted then
      for _ = 1, 300 do
        U.wait(10)
        if (E.memberCount() or 0) >= 1 then break end
      end
      E.setBots(2)
      E.start()
      for _ = 1, 400 do
        if E.phase() == "match" then break end
        U.tap(game, "a")
        U.wait(10)
      end
    end
    say("after start: phase=%s status=%s alive=%s",
        tostring(E.phase()), tostring(E.status()), tostring(E.aliveCount()))
    for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
    quiet(80)
    -- an adjacent bot is an unconditional fight; get them off the board
    local penned = 0
    for _, b in ipairs(E.bots() or {}) do
      if E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) then penned = penned + 1 end
    end
    say("bots banished to CINNABAR_ISLAND: %d", penned)
  end

  if BRLOADED and not E then
    BRLOADED.debugPhase("off")
    say("BR-IDLE: mod loaded, phase forced to %s status=%s",
        tostring(BRLOADED.phase()), tostring(BRLOADED.status()))
  end

  -- clean slate: he must not read as already defeated or already hidden
  game.save.defeatedTrainers = {}
  game.save.objectToggles = game.save.objectToggles or {}
  game.save.objectToggles[MAP] = nil

  local tank = Pokemon.new(game.data, "MEWTWO", 100)
  tank.moves = { { id = "PSYCHIC_M", pp = 99 } }
  game.save.party = { tank }

  U.teleport(game, MAP, STAND.x, STAND.y, STAND.facing)
  U.wait(30)
  quiet(40)

  if E then
    -- the teleport tore the stack down; re-assert the two fields the
    -- world.trainer_engaged handler reads, so npcFight is armed for sure
    E.debugPhase("match")
    E.debugStatus("alive")
    say("re-armed: phase=%s status=%s", tostring(E.phase()), tostring(E.status()))
  end

  local O = ow()
  say("staged on %s (%d,%d) facing %s; top==ow=%s",
      tostring(O.map and O.map.id), O.player.cellX, O.player.cellY,
      tostring(O.player.facing), tostring(top() == O))

  local function findGrunt()
    local o = ow()
    for _, n in ipairs(o.npcs or {}) do
      if n.def and n.def.name == NAME then return n end
    end
    return nil
  end
  local function poolEntry()
    local o = ow()
    for k, n in pairs(o.npcPool or {}) do
      if n and n.def and n.def.name == NAME then return k, n end
    end
    return nil, nil
  end

  local gruntRef = findGrunt()
  local poolKey0 = select(1, poolEntry())
  if not gruntRef then
    say("FATAL: %s is not on the floor", NAME)
    return quit(2)
  end
  say("grunt found: cell=(%d,%d) id=%s poolKey=%s",
      gruntRef.cellX, gruntRef.cellY, tostring(gruntRef.id), tostring(poolKey0))

  -- ---------------------------------------------------------------- sampler
  local function inList(list, x)
    for _, v in ipairs(list or {}) do if v == x then return true end end
    return false
  end
  local function topName()
    local t = top()
    if t == ow() then return "overworld" end
    local mt = getmetatable(t)
    if mt == TextBox then return "TextBox" end
    if mt == BattleState then return "BattleState" end
    return tostring(t)
  end
  local function snapshot()
    local o = ow()
    local parts = {}
    parts[#parts + 1] = ("#scriptMoves=%d"):format(#o.scriptMoves)
    for i, mv in ipairs(o.scriptMoves) do
      local e = mv.entity
      parts[#parts + 1] = ("mv[%d]{rem=%s dir=%s name=%s moving=%s cell=(%s,%s) "
        .. "tgt=(%s,%s) prog=%s isGrunt=%s}"):format(
        i, tostring(mv.remaining), tostring(mv.dir),
        tostring(e and e.def and e.def.name), tostring(e and e.moving),
        tostring(e and e.cellX), tostring(e and e.cellY),
        tostring(e and e.targetX), tostring(e and e.targetY),
        tostring(e and e.progress), tostring(e == gruntRef))
    end
    local pk, pn = poolEntry()
    parts[#parts + 1] = ("inNpcs=%s"):format(tostring(findGrunt() ~= nil))
    parts[#parts + 1] = ("inPool=%s(key=%s,sameTable=%s)"):format(
      tostring(pn ~= nil), tostring(pk), tostring(pn == gruntRef))
    parts[#parts + 1] = ("inEntities=%s"):format(
      tostring(inList(o.entities, gruntRef)))
    parts[#parts + 1] = ("top=%s topIsOw=%s depth=%s"):format(
      topName(), tostring(top() == o), tostring(#(game.stack.states or {})))
    parts[#parts + 1] = ("runner=%s"):format(
      tostring(o.runner and o.runner:isRunning()))
    parts[#parts + 1] = ("engaging=%s transitioning=%s emote=%s"):format(
      tostring(o.engaging), tostring(o.transitioning), tostring(o.emote ~= nil))
    parts[#parts + 1] = ("player=(%s,%s)"):format(
      tostring(o.player.cellX), tostring(o.player.cellY))
    return table.concat(parts, " ")
  end

  say("BEFORE TALK: %s", snapshot())

  ------------------------------------------------------------------- battle
  local said, seenAfter, battleSeen = {}, false, nil
  local lastLine
  local function pageText()
    local t = top()
    if getmetatable(t) ~= TextBox then return "" end
    local out = {}
    for _, page in ipairs(t.pages or {}) do
      if type(page) == "table" then
        for _, line in ipairs(page) do out[#out + 1] = tostring(line) end
      end
    end
    return table.concat(out, " ")
  end

  U.tap(game, "a")
  for f = 1, 4000 do
    local t = top()
    if getmetatable(t) == BattleState then
      battleSeen = battleSeen or t
      local cur = t.current
      local text = type(cur) == "table" and cur.text
      if type(text) == "string" and text ~= lastLine then
        lastLine = text
        said[#said + 1] = text
        say("battle says: %s", (text:gsub("\n", " ")))
      end
    end
    local pt = pageText()
    if pt:find("hideout", 1, true) then seenAfter = true break end
    if t and t.phase then
      if t.phase == "menu" then t.menuIndex = 1
      elseif t.phase == "moveSelect" then t.moveIndex = 1 end
    end
    U.tap(game, "a")
    U.wait(2)
  end
  say("after-battle 'hideout' box reached: %s", tostring(seenAfter))
  say("battle result=%s", battleSeen and tostring(battleSeen.result) or "no battle")
  if E then
    say("BR after battle: phase=%s status=%s objectToggles.GAME_CORNER.%s=%s",
        tostring(E.phase()), tostring(E.status()), NAME,
        tostring((game.save.objectToggles[MAP] or {})[NAME]))
  end
  say("AT HIDEOUT BOX: %s", snapshot())

  if not seenAfter then
    say("FATAL: never reached the after-battle box; nothing to sample")
    return quit(3)
  end

  -- Dismiss it: the exit walk is queued from this box's onDone.  A box
  -- ignores A while it is still typing, so this has to keep tapping for
  -- longer than the text takes, not a fixed dozen frames.
  local closed = false
  for i = 1, 300 do
    if getmetatable(top()) ~= TextBox then closed = true break end
    U.tap(game, "a")
    U.wait(3)
    if i % 40 == 0 then
      say("closing box, tap %d: top=%s text=%q", i, topName(), pageText())
    end
  end
  say("after-battle box closed: %s (top now %s)", tostring(closed), topName())
  say("AFTER BOX CLOSED: %s", snapshot())

  ------------------------------------------------------------- 10s sampling
  local SAMPLES = 600            -- 600 game frames == 10 seconds of sim time
  local t0 = wall()
  local prev, changes, stuckSince = nil, 0, nil
  local sawZero, zeroAt = false, nil
  local hb = 0
  for i = 1, SAMPLES do
    local s = snapshot()
    if i <= 10 then
      say("f%03d %s", i, s)
    elseif s ~= prev then
      changes = changes + 1
      say("f%03d CHANGED %s", i, s)
    end
    if #ow().scriptMoves == 0 and not sawZero then
      sawZero, zeroAt = true, i
    end
    prev = s
    hb = hb + 1
    if hb >= 60 then
      hb = 0
      say("f%03d heartbeat %s", i, s)
    end
    U.wait(1)
  end
  say("sampled %d frames in %.2fs wall; distinct-state changes after f10: %d",
      SAMPLES, wall() - t0, changes)
  say("#scriptMoves hit 0 during the window: %s (frame %s)",
      tostring(sawZero), tostring(zeroAt))
  say("END OF WINDOW: %s", snapshot())

  ------------------------------------------------------------- input inject
  local o = ow()
  local bx, by = o.player.cellX, o.player.cellY
  say("INPUT: player at (%d,%d) before injection", bx, by)
  for _, dir in ipairs({ "right", "down", "left", "up" }) do
    U.hold(game, dir, 40)
    U.wait(10)
    say("INPUT: held %s 40f -> player (%d,%d) #scriptMoves=%d",
        dir, ow().player.cellX, ow().player.cellY, #ow().scriptMoves)
  end
  local ax, ay = ow().player.cellX, ow().player.cellY
  say("INPUT: player moved: %s   (%d,%d) -> (%d,%d)",
      tostring(ax ~= bx or ay ~= by), bx, by, ax, ay)

  local topBefore = topName()
  U.tap(game, "start")
  U.wait(20)
  local topAfter = topName()
  say("INPUT: START -> top was %s, now %s, menu opened: %s",
      topBefore, topAfter, tostring(topAfter ~= topBefore and topAfter ~= "overworld"))
  U.tap(game, "b")
  U.wait(10)

  say("FINAL: %s", snapshot())
  local g = findGrunt()
  say("FINAL grunt in ow.npcs: %s at (%s,%s); gruntRef cell=(%s,%s)",
      tostring(g ~= nil), g and g.cellX or "-", g and g.cellY or "-",
      tostring(gruntRef.cellX), tostring(gruntRef.cellY))
  say("VERDICT[%s]: frozen=%s (#scriptMoves=%d, runner=%s, playerMoved=%s)",
      MODE, tostring(#ow().scriptMoves > 0 and not (ax ~= bx or ay ~= by)),
      #ow().scriptMoves, tostring(ow().runner and ow().runner:isRunning()),
      tostring(ax ~= bx or ay ~= by))
  return quit(0)
end
