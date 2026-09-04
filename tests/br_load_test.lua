-- Standalone: luajit mods/battle_royale/tests/br_load_test.lua
--
-- Loads the mod through the REAL headless loader against the fixture
-- dataset (no ROM import needed) and asserts it reaches "loaded" with no
-- errors.  That covers what br_test.lua cannot: the manifest validates, the
-- entry chunk runs, the sub-modules resolve, and every hook name, event and
-- registry it touches actually exists on this build.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

local run = T.sdk.loadMod("mods/battle_royale")

T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.eq(run.mod and run.mod.state, "loaded", "reached the loaded state")
T.eq(run.mod and run.mod.manifest.id, "battle_royale", "manifest id")

-- the network permission is what lets the mod reach src.link legitimately
T.check(run.mod and run.mod.manifest.permissionSet.network,
  "declares the network permission")

-- the exports other mods / a driver depend on
local exports = run.loader.exports.battle_royale
T.check(type(exports.phase) == "function", "exports phase")
T.check(type(exports.aliveCount) == "function", "exports aliveCount")
T.eq(exports.phase(), "off", "reports 'off' before any room")

-- ------- the launcher can actually offer an update (POK-103)
--
-- "Check for updates" in the launcher walks the INSTALLED mods and skips
-- any without a `github` field outright -- RomImporter:_syncModUpdateInfo
-- does `if m.github and m.github ~= ""` and otherwise clears the row.  This
-- manifest never had one, so the mod was invisible to the updater for its
-- whole life: eleven releases that no player could be offered.
--
-- Manifest.parseGithub is what the loader ran it through, so this asserts
-- the parsed value on the loaded mod rather than the raw JSON.

do
  local gh = run.mod and run.mod.manifest and run.mod.manifest.github
  T.check(gh ~= nil and gh ~= "",
          "the manifest declares a github repo (got " .. tostring(gh) .. ")")
  T.eq(gh, "campavao/kanto-battle-royale", "and it is the mod's own repo")

  -- the parse is strict; a value the launcher would reject must not ship
  local Manifest = require("src.mods.Manifest")
  T.eq(Manifest.parseGithub(gh), gh, "the launcher's own parser accepts it")
  T.check(Manifest.parseGithub(nil) == nil, "absent means no updates")
  T.check(Manifest.parseGithub("") == nil, "and so does empty")
end

-- ------- the START menu rows the mod owns (POK-99 / POK-100)
--
-- Driven through the REAL hook chain, which is the only place the anchor
-- bug is visible: mod.ui.insertBefore APPENDS when its anchor is missing,
-- and the mod's own ROYALE row used to anchor on OPTION -- a row POK-99
-- now removes for the length of a match.  Anchored there it would have
-- landed BELOW QUIT.
--
-- No room is open here, so this is the out-of-match shape: every vanilla
-- row survives and only ROYALE is added.  The in-match shape (OPTION and
-- MODS gone, MAP added) is a live-game check -- inSession() needs a relay.

do
  local Runtime = require("src.mods.Runtime")
  local function labels(items)
    local out = {}
    for i, it in ipairs(items) do out[i] = it.label end
    return table.concat(out, ",")
  end
  local vanilla = { { label = "POKeDEX" }, { label = "POKeMON" },
                    { label = "ITEM" }, { label = "RED" }, { label = "SAVE" },
                    { label = "OPTION" }, { label = "LINK" },
                    { label = "MODS" }, { label = "QUIT" } }
  local game = { save = { party = {} }, data = {} }
  local out = Runtime.call("ui.start_menu.items",
                           function(_, items) return items end, game, vanilla)
  T.check(type(out) == "table", "the start-menu hook returns a table")
  local shown = labels(out)
  T.check(shown:find("ROYALE", 1, true) ~= nil,
          "the mod adds its own row (" .. shown .. ")")
  local royaleAt, quitAt
  for i, it in ipairs(out) do
    if it.label and it.label:find("ROYALE", 1, true) then royaleAt = i end
    if it.label == "QUIT" then quitAt = i end
  end
  T.check(royaleAt and quitAt and royaleAt < quitAt,
          "and puts it above QUIT, not after it (" .. shown .. ")")
  T.check(out[#out].label == "QUIT", "QUIT stays the last row (" .. shown .. ")")
end

-- ------- and the in-match removals, read off the source
--
-- inSession() needs a live relay, so the branch itself cannot run headless.
-- What can be checked is that the branch exists and names the right rows,
-- which is what a future edit would break.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the start-menu scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local hook = src:match('mod%.hooks:wrap%("ui%.start_menu%.items".-\n  end%)')
    T.check(hook ~= nil, "found the start_menu hook")
    if hook then
      for _, row in ipairs({ "LINK", "SAVE", "OPTION", "MODS" }) do
        T.check(hook:find('removeLabel%(out, "' .. row .. '"%)') ~= nil,
                row .. " leaves the menu during a match")
      end
      T.check(hook:find('label = "MAP"', 1, true) ~= nil,
              "the map gets its own row")
      T.check(hook:find('insertBefore%(out, "OPTION"') == nil,
              "nothing anchors on OPTION any more -- it is not there to anchor on")
    end
  end
end

-- ------- Pewter's gym escort stands down for a match (POK-122)
--
-- The escort is armed from two places; this covers the map-script half.
-- What must not regress is the COMPOSITION: the contribution has to be in
-- the chain (so it runs) and must not replace vanilla (so a real
-- playthrough with this mod installed still gets walked to the gym).
-- Setting EVENT_BEAT_BROCK would have been the obvious fix and is the
-- wrong one -- data/scripts/gyms.lua branches BROCK's own talk on that
-- same flag, so it would leave every match a gym leader nobody can fight.

do
  -- Data.map_scripts is only populated on a real boot; a headless load
  -- leaves the contribution in the registry that MapScripts reads its
  -- chain from, so ask the registry directly.
  local reg = run.loader.content and run.loader.content.map_scripts
  T.check(reg ~= nil, "the engine offers a map_scripts registry")
  local chain = reg and reg:chain("PEWTER_CITY")
  T.check(chain ~= nil and #chain > 0,
          "the mod contributes a PEWTER_CITY map script")
  T.check(not (reg and reg:chainReplacesBase("PEWTER_CITY")),
          "it composes with vanilla rather than replacing it")

  local mine
  for _, entry in ipairs(chain or {}) do
    if type(entry) == "table" and entry.onStep then mine = entry end
  end
  T.check(mine ~= nil, "and the contribution carries an onStep")

  if mine then
    -- Idle, the guard stands down entirely: every cell falls through to
    -- base, escort included.  A mod that is installed but not in a match
    -- must leave Kanto exactly as it found it.
    T.eq(mine.onStep(nil, nil, 35, 17), false,
         "idle: a trigger cell is left to vanilla")
    T.eq(mine.onStep(nil, nil, 37, 19), false,
         "idle: the far trigger cell is left to vanilla")
    T.eq(mine.onStep(nil, nil, 1, 1), false,
         "idle: an ordinary cell is not consumed")
  end
end

-- ------- the other lockstep walks stand down too (POK-126, POK-127)
--
-- Same composition contract as the Pewter block above: in the chain so it
-- runs, never replacing base so a real playthrough still gets its scenes.
-- What these add is the CELL LIST, which is the part that rots -- a cell
-- typo is silent, because the symptom is a cutscene that fires in a match
-- nobody is running headlessly.

do
  local reg = run.loader.content and run.loader.content.map_scripts

  -- CERULEAN's Rocket thief: story5.lua M.CERULEAN_CITY.onStep triggers on
  -- (30,7) and (30,9).  Setting EVENT_BEAT_CERULEAN_ROCKET_THIEF instead
  -- would still award TM_DIG and would skip the fade that hides GUARD2.
  --
  -- YELLOW's JESSIE and JAMES: four maps, and three of them gate on
  -- nothing but the tile.  Registered on every cartridge because RED and
  -- BLUE attach no script to these cells -- see the note in main.lua.
  local suppressed = {
    { "CERULEAN_CITY",      { { 30, 7 }, { 30, 9 } } },
    { "MT_MOON_B2F",        { { 3, 5 } } },
    { "ROCKET_HIDEOUT_B4F", { { 24, 14 }, { 25, 14 } } },
    { "POKEMON_TOWER_7F",   { { 10, 12 }, { 11, 12 } } },
    { "SILPH_CO_11F",       { { 0, 3 }, { 1, 3 }, { 2, 3 }, { 3, 3 } } },
  }

  for _, row in ipairs(suppressed) do
    local mapId, cells = row[1], row[2]
    local chain = reg and reg:chain(mapId)
    T.check(chain ~= nil and #chain > 0,
            "the mod contributes a " .. mapId .. " map script")
    T.check(not (reg and reg:chainReplacesBase(mapId)),
            mapId .. " composes with vanilla rather than replacing it")

    local mine
    for _, entry in ipairs(chain or {}) do
      if type(entry) == "table" and entry.onStep then mine = entry end
    end
    T.check(mine ~= nil, mapId .. "'s contribution carries an onStep")

    if mine then
      -- Idle, every one of them stands down: a mod that is installed but
      -- not in a match must leave Kanto exactly as it found it.
      for _, c in ipairs(cells) do
        T.eq(mine.onStep(nil, nil, c[1], c[2]), false,
             ("idle: %s (%d,%d) is left to vanilla"):format(mapId, c[1], c[2]))
      end
    end
  end

  -- The base handlers that were reviewed and KEPT -- forced battles are
  -- fine in a match, forced walks are not.  If a future cell list grows to
  -- cover these, the SUPER NERD and GIOVANNI stop being contestable.
  for _, row in ipairs({ { "MT_MOON_B2F", 13, 8 },
                         { "SILPH_CO_11F", 6, 13 },
                         { "SILPH_CO_11F", 7, 12 } }) do
    local chain = reg and reg:chain(row[1])
    for _, entry in ipairs(chain or {}) do
      if type(entry) == "table" and entry.onStep then
        T.eq(entry.onStep(nil, nil, row[2], row[3]), false,
             ("%s (%d,%d) is not ours to consume"):format(row[1], row[2], row[3]))
      end
    end
  end
end

-- ------- a battle that never ran is not a defeat (POK-134)
--
-- Driven through the REAL event bus, because the bug this replaces was
-- entirely a question of WHICH bus.  The guard shipped on
-- `link.battle_ended`, whose payload LinkState builds by hand
-- ({ result, myParty, theirParty, peerName, role } -- src/link/LinkState.lua),
-- so the `ev.skipped` and `ev.battle.safari` it tested for could never be
-- there and the clause was unreachable.  The refusal really arrives on
-- `battle.ended` (BattleState emits `lose` with `skipped` when it marks a
-- battle dead) and the elimination is raised by the `world.blacked_out`
-- that follows, so the verdict has to be carried between the two.
--
-- Read through the log because that is the one observable that does not
-- need a live match under it: BR:eliminate is a no-op out of a round, so
-- status would look identical either way and prove nothing.
do
  local Runtime = require("src.mods.Runtime")
  local Logger = require("src.core.Logger")
  local setPhase = exports.debugPhase

  T.check(type(setPhase) == "function", "exports debugPhase (the phase fixture)")
  T.check(setPhase("nonsense") == nil, "...which refuses a phase BR does not have")

  local function blackoutAfter(...)
    local seen, real = {}, Logger.warn
    Logger.warn = function(fmt, ...) seen[#seen + 1] = tostring(fmt) end
    for _, ev in ipairs({ ... }) do Runtime.emit("battle.ended", ev) end
    Runtime.emit("world.blacked_out", {})
    Logger.warn = real
    for _, line in ipairs(seen) do
      if line:find("blacked out, but not a loss", 1, true) then return true end
    end
    return false
  end

  -- ------- inside the hunt, where an empty party is the designed state
  local REFUSED  = { result = "lose", skipped = true }
  local SAFARIL  = { result = "lose", battle = { safari = true } }
  local ORDINARY = { result = "lose" }

  for _, phase in ipairs({ "safari", "drop" }) do
    setPhase(phase)
    T.check(blackoutAfter(REFUSED),
            "in " .. phase .. ": a refused battle's blackout is not a loss")
    T.check(blackoutAfter(SAFARIL),
            "in " .. phase .. ": a SAFARI battle's blackout is not a loss either")
    -- the other half, and the one that keeps this honest
    T.check(not blackoutAfter(ORDINARY),
            "in " .. phase .. ": an ordinary loss still blacks out as a loss")
  end

  -- ------- and NOWHERE else (the narrowing).
  --
  -- Catching nothing costs you the match: tickDrop eliminates an
  -- empty-handed player at the buzzer.  Past that point a refused battle
  -- is a real whiteout, because a party can only be empty there if
  -- something went wrong -- and a player quietly immune to elimination is
  -- worse than one eliminated for a reason.  Keyed on the phase rather
  -- than trusted to the buzzer, so it does not depend on an invariant
  -- held in another function.
  for _, phase in ipairs({ "off", "lobby", "match", "over" }) do
    setPhase(phase)
    T.check(not blackoutAfter(REFUSED),
            "in " .. phase .. ": a refused battle's blackout IS a loss")
    T.check(not blackoutAfter(SAFARIL),
            "in " .. phase .. ": a SAFARI-flavoured loss IS a loss too")
  end

  -- ------- the verdict must not go stale, or outlive the phase it was
  -- earned in.
  setPhase("safari")
  -- a refusal, then a real battle, then a blackout is a real whiteout: the
  -- flag is rewritten by EVERY battle.ended, not only by the refusals
  T.check(not blackoutAfter(REFUSED, ORDINARY),
          "a refusal does not excuse the NEXT battle's whiteout")

  -- consumed, not merely read: two blackouts after one refusal means the
  -- second is a real one
  Runtime.emit("battle.ended", REFUSED)
  T.check(blackoutAfter(), "the blackout the refusal earned is excused")
  T.check(not blackoutAfter(),
          "...and the pass is spent -- a second blackout is a real one")

  -- a pass earned in the SAFARI does not survive into the match: the drop
  -- happens between the two, and a refusal from before it must not excuse
  -- a whiteout after it
  Runtime.emit("battle.ended", REFUSED)
  setPhase("match")
  T.check(not blackoutAfter(),
          "a pass earned in the SAFARI does not cross into the match")

  setPhase("off")
end

-- ------- a match that is OVER is over (POK-144 / POK-145)
--
-- All of this is driven through the REAL hook chain, because that is where
-- the bugs lived: the guards existed, they were just asked at the wrong
-- moment or scoped to the wrong window.  A phase table rather than a single
-- case, so the row that fails is named.
do
  local Runtime = require("src.mods.Runtime")
  local setPhase = exports.debugPhase
  local setStatus = exports.debugStatus
  T.check(type(setStatus) == "function", "exports debugStatus (the status fixture)")
  T.check(setStatus("nonsense") == nil, "...which refuses a status BR does not have")
  -- alive, because that is the only interesting one: a spectator is already
  -- refused everything below by the status == "out" clause these hooks have
  -- always had, and what POK-145 is about is the trainer who is still alive
  -- in a match that has stopped.
  setStatus("alive")

  -- ------- T1: the 1X clamp, at every phase.
  --
  -- The clamp was scoped to inRound(), which stops at the last elimination
  -- -- so it lifted the frame the winner was named and the Hall of Fame ran
  -- at whatever the player's GAME SPEED row says.  "over" is the row that
  -- failed.  "lobby"/"off" returning the vanilla value is what keeps the
  -- fix from becoming "the mod owns the speed rows forever".
  local function speedAt(phase)
    setPhase(phase)
    return Runtime.call("core.logic_speed", function() return 4 end, {})
  end
  for _, p in ipairs({ "safari", "drop", "match", "over" }) do
    T.eq(speedAt(p), 1, "the clamp holds 1X in " .. p)
  end
  for _, p in ipairs({ "off", "lobby" }) do
    T.eq(speedAt(p), 4,
         "and lifts in " .. p .. " -- the speed rows are the player's again")
  end

  -- ------- T2: no route trainer opens once the match is over.
  local function trainerCancelled(phase)
    setPhase(phase)
    local got
    Runtime.call("trainer.before_battle", function() got = "ran" return false end,
                 {}, {}, function(o) got = (o and o.cancel) and "cancel" or "continue" end)
    return got
  end
  T.eq(trainerCancelled("match"), "ran", "in a match, Kanto's own trainers fight")
  T.eq(trainerCancelled("over"), "cancel", "once it is over, none of them do")
  T.eq(trainerCancelled("off"), "ran",
       "and out of a session the hook is invisible")
  -- The deliberate side effect of scoping this to canOpenBattle rather than
  -- to "over" alone: the two phases either side of the match refuse as well.
  -- Nobody fights in the Safari (POK-21) and "drop" is the buzzer's own
  -- frame -- there are no route trainers in the zone to notice -- but it is
  -- a real behaviour change and a decision, so it is asserted rather than
  -- left to be rediscovered.  (The GRASS is the other way round in the
  -- Safari -- see T3 -- which is why the two hooks ask different
  -- predicates.)
  T.eq(trainerCancelled("safari"), "cancel", "and nobody fights in the Safari")
  T.eq(trainerCancelled("drop"), "cancel", "nor in the buzzer's own frame")

  -- ------- T3: and nothing walks out of the grass either -- except in the
  -- zone, where walking out of the grass is the entire game.
  local function rolled(phase)
    setPhase(phase)
    return Runtime.call("encounter.roll", function() return "rolled" end, {}, {})
  end
  T.eq(rolled("match"), "rolled", "in a match the grass still rolls")
  T.check(rolled("over") == nil, "once it is over it does not")
  T.eq(rolled("off"), "rolled", "and out of a session the roll is untouched")
  -- The Safari is NOT the same side effect as T2's.  This assertion used to
  -- read the other way, justified by "the zone's wild rolls come through
  -- encounter.species, a separate hook" -- which is not how the engine
  -- chains them: encounter.species is only called on a NON-NIL roll
  -- (src/world/OverworldController.lua:3867-3871).  A nil here is the
  -- zone's grass switched off, so every player walked it for two minutes,
  -- caught nothing, and was eliminated at the buzzer for catching nothing.
  -- 212 assertions passed with the Safari opening dead.
  T.eq(rolled("safari"), "rolled", "the Safari's grass is the point of the Safari")
  T.check(rolled("drop") == nil, "the drop's does not -- it is the buzzer's frame")

  -- ------- T3b: the two hooks AS THE ENGINE CHAINS THEM, which is the
  -- coverage T3 on its own did not have.  rollEncounter calls
  -- encounter.roll, and only if that is non-nil does it pass the result
  -- through encounter.species -- so a test that drives each hook alone can
  -- watch the second one work on a roll the first would never have handed
  -- it.  This drives the pair the way the overworld does.
  local function chained(phase)
    setPhase(phase)
    local enc = Runtime.call("encounter.roll",
                             function() return { species = "RATTATA", level = 3 } end,
                             {}, {})
    if not enc then return nil end
    return Runtime.call("encounter.species", function(e) return e end, enc, {})
  end
  T.check(type(exports.debugSafariPool) == "function",
          "exports debugSafariPool (this match's zone, as a fixture)")
  local pool = exports.debugSafariPool(20260827)
  T.eq(#pool, require("mods.battle_royale.lib.safari").POOL_SIZE,
       "the fixture stands a full zone")
  local inPool = {}
  for _, sp in ipairs(pool) do inPool[sp] = true end

  local caught = chained("safari")
  T.check(caught ~= nil,
          "a step in the zone's grass produces an encounter at all")
  T.check(caught and inPool[caught.species],
          "...drafted from THIS match's zone (got "
          .. tostring(caught and caught.species) .. ")")
  T.eq(caught and caught.level, exports.level(),
       "...at the rung, not the zone's vanilla levels")
  -- and the same chain in a match: the roll survives, the level is
  -- rewritten, and the pool does NOT apply -- outside the zone the species
  -- is whatever the route rolled.
  local wild = chained("match")
  T.check(wild ~= nil, "a route's grass rolls in a match")
  T.eq(wild and wild.species, "RATTATA",
       "...and keeps the route's own species -- the pool is the zone's alone")
  T.eq(wild and wild.level, exports.level(), "...also at the rung")
  T.check(chained("over") == nil,
          "and at \"over\" the chain never reaches encounter.species at all")
  exports.debugSafariPool(nil)

  -- T3c: the other two terms of canRollWild, which the phase table above
  -- cannot see.  A spectator and a player already in a PvP battle are
  -- refused in the ZONE too -- widening the roll to "safari" widened the
  -- phase and nothing else.
  setPhase("safari")
  setStatus("out")
  T.check(Runtime.call("encounter.roll", function() return "rolled" end, {}, {}) == nil,
          "a spectator's grass is quiet even in the zone")
  setStatus("alive")
  T.check(exports.debugPvp(true), "the fixture stands a PvP battle in the zone")
  T.check(Runtime.call("encounter.roll", function() return "rolled" end, {}, {}) == nil,
          "...and a fight already in hand refuses a wild one on top of it")
  exports.debugPvp(false)
  T.eq(rolled("safari"), "rolled", "cleared again: the zone rolls")
  setStatus("alive")

  -- ------- T4: canOpenBattle's truth table.  Cheap, and it is the
  -- predicate every guard above leans on.
  T.check(type(exports.canOpenBattle) == "function", "exports canOpenBattle")
  for _, phase in ipairs({ "off", "lobby", "safari", "drop", "match", "over" }) do
    for _, status in ipairs({ "alive", "out", "battle" }) do
      setPhase(phase)
      setStatus(status)
      local want = (phase == "match" and status == "alive")
      T.eq(exports.canOpenBattle(), want,
           ("a battle may%s open in %s/%s"):format(want and "" or " not", phase, status))
    end
  end
  -- ...and the third term, which nothing above reaches: BR.battle is set one
  -- frame before status follows it, and a live match is the only place that
  -- happens.  With the fixture standing a PvP record, "match"/"alive" -- the
  -- one row that says yes -- has to say no.
  T.check(type(exports.debugPvp) == "function", "exports debugPvp (the PvP fixture)")
  setPhase("match")
  setStatus("alive")
  T.eq(exports.canOpenBattle(), true, "match/alive with no PvP battle: yes")
  T.check(exports.debugPvp(true), "the fixture stands a PvP battle")
  T.eq(exports.canOpenBattle(), false,
       "...and a PvP battle already in hand refuses a second one")
  exports.debugPvp(false)
  T.eq(exports.canOpenBattle(), true, "cleared again: yes")

  -- ------- T11: the scripted route, which neither hook above can see.
  --
  -- encounter.roll is only ever raised by the grass-step roll and
  -- trainer.before_battle only by trainer sight and talk; a gym leader, a
  -- rival, Snorlax, a bird and Mewtwo all build their own BattleState in
  -- src/script/Commands.lua and push it past both.  script.command is the
  -- seam that sees those, and "end" is how a hook stops the script rather
  -- than letting the rest of it run without the fight it was written around.
  --
  -- ...and unlike every other hook in this file, that one is NOT live at
  -- load (POK-155).  It is armed by BR:onStart and dropped by BR:resetMatch,
  -- because a wrap that outlives the match makes
  -- Runtime.wantsHook("script.command") true for the life of the process and
  -- puts every script row of every ordinary playthrough down the runner's
  -- slower branch (src/script/ScriptRunner.lua:168-176).  This is the
  -- assertion that keeps it that way: a fresh load has not touched the hook
  -- at all.
  T.eq(Runtime.wantsHook("script.command"), false,
       "a freshly loaded mod has not wrapped script.command at all")
  T.check(type(exports.debugScriptWrap) == "function",
          "exports debugScriptWrap (the arm/disarm fixture)")
  T.eq(exports.debugScriptWrap(true), true, "...which arms the real link")
  T.eq(Runtime.wantsHook("script.command"), true,
       "and an armed match is what puts the runner on its hooked branch")
  T.eq(exports.debugScriptWrap(true), true, "arming twice is one link, not two")

  local function scripted(phase, name)
    setPhase(phase)
    local ran = false
    local out = Runtime.call("script.command",
                             function() ran = true return nil end, {}, name, {})
    if ran then return "ran" end
    return out
  end
  setStatus("alive")
  T.eq(scripted("match", "start_battle"), "ran", "in a match a scripted fight opens")
  T.eq(scripted("over", "start_battle"), "end", "once it is over the script stops")
  T.eq(scripted("over", "static_battle"), "end", "...and so does a static one")
  T.eq(scripted("over", "rival_battle"), "end", "...and the rival's")
  T.eq(scripted("over", "old_man_demo"), "end", "...and the old man's demo")
  T.eq(scripted("over", "show_text"), "ran",
       "while every other command in the script runs as it always did")
  T.eq(scripted("off", "start_battle"), "ran",
       "and out of a session the wrap is invisible -- a real playthrough is untouched")

  -- ------- T11b: a YIELDING command through the live wrap, on a real
  -- ScriptRunner (POK-155).
  --
  -- Everything above dispatches through Runtime.call by hand, which is a
  -- straight function call and cannot yield.  The real dispatch is a
  -- coroutine: ScriptRunner:exec runs inside one, and show_text pushes a
  -- TextBox and then calls runner:yield() -- from INSIDE the hook's pcall,
  -- three frames down (Hooks:call -> run(index) -> pcall(vanilla)).  Two
  -- engine comments assert LuaJIT lets a coroutine yield across a pcall like
  -- that (src/script/ScriptRunner.lua:168-176, src/script/gen2/Vm.lua), and
  -- BR now leans on it for every script row of every match -- but nothing in
  -- the tree exercised it: tests/mod_scripting_tests.lua:939 wraps
  -- non-yielding commands, and the T11 block above has no ScriptRunner under
  -- it at all.  So it is exercised here.
  --
  -- The fake game is the smallest thing show_text can run against: an empty
  -- text table (so the id falls through to the literal-string path), and a
  -- stack that captures the box instead of drawing it.  An EMPTY string
  -- deliberately -- a real one paginates into glyphs the fixture font does
  -- not have and buries the suite in warnings.  Calling the captured box's
  -- onDone is the player pressing A.
  do
    local ScriptRunner = require("src.script.ScriptRunner")
    local function stage()
      local boxes = {}
      local game = {
        data = { text = {} },
        save = { flags = {}, inventory = {} },
        stack = { push = function(_, state) boxes[#boxes + 1] = state end },
      }
      return ScriptRunner.new(game, nil), game, boxes
    end

    -- (1) it yields, it resumes, and the script finishes.
    setPhase("match")
    setStatus("alive")
    T.eq(Runtime.wantsHook("script.command"), true,
         "the wrap is armed for the yielding run")
    local runner, game, boxes = stage()
    runner:run({ { "set_field", "before", 1 },
                 { "show_text", "" },
                 { "set_field", "after", 1 } }, {})
    T.check(runner:isRunning(), "show_text yields inside the hook's pcall")
    T.eq(#boxes, 1, "...with its box on the stack")
    T.eq(game.save.before, 1, "the row before it ran")
    T.check(game.save.after == nil, "and the row after it has not")
    boxes[1].onDone()
    T.check(not runner:isRunning(), "the box closing resumes the script")
    T.eq(game.save.after, 1, "...and it runs to the end through the live wrap")

    -- (2) the refusal still works on the far side of a yield.  This is what
    -- the wrap is FOR: a gym leader's script is show_text rows and then a
    -- start_battle, so every real refusal happens after at least one yield.
    setPhase("over")
    runner, game, boxes = stage()
    runner:run({ { "show_text", "" },
                 { "start_battle", "fixture" },
                 { "set_field", "after", 1 } }, {})
    T.check(runner:isRunning(), "the leader's text yields")
    boxes[1].onDone()
    T.check(not runner:isRunning(), "and the script resumes past it")
    T.check(game.save.after == nil,
            "...into a refusal that stops the rest of the script")

    -- (3) and a yielded command can span the DISARM.  show_text is suspended
    -- inside the hook's pcall while the input.step tick keeps running, and
    -- that tick can reach resetMatch -- so the link the resume is standing
    -- in can be gone by the time it comes back.  Safe only because BR is the
    -- single link on this hook: `entry` is a captured local and
    -- run(index + 1) re-reads #chain, which is now 0, and runs vanilla.  A
    -- second mod on script.command makes this (and Hooks:call's missing
    -- dispatch snapshot) a real bug.
    setPhase("match")
    runner, game, boxes = stage()
    runner:run({ { "show_text", "" }, { "set_field", "after", 1 } }, {})
    T.check(runner:isRunning(), "suspended inside the hook")
    T.eq(exports.debugScriptWrap(false), false, "the match ends under it")
    boxes[1].onDone()
    T.check(not runner:isRunning(), "the resume lands even though the link went")
    T.eq(game.save.after, 1, "...and the rest of the script runs vanilla")
  end

  -- dropped, the mod is invisible again: the refusal that fired at "over"
  -- three assertions ago does not fire now.  (wantsHook stays true -- the
  -- unregister closure empties the chain but leaves the table, which is
  -- src/mods/Hooks.lua's to fix, not the mod's -- so this asserts the
  -- BEHAVIOUR rather than the flag.)
  T.eq(exports.debugScriptWrap(false), false, "the fixture drops the link")
  T.eq(scripted("over", "start_battle"), "ran",
       "with no match running, a scripted battle is nobody's business")
  T.eq(exports.debugScriptWrap(false), false, "dropping twice is a no-op")

  -- ------- T13: nobody is crowned from outside a round (POK-144).
  --
  -- The first half of the phantom-survivor cascade.  A client whose `start`
  -- was dropped sits in the LOBBY while the room plays a whole match around
  -- it -- it was still allocated a spawn, everyone else seeded it "alive",
  -- and nothing it owns ever broadcasts again, so checkWinner counts it to
  -- the end and crowns it.  With no phase guard, onWinner ran that ending
  -- from the lobby: recordWin() and a saveCareer() of a match this client
  -- never played, skin unlock and all.
  --
  -- debugWin has no guard of its own any more, precisely so this can be
  -- asked of BR rather than of the fixture.
  local winsBefore = exports.skinState().wins
  for _, p in ipairs({ "lobby", "off" }) do
    setPhase(p)
    setStatus("lobby")
    T.check(exports.debugWin() == nil, "no winner is crowned from " .. p)
    T.eq(exports.phase(), p, "...and the phase does not move off " .. p)
  end
  T.eq(exports.skinState().wins, winsBefore,
       "and no career win is banked for a match nobody here played")
  -- ...while the transition the guard must NOT break still works.  Headless
  -- there is no relay and BR.myId is nil, so the crown lands on the local
  -- player whatever is passed -- which is convenient here: the SAME call
  -- that changed nothing at all from the lobby banks a win from a match.
  setPhase("match")
  setStatus("alive")
  T.eq(exports.debugWin(), "over", "a match still ends with a winner")
  T.check(exports.ending() ~= nil, "...and arms the exit on its way out")
  T.eq(exports.skinState().wins, winsBefore + 1,
       "and the career win is banked exactly where it is earned")

  -- ------- T14: and the other half -- a `start` that lands while the last
  -- match is still standing.
  --
  -- The gate on `start` refused the message while self.started was true,
  -- and started is cleared only by resetMatch, which the new ending no
  -- longer runs at "over".  So the message was dropped with no log line and
  -- no change on screen, which is what made the client above a phantom.
  --
  -- It has to arrive through a FULL resetMatch, not clearEnding: the ending
  -- is seven fields and a match is forty.  BR.battle is the leftover this
  -- can stand up headlessly (debugPvp) and it is on the other side of that
  -- line -- clearEnding does not touch it, resetMatch does -- so it is
  -- exactly the difference between the two clears.
  T.eq(exports.phase(), "over", "the match that just ended is still standing")
  T.check(exports.debugPvp(true), "...with a PvP record still in hand")
  local landed, startErr = exports.debugStart({ seed = 7, spawns = {} })
  T.check(startErr == nil,
          "the arriving start applies cleanly (" .. tostring(startErr) .. ")")
  T.eq(landed, "lobby",
       "a client at \"over\" takes the next start rather than dropping it -- "
       .. "a start with no drop for us stops here, and only resetMatch can "
       .. "have put it in the lobby")
  T.check(exports.ending() == nil, "the last match's armed exit went with it")
  setPhase("match")
  setStatus("alive")
  T.eq(exports.canOpenBattle(), true,
       "and its battle record too -- which clearEnding alone would have kept")

  setStatus("lobby")
  setPhase("off")

  -- ------- T5/T6: the guards that cannot be called headlessly, read off
  -- the source -- the established pattern from the start-menu scan above.
  -- BR:startBotBattle and BR:beginBattle are closures over a live engine,
  -- but the guard's PRESENCE is exactly what a future edit would drop.
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the battle-guard scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    for _, fn in ipairs({ "startBotBattle", "beginBattle" }) do
      local body = src:match("function BR:" .. fn .. "%(.-\n  end\n")
      T.check(body ~= nil, "found BR:" .. fn)
      T.check(body and body:find("canOpenBattle", 1, true) ~= nil,
              fn .. " asks the phase at the moment it opens a battle")
      -- Scoped to the BODY, like the assertion above it.  Against the whole
      -- file this bans a perfectly ordinary line from every function in the
      -- mod for ever, and fails whoever writes it next with a message about
      -- beginBattle.
      T.check(body and body:find("if self.battle then return end", 1, true) == nil,
              fn .. " does not fall back to the old battle-only guard")
    end

    -- T6: leaving "match" must ABANDON the walk-up, not fire it.  Firing it
    -- is what opened a bot battle in a finished world.
    local walk = src:match("function BR:tickWalkUp%(.-\n  end\n")
    T.check(walk ~= nil, "found tickWalkUp")
    if walk then
      T.check(walk:find('and self.phase == "match"%) then return abandon%(%)') ~= nil,
              "a match that moved on abandons the walk-up")
      T.check(walk:find("return finish()", 1, true) == nil,
              "...and nothing still calls the old one-exit finish()")
      T.check(walk:find("return arrived()", 1, true) ~= nil,
              "while the walk that ARRIVES still opens the fight (POK-85)")
      -- ...onto a quiet screen only (POK-162): a bot standing beside a
      -- player in a menu waits, and does not push its battle over it
      T.check(walk:find("if not self:screenIsQuiet() then return end\n      return arrived()", 1, true) ~= nil,
              "...and waits beside a player whose screen is busy")
      T.check(walk:find("self.pending = nil", 1, true) ~= nil,
              "an abandoned walk-up clears the pending challenge with it")
    end

    -- ------- T12: the rest of the funnel's wiring, where a live engine hides
    -- it.  endMatch, onAgain, the tick's exit block and tickSays are all
    -- closures over a game, a stack and a relay, so none of them can be
    -- called headless -- and every assertion below is a defect this feature
    -- shipped with once, which is exactly what a source scan is for.

    -- A client can still be at "over" when the next `start` arrives, so the
    -- way IN to a match has to clear what the last one ended with -- above
    -- all `parading`, which otherwise stays true for the session and makes
    -- match two unendable (armEnding refused by the stale pendingEnd, the
    -- tick pushing the clocks every frame).  ONE list, called from both
    -- sides, because two lists drift.
    local clear = src:match("function BR:clearEnding%(.-\n  end\n")
    T.check(clear ~= nil, "found BR:clearEnding")
    for _, field in ipairs({ "pendingEnd", "parading", "overBattleAt",
                             "lastResult", "winnerId",
                             "pendingParade", "pendingFame" }) do
      T.check(clear and clear:find("self." .. field .. " = nil", 1, true) ~= nil,
              "clearEnding clears " .. field)
    end
    for _, fn in ipairs({ "resetMatch", "onStart" }) do
      local body = src:match("function BR:" .. fn .. "%(.-\n  end\n")
      T.check(body ~= nil, "found BR:" .. fn)
      T.check(body and body:find("self:clearEnding()", 1, true) ~= nil,
              fn .. " goes through the one shared list")
    end

    -- ...and the same pair carries the script.command wrap's whole lifetime
    -- (POK-155).  T11 proves the ARMED and DROPPED behaviours through the
    -- fixture, but nothing headless can reach onStart -- it needs a wire
    -- message and a live game -- so the two calls that actually put the mod
    -- on that schedule are read off the source, the way the battle guards
    -- below are.  Drop either one and the fixture-driven tests still pass
    -- while the real game either never refuses a scripted battle or never
    -- gives the hook back.
    do
      local starts = src:match("function BR:onStart%(.-\n  end\n")
      T.check(starts and starts:find("armScriptWrap()", 1, true) ~= nil,
              "onStart arms the scripted-battle wrap")
      local resets = src:match("function BR:resetMatch%(.-\n  end\n")
      T.check(resets and resets:find("disarmScriptWrap()", 1, true) ~= nil,
              "resetMatch drops it again -- the one path every exit takes")
      -- and it is registered in exactly one place, which is not the load
      -- path: a second mod.hooks:wrap on this name would be back to a link
      -- that outlives the match.
      local _, wraps = src:gsub('hooks:wrap%("script%.command"', "")
      T.eq(wraps, 1, "script.command is wrapped in exactly one place")
      local arm = src:match("local function armScriptWrap%(.-\n  end\n")
      T.check(arm and arm:find('hooks:wrap("script.command"', 1, true) ~= nil,
              "...and that place is armScriptWrap")
    end

    -- The deadline has to be able to EXPIRE.  It was reset every frame while
    -- a parade was armed, running or merely flagged -- so on the one route
    -- it exists for, a parade that wedged, it never fired at all while its
    -- comment claimed the opposite.
    local endTick = src:match('if BR%.pendingEnd and BR%.phase == "over" then.-\n    end\n')
    T.check(endTick ~= nil, "found the tick's exit block")
    if endTick then
      T.check(endTick:find("local expired = nowE >= BR.pendingEnd.deadline",
                           1, true) ~= nil,
              "the deadline is read before anything is allowed to push it")
      T.check(endTick:find("game.stack:top() == BR.parading", 1, true) ~= nil,
              "and only a parade actually ON the stack pushes it out")
      T.check(endTick:find("BR:armEnding(why)", 1, true) ~= nil,
              "an exit that threw re-arms instead of stranding the client")
    end

    local ends = src:match("function BR:endMatch%(.-\n  end\n")
    T.check(ends ~= nil, "found BR:endMatch")
    if ends then
      T.check(ends:find("autoStartAt", 1, true) == nil,
              "ending a match does not start the next one on its own")
      T.check(ends:find('if wasInSession then log:say("match over', 1, true) ~= nil,
              "and only writes 'match over' when there was a match to be over")
      T.check(ends:find("if self.tearingDown then return false end", 1, true) ~= nil,
              "a teardown already under way owns the exit: Relay:leave fires "
              .. "`closed` synchronously, so this nests inside itself")
    end

    local again = src:match("function BR:onAgain%(.-\n  end\n")
    T.check(again ~= nil, "found BR:onAgain")
    if again then
      T.check(again:find("armEnding", 1, true) ~= nil,
              "`again` at \"over\" ARMS the exit -- a host cannot pop a "
              .. "guest's Hall of Fame out from under them")
      T.check(again:find("endMatch", 1, true) ~= nil,
              "...and TAKES it for a client that never saw `winner`, which "
              .. "is the recovery this message has always been")
    end

    local says = src:match("function BR:tickSays%(.-\n  end\n")
    T.check(says ~= nil, "found BR:tickSays")
    T.check(says and says:find("if not self:screenIsQuiet() then return end",
                               1, true) ~= nil,
            "a queued say waits for a quiet screen rather than freezing under "
            .. "whatever is on top of it")
    T.check(says and says:find("if self:liveLocalBattle() then return end",
                               1, true) == nil,
            "...and not on a live battle alone, which left the battle-return "
            .. "transition and the parade open to the same freeze")

    -- ORDER, and it is load-bearing: resetMatch clears pendingSays, so the
    -- tick's exit block deletes the win banner if it runs first.  The
    -- banner survives only because tickSays delivers it above, which puts
    -- the runner to work, which makes screenIsQuiet() false, which defers
    -- the exit.  Nothing about either call site says "me first" on its own,
    -- so the order is asserted here.
    local saysAt = src:find('if BR.phase ~= "off" then BR:tickSays() end', 1, true)
    local exitAt = src:find('if BR.pendingEnd and BR.phase == "over" then', 1, true)
    T.check(saysAt and exitAt and saysAt < exitAt,
            "the tick delivers pending says BEFORE the exit that clears them")

    -- The two lines T14 rests on.  A guest reading the MATCH RECORD card
    -- cannot leave "over" by itself, so the gate must not refuse the host's
    -- next start -- and onStart must tear the last match down in full when
    -- it takes one.
    local gate = src:match('elseif msg%.t == "start" then.-\n\n')
    T.check(gate ~= nil, "found the `start` message gate")
    T.check(gate and gate:find("if fromId == self.relay.hostId then",
                               1, true) ~= nil,
            "the gate asks who sent the message and nothing else")
    T.check(gate and gate:find("self.relay.hostId and not self.started",
                               1, true) == nil,
            "...so it no longer drops a start for a client still in a match")
    local into = src:match("function BR:onStart%(.-\n  end\n")
    T.check(into and into:find("if self:inSession() then self:resetMatch() end",
                               1, true) ~= nil,
            "and onStart tears the last match down in full before it builds "
            .. "the next one on top")
    local crowns = src:match("function BR:onWinner%(.-\n  end\n")
    T.check(crowns and crowns:find("if not self:inRound() then return end",
                                    1, true) ~= nil,
            "onWinner is refused from every phase that is not a round")

    T.check(src:find("if BR:inSession() and ev and ev.battle then BR.localBattle",
                     1, true) ~= nil,
            "a battle that opens at \"over\" is recorded, so the funnel can "
            .. "close what no guard could refuse")
  end
end

-- ------- the event queue's wiring (POK-162), read off the source
--
-- onChallenge, onAccept, tickEvents and tickPending are closures over a
-- relay and a stack, so what can be pinned headless is that each gate is
-- still there.  Every line below is the exact shape of the wedge: an
-- answer given under an occupied stack, a pending nothing could clear, a
-- lockstep nobody joined.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the event-queue scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local function body(fn)
      return src:match("function BR:" .. fn .. "%(.-\n  end\n")
    end

    local chal = body("onChallenge")
    T.check(chal ~= nil, "found BR:onChallenge")
    T.check(chal and chal:find('Events.push(self.events, { kind = "challenge"', 1, true) ~= nil,
            "a challenge that lands on a busy screen is queued, not answered")
    T.check(chal and chal:find("if not self:screenIsQuiet() then", 1, true) ~= nil,
            "...and the gate is the one the parade and the exit wait on")
    T.check(chal and chal:find("Engage.answer", 1, true) == nil,
            "onChallenge itself no longer answers; answerChallenge does")

    local acc = body("onAccept")
    T.check(acc ~= nil, "found BR:onAccept")
    T.check(acc and acc:find("pend.nonce == nonce", 1, true) ~= nil,
            "an accept has to name the challenge it answers")
    T.check(acc and acc:find('Events.push(self.events, { kind = "begin"', 1, true) ~= nil,
            "an accept that lands on a busy screen queues the opening")
    T.check(acc and acc:find('Wire.decline(nonce, "timeout")', 1, true) ~= nil,
            "a late accept is declined so the accepter's lockstep closes")
    T.check(acc and acc:find("self.battle.opponentId == fromId then return end", 1, true) ~= nil,
            "...but never during the battle it crossed (a mutual sighting)")

    local dec = body("onDecline")
    T.check(dec ~= nil, "found BR:onDecline")
    T.check(dec and dec:find('Events.drop(self.events, "challenge", fromId)', 1, true) ~= nil,
            "a decline pulls that challenger's held challenge")
    T.check(dec and dec:find("b.nonce == nonce", 1, true) ~= nil
            and dec:find("not b.channel.heard", 1, true) ~= nil
            and dec:find("b.channel:peerGone()", 1, true) ~= nil,
            "...and closes a lockstep opened on that nonce that nobody joined")

    local tick = body("tickPending")
    T.check(tick ~= nil, "found BR:tickPending")
    T.check(tick and tick:find("Engage.stale(pend, now, Engage.PENDING_SECONDS)", 1, true) ~= nil,
            "a pending challenge times out")
    T.check(tick and tick:find("self.walkUp and self.walkUp.id == pend.to", 1, true) ~= nil,
            "...except while a bot is walking over on it (POK-85)")
    T.check(tick and tick:find("Engage.LINK_OPEN_SECONDS", 1, true) ~= nil
            and tick:find("not b.channel.heard", 1, true) ~= nil,
            "a lockstep whose peer never spoke is closed")

    local ev = body("tickEvents")
    T.check(ev ~= nil, "found BR:tickEvents")
    T.check(ev and ev:find("Events.expire(q, now, Events.HOLD_SECONDS)", 1, true) ~= nil
            and ev:find('Wire.decline(ev.nonce, "held")', 1, true) ~= nil,
            "a challenge held too long is declined, not forgotten")
    T.check(ev and ev:find("if not self:screenIsQuiet() then return end", 1, true) ~= nil,
            "the queue drains onto a quiet screen only")

    -- and the tick runs both, next to the walk-up
    T.check(src:find("BR:tickWalkUp()\n    -- the challenges waiting for a quiet screen", 1, true) ~= nil
            and src:find("    BR:tickEvents()\n    BR:tickPending()\n", 1, true) ~= nil,
            "the tick drains the queue and runs the nets every frame")

    -- the eyeline holds off a trainer in a menu; the mark now covers a
    -- dialog too, which is the nurse
    local try = body("tryEngage")
    T.check(try and try:find("if not self:screenIsQuiet() then return end", 1, true) ~= nil,
            "tryEngage fires from a quiet screen only")
    T.check(try and try:find("(p.busy ~= nil and not Bots.isBot(id))", 1, true) ~= nil,
            "...and does not challenge a trainer in a menu (a bot has no menu)")
    T.check(try and try:find('p.busy == "battle"', 1, true) ~= nil,
            "...nor a bot mid-fight, the rule the bump shares (POK-165)")
    local bot = body("tryBotEngage")
    T.check(bot and bot:find("if not self:screenIsQuiet() then return end", 1, true) ~= nil,
            "a bot does not spot a player whose screen is busy")
    local busy = src:match("local function myBusy%(%).-\n  end\n")
    T.check(busy and busy:find("ow.runner:isRunning()", 1, true) ~= nil,
            "a running dialog is broadcast as a menu")

    -- resetMatch drops the queue with the rest of the match
    T.check(src:find("    self.pendingSays = {}\n    Events.clear(self.events)\n", 1, true) ~= nil,
            "resetMatch clears the queue")
  end
end

-- ------- the route trainers' sight lines stay down (POK-163)
--
-- POK-150's lever is a talk table per map, filled at onStart.  A playtest
-- saw the sight lines come back mid-match and nothing reproduces it, so
-- the lever is now re-checked every TRAINER_TALK_TICKS and ranked above
-- any other mod's talk table.  What can be pinned headless: the
-- registration carries the rank, the re-check exists and runs from the
-- tick, and a re-arm that finds something missing says so in the log.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the trainer-talk scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    T.check(src:find("local contribution = { onInteract = fieldMoveInteract, priority = 50 }", 1, true) ~= nil,
            "the map-script contribution outranks the default priority")
    local tick = src:match("function BR:tickTrainerTalk%(.-\n  end\n")
    T.check(tick ~= nil, "found BR:tickTrainerTalk")
    T.check(tick and tick:find("self:armTrainerTalk()", 1, true) ~= nil,
            "the re-check re-arms")
    T.check(tick and tick:find("log:warn(", 1, true) ~= nil
            and tick:find("re-armed (POK-163)", 1, true) ~= nil,
            "...and a re-arm that found something missing is logged")
    T.check(src:find("    BR:tickPending()\n    -- ...and the route trainers' sight lines stay down (POK-163)\n    BR:tickTrainerTalk()\n", 1, true) ~= nil,
            "the tick runs the re-check")
    local arm = src:match("function BR:armTrainerTalk%(.-\n  end\n")
    T.check(arm and arm:find("return armed, maps", 1, true) ~= nil,
            "armTrainerTalk reports what it installed")
    T.check(src:find('log:say("route trainers stand down: %d talk handlers on %d maps"', 1, true) ~= nil,
            "onStart logs the arm count")
  end
end

-- ------- a quick room does not roll into the next match (POK-167)
--
-- The countdown is host-local clock state, so what a headless run can
-- pin is the wiring: every start consumes it, the READY UP lever exists,
-- and the lobby offers it in a quick room after a match instead of the
-- instant start.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  local m = io.open("mods/battle_royale/lib/menu.lua", "r")
  if not (f and m) then
    io.write("  (skipping the quick-again scan: sources not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local menu = m:read("*a")
    m:close()
    local start = src:match("function BR:startMatch%(.-\n  end\n")
    T.check(start ~= nil, "found BR:startMatch")
    T.check(start and start:find("self.autoStartAt = nil", 1, true) ~= nil,
            "a start consumes the quick-play countdown")
    local ready = src:match("function BR:readyUp%(.-\n  end\n")
    T.check(ready ~= nil, "found BR:readyUp")
    T.check(ready and ready:find("QUICK_START_SECONDS", 1, true) ~= nil,
            "...which arms the same sixty seconds the first lobby had")
    T.check(ready and ready:find('self.phase ~= "lobby" or self.autoStartAt then return false', 1, true) ~= nil,
            "...only from a lobby that is not already counting")
    T.check(menu:find('if BR.quick and BR.lastResult and not countdown then', 1, true) ~= nil
            and menu:find('label = "READY UP"', 1, true) ~= nil
            and menu:find("BR:readyUp()", 1, true) ~= nil,
            "a quick room after a match offers READY UP, not an instant start")
  end
end

-- ------- a ball that changed hands is a trade (POK-179), read off the
-- source: claimSpill asks the engine's own trade check, only for a ball
-- somebody else dropped, and plays the engine's own movie.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the trade-evolution scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local claim = src:match("function BR:claimSpill%(.-\n  end\n")
    T.check(claim ~= nil, "found BR:claimSpill")
    T.check(claim and claim:find("if not Spills.isOwn(key, self.myId) and Evolution.pendingFor(game, mon, trade) then", 1, true) ~= nil,
            "a trade evolution is asked only for a ball somebody else dropped")
    T.check(claim and claim:find('local trade = { kind = "trade" }', 1, true) ~= nil,
            "...through the engine's own TRADE method")
    T.check(claim and claim:find("Evolution.request(game, mon, trade)", 1, true) ~= nil,
            "...and plays the engine's own evolution movie")
    T.check(claim and claim:find("Party.add(save.party, mon)", 1, true) ~= nil
            and claim:find("Party.add(", 1, true) < claim:find("Evolution.pendingFor(", 1, true),
            "the mon joins the party before it evolves")
  end
end

-- ------- the stone counter (POK-178), read off the source: the talk
-- hook answers the 4F clerk with the extended list, only in a session,
-- and the MOON STONE's price goes back at resetMatch.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the stone-counter scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local talk = src:match('mod%.hooks:wrap%("world%.talk".-\n  end%)\n')
    T.check(talk ~= nil, "found the talk hook")
    T.check(talk and talk:find("Shops.stock(entry.label, entry.mart)", 1, true) ~= nil,
            "a mart entry is asked whether it is the stone counter")
    T.check(talk and talk:find('Screens.push(game, "ShopMenu", stock)', 1, true) ~= nil,
            "...and the counter opens the engine's own shop over the extended list")
    -- the counter sits under the session guard the cable club and nurse share
    local guard = talk and talk:find("if BR:inSession() and def and def.text and data and data.textEntry", 1, true)
    local counter = talk and talk:find("Shops.stock(entry.label, entry.mart)", 1, true)
    T.check(guard and counter and guard < counter, "...only while the match world exists")
    local reset = src:match("function BR:resetMatch%(.-\n  end\n")
    T.check(reset and reset:find("restoreMoonStone(", 1, true) ~= nil
            and reset:find("self.moonStonePrice = nil", 1, true) ~= nil,
            "resetMatch gives the MOON STONE its ROM price back")
  end
end

-- ------- A on a bag opens the bag (POK-176), read off the source: no
-- text box before the list, USE / TAKE / CANCEL per row, and a take that
-- travels by the item so the rest stays on the ground.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the loot-bag scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local open = src:match("function BR:openBag%(.-\n  end\n")
    T.check(open ~= nil, "found BR:openBag")
    T.check(open and open:find('ListMenu.new(game, (who .. "\'s BAG"):sub(1, 17), self:lootRows(key)', 1, true) ~= nil,
            "A on a bag pushes the item list of that bag alone")
    T.check(open and open:find("TextBox", 1, true) == nil and open:find("Take it?", 1, true) == nil,
            "...with no text box first")
    local choose = src:match("function BR:lootChoose%(.-\n  end\n")
    T.check(choose ~= nil, "found BR:lootChoose")
    T.check(choose and choose:find('label = "USE"', 1, true) ~= nil
            and choose:find('label = "TAKE"', 1, true) ~= nil
            and choose:find('label = "CANCEL"', 1, true) ~= nil,
            "a row offers USE / TAKE / CANCEL")
    T.check(choose and choose:find("if id ~= MONEY_ROW then", 1, true) ~= nil,
            "...and the money row only TAKE")
    local take = src:match("function BR:lootTake%(.-\n  end\n")
    T.check(take ~= nil, "found BR:lootTake")
    T.check(take and take:find("self.relay:broadcast(Wire.took(key, id, n))", 1, true) ~= nil,
            "a take travels by the item and count")
    T.check(take and take:find("Bag.add(save, id, n, game.data)", 1, true) ~= nil,
            "...through the bag's own capacity rule")
    local use = src:match("function BR:lootUse%(.-\n  end\n")
    T.check(use and use:find("if not self:lootTake(key, id) then return false end", 1, true) ~= nil
            and use:find("BagMenu.new(game, {})", 1, true) ~= nil,
            "USE takes the item and opens the PACK on it")
    T.check(src:find("self.spills:takeItem(msg.key, msg.item, msg.n, msg.cash)", 1, true) ~= nil,
            "a rival's per-item take lightens our copy of the bag")
    T.check(src:find('"Open the PACK\\nnow?"', 1, true) == nil,
            "the second question is gone")
  end
end

-- ------- pickups are walkable, and A on the tile takes them (POK-175),
-- read off the source: the placement rule refuses a cell with a ball on
-- it (passable balls would stack), the trade-drop path lands by the same
-- rule as a fall (the doorway hole POK-94 left), and an A press that
-- resolves to nothing asks the cell under the player.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the walkable-pickup scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local free = src:match("local function spillCellFree%(.-\n  end\n")
    T.check(free ~= nil, "found spillCellFree")
    T.check(free and free:find("BR.spills:keyAt(mapId, x, y) then return false", 1, true) ~= nil,
            "a cell with a ball on it is not free (no stacking)")
    T.check(free and free:find("Spawn.isWarp(data.maps, mapId, x, y) then return false", 1, true) ~= nil,
            "...and a doorway still is not")
    local drop = src:match("function BR:spillDropped%(.-\n  end\n")
    T.check(drop ~= nil, "found BR:spillDropped")
    T.check(drop and drop:find("return spillCellFree(data, here.mapId, x, y)", 1, true) ~= nil
            and drop:find("Spawn.walkable(", 1, true) == nil,
            "a traded-away mon lands by the fall's own cell rule, not bare walkability")
    local at = src:match('mod%.events:on%("world%.interacted", function%(ev%).-\n  end%)\n')
    T.check(at ~= nil, "found the A-on-the-tile listener")
    T.check(at and at:find('ev.kind == "none"', 1, true) ~= nil,
            "it answers only a press that resolved to nothing (facing wins)")
    T.check(at and at:find("BR.spills:keyAt(here.mapId, here.x, here.y)", 1, true) ~= nil
            and at:find("BR:openSpill(key)", 1, true) ~= nil,
            "...and opens the ball under the player's feet")
    T.check(at and at:find('BR.status == "alive"', 1, true) ~= nil
            and at:find("not BR.battle and not BR.botFight", 1, true) ~= nil,
            "...under the same guards as the faced-ball path")
  end
end

-- ------- the daily host's clock survives the hour (POK-180), read off
-- the source: the info handler goes through the rule, not straight to
-- the field, and a driver can hand it a late answer.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the daily re-arm scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local info = src:match('relay:on%("info", function%(_, info%).-\n    end%)\n')
    T.check(info ~= nil, "found the info handler")
    T.check(info and info:find("BR:armDaily(info.daily.secs)", 1, true) ~= nil,
            "the info handler arms through BR:armDaily")
    T.check(info and info:find("BR.autoStartAt = ", 1, true) == nil,
            "...and never writes the deadline itself")
    local arm = src:match("function BR:armDaily%(.-\n  end\n")
    T.check(arm ~= nil, "found BR:armDaily")
    T.check(arm and arm:find("Daily.rearm(self.autoStartAt, at)", 1, true) ~= nil,
            "armDaily is Daily.rearm over the held deadline")
    T.check(src:find("mod.exports.debugDailyInfo = function(secs)", 1, true) ~= nil,
            "a driver can hand the handler a late answer")
  end
end

-- ------- text never parks a match (POK-169/170) and a bump is a challenge
-- (POK-165), read off the source

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the auto-advance/bump scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    T.check(src:find("local AUTO_ADVANCE_SECONDS = 3", 1, true) ~= nil,
            "text auto-advances after three seconds")
    local auto = src:match("function BR:tickAutoResolve%(.-\n  end\n")
    T.check(auto ~= nil, "found BR:tickAutoResolve")
    T.check(auto and auto:find("lb.msgWaiting or lb.msgPrompt", 1, true) ~= nil
            and auto:find('press("b")', 1, true) ~= nil,
            "battle text waiting on a button is pressed through with B, never A (POK-66)")
    T.check(auto and auto:find("getmetatable(top) == TextBox", 1, true) ~= nil,
            "a text box of its own is pressed through too")
    T.check(auto and auto:find("self.runnerBusySince = now", 1, true) ~= nil,
            "each box gets its own three seconds")
    local coll = src:match('mod%.hooks:wrap%("movement%.collision".-\n  end%)\n')
    T.check(coll ~= nil, "found the collision hook")
    T.check(coll and coll:find("BR:trainerAtCell(ctx.map.id, ctx.toX, ctx.toY)", 1, true) ~= nil
            and coll:find('ctx.reason = "engage"', 1, true) ~= nil,
            "a step into a trainer is the engage gesture, refused only while a fight can start")
    T.check(src:find('BR:challengeTrainer(id, "walking up")', 1, true) ~= nil,
            "the walk-up talk starts the same fight")
    local chal = src:match("function BR:challengeTrainer%(.-\n  end\n")
    T.check(chal and chal:find("self:fleeAvoid(true)[id]", 1, true) ~= nil,
            "...and neither starts inside a flee's grace")
  end
end

-- ------- the last turn's text does not flash (POK-173) and the bots do
-- not queue up on the player (POK-174), read off the source

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the POK-173/174 scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local tb = src:match("function BR:tickBattleText%(.-\n  end\n")
    T.check(tb ~= nil and tb:find('lb.phase == "menu" and lb.msgHold then lb.msgHold = nil', 1, true) ~= nil,
            "a battle at the menu drops the stale text hold (POK-173)")
    T.check(src:find("    BR:tickAutoResolve(game)\n    BR:tickBattleText()\n", 1, true) ~= nil,
            "...every tick")
    local Bots = require("mods.battle_royale.lib.bots")
    T.check(type(Bots.BREATHER) == "number" and Bots.BREATHER >= 5 and Bots.BREATHER <= Bots.FIGHT_COOLDOWN,
            "the player's breather is real and no longer than the bots' own")
    T.check(src:find('if BR.phase == "match" then BR:startBreather() end', 1, true) ~= nil
            and src:find("BR:startBreather()   -- POK-174, the link battle's turn", 1, true) ~= nil,
            "every fight's end starts the breather")
    local try = src:match("function BR:tryEngage%(.-\n  end\n")
    local bot = src:match("function BR:tryBotEngage%(.-\n  end\n")
    T.check(try and try:find("if self:inBreather() then return end", 1, true) ~= nil
            and bot and bot:find("if self:inBreather() then return end", 1, true) ~= nil,
            "neither eyeline fires inside it")
    T.check(src:find('and otherId ~= self.botFight and o.busy ~= "battle" then', 1, true) ~= nil,
            "a fighting trainer is not prey, so bots walk at each other")
    T.check(src:find("and not self:inBreather(now))", 1, true) ~= nil,
            "...and neither is a player in the breather")
    local chal = src:match("function BR:challengeTrainer%(.-\n  end\n")
    T.check(chal and chal:find("inBreather", 1, true) == nil,
            "a deliberate bump or talk still fights: the breather is a shield, not a cage")
  end
end

run.release()
T.finish("br_load")
