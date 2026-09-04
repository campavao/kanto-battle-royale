-- The loot piñata (DESIGN D8): a fallen trainer's team spills onto the
-- ground as Poké Balls, each holding one of their Pokémon at 1 HP.
--
-- This is the half of D8 that makes an elimination interesting to everyone
-- nearby rather than only to whoever landed the last hit: the team does not
-- vanish with its trainer, it lies there, and anybody who reaches it first
-- can pick it up.  It is also the original vision's "Pokéballs on the ground
-- that sometimes contain Pokémon", which the engine happens to have a sprite
-- for.
--
-- Placement is computed by the player being eliminated and BROADCAST, not
-- derived: a spill lands wherever they happened to fall, which no other
-- client can work out for itself.  Everyone then spawns the same balls on
-- the same cells, and the first client to engage one says so, so it
-- disappears everywhere at once.
--
-- Pure aside from mod.world (spawning), like lib/ghosts.lua -- the placement
-- search takes a walkability predicate so tests can drive it with a grid.

local Spills = {}
Spills.__index = Spills

-- A ball is a runtime object with the engine's own item-ball sprite, still,
-- exactly like the item balls Kanto is littered with.  You press A facing
-- it, which is the interaction every Gen 1 player already knows -- or
-- standing ON it (POK-175): a pile of thirty trainers' loot used to be a
-- wall, and a player who walked into a spill found every way out blocked
-- by the very things they came for.  The balls are passable now, the way
-- the ghosts are, so a spill is something you wade through and pick over.
local BALL_SPRITE = "SPRITE_POKE_BALL"

-- Drawn a pixel high.  The overworld sorts its sprites by py and breaks a
-- tie however the sort falls, so a ball on the player's own cell could
-- flicker over their sprite; one pixel up puts it under their feet every
-- frame, and nobody can see a pixel.
Spills.UNDERFOOT = 1

-- The BAG (POK-25) is the mod's own 16x16 sheet, drawn in the item ball's
-- four shades and registered by main.lua; until that has happened -- or if
-- the registry will not take it -- the POKeDEX prop stands in.
Spills.BAG_SPRITE = "SPRITE_POKEDEX"

-- how far from where they fell we will look for somewhere to put a ball
local SEARCH_RADIUS = 4

-- Cells to lay a fallen team on: rings outward from where they went down,
-- so a spill reads as a pile around the trainer rather than a scatter
-- across the route.
--
-- The ring is preferred over the cell they fell on so the pile spreads --
-- but the search is not allowed to come up short.  It used to give up
-- silently on a walled-in or map-edge cell, and "sometimes a beaten player
-- drops a ball, sometimes not" was exactly how that looked in play.
-- Whatever the ring cannot place lands on the faller's own cell, which is
-- walkable by definition (they were standing on it) and free again now
-- that a beaten trainer's sprite despawns.  Stacked balls open one at a
-- time.
function Spills.placeAround(x, y, count, walkable)
  local out, taken = {}, {}
  local function tryCell(cx, cy)
    if #out >= count then return end
    local key = cx .. ":" .. cy
    if taken[key] then return end
    if walkable and not walkable(cx, cy) then return end
    taken[key] = true
    out[#out + 1] = { x = cx, y = cy }
  end
  for r = 1, SEARCH_RADIUS do
    for dy = -r, r do
      for dx = -r, r do
        if math.abs(dx) == r or math.abs(dy) == r then tryCell(x + dx, y + dy) end
      end
    end
    if #out >= count then break end
  end
  while #out < count do out[#out + 1] = { x = x, y = y } end
  return out
end

-- The wire payload for a fallen party: one entry per Pokemon that had any
-- HP left to spill, and -- when the trainer carried anything -- their BAG
-- (POK-25): items and money as one more thing on the ground, on the very
-- cell they fell on, the balls around it.  `key` is unique across the
-- match so a client can say "this one is gone" without ambiguity.
-- `barred(x, y)` is the narrow "and not HERE, whatever else is true" rule
-- for the BAG's own cell (POK-94: a doorway).  The bag lands on the cell
-- its owner fell on rather than in the ring -- that is what makes a bag
-- read as "this is where they went down" -- so it is the one placement
-- `walkable` never got a say in.  A player cannot stand still on a warp,
-- but a BOT could walk onto one, and a bag on a mart's door shuts that
-- building for the whole match exactly as a ball would.
--
-- Deliberately NOT the full `walkable` predicate: that also refuses a cell
-- with somebody standing on it, and a bag under an NPC is a thing drivers
-- stage on purpose (POK-75).  Only the doorway rule moves the bag, and it
-- moves it to the nearest cell the balls would have accepted.
function Spills.build(ownerId, mapId, x, y, party, walkable, bag, barred)
  local alive = {}
  for _, mon in ipairs(party or {}) do
    if (mon.hp or 0) >= 0 and mon.species then alive[#alive + 1] = mon end
  end
  local out = {}
  if #alive > 0 then
    local cells = Spills.placeAround(x, y, #alive, walkable)
    for i, mon in ipairs(alive) do
      local cell = cells[i]
      if cell then
        out[#out + 1] = { key = ownerId .. ":" .. i, x = cell.x, y = cell.y,
                          species = mon.species, level = mon.level or 5 }
      end
    end
  end
  local carried
  if bag and ((bag.items and #bag.items > 0) or (bag.money or 0) > 0) then
    local bx, by = x, y
    if barred and barred(bx, by) then
      local spot = Spills.placeAround(x, y, 1, function(cx, cy)
        if barred(cx, cy) then return false end
        return not walkable or walkable(cx, cy)
      end)[1]
      -- placeAround always returns something; if its whole search was
      -- barred it hands back the aim cell, and a bag nobody can reach
      -- still beats a bag that walls a door
      if spot and not barred(spot.x, spot.y) then bx, by = spot.x, spot.y end
    end
    carried = { key = ownerId .. ":bag", x = bx, y = by, items = bag.items or {},
                money = bag.money or 0, name = bag.name }
  end
  if #out == 0 and not carried then return nil end
  return { map = mapId, mons = out, bag = carried }
end

-- ------- the live objects

function Spills.new(mod)
  return setmetatable({ mod = mod, balls = {}, spawned = {} }, Spills)
end

-- Remember a spill regardless of whether we are standing on that map; sync
-- puts the balls in the world when somebody walks in.
function Spills:add(spill)
  for _, entry in ipairs(spill.mons or {}) do
    self.balls[entry.key] = { key = entry.key, map = spill.map, x = entry.x,
                              y = entry.y, species = entry.species,
                              level = entry.level }
  end
  local bag = spill.bag
  if bag and bag.key then
    self.balls[bag.key] = { key = bag.key, map = spill.map, x = bag.x, y = bag.y,
                            bag = { items = bag.items or {}, money = bag.money or 0,
                                    name = bag.name } }
  end
end

function Spills:get(key) return self.balls[key] end

-- Whose ball this was (POK-179): the key's first segment is the owner
-- Spills.build was given -- a relay id, a bot id (Bots.ID_BASE and up),
-- "npc" for Kanto's own trainers, 999 for a driver's debugSpill.  A drop
-- key ("7:drop:2") belongs to 7 the same way.
function Spills.ownerOf(key)
  if type(key) ~= "string" then return nil end
  return key:match("^([^:]+):")
end

-- Did WE drop this?  A trade evolution rides a change of hands, and
-- releasing your own KADABRA to make room and picking it straight back
-- up is not one.  Compared as text, because relay ids are numbers and
-- keys are strings.
function Spills.isOwn(key, myId)
  local owner = Spills.ownerOf(key)
  return owner ~= nil and myId ~= nil and owner == tostring(myId)
end

-- The ball on this very cell, if any (POK-75): the talk path asks by the
-- FACED CELL when the engine's pick answered an NPC standing on a ball.
function Spills:keyAt(mapId, x, y)
  for key, ball in pairs(self.balls) do
    if ball.map == mapId and ball.x == x and ball.y == y then return key end
  end
  return nil
end

-- Every spilled cell on a map, for a bot deciding where to walk (POK-121).
-- A fallen trainer's mons and bag on the floor are the most player-like
-- errand there is: somebody else paid for them and they are free.
-- `bagsOnly` narrows it to the bags, for a bot whose party is already
-- full but whose pockets are not (POK-158).
function Spills:cellsOn(mapId, bagsOnly)
  local out = {}
  for _, ball in pairs(self.balls) do
    if ball.map == mapId and (not bagsOnly or ball.bag) then
      out[#out + 1] = { x = ball.x, y = ball.y }
    end
  end
  table.sort(out, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  return out
end

function Spills:count()
  local n = 0
  for _ in pairs(self.balls) do n = n + 1 end
  return n
end

-- Whose ball is this NPC, if any?
function Spills:keyOf(npc)
  if not npc then return nil end
  for key, id in pairs(self.spawned) do
    if id == npc.id then return key end
  end
  return nil
end

function Spills:despawn(key)
  local npcId = self.spawned[key]
  if npcId then
    pcall(function() self.mod.world:removeNpc(npcId) end)
    self.spawned[key] = nil
  end
end

-- Gone for good: taken by somebody, so it leaves the world and the table.
function Spills:take(key)
  self:despawn(key)
  self.balls[key] = nil
end

-- Part of a bag is gone (POK-176): `n` of `item` left it, and the money
-- too when `cash`.  Every client applies the same message, so the bag on
-- the ground reads the same everywhere; the piece itself goes only when
-- nothing is left in it.  Returns "gone" then, true for a lighter bag,
-- false when there was no such bag or no such item in it.
function Spills:takeItem(key, item, n, cash)
  local ball = self.balls[key]
  local bag = ball and ball.bag
  if not bag then return false end
  local hit = false
  for i, it in ipairs(bag.items or {}) do
    if it.id == item then
      hit = true
      it.n = it.n - (n or it.n)
      if it.n <= 0 then table.remove(bag.items, i) end
      break
    end
  end
  if cash then bag.money = 0 end
  if not hit and not cash then return false end
  if #(bag.items or {}) == 0 and (bag.money or 0) <= 0 then
    self:take(key)
    return "gone"
  end
  return true
end

function Spills:despawnAll()
  for key in pairs(self.spawned) do self:despawn(key) end
  self.spawned = {}
end

function Spills:clear()
  self:despawnAll()
  self.balls = {}
end

-- Put the balls for this map into the world, and take away any that belong
-- somewhere else.  Same shape as Ghosts:sync, and called from the same tick.
function Spills:sync(mapId)
  for key, npcId in pairs(self.spawned) do
    local ball = self.balls[key]
    if not ball or ball.map ~= mapId then
      pcall(function() self.mod.world:removeNpc(npcId) end)
      self.spawned[key] = nil
    end
  end
  if not mapId then return end
  self.lastSync = { mapId = mapId, balls = 0, matched = 0 }
  for key, ball in pairs(self.balls) do
    self.lastSync.balls = self.lastSync.balls + 1
    if ball.map == mapId and not self.spawned[key] then
      self.lastSync.matched = self.lastSync.matched + 1
      -- pcall'd and logged: this runs from the per-tick hook, where a raw
      -- error is swallowed by the hook wrapper and the only symptom is a
      -- ball that never appears -- which is a miserable thing to debug.
      local ok, npcId, why = pcall(function()
        return self.mod.world:spawnNpc(mapId, {
          name = "BR_SPILL_" .. key,
          sprite = ball.bag and Spills.BAG_SPRITE or BALL_SPRITE,
          x = ball.x, y = ball.y,
          movement = "STAY",
          range = "DOWN",
        })
      end)
      if ok and npcId then
        self.spawned[key] = npcId
        -- walkable (POK-175), and under the feet of whoever stands on it
        local handle = self.mod.world.npc
          and (self.mod.world:npc(mapId, npcId)) or nil
        if handle then
          if handle.setPassable then handle:setPassable(true) end
          if handle.npc and handle.npc.py then
            handle.npc.py = handle.npc.py - Spills.UNDERFOOT
          end
        end
      else
        self.failed = self.failed or {}
        if not self.failed[key] then
          self.failed[key] = tostring(ok and why or npcId)
          if self.mod.log then
            self.mod.log:warn("couldn't place a spilled ball (%s) at %s %d,%d: %s",
              BALL_SPRITE, tostring(mapId), ball.x, ball.y, self.failed[key])
          end
        end
      end
    end
  end
end

return Spills
