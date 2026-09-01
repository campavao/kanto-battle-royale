-- Where everyone drops: a random walkable cell on a random outdoor map.
--
-- Pure: takes map and tileset definitions plus an rng, returns cells.  The
-- host runs this once at match start and sends the result in the `start`
-- message, so nobody else has to agree on the algorithm -- only on the
-- answer.
--
-- "Outdoor" is the engine's own test (Map.isOutdoor: the OVERWORLD
-- tileset), which is the eleven towns and the numbered routes -- Kanto
-- proper, no caves, no buildings, no Indigo Plateau.  Walkability is the
-- engine's too (Map.defIsWalkableCell), so nobody spawns in a wall or on
-- water; cells under a warp or an object are skipped so nobody spawns in a
-- doorway or inside an NPC.

local Map = require("src.world.Map")

local Spawn = {}

-- Deterministic Park-Miller PRNG so a seed reproduces a drop in tests.
-- rng(a, b) -> integer in [a, b]; rng() -> [0, 1).
function Spawn.rng(seed)
  local s = tonumber(seed) or 1
  if s ~= s or s == math.huge or s == -math.huge then s = 1 end
  s = math.floor(s) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(a, b)
    s = (s * 16807) % 2147483647
    if a == nil then return s / 2147483647 end
    if b == nil then a, b = 1, a end
    return a + (s % (b - a + 1))
  end
end

-- The outdoor maps, sorted so the order never depends on pairs().
function Spawn.outdoorMaps(maps)
  local ids = {}
  for id, def in pairs(maps or {}) do
    if type(def) == "table" and def.width and def.height and def.blocks
       and Map.isOutdoor(def) then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

local function blocked(def)
  local set = {}
  for _, w in ipairs(def.warps or {}) do set[w.y * 4096 + w.x] = true end
  for _, o in ipairs(def.objects or {}) do set[o.y * 4096 + o.x] = true end
  return set
end

-- Is this cell a warp -- a door, a cave mouth, a stairwell?
--
-- Walkability says nothing about it: a doorway is a perfectly walkable
-- tile, which is the whole point of it.  But it is walkable in order to be
-- STEPPED ON, and anything solid parked there closes the building for good
-- (POK-94: a spilled Poke Ball sat on the VIRIDIAN mart's door and nobody
-- could get in for the rest of the match).  Answered off the map
-- DEFINITION so it works for a map nobody is standing on, the same as
-- Spawn.walkable.
function Spawn.isWarp(maps, mapId, x, y)
  local def = maps and maps[mapId]
  if not def then return false end
  for _, w in ipairs(def.warps or {}) do
    if w.x == x and w.y == y then return true end
  end
  return false
end

-- Can an actor stand on this cell?  Answered off the map DEFINITION, not a
-- loaded map, so the host can walk a bot around a map nobody is standing on.
function Spawn.walkable(maps, tilesets, mapId, x, y)
  local def = maps and maps[mapId]
  local tilesetDef = def and tilesets and tilesets[def.tileset]
  if not (def and tilesetDef) then return false end
  if x < 0 or y < 0 or x >= def.width * 2 or y >= def.height * 2 then return false end
  return Map.defIsWalkableCell(def, tilesetDef, x, y)
     and not Map.defIsWaterCell(def, tilesetDef, x, y)
end

-- Can a SURFING actor stand on this cell (POK-158 M4)?  Water tiles are
-- NOT in the tileset's walkable list -- the engine's surf logic is what
-- lets a player onto them -- so this is simply the in-bounds water test,
-- the same `defIsWaterCell` trySurf asks before mounting.
function Spawn.swimmable(maps, tilesets, mapId, x, y)
  local def = maps and maps[mapId]
  local tilesetDef = def and tilesets and tilesets[def.tileset]
  if not (def and tilesetDef) then return false end
  if x < 0 or y < 0 or x >= def.width * 2 or y >= def.height * 2 then return false end
  return Map.defIsWaterCell(def, tilesetDef, x, y)
end

-- Walkable is not escapable (POK-23).  An island behind Surf water, a
-- Cut-fenced pocket and a ledge-locked hollow all pass the walkable test,
-- and all of them strand a Lv5 drop with no way off the map.  One
-- multi-source flood per map answers "can this cell reach a way out?"
-- for every cell at once.
--
-- The flood itself, pure over a predicate: w x h cells, isWalkable(x, y),
-- seeds an array of { x=, y= }.  Returns a set keyed y * 4096 + x holding
-- every walkable cell connected to a seed.
function Spawn.floodEscapable(w, h, isWalkable, seeds)
  local seen, queue = {}, {}
  local function push(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return end
    local k = y * 4096 + x
    if seen[k] or not isWalkable(x, y) then return end
    seen[k] = true
    queue[#queue + 1] = { x = x, y = y }
  end
  for _, sd in ipairs(seeds or {}) do push(sd.x, sd.y) end
  local i = 1
  while queue[i] do
    local c = queue[i]
    i = i + 1
    push(c.x + 1, c.y)
    push(c.x - 1, c.y)
    push(c.x, c.y + 1)
    push(c.x, c.y - 1)
  end
  return seen
end

-- One map's escapable region: seeded beside every warp (stepping onto the
-- warp is the way out) and along the walkable edge of every side with a
-- connection.  A ledge-hop-only hollow never joins the region -- ledge
-- tiles are not walkable, so nothing floods across them.
--
-- An edge cell is only a seed if a step off it actually CROSSES.  The
-- engine's rule (OverworldState:connectionLanding): the landing cell on
-- the neighbour is our coordinate shifted by the connection's offset,
-- CLAMPED into the neighbour's bounds, and the step happens only when
-- that cell is passable.  Seeding the whole edge instead called Pewter's
-- fenced south-east corner escapable -- it touches the south edge, but
-- ROUTE_2 is half Pewter's width and every landing from that stretch
-- clamps onto a tree, so a player dropped there could not leave at all.
-- `maps`/`tilesets` may be nil (a caller without the world in hand), and
-- the edge then keeps the old benefit of the doubt.
--
-- This per-map answer is the fallback for maps OUTSIDE the outdoor world
-- (the Safari opening) and for callers without the world in hand; outdoor
-- spawns use Spawn.escapableSets below, which floods all of Kanto at once
-- and cannot be fooled by two sealed pockets vouching for each other
-- across a seam.
function Spawn.escapableSet(def, tilesetDef, maps, tilesets)
  if not (def and tilesetDef) then return {} end
  local w, h = def.width * 2, def.height * 2
  local function walk(x, y)
    return Map.defIsWalkableCell(def, tilesetDef, x, y)
       and not Map.defIsWaterCell(def, tilesetDef, x, y)
  end
  local seeds = {}
  for _, wp in ipairs(def.warps or {}) do
    seeds[#seeds + 1] = { x = wp.x + 1, y = wp.y }
    seeds[#seeds + 1] = { x = wp.x - 1, y = wp.y }
    seeds[#seeds + 1] = { x = wp.x, y = wp.y + 1 }
    seeds[#seeds + 1] = { x = wp.x, y = wp.y - 1 }
  end
  -- does a step off the edge at this coordinate land on a passable cell?
  -- lx/ly may be huge: the clamp is the engine's own.
  local function landOk(conn, lx, ly)
    local dest = maps and maps[conn.map]
    local ts = dest and tilesets and tilesets[dest.tileset]
    if not (dest and ts) then return true end
    local dw, dh = dest.width * 2, dest.height * 2
    lx = math.max(0, math.min(dw - 1, lx))
    ly = math.max(0, math.min(dh - 1, ly))
    return Map.defIsWalkableCell(dest, ts, lx, ly)
       and not Map.defIsWaterCell(dest, ts, lx, ly)
  end
  local conns = def.connections or {}
  if conns.north then
    local off = (tonumber(conns.north.offset) or 0) * 2
    for x = 0, w - 1 do
      if landOk(conns.north, x - off, math.huge) then
        seeds[#seeds + 1] = { x = x, y = 0 }
      end
    end
  end
  if conns.south then
    local off = (tonumber(conns.south.offset) or 0) * 2
    for x = 0, w - 1 do
      if landOk(conns.south, x - off, 0) then
        seeds[#seeds + 1] = { x = x, y = h - 1 }
      end
    end
  end
  if conns.west then
    local off = (tonumber(conns.west.offset) or 0) * 2
    for y = 0, h - 1 do
      if landOk(conns.west, math.huge, y - off) then
        seeds[#seeds + 1] = { x = 0, y = y }
      end
    end
  end
  if conns.east then
    local off = (tonumber(conns.east.offset) or 0) * 2
    for y = 0, h - 1 do
      if landOk(conns.east, 0, y - off) then
        seeds[#seeds + 1] = { x = w - 1, y = y }
      end
    end
  end
  return Spawn.floodEscapable(w, h, walk, seeds)
end

-- The whole outdoor world's escapable regions in ONE flood.
--
-- The per-map flood lies at the seams: Vermilion's fenced sign pocket
-- (cells 24..39 x 0..2) exits only north onto ROUTE_6's own walled-off
-- corner (11..19 x 33..35), whose only exit is back south into the
-- Vermilion pocket.  Each map's edge check vouched for the other, so both
-- kept their spawn cells -- and a player dropped there sat softlocked
-- behind the town sign.  Escape means reaching a DOOR somewhere in Kanto,
-- so seed beside every warp on every outdoor map and flood across seam
-- crossings validated the way crossConnection validates them.
--
-- A region ABOVE a ledge escapes by hopping down it, so `ledges`
-- (data.field.ledges: standing tile + ledge tile + direction, the rows
-- checkLedgeHop matches) feeds one-way edges INTO the flood: when a cell
-- is escapable, the cell two up the hop is too.  Without the rows the
-- flood is merely conservative -- a plateau loses its spawn cells, nobody
-- gets stranded.  (A hop whose landing is on the CONNECTED map -- Route
-- 4's plaza onto Route 3 -- is not modelled; those plazas all hold a door
-- and are seeded anyway.)
--
-- Returns { [mapId] = set keyed y * 4096 + x } for every outdoor map.
-- Pure over the data; cached per maps table.
local LEDGE_VEC = { up = { 0, -1 }, down = { 0, 1 },
                    left = { -1, 0 }, right = { 1, 0 } }
local worldCache = setmetatable({}, { __mode = "k" })
function Spawn.escapableSets(maps, tilesets, ledges)
  local hit = worldCache[maps]
  if hit and hit.ledges == (ledges or false) then return hit.sets end

  local sets, defs, tsOf = {}, {}, {}
  for _, id in ipairs(Spawn.outdoorMaps(maps)) do
    local def = maps[id]
    local ts = tilesets and tilesets[def.tileset]
    if ts then
      sets[id], defs[id], tsOf[id] = {}, def, ts
    end
  end

  local function walk(id, x, y)
    local def = defs[id]
    if not def then return false end
    if x < 0 or y < 0 or x >= def.width * 2 or y >= def.height * 2 then
      return false
    end
    return Map.defIsWalkableCell(def, tsOf[id], x, y)
       and not Map.defIsWaterCell(def, tsOf[id], x, y)
  end

  local queue, qi = {}, 1
  local function push(id, x, y)
    local set = sets[id]
    if not set then return end
    local k = y * 4096 + x
    if set[k] or not walk(id, x, y) then return end
    set[k] = true
    queue[#queue + 1] = { id = id, x = x, y = y }
  end

  for id, def in pairs(defs) do
    for _, wp in ipairs(def.warps or {}) do
      push(id, wp.x + 1, wp.y)
      push(id, wp.x - 1, wp.y)
      push(id, wp.x, wp.y + 1)
      push(id, wp.x, wp.y - 1)
    end
  end

  while queue[qi] do
    local c = queue[qi]
    qi = qi + 1
    local def = defs[c.id]
    local w, h = def.width * 2, def.height * 2
    push(c.id, c.x + 1, c.y)
    push(c.id, c.x - 1, c.y)
    push(c.id, c.x, c.y + 1)
    push(c.id, c.x, c.y - 1)
    -- up the ledges: any cell whose hop lands here escapes through here
    for _, ledge in ipairs(ledges or {}) do
      local v = LEDGE_VEC[ledge.facing]
      if v and ledge.input == ledge.facing
         and (ledge.tileset or "OVERWORLD") == def.tileset then
        local mx, my = c.x - v[1], c.y - v[2]
        local sx, sy = c.x - 2 * v[1], c.y - 2 * v[2]
        if Map.defCellTile(def, tsOf[c.id], mx, my) == ledge.ledgeTile
           and Map.defCellTile(def, tsOf[c.id], sx, sy) == ledge.standingTile then
          push(c.id, sx, sy)
        end
      end
    end
    -- across the seams: landing math mirrors connectionLanding
    -- (destX = curX - offset*2), minus the clamp -- a landing outside the
    -- neighbour's bounds is a bump, not an exit
    local conns = def.connections or {}
    local function cross(conn, dx, dy)
      if conn and walk(conn.map, dx, dy) then push(conn.map, dx, dy) end
    end
    if c.y == 0 and conns.north then
      local d = defs[conns.north.map]
      if d then cross(conns.north, c.x - conns.north.offset * 2, d.height * 2 - 1) end
    end
    if c.y == h - 1 and conns.south then
      cross(conns.south, c.x - conns.south.offset * 2, 0)
    end
    if c.x == 0 and conns.west then
      local d = defs[conns.west.map]
      if d then cross(conns.west, d.width * 2 - 1, c.y - conns.west.offset * 2) end
    end
    if c.x == w - 1 and conns.east then
      cross(conns.east, 0, c.y - conns.east.offset * 2)
    end
  end

  worldCache[maps] = { sets = sets, ledges = ledges or false }
  return sets
end

-- Every cell a player could be dropped on for one map, in row-major order
-- -- walkable, unoccupied, and with a way off the map (POK-23).  With the
-- world's `maps`/`tilesets` in hand an OUTDOOR map's "way off" is answered
-- by the world flood above; anything else (the Safari opening, unit tests
-- over toy defs) falls back to the per-map flood.
function Spawn.cellsOf(def, tilesetDef, maps, tilesets, ledges)
  local out = {}
  if not (def and tilesetDef) then return out end
  local skip = blocked(def)
  local escape
  if maps and tilesets then
    for id, d in pairs(maps) do
      if d == def then
        escape = Spawn.escapableSets(maps, tilesets, ledges)[id]
        break
      end
    end
  end
  escape = escape or Spawn.escapableSet(def, tilesetDef, maps, tilesets)
  local w, h = def.width * 2, def.height * 2
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      if not skip[cy * 4096 + cx]
         and escape[cy * 4096 + cx]
         and Map.defIsWalkableCell(def, tilesetDef, cx, cy)
         and not Map.defIsWaterCell(def, tilesetDef, cx, cy) then
        out[#out + 1] = { x = cx, y = cy }
      end
    end
  end
  return out
end

-- n drop points on ONE map: the Safari opening puts everyone in the centre
-- together (POK-21), and the drop after it lands each player on a random
-- cell of the town they chose (POK-22).  Cells are dealt off a shuffled
-- deck, so nobody shares one until the map is full -- and then they do,
-- rather than a crowded room failing to drop.
--
-- Returns an array of { map=, x=, y= } of length n, or nil + reason.
function Spawn.pickIn(maps, tilesets, mapId, n, rng, ledges)
  rng = rng or Spawn.rng(os.time())
  local def = maps and maps[mapId]
  local cells = Spawn.cellsOf(def, def and tilesets and tilesets[def.tileset],
                              maps, tilesets, ledges)
  if #cells == 0 then return nil, "no free cells on " .. tostring(mapId) end
  for i = #cells, 2, -1 do
    local j = rng(1, i)
    cells[i], cells[j] = cells[j], cells[i]
  end
  local out = {}
  for i = 1, n do
    local c = cells[(i - 1) % #cells + 1]
    out[i] = { map = mapId, x = c.x, y = c.y }
  end
  return out
end

-- n drop points for n players: maps are dealt round-robin off a shuffled
-- deck so two players only share a map once every map has someone on it,
-- and no two players ever share a cell.
--
-- Returns an array of { map=, x=, y= } of length n, or nil + reason when the
-- data has nowhere to drop anyone.
function Spawn.pick(maps, tilesets, n, rng, ledges)
  rng = rng or Spawn.rng(os.time())
  local ids = Spawn.outdoorMaps(maps)
  if #ids == 0 then return nil, "no outdoor maps" end

  -- Fisher-Yates on the deck
  for i = #ids, 2, -1 do
    local j = rng(1, i)
    ids[i], ids[j] = ids[j], ids[i]
  end

  local cellCache = {}
  local function cells(id)
    if not cellCache[id] then
      local def = maps[id]
      cellCache[id] = Spawn.cellsOf(def, tilesets and tilesets[def.tileset],
                                    maps, tilesets, ledges)
    end
    return cellCache[id]
  end

  local taken = {}
  local out = {}
  local deck = 1
  local attempts = 0
  while #out < n do
    attempts = attempts + 1
    if attempts > n * 64 then return nil, "couldn't find enough free cells" end
    local id = ids[(deck - 1) % #ids + 1]
    deck = deck + 1
    local list = cells(id)
    if #list > 0 then
      local c = list[rng(1, #list)]
      local key = id .. ":" .. c.x .. ":" .. c.y
      if not taken[key] then
        taken[key] = true
        out[#out + 1] = { map = id, x = c.x, y = c.y }
      end
    end
  end
  return out
end

return Spawn
