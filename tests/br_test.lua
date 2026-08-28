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
local Door = require("mods.battle_royale.lib.door")
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
  eq(Wire.PROTOCOL, 10, "a room whose bots carry records is PROTOCOL 10")

  -- botrec (POK-158): the record on the wire
  local br = Wire.decode(Wire.botrec(1001, {
    { species = "PIDGEY", hpFrac = 1 }, { species = "EKANS", hpFrac = 0.4 },
  }))
  ok(br ~= nil, "botrec round-trips")
  eq(br and #br.record, 2, "both mons arrive")
  eq(br and br.record[2].hpFrac, 0.4, "the wound arrives with them")
  ok(Wire.decode({ t = "botrec", id = 1001, mons = {} }) == nil,
     "an empty record is refused")
  ok(Wire.decode({ t = "botrec", id = 1001,
                   mons = { { s = "A", f = "x" } } }) == nil,
     "a wordy hp fraction is refused")
  local clampR = Wire.decode({ t = "botrec", id = 1001,
                               mons = { { s = "MEW", f = 7 } } })
  eq(clampR and clampR.record[1].hpFrac, 1, "fractions clamp to [0,1]")
  -- the bag rides as a field on the record table itself
  local recBag = { { species = "PIDGEY", hpFrac = 1 } }
  recBag.bag = { items = { { id = "POTION", n = 2 } }, money = 750 }
  local withBag = Wire.decode(Wire.botrec(1001, recBag))
  ok(withBag and withBag.record.bag, "the bag rides the record")
  eq(withBag and withBag.record.bag.money, 750, "money intact")
  eq(withBag and withBag.record.bag.items[1].n, 2, "stacks intact")
  ok(Wire.decode({ t = "botrec", id = 1001, mons = { { s = "A", f = 1 } },
                   bag = "nope" }) == nil, "a wordy bag is refused")

  -- ------- the room door (POK-142)
  --
  -- A place says which build it came from, so the room can name the two
  -- numbers that decide whether anyone here can actually fight.
  do
    local mine = { engine = "0.2.31", mod = "0.34.1" }
    local p = Wire.decode(Wire.place("PALLET_TOWN", 1, 2, "down", "alive",
                                     nil, nil, mine))
    ok(p ~= nil, "a place carrying a build still decodes")
    eq(p and p.build and p.build.engine, "0.2.31", "place carries the engine release")
    eq(p and p.build and p.build.mod, "0.34.1", "place carries the mod version")

    -- a bot's place has no build, and that is not the same as a mismatch
    local bot = Wire.decode(Wire.place("PALLET_TOWN", 1, 2, "down", "alive",
                                       nil, 7, nil))
    ok(bot ~= nil, "a place with no build decodes")
    eq(bot and bot.build, nil, "and reports no build at all")
    ok(not Wire.buildDiffers(mine, bot and bot.build),
       "an unknown build is not a mismatch")
    ok(not Wire.buildDiffers(nil, mine), "and neither is an unknown side")

    -- the two mismatches, separately: they are chased in different places
    ok(Wire.buildDiffers(mine, { engine = "0.2.29", mod = "0.34.1" }),
       "a different engine release is a mismatch")
    ok(Wire.buildDiffers(mine, { engine = "0.2.31", mod = "0.34.0" }),
       "a different mod version is a mismatch")
    ok(not Wire.buildDiffers(mine, { engine = "0.2.31", mod = "0.34.1" }),
       "the same build is not")
    -- half-known: compare what both sides actually said and nothing else
    ok(Wire.buildDiffers(mine, { mod = "0.34.0" }),
       "a peer that named only its mod is still compared on it")
    ok(not Wire.buildDiffers(mine, { mod = "0.34.1" }),
       "...and agrees when it matches")

    -- a version off the wire is a stranger's string that lands in a text box
    eq(Wire.cleanVersion("0.34.1"), "0.34.1", "a plain version survives")
    eq(Wire.cleanVersion("0.0.0-dev"), "0.0.0-dev", "so does the dev placeholder")
    eq(Wire.cleanVersion("1.0\n\240RUN"), "1.0RUN", "control bytes are stripped")
    eq(Wire.cleanVersion(string.rep("9", 400)), string.rep("9", 16),
       "and a long one is capped")
    eq(Wire.cleanVersion(""), nil, "an empty version is unknown")
    eq(Wire.cleanVersion("!!!"), nil, "so is one with nothing left after cleaning")
    eq(Wire.cleanVersion(7), nil, "and so is a non-string")

    -- the case that will happen on every wire bump: their BATTLE ROYALE
    -- speaks another PROTOCOL, so the place never decodes at all and the
    -- caller gets a CODE it can branch on rather than a formatted string
    local none, why, code = Wire.decode({ t = "place", v = 8, st = "alive" })
    eq(none, nil, "a place from another protocol is refused")
    ok(why and why:find("protocol"), "and says so")
    eq(code, "protocol", "with a code the caller can act on")
  end

  -- ------- what the door SAYS (lib/door.lua)
  --
  -- The two numbers are chased in two different places -- the GAME wherever
  -- it was installed, the mod from the launcher's Check for updates -- so
  -- telling them apart is the point, not a nicety.
  do
    local mine = { engine = "0.2.31", mod = "0.34.1" }

    local engineOnly = Door.diffs(mine, { engine = "0.2.29", mod = "0.34.1" })
    eq(#engineOnly, 1, "an engine-only mismatch is one diff")
    eq(engineOnly[1].label, "GAME", "and it is the GAME that differs")
    eq(engineOnly[1].theirs, "0.2.29", "carrying their release")
    eq(engineOnly[1].mine, "0.2.31", "and ours")

    local modOnly = Door.diffs(mine, { engine = "0.2.31", mod = "0.34.0" })
    eq(#modOnly, 1, "a mod-only mismatch is one diff")
    eq(modOnly[1].label, "ROYALE", "and it is ROYALE that differs")

    eq(#Door.diffs(mine, { engine = "0.2.29", mod = "0.34.0" }), 2,
       "both wrong is both diffs")
    eq(#Door.diffs(mine, mine), 0, "a matching build has nothing to say")
    eq(Door.sentence("RED", mine, mine), nil, "...and so no sentence")
    eq(#Door.diffs(mine, nil), 0, "an absent build is not a disagreement")

    -- the log's flat form: one grep-able clause per mismatch
    eq(Door.parts(mine, { engine = "0.2.29", mod = "0.34.1" })[1],
       "GAME v0.2.29 (you v0.2.31)", "the log clause names both releases")

    local said = Door.sentence("RED", mine, { engine = "0.2.29", mod = "0.34.1" })
    ok(said and said:find("RED"), "the sentence names the trainer")
    ok(said and said:find("0.2.29", 1, true), "and their release")
    ok(said and said:find("0.2.31", 1, true), "and ours")
    ok(said and said:find("BATTLE"), "and says what it costs them")

    -- EVERY authored line fits the 18-column Gen 1 box, with the longest
    -- name the wire allows (MAX_NAME = 7) and both mismatches at once.
    -- Real version strings, not the 16-char cap: a peer that pads its
    -- version out to the cap only makes the box soft-wrap on a space,
    -- which is untidy rather than wrong.  What this pins is that the
    -- ORDINARY case never wraps, because a version number split across
    -- two lines is the one thing a player has to read exactly.
    local worst = Door.sentence("ABCDEFG", { engine = "0.2.31", mod = "0.34.1" },
                                { engine = "0.2.29", mod = "0.34.0" })
    for line in (worst .. "\n"):gmatch("([^\n]*)\n") do
      ok(#line <= 18, ("door line fits 18 cols (%d): %s"):format(#line, line))
    end
    for line in (Door.oldSentence("ABCDEFG") .. "\n"):gmatch("([^\n]*)\n") do
      ok(#line <= 18, ("old-peer line fits 18 cols (%d): %s"):format(#line, line))
    end
    ok(Door.oldSentence("BLUE"):find("BLUE"), "the old-peer sentence names them too")

    -- ------- the lobby's summary row
    --
    -- STATES A FACT.  Only the host ever reads it -- a mismatched guest is
    -- refused the room outright -- and a host whose guest is the one on
    -- something old must not be told to change their own install.  The
    -- reader-addressed wording belongs to the refusal screen, which is the
    -- one place we know who is behind.
    eq(Door.label(mine, {}), nil, "an empty room needs no warning")
    eq(Door.label(mine, { { build = mine } }), nil, "nor does a matching one")
    eq(Door.label(mine, { { build = { engine = "0.2.29", mod = "0.34.1" } } }),
       "! GAME MISMATCH", "an engine mismatch names the game")
    eq(Door.label(mine, { { build = { engine = "0.2.31", mod = "0.34.0" } } }),
       "! ROYALE MISMATCH", "a mod mismatch names the mod")
    eq(Door.label(mine, { { build = { engine = "0.2.29", mod = "0.34.0" } } }),
       "! BUILD MISMATCH", "one peer can be wrong about both")
    eq(Door.label(mine, { { build = { engine = "0.2.29", mod = "0.34.1" } },
                          { build = { engine = "0.2.31", mod = "0.34.0" } } }),
       "! BUILD MISMATCH", "and so can two peers between them")
    -- a peer we could not decode told us nothing except that their copy of
    -- THIS mod is not ours -- the PROTOCOL that refused them is ours
    eq(Door.label(mine, { { old = true } }), "! ROYALE MISMATCH",
       "an undecodable peer is a mod mismatch")
    eq(Door.label(mine, { { old = true },
                          { build = { engine = "0.2.29", mod = "0.34.1" } } }),
       "! BUILD MISMATCH", "...and stacks with an engine one")
    -- a bot, or anyone who has not said yet: nothing known is not a fault
    eq(Door.label(mine, { { build = nil } }), nil,
       "a peer with no build at all is not a mismatch")

    -- ------- the refusal screen, which IS reader-addressed
    eq(Door.action(Door.diffs(mine, { engine = "0.2.29", mod = "0.34.1" })),
       "UPDATE THE GAME", "an engine mismatch tells the reader to update it")
    eq(Door.action(Door.diffs(mine, { engine = "0.2.31", mod = "0.34.0" })),
       "UPDATE ROYALE", "and a mod mismatch points at the mod")
    eq(Door.action(Door.diffs(mine, { engine = "0.2.29", mod = "0.34.0" })),
       "UPDATE BOTH", "and both at both")
    eq(Door.action({}), nil, "with nothing to say when nothing differs")

    eq(Door.refusalRows(mine, mine), nil, "a matching room is not refused")
    local ref = Door.refusalRows(mine, { engine = "0.2.29", mod = "0.34.1" })
    eq(table.concat(ref, "|"),
       "CANNOT JOIN|UPDATE THE GAME|ROOM HAS|GAME v0.2.29|YOU HAVE|GAME v0.2.31",
       "the refusal names both builds, theirs above ours")
    local both = Door.refusalRows(mine, { engine = "0.2.29", mod = "0.34.0" })
    eq(#both, 8, "both mismatches is eight rows before the OK")
    for _, list in ipairs({ ref, both }) do
      for _, l in ipairs(list) do
        ok(#l <= 17, ("refusal row fits the box (%d): %s"):format(#l, l))
      end
    end
  end

  -- POK-113: what a trainer is doing, for the mark over their head
  local b = Wire.decode(Wire.busy("menu"))
  eq(b and b.kind, "menu", "busy round-trips a menu")

  -- ...and POK-121: the host puts a mark over a BOT's head too, for the
  -- seconds it stands in the grass.  Everything else about a bot is
  -- derived from the seed; this is a decision only the host made, so it
  -- rides the wire the way its steps do.
  local bb = Wire.decode(Wire.busy("battle", 1004))
  eq(bb and bb.kind, "battle", "a bot's mark round-trips")
  eq(bb and bb.as, 1004, "carrying the bot it belongs to")
  eq(Wire.decode(Wire.busy("menu")).as, nil, "a trainer's own mark names nobody")
  eq(Wire.decode(Wire.busy(nil, 1004)).as, 1004,
     "and clearing a bot's mark still says whose")
  eq(Wire.decode({ t = "busy", k = "nonsense", as = 1004 }).as, 1004,
     "an unknown kind still names the actor, so the mark can be cleared")
  eq(Wire.decode(Wire.busy("battle")).kind, "battle", "...and a battle")
  eq(Wire.decode(Wire.busy(nil)).kind, nil, "...and back to nothing")
  ok(Wire.decode(Wire.busy(nil)) ~= nil, "which is a message, not a refusal")
  -- A kind this build has no mark for reads as "not busy".  Dropping it
  -- would leave the LAST mark standing over someone who has moved on,
  -- which is worse than showing nothing.
  eq(Wire.decode({ t = "busy", k = "dancing" }).kind, nil,
     "an unknown kind clears the mark rather than keeping a stale one")
  eq(Wire.decode({ t = "busy", k = 7 }).kind, nil, "and so does a non-string")
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
  local fogged = Wire.decode(Wire.start(9, { { id = 1, map = "ROUTE_1", x = 1, y = 1 } },
                                       0, 180))
  eq(fogged and fogged.fog, 180, "start carries the round's fog length (POK-116)")
  eq(Wire.decode(Wire.start(9, { { id = 1, map = "ROUTE_1", x = 1, y = 1 } })).fog, nil,
     "an older start has none, and the reader falls back to its own option")
  eq(Wire.decode({ t = "start", seed = 9, fog = 0,
                   spawns = { { id = 1, map = "ROUTE_1", x = 1, y = 1 } } }).fog, nil,
     "a zero-length round would divide the match by nothing, so it is dropped")

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

  -- POK-107: the champion's parade, for the whole room to watch
  local fame = Wire.decode(Wire.fame(
    { { species = "PIKACHU", nickname = "SPARKY", level = 42 },
      { species = "ONIX" },
      { level = 9 } },                       -- no species: not a Pokemon
    { catches = 4, beats = 2, steps = 812, rings = 5, seconds = 754, money = 3000 }))
  ok(fame ~= nil, "a parade round-trips")
  eq(fame and #fame.party, 2, "a row with no species never makes the parade")
  eq(fame and fame.party[1].species, "PIKACHU", "the species carries")
  eq(fame and fame.party[1].nickname, "SPARKY", "so does what it was called")
  eq(fame and fame.party[1].level, 42, "and how far it got")
  eq(fame and fame.party[2].nickname, "ONIX", "an unnicknamed mon goes by species")
  eq(fame and fame.stats.seconds, 754, "the record card carries the run")
  eq(fame and fame.stats.rings, 5, "rings and all")

  -- it is drawn, never trusted
  local big = {}
  for i = 1, 40 do big[i] = { sp = "RATTATA", lv = 5 } end
  eq(#Wire.decode({ t = "fame", party = big }).party, 6,
     "a parade is capped at a party, however many were sent")
  eq(Wire.decode({ t = "fame", party = { { sp = "PIKACHU", lv = 9999 } } }).party[1].level,
     100, "an impossible level is clamped rather than drawn")
  ok(Wire.decode({ t = "fame", party = { { lv = 5 } } }) == nil,
     "a party row with no species is refused outright")
  ok(Wire.decode({ t = "fame" }) == nil, "and a parade with no party at all")
  eq(Wire.decode({ t = "fame", party = {} }).stats.catches, 0,
     "a parade with no record card still draws a card")

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

  -- POK-116: the clock that lets an heir carry the fog on
  local timed = Wire.decode(Wire.ring(3, 8, 9, 5.5, "CELADON CITY", 481.5))
  eq(timed and timed.elapsed, 481.5, "a ring carries the host's match clock")
  eq(ring and ring.elapsed, nil, "and is fine without one")
  ok(Wire.decode({ t = "ring", phase = 1, cx = 1, cy = 1, r = 2, e = -3 })
     .elapsed == nil, "a negative clock is dropped, not fatal")
  ok(Wire.decode({ t = "ring", phase = 1, cx = 1, cy = 1, r = 2, e = "soon" })
     .elapsed == nil, "and so is one that is not a number")

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

  -- POK-117: is there fog anywhere yet?  The grace phase is the one stretch
  -- of a match with none, and it is what keeps the Pokemon Centre open.
  ok(not Fog.isUp(Fog.radius(1)),
     "the grace phase has no fog on the board at all")
  for p = 2, Fog.phaseCount() do
    ok(Fog.isUp(Fog.radius(p)),
       "phase " .. p .. " has fog somewhere -- the counter is shut")
  end
  ok(Fog.isUp(Fog.EVERYWHERE), "the endgame is certainly fog")
  ok(not Fog.isUp(Fog.NOWHERE), "and NOWHERE is certainly not")
  ok(not Fog.isUp(nil), "no ring yet is not fog -- the match has not started")

  -- ------- bot goals and pathing (POK-121)
  --
  -- The complaint these answer is a SPECTATOR's: a dead player follows a
  -- bot for minutes, and a random walk over a fifty-cell route reads as
  -- pacing back and forth -- the one behaviour that cannot be mistaken for
  -- a person.  A goal, a real path to it, and a beat spent there is what a
  -- player looks like from outside.
  do
    local Bots = require("mods.battle_royale.lib.bots")

    -- --- the path itself
    local function open6(x, y) return x >= 0 and y >= 0 and x < 6 and y < 6 end
    local p = Bots.path(open6, { x = 0, y = 0 }, { x = 3, y = 2 })
    eq(p and #p, 5, "an open room is walked in Manhattan distance")
    eq(#Bots.path(open6, { x = 1, y = 1 }, { x = 1, y = 1 }), 0,
       "standing on the goal is a path of no steps")
    eq(Bots.path(function() return false end, { x = 0, y = 0 }, { x = 2, y = 2 }),
       nil, "nowhere to walk is nil, not an empty path")
    eq(Bots.path(open6, { x = 0, y = 0 }, { x = 5, y = 5 }, 3), nil,
       "and the node cap gives up rather than stalling the host")

    -- a wall with one gap: the BFS has to go the long way round, which a
    -- greedy step-toward (Bots.approach) cannot
    local function walled(x, y)
      if not open6(x, y) then return false end
      return not (x == 3 and y ~= 5)
    end
    local round = Bots.path(walled, { x = 0, y = 0 }, { x = 5, y = 0 })
    ok(round and #round == 15, "a wall is walked around, not into ("
       .. tostring(round and #round) .. " steps)")
    ok(Bots.approach({ x = 0, y = 0, map = "M" }, function(_, x, y) return walled(x, y) end,
                     { x = 5, y = 0 }) ~= nil,
       "...whereas the stride only ever tries the greedy step")

    -- --- goals
    local function fixedRng(seq)
      local i = 0
      return function(a, b)
        i = i + 1
        local v = seq[i] or 0.5
        if a and b then return math.max(a, math.min(b, math.floor(v))) end
        return v
      end
    end
    local bot = { x = 5, y = 5, map = "ROUTE_X" }

    -- the fog outranks everything a map has to offer
    local g = Bots.chooseGoal(bot, { inFog = true, items = { { x = 1, y = 1 } },
                                     grass = { { x = 2, y = 2 } } }, fixedRng({}))
    eq(g.kind, "seam", "standing in the fog, a bot leaves")
    eq(g.why, "ring", "and it is the ring that moved it")
    eq(Bots.chooseGoal(bot, { ringSoon = true }, fixedRng({})).kind, "seam",
       "a ring about to arrive is reason enough")

    -- loot beats grass: it is already a team, and somebody else paid for it
    local loot = Bots.chooseGoal(bot, { items = { { x = 9, y = 9 } },
                                        grass = { { x = 6, y = 5 } } }, fixedRng({}))
    eq(loot.kind, "item", "a spill on the map is worth more than grass")
    eq(loot.x, 9, "and it walks to the spill")

    -- grass most of the time, but not always, or a bot with grass on its
    -- map would never leave it and the roster would never mix
    local grassGoal = Bots.chooseGoal(bot, { grass = { { x = 12, y = 5 } } },
                                      fixedRng({ 0.1, 0.1 }))
    eq(grassGoal.kind, "grass", "grass is the default errand")
    local left = Bots.chooseGoal(bot, { grass = { { x = 12, y = 5 } } },
                                 fixedRng({ 0.9 }))
    eq(left.kind, "seam", "...but not every time")

    -- ...and grass UNDERFOOT is not an errand.  A bot in a dense patch that
    -- keeps targeting the nearest tuft walks one cell, dwells six seconds,
    -- and does it again -- measured at three cells in a minute, which is
    -- the pacing this whole system exists to remove.
    eq(#Bots.farEnough({ x = 5, y = 5 }, { { x = 6, y = 5 }, { x = 5, y = 4 } }), 0,
       "cells you are standing beside are not somewhere to go")
    eq(#Bots.farEnough({ x = 5, y = 5 }, { { x = 20, y = 5 } }), 1,
       "...and a patch across the route is")
    local underfoot = Bots.chooseGoal(bot, { grass = { { x = 6, y = 5 } },
                                             cells = { { x = 40, y = 40 } } },
                                      fixedRng({ 0.1, 0.1 }))
    ok(underfoot.kind ~= "grass",
       "so a bot already in the grass finds something else to do")
    -- ...and a map with NO errand still has to move the bot.  Returning
    -- "seam" here froze five of six bots solid in the first measured run:
    -- towns have no grass, and homeward will not move a bot already
    -- nearest the eye, so nothing was left to step them.
    local strollCells = {}
    for i = 1, 20 do strollCells[i] = { x = i, y = 20 } end
    local stroll = Bots.chooseGoal(bot, { cells = strollCells }, fixedRng({ 0.9 }))
    eq(stroll.kind, "stroll", "a map with no errand is still walked")
    ok(math.abs(stroll.x - bot.x) + math.abs(stroll.y - bot.y) >= 8,
       "and the stroll aims FAR, not at the next cell over")
    eq(Bots.chooseGoal(bot, {}, fixedRng({ 0.9 })).kind, "seam",
       "only a map with nowhere to walk at all is a map to leave")

    -- nearest, which is what makes a walk look aimed
    eq(Bots.nearest({ x = 0, y = 0 },
                    { { x = 9, y = 9 }, { x = 2, y = 1 }, { x = 5, y = 5 } }).x, 2,
       "the nearest cell is the one picked")
    eq(Bots.nearest({ x = 0, y = 0 }, {}), nil, "and nothing is nil")

    -- a dwell for every kind chooseGoal can return, or a bot arrives
    -- somewhere and stands there forever on a nil comparison
    for _, kind in ipairs({ "grass", "item", "ring", "seam" }) do
      ok(type(Bots.DWELL[kind]) == "number",
         "every goal kind has a dwell: " .. kind)
    end
    ok(Bots.DWELL.grass > Bots.DWELL.item,
       "grass is the long beat -- it has to read as a battle")

    -- ------- tiers (POK-121)
    --
    -- Rolled from (seed, id) like the name and the face, because whoever
    -- walks into a bot fights it LOCALLY: a disagreement about its team is
    -- a disagreement about who won.
    local t1 = Bots.tier(4242, Bots.idFor(3))
    eq(Bots.tier(4242, Bots.idFor(3)).id, t1.id, "a tier is stable for a bot")
    ok(Bots.tier(4243, Bots.idFor(3)).id ~= nil, "and another seed still gives one")
    local spread = {}
    for i = 1, 40 do
      local t = Bots.tier(99, Bots.idFor(i))
      spread[t.id] = (spread[t.id] or 0) + 1
    end
    ok((spread.ROOKIE or 0) > 0 and (spread.REGULAR or 0) > 0
       and (spread.ACE or 0) > 0, "a full roster draws all three tiers")
    ok((spread.ROOKIE or 0) > (spread.ACE or 0),
       "weighted toward ROOKIE -- an ACE you meet every match is not an ACE")

    -- THE non-negotiable: one mon at the drop, whatever the tier.  Two made
    -- a bot the favourite in every opening fight and broke the
    -- build-a-team arc, which is the whole reason this is a curve.
    for _, tier in ipairs(Bots.TIERS) do
      eq(Bots.partySize(tier, 5), 1, tier.id .. " drops with one mon")
      eq(Bots.partySize(tier, 100), tier.maxParty,
         tier.id .. " is at full strength by the last rung")
      -- monotonic: a bot never sheds a Pokemon as the match runs
      local last = 0
      for _, lv in ipairs({ 5, 15, 30, 50, 75, 100 }) do
        local n = Bots.partySize(tier, lv)
        ok(n >= last, tier.id .. " never shrinks its party (" .. lv .. ")")
        last = n
      end
    end
    ok(Bots.partySize(Bots.TIERS[3], 75) > Bots.partySize(Bots.TIERS[1], 75),
       "an ACE has built more team by the late ring than a ROOKIE")
    eq(Bots.partySize(nil, 100), 1, "no tier at all is still a legal party")

    -- the pools differ, and every species in them is real (checked against
    -- the live dataset in the party block further down)
    ok(Bots.pool(Bots.TIERS[1]) ~= Bots.pool(Bots.TIERS[3]),
       "a ROOKIE and an ACE do not draw from the same pool")

    -- aggression: the one thing a bot can express by walking
    local aceRoam = Bots.roamSeconds(20, Bots.TIERS[3])
    local rookieRoam = Bots.roamSeconds(20, Bots.TIERS[1])
    ok(aceRoam < rookieRoam, "an ACE crosses a seam sooner than a ROOKIE")
    ok(Bots.roamSeconds(20) == rookieRoam,
       "and no tier at all is the old behaviour exactly")
    ok(Bots.roamSeconds(2, Bots.TIERS[3]) >= 4,
       "no tier turns the endgame into a blur")
  end

  -- a bot's party is its tier's, at the rung, and every species is real
  do
    local Bots = require("mods.battle_royale.lib.bots")
    local data = { pokemon = {} }
    for _, tier in ipairs(Bots.TIERS) do
      for _, s in ipairs(Bots.pool(tier)) do data.pokemon[s] = true end
    end
    for _, tier in ipairs(Bots.TIERS) do
      local pool = {}
      for _, s in ipairs(Bots.pool(tier)) do pool[s] = true end
      -- find a bot of this tier and check what it brings
      for i = 1, 60 do
        local id = Bots.idFor(i)
        if Bots.tier(7, id).id == tier.id then
          local party = Bots.party(7, id, data, 100)
          eq(#party, tier.maxParty, tier.id .. " brings a full party at rung 100")
          for _, slot in ipairs(party) do
            eq(slot.level, 100, "every slot rides the rung")
            ok(pool[slot.species],
               tier.id .. " draws only from its own pool: " .. slot.species)
          end
          eq(#Bots.party(7, id, data, 5), 1, tier.id .. " drops with one")
          break
        end
      end
    end
    -- a build missing the tier's species degrades rather than asserting
    local thin = { pokemon = { RATTATA = true } }
    local fallback = Bots.party(7, Bots.idFor(1), thin, 100)
    ok(#fallback >= 1, "a thin dataset still yields a party")
    eq(fallback[1].species, "RATTATA", "...falling back to what exists")
  end

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
  ok(Fog.isSafe(locations, "FARAWAY", center, Fog.radius(1)),
     "everything is in at phase 1")
  ok(Fog.isSafe(locations, "NOWHERE", center, 1.5),
     "a map with no square is never punished")

  -- ------- the town map overlay's own geometry (POK-146)
  --
  -- The location grid sits 2 tiles in and 1 down on the 20x18 screen
  -- (pokered TownMapCoordsToOAMCoords; TownMap.markerXY).  Comparing raw
  -- screen tiles against the ring's centre drew the safe region a town up
  -- and left: the fog announced PEWTER CITY (2,3) and the bright square
  -- sat over INDIGO PLATEAU (0,2) -- whose SCREEN cell is exactly (2,3).
  do
    -- Pewter as the eye: its own screen cell is clear, Indigo's is not
    local pewter = { x = 2, y = 3 }
    ok(not Fog.shadesTile(pewter, 2, 2 + Fog.MAP_OX, 3 + Fog.MAP_OY),
       "the announced eye's own screen square stays bright")
    ok(Fog.shadesTile(pewter, 2, 2, 3),
       "the square the bug used to brighten (Indigo's) is shaded")
    -- the 2026-08-27 log's known-good ring: eye LAVENDER TOWN (14,5)
    local lavender = { x = 14, y = 5 }
    ok(not Fog.shadesTile(lavender, 9, 14 + Fog.MAP_OX, 5 + Fog.MAP_OY),
       "Lavender's screen square is bright when Lavender is the eye")
    ok(Fog.shadesTile(lavender, 9, 0, 0),
       "the far corner is fog")
    ok(Fog.shadesTile(lavender, Fog.EVERYWHERE, 14 + Fog.MAP_OX, 5 + Fog.MAP_OY),
       "a closed ring shades even the eye")
    ok(not Fog.shadesTile(lavender, Fog.NOWHERE, 0, 0),
       "the opening radius shades nothing on screen")
  end

  -- ------- which map the ring is asked about, indoors (POK-140)
  --
  -- The counter in a POKeMON CENTER shuts when the fog reaches THAT town,
  -- not when it reaches any town.  An interior has no square on this grid,
  -- so the question has to be re-pointed at the town the door opens onto.
  do
    eq(Fog.outdoorFor(locations, "HOME", "FARAWAY"), "HOME",
       "a placeable map answers for itself, whatever was remembered")
    eq(Fog.outdoorFor(locations, "POKECENTER", "FARAWAY"), "FARAWAY",
       "an interior defers to the outdoor map it was entered from")
    eq(Fog.outdoorFor(locations, "POKECENTER", nil), nil,
       "and says nothing when there is nothing to defer to")
    eq(Fog.outdoorFor(nil, "HOME", "FARAWAY"), "FARAWAY",
       "no grid at all is the same as unplaceable")

    -- the bug this fixes, stated as the two answers that used to be one:
    -- with the ring closed on HOME, the CENTER in HOME stays open and the
    -- one out in FARAWAY does not
    local inHome = Fog.outdoorFor(locations, "POKECENTER", "HOME")
    local inFar = Fog.outdoorFor(locations, "POKECENTER", "FARAWAY")
    ok(Fog.isSafe(locations, inHome, center, 1.5),
       "the CENTER in the safe town is still open")
    ok(not Fog.isSafe(locations, inFar, center, 1.5),
       "...and the one the ring has reached is not")
    -- ...and during the grace phase neither of them shuts, on the same
    -- rule rather than on a separate isUp() guard
    ok(Fog.isSafe(locations, inHome, center, Fog.radius(1))
       and Fog.isSafe(locations, inFar, center, Fog.radius(1)),
       "at phase 1 every counter is open")
    -- ...and at the end, none of them is
    ok(not Fog.isSafe(locations, inHome, center, Fog.EVERYWHERE),
       "when the fog covers Kanto even the home counter shuts")
  end
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

-- ------- phase 1 really is no fog anywhere (POK-93)
--
-- The grace period was arithmetic in a comment: phase 1's radius was 15 and
-- the comment called that "larger than the grid's diagonal", when 15 is the
-- grid's WIDTH and its diagonal is 21.22.  Real Kanto fell through the gap
-- -- LAVENDER_TOWN (14,5) is 15.62 squares from CINNABAR_ISLAND (2,15) --
-- so a Cinnabar eye put a Lavender lander in the fog on the frame they
-- touched the ground.  This checks the geometry against the shipped
-- location table and against the corners of the board, not against prose.

do
  local Fog = require("mods.battle_royale.lib.fog")

  -- the whole board, whatever the data says: every corner from every corner
  local corners = { { x = 0, y = 0 }, { x = 15, y = 0 },
                    { x = 0, y = 15 }, { x = 15, y = 15 } }
  local grid = {}
  for j, p in ipairs(corners) do grid["C" .. j] = { x = p.x, y = p.y } end
  local allCorners = true
  for _, c in ipairs(corners) do
    for j = 1, #corners do
      if not Fog.isSafe(grid, "C" .. j, c, Fog.radius(1)) then allCorners = false end
    end
  end
  ok(allCorners, "phase 1 reaches corner to corner of the 16x16 grid")
  ok(Fog.radius(1) > math.sqrt(15 * 15 + 15 * 15),
     "phase 1's radius clears the grid's true diagonal ("
     .. tostring(Fog.radius(1)) .. " > 21.22)")

  local okField, field = pcall(dofile, "data/generated/field.lua")
  local locations = okField and type(field) == "table"
    and field.townMap and field.townMap.locations
  if not locations then
    io.write("  (skipping the real-Kanto phase-1 sweep: no imported data)\n")
  else
    -- every placed map must be safe at phase 1 from every place the eye
    -- can land.  The eye is drawn from townList(), which is towns and
    -- cities; sweeping EVERY placed square is stricter and cheap.
    local worst, worstPair = -1, nil
    local unsafe = {}
    for centreId, c in pairs(locations) do
      if c.x and c.y then
        local centre = { x = c.x, y = c.y, id = centreId }
        for mapId, l in pairs(locations) do
          if l.x and l.y then
            local dx, dy = l.x - c.x, l.y - c.y
            local d = dx * dx + dy * dy
            if d > worst then worst, worstPair = d, centreId .. " -> " .. mapId end
            if not Fog.isSafe(locations, mapId, centre, Fog.radius(1))
               and #unsafe < 4 then
              unsafe[#unsafe + 1] = centreId .. " -> " .. mapId
            end
          end
        end
      end
    end
    ok(#unsafe == 0, "no placed map is in the fog at phase 1"
       .. (#unsafe > 0 and (": " .. table.concat(unsafe, ", ")) or ""))
    ok(Fog.radius(1) > math.sqrt(worst),
       ("phase 1 clears Kanto's widest pair (%s, %.2f squares)")
       :format(tostring(worstPair), math.sqrt(worst)))
    -- the pair that actually shipped the bug, named so a future radius
    -- change cannot quietly re-open it
    if locations.LAVENDER_TOWN and locations.CINNABAR_ISLAND then
      local c = locations.CINNABAR_ISLAND
      ok(Fog.isSafe(locations, "LAVENDER_TOWN",
                    { x = c.x, y = c.y, id = "CINNABAR_ISLAND" }, Fog.radius(1)),
         "a Lavender drop is safe under a Cinnabar eye at phase 1")
      ok(not Fog.isSafe(locations, "LAVENDER_TOWN",
                        { x = c.x, y = c.y, id = "CINNABAR_ISLAND" }, Fog.radius(2)),
         "and is in the fog once the ring actually shrinks")
    end
  end
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

-- ------- the bag obeys the doorway rule too (POK-94)
--
-- The balls go through placeAround and its predicate; the BAG lands on the
-- cell its owner fell on, which is what makes it read as "this is where
-- they went down" -- and is the one placement the predicate never saw.  A
-- player cannot stand still on a warp, but a BOT walks on plain tile
-- walkability and could stop in a doorway, and a bag on a mart's door
-- shuts that building for the match exactly as a ball would.

do
  local Spills = require("mods.battle_royale.lib.spills")
  local bag = { items = { { id = "POTION", n = 1 } }, money = 500, name = "SAM" }
  local everywhere = function() return true end
  local door = function(x, y) return x == 5 and y == 5 end

  -- no rule supplied: the old behaviour, the bag lands where they fell
  local plain = Spills.build(1, "M", 5, 5, {}, everywhere, bag)
  eq(plain.bag.x .. "," .. plain.bag.y, "5,5", "with no rule the bag lands on the spot")

  -- with the doorway rule, it steps off
  local moved = Spills.build(1, "M", 5, 5, {}, everywhere, bag, door)
  ok(not (moved.bag.x == 5 and moved.bag.y == 5),
     "a bag aimed at a door does not stay on it")
  ok(math.abs(moved.bag.x - 5) <= 1 and math.abs(moved.bag.y - 5) <= 1,
     "and lands right beside it (" .. moved.bag.x .. "," .. moved.bag.y .. ")")

  -- an ordinary cell is left exactly alone
  local fine = Spills.build(1, "M", 9, 9, {}, everywhere, bag, door)
  eq(fine.bag.x .. "," .. fine.bag.y, "9,9", "a cell that is not a door is untouched")

  -- the relocation still respects walkability: only the one free neighbour
  local onlyOne = function(x, y) return (x == 4 and y == 5) or (x == 5 and y == 5) end
  local tight = Spills.build(1, "M", 5, 5, {}, onlyOne, bag, door)
  eq(tight.bag.x .. "," .. tight.bag.y, "4,5",
     "it moves to a cell the balls would have taken")

  -- and a spill of balls around a door still puts none on it
  local spill = Spills.build(1, "M", 4, 5, { { species = "RATTATA", level = 5, hp = 1 },
                                             { species = "PIDGEY", level = 5, hp = 1 },
                                             { species = "ODDISH", level = 5, hp = 1 } },
                             function(x, y) return not door(x, y) end, bag, door)
  local onDoor = 0
  for _, m in ipairs(spill.mons) do
    if door(m.x, m.y) then onDoor = onDoor + 1 end
  end
  eq(onDoor, 0, "no ball lands on the door either")
  eq(#spill.mons, 3, "and every ball still gets placed")
end

-- ------- you never engage what you cannot see (POK-96)

do
  local Engage = require("mods.battle_royale.lib.engage")

  -- the faithful Game Boy view: 160x144 world pixels, camera centred
  eq(Engage.visibleRange("left", 160), 5,
     "a 160px-wide view reaches five cells along a row, not six")
  eq(Engage.visibleRange("right", 160), 5, "the same the other way")
  eq(Engage.visibleRange("up", 144), 4, "and four down a column")
  eq(Engage.visibleRange("down", 144), 4, "the same downward")
  ok(Engage.visibleRange("left", 160) < Engage.RANGE,
     "which is a real cut from the tuned row range")
  eq(Engage.visibleRange("up", 144), Engage.RANGE_Y,
     "while the column range was already honest")

  -- capped, never extended: a wider window must not buy a longer eyeline,
  -- or the biggest monitor spots everyone first
  eq(Engage.visibleRange("left", 1600), Engage.RANGE,
     "a zoomed-out view is still held to the tuned range")
  eq(Engage.visibleRange("up", 1600), Engage.RANGE_Y, "on the column too")

  -- and a view so small nothing would be visible still leaves one cell:
  -- the trainer standing directly in front of you is always engageable
  eq(Engage.visibleRange("left", 16), 1, "a tiny view still sees the next cell")
  eq(Engage.visibleRange("left", nil), Engage.RANGE,
     "an unaskable renderer falls back to the tuned range")
  eq(Engage.visibleRange("left", 0), Engage.RANGE, "so does a zero span")

  -- ...and the cell a trainer is engaged ON is the one they are DRAWN on
  -- (POK-96).  A ghost replays steps at walking pace, so it trails the
  -- wire; engaging off the wire opens a fight against somebody this screen
  -- has not put anywhere yet.
  do
    local Ghosts = require("mods.battle_royale.lib.ghosts")
    local ghosts = setmetatable({ ghosts = {} }, { __index = Ghosts })
    local npc = { cellX = 3, cellY = 7 }
    ghosts._handle = function(_, g) return g.here and { npc = npc } or nil end
    ghosts.ghosts.a = { mapId = "M", npcId = 1, queue = {}, here = true }
    ghosts.ghosts.b = { mapId = "M", npcId = 2, queue = {} }   -- no handle
    local x, y = ghosts:cellOf("a")
    eq(x .. "," .. y, "3,7", "cellOf reports where the ghost is standing")
    ok(ghosts:cellOf("b") == nil, "and nil for a ghost with no live NPC")
    ok(ghosts:cellOf("nobody") == nil, "or for a peer we have never drawn")
    -- an NPC that has not been given a cell yet is not a position either
    ghosts.ghosts.c = { mapId = "M", npcId = 3, queue = {}, here = true }
    npc.cellX = nil
    ok(ghosts:cellOf("c") == nil, "nor one with no cell yet")
  end

  -- the cap really shortens the line the target search walks
  local me = { x = 0, y = 0, facing = "right", status = "alive" }
  local far = { id = 2, map = nil, x = 6, y = 0, status = "alive" }
  eq(Engage.target(me, { far }, { range = Engage.RANGE }), 2,
     "six cells away is a target at the tuned range")
  ok(Engage.target(me, { far }, { range = Engage.visibleRange("right", 160) }) == nil,
     "and is not one once the frame has its say")
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

    -- a doorway is not a floor (POK-94).  A warp tile is walkable BY
    -- DESIGN -- you have to be able to step on it -- so walkability alone
    -- happily let a spilled ball land on the VIRIDIAN mart's door, and a
    -- solid ball on a warp shuts that building for the whole match, for
    -- everyone, because every client lays the same spill out.
    local doors = (maps.VIRIDIAN_CITY or {}).warps or {}
    ok(#doors > 0, "VIRIDIAN_CITY has doors to test (" .. #doors .. ")")
    local walkableDoors, caught = 0, 0
    for _, w in ipairs(doors) do
      if Spawn.walkable(maps, tilesets, "VIRIDIAN_CITY", w.x, w.y) then
        walkableDoors = walkableDoors + 1
        if Spawn.isWarp(maps, "VIRIDIAN_CITY", w.x, w.y) then caught = caught + 1 end
      end
    end
    ok(walkableDoors > 0,
       "and its doors really are walkable tiles (" .. walkableDoors .. ")")
    eq(caught, walkableDoors, "isWarp catches every one of them")
    ok(not Spawn.isWarp(maps, "VIRIDIAN_CITY", 0, 0),
       "and does not cry warp on an ordinary cell")
    ok(not Spawn.isWarp(maps, "NOT_A_MAP", 1, 1), "an unknown map has no warps")
    ok(not Spawn.isWarp(nil, "VIRIDIAN_CITY", 23, 25), "nor does no map table")

    -- the placement search must route around a door rather than stack on
    -- it: aim a four-ball spill right at one and check none of them land
    local door = doors[1]
    if door then
      local Spills = require("mods.battle_royale.lib.spills")
      local cells = Spills.placeAround(door.x, door.y, 4, function(x, y)
        return Spawn.walkable(maps, tilesets, "VIRIDIAN_CITY", x, y)
           and not Spawn.isWarp(maps, "VIRIDIAN_CITY", x, y)
      end)
      local onADoor = 0
      for _, c in ipairs(cells) do
        if Spawn.isWarp(maps, "VIRIDIAN_CITY", c.x, c.y) then onADoor = onADoor + 1 end
      end
      eq(onADoor, 0, "a spill aimed at a door puts nothing on it")
      eq(#cells, 4, "and still places every ball")
    end
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

-- ------------------------------------------------------------------
-- POK-110: a TM that says what it teaches
-- ------------------------------------------------------------------
do
  local Machines = require("mods.battle_royale.lib.machines")

  -- a hand-built data handle first, so the rules are checked without a ROM
  local fake = {
    moves = {
      MEGA_PUNCH = { name = "MEGA PUNCH" },
      CUT = { name = "CUT" },
      GHOST_MOVE = { name = "" },
    },
    items = {
      TM_MEGA_PUNCH = { name = "TM01", machine = { kind = "TM", move = "MEGA_PUNCH" } },
      HM_CUT        = { name = "HM01", machine = { kind = "HM", move = "CUT" } },
      POTION        = { name = "POTION" },
      TM_UNKNOWN    = { name = "TM99", machine = { kind = "TM", move = "NO_SUCH_MOVE" } },
      TM_NAMELESS   = { name = "TM98", machine = { kind = "TM", move = "GHOST_MOVE" } },
    },
  }

  local saved = Machines.apply(fake)
  eq(fake.items.TM_MEGA_PUNCH.name, "MEGA PUNCH", "a TM says what it teaches")
  eq(fake.items.HM_CUT.name, "CUT", "and so does an HM")
  eq(fake.items.POTION.name, "POTION", "an ordinary item is left alone")
  -- a machine this build cannot resolve keeps its number rather than
  -- becoming a blank row in the bag
  eq(fake.items.TM_UNKNOWN.name, "TM99", "a move the build lacks is left alone")
  eq(fake.items.TM_NAMELESS.name, "TM98", "and so is a move with no name")

  eq(saved.TM_MEGA_PUNCH, "TM01", "the way back is recorded")
  eq(saved.POTION, nil, "and records only what actually changed")

  -- The rename rides on game.data, which is the ENGINE's and shared with
  -- the player's real save -- so the way out has to be exact.
  eq(Machines.restore(fake, saved), 2, "restore puts back both machines")
  eq(fake.items.TM_MEGA_PUNCH.name, "TM01", "TM01 is TM01 again")
  eq(fake.items.HM_CUT.name, "HM01", "HM01 is HM01 again")

  -- Applying twice without restoring is a no-op the second time, so its
  -- `saved` is empty: the call site must guard, and this pins the reason.
  local first = Machines.apply(fake)
  local second = Machines.apply(fake)
  ok(next(first) ~= nil, "the first apply has a way back")
  ok(next(second) == nil, "a second apply has none -- the call site guards")
  Machines.restore(fake, first)
  eq(fake.items.TM_MEGA_PUNCH.name, "TM01", "and the first way back still works")

  ok(Machines.nameFor(fake, nil) == nil, "no def, no name")
  ok(Machines.nameFor(fake, { name = "POTION" }) == nil, "no machine, no name")
  ok(Machines.apply(nil) ~= nil, "apply survives a data handle with no items")
  eq(Machines.restore(nil, saved), 0, "and restore does too")

  -- ...then against the real table, which is where a wrong field shows up.
  -- Required HERE: the gyms block's okD/Data are locals inside that block,
  -- so reading them from this one silently skips everything below and the
  -- suite passes having checked nothing.
  local okD, Data = pcall(require, "src.core.Data")
  ok(okD and Data ~= nil, "the real data module loaded, so the rest is real")
  if okD and Data and Data.load then
    pcall(function() Data:load() end)
    if Data.items and Data.moves then
      local realSaved = Machines.apply(Data)
      local machines, longest = 0, 0
      for id, def in pairs(Data.items) do
        if def.machine then
          machines = machines + 1
          ok(type(def.name) == "string" and not def.name:match("^[TH]M%d"),
             id .. " no longer reads as a number")
          if #def.name > longest then longest = #def.name end
        end
      end
      eq(machines, 55, "fifty TMs and five HMs")
      ok(longest <= 12,
         "the longest machine name is " .. longest .. ", which the bag box fits")
      eq(Data.items.TM_SEISMIC_TOSS and Data.items.TM_SEISMIC_TOSS.name,
         "SEISMIC TOSS", "TM19 reads SEISMIC TOSS")
      eq(Data.items.HM_CUT and Data.items.HM_CUT.name, "CUT", "HM01 reads CUT")
      eq(Data.items.POTION and Data.items.POTION.name, "POTION",
         "and a POTION is still a POTION")

      Machines.restore(Data, realSaved)
      eq(Data.items.TM_SEISMIC_TOSS and Data.items.TM_SEISMIC_TOSS.name, "TM19",
         "and every one of them goes back, so a real save never sees this")
      eq(Data.items.HM_CUT and Data.items.HM_CUT.name, "HM01", "HMs included")
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

-- ------- and at the player's pace, not an NPC's (POK-97)
--
-- The stutter POK-70 could not cure was a RATE mismatch, not arrival
-- jitter: Player steps a cell in 16 frames, NPC in 32, and a ghost is a
-- replay of somebody else's player.  Fed one step per 16 frames and
-- playing one per 32, the queue gained a step it could not spend every
-- other step, overran MAX_BACKLOG in about a second and a half of steady
-- walking, and resolved as a teleport.
--
-- This drives _syncOne frame by frame against a handle that actually
-- models how long a step takes, so the failure is the observable one: a
-- snap during a walk nobody interrupted.

do
  local Ghosts = require("mods.battle_royale.lib.ghosts")

  -- a peer walking steadily: one committed step every `arrivalFrames`
  local function walkFor(frames, stepFrames, arrivalFrames)
    local h = { left = 0, snaps = 0, steps = 0 }
    local handle = {
      setPassable = function() end,
      isMoving = function() return h.left > 0 end,
      stepNow = function() h.left = stepFrames; h.steps = h.steps + 1 end,
      position = function() return 0, 0 end,
      placeAt = function() h.snaps = h.snaps + 1 end,
      face = function() end,
    }
    local ghosts = setmetatable({ ghosts = {} }, { __index = Ghosts })
    ghosts._handle = function() return handle end
    ghosts.ghosts.x = { mapId = "M", queue = {}, npcId = 1 }
    -- the peer never leaves the cell we report, so the only thing that can
    -- call placeAt is the backlog overrun itself
    local peer = { map = "M", x = 0, y = 0, facing = "down", status = "alive" }
    for f = 1, frames do
      if f % arrivalFrames == 0 then ghosts:pushStep("x", "up") end
      ghosts:_syncOne(nil, "x", "M", peer)
      if h.left > 0 then h.left = h.left - 1 end
    end
    return h
  end

  -- ten seconds of walking, one step arriving every 16 frames
  local slow = walkFor(600, 32, 16)
  ok(slow.snaps > 0,
     "an NPC-paced ghost still snaps during a steady walk (" .. slow.snaps .. ")")
  local matched = walkFor(600, 16, 16)
  eq(matched.snaps, 0, "a player-paced one never does")
  ok(matched.steps > 30,
     "and it walks the whole way instead (" .. matched.steps .. " steps)")

  -- the spawn really pins it, read off a stubbed world
  local spawned = {}
  local handle = { npc = spawned, setPassable = function() end }
  local mod = {
    log = { warn = function() end },
    world = {
      spawnNpc = function() return 7 end,
      removeNpc = function() return true end,
      npc = function() return handle end,
      overworld = function() return { player = { stepFrames = 16 } } end,
    },
  }
  local ghosts = Ghosts.new(mod)
  ghosts:_spawn(nil, "x", "M", 3, 4, "down", { status = "alive" })
  eq(spawned.stepFrames, 16, "a fresh ghost is given the player's step length")

  -- a build that retimes walking retimes the ghosts with it
  mod.world.overworld = function() return { player = { stepFrames = 8 } } end
  ghosts:_spawn(nil, "y", "M", 3, 4, "down", { status = "alive" })
  eq(spawned.stepFrames, 8, "whatever this build's player step actually is")

  -- ...and no overworld at all must not crash a spawn
  mod.world.overworld = function() return nil end
  ghosts:_spawn(nil, "z", "M", 3, 4, "down", { status = "alive" })
  ok((spawned.stepFrames or 0) > 0, "with a sane fallback when there is no world")
end

-- ------- the world does not pause because our screen did (POK-98)

do
  local Ghosts = require("mods.battle_royale.lib.ghosts")
  local ticked = {}
  local map = { id = "M" }
  local function npcFor(name)
    return { update = function(_, m, e) ticked[#ticked + 1] = name .. ":" .. tostring(m.id) end }
  end
  local here, away = npcFor("here"), npcFor("away")
  local ghosts = setmetatable({ ghosts = {} }, { __index = Ghosts })
  ghosts._handle = function(_, g)
    return { npc = (g.mapId == "M") and here or away,
             ow = { map = map, entities = {} } }
  end
  ghosts.ghosts.a = { mapId = "M", npcId = 1, queue = {} }
  ghosts.ghosts.b = { mapId = "OTHER", npcId = 2, queue = {} }

  ghosts:advance("M")
  eq(#ticked, 1, "only the ghosts on our own map are advanced")
  eq(ticked[1], "here:M", "and they are advanced against that map")
  ghosts:advance(nil)
  eq(#ticked, 1, "no map, nothing to advance")
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

  -- An edge is only a way out where the step actually CROSSES.  Pewter's
  -- fenced south-east corner touches the south edge, but ROUTE_2 is half
  -- Pewter's width and every landing from that stretch clamps onto a
  -- tree -- a real player was dropped there with no Fly and no way out.
  local okData, maps = pcall(dofile, "data/generated/maps.lua")
  local okTs, tilesets = pcall(dofile, "data/generated/tilesets.lua")
  if okData and okTs and maps and tilesets and maps.PEWTER_CITY then
    local def = maps.PEWTER_CITY
    local ts = tilesets[def.tileset]
    local pocket = {}
    for _, c in ipairs(Spawn.cellsOf(def, ts, maps, tilesets)) do
      if c.x >= 36 and c.y >= 26 then pocket[#pocket + 1] = c.x .. "," .. c.y end
    end
    eq(#pocket, 0, "nobody drops in Pewter's fenced corner ("
       .. table.concat(pocket, " ") .. ")")
    ok(#Spawn.cellsOf(def, ts, maps, tilesets) > 500,
       "the town square is still a drop zone")
  else
    print("skip: Pewter corner pin (no generated Kanto data)")
  end
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

  -- POK-147: the deal only avoids sharing WHILE MAPS REMAIN, so the pool
  -- has to be at least the roster.  Eleven fly towns under thirty bots
  -- wrapped into 2-3 per town, all in sight-line at t=0, and 18 of 31
  -- trainers were gone before the player met anybody.  The bot deal now
  -- draws from every outdoor map the Town Map can place (BR:botDropSpots);
  -- this pins that Kanto actually offers Bots.MAX of them.
  do
    local okData, maps = pcall(dofile, "data/generated/maps.lua")
    local okField, field = pcall(dofile, "data/generated/field.lua")
    local locs = okField and field and field.townMap and field.townMap.locations
    if okData and maps and locs then
      local Map = require("src.world.Map")
      local spots = 0
      for id, def in pairs(maps) do
        if Map.isOutdoor(def) and locs[id] then spots = spots + 1 end
      end
      ok(spots >= Bots.MAX,
         "enough placeable outdoor maps that a full deal never wraps ("
         .. spots .. " for " .. Bots.MAX .. " bots)")
    else
      print("skip: bot drop pool (no generated Kanto data)")
    end
  end

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

  -- ------- the record (POK-158 M1): a team a bot BUILDS, not a synth

  local rec = Bots.newRecord(4242, 1001, nil)
  eq(#rec, 1, "one mon at the drop, whatever the tier")
  eq(rec[1].hpFrac, 1, "and it is healthy")
  eq(Bots.newRecord(4242, 1001, nil)[1].species, rec[1].species,
     "the drop mon is derived: two lazy creations agree")

  eq(Bots.recordCap(), 6, "every bot builds to a full six, like a player")

  local team = {
    { species = "PIDGEY", hpFrac = 1 },
    { species = "RATTATA", hpFrac = 0 },     -- fainted last fight
    { species = "EKANS", hpFrac = 0.4 },
  }
  local rows, idx = Bots.fightRows(team, 30)
  eq(#rows, 2, "a fainted mon does not fight")
  eq(rows[1].species, "PIDGEY", "record order holds")
  eq(rows[2].species, "EKANS", "the hurt one still answers the bell")
  eq(rows[1].level, 30, "every fight is at the rung")
  eq(idx[2], 3, "idx maps each row back to its record slot")
  eq(#Bots.spillRows(team, 30), 3, "the spill counts the fallen too")

  -- the fight ends; the enemyParty rows land back on the right mons
  Bots.scarRecord(team, idx, {
    { hp = 12, stats = { hp = 48 } },        -- PIDGEY down to a quarter
    { hp = 0, stats = { hp = 40 } },         -- EKANS fainted
  })
  eq(team[1].hpFrac, 0.25, "damage carries out of the fight")
  eq(team[2].hpFrac, 0, "an untouched fainted mon stays fainted")
  eq(team[3].hpFrac, 0, "a mon lost in the fight is recorded lost")
  ok(Bots.recordAlive(team), "one healthy mon is still a trainer")
  ok(not Bots.recordAlive({ { species = "A", hpFrac = 0 } }),
     "a wiped record is not")

  -- catches: capped by tier, paced by chance, drawn from the map's table
  local slots = { { species = "CATERPIE", level = 4 } }
  local always = function(a, b) if a then return a end return 0 end
  local never = function(a, b) if a then return a end return 0.99 end
  local r2 = { { species = "MANKEY", hpFrac = 1 } }
  eq(Bots.rollCatch(r2, 2, slots, always), "CATERPIE", "a dwell can catch")
  eq(#r2, 2, "and the team grew")
  eq(r2[2].hpFrac, 1, "a fresh catch is healthy")
  eq(Bots.rollCatch(r2, 2, slots, always), nil, "the cap is the cap")
  eq(Bots.rollCatch({ {} }, 6, slots, never), nil, "most dwells catch nothing")
  eq(Bots.rollCatch({ {} }, 6, {}, always), nil, "no grass table, no catch")

  -- ------- the records fight (POK-158 M3)

  local sim = { pokemon = {
    BIG = { baseStats = { hp = 100, attack = 100, defense = 100,
                          speed = 100, special = 100 } },
    SMALL = { baseStats = { hp = 20, attack = 20, defense = 20,
                            speed = 20, special = 20 } },
  } }
  eq(Bots.recordPower({ { species = "BIG", hpFrac = 1 } }, sim), 500,
     "power is the base-stat total")
  eq(Bots.recordPower({ { species = "BIG", hpFrac = 0.5 },
                        { species = "SMALL", hpFrac = 0 } }, sim), 250,
     "wounds scale it and faints zero it")
  eq(Bots.recordPower({ { species = "WHO", hpFrac = 1 } }, nil), 300,
     "an unplaceable species gets the middling default")

  local recA = { { species = "BIG", hpFrac = 1 } }
  local recB = { { species = "SMALL", hpFrac = 1 } }
  eq(Bots.resolveFight(recA, recB, sim, function() return 0.5 end), "a",
     "the stronger team usually wins")
  eq(recA[1].hpFrac, 0.8, "and pays a fifth of itself for a small win")
  local recA2 = { { species = "BIG", hpFrac = 1 } }
  local recB2 = { { species = "SMALL", hpFrac = 1 } }
  eq(Bots.resolveFight(recA2, recB2, sim, function() return 0.9 end), "b",
     "an upset stays possible")
  eq(recB2[1].hpFrac, 0.1, "and the underdog barely stands")
  ok(Bots.recordAlive(recB2), "a winner is never wiped by its own win")

  -- who wants the nurse (POK-158 M2)
  ok(Bots.wantsHeal({ { hpFrac = 0.4 } }), "half a team down wants healing")
  ok(Bots.wantsHeal({ { hpFrac = 1 }, { hpFrac = 0 } }), "a faint always does")
  ok(not Bots.wantsHeal({ { hpFrac = 1 }, { hpFrac = 0.8 } }),
     "scratches walk it off")
  ok(not Bots.wantsHeal({}), "an empty record wants nothing")

  -- ...and the errand ladder honours it
  local sick = { x = 5, y = 5 }
  local g = Bots.chooseGoal(sick, { heal = { x = 9, y = 9 },
                                    items = { { x = 6, y = 5 } } },
                            function() return 0 end)
  eq(g.kind, "heal", "a hurt team walks to the Centre before the loot")
  eq(Bots.chooseGoal(sick, { inFog = true, heal = { x = 9, y = 9 } },
                     function() return 0 end).kind, "seam",
     "but never into the fog")

  -- ------- the bag lives (POK-158 M2/M4)

  local hurtRec = { { species = "A", hpFrac = 0.3 },
                    { species = "B", hpFrac = 0.5 } }
  local bag = { items = { { id = "POKE_BALL", n = 2 },
                          { id = "SUPER_POTION", n = 1 },
                          { id = "POTION", n = 1 } }, money = 500 }
  local used, onto = Bots.quaff(hurtRec, bag)
  eq(used, "POTION", "the weakest potion that helps goes first")
  eq(onto and onto.species, "A", "onto the most-hurt mon standing")
  eq(hurtRec[1].hpFrac, 0.6, "and it helps")
  eq(#bag.items, 2, "the empty bottle leaves the bag")
  eq(Bots.quaff({ { species = "A", hpFrac = 0.9 } }, bag), nil,
     "nobody hurt, nothing drunk")
  eq(Bots.quaff({ { species = "A", hpFrac = 0 } }, bag), nil,
     "a potion cannot raise the fainted")
  local drained = { { species = "A", hpFrac = 0.2 } }
  eq(Bots.quaff(drained, { items = { { id = "POKE_BALL", n = 9 } } }), nil,
     "no medicine, no gulp")

  Bots.bagMerge(bag, { items = { { id = "POKE_BALL", n = 3 },
                                 { id = "TM_ICE_BEAM", n = 1 } },
                       money = 250 })
  eq(bag.money, 750, "the money adds")
  local counts = {}
  for _, it in ipairs(bag.items) do counts[it.id] = it.n end
  eq(counts.POKE_BALL, 5, "stacks merge by id")
  eq(counts.TM_ICE_BEAM, 1, "new items append")

  eq(Bots.tmMove("TM_ICE_BEAM"), "ICE_BEAM", "a TM names its move")
  eq(Bots.tmMove("POTION"), nil, "a potion does not")
  ok(Bots.canLearn({ tmhm = { [13] = "ICE_BEAM", [15] = "SWIFT" } },
                   "ICE_BEAM"), "tmhm says yes")
  ok(not Bots.canLearn({ tmhm = { [15] = "SWIFT" } }, "ICE_BEAM"),
     "and no")
  ok(not Bots.canLearn(nil, "ICE_BEAM"), "an unknown species learns nothing")
end

-- ------- the endgame hunt (POK-95)
--
-- A playtest watched a match get down to three survivors who then paced
-- their own maps until the fog decided it.  Same-map hunting already
-- worked; nothing pulled a bot ACROSS a seam toward anybody.

do
  local Bots = require("mods.battle_royale.lib.bots")

  -- the seam clock tightens as the roster thins
  eq(Bots.roamSeconds(20), Bots.ROAM_SECONDS, "a full lobby ambles")
  ok(Bots.roamSeconds(Bots.HUNT_FROM) < Bots.ROAM_SECONDS,
     "a thinning one crosses seams more often")
  ok(Bots.roamSeconds(3) < Bots.roamSeconds(Bots.HUNT_FROM),
     "and the last few sooner still")
  ok(Bots.roamSeconds(nil) == Bots.ROAM_SECONDS,
     "an unknown roster ambles rather than sprints")
  local prev = 0
  for n = 2, 20 do
    local s = Bots.roamSeconds(n)
    ok(s >= prev, "the clock never tightens as the field GROWS (" .. n .. ")")
    prev = s
  end

  -- Bots.homeward ranks exits by whatever distance it is handed, which is
  -- what lets the same routine walk a bot at the ring's eye early and at
  -- the nearest trainer late.  Prove it moves toward a target rather than
  -- toward a fixed centre.
  local rng = Bots.rng(1, 1)
  -- three exits; B is the one nearest the prey
  local toPrey = { A = 25, B = 4, C = 16 }
  eq(Bots.homeward({ "A", "B", "C" }, function(m) return toPrey[m] end, 36, rng),
     "B", "the seam that closes on the prey is the one walked")
  -- ...and it holds when nothing is closer than standing still, which is
  -- the same-map case the tick's own prey search takes over
  ok(Bots.homeward({ "A", "B", "C" }, function(m) return toPrey[m] end, 0, rng) == nil,
     "already nearest: hold, and let the same-map hunt do the work")

  -- an unplaceable map ranks last rather than winning by being nil
  local partial = { A = nil, B = 9 }
  eq(Bots.homeward({ "A", "B" }, function(m) return partial[m] end, 100, rng),
     "B", "a map the Town Map cannot place is not a shortcut")
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

-- ------- the ladder never climbs mid-fight (POK-91)
--
-- scaleMon replaces mon.stats wholesale and can evolve the thing standing
-- on the field, and BattleState's battlers alias the very party tables it
-- rewrites -- so a fog shrink that landed during a battle took a Lv5 lead
-- to Lv15 between turns.  The guard used to be `BR.status ~= "battle"` at
-- the call site, and `status` only says "battle" for a PvP duel or a bot
-- fight: a WILD encounter or one of Kanto's own trainers left it "alive"
-- and levelled straight through the fight.
--
-- tickLevels needs a whole Game to run, so this reads the source: the
-- battle guard must be inside the function and must come before the first
-- thing that mutates a party.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the mid-fight scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local body = src:match("function BR:tickLevels%(%)(.-)\n  end\n")
    ok(body ~= nil, "found BR:tickLevels in main.lua")
    if body then
      local guardAt = body:find("liveLocalBattle", 1, true)
      local scaleAt = body:find("needsScaling", 1, true)
      ok(guardAt ~= nil, "tickLevels asks liveLocalBattle before it scales")
      ok(scaleAt ~= nil, "tickLevels is still the thing that scales")
      ok(guardAt and scaleAt and guardAt < scaleAt,
         "the battle guard comes before any party is touched")
      -- the guard must be a RETURN, not a log line
      ok(body:match("liveLocalBattle%(%)%s*then%s*return") ~= nil,
         "and it returns rather than carrying on")
    end
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
        -- the deep-log switch the DEBUG LOG row reads (POK-86)
        debugOn = false,
        isDebug = function(self) return self.debugOn end,
        statsOn = function(self) return self.stats ~= false end,
        setStatsOn = function(self, on) self.stats = on and true or false return self.stats end,
        setDebug = function(self, on) self.debugOn = on and true or false end,
        cycleSafari = function(self) self.cycledSafari = true end,
        -- the room door (POK-142): no trouble unless a test says so
        buildTrouble = function(self, id) return (self.trouble or {})[id] end,
        buildTroubleLabel = function(self) return self.troubleLabel end,
        buildOf = function(self) return self.myBuild end,
        myBuild = { engine = "0.2.31", mod = "0.34.1" },
        -- trainers the door turned away: none unless a test stages some
        flaggedAbsent = function(self) return self.absent or {} end,
        clearRefusal = function(self) self.refused = nil end,
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

    -- ------- no face may run off the bottom of the screen (POK-104)
    --
    -- The box height was `#items * rowStep + 2` flat, which is right for a
    -- fixed list and wrong for this one: the hosted lobby grows a row per
    -- trainer in the room on top of the host's settings, so a real room
    -- pushed START MATCH and LEAVE off the canvas with no way to reach
    -- them -- the screen that starts matches could not start one.  Menu
    -- knew how to scroll all along; nobody had set maxVisible.
    do
      local cap = BRMenu.maxRows(2)
      eq(cap, 8, "eight double-spaced rows fit the 18-tile canvas")
      eq(BRMenu.maxRows(), cap, "row step 2 is the default")
      ok(BRMenu.maxRows(1) > cap, "a tighter row step fits more")
      ok(BRMenu.maxRows(99) >= 1, "and an absurd one still leaves a row")

      -- the first face must fit outright: it is the one nobody scrolls
      local first = BRMenu.items({ version = "0.0.0" }, fakeBR(), {})
      ok(#first <= cap,
         "the first face fits on one screen (" .. #first .. "/" .. cap .. ")")

      -- ...and the hosted lobby is the one that does not, which is the
      -- whole reason the cap has to exist
      local crowd = {}
      for i = 1, 6 do crowd[i] = { id = i, name = "P" .. i } end
      local lobbyBR = fakeBR({ relay = room(true, { members = crowd }) })
      local lobby, lobbyView = BRMenu.items({ version = "0.0.0" }, lobbyBR, {})
      eq(lobbyView, "lobby", "a room with a host is the lobby face")
      ok(#lobby > cap,
         "a full lobby overflows one screen (" .. #lobby .. " rows)")
      -- the rows that were falling off are the ones you cannot do without
      ok(find(lobby, "START MATCH") ~= nil, "START MATCH is in the list")
      ok(find(lobby, "LEAVE") ~= nil, "so is LEAVE")

      -- one row per member, so this grows without bound as a room fills:
      -- a cap is the only thing that can hold it
      local bigger = BRMenu.items({ version = "0.0.0" },
        fakeBR({ relay = room(true, { members = (function()
          local m = {}
          for i = 1, 12 do m[i] = { id = i, name = "P" .. i } end
          return m
        end)() }) }), {})
      ok(#bigger > #lobby, "a fuller room is a longer list still")
    end

    -- ------- the door marks the lobby (POK-142)
    --
    -- The roster is where somebody waiting is actually looking, and it
    -- needs no script runner -- which matters, because this screen opens
    -- from the TITLE as well as from the start menu, and with no overworld
    -- under it there is nothing to queue a text box onto at all.
    do
      local marked = fakeBR({
        relay = room(true),
        trouble = { [2] = "build" },
        troubleLabel = "! UPDATE THE GAME",
      })
      local rows = labels(BRMenu.items({ version = "0.0.0" }, marked, {}))
      ok(rows:find("- RED*|", 1, true),
         "an agreeing trainer keeps their plain row, host star and all")
      ok(rows:find("- BLUE!|", 1, true), "and the one the door flagged wears a !")

      -- the mark sits against the NAME, ahead of the host's asterisk: the
      -- Gen 1 font draws no asterisk, so a "!" after one floats a blank
      -- cell away from the trainer it accuses
      local host = labels(BRMenu.items({ version = "0.0.0" }, fakeBR({
        relay = room(true), trouble = { [1] = "build" },
        troubleLabel = "! UPDATE ROYALE",
      }), {}))
      ok(host:find("- RED!*|", 1, true),
         "a flagged host wears the ! before the star: " .. host)
      ok(rows:find("! UPDATE THE GAME", 1, true),
         "with one row saying which number to chase")

      ok(rows:find("YOU ARE ON:", 1, true), "and our own numbers under it")
      ok(rows:find("ROYALE v0.34.1", 1, true), "the mod version we are running")
      ok(rows:find("GAME v0.2.31", 1, true), "and the engine release")

      -- a trainer the door turned away leaves a trace, because on the host
      -- that trace is the only sign they were ever there
      local bounced = labels(BRMenu.items({ version = "0.0.0" }, fakeBR({
        relay = room(true),
        troubleLabel = "! GAME MISMATCH",
        absent = { { id = 9, name = "GUESTB",
                     build = { engine = "9.9.9", mod = "0.34.1" } } },
      }), {}))
      ok(bounced:find("! GUESTB|", 1, true),
         "the turned-away trainer is listed under the roster: " .. bounced)
      -- ------- the face a refused guest actually lands on
      --
      -- Not a text box: this screen opens from the TITLE as well as the
      -- start menu, so there is not always an overworld to queue a say
      -- onto, and teardown's own message is documented as lost on the way
      -- to the title (POK-115).  The explanation has to BE the screen.
      do
        local refusedBR = fakeBR({
          refused = { rows = { "CANNOT JOIN", "UPDATE THE GAME", "ROOM HAS",
                               "GAME v0.2.31", "YOU HAVE", "GAME v9.9.9" } },
        })
        local items, view = BRMenu.items({ version = "0.0.0" }, refusedBR, {})
        eq(view, "refused", "a refused client gets its own face")
        local list = labels(items)
        ok(list:find("CANNOT JOIN|", 1, true), "which says it cannot join")
        ok(list:find("GAME v0.2.31|", 1, true), "names the room's build")
        ok(list:find("GAME v9.9.9|", 1, true), "and ours")
        local okRow = find(items, "OK")
        ok(okRow ~= nil, "with a way out of it")
        okRow.onSelect()
        eq(refusedBR.refused, nil, "which clears the refusal")
        eq(select(2, BRMenu.items({ version = "0.0.0" }, refusedBR, {})), "menu",
           "and lands back on the first face")

        -- a refusal outranks the plain menu but never a running match
        local mid = fakeBR({ refused = { rows = { "CANNOT JOIN" } },
                             phase = "match" })
        eq(select(2, BRMenu.items({ version = "0.0.0" }, mid, {})), "match",
           "a match already running outranks a stale refusal")

        for _, it in ipairs(BRMenu.items({ version = "0.0.0" }, fakeBR({
          refused = { rows = Door.refusalRows(
            { engine = "0.2.31", mod = "0.34.1" },
            { engine = "0.2.29", mod = "0.34.0" }) },
        }), {})) do
          ok(#it.label <= 17,
             ("refusal face row fits (%d): %s"):format(#it.label, it.label))
        end
      end

      -- ...and a fightable room says none of it.  The "!" is the whole
      -- signal, so nothing else in this face may carry one.
      local clean = labels(BRMenu.items({ version = "0.0.0" },
                                        fakeBR({ relay = room(true) }), {}))
      ok(not clean:find("!", 1, true),
         "a fightable room has no ! anywhere in it: " .. clean)
      ok(not clean:find("YOU ARE ON:", 1, true),
         "and does not spend rows on numbers nobody needs")

      -- fit() sizes the box to the widest label + 3 against a 20-tile
      -- canvas, so a label past 17 characters is clipped off the right
      -- with nothing to say it happened.  The door added the longest rows
      -- this face has ever carried, so it brings the check with it.
      for _, br in ipairs({ marked, fakeBR({ relay = room(true) }) }) do
        for _, it in ipairs(BRMenu.items({ version = "0.34.1" }, br, {})) do
          ok(#it.label <= 17,
             ("lobby row fits the box (%d): %s"):format(#it.label, it.label))
        end
      end
    end

    -- the first face: every row keeps the screen, because the room it
    -- starts is what turns the screen into the lobby
    local BR = fakeBR()
    local items, view = BRMenu.items({ version = "9.9.9" }, BR, {})
    eq(view, "menu", "no room is the first face")
    eq(labels(items), "QUICK PLAY|SOLO VS BOTS|HOST GAME|JOIN BY CODE|NAME: RED|SKIN: RED|SERVER...|v9.9.9",
       "the first face, in order")
    -- the stamp is read off the loader's own mod.version, never written
    -- here, so it cannot drift from the manifest
    eq(labels(BRMenu.items({ version = "1.2.3" }, fakeBR(), {})):match("[^|]+$"),
       "v1.2.3", "the row reports whatever version the loader handed the mod")
    eq(labels(BRMenu.items({}, fakeBR(), {})):match("[^|]+$"), "v?",
       "and says so plainly when there is no version to read")
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
    eq(labels(items), "BOTS: 3|FOG: 120s|SAFARI: 120s|DEBUG LOG: OFF|SEND STATS: ON|START MATCH|LEAVE",
       "solo: bots, the two clocks, start, leave")
    find(items, "FOG").onSelect()
    ok(BR.cycledFog, "the FOG row cycles the fog clock (POK-44)")
    -- BR_DEBUG could never work in the game (the mod sandbox hides the
    -- environment), so the deep tier is a row like any other knob
    find(items, "DEBUG LOG: OFF").onSelect()
    ok(BR:isDebug(), "the DEBUG LOG row turns the deep tier on (POK-86)")
    items = BRMenu.items({}, BR, {})
    ok(find(items, "DEBUG LOG: ON") ~= nil, "and the row says so next frame")
    find(items, "DEBUG LOG: ON").onSelect()
    ok(not BR:isDebug(), "...and back off")
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
       "CODE ABCDEF|- RED*|- BLUE|OPEN: NO|BOTS: 3|FOG: 120s|SAFARI: 120s|DEBUG LOG: OFF|SEND STATS: ON|FILL: OFF|TRAINERS: 5|START MATCH (12)|LEAVE",
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
    -- The match is over, and this face is now only the moment between the
    -- winner being named and endMatch taking the exit (POK-144) -- the
    -- START menu is open at "over" (POK-84), so it is still reachable and
    -- still reads as a result: no live level, no ring that stopped
    -- closing, no count of who is still standing.  PLAY AGAIN is NOT here
    -- any more; it is the lobby's own start row, below.
    BR.phase = "over"
    BR.relay = room(true)
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "MATCH OVER|LEAVE MATCH",
       "over, as the host: no run-it-back row on the match face")
    BR.relay = room(false)
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "MATCH OVER|LEAVE MATCH",
       "over, as a guest: the same two rows")
    -- still standing when it ended means you are the one left standing
    BR.status = "alive"
    items = BRMenu.items({}, BR, {})
    eq(labels(items), "YOU WIN!|LEAVE MATCH", "the champion is told so")
    BR.status = "out"

    -- ------- T8: the finished match lands on the LOBBY face, carrying its
    -- result (POK-144).  This is the screen every terminal route reaches
    -- now, so it is the screen that has to say what happened -- there is no
    -- overworld under it to queue a say onto.
    BR.phase, BR.status, BR.relay = "lobby", "lobby", room(true)
    BR.solo = true
    BR.lastResult = { won = true, at = 0 }
    items, view = BRMenu.items({}, BR, {})
    eq(view, "lobby", "a finished match lands on the LOBBY face, not the match one")
    ok(labels(items):find("YOU WIN!", 1, true), "and the lobby says so")
    ok(labels(items):find("PLAY AGAIN", 1, true),
       "the host's start row reads PLAY AGAIN")
    ok(not labels(items):find("START MATCH", 1, true), "...and not both")
    BR.lastResult = { won = false, name = "SAM", at = 0 }
    items = BRMenu.items({}, BR, {})
    ok(labels(items):find("MATCH OVER", 1, true), "a loss says so plainly")
    ok(labels(items):find("SAM WON", 1, true),
       "a loss names the trainer who did not lose")
    BR.lastResult = nil
    items = BRMenu.items({}, BR, {})
    ok(labels(items):find("START MATCH", 1, true), "a fresh room is a fresh room")
    ok(not labels(items):find("MATCH OVER", 1, true), "...with nothing to report")

    -- ------- T9: and the first face too, when the room went with the
    -- match.  A relay that closed means there is nothing to go back to, so
    -- the screen offers the ways to start again -- with the result ON the
    -- version row rather than above it.
    --
    -- That is not a stylistic choice.  This face is EXACTLY maxRows(2) long
    -- (the assertion further up says so in as many words), so a row of its
    -- own would push the build number off the bottom behind a scroll arrow
    -- -- the regression POK-104 exists to prevent, on the one line a
    -- refused player is asked to read out.  The suite asserted the
    -- invariant and its violation in the same file for one round; it
    -- asserts the invariant here too so that cannot happen twice.
    BR.relay = nil
    BR.solo = false
    --
    -- The version here is the WIDEST this mod can realistically stamp, not
    -- a round "9.9.9": the folded row is "YOU LOST v" plus the version, so
    -- the fixture is what decides whether the 17-character assertion below
    -- means anything at all.  "0.36.10" makes it exactly 17 -- the last one
    -- that fits.  One more character and fit() sizes the box to 21 tiles on
    -- a 20-tile canvas and clips the build number off the right, which is
    -- the whole reason the row exists.
    local WIDEST = "0.36.10"
    BR.lastResult = { won = false, name = "SAM", at = 0 }
    items, view = BRMenu.items({ version = WIDEST }, BR, {})
    eq(view, "menu", "no room left is the first face")
    eq(labels(items),
       "QUICK PLAY|SOLO VS BOTS|HOST GAME|JOIN BY CODE|NAME: RED|SKIN: RED|SERVER...|YOU LOST v0.36.10",
       "the result rides ON the version row, and the winner's name is dropped")
    ok(#items <= BRMenu.maxRows(2),
       ("the first face still fits with a result on it (%d/%d)")
       :format(#items, BRMenu.maxRows(2)))
    BR.lastResult = { won = true, at = 0 }
    items = BRMenu.items({ version = WIDEST }, BR, {})
    ok(labels(items):find("YOU WIN! v0.36.10", 1, true),
       "a win reads as a win on the same row")
    eq(#items, BRMenu.maxRows(2), "...still eight rows, not nine")
    for _, it in ipairs(items) do
      ok(#it.label <= 17,
         ("first-face row fits the box (%d): %s"):format(#it.label, it.label))
    end
    BR.lastResult = nil
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
-- POK-102: a room of one says nothing
--
-- The relay fans `all` out to every OTHER member, so a solo room forwards
-- every frame to nobody.  Count what actually reaches the transport rather
-- than what a peer receives -- with no peer there is no other side to look
-- at, and the whole point is the bytes that never leave.
-- ------------------------------------------------------------------
do
  local hub = Hub.new()
  local wire = hub:connect()
  local sent = { all = 0, to = 0 }
  local rawSend = wire.send
  wire.send = function(self, msg)
    local t = type(msg) == "table" and msg.type
    if t == "all" then sent.all = sent.all + 1
    elseif t == "to" then sent.to = sent.to + 1 end
    return rawSend(self, msg)
  end

  local host = Relay.new({ transport = wire })

  -- Before the room exists there is no roster to trust, so a broadcast goes
  -- out rather than being swallowed on a guess.
  host:broadcast(Wire.face("down", "PALLET_TOWN"))
  eq(sent.all, 1, "with no roster yet, a broadcast still goes out")

  host:host("RED")
  host:update()
  eq(#host.members, 1, "a room of one knows it is a room of one")

  for _ = 1, 5 do host:broadcast(Wire.face("down", "PALLET_TOWN")) end
  eq(sent.all, 1, "a solo room puts no `all` frame on the wire")
  eq(host.suppressed, 5, "and counts every frame it withheld")
  ok(host:broadcast(Wire.out()) == true,
     "a suppressed broadcast still reports success -- nothing failed")
  eq(host.suppressed, 6, "including that one")

  -- `to` is a different path and is never gated: it names its recipient.
  host:send(host.id, Wire.challenge(1))
  eq(sent.to, 1, "a unicast is untouched by the gate")

  -- The moment somebody else is in the room, the fan-out resumes.
  local guest = Relay.new({ transport = hub:connect() })
  local guestInbox = {}
  guest:on("message", function(from, m) guestInbox[#guestInbox + 1] = m end)
  guest:join("ROOM01", "BLUE")
  guest:update()
  host:update()
  eq(#host.members, 2, "the roster grew")
  host:broadcast(Wire.place("ROUTE_1", 3, 4, "down", "alive", "SPRITE_RED"))
  guest:update()
  eq(sent.all, 2, "with a peer present the frame goes out again")
  eq(#guestInbox, 1, "and the peer actually receives it")
  eq(host.suppressed, 6, "nothing further was withheld")

  -- ...and when they leave, the room is quiet again.
  guest:leave()
  host:update()
  eq(#host.members, 1, "the roster shrank back to one")
  host:broadcast(Wire.out())
  eq(sent.all, 2, "the last trainer standing talks to nobody")
  eq(host.suppressed, 7, "which is one more frame withheld")
end

-- ------------------------------------------------------------------
-- POK-119: the rod grows with the ring
-- ------------------------------------------------------------------
do
  local Rods = require("mods.battle_royale.lib.rods")
  local Levels = require("mods.battle_royale.lib.levels")

  eq(#Rods.LADDER, #Levels.LADDER,
     "one rod per rung: the rod and the level ride the same clock")
  eq(Rods.FIRST, "OLD_ROD", "everyone drops with the OLD ROD")
  eq(Rods.at(1), "OLD_ROD", "the opening is an OLD ROD")
  eq(Rods.at(3), "GOOD_ROD", "the middle rings hand up a GOOD ROD")
  eq(Rods.at(6), "SUPER_ROD", "and the endgame a SUPER ROD")

  -- the ladder only ever climbs
  local worst = 0
  for _, id in ipairs(Rods.LADDER) do
    ok(Rods.rank(id) >= worst, "the ladder never hands back a worse rod")
    worst = Rods.rank(id)
  end

  -- out-of-range phases clamp rather than reading nil into the bag
  eq(Rods.at(0), "OLD_ROD", "a phase below the ladder is the first rung")
  eq(Rods.at(99), "SUPER_ROD", "and one past the end is the last")
  eq(Rods.at(nil), "OLD_ROD", "no phase at all is the first rung")

  ok(Rods.isBetter("SUPER_ROD", "GOOD_ROD"), "SUPER beats GOOD")
  ok(Rods.isBetter("OLD_ROD", nil), "any rod beats no rod")
  ok(not Rods.isBetter("OLD_ROD", "SUPER_ROD"), "and OLD never beats SUPER")
  ok(not Rods.isBetter("SUPER_ROD", "SUPER_ROD"), "a rod does not beat itself")
end

-- ------------------------------------------------------------------
-- POK-118: the Safari zone rotates
-- ------------------------------------------------------------------
do
  local Safari = require("mods.battle_royale.lib.safari")

  local a1 = Safari.pool(12345, nil)
  local a2 = Safari.pool(12345, nil)
  eq(#a1, Safari.POOL_SIZE, "a match's zone holds POOL_SIZE species")
  eq(table.concat(a1, ","), table.concat(a2, ","),
     "the same seed draws the same zone -- everyone drafts from one list")

  local b = Safari.pool(54321, nil)
  ok(table.concat(a1, ",") ~= table.concat(b, ","),
     "a different match is a different zone, which is the whole point")

  local seen = {}
  for _, sp in ipairs(a1) do
    ok(not seen[sp], "no species is in the zone twice: " .. tostring(sp))
    seen[sp] = true
  end

  -- every draw is a real candidate
  local cand = {}
  for _, sp in ipairs(Safari.CANDIDATES) do cand[sp] = true end
  local allKnown = true
  for _, sp in ipairs(a1) do allKnown = allKnown and cand[sp] end
  ok(allKnown, "a zone is drawn from the candidate list and nowhere else")

  -- a build missing most of the list degrades instead of asserting
  local thin = Safari.pool(7, { pokemon = { RATTATA = true, ONIX = true } })
  eq(#thin, 2, "a zone can only hold species this build actually has")
  local poor = Safari.pool(7, { pokemon = {} })
  eq(#poor, 1, "and a build with none of them still yields something catchable")
  eq(poor[1], "RATTATA", "namely a RATTATA, which Kanto can always find")

  -- picking within a zone
  local rolled = Safari.pick(a1, function(lo, hi) return lo end)
  eq(rolled, a1[1], "pick draws through the caller's own roll")
  ok(Safari.pick({}, function() return 1 end) == nil, "an empty zone yields nobody")
  ok(Safari.pick(nil, nil) == nil, "and neither does no zone at all")

  -- the pool is a set, so the order it is written in cannot leak through
  local sorted = true
  for i = 2, #a1 do sorted = sorted and (a1[i - 1] <= a1[i]) end
  ok(sorted, "a zone comes back in a stable order")
end

-- ------------------------------------------------------------------
-- POK-108: a trainer in a doorway is not a door plug
-- ------------------------------------------------------------------
do
  local Ghosts = require("mods.battle_royale.lib.ghosts")
  -- one map, one door: the mart's, at 29,19 on the real VIRIDIAN_CITY
  local maps = { VIRIDIAN_CITY = { warps = { { x = 29, y = 19,
                                               destMap = "VIRIDIAN_MART" } } } }

  ok(not Ghosts.passableFor(maps, "VIRIDIAN_CITY", { x = 10, y = 10, status = "alive" }),
     "a living trainer in the open is solid -- you cannot walk through somebody")
  ok(Ghosts.passableFor(maps, "VIRIDIAN_CITY", { x = 10, y = 10, status = "out" }),
     "an eliminated one is walk-through, so a corpse cannot wall a survivor in")
  ok(Ghosts.passableFor(maps, "VIRIDIAN_CITY", { x = 29, y = 19, status = "alive" }),
     "and one standing IN the mart's door is too, or the shop shuts for good (POK-94)")
  ok(Ghosts.passableFor(maps, "VIRIDIAN_CITY", { x = 29, y = 19, status = "battle" }),
     "mid-battle in a doorway seals it just as thoroughly")
  ok(not Ghosts.passableFor(maps, "VIRIDIAN_CITY", { x = 29, y = 20, status = "alive" }),
     "the cell beside the door is not the door")
  ok(not Ghosts.passableFor(maps, "PALLET_TOWN", { x = 29, y = 19, status = "alive" }),
     "and the door is this map's, not that coordinate on every map")
  ok(not Ghosts.passableFor(maps, "VIRIDIAN_CITY", nil),
     "no peer at all is not a hole in the world")
end

-- ------------------------------------------------------------------
-- POK-116: the room outlives its host
-- ------------------------------------------------------------------
do
  local hub = Hub.new()
  local host = Relay.new({ transport = hub:connect() })
  local a = Relay.new({ transport = hub:connect() })
  local b = Relay.new({ transport = hub:connect() })
  local aClosed, bClosed = nil, nil
  a:on("closed", function(r) aClosed = r or "nil" end)
  b:on("closed", function(r) bClosed = r or "nil" end)

  host:host("RED")
  host:update()
  a:join(host.code, "BLUE")
  b:join(host.code, "GREEN")
  a:update(); b:update(); host:update()
  -- both guests offer to take the room over, as wireRelay does on joining
  a:canHost(true)
  b:canHost(true)
  ok(not a:isHost(), "a guest is not the host to begin with")

  host:leave()
  a:update(); b:update()
  ok(aClosed == nil and bClosed == nil, "the room did not close under them")
  ok(a:isHost(), "the longest-standing eligible guest inherits the room")
  ok(not b:isHost(), "and the other one does not")
  eq(b.hostId, a.id, "everybody agrees who the host is now")

  -- and it is a working room: the new host's broadcasts still reach the rest
  local got = nil
  b:on("message", function(from, m) got = { from = from, m = m } end)
  a:broadcast(Wire.ring(2, 8, 9, 9, "CELADON CITY", 240))
  b:update()
  eq(got and got.from, a.id, "the new host's word carries the new host's id")
  eq(got and Wire.decode(got.m).elapsed, 240, "clock and all")
end

-- ------------------------------------------------------------------
-- POK-116: a room nobody can inherit still closes
-- ------------------------------------------------------------------
do
  local hub = Hub.new()
  local host = Relay.new({ transport = hub:connect() })
  local guest = Relay.new({ transport = hub:connect() })
  local closed = nil
  guest:on("closed", function(r) closed = r or "nil" end)

  host:host("RED")
  host:update()
  guest:join(host.code, "BLUE")
  guest:update(); host:update()
  -- the guest never offers: an older client, or one already eliminated
  host:leave()
  guest:update()
  ok(closed ~= nil, "the room closes when nobody can take it over")
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
  -- fromText is an RFC 0014 seam, native since gen1recomp v0.2.26 --
  -- seams_test is what asserts it is really there (POK-29)
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

-- The `key=value` store under both the career and the stats.  Tested on its
-- own because it is now shared: a change here moves two files at once, and
-- "the career round-trips" would not say which half broke.
do
  local KeyFile = require("mods.battle_royale.lib.keyfile")

  eq(KeyFile.trim("  RED  "), "RED", "trim takes both ends")
  eq(KeyFile.trim(""), "", "...and an empty string survives it")

  local f = KeyFile.parse("a=1\nb = two \n")
  eq(f.a, "1", "a row parses")
  eq(f.b, "two", "...and both sides are trimmed")

  eq(KeyFile.parse("name=A=B").name, "A=B", "the FIRST = splits, so a value may hold more")
  eq(next(KeyFile.parse("")), nil, "an empty file parses to nothing")
  eq(next(KeyFile.parse(nil)), nil, "and so does a missing one")
  eq(next(KeyFile.parse("not a row")), nil, "a line with no = is dropped")
  eq(KeyFile.parse("a=1\r\nb=2\r\n").b, "2", "CRLF is a line ending too")
  eq(KeyFile.parse("a=1\na=2\n").a, "2", "a later row wins")
  eq(KeyFile.parse("a=\n").a, "", "a valueless row is present and empty")

  eq(KeyFile.encode({ { "a", "1" }, { "b", "2" } }), "a=1\nb=2\n",
     "encode writes the pairs in order, one per line")
  eq(KeyFile.encode({ { "a", "1" }, { "b", nil }, { "c", "3" } }), "a=1\nc=3\n",
     "a nil value writes no line at all")

  -- the round trip is the property that matters: the parser must read back
  -- what the encoder wrote, for every value the callers can produce
  local pairs_ = { { "id", "0123456789abcdef" }, { "since", "2026-08-27" },
                   { "solo", "17" }, { "off", "0" } }
  local back = KeyFile.parse(KeyFile.encode(pairs_))
  for _, kv in ipairs(pairs_) do
    eq(back[kv[1]], kv[2], "round trip: " .. kv[1])
  end

  eq(KeyFile.count("3"), 3, "count reads a number out of a string")
  eq(KeyFile.count(-1), 0, "a negative count is none")
  eq(KeyFile.count(2.7), 2, "a fractional count is floored")
  eq(KeyFile.count("nope"), 0, "and a word is none")
  eq(KeyFile.count(nil), 0, "and so is nothing")

  -- no mod.cache (an engine that will not give us one) is not an error
  eq(next(KeyFile.load(nil, "k", function() return { bad = true } end)), nil,
     "no cache loads an empty table without calling decode")
  local okSave, why = KeyFile.save(nil, "k", "a=1\n", nil, "thing")
  eq(okSave, false, "no cache is a failed save")
  ok(type(why) == "string", "...with a reason")
end

-- POK-120: the career that outlives a playthrough
do
  local Career = require("mods.battle_royale.lib.career")

  local function roundTrip(t) return Career.decode(Career.encode(t)) end

  local full = roundTrip({ name = "ASH", skin = "HIKER", wins = 12 })
  eq(full.name, "ASH", "name round-trips")
  eq(full.skin, "HIKER", "skin round-trips")
  eq(full.wins, 12, "wins round-trip")

  local bare = roundTrip({})
  ok(bare.name == nil, "no name is no row")
  ok(bare.skin == nil, "no skin is no row")
  eq(bare.wins, 0, "a career always states its wins")

  -- Wire.cleanName lets punctuation through and `=` is punctuation; the
  -- FIRST `=` splits, so the rest of the name survives intact
  eq(roundTrip({ name = "A=B" }).name, "A=B", "an = in the name survives")
  eq(roundTrip({ name = "MR. MIME" }).name, "MR. MIME", "a space in the name survives")

  eq(Career.cleanWins(-3), 0, "wins never go negative")
  eq(Career.cleanWins(2.7), 2, "wins are whole")
  eq(Career.cleanWins("5"), 5, "a numeric string is a count")
  eq(Career.cleanWins("nope"), 0, "nonsense is no wins")
  eq(Career.cleanWins(nil), 0, "absent is no wins")
  eq(roundTrip({ wins = -4 }).wins, 0, "a negative count is stored as zero")

  -- a file poked by hand loses a field at worst
  local poked = Career.decode("wins=9\nbogus=1\nnot a row\nskin=LASS\n")
  eq(poked.wins, 9, "an unknown row does not derail the parse")
  eq(poked.skin, "LASS", "rows after the junk still read")
  ok(poked.name == nil, "a missing row is simply absent")
  eq(next(Career.decode("")), nil, "an empty file is an empty career")
  eq(next(Career.decode(nil)), nil, "a missing file is an empty career")

  -- in case the file is ever touched by a Windows editor
  eq(Career.decode("name=RED\r\nwins=3\r\n").name, "RED", "CRLF keeps the name")
  eq(Career.decode("name=RED\r\nwins=3\r\n").wins, 3, "CRLF keeps the wins")

  -- ------- the store, against an in-memory mod.cache

  local function fakeMod(refuseWrites)
    local files = {}
    return {
      files = files,
      cache = {
        read = function(_, key) return files[key] end,
        write = function(_, key, bytes)
          if refuseWrites then return nil, "disk is full" end
          files[key] = bytes
          return true
        end,
      },
    }
  end

  local m = fakeMod()
  eq(next(Career.load(m)), nil, "a fresh install has no career")
  ok(Career.save(m, { name = "BLUE", skin = "ROCKET", wins = 21 }),
     "save reports success")
  local back = Career.load(m)
  eq(back.name, "BLUE", "the name comes back")
  eq(back.skin, "ROCKET", "the skin comes back")
  eq(back.wins, 21, "the wins come back")
  ok(m.files[Career.KEY] ~= nil, "and it landed under the versioned key")
  -- the whole point of the ticket: the store is not keyed by a playthrough,
  -- so a later launch reading the same cache finds the same career
  eq(Career.load(m).wins, 21, "a later session reads the same career")

  local warned = {}
  local log = { warn = function(_, fmt, ...) warned[#warned + 1] = fmt:format(...) end }
  local okSave, err = Career.save(fakeMod(true), { wins = 1 }, log)
  ok(not okSave, "a refused write reports failure")
  eq(err, "disk is full", "and hands back the reason")
  eq(#warned, 1, "and says so once in the log, instead of swallowing it")

  -- an engine without mod.cache degrades to no career, never to a throw
  eq(next(Career.load({})), nil, "no cache is an empty career")
  ok(not Career.save({}, { wins = 1 }), "and a save that cannot land says so")
end

-- POK-124: counting play without ever opening a socket to report it
do
  local Stats = require("mods.battle_royale.lib.stats")

  -- ------- the id

  local id = Stats.newId()
  eq(#id, 16, "an install id is 16 characters")
  ok(id:match("^[0-9a-f]+$") ~= nil, "and hex, which is what the relay accepts")
  ok(Stats.newId() ~= Stats.newId(), "two installs are not the same install")

  -- ------- the file

  local function roundTrip(t) return Stats.decode(Stats.encode(t)) end

  local full = roundTrip({ id = "abc123", since = "2026-08-20", solo = 7 })
  eq(full.id, "abc123", "id round-trips")
  eq(full.since, "2026-08-20", "first-seen round-trips")
  eq(full.solo, 7, "the solo count round-trips")
  eq(full.off, false, "and the opt-out defaults to on")

  eq(roundTrip({ off = true }).off, true, "an opt-out round-trips")
  eq(Stats.cleanCount(-4), 0, "a count never goes negative")
  eq(Stats.cleanCount(2.7), 2, "a count is whole")
  eq(Stats.cleanCount("nope"), 0, "nonsense is no matches")
  eq(next(Stats.decode("")), nil, "an empty file is an empty ledger")
  eq(next(Stats.decode(nil)), nil, "so is a missing one")
  eq(Stats.decode("solo=3\nbogus=1\nnot a row\n").solo, 3,
     "a hand-poked file loses a field at worst")

  -- ------- the store, against an in-memory mod.cache
  --
  -- The fake mod has a cache and NOTHING else -- no net, no relay, no
  -- socket of any kind.  That every path below works against it is the
  -- point of POK-124: recording play must not need a network, because
  -- Net:connectTCP blocks for five seconds and a solo player asked to be
  -- left alone.

  local function fakeMod()
    local files = {}
    return { files = files, version = "0.31.0", cache = {
      read = function(_, k) return files[k] end,
      write = function(_, k, b) files[k] = b return true end } }
  end

  local m = fakeMod()
  local s = Stats.ensure(m)
  ok(s.id and #s.id == 16, "ensure mints an id on a fresh install")
  ok(m.files[Stats.KEY] == nil,
     "but writes nothing at boot -- an engine that cannot take a write must"
     .. " not warn on every launch about play that has not happened")
  Stats.recordSolo(m, s, nil)
  ok(m.files[Stats.KEY] ~= nil, "the first thing worth reporting persists the id")
  eq(Stats.ensure(m).id, s.id, "so the next launch is the same install")
  Stats.flushed(m, s, nil)

  -- ------- counting

  Stats.recordSolo(m, s, nil)
  Stats.recordSolo(m, s, nil)
  eq(s.solo, 2, "two solo matches are two solo matches")
  eq(Stats.load(m).solo, 2, "and they survive a restart")

  local msg = Stats.message(s, m.version)
  eq(msg and msg.type, "stat", "the wire message is a stat")
  eq(msg and msg.solo, 2, "carrying the pending count")
  eq(msg and msg.id, s.id, "and the install id")
  eq(msg and msg.v, "0.31.0", "and the build, so a version spread is readable")
  ok(msg and msg.name == nil, "and NOT the trainer name, which the player chose")

  -- the count clears only once it has actually gone somewhere
  Stats.flushed(m, s, nil)
  eq(s.solo, 0, "a flushed count is zero")
  eq(Stats.load(m).solo, 0, "durably")
  eq(Stats.message(s, m.version).solo, 0, "and the next message says nothing new")

  -- ------- the opt-out stops the counting, not just the sending

  Stats.setOff(m, s, true, nil)
  eq(Stats.message(s, m.version), nil, "opted out, there is no message to send")
  Stats.recordSolo(m, s, nil)
  eq(s.solo, 0, "and nothing is counted while it is off")
  eq(Stats.load(m).off, true, "the choice is remembered")
  Stats.setOff(m, s, false, nil)
  Stats.recordSolo(m, s, nil)
  eq(s.solo, 1, "turning it back on starts counting again")

  -- an engine with no cache degrades to no ledger rather than throwing
  eq(next(Stats.load({})), nil, "no cache is an empty ledger")
  ok(not Stats.save({}, { id = "x" }), "and a save that cannot land says so")

  -- ------- a stat never rides a LocalRoom (the guard against losing it)

  local Relay = require("mods.battle_royale.lib.relay")
  local sent = {}
  local fakeNet = { closed = false, send = function(_, msg) sent[#sent + 1] = msg end }

  local localRoom = Relay.new({ transport = fakeNet })
  localRoom.status = "lobby"
  eq(localRoom:stat({ id = "abc" }), false,
     "a solo room has no address, so it refuses a stat")
  eq(#sent, 0, "and nothing was written into the void")

  local online = Relay.new({ address = "example:7790" })
  online.net = fakeNet
  online.status = "lobby"
  eq(online:stat({ id = "abc", solo = 4 }), true, "a real relay takes it")
  eq(sent[1] and sent[1].type, "stat", "as a stat")
  eq(sent[1] and sent[1].solo, 4, "with the count")

  online.status = "connecting"
  eq(online:stat({ id = "abc" }), false, "and not before the room exists")
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

-- POK-86: the match log's two tiers and its correlation prefix.
do
  local Log = require("mods.battle_royale.lib.log")
  local said = {}
  local out = {
    info = function(_, fmt, ...) said[#said + 1] = fmt:format(...) end,
    warn = function(_, fmt, ...) said[#said + 1] = "W " .. fmt:format(...) end,
  }
  local log = setmetatable({ out = out, deepOn = false }, Log)

  eq(log:prefix(), "", "no room yet means no prefix to read past")
  log:say("hello %s", "world")
  eq(said[#said], "hello world", "say goes straight out")

  -- deep is silent until it is asked for: this is the whole point of it
  log:deep("noise")
  eq(#said, 1, "deep says nothing while it is off")
  log:setDeep(true)
  ok(log:isDeep(), "...and reports itself on")
  log:deep("noise")
  eq(#said, 2, "deep speaks once it is on")

  -- correlation: the code and seed the relay's own log also prints
  log:match("A7QK", nil)
  eq(log:prefix(), "[A7QK/-] ", "a room before a match shows the code alone")
  log:match(nil, 91823)
  eq(log:prefix(), "[A7QK/91823] ", "and the seed joins it when the match starts")
  log:say("ring 3")
  eq(said[#said], "[A7QK/91823] ring 3", "every line carries it")
  log:forget()
  eq(log:prefix(), "", "leaving the match drops the prefix")

  -- a logger with nowhere to write must not throw
  local mute = setmetatable({ out = nil, deepOn = true }, Log)
  ok(pcall(function() mute:say("x") mute:deep("y") mute:warn("z") end),
     "a logger with no sink is silent, not fatal")
end

-- POK-89: bots have faces of their own.
do
  local Bots = require("mods.battle_royale.lib.bots")
  local Skins = require("mods.battle_royale.lib.skins")

  -- the invariant the ticket is really about: a bot must never turn up
  -- wearing something the player unlocks, or its face claims a rank
  local worn = {}
  for _, e in ipairs(Skins.LADDER) do worn[e.walk] = true end
  local clash = nil
  for _, e in ipairs(Bots.LOOKS) do
    if worn[e.walk] then clash = e.walk end
  end
  eq(clash, nil, "no bot look is a player wardrobe skin")
  ok(#Bots.LOOKS >= 6, "and there are enough of them to vary (" .. #Bots.LOOKS .. ")")

  -- every pair has to exist in the extracted data: a missing sheet asserts
  -- inside NPC.new and a missing class inside BattleState
  local okS, sprites = pcall(require, "data.generated.sprites")
  local okT, trainers = pcall(require, "data.generated.trainers")
  if okS and okT then
    for _, e in ipairs(Bots.LOOKS) do
      ok(sprites[e.walk] ~= nil, "bot walk sheet exists: " .. e.walk)
      ok(trainers[e.class] ~= nil, "bot trainer class exists: " .. e.class)
    end
  end

  -- seeded: the same bot looks the same on every client, all match
  local a1 = Bots.look(4242, Bots.idFor(1))
  local a2 = Bots.look(4242, Bots.idFor(1))
  ok(a1 ~= nil, "a bot gets a look")
  eq(a1.walk, a2.walk, "and the same one every time it is asked")
  -- ...and a roster is not all one face
  local seen, n = {}, 0
  for i = 1, 12 do
    local e = Bots.look(4242, Bots.idFor(i))
    if e and not seen[e.walk] then seen[e.walk] = true n = n + 1 end
  end
  ok(n >= 3, "a roster of twelve wears more than a couple of faces (" .. n .. ")")

  -- a build missing the art degrades instead of asserting
  local only = Bots.LOOKS[2]
  local thin = Bots.look(7, Bots.idFor(3),
    { sprites = { [only.walk] = true }, trainers = { [only.class] = true } })
  eq(thin and thin.walk, only.walk, "a thin build falls back to what it has")
  eq(Bots.look(7, Bots.idFor(3), { sprites = {}, trainers = {} }), nil,
     "and a build with none of them says so")

  -- POK-160: the brain rides the tier, not the face.  An ai-tier bot may
  -- wear any of the ten faces now, and its fight brain comes from
  -- Bots.fightAI instead -- a cooltrainer ai_classes record for REGULAR
  -- and ACE, nothing (GenericAI) for a ROOKIE.
  local COOL = { OPP_COOLTRAINER_M = true, OPP_COOLTRAINER_F = true }
  local aiFaces, seenBrain = {}, {}
  for i = 1, 60 do
    local id = Bots.idFor(i)
    local tier = Bots.tier(4242, id)
    local brain = Bots.fightAI(4242, id)
    eq(brain, Bots.fightAI(4242, id), "a bot's brain is stable")
    if tier.ai then
      ok(brain and COOL[brain], tier.id .. " fights with a cooltrainer brain")
      seenBrain[brain] = true
      local e = Bots.look(4242, id)
      if e and not COOL[e.class] then aiFaces[e.class] = true end
    else
      eq(brain, nil, "a ROOKIE fights on GenericAI")
    end
  end
  ok(next(aiFaces) ~= nil, "an ai-tier bot can wear a non-cooltrainer face")
  ok(seenBrain.OPP_COOLTRAINER_M and seenBrain.OPP_COOLTRAINER_F,
     "both cooltrainer brains turn up across a roster")
end

-- POK-85: the walk over.  Bots.wander is a roam; this is a stride.
do
  local Bots = require("mods.battle_royale.lib.bots")
  local open = function() return true end
  local function bot(x, y) return { map = "M", x = x, y = y } end

  eq(Bots.approach(bot(1, 5), open, { x = 9, y = 5 }), "right", "east closes east")
  eq(Bots.approach(bot(9, 5), open, { x = 1, y = 5 }), "left", "and west, west")
  eq(Bots.approach(bot(5, 9), open, { x = 5, y = 1 }), "up", "the bigger gap first")
  eq(Bots.approach(bot(5, 1), open, { x = 5, y = 9 }), "down", "...either way")
  -- adjacent is arrival: a trainer stops beside you, never on you
  eq(Bots.approach(bot(4, 5), open, { x = 5, y = 5 }), nil, "adjacent is arrived")
  eq(Bots.approach(bot(5, 5), open, { x = 5, y = 5 }), nil, "and so is on the spot")
  -- walls: the second-choice axis carries it round
  local noEast = function(_, x) return x <= 5 end
  eq(Bots.approach(bot(5, 9), noEast, { x = 9, y = 1 }), "up",
     "boxed in on one axis, it takes the other")
  -- ...and walled off entirely, it says so rather than strolling away
  eq(Bots.approach(bot(5, 5), function() return false end, { x = 9, y = 9 }), nil,
     "walled off is nil, not a wander")
  -- unlike wander, it never pauses: same answer every time
  for _ = 1, 20 do
    if Bots.approach(bot(1, 5), open, { x = 9, y = 5 }) ~= "right" then
      ok(false, "the stride never dithers")
      break
    end
  end
  ok(true, "the stride never dithers")
  ok(Bots.WALKUP_STEPS > 0 and Bots.WALKUP_SECONDS > 0, "the stride is bounded")
end

-- POK-84: the marker the Cable Club guard reads.  The world.talk wrap asks
-- data:textEntry(map.def.label, npc.def.text) and refuses on entry.cableClub
-- -- the same flag OverworldState uses to find the receptionist.  If the
-- extractor ever stops emitting it the desk quietly re-opens mid-match, and
-- nothing else would notice, so pin it.
do
  local okT, tp = pcall(require, "data.generated.text_pointers")
  if okT and type(tp) == "table" then
    local desks, viridian = 0, false
    for map, entries in pairs(tp) do
      for _, e in pairs(entries) do
        if type(e) == "table" and e.cableClub then
          desks = desks + 1
          if map == "ViridianPokecenter" then viridian = true end
        end
      end
    end
    ok(desks >= 10, "every POKeMON CENTER link desk is marked (" .. desks .. ")")
    ok(viridian, "VIRIDIAN's among them, keyed by the map's own label")
  end
end

-- POK-82: the Hall of Fame is the end of the run -- closing the last page
-- pops itself AND tells the mod, so the champion is not left standing in a
-- finished world.
do
  local Fame = require("mods.battle_royale.lib.fame")
  local popped, done = 0, 0
  local game = { stack = { pop = function() popped = popped + 1 end } }
  local f = Fame.new(game, {}, {}, function() done = done + 1 end)
  eq(#f.pages, 1, "an empty party still parades the record card")
  eq(done, 0, "the run is not over while a page is up")
  f:advance()
  eq(popped, 1, "closing the last page pops the parade")
  eq(done, 1, "and hands the run back to the mod")
  -- a parade nobody wired still closes cleanly
  local g2 = { stack = { pop = function() end } }
  local f2 = Fame.new(g2, {}, {})
  local okA = pcall(function() f2:advance() end)
  ok(okA, "no onDone is not an error")
end

-- ------- the lockstep cells still match the scenes they suppress
--
-- lib/lockstep.lua is a list of coordinates, and a coordinate list rots
-- quietly: upstream moves a trigger, nothing errors, and a cutscene walks
-- back into matches.  So drive VANILLA's own onStep at every cell the list
-- claims and require it to fire there -- if it does not, the entry is
-- either wrong or no longer earning its keep.
--
-- This is the only executable check standing behind the four YELLOW rows.
-- There is no Yellow ROM in the dev setup, so unlike CERULEAN they cannot
-- be smoke-tested end to end.  PEWTER is left out on purpose: its escort
-- reaches for Music and TextBox on the way in, and it has been verified in
-- play since POK-122.

do
  local Lockstep = require("mods.battle_royale.lib.lockstep")
  local JJ = require("data.scripts.yellow_jessie_james")
  local S5 = require("data.scripts.story5")
  -- The E4 shove pushes a real TextBox before it moves anybody, and this
  -- harness has no render stack.  Standing one in for the require the
  -- handler makes lazily keeps the part under test -- which cells it
  -- decides to fire on -- entirely real.
  package.loaded["src.render.TextBox"] = package.loaded["src.render.TextBox"]
    or { new = function(_, _, done) if done then done() end return {} end }
  local S4 = require("data.scripts.story4")

  -- Just enough overworld for these handlers to reach the point where they
  -- commit: a runner that records instead of running, and an NPC for the
  -- ones that look one up before they start.
  local function stub()
    local ran = false
    return {
      npcs = {},
      scriptMoves = {},
      player = { cellX = 0, cellY = 0 },
      -- the E4 rooms print before they shove
      stack = { push = function() end },
      runner = {
        isRunning = function() return false end,
        run = function() ran = true end,
      },
      npcByIndex = function() return { def = {} } end,
      -- The E4 shove does not go through the runner at all -- it calls
      -- ow:scriptMove directly from the text box's callback -- so a stub
      -- that only watched `runner.run` recorded nothing and the row read
      -- as "the vanilla handler does not fire here", which would have been
      -- a very convincing wrong answer.
      scriptMove = function(self, ...)
        ran = true
        self.scriptMoves[#self.scriptMoves + 1] = { ... }
      end,
    }, function() return ran end
  end

  -- MT_MOON wants a fossil in the bag before JESSIE and JAMES care, and
  -- SILPH's base handler is short-circuited so only the YELLOW half is
  -- under test.  Nothing here sets the four "already beaten" flags, or
  -- EVENT_BEAT_CERULEAN_ROCKET_THIEF.
  local function save()
    return { flags = { EVENT_GOT_HELIX_FOSSIL = true,
                       EVENT_BEAT_SILPH_CO_GIOVANNI = true } }
  end

  -- control cells: a neighbour, and for the two maps whose base handlers
  -- were deliberately KEPT, the very cell that must stay contestable --
  -- MT_MOON's SUPER NERD and SILPH's GIOVANNI.  A list that crept one
  -- cell wider than vanilla would start eating ordinary steps.
  local under = {
    { "MT_MOON_B2F",        JJ.MT_MOON_B2F.onStep,        { { 13, 8 }, { 3, 6 } } },
    { "ROCKET_HIDEOUT_B4F", JJ.ROCKET_HIDEOUT_B4F.onStep, { { 23, 14 }, { 24, 13 } } },
    { "POKEMON_TOWER_7F",   JJ.POKEMON_TOWER_7F.onStep,   { { 9, 12 }, { 10, 11 } } },
    { "SILPH_CO_11F",       JJ.SILPH_CO_11F.onStep,       { { 6, 13 }, { 7, 12 }, { 4, 3 } } },
    { "CERULEAN_CITY",      S5.CERULEAN_CITY.onStep,      { { 30, 8 }, { 29, 7 }, { 20, 6 } } },
    -- POK-128.  Controls are the cells just outside the entrance mouth --
    -- a list one cell wider than vanilla's would start eating ordinary
    -- steps inside a room somebody is trying to cross.
    { "LORELEIS_ROOM", S4.LORELEIS_ROOM.onStep, { { 3, 10 }, { 6, 11 }, { 4, 9 }, { 5, 2 } } },
    { "BRUNOS_ROOM",   S4.BRUNOS_ROOM.onStep,   { { 3, 11 }, { 6, 10 }, { 5, 9 } } },
    { "AGATHAS_ROOM",  S4.AGATHAS_ROOM.onStep,  { { 3, 10 }, { 6, 10 }, { 4, 8 } } },
  }

  for _, row in ipairs(under) do
    local mapId, onStep, controls = row[1], row[2], row[3]
    local cells = Lockstep.CELLS[mapId]
    ok(cells ~= nil and next(cells) ~= nil, mapId .. " is on the lockstep list")

    for key in pairs(cells or {}) do
      local sx, sy = key:match("^(%-?%d+),(%-?%d+)$")
      local x, y = tonumber(sx), tonumber(sy)
      ok(x ~= nil and y ~= nil, mapId .. " cell " .. key .. " parses")
      if x and y then
        local ow, fired = stub()
        -- `data.text` is for the E4 shove, which looks its line up before
        -- it moves anybody; the others never touch it
        local game = { save = save(), data = { text = {} },
                       stack = { push = function() end } }
        local called, res = pcall(onStep, game, ow, x, y)
        ok(called, ("%s (%d,%d): the vanilla handler runs"):format(mapId, x, y))
        ok(called and (res == true or fired()),
           ("%s (%d,%d) still starts a scripted walk"):format(mapId, x, y))
        -- and the mod covers it
        ok(Lockstep.blocks(mapId, x, y),
           ("%s (%d,%d) is suppressed during a match"):format(mapId, x, y))
      end
    end

    for _, c in ipairs(controls) do
      ok(not Lockstep.blocks(mapId, c[1], c[2]),
         ("%s (%d,%d) is not ours to consume"):format(mapId, c[1], c[2]))

    end
  end

  -- the rule itself: forced battles stay reachable.  These are the cells
  -- reviewed and kept -- if a future edit sweeps them onto the list, the
  -- SUPER NERD, GIOVANNI and the DOJO master stop being contestable.
  ok(not Lockstep.blocks("FIGHTING_DOJO", 4, 3), "the DOJO master is still fightable")
  ok(Lockstep.CELLS.ROUTE_24 == nil, "Nugget Bridge is text, not a walk -- left alone")
  -- ...and the E4 members stay fightable: only the entrance mouth is ours
  ok(not Lockstep.blocks("LORELEIS_ROOM", 4, 2),
     "LORELEI herself is still reachable")
  ok(not Lockstep.blocks("AGATHAS_ROOM", 5, 3), "so is AGATHA")

  -- The other half of POK-128 is a FLAG rather than a cell -- the walk-in
  -- is an onEnter and map_scripts composes those all-run -- so it lives in
  -- main.lua's STORY_FLAGS and is not assertable from here; br_load_test
  -- is what proves that list still loads.
end

-- ------- standing another mod down, and putting it back (POK-134)
--
-- The suspend is the easy half.  Every test here is really about the way
-- back: this reaches into ANOTHER mod's published API and takes the
-- player's overworld away, and the only acceptable outcome of anything
-- going wrong is that we did not take it.

do
  local Coexist = require("mods.battle_royale.lib.coexist")

  -- a stand-in for the other mod: records what was called on it
  local function fake(opts)
    opts = opts or {}
    local calls = {}
    local exports = {}
    for _, name in ipairs({ "removeHooks", "clearAll", "installHooks" }) do
      if not (opts.missing and opts.missing[name]) then
        exports[name] = function()
          calls[#calls + 1] = name
          if opts.throws and opts.throws[name] then
            error("boom: " .. name, 0)
          end
        end
      end
    end
    return { id = "overworld_wild_spawns", version = "2.2.0",
             exports = exports }, calls
  end

  local WILDS = Coexist.MODS[1] and Coexist.MODS[1].id
  eq(WILDS, "overworld_wild_spawns", "the Wilds of Kanto id is on the list")

  -- ------- nobody else installed: silent no-op, and still a token
  do
    local token = Coexist.suspend(function() return nil end)
    ok(type(token) == "table", "an absent mod still returns a token")
    eq(#Coexist.suspended(token), 0, "...naming nothing")
    Coexist.restore(token)   -- must not throw
    ok(true, "restoring an empty token is safe")
  end

  -- ------- the ordinary path
  do
    local handle, calls = fake()
    local token = Coexist.suspend(function() return handle end)
    eq(table.concat(calls, ","), "removeHooks,clearAll",
       "suspend removes the hooks and clears the overworld, in that order")
    eq(table.concat(Coexist.suspended(token), ","), "overworld_wild_spawns",
       "the token names who is stood down")
    Coexist.restore(token)
    eq(table.concat(calls, ","), "removeHooks,clearAll,installHooks",
       "restore puts the hooks back")
    eq(#Coexist.suspended(token), 0, "a spent token names nobody")
  end

  -- ------- restore twice: every exit path runs through resetMatch and some
  -- arrive twice, so this must not double-install.
  --
  -- That invariant used to be aspirational -- a bot winning, a match nobody
  -- won and a champion whose parade could not run all reached no reset at
  -- all.  It is true now: BR:endMatch is the single funnel, and both of its
  -- branches (keep the room / teardown) call resetMatch (POK-144).
  do
    local handle, calls = fake()
    local token = Coexist.suspend(function() return handle end)
    Coexist.restore(token)
    Coexist.restore(token)
    local n = 0
    for _, c in ipairs(calls) do if c == "installHooks" then n = n + 1 end end
    eq(n, 1, "restoring twice installs the hooks once")
  end

  -- ------- THE ONE THAT MATTERS: if we never removed the hooks, we must
  -- not install them.  Reinstalling hooks nobody took out is its own bug.
  do
    local handle, calls = fake({ missing = { removeHooks = true } })
    local token = Coexist.suspend(function() return handle end)
    Coexist.restore(token)
    for _, c in ipairs(calls) do
      ok(c ~= "installHooks",
         "no removeHooks means no installHooks (called " .. c .. ")")
    end
  end

  do
    local handle, calls = fake({ throws = { removeHooks = true } })
    local token = Coexist.suspend(function() return handle end)
    Coexist.restore(token)
    local n = 0
    for _, c in ipairs(calls) do if c == "installHooks" then n = n + 1 end end
    eq(n, 0, "a removeHooks that THREW is not restored either")
  end

  -- ------- a throwing clearAll still leaves the hooks restorable: the
  -- overworld may be in a strange state, but the player gets their mod back
  do
    local handle, calls = fake({ throws = { clearAll = true } })
    local token = Coexist.suspend(function() return handle end)
    Coexist.restore(token)
    local n = 0
    for _, c in ipairs(calls) do if c == "installHooks" then n = n + 1 end end
    eq(n, 1, "clearAll failing does not cost us the way back")
  end

  -- ------- a find() that throws is somebody else's bug, not a crash here
  do
    local token = Coexist.suspend(function() error("nope", 0) end)
    eq(#Coexist.suspended(token), 0, "a throwing find suspends nothing")
    Coexist.restore(token)
    ok(true, "...and restores cleanly")
  end

  -- ------- the documented trap, asserted so it stays documented: a second
  -- suspend is NOT a no-op.  It hands back a second LIVE token, and
  -- restoring both installs the other mod's hooks twice -- so main.lua's
  -- `if not self.suspendedMods` is the only thing preventing it, and this
  -- pins the behaviour that makes that guard load-bearing.
  --
  -- These assertions were `>= 0` and `ok(true)` and passed against the
  -- opposite claim: the comment said the second token came back empty,
  -- nothing could fail, and the double install went unnoticed.  Assert the
  -- real numbers or do not assert.
  do
    local handle, calls = fake()
    local first = Coexist.suspend(function() return handle end)
    local second = Coexist.suspend(function() return handle end)
    eq(#Coexist.suspended(first), 1, "the first token holds the way back")
    eq(#Coexist.suspended(second), 1,
       "a second suspend is live too -- the caller must not make one")
    Coexist.restore(second)
    Coexist.restore(first)
    local n = 0
    for _, c in ipairs(calls) do if c == "installHooks" then n = n + 1 end end
    eq(n, 2, "...and restoring both double-installs, which is the trap")
  end
end

io.write(("\nbattle royale: %d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
