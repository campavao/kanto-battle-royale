-- POK-112 and POK-117, in a real game: a gift that lands on a full party,
-- and the Pokemon Centre closing when the fog rolls in.
--
-- One client, no relay server (a solo room is a LocalRoom).  Run from a
-- gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-playtest-gift POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/playtest_gift.lua \
--   <path to>/lovec . > gift.log 2>&1
--
-- Exit 0 with a `GIFT OK` line passes; any `PVP FAIL` line fails.
--
-- Both halves are checked against state the mod cannot fake: the gift half
-- asserts the party ROSTER and the ball on the ground, not that a menu
-- appeared; the nurse half damages the party to 1 HP and asserts the HP
-- afterwards, with a phase-1 control proving the nurse still heals when
-- there is no fog.  A gate that broke the nurse outright would pass the
-- refusal check and fail the control.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Fog = require("mods.battle_royale.lib.fog")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  local fails = 0
  local function check(cond, msg)
    if cond then
      U.log("GIFT ok: " .. msg)
    else
      U.log("PVP FAIL: " .. msg)
      fails = fails + 1
    end
    return cond
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
  -- The fog interval is handed out by Wire.start and does NOT change under
  -- a running match, so it has to be right before the match begins.  45s a
  -- phase leaves the gift half inside the grace period and still reaches
  -- the first shrink long before the all-fog endgame at ~315s.
  E.setFog(45)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(1)

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
  quiet(80)

  local save = game.save
  local Pokemon = require("src.pokemon.Pokemon")
  local Boxes = require("src.pokemon.Boxes")
  local Commands = require("src.script.Commands")

  local function speciesList(party)
    local out = {}
    for i, m in ipairs(party or {}) do out[i] = tostring(m.species) end
    return table.concat(out, ",")
  end
  local function partyHas(sp)
    for _, m in ipairs(save.party or {}) do
      if m.species == sp then return true end
    end
    return false
  end
  local function boxedCount()
    local n = 0
    for _, box in ipairs(Boxes.ensure(save)) do n = n + #box end
    return n
  end

  -- ------------------------------------------------------------------
  -- POK-112: a gift arriving on a full party
  --
  -- Six DISTINCT species, so "the released one is on the ground" is a
  -- statement about a specific mon rather than about a crowd of RATTATA.
  -- ------------------------------------------------------------------
  local FILL = { "RATTATA", "PIDGEY", "SPEAROW", "EKANS", "SANDSHREW", "ZUBAT" }
  save.party = {}
  for i, sp in ipairs(FILL) do save.party[i] = Pokemon.new(game.data, sp, 10 + i) end
  Boxes.ensure(save)
  check(#save.party == 6, "staged a full party: " .. speciesList(save.party))
  check(boxedCount() == 0, "and empty boxes to start")

  local before = {}
  for _, b in ipairs(E.spills() or {}) do before[b.key] = true end

  -- Exactly what the Fighting Dojo's prize ball does: a native map script
  -- calling the command directly, with no ScriptRunner under it.
  local ctx = { save = save, game = game, overworld = C.ow() }
  Commands.give_pokemon(ctx, "HITMONCHAN", 30)
  check(ctx.boxNum ~= nil,
        "vanilla sent the gift to a box (that is the bug being fixed)")

  -- Dismiss the gift's own boxes; the tick opens the picker once the map
  -- is back on top.
  local picker = nil
  for _ = 1, 300 do
    local top = game.stack:top()
    if type(top) == "table" and top.pickOnly and top.onSwitch then
      picker = top
      break
    end
    U.tap(game, "a")
    U.wait(12)
  end
  if not check(picker ~= nil, "the party picker opened for the boxed gift") then
    U.log("GIFT: stack top was " .. tostring(game.stack:top()))
  end

  if picker then
    -- A on the first row releases FILL[1] and the gift takes the slot
    U.tap(game, "a")
    U.wait(30)
    quiet(120)
  end

  check(partyHas("HITMONCHAN"),
        "the gift is in the party: " .. speciesList(save.party))
  check(not partyHas(FILL[1]),
        "the released member left the party (" .. FILL[1] .. ")")
  check(#save.party == 6, "the party is still six, not seven")
  check(boxedCount() == 0,
        "and nothing was left in the box (found " .. boxedCount() .. ")")

  local dropped = nil
  for _, b in ipairs(E.spills() or {}) do
    if not before[b.key] and b.species == FILL[1] then dropped = b end
  end
  check(dropped ~= nil,
        "the released member is on the ground as a ball for somebody else")

  -- ------------------------------------------------------------------
  -- POK-113: the mark actually draws over a ghost
  --
  -- The wire and the derivation are proven by the two-client duel
  -- scenario; what THAT cannot reach is the overlay itself, because both
  -- clients are in the battle (the hud hook returns early when the
  -- overworld is not on top) or a map apart.  So: park a bot beside us,
  -- put a mark on it by hand, and confirm the frame renders with the
  -- overworld up and nothing thrown.  A throw inside render.hud is
  -- swallowed by the hook chain and only ever surfaces as a log line, so
  -- "it looked fine" is not evidence -- tickError is.
  -- while it is still PHASE 1 and the bot is still alive: run this after
  -- the fog and the only bot may be gone, which would make every check
  -- below pass without drawing a thing.
  local botId = nil
  for _, b in ipairs(E.bots() or {}) do
    if b.status == "alive" then botId = b.id break end
  end
  if check(botId ~= nil, "a living bot to hang a mark on") then
    -- Pewter's street, not wherever we happened to drop: a random map put
    -- the probe against a fence line where a screenshot could not say
    -- which sprite the mark belonged to.  This is the post every other
    -- driver in here stages on.
    if not check(L.flyTo(C, "PEWTER_CITY"), "flew to Pewter for the mark shot") then
      U.log("GIFT: mark shot staged at " .. tostring(C.map()) .. " instead")
    end
    L.goTo(C, "PEWTER_CITY", 16, 18, 300)
    quiet(80)
    local ow = C.ow()
    local map, px, py = C.map(), C.x(), C.y()
    -- BESIDE us, never in front: the eyeline has no consent step and would
    -- turn the probe into a fight.  Two cells clear, so a screenshot shows
    -- unambiguously which sprite the mark belongs to.
    E.debugPlaceBot(botId, map, px - 4, py)
    U.wait(60)
    U.log(("GIFT: probe at %s %s,%s; bot at %s,%s")
          :format(tostring(map), tostring(px), tostring(py),
                  tostring(px - 2), tostring(py)))
    for _, kind in ipairs({ "menu", "battle" }) do
      -- Re-place and shoot PROMPTLY.  A bot walks on its own clock and its
      -- ghost replays those steps, so a long wait here drifts it next to
      -- the player and a screenshot can no longer say which trainer the
      -- bubble belongs to.  Four cells of separation for the same reason.
      E.debugPlaceBot(botId, map, px - 4, py)
      check(E.debugBusy(botId, kind) == true, "marked the bot as " .. kind)
      U.wait(15)
      check(game.stack:top() == ow,
            "the map is on top, so the overlay is actually drawing (" .. kind .. ")")
      if SHOTS then U.shot(game, SHOTS .. "/mark_" .. kind .. ".png") end
      U.wait(20)
    end
    E.debugBusy(botId, nil)
    U.wait(45)
    check(game.stack:top() == ow, "and clearing the mark leaves the map alone")
  end



  -- ------------------------------------------------------------------
  -- POK-117: the counter shuts when the fog rolls in
  -- ------------------------------------------------------------------
  local function findNurse()
    local ow = C.ow()
    local label = ow and ow.map and ow.map.def and ow.map.def.label
    if not label then return nil end
    for _, npc in ipairs(ow.npcs or {}) do
      local d = npc.def
      if d and d.text then
        local entry = game.data:textEntry(label, d.text)
        if entry and entry.nurse then return npc end
      end
    end
    return nil
  end

  -- Stand in front of the counter and face up; the engine talks across
  -- counter tiles (OverworldController), so both the adjacent cell and the
  -- one below it reach her.
  local function talkToNurse(mapId)
    -- Land on the map FIRST: findNurse reads the overworld's own npc list,
    -- so asking before the teleport asks about the map we are leaving.
    local def = game.data.maps and game.data.maps[mapId]
    local warp = def and def.warps and def.warps[1]
    U.teleport(game, mapId, (warp and warp.x) or 3, (warp and warp.y) or 7, "up")
    U.wait(30)
    local nurse = findNurse()
    if not nurse then return nil, "no nurse on " .. tostring(mapId) end
    for _, dy in ipairs({ 1, 2 }) do
      U.teleport(game, mapId, nurse.cellX, nurse.cellY + dy, "up")
      U.wait(20)
      local was = game.stack:top()
      U.tap(game, "a")
      U.wait(40)
      local top = game.stack:top()
      if top ~= was then
        -- TextBox.pages is a list of PAGES, each of which is a list of
        -- line strings -- so this is two levels deep, not one.
        local said = ""
        if type(top) == "table" and type(top.pages) == "table" then
          for _, page in ipairs(top.pages) do
            if type(page) == "table" then
              for _, line in ipairs(page) do
                if type(line) == "string" then said = said .. " " .. line end
              end
            elseif type(page) == "string" then
              said = said .. " " .. page
            end
          end
        end
        -- A from here on.  Her prompt is a YES/NO and A takes YES -- B
        -- would DECLINE the heal, which would make the control pass for
        -- entirely the wrong reason.
        for _ = 1, 200 do
          if game.stack:top() == C.ow() then break end
          U.tap(game, "a")
          U.wait(12)
        end
        return true, said
      end
    end
    return nil, "pressing A at the nurse opened nothing"
  end

  -- Three mons at the ladder's TOP rung, on their last legs.
  --
  -- The level matters.  BR:tickLevels scales anything below the current
  -- rung and Levels.carryHp then carries 1 HP up into a bigger maximum as
  -- MORE than 1 -- so a low-level probe party "heals" itself a second after
  -- the ring closes and the nurse never has to.  At 100 needsScaling is
  -- never true, so the only thing that can raise this party's HP is her.
  local function stageWounded()
    save.party = {}
    for i = 1, 3 do
      local m = Pokemon.new(game.data, FILL[i], 100)
      m.hp = 1
      save.party[i] = m
    end
  end
  local function healed()
    for _, m in ipairs(save.party or {}) do
      if (m.hp or 0) > 1 then return true end
    end
    return false
  end

  -- A Centre still inside the ring, so the fog cannot be what changes the
  -- party's HP under the probe.
  local function safeCentre()
    local ring = E.ring()
    local field = game.data.field
    local locs = field and field.townMap and field.townMap.locations
    if not (ring and locs) then return nil end
    local best = nil
    for id in pairs(game.data.maps or {}) do
      if type(id) == "string" and id:match("_POKECENTER$")
         and Fog.isSafe(locs, id, { x = ring.x, y = ring.y }, ring.radius) then
        if not best or id < best then best = id end
      end
    end
    return best
  end

  -- --- control: no fog yet, so the nurse still heals
  local centre = safeCentre()
  if not check(centre ~= nil, "found a Pokemon Centre inside the ring") then
    U.log("GIFT: ring was " .. tostring(E.ring() and E.ring().place))
  end

  if centre then
    U.log("GIFT: using " .. centre)
    check(not Fog.isUp(E.ring() and E.ring().radius),
          "control runs while the board still has no fog on it")
    stageWounded()
    local ok, said = talkToNurse(centre)
    check(ok, "the nurse answers at all (" .. tostring(said) .. ")")
    check(healed(), "with no fog she heals, as she always has")
  end

  -- --- wait for the ring to close on its own.
  --
  -- It cannot be hurried: the interval was fixed at Wire.start and the
  -- clock is WALL time, while U.wait counts SIM frames -- at
  -- POKEPORT_SPEED=3 a 45-second phase is ~8100 of them, so the budget
  -- here is deliberately fat rather than tuned.
  local reached = false
  for _ = 1, 1600 do
    U.wait(10)
    local r = E.ring()
    if r and Fog.isUp(r.radius) then reached = true break end
    if E.phase() ~= "match" then break end
  end
  local ring = E.ring()
  check(reached, "the ring closed at least once (phase "
        .. tostring(ring and ring.phase) .. ", radius "
        .. tostring(ring and ring.radius) .. ")")

  if reached then
    local shut = safeCentre()
    if check(shut ~= nil, "a Centre is still inside the closed ring") then
      U.log("GIFT: fogged run uses " .. shut)
      stageWounded()
      local ok, said = talkToNurse(shut)
      check(ok, "she still answers")
      check(not healed(), "but nothing was healed: the counter is shut")
      check(type(said) == "string" and said:lower():find("fog") ~= nil,
            "and she says why:" .. tostring(said))
      check(E.phase() == "match",
            "and the probe is still in the match (phase "
            .. tostring(E.phase()) .. ")")
    end
  end

  local err = E.tickError and E.tickError()
  check(err == nil, "no tick error was logged (" .. tostring(err) .. ")")

  if fails == 0 then
    U.log("GIFT OK")
    love.event.quit(0)
  else
    U.log(("GIFT: %d check(s) failed"):format(fails))
    love.event.quit(1)
  end
  U.wait(10)
end
