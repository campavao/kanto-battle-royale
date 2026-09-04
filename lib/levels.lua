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

-- Carry damage across a stat recalc as an absolute amount -- a Gen 1
-- level-up heals nothing.  Fainted is a state, not an amount: 0 HP rides
-- through every rung as 0 HP, never revived by the clock (POK-38).
function Levels.carryHp(oldMax, oldHp, newMax)
  newMax = tonumber(newMax) or 0
  oldMax = tonumber(oldMax) or 0
  local hp = tonumber(oldHp) or 0
  if oldMax <= 0 then return newMax end -- no old stats: arrive whole
  if hp <= 0 then return 0 end          -- fainted stays fainted
  return math.max(1, newMax - math.max(0, oldMax - hp))
end

-- The level-up moves between two rungs, learned the way a trainer would
-- want them learned (POK-172).  Pokemon.learnMovesFromDayCare drops the
-- OLDEST slot for every new move, which on an automatic level-up threw
-- away moves the trainer had spent a TM on -- the whole reason a TM is
-- loot (POK-62).  Provenance is inferred rather than bookkept: a move the
-- species learns by level at or below the level it HAD is a level-up
-- move; anything else was taught (a TM, an HM, a pre-evolution's
-- learnset) and is never displaced.  An empty slot is filled first; then
-- the oldest level-up move gives way; if every slot is taught, the rung's
-- move is skipped.  A move learned this rung counts as level-up for the
-- next.  Returns the ids learned and the ids forgotten, in order.
function Levels.learn(data, mon, def, from, to)
  local learned, forgot = {}, {}
  if not (def and def.learnset and mon) then return learned, forgot end
  mon.moves = mon.moves or {}
  local natural = {}
  -- the level-1 moves live beside the learnset, not in it (Pokemon.movesAtLevel)
  for _, m in ipairs(def.level1Moves or {}) do natural[m] = true end
  for _, e in ipairs(def.learnset) do
    if e.level <= from then natural[e.move] = true end
  end
  for _, e in ipairs(def.learnset) do
    if e.level > to then break end
    if e.level > from then
      local known = false
      for _, mv in ipairs(mon.moves) do
        if mv.id == e.move then known = true break end
      end
      if not known then
        local mdef = data and data.moves and data.moves[e.move]
        local slot = { id = e.move, pp = mdef and mdef.pp or 0 }
        if #mon.moves < 4 then
          mon.moves[#mon.moves + 1] = slot
          learned[#learned + 1] = e.move
        else
          local victim
          for i, mv in ipairs(mon.moves) do
            if natural[mv.id] then victim = i break end
          end
          if victim then
            forgot[#forgot + 1] = mon.moves[victim].id
            table.remove(mon.moves, victim)
            mon.moves[#mon.moves + 1] = slot
            learned[#learned + 1] = e.move
          end
        end
      end
      natural[e.move] = true
    end
  end
  return learned, forgot
end

return Levels
