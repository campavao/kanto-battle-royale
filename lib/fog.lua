-- The Weezing fog: a shrinking ring over Kanto, on the shared match clock.
--
-- Pure geometry and scheduling -- no love.*, no socket, no engine module --
-- so all of it is exercised headless by tests/br_test.lua.
--
-- WHAT THE RING IS DRAWN ON.  Kanto here is not one big canvas the way
-- Hoenn was in the sibling project: it is 222 separate maps stitched by
-- warps, with no global coordinate space to put a circle in.  But the game
-- already ships Kanto's real geography -- `field.townMap.locations` gives
-- every map a cell on the 16x16 Town Map grid, interiors included (a
-- building sits on its town's square).  So the ring is a circle in TOWN MAP
-- space and a map is safe when its square is inside it.  That means the fog
-- follows the Kanto you know: it closes on a named place, the routes around
-- it go first, and hiding in a building does not help because the building
-- is on the same square as the town it is in.
--
-- The schedule is a list of radii.  Phase 1 covers everything (the grace
-- period while people catch a team) and each later phase is tighter, so the
-- last one is a couple of squares around the centre -- the climactic arena
-- DESIGN D11 asks for.

local Fog = {}

-- Radii in town-map squares.  15 is larger than the grid's diagonal, so
-- phase 1 is "no fog anywhere" without needing a special case.
Fog.PHASES = { 15, 9, 7, 5, 3, 1.5 }

-- How long each phase lasts before the next shrink, in seconds.  A default
-- match is therefore about ten minutes; the mod exposes it as an option so
-- a short game (or a test) can turn it right down.
Fog.DEFAULT_PHASE_SECONDS = 120

-- Fog damage, taken by every party member this often while you are outside
-- the ring.  Gen 1's overworld poison is a flat 1 HP per 4 steps, and that
-- is the obvious thing to copy -- but it does not survive level scaling
-- (DESIGN D12).  A level 5 starter has about 20 HP and a level 100 team has
-- three hundred, so a flat point would kill you in a careless minute at the
-- drop and take twenty patient minutes in the final ring, which is exactly
-- backwards: the fog has to bite hardest when the ring is smallest.
--
-- So it is a FRACTION of each Pokemon's maximum -- a tenth per tick, which
-- is ten ticks or about forty seconds from full health to fainted, the same
-- at level 5 and at level 100.  Long enough to cross a corner of the map on
-- purpose, far too short to wait out.
Fog.TICK_SECONDS = 4
Fog.DAMAGE_FRACTION = 0.10
Fog.TICKS_TO_KILL = math.ceil(1 / Fog.DAMAGE_FRACTION)

-- What one tick takes off a Pokemon with this much maximum HP.  Always at
-- least a point, so a very small mon still dies rather than idling forever
-- on a rounded-down zero.
function Fog.bite(maxHp)
  return math.max(1, math.floor((tonumber(maxHp) or 0) * Fog.DAMAGE_FRACTION))
end

function Fog.phaseCount() return #Fog.PHASES end

function Fog.radius(phase)
  return Fog.PHASES[math.max(1, math.min(#Fog.PHASES, math.floor(phase or 1)))]
end

function Fog.isFinalPhase(phase) return (phase or 1) >= #Fog.PHASES end

-- Which phase a match of this age is in (1-based).
function Fog.phaseAt(elapsedSeconds, phaseSeconds)
  phaseSeconds = phaseSeconds or Fog.DEFAULT_PHASE_SECONDS
  if phaseSeconds <= 0 then return #Fog.PHASES end
  local phase = math.floor((elapsedSeconds or 0) / phaseSeconds) + 1
  return math.max(1, math.min(#Fog.PHASES, phase))
end

-- Where the ring closes.  Chosen from the places worth naming -- the towns
-- and cities -- so the announcement is somewhere a player can picture
-- ("THE FOG CLOSES ON CELADON CITY") rather than a route number.  Derived
-- from the match seed, so every client agrees without being told.
--
-- `towns` is a list of { id, x, y, name }.
function Fog.center(seed, towns)
  if not towns or #towns == 0 then return nil end
  local ordered = {}
  for i, t in ipairs(towns) do ordered[i] = t end
  table.sort(ordered, function(a, b) return a.id < b.id end)
  -- one draw off the seed, the same everywhere
  local s = math.floor(tonumber(seed) or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  s = (s * 16807) % 2147483647
  return ordered[s % #ordered + 1]
end

-- Is this map inside the ring?  A map with no town-map square is treated as
-- safe: that only happens for content this build does not place on the map,
-- and killing a player for standing somewhere the fog cannot describe would
-- be the wrong way to resolve it.
function Fog.isSafe(locations, mapId, center, radius)
  if not (locations and center) then return true end
  local loc = locations[mapId]
  if not loc then return true end
  local dx, dy = loc.x - center.x, loc.y - center.y
  return (dx * dx + dy * dy) <= (radius * radius)
end

-- Distance from the ring's edge in squares: negative inside, positive out.
-- Used to warn a player who is close to the edge.
function Fog.distanceOutside(locations, mapId, center, radius)
  if not (locations and center) then return -math.huge end
  local loc = locations[mapId]
  if not loc then return -math.huge end
  local dx, dy = loc.x - center.x, loc.y - center.y
  return math.sqrt(dx * dx + dy * dy) - radius
end

-- Every outdoor map still inside the ring, sorted, for relocating anyone
-- the fog would otherwise strand (bots).  Falls back to the centre's own
-- map so the list is never empty.
function Fog.safeMaps(locations, outdoorIds, center, radius)
  local out = {}
  for _, id in ipairs(outdoorIds or {}) do
    if Fog.isSafe(locations, id, center, radius) then out[#out + 1] = id end
  end
  table.sort(out)
  if #out == 0 and center and center.id then out[1] = center.id end
  return out
end

-- Is this Pokemon a Poison type?  A poison lead walks the fog unharmed --
-- the fog is its element (DESIGN D11 / O5), and it gives an otherwise
-- unloved type a real reason to be in your party.
function Fog.immune(mon, data)
  if not (mon and data and data.pokemon) then return false end
  local def = data.pokemon[mon.species]
  for _, t in ipairs((def and def.types) or {}) do
    if t == "POISON" then return true end
  end
  return false
end

return Fog
