-- POK-160: a bot picks its fights, and its brain rides its tier.
--
-- Three probes, staged in Pewter with the player as bait:
--
--   1. STAND DOWN: a bot scarred to 20% shares our map -- prey it would
--      have stalked yesterday.  It must NOT open a fight; it must walk
--      to the Centre and come back whole (the nurse -- quaffing is off
--      wherever a Centre is standing).
--   2. THE HUNT RESUMES: healed, the same bot must stalk us down and
--      open the fight on its own.
--   3. THE BRAIN: the battle it opens must carry the aiClass its tier
--      deals (Bots.fightAI) whatever face it wears, with aiUses re-asked
--      off that brain -- not baked off the face's class.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-fight-picking POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/fight_picking_smoke.lua \
--   <path to>/lovec . > fight_picking.log 2>&1
--
-- Exit 0 with a `PICKING OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("BAIT")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(6)
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

  -- the target: any bot whose tier deals a brain (P(none of six) ~ 1.5%)
  local Bots = require("mods.battle_royale.lib.bots")
  local seed = E.matchSeed()
  if not seed then return C.fail("no match seed") end
  local target, brain
  for _, b in ipairs(E.bots() or {}) do
    local ai = Bots.fightAI(seed, b.id)
    if ai then target, brain = b, ai break end
  end
  if not target then
    return C.fail("all six bots came up ROOKIE (unlucky seed; rerun)")
  end
  U.log(("PICKING: target %s wears %s and fights as %s")
    :format(tostring(target.name), tostring(target.class), brain))

  -- bait goes to Pewter; the target follows, everyone else parks far away
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not reach Pewter; at " .. tostring(C.map()))
  end
  U.wait(30)
  local DOOR = { x = 14, y = 26 }   -- the PEWTER_POKECENTER door's step cell
  local Spawn = require("mods.battle_royale.lib.spawn")
  local cells = Spawn.cellsOf(game.data.maps.PEWTER_CITY,
                              game.data.tilesets[game.data.maps.PEWTER_CITY.tileset],
                              game.data.maps, game.data.tilesets)
  -- Our perch: far from the door, with a wall directly south, because
  -- tryEngage runs every tick -- a player whose eyeline crossed the
  -- healing bot would open the very fight probe 1 asserts against
  -- (jumping a wounded bot is allowed on purpose).  Facing the wall
  -- keeps our eyeline out of the picture entirely.
  -- ...and BFS-reachable from the door: walkable is not reachable
  -- (POK-23), and a perch on the museum bluff left the stalk wandering
  -- at a cliff for the whole probe
  local function canWalk(x, y)
    return Spawn.walkable(game.data.maps, game.data.tilesets,
                          "PEWTER_CITY", x, y)
  end
  local perch
  for _, c in ipairs(cells) do
    local toDoor = math.abs(c.x - DOOR.x) + math.abs(c.y - DOOR.y)
    if toDoor >= 12 and toDoor <= 20
       and not canWalk(c.x, c.y + 1)
       and Bots.path(canWalk, DOOR, { x = c.x, y = c.y }, 4000) then
      perch = c
      break
    end
  end
  if not perch then return C.fail("no walled perch far from the Centre") end
  if not L.goTo(C, "PEWTER_CITY", perch.x, perch.y, 400) then
    return C.fail(("never reached the perch at %d,%d; at %s,%s")
      :format(perch.x, perch.y, tostring(C.x()), tostring(C.y())))
  end
  local ow = C.ow()
  for _ = 1, 20 do
    if ow.player.facing == "down" then break end
    U.hold(game, "down", 2)
    U.wait(8)
  end
  local px, py = perch.x, perch.y
  local stand
  for _, c in ipairs(cells) do
    local toUs = math.abs(c.x - px) + math.abs(c.y - py)
    local toDoor = math.abs(c.x - DOOR.x) + math.abs(c.y - DOOR.y)
    if toUs >= 8 and toDoor >= 2 and toDoor <= 8 then
      if not stand or toDoor < stand.toDoor then
        stand = { x = c.x, y = c.y, toDoor = toDoor }
      end
    end
  end
  if not stand then return C.fail("no Pewter cell out of our eyeline near the door") end

  local function park()
    -- the rest of the roster stays a region away, spread out so no two
    -- of them go adjacent and thin each other mid-probe
    local slot = 0
    for _, b in ipairs(E.bots() or {}) do
      if b.id ~= target.id and b.status == "alive" then
        E.debugPlaceBot(b.id, "LAVENDER_TOWN", 5 + slot * 4, 5)
        slot = slot + 1
      end
    end
  end
  local function targetHere()
    for _, b in ipairs(E.bots() or {}) do
      if b.id == target.id then return b end
    end
    return nil
  end

  -- probe 1: scarred, with bait on its map, it heals instead of hunting
  if not E.debugScarBot(target.id, 0.2) then
    return C.fail("could not scar the target")
  end
  E.debugPlaceBot(target.id, "PEWTER_CITY", stand.x, stand.y)
  -- Real-time budgets: bot clocks run on love.timer whatever the frame
  -- rate, and a frame-counted wait at speed 3 burns through "minutes" of
  -- labels in seconds of walking (run 2-5 of this driver, POK-160).
  local t0 = love.timer.getTime()
  local lastSay = t0
  local whole = false
  while love.timer.getTime() - t0 < 90 do
    park()
    local b = targetHere()
    if not b or b.status ~= "alive" then return C.fail("lost the target mid-heal") end
    if b.map ~= "PEWTER_CITY" then
      E.debugPlaceBot(target.id, "PEWTER_CITY", stand.x, stand.y)
    end
    if E.status() == "battle" then
      return C.fail("a wrecked bot still picked a fight")
    end
    local e = E.tickError()
    if e then return C.fail("tick error mid-heal: " .. tostring(e)) end
    local rec = E.botRecord(target.id)
    whole = rec and #rec > 0
    for _, m in ipairs(rec or {}) do
      if (m.hpFrac or 0) < 1 then whole = false break end
    end
    if whole then break end
    if love.timer.getTime() - lastSay >= 15 then
      lastSay = love.timer.getTime()
      local worst = 1
      for _, m in ipairs(rec or {}) do
        if (m.hpFrac or 1) < worst then worst = m.hpFrac end
      end
      U.log(("PICKING: standing down (%.0fs, worst %d%%, bot %s %s,%s)")
        :format(lastSay - t0, math.floor(worst * 100),
                tostring(b.map), tostring(b.x), tostring(b.y)))
    end
    U.wait(30)
  end
  if not whole then
    return C.fail("ninety real seconds hurt and it never reached the nurse")
  end
  U.log("PICKING: it stood down and healed with bait on its map")

  -- probe 2: healed, the stalk resumes and IT opens the fight
  local opened = false
  t0 = love.timer.getTime()
  lastSay = t0
  while love.timer.getTime() - t0 < 120 do
    park()
    if E.status() == "battle" then opened = true break end
    local b = targetHere()
    if not b or b.status ~= "alive" then return C.fail("lost the target mid-stalk") end
    if b.map ~= "PEWTER_CITY" then
      E.debugPlaceBot(target.id, "PEWTER_CITY", stand.x, stand.y)
    end
    local e = E.tickError()
    if e then return C.fail("tick error mid-stalk: " .. tostring(e)) end
    if love.timer.getTime() - lastSay >= 15 then
      lastSay = love.timer.getTime()
      local row
      for _, r in ipairs((E.debugFightProbe() or {}).bots or {}) do
        if r.id == target.id then row = r break end
      end
      U.log(("PICKING: waiting on the stalk (%.0fs, bot %s,%s us %s,%s, hunting=%s pathLeft=%s)")
        :format(lastSay - t0, tostring(b.x), tostring(b.y),
                tostring(C.x()), tostring(C.y()),
                tostring(row and row.hunting), tostring(row and row.pathLeft)))
    end
    U.wait(30)
  end
  if not opened then
    return C.fail("healed, with bait in sight for two real minutes, and it never engaged")
  end
  U.log("PICKING: healed, it hunted us down")

  -- probe 3: the battle carries the tier's brain, not the face's
  local battle
  for _ = 1, 200 do
    local top = game.stack:top()
    if type(top) == "table" and top.trainer and top.aiUses ~= nil then
      battle = top
      break
    end
    U.wait(3)
  end
  if not battle then return C.fail("the fight opened but no battle surfaced") end
  if battle.trainer.aiClass ~= brain then
    return C.fail(("brain mismatch: wanted %s, battle carries %s")
      :format(tostring(brain), tostring(battle.trainer.aiClass)))
  end
  local uses = require("data.scripts.ai_classes")[brain].uses
  if battle.aiUses ~= uses then
    return C.fail(("aiUses %s but the %s brain deals %s -- baked off the face?")
      :format(tostring(battle.aiUses), brain, tostring(uses)))
  end
  -- ...and the move layer is wired: last aiMods entry is the mod's own
  -- scoring pass, and the merged registry resolves it to a score fn
  local mods = battle.enemyAIMods or {}
  if mods[#mods] ~= "BR_BOT_MOVES" then
    return C.fail(("aiMods end with %s, not BR_BOT_MOVES -- baked off the face?")
      :format(tostring(mods[#mods])))
  end
  local rec = battle.data and battle.data.ai_classes
    and battle.data.ai_classes.BR_BOT_MOVES
  if not (rec and type(rec.score) == "function") then
    return C.fail("BR_BOT_MOVES is named but the registry cannot resolve it")
  end
  U.log(("PICKING OK: stood down hurt, hunted healed, fights as %s (aiUses %d) and picks its moves")
    :format(brain, uses))
  love.event.quit(0)
  U.wait(30)
end
