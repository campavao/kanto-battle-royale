-- POK-85 / POK-89 smoke: what a bot looks like, and what it does before it
-- fights you.
--
-- Stages an engage instead of waiting for one: host a solo room, drop a bot
-- a few cells away with debugPlaceBot, face it, and let the eyeline do the
-- rest.  Then check the three things the playtest complained about:
--
--   1. the bot wears a face of its own, not the local player's skin
--      (every bot used to inherit whatever the VIEWER was wearing),
--   2. it WALKS OVER before the battle rather than fighting from range, and
--   3. the battle carries the bot's name from the intro on, not its class.
--
-- One client, no relay server -- a solo room is a LocalRoom.  Run from a
-- gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bot-smoke POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bot_smoke.lua \
--   <path to>/lovec . > bot.log 2>&1
--
-- Exit 0 with a `BOT OK` line passes; any `PVP FAIL` line fails (the failure
-- channel comes from pvplib, shared with the two-client pair).  Set
-- BR_SHOTS=<dir> for screenshots of the walk and the battle intro.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")
local Skins = require("mods.battle_royale.lib.skins")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end

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

  -- Stage this somewhere KNOWN.  The drop is random, and half of Kanto is
  -- a bad arena for an eyeline test -- Route 19 is water, Pallet is twenty
  -- cells wide, Route 12 is a corridor of ledges.  Pewter's street is the
  -- same clear line the two-client duel uses, so borrow it.
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)
  local ow = C.ow()
  local myMap, myX, myY = C.map(), C.x(), C.y()
  U.log(("BOT: posted on %s at %s,%s"):format(
    tostring(myMap), tostring(myX), tostring(myY)))

  -- ---------------------------------------------------------------- 1. faces
  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots in the match") end
  local mine = E.skinState() and E.skinState().walk
  local wardrobe = {}
  for _, e in ipairs(Skins.LADDER) do wardrobe[e.walk] = true end
  local known = {}
  for _, e in ipairs(Bots.LOOKS) do known[e.walk] = e.class end
  local faces = {}
  for _, b in ipairs(roster) do
    if not b.sprite then
      return C.fail("bot " .. tostring(b.name) .. " has no face of its own")
    end
    if b.sprite == mine and wardrobe[b.sprite] then
      return C.fail(("bot %s is wearing MY skin (%s)"):format(
        tostring(b.name), tostring(b.sprite)))
    end
    if not known[b.sprite] then
      return C.fail(("bot %s wears %s, which is not a bot look"):format(
        tostring(b.name), tostring(b.sprite)))
    end
    if b.class ~= known[b.sprite] then
      return C.fail(("bot %s: sheet %s but class %s"):format(
        tostring(b.name), tostring(b.sprite), tostring(b.class)))
    end
    faces[#faces + 1] = b.sprite
  end
  U.log("BOT: roster faces " .. table.concat(faces, ", ") ..
        " (mine is " .. tostring(mine) .. ")")

  -- ------------------------------------------------------- 2. the walk over
  -- Staging an engage means putting the bot on a line the ENGINE agrees
  -- is clear: Engage.target blocks sight on map:isWalkableCell, so a lane
  -- picked with the mod's own Spawn.walkable can disagree and the bot is
  -- simply never seen.  (The first attempt also put one at x=22 of a
  -- 20-wide Pallet Town.)  And a placed bot keeps roaming, so it can walk
  -- out of the lane before the eyeline catches it -- hence the retry.
  local victim = roster[1]
  local map = ow and ow.map
  if not map then return C.fail("no map to stage on") end
  local function clear(x, y)
    return map:inBounds(x, y) and map:isWalkableCell(x, y)
  end
  local DIRS = {
    { dir = "right", dx = 1,  dy = 0,  reach = 6 },
    { dir = "left",  dx = -1, dy = 0,  reach = 6 },
    { dir = "down",  dx = 0,  dy = 1,  reach = 4 },
    { dir = "up",    dx = 0,  dy = -1, reach = 4 },
  }
  -- Prefer the way we are ALREADY facing.  A driver's "turn" is a held
  -- direction, and a held direction in Gen 1 turns you on one frame and
  -- walks you on the next -- so turning to face a lane can also step into
  -- it, which is how an earlier attempt ended up staring down a lane it
  -- had left.  The eyeline only ever looks where the player faces.
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
    -- nothing down our nose: turn, then take our real position from the
    -- world rather than assuming the turn cost us nothing
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
    return C.fail(("no clear eyeline from %s,%s facing %s on %s"):format(
      tostring(myX), tostring(myY), tostring(facing), tostring(myMap)))
  end

  local bx = myX + lane.d.dx * lane.gap
  local by = myY + lane.d.dy * lane.gap
  local fromX, fromY = myX, myY
  local startD = math.abs(bx - fromX) + math.abs(by - fromY)
  U.log(("BOT: facing %s from %d,%d; lane cell %d,%d (range %d)"):format(
    tostring(lane.d.dir), fromX, fromY, bx, by, startD))
  local function botAt()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == victim.id then return b end
    end
    return nil
  end

  -- hold it in the lane until the eyeline takes; once the stride begins
  -- the roam has let go of it (tickBots skips a bot that is walking over)
  local striding = false
  for attempt = 1, 40 do
    if E.status() == "battle" or E.walkUp() then striding = true break end
    E.debugPlaceBot(victim.id, myMap, bx, by)
    for _ = 1, 15 do
      if E.status() == "battle" or E.walkUp() then striding = true break end
      U.wait(4)
    end
    if striding then break end
    if attempt % 10 == 0 then
      U.log(("BOT: still staging (%d); bot at %s"):format(attempt,
        tostring((botAt() or {}).x)))
    end
  end
  if not striding then
    local b = botAt()
    return C.fail(("the eyeline never caught it (bot %s,%s me %s,%s status %s)"):format(
      tostring(b and b.x), tostring(b and b.y), tostring(C.x()), tostring(C.y()),
      tostring(E.status())))
  end
  U.log(("BOT: %s spotted at range %d; watching it come"):format(
    tostring(victim.name), startD))

  -- now watch it close.  The stride is the whole point: a bot that fought
  -- from where it stood is the bug.
  local started, closest, sawStride = false, startD, false
  for _ = 1, 600 do
    local w = E.walkUp()
    if w and (w.steps or 0) > 0 then sawStride = true end
    local b = botAt()
    local mx, my = C.x() or fromX, C.y() or fromY
    if b and b.map == myMap then
      local d = math.abs(b.x - mx) + math.abs(b.y - my)
      if d < closest then closest = d end
    end
    if E.status() == "battle" then started = true break end
    U.wait(3)
  end
  if not started then
    return C.fail(("the fight never started (closest %d, stride %s)"):format(
      closest, tostring(sawStride)))
  end
  if not sawStride then
    return C.fail(("no walk over: it fought from range %d"):format(startD))
  end
  if closest >= startD then
    return C.fail(("it strode but never got closer (%d -> %d)"):format(
      startD, closest))
  end
  U.log(("BOT: %s walked in from %d to %d before the fight"):format(
    tostring(victim.name), startD, closest))
  shot("walkup")

  -- --------------------------------------------------------- 3. the name
  -- the battle is the state on the stack carrying a trainer
  local battle
  for _ = 1, 200 do
    local top = game.stack:top()
    if type(top) == "table" and top.trainer and top.enemy then battle = top break end
    U.wait(5)
  end
  if not battle then return C.fail("the bot battle never reached the stack") end
  shot("intro")

  local shown = tostring(battle.trainer and battle.trainer.name)
  if shown ~= victim.name then
    return C.fail(("the battle calls it %s, not %s"):format(shown, tostring(victim.name)))
  end
  -- the intro line is BAKED by newTrainer before the mod can overlay the
  -- name -- this is the one that used to say YOUNGSTER all the way to the
  -- defeat text
  local intro = tostring(battle.introText or "")
  if not intro:find(victim.name, 1, true) then
    return C.fail(("the intro reads %q, without %s"):format(intro, tostring(victim.name)))
  end
  local classWord = tostring(victim.class or ""):gsub("^OPP_", "")
  if classWord ~= "" and intro:find(classWord, 1, true) then
    return C.fail(("the intro still fronts the class: %q"):format(intro))
  end
  U.log(("BOT OK: %s wore %s, walked in, and the intro reads %q"):format(
    tostring(victim.name), tostring(victim.sprite), intro))
  love.event.quit(0)
  U.wait(10)
end
