-- The battle-royale room vocabulary: constructors and a validating decoder.
--
-- Pure logic -- no love.*, no socket, no engine module -- so the protocol is
-- exercised headless by tests/br_test.lua.  Everything that touches the
-- network lives in relay.lua; everything that touches the overworld lives
-- in ghosts.lua and main.lua.
--
-- These are the `m` payloads inside the relay's {type="recv", from=, m=}
-- envelope (see relay/server.js).  Field names are short because a step
-- goes out roughly four times a second per player to every other player.
--
--   {t="place", map=, x=, y=, f=, st=, sprite=}   where I am + my status
--   {t="step",  d=, x=, y=, map=}                 a step just committed
--   {t="face",  f=, map=}                         a turn in place
--
-- place/step/face may carry `as = <id>`: "this is about that actor, relayed
-- by me".  The host uses it to move its bots, since a bot has no connection
-- of its own for the relay to attribute a message to.  Only the host's `as`
-- is honoured (see main.lua), so a guest cannot puppet anyone.
--   {t="start", seed=, spawns={{id=,map=,x=,y=}}} host: the match begins
--   {t="challenge", n=}                           I am facing you: fight
--   {t="accept", n=} / {t="decline", n=, why=}    the reply
--   {t="bt", m={...}}                             one link-battle message
--   {t="out"}                                     I have been eliminated
--   {t="loot", items={{id=,n=}}, money=}          my bag, to my killer
--   {t="botout", id=}                             I beat that bot
--   {t="spill", map=, mons={{key,x,y,species,lv}}} my team hit the ground
--   {t="took", key=}                              that ball is mine
--   {t="npcout", map=, obj=}                     a map's own trainer fell:
--                                                 hide the sprite everywhere
--   {t="ring", phase=, cx=, cy=, r=, place=}      host: the fog closed in
--                                                 (r < 0: over everything)
--   {t="winner", id=}                             host: the match is over
--
-- Statuses: "lobby" (not in the world yet), "alive", "battle" (locked in
-- a fight -- do not engage), "out" (eliminated, spectating on foot).
--
-- A peer that speaks a different PROTOCOL is refused at `place` rather than
-- half-understood.

local Wire = {}

-- 2: npcout joined the vocabulary, spills may stack on one cell, and a
--    loot ball is a gift prompt -- a v1 peer would keep beaten trainers
--    standing and fight balls, silently diverging from the room
Wire.PROTOCOL = 2

Wire.DIRS = { up = true, down = true, left = true, right = true }
Wire.STATUS = { lobby = true, alive = true, battle = true, out = true }

local MAX_NAME = 7     -- the Gen 1 player name box
local MAX_ID = 64
local MAX_CELL = 1000
local MAX_PLAYERS = 32

local function isCell(v)
  return type(v) == "number" and v == math.floor(v)
     and v >= -MAX_CELL and v <= MAX_CELL
end

local function isMapId(v)
  return type(v) == "string" and v ~= "" and #v <= MAX_ID
end

local function isId(v)
  return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= 1e6
end

-- Trim to the name box's width and drop anything the font cannot draw, so a
-- peer cannot inject control characters into our text boxes.
function Wire.cleanName(name)
  if type(name) ~= "string" then return "PLAYER" end
  local out = name:gsub("[^%w%p ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  out = out:sub(1, MAX_NAME):gsub("%s+$", "")  -- capping can re-expose a space
  if out == "" then return "PLAYER" end
  return out
end

-- ------- constructors

function Wire.place(map, x, y, facing, status, sprite, as)
  return { t = "place", v = Wire.PROTOCOL, map = map, x = x, y = y, f = facing,
           st = status, sprite = sprite, as = as }
end

function Wire.step(dir, x, y, map, as)
  return { t = "step", d = dir, x = x, y = y, map = map, as = as }
end

function Wire.face(facing, map, as)
  return { t = "face", f = facing, map = map, as = as }
end

-- spawns: array of { id=, map=, x=, y= }, one per player in the match
function Wire.start(seed, spawns)
  return { t = "start", seed = seed, spawns = spawns }
end

function Wire.challenge(nonce) return { t = "challenge", n = nonce } end
function Wire.accept(nonce) return { t = "accept", n = nonce } end
function Wire.decline(nonce, why) return { t = "decline", n = nonce, why = why } end
function Wire.battle(inner) return { t = "bt", m = inner } end
function Wire.out() return { t = "out" } end

-- items: array of { id=, n= }; the loser's whole bag plus their money,
-- unicast to whoever beat them (the first slice of the loot spill)
function Wire.loot(items, money)
  return { t = "loot", items = items, money = money }
end

function Wire.botout(id) return { t = "botout", id = id } end

-- a fallen team on the ground (DESIGN D8); `mons` rows are
-- { key, x, y, species, lv }
function Wire.spill(map, mons)
  local rows = {}
  for i, m in ipairs(mons or {}) do
    -- `lv` on the wire, `level` everywhere else: the field name is short
    -- because a full party ships six of these in one message
    rows[i] = { key = m.key, x = m.x, y = m.y, species = m.species, lv = m.level }
  end
  return { t = "spill", map = map, mons = rows }
end
function Wire.took(key) return { t = "took", key = key } end

-- one of Kanto's own trainers has been beaten: the sprite goes away for
-- everyone, and only its balls (a separate spill message) stay
function Wire.npcout(map, obj) return { t = "npcout", map = map, obj = obj } end

-- the host's word on where the fog is now; `place` is the centre's name,
-- carried so every client can announce it without a location table lookup
function Wire.ring(phase, cx, cy, r, place)
  return { t = "ring", phase = phase, cx = cx, cy = cy, r = r, place = place }
end
function Wire.winner(id) return { t = "winner", id = id } end

-- ------- decoding
--
-- Returns a normalized message, or nil + a reason.  The caller drops what
-- does not validate instead of trusting the shape: the relay forwards
-- whatever the other end sent, and "the other end" is a stranger's build.

local decoders = {}

-- the optional relayed-actor id; absent or malformed means "the sender"
local function actorOf(m)
  if m.as == nil then return nil end
  if not isId(m.as) then return nil end
  return m.as
end

decoders.place = function(m)
  if m.v ~= Wire.PROTOCOL then
    return nil, ("protocol %s, expected %d"):format(tostring(m.v), Wire.PROTOCOL)
  end
  if m.map ~= nil and not isMapId(m.map) then return nil, "bad map" end
  if m.map ~= nil and not (isCell(m.x) and isCell(m.y)) then return nil, "bad cell" end
  if m.f ~= nil and not Wire.DIRS[m.f] then return nil, "bad facing" end
  if not Wire.STATUS[m.st] then return nil, "bad status" end
  return { t = "place", map = m.map, x = m.x, y = m.y, facing = m.f or "down",
           status = m.st, as = actorOf(m),
           sprite = type(m.sprite) == "string" and #m.sprite <= MAX_ID
                    and m.sprite or nil }
end

decoders.step = function(m)
  if not Wire.DIRS[m.d] then return nil, "bad dir" end
  if not (isCell(m.x) and isCell(m.y)) then return nil, "bad cell" end
  if m.map ~= nil and not isMapId(m.map) then return nil, "bad map" end
  return { t = "step", dir = m.d, x = m.x, y = m.y, map = m.map, as = actorOf(m) }
end

decoders.face = function(m)
  if not Wire.DIRS[m.f] then return nil, "bad facing" end
  if m.map ~= nil and not isMapId(m.map) then return nil, "bad map" end
  return { t = "face", facing = m.f, map = m.map, as = actorOf(m) }
end

decoders.start = function(m)
  if type(m.seed) ~= "number" then return nil, "bad seed" end
  if type(m.spawns) ~= "table" then return nil, "bad spawns" end
  local spawns = {}
  for i, s in ipairs(m.spawns) do
    if i > MAX_PLAYERS then break end
    if type(s) ~= "table" or not isId(s.id) or not isMapId(s.map)
       or not (isCell(s.x) and isCell(s.y)) then
      return nil, "bad spawn"
    end
    spawns[#spawns + 1] = { id = s.id, map = s.map, x = s.x, y = s.y }
  end
  if #spawns == 0 then return nil, "no spawns" end
  return { t = "start", seed = math.floor(m.seed), spawns = spawns }
end

local function nonce(m)
  if type(m.n) ~= "number" then return nil end
  return math.floor(m.n)
end

decoders.challenge = function(m)
  local n = nonce(m)
  if not n then return nil, "bad nonce" end
  return { t = "challenge", nonce = n }
end

decoders.accept = function(m)
  local n = nonce(m)
  if not n then return nil, "bad nonce" end
  return { t = "accept", nonce = n }
end

decoders.decline = function(m)
  local n = nonce(m)
  if not n then return nil, "bad nonce" end
  return { t = "decline", nonce = n,
           why = type(m.why) == "string" and m.why:sub(1, MAX_ID) or nil }
end

decoders.bt = function(m)
  -- the inner message is LinkBattle's; Session/Wire.sanitize validates it
  -- on the way into the battle, so here it only has to be a table
  if type(m.m) ~= "table" then return nil, "bad battle payload" end
  return { t = "bt", inner = m.m }
end

decoders.out = function() return { t = "out" } end

local MAX_STACKS = 32

decoders.loot = function(m)
  if type(m.items) ~= "table" then return nil, "bad items" end
  local items = {}
  for i, it in ipairs(m.items) do
    if i > MAX_STACKS then break end
    if type(it) ~= "table" or type(it.id) ~= "string" or it.id == ""
       or #it.id > MAX_ID or type(it.n) ~= "number" then
      return nil, "bad item"
    end
    local n = math.floor(it.n)
    if n >= 1 then items[#items + 1] = { id = it.id, n = math.min(99, n) } end
  end
  local money = type(m.money) == "number"
    and math.max(0, math.min(999999, math.floor(m.money))) or 0
  return { t = "loot", items = items, money = money }
end

decoders.botout = function(m)
  if not isId(m.id) then return nil, "bad id" end
  return { t = "botout", id = m.id }
end

local MAX_SPILL = 6 -- a party

decoders.spill = function(m)
  if not isMapId(m.map) then return nil, "bad map" end
  if type(m.mons) ~= "table" then return nil, "bad mons" end
  local mons = {}
  for i, row in ipairs(m.mons) do
    if i > MAX_SPILL then break end
    if type(row) ~= "table" or type(row.key) ~= "string" or row.key == ""
       or #row.key > MAX_ID or type(row.species) ~= "string"
       or row.species == "" or #row.species > MAX_ID
       or not (isCell(row.x) and isCell(row.y)) then
      return nil, "bad spill row"
    end
    mons[#mons + 1] = {
      key = row.key, x = row.x, y = row.y, species = row.species,
      level = math.max(1, math.min(100, math.floor(tonumber(row.lv) or 5))),
    }
  end
  if #mons == 0 then return nil, "empty spill" end
  return { t = "spill", map = m.map, mons = mons }
end

decoders.npcout = function(m)
  if not isMapId(m.map) then return nil, "bad map" end
  if type(m.obj) ~= "string" or m.obj == "" or #m.obj > MAX_ID then
    return nil, "bad object"
  end
  return { t = "npcout", map = m.map, obj = m.obj }
end

decoders.took = function(m)
  if type(m.key) ~= "string" or m.key == "" or #m.key > MAX_ID then
    return nil, "bad key"
  end
  return { t = "took", key = m.key }
end

local function isCoord(v)
  return type(v) == "number" and v == v and v >= -64 and v <= 64
end

decoders.ring = function(m)
  if type(m.phase) ~= "number" or m.phase < 1 or m.phase > 64 then
    return nil, "bad phase"
  end
  if not (isCoord(m.cx) and isCoord(m.cy)) then return nil, "bad centre" end
  -- a negative radius is the fog over everything (Fog.EVERYWHERE), not an
  -- error: the final ring has to cross the wire like any other
  if type(m.r) ~= "number" or m.r ~= m.r or m.r < -1 or m.r > 64 then
    return nil, "bad radius"
  end
  return { t = "ring", phase = math.floor(m.phase), cx = m.cx, cy = m.cy,
           r = m.r,
           place = type(m.place) == "string" and m.place:sub(1, MAX_ID) or nil }
end

decoders.winner = function(m)
  if m.id ~= nil and not isId(m.id) then return nil, "bad id" end
  return { t = "winner", id = m.id }
end

function Wire.decode(m)
  if type(m) ~= "table" then return nil, "not a table" end
  local decoder = decoders[m.t]
  if not decoder then return nil, "unknown type: " .. tostring(m.t) end
  return decoder(m)
end

return Wire
