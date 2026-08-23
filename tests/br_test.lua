-- Standalone: luajit mods/battle_royale/tests/br_test.lua
--
-- Covers the pieces that can be tested without a display or a ROM: the wire
-- vocabulary, the engage rule, the drop picker (against a synthetic map
-- fixture so no import is needed), and lib/relay.lua driven over the
-- in-memory hub in fake_relay.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

local passed, failed = 0, 0
local function ok(cond, label)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("  FAIL: ", label, "\n") end
end
local function eq(got, want, label)
  if got ~= want then
    failed = failed + 1
    io.write(("  FAIL: %s (got %s, want %s)\n"):format(label, tostring(got), tostring(want)))
  else passed = passed + 1 end
end

local Wire = require("mods.battle_royale.lib.wire")
local Engage = require("mods.battle_royale.lib.engage")
local Relay = require("mods.battle_royale.lib.relay")
local Hub = require("mods.battle_royale.tests.fake_relay")

-- ------- wire

do
  local m = Wire.decode(Wire.place("PALLET_TOWN", 5, 6, "down", "alive", "SPRITE_RED"))
  ok(m ~= nil, "place round-trips")
  eq(m and m.status, "alive", "place carries status")
  eq(m and m.sprite, "SPRITE_RED", "place carries sprite")

  ok(Wire.decode({ t = "place", v = 999, map = "X", x = 1, y = 1, f = "up", st = "alive" }) == nil,
     "wrong protocol is refused")
  ok(Wire.decode({ t = "place", v = Wire.PROTOCOL, st = "bogus" }) == nil,
     "bad status is refused")

  local s = Wire.decode(Wire.step("up", 4, 5, "ROUTE_1"))
  eq(s and s.dir, "up", "step carries dir")
  eq(s and s.x, 4, "step carries x")

  local st = Wire.decode(Wire.start(12345, { { id = 1, map = "ROUTE_1", x = 2, y = 3 },
                                             { id = 2, map = "PALLET_TOWN", x = 4, y = 5 } }))
  ok(st ~= nil, "start round-trips")
  eq(st and #st.spawns, 2, "start carries both spawns")
  ok(Wire.decode({ t = "start", seed = 1, spawns = {} }) == nil, "empty start is refused")

  eq(Wire.decode(Wire.challenge(7)).nonce, 7, "challenge nonce")
  eq(Wire.decode(Wire.accept(7)).nonce, 7, "accept nonce")
  eq(Wire.decode(Wire.winner(3)).id, 3, "winner id")

  local lt = Wire.decode(Wire.loot({ { id = "POKE_BALL", n = 6 },
                                     { id = "POTION", n = 1 } }, 3000))
  ok(lt ~= nil, "loot round-trips")
  eq(lt and #lt.items, 2, "loot carries both stacks")
  eq(lt and lt.items[1].n, 6, "loot carries the count")
  eq(lt and lt.money, 3000, "loot carries money")
  ok(Wire.decode({ t = "loot", items = "x" }) == nil, "malformed loot refused")
  ok(Wire.decode({ t = "loot", items = { { id = "", n = 1 } } }) == nil,
     "empty item id refused")
  eq(Wire.decode({ t = "loot", items = {}, money = -5 }).money, 0,
     "negative money clamps to zero")
  eq(Wire.decode({ t = "loot", items = { { id = "X", n = 500 } } }).items[1].n, 99,
     "oversized stack clamps")
  eq(Wire.cleanName("  ab\1cdef ghi "), "abcdef", "name cleaned + capped to 7")
  eq(Wire.cleanName(nil), "PLAYER", "name falls back")

  eq(Wire.decode(Wire.botout(1001)).id, 1001, "botout carries the bot id")
  ok(Wire.decode({ t = "botout" }) == nil, "botout without an id is refused")

  local ring = Wire.decode(Wire.ring(3, 8, 9, 5.5, "CELADON CITY"))
  ok(ring ~= nil, "ring round-trips")
  eq(ring and ring.phase, 3, "ring carries the phase")
  eq(ring and ring.r, 5.5, "ring carries a fractional radius")
  eq(ring and ring.place, "CELADON CITY", "ring carries the place name")
  ok(Wire.decode({ t = "ring", phase = 1, cx = 1, cy = 1 }) == nil,
     "a ring with no radius is refused")
  ok(Wire.decode({ t = "ring", phase = 0, cx = 1, cy = 1, r = 2 }) == nil,
     "phase 0 is refused")
  ok(Wire.decode({ t = "ring", phase = 1, cx = "x", cy = 1, r = 2 }) == nil,
     "a malformed centre is refused")

  -- `as`: the host relaying a bot's movement
  eq(Wire.decode(Wire.step("up", 1, 2, "ROUTE_1", 1001)).as, 1001,
     "step carries the relayed actor")
  eq(Wire.decode(Wire.face("down", "ROUTE_1", 1001)).as, 1001,
     "face carries the relayed actor")
  eq(Wire.decode(Wire.place("ROUTE_1", 1, 2, "up", "alive", nil, 1001)).as, 1001,
     "place carries the relayed actor")
  eq(Wire.decode(Wire.step("up", 1, 2, "ROUTE_1")).as, nil,
     "an ordinary step has no actor")
  eq(Wire.decode({ t = "step", d = "up", x = 1, y = 2, as = "nope" }).as, nil,
     "a malformed actor is dropped, not trusted")
end

-- ------- bots

do
  local Bots = require("mods.battle_royale.lib.bots")

  -- the lobby ladder covers 0..MAX and always comes back to none
  eq(Bots.nextCount(0), 1, "the ladder starts at one bot")
  eq(Bots.nextCount(Bots.MAX), 0, "the ladder wraps at the cap")
  eq(Bots.nextCount(4), 5, "an off-ladder count steps to the next rung")
  local seen, n = { [0] = true }, 0
  for _ = 1, #Bots.LADDER + 1 do n = Bots.nextCount(n); seen[n] = true end
  ok(seen[Bots.MAX], "the ladder reaches the cap")
  eq(Bots.LADDER[#Bots.LADDER], Bots.MAX, "the ladder ends at the cap")

  ok(Bots.isBot(Bots.ID_BASE), "ID_BASE is a bot id")
  ok(not Bots.isBot(1), "a room id is not a bot")
  ok(not Bots.isBot(nil), "nil is not a bot")

  -- everything about a bot is derived, so two clients agree without talking
  local id = Bots.idFor(1)
  eq(Bots.name(4242, id), Bots.name(4242, id), "the name is stable for a seed")
  ok(#Bots.name(4242, id) <= 7, "the name fits the Gen 1 name box")

  -- a full roster must be all-distinct: the winner banner names one trainer
  local usedNames, dupes = {}, {}
  for i = 1, Bots.MAX do
    local nm = Bots.name(4242, Bots.idFor(i))
    if usedNames[nm] then dupes[#dupes + 1] = nm end
    usedNames[nm] = true
    ok(#nm <= 7, "bot " .. i .. " name fits the box (" .. nm .. ")")
  end
  eq(#dupes, 0, "a full roster has no duplicate names ("
     .. table.concat(dupes, ",") .. ")")

  -- and past the end of the name list too
  local wideNames, wideDupes = {}, 0
  for i = 1, 40 do
    local nm = Bots.name(7, Bots.idFor(i))
    if wideNames[nm] then wideDupes = wideDupes + 1 end
    wideNames[nm] = true
  end
  eq(wideDupes, 0, "40 bots (past the name list) stay distinct")

  local a = Bots.party(4242, id, nil)
  local b = Bots.party(4242, id, nil)
  eq(#a, #b, "the party size is stable for a seed")
  eq(a[1].species, b[1].species, "the party species is stable for a seed")
  eq(#a, 1, "a bot drops with one mon, same as a player")
  eq(a[1].level, 5, "at the starting level")
  -- the shape BattleState's trainer.party hook expects
  ok(type(a[1].species) == "string" and type(a[1].level) == "number",
     "party rows are {species, level}")

  -- a data table missing a species must not put it in a party
  local onlyRattata = Bots.party(7, id, { pokemon = { RATTATA = {} } })
  local allRattata = true
  for _, row in ipairs(onlyRattata) do
    if row.species ~= "RATTATA" then allRattata = false end
  end
  ok(allRattata, "species the build lacks are filtered out of the pool")

  -- roaming: the seams a map opens onto, which is how bots ever meet
  eq(#Bots.exits(nil), 0, "no map, no exits")
  eq(#Bots.exits({}), 0, "a map with no connections is a dead end")
  local exits = Bots.exits({ connections = { north = "VIRIDIAN_CITY",
                                             south = "PALLET_TOWN" } })
  eq(#exits, 2, "both seams are exits")
  eq(exits[1], "PALLET_TOWN", "and they come back sorted")
  eq(#Bots.exits({ connections = { north = { map = "VIRIDIAN_CITY" } } }), 1,
     "a table-shaped connection resolves too")

  -- noticing each other
  local p1 = { map = "R", x = 5, y = 5 }
  local p2 = { map = "R", x = 7, y = 5 }
  ok(Bots.near(p1, p2), "two bots a few cells apart notice each other")
  ok(not Bots.near(p1, { map = "R", x = 20, y = 5 }), "across the map they do not")
  ok(not Bots.near(p1, { map = "OTHER", x = 5, y = 5 }),
     "and never through a different map")
  ok(not Bots.near(p1, nil), "a missing bot notices nobody")
  ok(Bots.near(p1, { map = "R", x = 5, y = 6 }, 1), "the range is adjustable")

  -- wander: walled in on every side means stand still
  local bot = { map = "M", x = 5, y = 5, facing = "up" }
  local never = function() return false end
  local rng = Bots.rng(1, id)
  local moved = false
  for _ = 1, 50 do
    if Bots.wander(bot, rng, never) then moved = true end
  end
  ok(not moved, "a bot with nowhere to go never steps")

  -- hunting: given somewhere to be, it closes rather than strolls
  local always = function() return true end
  local hunter = { map = "M", x = 5, y = 5, facing = "up" }
  local rngH = Bots.rng(3, id)
  local closed = 0
  for _ = 1, 40 do
    local dir = Bots.wander(hunter, rngH, always, { x = 12, y = 5 })
    if dir == "right" then closed = closed + 1 end
  end
  ok(closed > 20, "a hunting bot mostly steps toward its target (" .. closed .. "/40)")
  -- and it will not walk into a wall to do it
  local wall = function(_, x) return x <= 5 end
  local blocked = Bots.wander({ map = "M", x = 5, y = 5, facing = "up" },
                              Bots.rng(4, id), wall, { x = 12, y = 5 })
  ok(blocked ~= "right", "but not through a wall")

  -- open field: it does move, and only ever one of the four grid directions
  local always = function() return true end
  local seen, steps = {}, 0
  local rng2 = Bots.rng(2, id)
  for _ = 1, 200 do
    local dir = Bots.wander(bot, rng2, always)
    if dir then
      steps = steps + 1
      seen[dir] = true
      ok(Bots.DELTA[dir] ~= nil, "wander returns a real direction")
    end
  end
  ok(steps > 0, "a bot in the open walks (" .. steps .. "/200 beats)")
  ok(steps < 200, "and sometimes pauses")
end

-- ------- fog

do
  local Fog = require("mods.battle_royale.lib.fog")

  -- the schedule: phase 1 covers everything, and it only ever tightens
  eq(Fog.phaseAt(0, 60), 1, "a fresh match is in phase 1")
  eq(Fog.phaseAt(59, 60), 1, "still phase 1 just before the first shrink")
  eq(Fog.phaseAt(60, 60), 2, "phase 2 on the first shrink")
  eq(Fog.phaseAt(10e6, 60), Fog.phaseCount(), "the clock stops at the last ring")
  eq(Fog.phaseAt(0, 0), Fog.phaseCount(), "a zero-length phase means final ring")
  local prev = math.huge
  for p = 1, Fog.phaseCount() do
    local r = Fog.radius(p)
    ok(r < prev, "ring " .. p .. " is tighter than the last (" .. r .. ")")
    prev = r
  end
  ok(Fog.isFinalPhase(Fog.phaseCount()), "the last phase is final")
  ok(not Fog.isFinalPhase(1), "the first phase is not")

  -- geometry on a town-map grid
  local locations = {
    HOME      = { x = 8, y = 8, name = "HOME" },
    NEXTDOOR  = { x = 9, y = 8, name = "NEXTDOOR" },
    FARAWAY   = { x = 15, y = 15, name = "FARAWAY" },
    INDOORS   = { x = 8, y = 8, name = "HOME SHOP" }, -- shares HOME's square
  }
  local center = { x = 8, y = 8, id = "HOME", name = "HOME" }
  ok(Fog.isSafe(locations, "HOME", center, 1.5), "the centre is inside")
  ok(Fog.isSafe(locations, "NEXTDOOR", center, 1.5), "one square out is inside")
  ok(not Fog.isSafe(locations, "FARAWAY", center, 1.5), "the far corner is out")
  ok(Fog.isSafe(locations, "INDOORS", center, 1.5),
     "a building is as safe as the town it stands in")
  ok(not Fog.isSafe(locations, "FARAWAY", center, 3), "still out at radius 3")
  ok(Fog.isSafe(locations, "FARAWAY", center, 15), "everything is in at phase 1")
  ok(Fog.isSafe(locations, "NOWHERE", center, 1.5),
     "a map with no square is never punished")

  ok(Fog.distanceOutside(locations, "FARAWAY", center, 1.5) > 0, "outside is positive")
  ok(Fog.distanceOutside(locations, "HOME", center, 1.5) < 0, "inside is negative")

  local safe = Fog.safeMaps(locations, { "HOME", "NEXTDOOR", "FARAWAY" }, center, 1.5)
  eq(#safe, 2, "safeMaps lists what is inside")
  eq(safe[1], "HOME", "and returns them sorted")
  eq(#Fog.safeMaps(locations, { "FARAWAY" }, center, 1.5), 1,
     "an empty result falls back to the centre")

  -- the centre is stable for a seed and is a named place
  local towns = {
    { id = "A", x = 1, y = 1, name = "ATOWN" },
    { id = "B", x = 5, y = 5, name = "BTOWN" },
    { id = "C", x = 9, y = 9, name = "CTOWN" },
  }
  local c1 = Fog.center(4242, towns)
  eq(c1.id, Fog.center(4242, towns).id, "the centre is stable for a seed")
  ok(c1.name ~= nil, "the centre is somewhere with a name")
  ok(Fog.center(1, {}) == nil, "no towns means no centre")

  -- the bite scales with the Pokemon, or level scaling would defang it:
  -- a flat point kills a Lv5 starter in a minute and a Lv100 team in twenty
  eq(Fog.bite(20), 2, "a Lv5 starter loses a tenth of its bar a tick")
  eq(Fog.bite(300), 30, "and a level 100 mon loses a tenth of its much bigger one")
  eq(Fog.bite(1), 1, "the bite is never zero")
  eq(Fog.bite(0), 1, "nor for a mon with no recorded maximum")
  local ticksSmall, ticksBig = math.ceil(20 / Fog.bite(20)), math.ceil(300 / Fog.bite(300))
  ok(math.abs(ticksSmall - ticksBig) <= 2,
     "a big team and a small one last about as long (" .. ticksSmall
     .. " vs " .. ticksBig .. " ticks)")
  eq(Fog.TICKS_TO_KILL, 10, "ten ticks from full to fainted")
  eq(Fog.TICKS_TO_KILL * Fog.TICK_SECONDS, 40,
     "which is forty seconds of standing in it")

  -- a Poison lead walks the fog unharmed
  local data = { pokemon = { ZUBAT = { types = { "POISON", "FLYING" } },
                             RATTATA = { types = { "NORMAL" } } } }
  ok(Fog.immune({ species = "ZUBAT" }, data), "a Poison type is immune")
  ok(not Fog.immune({ species = "RATTATA" }, data), "a Normal type is not")
  ok(not Fog.immune(nil, data), "no lead is not immune")
end

-- ------- the loot spill (DESIGN D8)

do
  local Spills = require("mods.battle_royale.lib.spills")

  -- an open field: the pile starts where they fell and rings outward
  local open = function() return true end
  local cells = Spills.placeAround(10, 10, 4, open)
  eq(#cells, 4, "a cell per Pokemon")
  -- never on the faller's own cell: they are still standing there, and two
  -- objects on one cell makes pressing A a coin toss between them
  for _, c in ipairs(cells) do
    ok(not (c.x == 10 and c.y == 10), "no ball on the cell they fell on")
  end
  local seen, dup = {}, false
  for _, c in ipairs(cells) do
    local k = c.x .. "," .. c.y
    if seen[k] then dup = true end
    seen[k] = true
    ok(math.abs(c.x - 10) <= 4 and math.abs(c.y - 10) <= 4, "and stays nearby")
  end
  ok(not dup, "no two Pokemon share a cell")

  -- a wall means fewer places to put them, not a crash
  local onlyOne = function(x, y) return x == 11 and y == 10 end
  eq(#Spills.placeAround(10, 10, 4, onlyOne), 1,
     "a spill with one free cell drops one ball")
  eq(#Spills.placeAround(10, 10, 4, function(x, y) return x == 10 and y == 10 end), 0,
     "and the faller's own cell does not count as free")
  eq(#Spills.placeAround(10, 10, 4, function() return false end), 0,
     "nowhere to put them is empty, not an error")

  -- the wire payload
  local party = { { species = "RATTATA", level = 12, hp = 0 },
                  { species = "PIDGEY", level = 15, hp = 3 } }
  local spill = Spills.build(7, "ROUTE_1", 5, 5, party, open)
  ok(spill ~= nil, "a fallen party becomes a spill")
  eq(spill.map, "ROUTE_1", "on the map they fell on")
  eq(#spill.mons, 2, "one ball per Pokemon")
  eq(spill.mons[1].species, "RATTATA", "carrying the species")
  eq(spill.mons[1].level, 12, "and the level it had grown to")
  ok(spill.mons[1].key ~= spill.mons[2].key, "keys are distinct")
  ok(spill.mons[1].key:find("7", 1, true) ~= nil, "and namespaced by owner")
  ok(Spills.build(7, "ROUTE_1", 5, 5, {}, open) == nil, "an empty party spills nothing")

  -- round-trips, and survives a hostile row
  local decoded = Wire.decode(Wire.spill(spill.map, spill.mons))
  ok(decoded ~= nil, "spill round-trips")
  eq(#decoded.mons, 2, "with both balls")
  eq(decoded.mons[1].level, 12, "and the level")
  ok(Wire.decode({ t = "spill", map = "R", mons = { { key = "", x = 1, y = 1,
     species = "RATTATA" } } }) == nil, "a keyless ball is refused")
  ok(Wire.decode({ t = "spill", map = "R", mons = {} }) == nil,
     "an empty spill is refused")
  eq(Wire.decode(Wire.took("7:1")).key, "7:1", "took carries the key")
  ok(Wire.decode({ t = "took" }) == nil, "took without a key is refused")

  -- the table: add, claim, gone
  local fake = { world = { removeNpc = function() return true end,
                           spawnNpc = function() return "npc1" end } }
  local s = Spills.new(fake)
  s:add(spill)
  eq(s:count(), 2, "both balls are remembered")
  ok(s:get(spill.mons[1].key) ~= nil, "and findable by key")
  s:take(spill.mons[1].key)
  eq(s:count(), 1, "claiming one removes it")
  ok(s:get(spill.mons[1].key) == nil, "for good")
  s:clear()
  eq(s:count(), 0, "and a match end clears the rest")
end

-- ------- level scaling

do
  local Levels = require("mods.battle_royale.lib.levels")
  local Fog = require("mods.battle_royale.lib.fog")

  eq(Levels.rungs(), Fog.phaseCount(),
     "one level rung per fog phase -- one clock, not two")
  eq(Levels.at(1), 5, "the drop is the starting level")
  eq(Levels.at(Levels.rungs()), Levels.MAX, "the last ring is level 100")
  eq(Levels.at(0), 5, "a phase below the ladder clamps to the drop")
  eq(Levels.at(999), Levels.MAX, "a phase past the ladder clamps to the cap")
  local prev = 0
  for p = 1, Levels.rungs() do
    local lv = Levels.at(p)
    ok(lv > prev, "rung " .. p .. " is higher than the last (" .. lv .. ")")
    prev = lv
  end

  ok(Levels.needsScaling({ level = 5 }, 30), "a Lv5 mon scales up to 30")
  ok(not Levels.needsScaling({ level = 50 }, 30),
     "scaling never demotes a mon that is already past the rung")
  ok(not Levels.needsScaling(nil, 30), "no mon needs no scaling")

  -- a bot's team is built at the rung it is fought at
  local Bots = require("mods.battle_royale.lib.bots")
  local low = Bots.party(1, Bots.idFor(1), nil, 5)
  local high = Bots.party(1, Bots.idFor(1), nil, 75)
  eq(low[1].species, high[1].species, "scaling does not reroll the species")
  eq(low[1].level, 5, "a bot at the drop is level 5")
  eq(high[1].level, 75, "and level 75 in the fifth ring")
  eq(Bots.party(1, Bots.idFor(1), nil, 999)[1].level, 100, "clamped to 100")
  eq(Bots.party(1, Bots.idFor(1), nil)[1].level, 5, "defaulting to the drop")
end

-- ------- engage

do
  -- me at (5,5) facing right; target on (6,5)
  local me = { id = 2, map = "R", x = 5, y = 5, facing = "right", moving = false, status = "alive" }
  local a = { id = 5, map = "R", x = 6, y = 5, facing = "left", moving = false, status = "alive" }
  eq(Engage.target(me, { a }), 5, "faces adjacent alive trainer -> target")

  -- the eyeline reaches (DESIGN D10), and stops where it should
  eq(Engage.RANGE, 6, "the eyeline is six cells")
  for step = 1, Engage.RANGE do
    a.x = 5 + step
    eq(Engage.target(me, { a }), 5, "spotted " .. step .. " cells down the line")
  end
  a.x = 5 + Engage.RANGE + 1
  ok(Engage.target(me, { a }) == nil, "one cell past the range is not spotted")

  -- sight does not bend: off the facing axis is invisible at any distance
  a.x, a.y = 8, 6
  ok(Engage.target(me, { a }) == nil, "a trainer off the axis is not spotted")
  a.y = 5

  -- terrain stops it
  local wallAt7 = function(x) return x == 7 end
  a.x = 6
  eq(Engage.target(me, { a }, { blocked = wallAt7 }), 5,
     "someone in front of the wall is still spotted")
  a.x = 9
  ok(Engage.target(me, { a }, { blocked = wallAt7 }) == nil,
     "someone behind a wall is not")
  eq(#Engage.sightLine(me, 6, wallAt7), 2,
     "the line stops on the blocking cell itself")
  eq(#Engage.sightLine(me, 6), 6, "an unobstructed line runs the full range")

  -- the nearest body on the line is the one engaged
  local near = { id = 9, map = "R", x = 6, y = 5, facing = "left",
                 moving = false, status = "alive" }
  local far = { id = 3, map = "R", x = 9, y = 5, facing = "left",
                moving = false, status = "alive" }
  eq(Engage.target(me, { far, near }), 9,
     "the closer trainer is engaged even with a lower id further off")
  a.x = 6

  a.status = "out"
  ok(Engage.target(me, { a }) == nil, "eliminated player is not a target")
  a.status = "alive"; a.moving = true
  ok(Engage.target(me, { a }) == nil, "moving player is not a target")
  a.moving = false; a.map = "OTHER"
  ok(Engage.target(me, { a }) == nil, "player on another map is not a target")
  a.map = "R"; me.facing = "left"
  ok(Engage.target(me, { a }) == nil, "not facing them -> no target")

  eq(Engage.isHost(2, 5), true, "lower id hosts")
  eq(Engage.isHost(5, 2), false, "higher id does not host")

  -- lowest id wins when two candidates are somehow on the same cell
  me.facing = "right"
  local b = { id = 3, map = "R", x = 6, y = 5, facing = "left", moving = false, status = "alive" }
  eq(Engage.target(me, { a, b }), 3, "ties break to the lower id")

  eq(Engage.answer({ status = "alive" }, 5, nil), "accept", "idle player accepts")
  eq(Engage.answer({ status = "battle" }, 5, nil), "busy", "in-battle player is busy")
  eq(Engage.answer({ status = "alive" }, 5, { to = 9 }), "busy",
     "player pending with someone else is busy")
  eq(Engage.answer({ status = "alive" }, 5, { to = 5 }), "accept",
     "a challenge from the one we are challenging is accepted")
end

-- ------- spawn (against the real imported data when it is present)
-- Spawn leans on src.world.Map's real tileset semantics, so a faithful
-- synthetic fixture would have to reproduce the whole tileset format.  We
-- test it against the generated Kanto data instead, and skip cleanly when
-- no ROM has been imported (CI, a fresh checkout) so the suite still passes.

do
  local okData, maps = pcall(dofile, "data/generated/maps.lua")
  local okTs, tilesets = pcall(dofile, "data/generated/tilesets.lua")
  local okMap = pcall(require, "src.world.Map")
  if not (okData and okTs and okMap and type(maps) == "table") then
    io.write("  (skipping spawn: no imported data / Map unavailable headless)\n")
  else
    local Spawn = require("mods.battle_royale.lib.spawn")
    local outdoor = Spawn.outdoorMaps(maps)
    ok(#outdoor > 0, "found outdoor Kanto maps (" .. #outdoor .. ")")

    local drops, err = Spawn.pick(maps, tilesets, 8, Spawn.rng(42))
    ok(drops ~= nil, "picks 8 drops (" .. tostring(err) .. ")")
    if drops then
      eq(#drops, 8, "one drop per player")
      local seen, unique, allOutdoor = {}, true, true
      for _, d in ipairs(drops) do
        local key = d.map .. ":" .. d.x .. ":" .. d.y
        if seen[key] then unique = false end
        seen[key] = true
        if not maps[d.map] then allOutdoor = false end
      end
      ok(unique, "no two players share a cell")
      ok(allOutdoor, "every drop is on a real map")
      -- determinism: same seed -> same first drop
      local again = Spawn.pick(maps, tilesets, 8, Spawn.rng(42))
      eq(again and again[1].map, drops[1].map, "same seed reproduces the drop map")
      eq(again and again[1].x, drops[1].x, "same seed reproduces the drop cell")
    end
  end
end

-- ------- relay round-trip over the in-memory hub

do
  local hub = Hub.new()
  local host = Relay.new({ transport = hub:connect() })
  local guest = Relay.new({ transport = hub:connect() })

  local hostJoined, guestJoined = false, false
  local hostRoster, guestRoster = nil, nil
  local hostInbox, guestInbox = {}, {}
  host:on("joined", function() hostJoined = true end)
  host:on("roster", function(m) hostRoster = m end)
  host:on("message", function(from, m) hostInbox[#hostInbox + 1] = { from = from, m = m } end)
  guest:on("joined", function() guestJoined = true end)
  guest:on("roster", function(m) guestRoster = m end)
  guest:on("message", function(from, m) guestInbox[#guestInbox + 1] = { from = from, m = m } end)

  host:host("RED")
  host:update()
  ok(hostJoined, "host reaches the lobby")
  eq(host.code, "ROOM01", "host gets a code")
  ok(host:isHost(), "host is the host")

  guest:join("ROOM01", "BLUE")
  guest:update()
  host:update()
  ok(guestJoined, "guest reaches the lobby")
  ok(not guest:isHost(), "guest is not the host")
  eq(guestRoster and #guestRoster, 2, "guest sees both members")
  eq(hostRoster and #hostRoster, 2, "host sees both members")
  eq(guest.hostId, host.id, "guest knows who the host is")

  -- broadcast a place from the host; the guest receives it
  host:broadcast(Wire.place("ROUTE_1", 3, 4, "down", "alive", "SPRITE_RED"))
  guest:update()
  eq(#guestInbox, 1, "guest received the broadcast")
  local decoded = Wire.decode(guestInbox[1].m)
  eq(decoded and decoded.map, "ROUTE_1", "the broadcast decodes")
  eq(guestInbox[1].from, host.id, "and is attributed to the host")

  -- unicast a challenge from guest to host
  guest:send(host.id, Wire.challenge(1))
  host:update()
  eq(#hostInbox, 1, "host received the unicast")
  eq(Wire.decode(hostInbox[1].m).nonce, 1, "the challenge decodes")

  -- guest leaving closes their side and updates the host roster
  guest:leave()
  host:update()
  eq(hostRoster and #hostRoster, 1, "host roster shrinks when the guest leaves")
end

-- ------------------------------------------------------------------
-- the room with nobody in it: solo play without a server
-- ------------------------------------------------------------------
do
  local LocalRoom = require("mods.battle_royale.lib.localroom")

  local relay = Relay.new({ transport = LocalRoom.new() })
  local joined, roster = false, nil
  relay:on("joined", function() joined = true end)
  relay:on("roster", function(m) roster = m end)
  relay:on("message", function() ok(false, "a room of one delivered a message") end)
  relay:on("closed", function(r) ok(false, "the local room closed: " .. tostring(r)) end)

  ok(relay:host("LONER"), "hosting a local room succeeds with no server")
  relay:update()
  ok(relay:isOpen(), "the local room reaches the lobby")
  ok(joined, "and reports joined")
  ok(relay:isHost(), "the one member is the host")
  eq(roster and #roster, 1, "the roster is a room of one")
  eq(roster and roster[1].name, "LONER", "under the name we gave")

  -- broadcasting into an empty room is a no-op rather than an error, which
  -- is exactly what lets every match path above run solo unchanged
  ok(relay:broadcast(Wire.place("ROUTE_1", 1, 2, "down", "alive", "SPRITE_RED")),
     "broadcasting into an empty room is accepted")
  ok(relay:send(99, Wire.challenge(1)), "so is a unicast to nobody")
  relay:update()

  -- it has to answer its own pings, or the silence timeout would make a solo
  -- match disconnect itself partway through
  relay.lastPing = -1000
  relay:update()
  ok(relay.lastHeard > 0, "its pong refreshes the silence timer")
  relay.lastPing = -1000
  relay:update()
  ok(relay:isOpen(), "the local room stays open across ping cycles")

  -- there is no other room to join
  local j = Relay.new({ transport = LocalRoom.new() })
  local closedWith = nil
  j:on("closed", function(r) closedWith = r end)
  j:join("ABC123", "NOBODY")
  j:update()
  ok(closedWith ~= nil, "joining a code with no server fails cleanly")
end

-- ------------------------------------------------------------------
-- FILL TO: a roster target that bots make up the shortfall in
-- ------------------------------------------------------------------
do
  local Bots = require("mods.battle_royale.lib.bots")

  eq(Bots.FILL[1], 0, "the fill ladder starts at off")
  eq(Bots.FILL[2], 2, "and then at two, because a match of one is over")
  eq(Bots.FILL[#Bots.FILL], Bots.MAX + 1, "and tops out at a full bot roster")
  eq(Bots.nextFill(0), 2, "off steps to two")
  eq(Bots.nextFill(8), 12, "and climbs the ladder")
  eq(Bots.nextFill(Bots.MAX + 1), 0, "and wraps back to off")

  -- the arithmetic the lobby does: whichever of the two knobs wants more
  local function botsFor(botCount, fillTo, humans)
    local want = botCount
    if fillTo > 0 then want = math.max(want, fillTo - humans) end
    return math.max(0, math.min(want, Bots.MAX))
  end
  eq(botsFor(0, 8, 1), 7, "alone, a target of eight is seven bots")
  eq(botsFor(0, 8, 3), 5, "three humans need only five")
  eq(botsFor(0, 8, 8), 0, "a full lobby of humans needs none")
  eq(botsFor(0, 8, 12), 0, "and an over-full one does not go negative")
  eq(botsFor(4, 8, 6), 4, "an explicit BOTS count is a floor, not a ceiling")
  eq(botsFor(0, 0, 1), 0, "fill off means the BOTS row alone decides")
  eq(botsFor(99, 0, 1), Bots.MAX, "and the roster never exceeds the bot cap")
end


-- ------------------------------------------------------------------
-- the SERVER... widget has to be able to hold a hosted relay's address
-- ------------------------------------------------------------------
do
  local CodeEntry = require("src.link.CodeEntry")
  -- Entry.ADDRESS without pulling in the screen (which wants love + a game)
  local ADDRESS = { charset = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:",
                    length = 40 }

  local function roundTrip(text)
    local state = CodeEntry.fromText(text:upper(), ADDRESS)
    return (CodeEntry.text(state):gsub("%s+$", ""):gsub("^%s+", "")):lower()
  end

  -- a managed host: letters, dots, a hyphen and a five-digit port.  This is
  -- the case the old 21-slot digits-only shape could not express at all.
  eq(roundTrip("roundhouse.proxy.rlwy.net:23456"),
     "roundhouse.proxy.rlwy.net:23456", "a hosted relay hostname round-trips")
  eq(roundTrip("br-relay-production.up.railway.app:7790"),
     "br-relay-production.up.railway.app:7790",
     "and a longer one with a hyphen in it")
  eq(#("br-relay-production.up.railway.app:7790") <= ADDRESS.length, true,
     "the widget is long enough for a real managed hostname")
  -- the old cases still work
  eq(roundTrip("127.0.0.1:7790"), "127.0.0.1:7790", "a dotted IPv4 still round-trips")
  eq(roundTrip("10.0.0.5:7790"), "10.0.0.5:7790", "and a short one")
  -- blank is the first slot, so an untouched widget is empty rather than AAAA
  eq(CodeEntry.text(CodeEntry.new(ADDRESS)):gsub("%s", ""), "",
     "a fresh address entry starts blank")
end


io.write(("\nbattle royale: %d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
