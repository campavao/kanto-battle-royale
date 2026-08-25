-- The other trainers, as things Kanto can actually contain.
--
-- Each remote player is a runtime object (mod.world:spawnNpc) we drive
-- ourselves.  Making them real NPCs rather than sprites we blit is what
-- buys the feature for free: the tile renderer sorts them against the map,
-- Collision treats them as solid so you cannot walk through someone, and
-- OverworldState:interact finds them when you press A.
--
-- What we do NOT use is Handle:scriptMove -- that queues onto
-- OverworldState.scriptMoves, which the overworld reads as "a cutscene is
-- running" and would freeze your controls for 16 frames per remote step.
-- Handle:stepNow drives the same per-tile state without the queue.
--
-- Replay, not simulation: each peer decided (and collision-checked) its own
-- steps.  We repeat them verbatim and let the cell coordinates in the
-- message correct any drift.
--
-- This is coop/lib/ghosts.lua generalised from one peer to a table keyed by
-- room id, because a battle royale room has many.  An eliminated trainer's
-- ghost despawns entirely: what stays behind is their Poke Balls, and balls
-- with no trainer is how you read that somebody else got there first --
-- the world is a record of the match, not a field of corpses.

local Ghosts = {}
Ghosts.__index = Ghosts

-- Un-replayed steps we will walk out before snapping.  Each costs 16 frames;
-- past this a backlog would put the ghost visibly behind the truth, so we
-- teleport instead of politely queueing.
local MAX_BACKLOG = 3
-- how long a LONE queued step is held before it plays (POK-70): a steady
-- walk arrives one step per step-time, so draining the instant each lands
-- plays as walk-stop-walk-stop -- the stutter a spectator sees.  Holding
-- the first step a beat lets the next one arrive, and a continuous walk
-- then plays continuously, one step behind the wire.
Ghosts.HOLD_TICKS = 12

local FACING_TO_RANGE = { down = "DOWN", up = "UP", left = "LEFT", right = "RIGHT" }
local DEFAULT_SPRITE = "SPRITE_RED"

function Ghosts.new(mod)
  return setmetatable({
    mod = mod,
    ghosts = {},   -- id -> { npcId, mapId, queue, sprite, name }
  }, Ghosts)
end

-- The sprite sheet the peer advertised, if this build actually has it; an
-- unrecognised id must not crash NPC.new (which asserts on an unknown
-- sheet), so it falls back.
function Ghosts:resolveSprite(game, wanted)
  local sprites = game and game.data and game.data.sprites
  if not sprites then return DEFAULT_SPRITE end
  if wanted and sprites[wanted] then return wanted end
  local field = game.data.field
  local walk = field and field.playerSprites and field.playerSprites.walk
  if walk and sprites[walk] then return walk end
  if sprites[DEFAULT_SPRITE] then return DEFAULT_SPRITE end
  return next(sprites)
end

function Ghosts:_handle(g)
  if not (g and g.npcId and g.mapId) then return nil end
  return (self.mod.world:npc(g.mapId, g.npcId))
end

-- Is this NPC one of ours, and whose?  The world.talk hook asks before
-- deciding whether the A press is ours to answer.
function Ghosts:ownerOf(npc)
  if not npc then return nil end
  for id, g in pairs(self.ghosts) do
    if g.npcId and npc.id == g.npcId then return id end
  end
  return nil
end

function Ghosts:isSpawned(id)
  local g = self.ghosts[id]
  return g ~= nil and g.npcId ~= nil
end

-- the live NPC object behind a ghost, while it is spawned on the map we
-- are on (its px/py walk with it, which is what a camera wants)
function Ghosts:npcOf(id)
  local g = self.ghosts[id]
  local handle = g and self:_handle(g)
  return handle and handle.npc or nil
end

-- ------- lifecycle

function Ghosts:_spawn(game, id, mapId, x, y, facing, peer)
  self:despawn(id)
  local sprite = self:resolveSprite(game, peer.sprite)
  local npcId, err = self.mod.world:spawnNpc(mapId, {
    name = "BR_PEER_" .. id,
    sprite = sprite,
    x = x, y = y,
    movement = "STAY",
    range = FACING_TO_RANGE[facing] or "DOWN",
  })
  if not npcId then
    self.mod.log:warn("couldn't place player %s: %s", tostring(id), tostring(err))
    return
  end
  local g = { npcId = npcId, mapId = mapId, queue = {},
              sprite = sprite, name = peer.name }
  self.ghosts[id] = g
  -- eliminated players are walk-through so a corpse can't wall a survivor in
  local handle = self:_handle(g)
  if handle then handle:setPassable(peer.status == "out") end
end

function Ghosts:despawn(id)
  local g = self.ghosts[id]
  if not g then return end
  if g.npcId then
    -- runtime objects live in the shared map def until removed, so a missed
    -- despawn leaves a frozen double standing in the world
    local ok, err = self.mod.world:removeNpc(g.npcId)
    if not ok and err then self.mod.log:warn("couldn't remove ghost: %s", tostring(err)) end
  end
  self.ghosts[id] = nil
end

function Ghosts:despawnAll()
  for id in pairs(self.ghosts) do self:despawn(id) end
end

-- ------- driving
--
-- Reconcile every peer against its ghost: spawn on arrival to my map,
-- despawn on departure, drain each step queue at walking pace.  `peers` is
-- id -> { map, x, y, facing, sprite, status }.

function Ghosts:sync(game, myMapId, peers)
  -- drop ghosts for peers that vanished, left my map, or fell -- a beaten
  -- trainer leaves only their balls behind
  for id, g in pairs(self.ghosts) do
    local p = peers[id]
    if not p or p.map ~= myMapId or p.status == "out" then self:despawn(id) end
    if g == nil then end -- luacheck appeasement
  end
  if not myMapId then return end

  for id, p in pairs(peers) do
    if p.map == myMapId and p.status ~= "out" then
      self:_syncOne(game, id, myMapId, p)
    end
  end
end

function Ghosts:_syncOne(game, id, myMapId, p)
  local g = self.ghosts[id]
  if not g or g.mapId ~= myMapId then
    self:_spawn(game, id, myMapId, p.x, p.y, p.facing, p)
    return
  end

  local handle = self:_handle(g)
  if not handle then
    -- the map reloaded under us and took the pooled NPC with it; forget the
    -- stale id and let the next tick respawn
    g.npcId = nil
    return
  end

  -- keep solidity in step with the peer's status (alive: solid, out: pass)
  handle:setPassable(p.status == "out")

  if handle:isMoving() then return end

  if #g.queue > MAX_BACKLOG then
    g.queue = {}
    handle:placeAt(p.x, p.y, p.facing)
    return
  end

  local dir = g.queue[1]
  if dir then
    g.held = (g.held or 0) + 1
    if #g.queue >= 2 or g.held > Ghosts.HOLD_TICKS then
      g.held = 0
      table.remove(g.queue, 1)
      handle:stepNow(dir)
    end
    return
  end
  g.held = 0

  local cx, cy = handle:position()
  if cx ~= p.x or cy ~= p.y then
    handle:placeAt(p.x, p.y, p.facing)
  else
    handle:face(p.facing)
  end
end

-- A step a peer committed.  Queued rather than applied now: the ghost may
-- still be walking off the previous one, and steps must not overlap.
function Ghosts:pushStep(id, dir)
  local g = self.ghosts[id]
  if g then g.queue[#g.queue + 1] = dir end
end

function Ghosts:face(id, facing)
  local handle = self:_handle(self.ghosts[id])
  if handle and not handle:isMoving() then handle:face(facing) end
end

return Ghosts
