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
-- period while people catch a team) and each later phase is tighter: a
-- couple of squares around the centre is the climactic arena DESIGN D11
-- asks for, then the town alone, then nothing at all.
--
-- THE RING NEVER STOPS.  It used to clamp at the arena, and a match with
-- survivors who would not fight each other (four of them, at level 100,
-- standing in Celadon) simply never ended.  So the last phase is fog over
-- the whole map.  The endgame in that case is who lasts longest inside it --
-- about forty seconds from full health, longer for whoever kept their
-- Potions -- and it is expected to be rare, because players in one town
-- usually finish each other off first.  What matters is that it is a
-- guarantee: a match ends.

local Fog = {}

-- Radii in town-map squares.  Phase 1 is "no fog anywhere" -- expressed as
-- a radius wider than the board rather than as a special case, so isSafe
-- stays one comparison.  0 is the centre's own square only (the town and
-- its buildings).  A negative radius is EVERYWHERE: no square is inside it,
-- whatever the distance.
Fog.EVERYWHERE = -1
-- The board is field.townMap's 16x16 grid, so squares run 0..15 and the
-- longest line across it is sqrt(15^2 + 15^2) = 21.22.  This used to be 15,
-- described in this very comment as "larger than the grid's diagonal" --
-- which is the width of the grid, not its diagonal.  The gap was real
-- geography: LAVENDER_TOWN (14,5) is 15.62 squares from CINNABAR_ISLAND
-- (2,15), so a match whose eye landed on Cinnabar put anyone dropping into
-- Lavender in the fog on the frame they touched the ground, with no grace
-- period at all (POK-93).  NOWHERE clears the true diagonal with room to
-- spare, and br_test proves it against the real location table rather than
-- against arithmetic in a comment.
Fog.NOWHERE = 24
Fog.PHASES = { Fog.NOWHERE, 9, 7, 5, 3, 1.5, 0, Fog.EVERYWHERE }

-- How long each phase lasts before the next shrink, in seconds.  A default
-- match therefore reaches the all-fog endgame at about sixteen minutes; the
-- mod exposes it as an option so a short game (or a test) can turn it right
-- down.
Fog.DEFAULT_PHASE_SECONDS = 240

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

-- Has the ring closed completely -- is there nowhere left to stand?
function Fog.coversAll(radius) return (tonumber(radius) or 0) < 0 end

-- Is there fog ANYWHERE on the board?  Phase 1's radius is NOWHERE, which
-- clears the grid's true diagonal, so every square is inside it and nothing
-- is fogged: the grace period is the one stretch of a match with no fog in
-- it at all.  Every later phase has some.  Expressed against the radius
-- rather than the phase number so it reads the same value isSafe does --
-- a schedule edit cannot leave the two disagreeing.
function Fog.isUp(radius)
  local r = tonumber(radius)
  return r ~= nil and r < Fog.NOWHERE
end

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
-- be the wrong way to resolve it.  Until the fog covers everything, that is
-- -- the final phase has no inside, and a map the grid cannot place is not
-- a loophole in it.
function Fog.isSafe(locations, mapId, center, radius)
  if Fog.coversAll(radius) then return false end
  if not (locations and center) then return true end
  local loc = locations[mapId]
  if not loc then return true end
  local dx, dy = loc.x - center.x, loc.y - center.y
  return (dx * dx + dy * dy) <= (radius * radius)
end

-- Which map the ring should be asked about, for somebody who may be
-- standing INDOORS (POK-140).
--
-- isSafe answers against the town-map grid, and an interior has no square
-- on it -- `locations[mapId]` is nil and the honest answer for an
-- unplaceable map is "safe".  That is right for the fog itself (a building
-- is not a square the ring can close on) and wrong for anything asking
-- "which town am I in", which is what a POKeMON CENTER's counter needs.
--
-- The engine already keeps the answer: save.lastOutdoor is pokered's
-- wLastMap, written by OverworldState:rememberOutdoor whenever the player
-- warps OFF an outdoor map -- so walking into VIRIDIAN's CENTER leaves it
-- pointing at VIRIDIAN_CITY.
--
-- nil when there is nothing to go on, and every caller must read that as
-- "cannot say" rather than "in the fog": a counter that refuses for a
-- reason nobody can see is worse than one that serves when it should not.
function Fog.outdoorFor(locations, mapId, lastOutdoorId)
  if locations and mapId and locations[mapId] then return mapId end
  return lastOutdoorId
end

-- Distance from the ring's edge in squares: negative inside, positive out.
-- Used to warn a player who is close to the edge.
function Fog.distanceOutside(locations, mapId, center, radius)
  if Fog.coversAll(radius) then return math.huge end
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

-- One shared clock per map the ring has left (POK-35).  `state` persists
-- between calls (mapId -> {ticks, last, dead}); `mapIds` is the list worth
-- watching (maps that hold trainers).  A map outside the ring counts the
-- same TICK_SECONDS beats a player does and dies at TICKS_TO_KILL -- the
-- same grace, so a trainer just past the edge is not vaporised the moment
-- the ring moves.  Returns the maps whose clock ran out on THIS call.  A
-- map the ring re-admits before the end is reprieved (the centre can move
-- between phases); the dead stay dead.
function Fog.tickMaps(state, mapIds, locations, center, radius, now)
  local died = {}
  if not (state and now) then return died end
  for _, id in ipairs(mapIds or {}) do
    local st = state[id]
    if not (st and st.dead) then
      if Fog.isSafe(locations, id, center, radius) then
        if st then state[id] = nil end
      elseif not st then
        state[id] = { ticks = 0, last = now }
      elseif (now - (st.last or 0)) >= Fog.TICK_SECONDS then
        st.last = now
        st.ticks = st.ticks + 1
        if st.ticks >= Fog.TICKS_TO_KILL then
          st.dead = true
          died[#died + 1] = id
        end
      end
    end
  end
  return died
end

-- Is this Pokemon a Poison type?
--
-- NOT USED right now, and deliberately kept.  A Poison lead used to walk the
-- fog unharmed (DESIGN D11), which read well and played badly: Kanto is full
-- of Zubat, Nidoran, Koffing and Grimer, so the common case was a lead that
-- ignored the ring for a whole match -- and once the fog stops clamping and
-- covers everything, an immune lead wins by standing still.  Immunity is off
-- until lead-type abilities get a proper design pass, and this stays as the
-- thing that pass starts from rather than something to write again.
--
-- A poison lead walks the fog unharmed --
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

-- ------- the town map overlay's geometry (POK-146)
--
-- The ring lives on the LOCATION grid (16x16 nybbles), but the town map
-- ART places that grid 2 tiles in and 1 tile down on its 20x18 screen --
-- pokered's TownMapCoordsToOAMCoords, mirrored by TownMap's markerXY
-- (`loc.x * 8 + 16, loc.y * 8 + 8`).  The overlay walks SCREEN tiles, so
-- it has to undo that offset before comparing against the ring's centre;
-- subtracting raw screen coordinates shifted the whole safe region two
-- tiles left and one up -- the fog announced PEWTER CITY and the bright
-- square sat over INDIGO PLATEAU, which is exactly the town that lives
-- at Pewter's unshifted coordinates.
Fog.MAP_OX, Fog.MAP_OY = 2, 1

-- is the fog over this SCREEN tile of the town map?
function Fog.shadesTile(center, radius, gx, gy)
  if Fog.coversAll(radius) then return true end
  local dx = (gx - Fog.MAP_OX) - center.x
  local dy = (gy - Fog.MAP_OY) - center.y
  return (dx * dx + dy * dy) > (radius * radius)
end

return Fog
