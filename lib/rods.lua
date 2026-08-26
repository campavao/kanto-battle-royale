-- The rod, and how it grows (POK-119).
--
-- Everyone drops with an OLD ROD and it is upgraded as the match runs, so
-- water is a place you can work rather than scenery you walk around.  Kanto
-- is full of it -- the routes south of Fuchsia are more sea than land -- and
-- without a rod all of that is a hole in the map where nothing can be
-- caught and no team can be rebuilt.
--
-- ONE CLOCK, like the levels.  The rungs are indexed by the FOG's phase
-- (lib/levels.lua makes the same argument): a ring shrink, a power spike
-- and a better rod are the same beat, so the match keeps one rhythm instead
-- of three.  Nothing here is earned or bought -- everybody's rod is the
-- same rod at the same moment, exactly like the badges and the HMs, because
-- a battle royale cannot afford a tech tree somebody wins by fishing.
--
-- Pure over plain values, so br_test checks the ladder without a bag.

local Rods = {}

-- One rod per fog rung, against Levels.LADDER's six.  Old for the opening
-- two, Good through the middle, Super for the endgame -- so the sea gets
-- better to fish exactly as the land gets smaller and more dangerous.
Rods.LADDER = {
  "OLD_ROD", "OLD_ROD", "GOOD_ROD", "GOOD_ROD", "SUPER_ROD", "SUPER_ROD",
}

-- Every rod the ladder can hand out, best last.  The grant swaps rather
-- than stacks -- three rods in the bag is three ways to do one thing, and
-- the BAG is already the busiest screen in the match.
Rods.ALL = { "OLD_ROD", "GOOD_ROD", "SUPER_ROD" }

Rods.FIRST = Rods.LADDER[1]

function Rods.at(phase)
  local i = math.floor(tonumber(phase) or 1)
  if i < 1 then i = 1 end
  if i > #Rods.LADDER then i = #Rods.LADDER end
  return Rods.LADDER[i]
end

-- Is `a` a better rod than `b`?  Answered off the ladder's order rather
-- than by name, so the ranking has exactly one definition.
function Rods.rank(id)
  for i, r in ipairs(Rods.ALL) do
    if r == id then return i end
  end
  return 0
end

function Rods.isBetter(a, b) return Rods.rank(a) > Rods.rank(b) end

-- What the player is told when the fog hands them a better rod.  Kept here
-- with the ladder so the wording and the rung cannot drift apart.
local SAID = {
  GOOD_ROD  = "Your OLD ROD was\nreplaced by a\nGOOD ROD!",
  SUPER_ROD = "Your GOOD ROD was\nreplaced by a\nSUPER ROD!",
}

function Rods.upgradeLine(id) return SAID[id] end

return Rods
