-- Level scaling on the shared match clock (DESIGN D12).
--
-- Pure: a ladder and the arithmetic around it, so tests/br_test.lua can
-- check the shape without an engine.  The mutation of an actual Pokemon
-- lives in main.lua, where engine access is normal.
--
-- ONE CLOCK, NOT TWO.  The rungs are indexed by the FOG's phase, so a ring
-- shrink and a power spike are the same beat: the map tightens and everyone
-- gets stronger at the same moment.  That was the point of D11's "shrinks
-- share the match clock with level-scaling" -- two timers would give a match
-- two unrelated rhythms and neither would read.
--
-- Everyone scales, so nobody falls behind by being unlucky: a late catch
-- snaps to the current rung too, which is what keeps a Pokemon you found in
-- the last ring worth catching at all.

local Levels = {}

-- One rung per fog phase.  Phase 1 is the drop (everybody's Lv5 starter).
Levels.LADDER = { 5, 15, 30, 50, 75, 100 }

Levels.MAX = 100

function Levels.at(phase)
  local i = math.floor(tonumber(phase) or 1)
  if i < 1 then i = 1 end
  if i > #Levels.LADDER then i = #Levels.LADDER end
  return Levels.LADDER[i]
end

function Levels.rungs() return #Levels.LADDER end

-- Does this mon need pulling up to the current rung?  Deliberately one
-- directional: scaling never demotes something the player levelled past.
function Levels.needsScaling(mon, target)
  return mon ~= nil and (mon.level or 0) < (target or 0)
end

return Levels
