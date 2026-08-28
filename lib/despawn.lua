-- Hiding a map trainer without stranding the script still walking him.
--
-- The freeze this exists to stop: BR hid a beaten trainer through
-- `mod.world:toggleObject`, which for the CURRENT map ends in a full
-- `ow:setMap(..., via = "reload")` (src/world/WorldAPI.lua:341).  That
-- rebuilds `ow.npcs` without him and never touches `ow.scriptMoves`, so the
-- vanilla script that is mid-walk-out -- data/scripts/story3.lua:588, the
-- Game Corner Rocket -- keeps calling `ow:scriptMove` on the npc its closure
-- captured.  A move only retires on `not mv.entity.moving`
-- (OverworldController.lua:4842), `moving` is only cleared by `npc:update()`,
-- and update iterates `self.npcs` (OverworldController.lua:1212) -- which he
-- is no longer in.  The move never retires, `#scriptMoves > 0` gates
-- `handleInput`, and the player loses the D-pad AND START for good.
--
-- Switching to the engine's in-place `Commands.hide_object` does not help:
-- it removes him from `ow.npcs` too (src/script/Commands.lua:575-580).
-- Removal by ANY mechanism strands the move.  What is load-bearing is WHEN
-- the removal happens, not HOW -- so:
--
--   the toggle-store write is immediate; the sprite removal waits for a
--   quiet frame.
--
-- `hide` writes `save.objectToggles` on the spot, which is the half that
-- actually has to be prompt (it is what the spawn filter reads, so he is
-- gone on the next map entry no matter what happens next) and the half that
-- is safe to do at any time -- it touches no live entity.  The removal is
-- queued and drained only on a frame where the engine itself would let the
-- player move, so no script is holding a reference to him.
--
-- `seen` is exactly "already in the queue": the fog sweep calls hide many
-- times in one frame, and draining an entry lets a later hide queue again.

local Despawn = {}
Despawn.__index = Despawn

function Despawn.new()
  return setmetatable({ queue = {}, seen = {} }, Despawn)
end

-- The engine's own composite at OverworldController.lua:1229-1231, plus the
-- `transitioning` it is paired with two lines down -- if any of these is
-- set, the frame belongs to a script and an entity may still be spoken for.
-- The script runner is in here for the reason the whole file exists: a
-- script BETWEEN two scriptMoves has an empty queue and is about to push
-- another move onto the npc we are being asked to delete.
local function busy(ow)
  local runner = ow.runner
  return (runner and runner.isRunning and runner:isRunning())
    or #(ow.scriptMoves or {}) > 0
    or ow.engaging or ow.transitioning or ow.emote or ow.teleportOut
    or ow.flyAnim or ow.flyArrive
end

-- Immediate store write, deferred removal.  Never reloads the map and never
-- removes a live NPC -- both of those are drain's job, later.
function Despawn:hide(game, mapId, objName)
  local save = game and game.save
  if not save or mapId == nil or objName == nil then return end
  save.objectToggles = save.objectToggles or {}
  save.objectToggles[mapId] = save.objectToggles[mapId] or {}
  save.objectToggles[mapId][objName] = false
  local seen = self.seen[mapId]
  if not seen then seen = {}; self.seen[mapId] = seen end
  if seen[objName] then return end
  seen[objName] = true
  self.queue[#self.queue + 1] = { map = mapId, obj = objName }
end

-- `quiet` is the caller's own "nothing of mine is happening either".
-- Returns how many sprites were actually removed.
function Despawn:drain(game, ow, quiet)
  local save = game and game.save
  if not quiet or not ow or not save or busy(ow) then return 0 end
  local Commands = require("src.script.Commands")
  local ctx = { game = game, save = save, overworld = ow }
  local removed = 0
  for _, entry in ipairs(self.queue) do
    -- guarded because hide_object dereferences ow.map.id unguarded
    -- (Commands.lua:558); off the map the store write already did all that
    -- can be done, and the spawn filter hides him on re-entry
    if ow.map and ow.map.id == entry.map then
      Commands.hide_object(ctx, entry.map, entry.obj)
      removed = removed + 1
    end
    local seen = self.seen[entry.map]
    if seen then seen[entry.obj] = nil end
  end
  self.queue = {}
  return removed
end

-- Called when a match ends.  A queue that outlives the match would drain
-- into the player's real playthrough and hide a trainer there permanently.
function Despawn:clear()
  self.queue, self.seen = {}, {}
end

function Despawn:count()
  return #self.queue
end

return Despawn
