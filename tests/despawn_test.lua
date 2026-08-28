-- Beating a map trainer must not freeze the player (POK-134 follow-up).
--
-- The live bug: BR hid the beaten trainer by removing him from `ow.npcs` on
-- the spot, while the vanilla script was still walking him out with
-- `ow:scriptMove`.  A move only retires once its entity stops `moving`, and
-- only npcs in `ow.npcs` are updated -- so the move never retired,
-- `#scriptMoves > 0` held the input gate down, and the D-pad and START were
-- gone for the rest of the run.
--
-- lib/despawn.lua splits the two halves: the toggle-store write is
-- immediate, the sprite removal waits for a quiet frame.  t1 below is the
-- test that would have caught the original bug.
--
--   luajit mods/battle_royale/tests/despawn_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Despawn = require("mods.battle_royale.lib.despawn")

local MAP, ROCKET = "GAME_CORNER", "ROCKET"

-- The shape Commands.hide_object actually reads: npcs/entities keyed by
-- `def.name`, npcPool keyed by `id`.  A real OverworldState is not needed
-- and would not be honest -- what is under test is the timing, not the map.
local function fakeWorld(mapId, names)
  local ow = { map = { id = mapId }, npcs = {}, entities = {},
               npcPool = {}, scriptMoves = {} }
  for _, name in ipairs(names or {}) do
    local npc = { id = name, def = { name = name }, moving = false }
    ow.npcs[#ow.npcs + 1] = npc
    ow.entities[#ow.entities + 1] = npc
    ow.npcPool[npc.id] = npc
  end
  return ow
end

local function fakeGame()
  return { save = {} }
end

local function hasNpc(ow, name)
  for _, n in ipairs(ow.npcs) do
    if n.def and n.def.name == name then return true end
  end
  return false
end

local function toggle(game, mapId, objName)
  local t = game.save.objectToggles
  t = t and t[mapId]
  return t and t[objName]
end

-- t1 -- the regression.  A script move is live, so the sprite stays; the
-- store write must NOT have been deferred along with it.
do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
  ow.scriptMoves = { { entity = ow.npcs[1], remaining = 3 } }
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)

  T.check(hasNpc(ow, ROCKET),
          "a hide during a scriptMove leaves the npc in ow.npcs this tick")
  T.eq(toggle(game, MAP, ROCKET), false,
       "...and the toggle store already says hidden, same tick")

  -- even asked nicely, the drain refuses while the move is unretired
  T.eq(d:drain(game, ow, true), 0, "a quiet drain removes nothing mid-move")
  T.check(hasNpc(ow, ROCKET), "the npc the script still walks is untouched")
  T.eq(d:count(), 1, "and the removal is still owed")
end

-- t2 -- the move retired, the frame is quiet: now he goes.
do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET, "CLERK" })
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  T.eq(d:drain(game, ow, true), 1, "a quiet drain with no scriptMoves removes one")

  T.check(not hasNpc(ow, ROCKET), "gone from ow.npcs")
  T.eq(ow.npcPool[ROCKET], nil, "gone from ow.npcPool")
  local inEntities = false
  for _, e in ipairs(ow.entities) do
    if e.def and e.def.name == ROCKET then inEntities = true end
  end
  T.check(not inEntities, "gone from ow.entities")
  T.eq(d:count(), 0, "and the queue is empty")
  T.check(hasNpc(ow, "CLERK"), "the bystander is left alone")
end

-- t3 -- the caller says the frame is not quiet: nothing moves, nothing lost.
do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  T.eq(d:drain(game, ow, false), 0, "drain(quiet=false) removes nothing")
  T.check(hasNpc(ow, ROCKET), "the npc is still there")
  T.eq(d:count(), 1, "and the entry is still queued for a later frame")
end

-- t4 -- the fog sweep calls hide every frame it runs; one entry, not five.
do
  local game = fakeGame()
  local d = Despawn.new()
  for _ = 1, 5 do d:hide(game, MAP, ROCKET) end
  T.eq(d:count(), 1, "five hides of the same object queue one entry")
  d:hide(game, MAP, "CLERK")
  T.eq(d:count(), 2, "a different object on the same map still queues")
  d:hide(game, "CELADON_CITY", ROCKET)
  T.eq(d:count(), 3, "so does the same name on a different map")
end

-- t5 -- off the current map there is nothing to remove, and the store write
-- is the whole fix: the spawn filter hides him when the map is next entered.
do
  local game, ow = fakeGame(), fakeWorld("CELADON_CITY", { "CELADON_NPC" })
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  T.eq(toggle(game, MAP, ROCKET), false, "an off-map hide still writes the store")
  T.eq(#ow.npcs, 1, "and touches no npc on the map we are standing on")
  T.eq(d:drain(game, ow, true), 0, "the drain removes nothing off-map")
  T.eq(#ow.npcs, 1, "the current map is still whole")
  T.eq(d:count(), 0, "and the entry is dropped, not carried forever")
end

-- t6 -- clear() at the end of a match.  This guards a WORSE bug than the
-- freeze: a deferred removal that drained after resetMatch would call
-- hide_object against whatever save is current THEN -- the player's real
-- playthrough -- and hide one of their trainers permanently.
do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  d:clear()
  T.eq(d:count(), 0, "clear() empties the queue")
  T.eq(d:drain(game, ow, true), 0, "a drain after clear() removes nothing")
  T.check(hasNpc(ow, ROCKET), "the trainer in the real playthrough survives")

  -- ...and clear() must forget the dedupe too, or the next match could
  -- never hide that trainer again
  d:hide(game, MAP, ROCKET)
  T.eq(d:count(), 1, "and the next match can queue the same object again")
end

-- Every field of the busy composite, one at a time, so an edit that drops
-- one is caught here instead of as a freeze mid-match.  These mirror
-- OverworldController.lua:1229-1231.
do
  local fields = { "engaging", "transitioning", "emote", "teleportOut",
                   "flyAnim", "flyArrive" }
  for _, field in ipairs(fields) do
    local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
    ow[field] = true
    local d = Despawn.new()
    d:hide(game, MAP, ROCKET)
    T.eq(d:drain(game, ow, true), 0, "ow." .. field .. " blocks the drain")
    T.check(hasNpc(ow, ROCKET), "ow." .. field .. ": the npc stays")
    T.eq(d:count(), 1, "ow." .. field .. ": the removal is still owed")

    -- and clearing it lets the same drain through, so the guard is that
    -- field and not something else about the fake
    ow[field] = nil
    T.eq(d:drain(game, ow, true), 1, "ow." .. field .. " cleared: the drain runs")
    T.check(not hasNpc(ow, ROCKET), "ow." .. field .. " cleared: the npc goes")
  end
end

-- scriptMoves and the script runner, the two that are not plain flags
do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
  ow.scriptMoves = { { entity = ow.npcs[1], remaining = 1 } }
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  T.eq(d:drain(game, ow, true), 0, "a non-empty ow.scriptMoves blocks the drain")
  ow.scriptMoves = {}
  T.eq(d:drain(game, ow, true), 1, "an empty one does not")
end

do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
  local running = true
  ow.runner = { isRunning = function() return running end }
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  -- a script between two scriptMoves has an empty move queue and is about
  -- to push another move onto the npc we are being asked to delete
  T.eq(d:drain(game, ow, true), 0, "a running script blocks the drain")
  running = false
  T.eq(d:drain(game, ow, true), 1, "a finished one does not")
end

-- a nil ow.map: hide_object dereferences ow.map.id unguarded, so the drain
-- must not reach it (Commands.lua:558)
do
  local game, ow = fakeGame(), fakeWorld(MAP, { ROCKET })
  ow.map = nil
  local d = Despawn.new()
  d:hide(game, MAP, ROCKET)
  T.eq(d:drain(game, ow, true), 0, "a mapless overworld drains without throwing")
  T.eq(d:count(), 0, "and the entry is dropped")
end

-- The reload is what stranded the scripted move, and nothing in the unit
-- suite can see it happen: br_test never builds a real OverworldState and
-- never loads data/scripts/story3.lua, which is why 1810 assertions passed
-- straight over the freeze.  This is the cheap guard that the next edit does
-- not quietly put it back.  Reading a source file is fine here -- tests run
-- under luajit, not the mod sandbox.
do
  local f = assert(io.open("mods/battle_royale/main.lua", "r"))
  local src = f:read("*a")
  f:close()
  T.check(not src:find("toggleObject(", 1, true),
       "main.lua reaches the toggle store through despawn, never toggleObject")
  T.check(src:find("despawns:drain(", 1, true) ~= nil,
       "and something actually drains the queue")
end

T.finish("battle royale despawn")
