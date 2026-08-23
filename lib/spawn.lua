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

-- Every cell a player could be dropped on for one map, in row-major order.
function Spawn.cellsOf(def, tilesetDef)
  local out = {}
  if not (def and tilesetDef) then return out end
  local skip = blocked(def)
  local w, h = def.width * 2, def.height * 2
  for cy = 0, h - 1 do
    for cx = 0, w - 1 do
      if not skip[cy * 4096 + cx]
         and Map.defIsWalkableCell(def, tilesetDef, cx, cy)
         and not Map.defIsWaterCell(def, tilesetDef, cx, cy) then
        out[#out + 1] = { x = cx, y = cy }
      end
    end
  end
  return out
end

-- n drop points for n players: maps are dealt round-robin off a shuffled
-- deck so two players only share a map once every map has someone on it,
-- and no two players ever share a cell.
--
-- Returns an array of { map=, x=, y= } of length n, or nil + reason when the
-- data has nowhere to drop anyone.
function Spawn.pick(maps, tilesets, n, rng)
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
      cellCache[id] = Spawn.cellsOf(def, tilesets and tilesets[def.tileset])
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
