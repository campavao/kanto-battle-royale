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

  -- the Safari opening (POK-21): start carries the round, beats carry the clock
  eq(Wire.PROTOCOL, 6, "peeking at the watched trainer is PROTOCOL 6")
  eq(Wire.decode(Wire.peek()).t, "peek", "peek round-trips")
  local st6 = Wire.decode(Wire.state({
    party = { { species = "PIDGEY", level = 12, hp = 23, maxHp = 40, status = "PSN",
                moves = { "GUST", "SAND_ATTACK", "QUICK_ATTACK", "WHIRLWIND", "TOO_MANY" } } },
    items = { { id = "POTION", n = 2 } }, money = 500 }))
  ok(st6 ~= nil, "state round-trips")
  eq(st6 and #st6.party, 1, "with the party")
  eq(st6 and st6.party[1].hp .. "/" .. st6.party[1].maxHp, "23/40", "HP and max")
  eq(st6 and st6.party[1].status, "PSN", "the status")
  eq(st6 and #st6.party[1].moves, 4, "at most four moves")
  eq(st6 and st6.items[1].n, 2, "the bag")
  eq(st6 and st6.money, 500, "and the money")
  ok(Wire.decode({ t = "state", party = "x" }) == nil, "a state without a party is refused")
  ok(Wire.decode({ t = "state", party = { { sp = "" } } }) == nil, "and a nameless row")
  eq(Wire.decode({ t = "state", party = { { sp = "MEW", lv = 900, hp = -5 } }, money = -1 }).party[1].level,
     100, "levels clamp")
  eq(Wire.decode(Wire.again()).t, "again", "again round-trips")
  local safariStart = Wire.decode(Wire.start(7,
    { { id = 1, map = "SAFARI_ZONE_CENTER", x = 2, y = 3 } }, 120))
  ok(safariStart ~= nil, "a start with a Safari round decodes")
  eq(safariStart and safariStart.safari, 120, "carrying the round's length")
  eq(st and st.safari, 0, "no round is 0, not nil")
  ok(Wire.decode({ t = "start", seed = 7, safari = -5,
     spawns = { { id = 1, map = "ROUTE_1", x = 2, y = 3 } } }) == nil,
     "a negative round is refused")
  local beat = Wire.decode(Wire.safari(42))
  ok(beat ~= nil, "a clock beat decodes")
  eq(beat and beat.left, 42, "with the seconds left")
  eq(Wire.decode(Wire.safari(0)).left, 0, "zero is the buzzer, and it travels")
  ok(Wire.decode({ t = "safari" }) == nil, "a beat without a clock is refused")
  ok(Wire.decode({ t = "safari", left = 9999 }) == nil, "and so is an absurd one")

  eq(Wire.decode(Wire.challenge(7)).nonce, 7, "challenge nonce")
  eq(Wire.decode(Wire.accept(7)).nonce, 7, "accept nonce")
  eq(Wire.decode(Wire.winner(3)).id, 3, "winner id")

  -- the bag on the ground (POK-25): a spill carries it as one more thing
  local bagged = Wire.decode(Wire.spill("ROUTE_1",
    { { key = "7:1", x = 5, y = 6, species = "PIDGEY", level = 8 } },
    { key = "7:bag", x = 5, y = 5, name = "RED",
      items = { { id = "POKE_BALL", n = 6 }, { id = "POTION", n = 1 } }, money = 3000 }))
  ok(bagged ~= nil and bagged.bag ~= nil, "a spill with a bag round-trips")
  eq(bagged and bagged.bag.key, "7:bag", "the bag has its own key")
  eq(bagged and #bagged.bag.items, 2, "both stacks")
  eq(bagged and bagged.bag.items[1].n, 6, "with their counts")
  eq(bagged and bagged.bag.money, 3000, "and the money")
  eq(bagged and bagged.bag.name, "RED", "and whose it was")
  local bagOnly = Wire.decode(Wire.spill("ROUTE_1", {},
    { key = "7:bag", x = 5, y = 5, items = {}, money = 500 }))
  ok(bagOnly ~= nil and #bagOnly.mons == 0 and bagOnly.bag.money == 500,
     "a trainer with nothing but a bag still spills the bag")
  ok(Wire.decode({ t = "spill", map = "R", mons = {}, bag = { key = "", x = 1, y = 1 } }) == nil,
     "a keyless bag is refused")
  ok(Wire.decode({ t = "spill", map = "R", mons = {}, bag = { key = "k", x = 1, y = 1,
     items = { { id = "", n = 1 } } } }) == nil, "an empty item id is refused")
  local clamped = Wire.decode({ t = "spill", map = "R", mons = {}, bag = { key = "k", x = 1, y = 1,
     items = { { id = "X", n = 500 } }, money = -5, name = "ABCDEFGHIJ" } })
  eq(clamped and clamped.bag.items[1].n, 99, "an oversized stack clamps")
  eq(clamped and clamped.bag.money, 0, "negative money clamps to zero")
  eq(clamped and clamped.bag.name, "ABCDEFG", "the name is capped at seven")
  ok(Wire.loot == nil, "loot is gone from the vocabulary")
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
  local npcout = Wire.decode(Wire.npcout("ROUTE_1", "TRAINER_3"))
  ok(npcout ~= nil, "npcout round-trips")
  eq(npcout and npcout.map, "ROUTE_1", "npcout carries the map")
  eq(npcout and npcout.obj, "TRAINER_3", "and the object to hide")
  ok(Wire.decode({ t = "npcout", map = "ROUTE_1" }) == nil,
     "npcout without an object is refused")
  ok(Wire.decode({ t = "npcout", map = "ROUTE_1", obj = ("X"):rep(65) }) == nil,
     "and an oversized object name is refused")

  local everywhere = Wire.decode(Wire.ring(8, 8, 9, -1, "CELADON CITY"))
  eq(everywhere and everywhere.r, -1,
     "the all-fog ring (a negative radius) crosses the wire intact")
  ok(Wire.decode({ t = "ring", phase = 1, cx = 1, cy = 1, r = -7 }) == nil,
     "but an arbitrary negative radius is still refused")

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

  -- the ring never clamps: the last phase is fog over everything, so a match
  -- whose survivors will not fight each other still ends
  ok(Fog.coversAll(Fog.radius(Fog.phaseCount())),
     "the final phase covers the whole map")
  ok(not Fog.coversAll(Fog.radius(Fog.phaseCount() - 1)),
     "the phase before it still has an inside")
  eq(Fog.radius(Fog.phaseCount() - 1), 0,
     "and that inside is the centre's own square only")
  ok(not Fog.coversAll(0), "radius 0 is a place, not the absence of one")
  ok(Fog.coversAll(Fog.EVERYWHERE), "EVERYWHERE is the absence of one")
  ok(Fog.radius(Fog.phaseCount() + 50) == Fog.EVERYWHERE,
     "past the schedule the fog stays everywhere -- no clamp back to a ring")

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
  ok(Fog.isSafe(locations, "HOME", center, 0), "at radius 0 the centre is safe")
  ok(Fog.isSafe(locations, "INDOORS", center, 0),
     "and so are the buildings on its square")
  ok(not Fog.isSafe(locations, "NEXTDOOR", center, 0),
     "but the next square over is not")
  ok(not Fog.isSafe(locations, "HOME", center, Fog.EVERYWHERE),
     "once the fog covers everything, even the centre is in it")
  ok(not Fog.isSafe(locations, "NOWHERE", center, Fog.EVERYWHERE),
     "and an unplaced map is no longer a loophole")
  ok(not Fog.isSafe(nil, "HOME", nil, Fog.EVERYWHERE),
     "nor is having no location table at all")
  ok(Fog.distanceOutside(locations, "HOME", center, Fog.EVERYWHERE) > 0,
     "everything reads as outside the all-fog ring")

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
  -- the ring is preferred over the faller's own cell, so an open-field pile
  -- spreads instead of stacking
  for _, c in ipairs(cells) do
    ok(not (c.x == 10 and c.y == 10),
       "an open field puts no ball on the cell they fell on")
  end
  local seen, dup = {}, false
  for _, c in ipairs(cells) do
    local k = c.x .. "," .. c.y
    if seen[k] then dup = true end
    seen[k] = true
    ok(math.abs(c.x - 10) <= 4 and math.abs(c.y - 10) <= 4, "and stays nearby")
  end
  ok(not dup, "no two Pokemon share a cell")

  -- a wall must not mean lost loot: the shortfall stacks on the faller's
  -- own cell, which is walkable by definition (they stood on it) and free
  -- now that a beaten trainer's sprite despawns
  local onlyOne = function(x, y) return x == 11 and y == 10 end
  local walled = Spills.placeAround(10, 10, 4, onlyOne)
  eq(#walled, 4, "a walled-in spill still drops every ball")
  eq(walled[1].x .. "," .. walled[1].y, "11,10", "the one free ring cell is used first")
  local stacked = 0
  for _, c in ipairs(walled) do
    if c.x == 10 and c.y == 10 then stacked = stacked + 1 end
  end
  eq(stacked, 3, "and the rest stack where they fell")
  eq(#Spills.placeAround(10, 10, 4, function() return false end), 4,
     "even nowhere-free drops the whole team where they fell")

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

  -- the bag (POK-25): on the cell they fell on, the balls around it
  local carried = Spills.build(7, "ROUTE_1", 5, 5, party, open,
    { items = { { id = "POTION", n = 2 } }, money = 500, name = "RED" })
  ok(carried ~= nil and carried.bag ~= nil, "a carried bag spills with the team")
  eq(carried and carried.bag.key, "7:bag", "under its own key")
  eq(carried and (carried.bag.x .. "," .. carried.bag.y), "5,5", "on the cell they fell on")
  ok(carried and (carried.mons[1].x .. "," .. carried.mons[1].y) ~= "5,5",
     "with the balls around it")
  local bagAlone = Spills.build(7, "ROUTE_1", 5, 5, {}, open, { items = {}, money = 500 })
  ok(bagAlone ~= nil and #bagAlone.mons == 0 and bagAlone.bag.money == 500,
     "a trainer with no team still drops the bag")
  ok(Spills.build(7, "ROUTE_1", 5, 5, {}, open, { items = {}, money = 0 }) == nil,
     "an empty bag is nothing to drop")

  -- round-trips, and survives a hostile row
  local decoded = Wire.decode(Wire.spill(spill.map, spill.mons))
  ok(decoded ~= nil, "spill round-trips")
  eq(#decoded.mons, 2, "with both balls")
  eq(decoded.mons[1].level, 12, "and the level")
  ok(Wire.decode({ t = "spill", map = "R", mons = { { key = "", x = 1, y = 1,
     species = "RATTATA" } } }) == nil, "a keyless ball is refused")
  ok(Wire.decode({ t = "spill", map = "R", mons = {} }) == nil,
     "an empty spill is refused")
  -- a 6/6 release travels as a one-ball spill under its own key namespace,
  -- which the elimination keys (ownerId:i) can never collide with
  local drop = Wire.decode(Wire.spill("ROUTE_1",
    { { key = "5:drop:1", x = 5, y = 6, species = "PIDGEY", level = 8 } }))
  ok(drop ~= nil, "a single released mon travels as a spill")
  eq(#drop.mons, 1, "of one ball")
  eq(drop.mons[1].key, "5:drop:1", "with its drop key intact")
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

  -- the bag is one more thing on the ground, with its contents
  local t = Spills.new(fake)
  t:add(carried)
  eq(t:count(), 3, "the bag counts alongside the balls")
  ok(t:get("7:bag") ~= nil and t:get("7:bag").bag ~= nil and t:get("7:bag").bag.money == 500,
     "and is findable, with its contents")
  t:take("7:bag")
  eq(t:count(), 2, "taking it leaves the balls")
end

-- ------- level scaling

do
  local Levels = require("mods.battle_royale.lib.levels")
  local Fog = require("mods.battle_royale.lib.fog")

  -- one clock, not two: the ladder is indexed by the fog's phase.  The fog
  -- keeps closing after the ladder tops out (the last rungs are the endgame
  -- at level 100), so the ladder is never LONGER than the schedule.
  ok(Levels.rungs() <= Fog.phaseCount(),
     "every level rung has a fog phase to ride")
  eq(Levels.at(Fog.phaseCount()), Levels.MAX,
     "the all-fog phase is at the level cap")
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

  -- POK-38: the rung raises the ceiling, never the floor
  eq(Levels.carryHp(22, 0, 47), 0, "a fainted mon stays fainted across a rung")
  eq(Levels.carryHp(22, 22, 47), 47, "an untouched mon rides up to the new max")
  eq(Levels.carryHp(22, 10, 47), 35, "damage carries as an absolute amount")
  eq(Levels.carryHp(40, 1, 41), 2, "a 1 HP mon gains just the max-HP growth")
  eq(Levels.carryHp(50, 2, 40), 1, "the 1 HP floor holds even if the max shrank")
  eq(Levels.carryHp(0, 0, 30), 30, "a mon with no recorded stats arrives whole")

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

  -- POK-60: the column is shorter than the row -- nothing engages you
  -- from off screen
  eq(Engage.RANGE_Y, 4, "the vertical eyeline is four cells")
  eq(Engage.rangeFor("down"), 4, "a column facing reaches four")
  eq(Engage.rangeFor("left"), 6, "a row facing reaches six")
  local meDown = { id = 1, map = "M", x = 5, y = 5, facing = "down",
                   moving = false, status = "alive", busy = false }
  local below = { id = 9, map = "M", x = 5, y = 5 + Engage.RANGE_Y,
                  facing = "up", moving = false, status = "alive", busy = false }
  eq(Engage.target(meDown, { below }), 9, "four cells down the column is seen")
  below.y = 5 + Engage.RANGE_Y + 1
  ok(Engage.target(meDown, { below }) == nil, "five is off screen, and unseen")

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

    -- the Safari opening (POK-21): everyone on the centre map, together
    local safari, why = Spawn.pickIn(maps, tilesets, "SAFARI_ZONE_CENTER", 8, Spawn.rng(42))
    ok(safari ~= nil, "deals 8 Safari spawns (" .. tostring(why) .. ")")
    if safari then
      eq(#safari, 8, "one per trainer")
      local seen, unique, allCentre, allWalkable = {}, true, true, true
      for _, d in ipairs(safari) do
        local key = d.x .. ":" .. d.y
        if seen[key] then unique = false end
        seen[key] = true
        if d.map ~= "SAFARI_ZONE_CENTER" then allCentre = false end
        if not Spawn.walkable(maps, tilesets, d.map, d.x, d.y) then allWalkable = false end
      end
      ok(unique, "no two trainers share a cell")
      ok(allCentre, "all of them in the centre")
      ok(allWalkable, "and every cell is walkable")
      ok(#Spawn.outdoorMaps({ SAFARI_ZONE_CENTER = maps.SAFARI_ZONE_CENTER }) == 0,
         "which the outdoor drop could never reach (FOREST tileset)")
    end
    -- a crowd bigger than the map shares cells rather than failing to drop
    local crowd = Spawn.pickIn(maps, tilesets, "SAFARI_ZONE_CENTER", 2000, Spawn.rng(1))
    eq(crowd and #crowd, 2000, "a crowd bigger than the map still all lands")
    ok(Spawn.pickIn(maps, tilesets, "NOT_A_MAP", 1, Spawn.rng(1)) == nil,
       "an unknown map is refused")
    -- the drop after the buzzer (POK-22): a random cell of the chosen town
    local landing = Spawn.pickIn(maps, tilesets, "PALLET_TOWN", 1, Spawn.rng(9))
    ok(landing and landing[1] and landing[1].map == "PALLET_TOWN", "a town landing is on that town")
    ok(landing and Spawn.walkable(maps, tilesets, "PALLET_TOWN", landing[1].x, landing[1].y),
       "on a walkable cell")
  end
end

-- ------- fleeing a PvP battle is not free (POK-24)

do
  local Flee = require("mods.battle_royale.lib.flee")
  local Engage = require("mods.battle_royale.lib.engage")

  -- the roll
  eq(Flee.chance(100, 100, 1, 0), 64, "one in four at equal speed")
  eq(Flee.chance(200, 100, 1, 0), 128, "half at twice their speed")
  eq(Flee.chance(1000, 100, 1, 0), 160, "never better than five in eight")
  eq(Flee.chance(100, 100, 2, 0), 84, "a retry adds a little")
  eq(Flee.chance(1000, 100, 10, 0), 240, "retries never make it certain")
  eq(Flee.chance(100, 100, 1, 1), 32, "an earlier escape from this pursuer halves it")
  eq(Flee.chance(100, 100, 1, 3), 8, "and again, every time")
  eq(Flee.chance(0, nil, 1, 0), 64, "nonsense speeds fall back to equal")
  ok(Flee.roll(100, 100, 1, 0, function() return 64 end),
     "rng at the chance escapes (the <= keeps the equal case)")
  ok(not Flee.roll(100, 100, 1, 0, function() return 65 end), "one above it does not")

  -- the wrap, on a stand-in battle with no battlers (equal speed)
  local function fakeBattle()
    local b = { submitted = 0, said = {} }
    b.tryRun = function(s) s.submitted = s.submitted + 1 end
    b.say = function(s, t) s.said[#s.said + 1] = t end
    return b
  end
  ok(not Flee.wrap({}, {}), "nothing to wrap is reported")
  local roll = 255
  local b = fakeBattle()
  local save = { inventory = {} }
  local flees = {}
  ok(Flee.wrap(b, { save = save, prior = 0, rng = function() return roll end,
                    onFlee = function(how) flees[#flees + 1] = how end }),
     "a battle with a tryRun is wrapped")
  b:tryRun()
  eq(b.submitted, 0, "a failed roll submits nothing")
  eq(b.said[1], "Can't escape!", "and says so")
  eq(b.afterQueue, "menu", "and hands the menu back")
  eq(#flees, 0, "no flee recorded")
  roll = 84
  b:tryRun()
  eq(b.submitted, 1, "the retry's better odds let it through")
  eq(flees[1], "ran", "and it is a flee")
  local doll = fakeBattle()
  save.inventory.POKE_DOLL = 2
  Flee.wrap(doll, { save = save, prior = 9, rng = function() return 255 end,
                    onFlee = function(how) flees[#flees + 1] = how end })
  doll:tryRun()
  eq(doll.submitted, 1, "a POKe DOLL bails whatever the odds")
  eq(save.inventory.POKE_DOLL, 1, "and is spent")
  eq(flees[2], "doll", "recorded as a doll")
  doll:tryRun()
  eq(save.inventory.POKE_DOLL, nil, "the last one leaves the bag entirely")
  eq(doll.submitted, 2, "and still bails")

  -- the grace and the lockout: an avoided trainer is not a target, and
  -- does not shield anyone behind them
  local me = { id = 1, map = "R", x = 5, y = 5, facing = "up", moving = false,
               status = "alive", busy = false }
  local function at(id, x, y)
    return { id = id, map = "R", x = x, y = y, facing = "down", moving = false,
             status = "alive", busy = false }
  end
  eq(Engage.target(me, { at(2, 5, 3) }), 2, "in sight: a target")
  eq(Engage.target(me, { at(2, 5, 3) }, { avoid = { [2] = true } }), nil,
     "avoided: not a target")
  eq(Engage.target(me, { at(2, 5, 3), at(3, 5, 2) }, { avoid = { [2] = true } }), 3,
     "and not a shield for the one behind")
  eq(Engage.answer({ status = "alive", inBattle = false }, 2, nil, { [2] = true }), "busy",
     "a challenge inside the grace is declined")
  eq(Engage.answer({ status = "alive", inBattle = false }, 2, nil, { [3] = true }), "accept",
     "somebody else's grace is not ours")
end

-- ------- ...and on the real lockstep (needs the imported data, like the
-- engine's own link tests): a loopback host/guest pair, the guest's RUN
-- wrapped.  A failed roll leaves the battle running and the host hears
-- nothing; a passing roll -- or a POKe DOLL -- ends it as a draw on both.

do
  -- the engine's own link tests run under the love stub; so does this block,
  -- and only this block -- the room tests below time themselves without one
  local hadLove = _G.love
  local okAll, err = pcall(function()
    _G.love = _G.love or require("tests.love_stub")
    local Data = require("src.core.Data")
    Data:load()
    local Input = require("src.core.Input")
    Input:init()
    require("src.render.Font").load(Data)
    local Net = require("src.link.Net")
    local Protocol = require("src.link.Protocol")
    local Pokemon = require("src.pokemon.Pokemon")
    local SaveData = require("src.core.SaveData")
    local LinkBattle = require("src.link.LinkBattle")
    local Flee = require("mods.battle_royale.lib.flee")

    local function makeFakeGame(species)
      local save = SaveData.newGame()
      table.insert(save.party, Pokemon.new(Data, species, 50))
      local stack = { list = {} }
      function stack:push(s, ...) table.insert(self.list, s) if s.enter then s:enter(...) end end
      function stack:pop() table.remove(self.list) end
      function stack:top() return self.list[#self.list] end
      function stack:update(dt) local t = self:top() if t and t.update then t:update(dt) end end
      return { data = Data, input = Input, stack = stack, save = save }
    end
    local function pair(seed, extra)
      local gA, gB = makeFakeGame("RATTATA"), makeFakeGame("RATTATA")
      gB.save.player.name = "BLUE"
      local nA, nB = Net.loopbackPair()
      local pA, pB = Protocol.packParty(gA.save.party), Protocol.packParty(gB.save.party)
      local turnLimit = extra and extra.turnLimit
      local bA = LinkBattle.newHost(gA, nA, { myParty = pA, theirParty = pB, theirName = "BLUE", seed = seed,
                                              turnLimit = turnLimit })
      local bB = LinkBattle.newGuest(gB, nB, { myParty = pB, theirParty = pA, theirName = "RED", seed = seed,
                                               turnLimit = turnLimit })
      local rA, rB
      bA.onFinish = function(r) rA = r end
      bB.onFinish = function(r) rB = r end
      gA.stack:push(bA)
      gB.stack:push(bB)
      return gA, gB, bA, bB, function() return rA, rB end
    end
    -- step both sides; a side that is not at its menu gets A mashed so the
    -- intro and the messages advance, a side at its menu is left waiting
    local function pump(gA, gB, bA, bB, n)
      for _ = 1, n do
        Input.pressed = (bA.phase ~= "menu") and { a = true } or {}
        gA.stack:update(1 / 60)
        Input.pressed = (bB.phase ~= "menu") and { a = true } or {}
        gB.stack:update(1 / 60)
      end
    end
    local function settle(gA, gB, bA, bB, n)   -- mash A on both until they finish
      for _ = 1, n do
        Input.pressed = { a = true }
        gA.stack:update(1 / 60)
        gB.stack:update(1 / 60)
      end
    end

    local gA, gB, bA, bB, results = pair(4242)
    eq(bB.kind, "link", "the guest's battle is a link battle")
    local roll, flees = 255, {}
    ok(Flee.wrap(bB, { save = gB.save, prior = 0, rng = function() return roll end,
                       onFlee = function(how) flees[#flees + 1] = how end }),
       "the guest's RUN is wrappable on the real lockstep")
    pump(gA, gB, bA, bB, 600)
    eq(bB.phase, "menu", "the guest reaches its menu")
    bB:tryRun()
    eq(bB.afterQueue, "menu", "lockstep: a failed roll hands the menu back")
    pump(gA, gB, bA, bB, 300)
    local rA, rB = results()
    ok(rA == nil and rB == nil, "and the host never hears of it: the battle is still on")
    eq(#flees, 0, "no flee recorded")
    roll = 0
    bB:tryRun()
    eq(flees[1], "ran", "a passing roll is a flee")
    settle(gA, gB, bA, bB, 2000)
    rA, rB = results()
    eq(rA, "draw", "host: the run ends it as a draw")
    eq(rB, "draw", "guest: a draw too")

    local gA2, gB2, bA2, bB2, results2 = pair(777)
    gB2.save.inventory.POKE_DOLL = 1
    local how
    Flee.wrap(bB2, { save = gB2.save, prior = 5, rng = function() return 255 end,
                     onFlee = function(h) how = h end })
    pump(gA2, gB2, bA2, bB2, 600)
    bB2:tryRun()
    eq(how, "doll", "lockstep: the doll bails at any odds")
    eq(gB2.save.inventory.POKE_DOLL, nil, "and is spent")
    settle(gA2, gB2, bA2, bB2, 2000)
    local r2A, r2B = results2()
    eq(r2A, "draw", "host: the doll's draw")
    eq(r2B, "draw", "guest: the doll's draw")

    -- POK-59: the engine's shot clock, which the mod arms for match PvP.
    -- The host picks at once; the guest never does -- the guest's own
    -- clock forfeits it, and the host holds a definite WIN, not a draw.
    local gA3, gB3, bA3, bB3, results3 = pair(31337, { turnLimit = 30 })
    pump(gA3, gB3, bA3, bB3, 600)
    eq(bA3.phase, "menu", "shot clock: the host reaches its menu")
    eq(bB3.phase, "menu", "shot clock: the guest reaches its menu")
    bA3:resolveTurn(bA3.player.curMoves[1])
    for _ = 1, 31 * 60 do            -- the guest stalls past the clock
      Input.pressed = {}
      gA3.stack:update(1 / 60)
      gB3.stack:update(1 / 60)
    end
    settle(gA3, gB3, bA3, bB3, 2000)
    local r3A, r3B = results3()
    eq(r3B, "lose", "the staller forfeits when the clock runs out")
    eq(r3A, "win", "and the opponent wins outright")
  end)
  if not hadLove then _G.love = nil end
  if not okAll then
    io.write("  (skipping the lockstep flee: " .. tostring(err) .. ")\n")
  end
end

-- ------- free move management (POK-19), priced by the ladder (POK-58)

do
  local MoveKit = require("mods.battle_royale.lib.moves")
  local data = {
    moves = { TACKLE = { name = "TACKLE", pp = 35 }, GROWL = { name = "GROWL", pp = 40 },
              VINE_WHIP = { name = "VINE WHIP", pp = 10 }, CUT = { name = "CUT", pp = 30 },
              TOXIC = { name = "TOXIC", pp = 10 }, SOLARBEAM = { name = "SOLARBEAM", pp = 10 } },
    items = { TM_TOXIC = { machine = { kind = "TM", move = "TOXIC", number = 6 } },
              TM_SOLARBEAM = { machine = { kind = "TM", move = "SOLARBEAM", number = 22 } },
              HM_CUT = { machine = { kind = "HM", move = "CUT", number = 1 } } },
    pokemon = { BULBASAUR = {
      level1Moves = { "TACKLE", "GROWL" },
      learnset = { { level = 13, move = "VINE_WHIP" }, { level = 48, move = "SOLARBEAM" } },
      tmhm = { "TOXIC", "SOLARBEAM", "CUT", "NOT_A_MOVE" },
    } },
  }
  local mon = { species = "BULBASAUR", level = 13, moves = { { id = "TACKLE", pp = 35 } } }

  local list = MoveKit.learnable(data, mon)
  local names, hows = {}, {}
  for i, m in ipairs(list) do names[i], hows[i] = m.name, m.how end
  eq(table.concat(names, "|"), "GROWL|VINE WHIP",
     "no bag: level-up moves at or below the mon's level, nothing else")
  eq(table.concat(hows, "|"), "L1|L13", "tagged by their levels")

  local bagged = MoveKit.learnable(data, mon, { bag = { TM_TOXIC = 1, HM_CUT = 1 } })
  local bn, bh, bi = {}, {}, {}
  for i, m in ipairs(bagged) do bn[i], bh[i], bi[i] = m.name, m.how, m.item or "-" end
  eq(table.concat(bn, "|"), "GROWL|VINE WHIP|TOXIC|CUT",
     "machines join the list only from the bag")
  eq(table.concat(bh, "|"), "L1|L13|TM|HM", "tagged TM and HM")
  eq(table.concat(bi, "|"), "-|-|TM_TOXIC|HM_CUT",
     "a machine row names the item that pays for it")

  local tmOnly = MoveKit.learnable(data, mon, { bag = { TM_SOLARBEAM = 1 } })
  eq(tmOnly[#tmOnly] and tmOnly[#tmOnly].id, "SOLARBEAM",
     "a TM ignores the level gate, exactly like the cartridge")
  eq(tmOnly[#tmOnly] and tmOnly[#tmOnly].how, "TM", "and reads as a TM")

  eq(#MoveKit.learnable(data, { species = "BULBASAUR", level = 5, moves = {} }), 2,
     "a Lv5 knows only its level-1 pool")
  eq(#MoveKit.learnable(data, { species = "MEWTHREE" }), 0, "an unknown species learns nothing")

  eq(MoveKit.teach(data, mon, "GROWL"), false, "a free slot: nothing forgotten")
  eq(mon.moves[2].id, "GROWL", "and the move is in it")
  eq(mon.moves[2].pp, 40, "with its full PP")
  eq(select(2, MoveKit.teach(data, mon, "GROWL")), "already known", "no doubles")
  MoveKit.teach(data, mon, "VINE_WHIP")
  MoveKit.teach(data, mon, "TOXIC")
  eq(#mon.moves, 4, "four slots fill up")
  eq(select(2, MoveKit.teach(data, mon, "CUT")), "which move?", "a fifth needs a slot to forget")
  eq(MoveKit.teach(data, mon, "CUT", 1), "TACKLE", "forgetting slot 1 reports what went")
  eq(mon.moves[1].id, "CUT", "and CUT took its place")
  eq(mon.moves[1].pp, 30, "at full PP")
  eq(#mon.moves, 4, "still four")
  eq(select(2, MoveKit.teach(data, mon, "NOT_A_MOVE")), "no such move", "an unknown move is refused")
  eq(#MoveKit.learnable(data, mon), 1,
     "TACKLE alone remains: forgetting is not forever, and no bag means no machines")
end

-- ------- gyms as contested one-shot bosses (POK-26)

do
  local Gyms = require("mods.battle_royale.lib.gyms")
  local okD, Data = pcall(require, "src.core.Data")
  local count = 0
  for class, prize in pairs(Gyms.LEADERS) do
    count = count + 1
    ok(type(prize.name) == "string" and #prize.name > 0, class .. " has a name")
    ok(type(prize.tm) == "string" and prize.tm:sub(1, 3) == "TM_",
       class .. " holds a TM")
    ok(type(prize.label) == "string" and #prize.label > 0, class .. " has a label")
  end
  eq(count, 8, "eight gyms, eight leaders, eight prizes")
  ok(Gyms.leader(nil) == nil, "no class, no leader")
  ok(Gyms.leader("OPP_YOUNGSTER") == nil, "a youngster runs no gym")
  if okD and Data and Data.load then
    pcall(function() Data:load() end)
    if Data.items then
      for class, prize in pairs(Gyms.LEADERS) do
        ok(Data.items[prize.tm] ~= nil, class .. "'s prize exists: " .. prize.tm)
      end
      ok(Gyms.leaderOfObject(Data.maps, "PEWTER_GYM", "PEWTERGYM_BROCK") ~= nil,
         "BROCK is found behind his npcout")
      ok(Gyms.leaderOfObject(Data.maps, "PEWTER_GYM", "PEWTERGYM_COOLTRAINER_M") == nil,
         "his cooltrainer is not a leader")
    end
  end
end

-- ------- the rival's ambushes never fire in a match (POK-67)

do
  local src = io.open("mods/battle_royale/main.lua"):read("*a")
  for _, n in ipairs({
    "EVENT_BATTLED_RIVAL_IN_OAKS_LAB",
    "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE", "EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE",
    "EVENT_BEAT_CERULEAN_RIVAL", "EVENT_BEAT_SS_ANNE_RIVAL",
    "EVENT_BEAT_POKEMON_TOWER_RIVAL", "EVENT_BEAT_SILPH_CO_RIVAL",
  }) do
    ok(src:find(n, 1, true) ~= nil, n .. " rides the loadout")
    local story = io.open("data/scripts/story.lua"):read("*a")
      .. io.open("data/scripts/story5.lua"):read("*a")
    if n ~= "EVENT_BATTLED_RIVAL_IN_OAKS_LAB"
       and n ~= "EVENT_BEAT_POKEMON_TOWER_RIVAL"
       and n ~= "EVENT_BEAT_SILPH_CO_RIVAL" then
      ok(story:find(n, 1, true) ~= nil,
         n .. " is the engine script's own gate")
    end
  end
end

-- ------- the ghost walks like a trainer, not a metronome (POK-70)

do
  local Ghosts = require("mods.battle_royale.lib.ghosts")
  local steps, placed = {}, false
  local handle = {
    setPassable = function() end,
    isMoving = function() return false end,
    stepNow = function(_, d) steps[#steps + 1] = d end,
    position = function() return 0, 0 end,
    placeAt = function() placed = true end,
    face = function() end,
  }
  local self = setmetatable({ ghosts = {} }, { __index = Ghosts })
  self._handle = function() return handle end
  local g = { mapId = "M", queue = { "up" }, npcId = 1 }
  self.ghosts.x = g
  local peer = { map = "M", x = 0, y = 0, facing = "down", status = "alive" }
  for _ = 1, Ghosts.HOLD_TICKS do self:_syncOne(nil, "x", "M", peer) end
  eq(#steps, 0, "a lone step is held for the jitter buffer")
  self:_syncOne(nil, "x", "M", peer)
  eq(#steps, 1, "and plays once the grace runs out")
  g.queue = { "up", "left" }
  self:_syncOne(nil, "x", "M", peer)
  eq(#steps, 2, "a second queued step releases the first at once")
  eq(g.queue[1], "left", "leaving the follower queued")
  ok(not placed, "no snap-teleport happened on the way")
end

-- ------- escapable, not merely walkable (POK-23)

do
  local Spawn = require("mods.battle_royale.lib.spawn")
  -- an 8x6 pond world: a land ring, and an island at (4..5, 2..3) walled
  -- in by water (x 3..6, y 1..4 minus the island itself)
  local water = {}
  local function key(x, y) return y * 4096 + x end
  for x = 3, 6 do for y = 1, 4 do water[key(x, y)] = true end end
  for x = 4, 5 do for y = 2, 3 do water[key(x, y)] = nil end end
  local function isWalk(x, y) return not water[key(x, y)] end

  local esc = Spawn.floodEscapable(8, 6, isWalk, { { x = 0, y = 5 } })
  ok(esc[key(0, 0)], "the mainland reaches the seed")
  ok(esc[key(7, 5)], "all the way around the pond")
  ok(not esc[key(4, 2)], "the island is walkable and unreachable")
  ok(not esc[key(3, 2)], "water never joins the region")
  local none = Spawn.floodEscapable(8, 6, isWalk, {})
  ok(not none[key(0, 0)], "no seeds, no region")
  local edge = Spawn.floodEscapable(8, 6, isWalk, { { x = -3, y = 99 } })
  ok(not edge[key(0, 0)], "an out-of-bounds seed seeds nothing")
end

-- ------- bots that hunt (POK-42, POK-43)

do
  local Bots = require("mods.battle_royale.lib.bots")
  local Spawn = require("mods.battle_royale.lib.spawn")
  local low = function(a) return a end

  local D = { A = 25, B = 4, C = 100 }
  local dOf = function(id) return D[id] end
  eq(Bots.homeward({ "A", "B", "C" }, dOf, 50, low), "B",
     "the seam nearest the eye wins")
  eq(Bots.homeward({ "A", "C" }, dOf, 9, low), nil,
     "already nearer than every seam: stay put")
  eq(Bots.homeward({ "A", "C" }, dOf, nil, low), "A",
     "an unplaced map still walks toward the eye")
  local blind = Bots.homeward({ "A", "B" }, function() return nil end, nil, low)
  ok(blind == "A" or blind == "B", "no distances anywhere: the old stroll")
  eq(Bots.homeward({}, dOf, 1, low), nil, "no seams, no roam")

  local dealt = Bots.dealTowns(11, 8, Spawn.rng(4242))
  eq(#dealt, 8, "every bot gets a town")
  local seen, dup = {}, false
  for _, t in ipairs(dealt) do
    if seen[t] then dup = true end
    seen[t] = true
  end
  ok(not dup, "no two bots share a town while towns remain")
  eq(#Bots.dealTowns(3, 7, Spawn.rng(7)), 7, "more bots than towns still all land")

  -- POK-62: the TM in the bag
  local inPool = {}
  for _, id in ipairs(Bots.TM_COMMON) do inPool[id] = true end
  for _, id in ipairs(Bots.TM_PRIZE) do inPool[id] = true end
  eq(Bots.lootTM(4242, 1001), Bots.lootTM(4242, 1001),
     "the bag's TM is stable for a seed")
  ok(Bots.lootTM(4242, 1001) ~= Bots.lootTM(4242, 1002)
     or Bots.lootTM(4242, 1003) ~= Bots.lootTM(4242, 1002),
     "different bots carry different TMs")
  local prizes, total = 0, 200
  for i = 1, total do
    local tm = Bots.lootTM(4242, 1000 + i)
    ok(inPool[tm], "every dealt TM is from a pool (" .. tostring(tm) .. ")")
    for _, pid in ipairs(Bots.TM_PRIZE) do
      if tm == pid then prizes = prizes + 1 break end
    end
  end
  ok(prizes >= 20 and prizes <= 100,
     "roughly one bag in four holds a prize (" .. prizes .. "/" .. total .. ")")
end

-- ------- the Hall of Fame (POK-47)

do
  local Fame = require("mods.battle_royale.lib.fame")
  eq(Fame.timeString(754), "12:34", "time reads minutes:seconds")
  eq(Fame.timeString(nil), "0:00", "no time is zero")
  local party = { { species = "PIDGEY", level = 20 },
                  { species = "NIDORINO", nickname = "NIDO", level = 30 },
                  { level = 5 } }
  local pages = Fame.pages(party, { catches = 4, beats = 2, steps = 812,
                                    rings = 5, seconds = 754, money = 3210 })
  eq(#pages, 3, "two mons and the card (a specieless row is skipped)")
  eq(pages[1].kind .. ":" .. pages[1].name, "mon:PIDGEY", "the lead leads the parade")
  eq(pages[2].name, "NIDO", "a nickname is the shown name")
  eq(pages[3].kind, "card", "the record closes the parade")
  local lines = pages[3].lines
  eq(#lines, 6, "six rows on the card")
  eq(lines[1][1] .. "=" .. lines[1][2], "CAUGHT=4", "catches counted")
  eq(lines[4][2], "5", "rings survived")
  eq(lines[5][2], "12:34", "time alive")
  eq(lines[6][2], "3210", "the money came along")
end

-- ------- main.lua: a local helper is only in scope below its own line
--
-- `local function clock()` at line 873 is a nil global at line 810, and the
-- symptom was every tick of a live match dying with "attempt to call global
-- 'clock'" -- unseen by any unit test because none of them run the tick
-- for an alive player after the drop.  luacheck would say so; it is not on
-- this machine, so this says so.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the early-use scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local lines = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local defs = {}
    for i, line in ipairs(lines) do
      local name = line:match("^%s*local function ([%w_]+)%s*%(")
      if name and not defs[name] then defs[name] = i end
    end
    local early = {}
    for name, at in pairs(defs) do
      for i = 1, at - 1 do
        local line = lines[i]:gsub("%-%-.*$", "")     -- comments do not count
        -- a call or a reference (`foo(` / `= foo` / `, foo`) but not `.foo`
        -- or `:foo` (a method or field of the same name is somebody else's)
        if line:find("[^%w_%.:]" .. name .. "%s*%(") or line:find("^" .. name .. "%s*%(") then
          early[#early + 1] = ("%s at %d (defined at %d)"):format(name, i, at)
        end
      end
    end
    table.sort(early)
    ok(#early == 0, "no local helper is used above its definition"
       .. (#early > 0 and (": " .. table.concat(early, "; ")) or ""))
  end
end

-- ------- what a spectator sees (POK-18)

do
  local Peek = require("mods.battle_royale.lib.peek")
  local data = {
    pokemon = { PIDGEY = { name = "PIDGEY" } },
    moves = { GUST = { name = "GUST" }, SAND_ATTACK = { name = "SAND-ATTACK" } },
    items = { POTION = { name = "POTION" }, POKE_BALL = { name = "POKe BALL" } },
  }
  local save = { party = { { species = "PIDGEY", level = 12, hp = 23, stats = { hp = 40 },
                             status = "PSN", moves = { { id = "GUST", pp = 30 }, { id = "SAND_ATTACK", pp = 15 } },
                             dvs = { 1, 2, 3 }, exp = 999 } } }
  local s = Peek.summary(save, { items = { { id = "POTION", n = 2 } }, money = 500 })
  eq(#s.party, 1, "a summary per party member")
  eq(s.party[1].hp .. "/" .. s.party[1].maxHp, "23/40", "HP and max")
  eq(table.concat(s.party[1].moves, ","), "GUST,SAND_ATTACK", "move ids only")
  ok(s.party[1].dvs == nil and s.party[1].exp == nil, "and nothing that rebuilds the record")
  eq(s.money, 500, "the money rides along")
  -- the vanilla screens draw a borrowed view (POK-53)
  local view = Peek.saveView(data, s.party)
  eq(#view, 1, "the save view keeps known species")
  eq(view[1].hp .. "/" .. view[1].stats.hp, "23/40", "hp, and a synthesized stats.hp for the bar")
  eq(view[1].status, "PSN", "the status rides into the view")
  eq(#Peek.saveView(data, { { species = "MISSINGNO", level = 5 } }), 0,
     "an unknown species never reaches the screen")
  eq(Peek.moveRows(data, s.party[1])[2].label, "SAND-ATTACK", "moves by name")
  local bag = Peek.itemRows(data, s.items, s.money)
  eq(bag[1].label .. " " .. bag[1].right, "POTION x2", "an item row in BagMenu's own shape")
  eq(bag[1].value, "POTION", "and it carries the id")
  eq(bag[2].label, "¥500", "the money is a row of its own")
  eq(#Peek.itemRows(data, {}, 0), 0, "an empty bag stays empty -- the item box says Nothing here")
  local Bots = require("mods.battle_royale.lib.bots")
  local bot = Peek.botParty(Bots, 1, Bots.idFor(1), nil, 30)
  ok(#bot >= 1 and bot[1].species ~= nil, "a bot's party is derived from the seed")
  eq(bot[1].level, 30, "at the rung")
  eq(bot[1].hp, bot[1].maxHp, "at full HP")
end

-- ------- one lobby screen, not a menu round-trip (POK-32)
--
-- The screen's rows are a function of BR, rebuilt every frame; the rows
-- that start a room keep the screen open so it can become the lobby.

do
  local okMenu, BRMenu = pcall(require, "mods.battle_royale.lib.menu")
  if not okMenu then
    io.write("  (skipping lobby screen: " .. tostring(BRMenu) .. ")\n")
  else
    local function fakeBR(over)
      local BR = {
        phase = "off", status = "lobby", solo = false, botCount = 3, fillTo = 0,
        ring = nil, relay = nil,
        aliveCount = function() return 4 end,
        level = function() return 5 end,
        safariLeft = function() return 65 end,
        startsIn = function() return nil end,
        isOpen = function() return false end,
        botsAtStart = function(self) return self.botCount end,
        playerName = function() return "RED" end,
        skinLabel = function() return "RED" end,
        skinId = function() return "RED" end,
        winCount = function() return 0 end,
        setSkin = function() end,
        relayAddress = function() return "127.0.0.1:7790" end,
        fogSeconds = function() return 120 end,
        safariSeconds = function() return 120 end,
        cycleFog = function(self) self.cycledFog = true end,
        cycleSafari = function(self) self.cycledSafari = true end,
      }
      for k, v in pairs(over or {}) do BR[k] = v end
      return BR
    end
    local function room(host, over)
      local r = { code = "ABCDEF", hostId = 1, status = "open",
                  members = { { id = 1, name = "RED" }, { id = 2, name = "BLUE" } },
                  isOpen = function() return true end,
                  isHost = function() return host end }
      for k, v in pairs(over or {}) do r[k] = v end
      return r
    end
    local function labels(items)
      local out = {}
      for i, it in ipairs(items) do out[i] = it.label end
      return table.concat(out, "|")
    end
    local function find(items, prefix)
      for _, it in ipairs(items) do
        if it.label:sub(1, #prefix) == prefix then return it end
      end
      return nil
    end

    -- the first face: every row keeps the screen, because the room it
    -- starts is what turns the screen into the lobby
    local BR = fakeBR()
    local items, view = BRMenu.items({}, BR, {})
    eq(view, "menu", "no room is the first face")
    eq(labels(items), "QUICK PLAY|SOLO VS BOTS|HOST GAME|JOIN BY CODE|NAME: RED|SKIN: RED|SERVER...",
       "the first face, in order")
    local allOpen = true
    for _, it in ipairs(items) do if not it.keepOpen then allOpen = false end end
    ok(allOpen, "and every row keeps the screen open")

    -- connecting
    BR.relay = room(true, { status = "connecting", isOpen = function() return false end })
    items, view = BRMenu.items({}, BR, {})
    eq(view, "connecting", "a relay mid-handshake is the connecting face")
    eq(labels(items), "CONNECTING...|CANCEL", "which waits, or cancels")

    -- a solo lobby: the two rows that decide the match, and out
    BR.relay = room(true)
    BR.solo = true
    items, view = BRMenu.items({}, BR, {})
    eq(view, "lobby", "an open room is the lobby")
    eq(labels(items), "BOTS: 3|FOG: 120s|SAFARI: 120s|START MATCH|LEAVE",
       "solo: bots, the two clocks, start, leave")
    find(items, "FOG").onSelect()
    ok(BR.cycledFog, "the FOG row cycles the fog clock (POK-44)")
    ok(find(items, "SAFARI: 120s") ~= nil and find(items, "SAFARI: 120s").keepOpen,
       "the SAFARI row is a setting that keeps the screen")
    ok(find(items, "BOTS").keepOpen, "changing BOTS keeps the screen")
    ok(not find(items, "START MATCH").keepOpen, "START MATCH is the way out")
    ok(not find(items, "LEAVE").keepOpen, "and so is LEAVE")

    -- a hosted room with people in it
    BR.solo = false
    BR.startsIn = function() return 12 end
    items = BRMenu.items({}, BR, {})
    eq(labels(items),
       "CODE ABCDEF|- RED*|- BLUE|OPEN: NO|BOTS: 3|FOG: 120s|SAFARI: 120s|FILL TO: OFF|TRAINERS: 5|START MATCH (12)|LEAVE",
       "hosting: code, roster, OPEN, BOTS, the clocks, FILL TO, the total, the countdown")

    -- a guest waits
    BR.relay = room(false)
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "CODE ABCDEF|- RED*|- BLUE|WAIT FOR HOST|LEAVE", "a guest waits for the host")

    -- the match report, with the Safari clock while it runs
    BR.phase = "safari"
    BR.status = "alive"
    items, view = BRMenu.items({}, BR, {})
    eq(view, "match", "a round is the match face")
    eq(labels(items), "ALIVE: 4|SAFARI 1:05|LEVEL: 5|LEAVE MATCH", "the Safari clock rides the report")
    BR.phase = "match"
    BR.status = "out"
    BR.ring = { phase = 3, center = { name = "CELADON CITY" } }
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "SPECTATING|LEVEL: 5|FOG: CELADON CITY|LEAVE MATCH", "spectating, with the fog")
    -- the match is over: the host can run it back, a guest waits to be sent
    BR.phase = "over"
    BR.relay = room(true)
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "SPECTATING|LEVEL: 5|FOG: CELADON CITY|PLAY AGAIN|LEAVE MATCH",
       "over, as the host: PLAY AGAIN")
    ok(not find(items, "PLAY AGAIN").keepOpen, "which closes the report (the world is about to go)")
    BR.relay = room(false)
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "SPECTATING|LEVEL: 5|FOG: CELADON CITY|LEAVE MATCH",
       "over, as a guest: the host decides")
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
  -- fromText is an RFC 0014 seam; on a stock engine the shim supplies it,
  -- exactly as it does for the running mod (shim_test covers both worlds)
  if not CodeEntry.fromText then require("mods.battle_royale.lib.shim").apply() end
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


-- ------- the fog takes Kanto's own trainers (POK-35): Fog.tickMaps

do
  local Fog = require("mods.battle_royale.lib.fog")
  -- a 3-map world: A inside the ring, B and C outside it
  local locations = { A = { x = 0, y = 0 }, B = { x = 9, y = 0 }, C = { x = 0, y = 9 } }
  local center = { x = 0, y = 0 }
  local maps = { "A", "B", "C" }
  local state, t = {}, 1000

  -- first sight of an unsafe map arms its clock but takes nothing
  local died = Fog.tickMaps(state, maps, locations, center, 2, t)
  eq(#died, 0, "arming the clocks takes nobody")
  ok(state.B and state.B.ticks == 0, "an unsafe map's clock is armed")
  ok(state.A == nil, "a safe map has no clock")

  -- the same grace players get: TICKS_TO_KILL beats, TICK_SECONDS apart
  for i = 1, Fog.TICKS_TO_KILL - 1 do
    t = t + Fog.TICK_SECONDS
    died = Fog.tickMaps(state, maps, locations, center, 2, t)
    eq(#died, 0, "still counting at beat " .. i)
  end
  t = t + Fog.TICK_SECONDS
  died = Fog.tickMaps(state, maps, locations, center, 2, t)
  eq(#died, 2, "both fogged maps die on the last beat")
  ok(state.B.dead and state.C.dead, "and are marked dead")

  -- the dead stay dead, and are not reported twice
  t = t + Fog.TICK_SECONDS
  died = Fog.tickMaps(state, maps, locations, center, 2, t)
  eq(#died, 0, "a dead map is not taken twice")

  -- a beat needs the full TICK_SECONDS
  local s2, t2 = {}, 5000
  Fog.tickMaps(s2, { "B" }, locations, center, 2, t2)
  Fog.tickMaps(s2, { "B" }, locations, center, 2, t2 + Fog.TICK_SECONDS - 1)
  eq(s2.B.ticks, 0, "a beat needs the full TICK_SECONDS")

  -- a recentred ring reprieves a counting map...
  local s3 = {}
  Fog.tickMaps(s3, { "B" }, locations, center, 2, 100)
  Fog.tickMaps(s3, { "B" }, locations, { x = 9, y = 0 }, 2, 104)
  eq(s3.B, nil, "a map the ring re-admits is reprieved")

  -- ...but never resurrects a dead one
  local s4 = { B = { ticks = Fog.TICKS_TO_KILL, dead = true, last = 0 } }
  local d4 = Fog.tickMaps(s4, { "B" }, locations, { x = 9, y = 0 }, 2, 200)
  eq(#d4, 0, "the dead stay dead")
  ok(s4.B.dead, "even when the ring re-admits their map")

  -- the all-covering ring (radius -1) counts every map down
  local s5 = {}
  Fog.tickMaps(s5, maps, locations, center, -1, 300)
  ok(s5.A ~= nil and s5.B ~= nil and s5.C ~= nil,
     "the final ring arms every clock")
end


-- POK-75: the talk path finds a ball by its cell
do
  local Spills = require("mods.battle_royale.lib.spills")
  local S = Spills.new({})
  local open = function() return true end
  local spill = Spills.build(7, "ROUTE_1", 5, 5,
    { { species = "PIDGEY", level = 9, hp = 12 } }, open,
    { items = {}, money = 100, name = "A" })
  S:add(spill)
  local mon = spill.mons[1]
  eq(S:keyAt("ROUTE_1", mon.x, mon.y), mon.key, "keyAt finds the ball's cell")
  eq(S:keyAt("ROUTE_1", spill.bag.x, spill.bag.y), spill.bag.key,
     "keyAt finds the bag's cell")
  ok(S:keyAt("ROUTE_2", mon.x, mon.y) == nil, "keyAt is per-map")
  ok(S:keyAt("ROUTE_1", 40, 40) == nil, "an empty cell has no key")
end

-- POK-79: the skin ladder
do
  local Skins = require("mods.battle_royale.lib.skins")
  eq(#Skins.LADDER, 9, "nine skins incl. the original")
  local want = { 0, 1, 3, 5, 10, 15, 20, 25, 30 }
  for i, e in ipairs(Skins.LADDER) do
    eq(e.wins, want[i], "ladder rung " .. i)
  end
  ok(Skins.isUnlocked(Skins.LADDER[1], 0), "RED is free")
  ok(not Skins.isUnlocked(Skins.get("GIOVANNI"), 29), "GIOVANNI holds out at 29")
  ok(Skins.isUnlocked(Skins.get("GIOVANNI"), 30), "GIOVANNI yields at 30")
  eq(Skins.get("nope").id, "RED", "an unknown id falls back to RED")
  eq(#Skins.justUnlocked(0, 1), 1, "the first win unlocks one skin")
  eq(Skins.justUnlocked(0, 1)[1].id, "YOUNGSTER", "and it is the YOUNGSTER")
  eq(#Skins.justUnlocked(3, 5), 1, "3->5 unlocks exactly the SAILOR")
  eq(#Skins.justUnlocked(5, 5), 0, "standing still unlocks nothing")
  -- POK-80: a walk sheet maps back to its trainer class for the PvP pic
  eq(Skins.classForWalk("SPRITE_GIRL"), "OPP_LASS", "LASS's sheet -> OPP_LASS")
  eq(Skins.classForWalk("SPRITE_GIOVANNI"), "OPP_GIOVANNI", "GIOVANNI's sheet -> its class")
  ok(Skins.classForWalk("SPRITE_RED") == nil, "RED has no trainer class")
  ok(Skins.classForWalk("SPRITE_NOPE") == nil, "an unknown sheet has no class")
  ok(Skins.classForWalk(nil) == nil, "nil sheet is safe")
  -- every skin with a class advertises a walk sheet that maps back to it
  for _, e in ipairs(Skins.LADDER) do
    if e.class then
      eq(Skins.classForWalk(e.walk), e.class, "round-trip: " .. e.id)
    end
  end
  -- every wardrobe entry points at shipped data
  local okS, sprites = pcall(require, "data.generated.sprites")
  local okT, trainers = pcall(require, "data.generated.trainers")
  if okS and okT then
    for _, e in ipairs(Skins.LADDER) do
      ok(sprites[e.walk] ~= nil, "walk sheet exists: " .. e.id)
      if e.class then ok(trainers[e.class] ~= nil, "trainer class exists: " .. e.id) end
    end
  end
end

-- POK-78: the fog overlay intensity curve
do
  local FogView = require("mods.battle_royale.lib.fogview")
  local M = FogView.EDGE_MARGIN
  local function inten(d, all) local i = FogView.state(d, all) return i end
  local function puls(d, all) local _, p = FogView.state(d, all) return p end
  eq(inten(nil, false), 0, "no ring -> clean screen")
  eq(inten(-10, false), 0, "deep safe -> clean")
  eq(inten(0, false), 1, "at the ring edge (inside) -> full fog")
  eq(inten(2, false), 1, "out in the fog -> full")
  eq(inten(5, true), 1, "the final ring is full everywhere")
  ok(puls(1, false), "in the fog it pulses")
  ok(puls(5, true), "the final ring pulses")
  ok(not puls(-M / 2, false), "the pre-arrival creep does not pulse")
  -- the creep thickens as the ring nears, while still safe
  local near = inten(-M / 4, false)
  local far = inten(-M * 0.9, false)
  ok(near > far, "the creep thickens as the ring closes")
  ok(near > 0 and near < 1, "and stays a hint, not full fog")
  ok(far > 0, "even at the margin's reach there is a wisp")
  -- pulse() breathes within a shallow band
  ok(FogView.pulse(0) >= 0.78 and FogView.pulse(1.7) <= 1.01, "pulse stays shallow")
end

io.write(("\nbattle royale: %d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
