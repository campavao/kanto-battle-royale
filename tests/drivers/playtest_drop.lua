-- The 2026-08-25 playtest batch, Safari-and-drop half: POK-92, POK-93,
-- POK-101, POK-99, POK-100.
--
-- One client, no relay server (a solo room is a LocalRoom).  Run from a
-- gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-playtest-drop POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_drop.lua \
--   <path to>/lovec . > drop.log 2>&1
--
-- Exit 0 with a `DROP OK` line passes; any `PVP FAIL` line fails (the
-- failure channel is pvplib's, shared with every other driver here).
-- BR_SHOTS=<dir> captures the picker and the landing.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Fog = require("mods.battle_royale.lib.fog")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local function shot(name)
    if SHOTS then U.shot(game, SHOTS .. "/" .. name .. ".png") end
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("DROPPER")
  -- long enough to get into a battle on purpose, short enough that the
  -- run does not outlive the harness
  E.setSafari(45)
  E.setFog(240)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(3)

  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end
  E.start()

  if not L.waitPhase(C, "safari", 240) then
    return C.fail("never reached the SAFARI (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.log("DROP: in the Safari, " .. tostring(E.safariLeft()) .. "s left")

  -- A team to drop with.  Catching one for real is a dice roll the clock
  -- cannot afford, and what is under test is the BUZZER, not the catch --
  -- an empty party at the buzzer is the "caught nothing" elimination
  -- (a different, already-tested path).
  L.armParty(C, "NIDORINO", 5, "TACKLE")

  -- ---------------------------------------------------- POK-92: the buzzer
  --
  -- Open a battle and then run the clock out inside it.  Before the fix
  -- tickDrop returned early on liveLocalBattle() for as long as the player
  -- cared to stay, so the zone was an unlimited catching phase for anyone
  -- who simply never pressed RUN.
  -- Pushed the way the world pushes one -- pushBattle + the onFinish that
  -- hands the result back to the overworld -- because that is what the
  -- return transition needs to resolve against.  A raw stack:push stages a
  -- battle nothing can ever finish, which is a driver bug, not a match one.
  local staged
  local okBattle = pcall(function()
    local ow = C.ow()
    staged = require("src.battle.BattleState").newWild(game, "NIDORAN_M", 5)
    staged.onFinish = function(result) ow:afterBattle(result, staged) end
    ow:pushBattle(staged)
  end)
  if not (okBattle and staged) then return C.fail("could not stage a Safari battle") end
  local opened = false
  for _ = 1, 200 do
    U.wait(10)
    if game.stack:top() == staged then opened = true break end
  end
  if not opened then return C.fail("the staged battle did not open") end
  U.log("DROP: a battle is open; sounding the buzzer")
  shot("01-battle-at-the-buzzer")

  -- the exact thing under test: is this battle still on the stack?
  local function stagedIsUp()
    for _, s in ipairs(game.stack.states or {}) do
      if s == staged then return true end
    end
    return false
  end

  E.buzz()
  -- BUZZER_BATTLE_GRACE is 3s of WALL time; nothing below presses a button
  -- at the battle, so if it ever closes it closed itself.
  local closed = false
  for _ = 1, 400 do
    U.wait(15)
    if not stagedIsUp() then closed = true break end
  end
  if not closed then
    return C.fail(("the buzzer never closed the battle: phase %s, top %s")
      :format(tostring(E.phase()), tostring(game.stack:top())))
  end
  U.log("DROP: POK-92 ok -- the buzzer closed the battle with no input from us")

  -- ------------------------------------------------- POK-101: pick on a map
  local TownMap = require("src.ui.TownMap")
  local picker, waited = nil, 0
  for _ = 1, 400 do
    U.wait(15)
    waited = waited + 1
    local top = game.stack:top()
    if getmetatable(top) == TownMap then picker = top break end
    -- the PA's "Time's up!" pages sit in front of the gate walk
    if C.busy() then U.tap(game, "a") end
    if E.phase() == "match" then break end
  end
  if not picker then
    return C.fail(("the drop picker was not the TOWN MAP (top %s, phase %s)")
      :format(tostring(getmetatable(game.stack:top())), tostring(E.phase())))
  end
  if not picker.fly then return C.fail("the map opened as a viewer, not a picker") end
  if not (picker.locs and #picker.locs > 1) then
    return C.fail("the picker offers " .. tostring(picker.locs and #picker.locs)
                  .. " place(s) to drop")
  end
  if not (picker.flyMapIds and picker.flyMapIds[picker.sel]) then
    return C.fail("the cursor is not over a droppable town")
  end
  U.log(("DROP: POK-101 ok -- the TOWN MAP picker offers %d towns, cursor on %s")
    :format(#picker.locs, tostring(picker.flyMapIds[picker.sel])))
  shot("02-drop-picker")

  -- cycle a couple of towns to prove the cursor moves, then commit
  local first = picker.flyMapIds[picker.sel]
  U.tap(game, "up") U.wait(10)
  U.tap(game, "up") U.wait(10)
  local moved = picker.flyMapIds[picker.sel]
  if moved == first and #picker.locs > 2 then
    return C.fail("the cursor did not move over the map")
  end
  U.tap(game, "a")

  if not L.waitPhase(C, "match", 240) then
    return C.fail("never landed (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 10 do U.tap(game, "a") U.wait(20) end
  U.log(("DROP: landed on %s at %s,%s"):format(
    tostring(C.map()), tostring(C.x()), tostring(C.y())))

  -- ------------------------------------------- POK-93: phase 1 is a grace
  --
  -- Phase 1's radius was 15 while the town-map grid runs 0..15 on both
  -- axes -- a diagonal of 21.22 -- so the far corners of Kanto were
  -- OUTSIDE the "covers everything" ring.  Landing in Lavender under a
  -- Cinnabar eye put you in the fog on the frame you touched the ground.
  --
  -- The eye is only announced at the landing, so the drop cannot be aimed
  -- at it in advance: read it now and FLY to whichever town is furthest
  -- from it, which is exactly the case that used to fail.
  local ring = E.ring()
  if not ring then return C.fail("no ring after landing") end
  if ring.phase ~= 1 then
    return C.fail("the match opened on fog phase " .. tostring(ring.phase))
  end
  U.log(("DROP: the eye is %s at %s,%s, radius %s")
    :format(tostring(ring.place), tostring(ring.x), tostring(ring.y),
            tostring(ring.radius)))

  local locations = game.data.field.townMap.locations
  local worst, worstMap, worstD = nil, nil, -1
  for _, town in ipairs({ "PALLET_TOWN", "VIRIDIAN_CITY", "PEWTER_CITY",
                          "CERULEAN_CITY", "VERMILION_CITY", "LAVENDER_TOWN",
                          "CELADON_CITY", "FUCHSIA_CITY", "SAFFRON_CITY",
                          "CINNABAR_ISLAND" }) do
    local l = locations[town]
    if l then
      local dx, dy = l.x - ring.x, l.y - ring.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d > worstD then worst, worstMap, worstD = l, town, d end
    end
  end
  U.log(("DROP: furthest town from the eye is %s, %.2f squares"):format(
    tostring(worstMap), worstD))
  if worstD <= 15 then
    -- can happen for a central eye; the assertion below is still worth
    -- making, it just is not the regression case
    U.log("DROP: (note) no town is past the old radius for this eye")
  end
  if not L.flyTo(C, worstMap) then
    return C.fail("FLY did not reach " .. tostring(worstMap)
                  .. "; at " .. tostring(C.map()))
  end
  for _ = 1, 10 do U.tap(game, "a") U.wait(20) end
  U.wait(60)

  if E.inFog() then
    return C.fail(("in the fog at phase 1 on %s (%.2f squares from %s, radius %s)")
      :format(tostring(C.map()), worstD, tostring(ring.place),
              tostring(E.ring() and E.ring().radius)))
  end
  -- and it stays that way: hold here a while, since the ring advances on
  -- WALL time and a phase is 240s of it
  for _ = 1, 40 do
    U.wait(30)
    if E.inFog() then
      return C.fail("the fog arrived during phase 1 on " .. tostring(C.map()))
    end
  end
  local now = E.ring()
  if now.phase ~= 1 then
    return C.fail("the ring left phase 1 during the grace period")
  end
  U.log(("DROP: POK-93 ok -- %.2f squares from the eye, radius %s, no fog")
    :format(worstD, tostring(now.radius)))

  -- The eye is drawn from the match seed, so a run cannot choose the pair
  -- that actually broke.  Check the geometry itself against THIS build's
  -- shipped location table: no placed map may be outside phase 1 from any
  -- square the eye can land on, and the worst pair in Kanto must clear it.
  local widest, widestPair = -1, nil
  for aId, a in pairs(locations) do
    for bId, b in pairs(locations) do
      if a.x and b.x then
        local dx, dy = a.x - b.x, a.y - b.y
        local d = dx * dx + dy * dy
        if d > widest then widest, widestPair = d, aId .. " -> " .. bId end
      end
    end
  end
  if Fog.radius(1) <= math.sqrt(widest) then
    return C.fail(("phase 1 (radius %s) does not cover Kanto's widest pair: %s at %.2f")
      :format(tostring(Fog.radius(1)), tostring(widestPair), math.sqrt(widest)))
  end
  -- and the exact drop the playtest reported
  local lav, cin = locations.LAVENDER_TOWN, locations.CINNABAR_ISLAND
  if lav and cin then
    local dx, dy = lav.x - cin.x, lav.y - cin.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d > Fog.radius(1) then
      return C.fail("a LAVENDER drop under a CINNABAR eye is still in the fog")
    end
    U.log(("DROP: LAVENDER is %.2f squares from CINNABAR, phase 1 reaches %s")
      :format(d, tostring(Fog.radius(1))))
  end
  U.log(("DROP: widest pair in Kanto is %s at %.2f squares, phase 1 covers it")
    :format(tostring(widestPair), math.sqrt(widest)))
  shot("03-landed-no-fog")

  -- --------------------------------- POK-99 / POK-100: the START menu rows
  -- a say left over from the landing/FLY eats START, so get back to bare
  -- overworld first (B advances text and backs out of anything else)
  local quiet = false
  for _ = 1, 120 do
    if game.stack:top() == C.ow() then quiet = true break end
    U.tap(game, "b")
    U.wait(12)
  end
  if not quiet then
    return C.fail("could not get back to the overworld to open the menu")
  end
  local menu
  for _ = 1, 20 do
    U.tap(game, "start")
    U.wait(30)
    local top = game.stack:top()
    if top and top.items then menu = top break end
    if top ~= C.ow() then U.tap(game, "b") U.wait(12) end
  end
  if not menu then
    return C.fail("the START menu did not open (top "
                  .. tostring(game.stack:top()) .. ")")
  end
  local labels, seen = {}, {}
  for i, it in ipairs(menu.items) do
    labels[i] = tostring(it.label)
    seen[tostring(it.label)] = true
  end
  local shown = table.concat(labels, ",")
  U.log("DROP: START menu = " .. shown)
  if seen.OPTION then return C.fail("OPTION is still on the menu: " .. shown) end
  if seen.MODS then return C.fail("MODS is still on the menu: " .. shown) end
  if seen.LINK then return C.fail("LINK is still on the menu: " .. shown) end
  if seen.SAVE then return C.fail("SAVE is still on the menu: " .. shown) end
  if not seen.MAP then return C.fail("no MAP row: " .. shown) end
  if labels[#labels] ~= "QUIT" then
    return C.fail("QUIT is not the last row: " .. shown)
  end
  local royale = false
  for _, l in ipairs(labels) do if l:find("ROYALE", 1, true) then royale = true end end
  if not royale then return C.fail("the mod's own row is gone: " .. shown) end
  U.log("DROP: POK-99 ok -- OPTION and MODS are gone")
  shot("04-start-menu")

  -- MAP opens the town map from the menu, with no TOWN_MAP in the bag
  -- needed and no bag round trip
  game.save.bag = {}
  local mapRow
  for i, it in ipairs(menu.items) do if it.label == "MAP" then mapRow = i end end
  menu.index = mapRow
  U.tap(game, "a")
  U.wait(45)
  if getmetatable(game.stack:top()) ~= TownMap then
    return C.fail("MAP did not open the TOWN MAP (top "
                  .. tostring(getmetatable(game.stack:top())) .. ")")
  end
  U.log("DROP: POK-100 ok -- MAP opens the town map with an empty bag")
  shot("05-map-row")

  U.log("DROP OK")
  love.event.quit(0)
  U.wait(30)
end
