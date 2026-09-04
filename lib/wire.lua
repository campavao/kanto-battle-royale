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
--   {t="botrec", id=, mons={{s=,f=}}}             a bot's persistent team
--                                                 changed (POK-158)
--   {t="spill", map=, mons={{key,x,y,species,lv}}} my team hit the ground
--   {t="took", key=}                              that ball is mine
--   {t="npcout", map=, obj=}                     a map's own trainer fell:
--                                                 hide the sprite everywhere
--   {t="ring", phase=, cx=, cy=, r=, place=, e=}  host: the fog closed in
--                                                 (e: seconds since the
--                                                 match began -- the one
--                                                 piece of host state a
--                                                 guest cannot derive)
--                                                 (r < 0: over everything)
--   {t="winner", id=}                             host: the match is over
--   {t="fame", party=, stats=}                    the champion's parade,
--                                                 for the whole room to watch
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
-- 3: a match opens in the Safari (start carries the round's length, and a
--    safari beat carries the host's clock) -- a v2 peer would drop into
--    the zone with a RATTATA and fight whoever it met there
-- 4: again -- the host sends the room back to the lobby for another match;
--    a v3 peer would sit in a finished world while the others re-dropped
-- 5: a spill carries the fallen trainer's BAG as one more thing on the
--    ground (items and money, D8's other half) and `loot` is gone -- a v4
--    peer would wait for a loot message that never comes
-- 6: peek / state -- a spectator asks the trainer they watch for a party
--    and bag summary, and gets one; a v5 peer would never answer
-- 7: a ring carries the host's elapsed match clock and a start carries the
--    round's fog length, so the room can be handed to somebody else when
--    the host drops (POK-116) -- a v6 peer promoted mid-match has no clock
--    to resume and would restart the fog at phase 1, with the ring
--    springing back open around everyone; and the champion sends their
--    parade so the whole room watches the same ending (POK-107)
-- 8: busy -- a trainer says when they are in a menu or in a fight, so the
--    room can see it over their head (POK-113); a v7 peer sends nothing
--    and would stand there looking idle while it read its PACK
-- 9: a place says which BUILD it came from -- the engine release and this
--    mod's version.  Neither was on the wire and neither is negotiable:
--    the engine refuses a link battle between two different engine
--    RELEASES (src/link/Handshake.lua checkCompat -> engine_skew) and a
--    different mod version changes the link fingerprint (Fingerprint's
--    modKey folds id@version for every mod that has not declared
--    affects_link = false, and this one has not).  So a mismatched pair
--    shares the overworld perfectly happily -- room, roster, ghosts,
--    walking, all of it on this wire -- and then cannot fight, which is
--    the whole game.  A v8 peer sends neither field and is refused at
--    `place` anyway; what these buy is a room that can NAME the
--    difference at the door, instead of leaving it to be discovered at
--    the first engage where the only message is the engine's "Link
--    battle needs the same version and mods" -- which names no number.
-- 10: botrec -- a bot's persistent team (POK-158).  Two clients that
--    disagree about a bot's record disagree about who wins a fight with
--    it, so the message is load-bearing, not cosmetic.
Wire.PROTOCOL = 11

Wire.DIRS = { up = true, down = true, left = true, right = true }
Wire.STATUS = { lobby = true, alive = true, battle = true, out = true }
-- What a trainer is doing that is not walking (POK-113).  Absent -- and a
-- `busy` carrying no kind -- means "back on the map", which is the state
-- nothing needs to be drawn for.
Wire.BUSY = { menu = true, battle = true }

local MAX_NAME = 7     -- the Gen 1 player name box
local MAX_ID = 64
local MAX_VER = 16     -- "0.34.0", "0.0.0-dev", and room for a suffix.
                       -- Short on purpose: these land in an 18-column Gen
                       -- 1 text box (lib/door.lua), so a stranger does not
                       -- get to decide how many lines we spend on them.
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

-- A version off the wire is a stranger's string that ends up in one of our
-- text boxes, so it keeps the semver alphabet and nothing else.  nil means
-- UNKNOWN -- a peer that sent none, or sent rubbish -- which is not the
-- same thing as "different"; see Wire.buildDiffers.
function Wire.cleanVersion(v)
  if type(v) ~= "string" then return nil end
  local out = v:gsub("[^%w%.%-+]", ""):sub(1, MAX_VER)
  if out == "" then return nil end
  return out
end

-- Can these two builds fight each other?  Either half being unknown is NOT
-- a mismatch: a bot's place carries no build of its own, and an old peer
-- carries none at all.  Saying nothing is better than accusing somebody of
-- a difference the room cannot actually see.
function Wire.buildDiffers(mine, theirs)
  if type(mine) ~= "table" or type(theirs) ~= "table" then return false end
  if mine.engine and theirs.engine and mine.engine ~= theirs.engine then
    return true
  end
  if mine.mod and theirs.mod and mine.mod ~= theirs.mod then return true end
  return false
end

-- ------- constructors

-- `build` is { engine =, mod = } and is the sender's OWN (PROTOCOL 9).
-- Bot places pass none: a bot is the host's puppet with no install of its
-- own, and it never fights over the link, so it has no build to compare.
function Wire.place(map, x, y, facing, status, sprite, as, build)
  return { t = "place", v = Wire.PROTOCOL, map = map, x = x, y = y, f = facing,
           st = status, sprite = sprite, as = as,
           ev = build and build.engine, mv = build and build.mod }
end

function Wire.step(dir, x, y, map, as)
  return { t = "step", d = dir, x = x, y = y, map = map, as = as }
end

function Wire.face(facing, map, as)
  return { t = "face", f = facing, map = map, as = as }
end

-- spawns: array of { id=, map=, x=, y= }, one per player in the match.
-- `fog` is the round's phase length: a mod option, so it belongs to the
-- host who started the match rather than to whoever is reading -- otherwise
-- an heir with a different setting would carry the ring on at its own pace
-- (POK-116).
function Wire.start(seed, spawns, safari, fog)
  return { t = "start", seed = seed, spawns = spawns, safari = safari,
           fog = fog }
end

function Wire.challenge(nonce) return { t = "challenge", n = nonce } end
function Wire.accept(nonce) return { t = "accept", n = nonce } end
function Wire.decline(nonce, why) return { t = "decline", n = nonce, why = why } end
function Wire.battle(inner) return { t = "bt", m = inner } end
function Wire.out() return { t = "out" } end

function Wire.botout(id) return { t = "botout", id = id } end

-- A bot's persistent team (POK-158): each mon's species and how much of
-- itself it still has, plus its BAG once it has a real one -- potions get
-- drunk and looted bags merge in, so the bag has to travel with the team.
-- Broadcast by whoever changed the record -- the host on a catch, the
-- client whose fight just scarred it -- and applied verbatim by everyone.
function Wire.botrec(id, record)
  local rows = {}
  for i, m in ipairs(record or {}) do
    if i > 6 then break end
    rows[i] = { s = m.species, f = m.hpFrac }
  end
  local out = { t = "botrec", id = id, mons = rows }
  local bag = record and record.bag
  if bag then
    out.bag = { items = bag.items or {}, money = bag.money or 0 }
  end
  return out
end

-- a fallen team on the ground (DESIGN D8); `mons` rows are
-- { key, x, y, species, lv }, and `bag` -- the trainer's items and money,
-- one more thing on the ground (POK-25) -- is { key, x, y, items, money,
-- name }
function Wire.spill(map, mons, bag)
  local rows = {}
  for i, m in ipairs(mons or {}) do
    -- `lv` on the wire, `level` everywhere else: the field name is short
    -- because a full party ships six of these in one message
    rows[i] = { key = m.key, x = m.x, y = m.y, species = m.species, lv = m.level }
  end
  local out = { t = "spill", map = map, mons = rows }
  if bag then
    out.bag = { key = bag.key, x = bag.x, y = bag.y, items = bag.items,
                money = bag.money, name = bag.name }
  end
  return out
end
-- Something on the ground is gone (D8), or PART of a bag is (POK-176):
-- with `item` and `n`, that many of that item left the bag and the rest
-- is still there; `cash` says the money went too.  A bare key is the
-- whole piece -- a ball, or a bag a bot swallowed whole.  PROTOCOL 11.
function Wire.took(key, item, n, cash)
  local out = { t = "took", key = key }
  if item then
    out.item, out.n = item, n
    if cash then out.cash = true end
  end
  return out
end

-- one of Kanto's own trainers has been beaten: the sprite goes away for
-- everyone, and only its balls (a separate spill message) stay
function Wire.npcout(map, obj) return { t = "npcout", map = map, obj = obj } end

-- the host's word on where the fog is now; `place` is the centre's name,
-- carried so every client can announce it without a location table lookup
-- `elapsed` is the host's own match clock.  It rides every shrink so that
-- whoever inherits the room can carry the fog on from where it was rather
-- than starting it again (POK-116).
function Wire.ring(phase, cx, cy, r, place, elapsed)
  return { t = "ring", phase = phase, cx = cx, cy = cy, r = r, place = place,
           e = elapsed }
end
-- the host's Safari clock (POK-21): seconds left, zero being the buzzer
function Wire.safari(left) return { t = "safari", left = left } end
function Wire.winner(id) return { t = "winner", id = id } end

-- The champion's parade, so the ending is the room's rather than one
-- screen's (POK-107).  Only the winner can author it -- it is their team --
-- and it carries what the Hall of Fame draws and nothing else: a species,
-- what it was called, and how far it got.
function Wire.fame(party, stats)
  local rows = {}
  for _, mon in ipairs(party or {}) do
    if mon.species then
      rows[#rows + 1] = { sp = mon.species,
                          nm = mon.nickname or mon.species,
                          lv = mon.level or 1 }
    end
  end
  return { t = "fame", party = rows, stats = stats }
end
-- Back to the lobby with the roster kept (POK-20, re-based by POK-144).
-- Host only, and no longer a button anybody presses: endMatch broadcasts it
-- as part of every ending that keeps the room.  A client already at "over"
-- takes it as "the exit is due" and lets its own ending finish first; a
-- client still standing in a match it never saw end takes it as the exit
-- itself, which is the recovery this message has always been.
function Wire.again() return { t = "again" } end

-- What this trainer is doing (POK-113).  Edge-triggered: sent when the
-- answer CHANGES rather than every tick, and re-sent on the position
-- resync so a peer that missed the edge is not left holding a stale mark.
-- nil is the common case (walking around) and costs one field.
-- `as` lets the host put a mark over a BOT's head (POK-121).  Everything
-- else about a bot is derived, but this is a broadcast of a decision the
-- host alone made -- how long that bot stands in the grass -- so it has to
-- ride the wire like its steps do.  Without it a bot's six-second errand
-- dwell reads as a trainer who stopped for no reason, which is worse than
-- the pacing it replaced.
function Wire.busy(kind, as) return { t = "busy", k = kind, as = as } end

-- a spectator asks the trainer they watch what they carry (POK-18)...
function Wire.peek() return { t = "peek" } end
-- ...and is answered: party rows are { sp, lv, hp, mhp, st, mv } on the
-- wire, the bag as item stacks plus money
function Wire.state(state)
  local party = {}
  for i, m in ipairs((state and state.party) or {}) do
    party[i] = { sp = m.species, lv = m.level, hp = m.hp, mhp = m.maxHp,
                 st = m.status, mv = m.moves }
  end
  return { t = "state", party = party, items = state and state.items or {},
           money = state and state.money or 0 }
end

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

-- The third return is a CODE for the caller to branch on.  A protocol
-- mismatch is the one drop worth telling a player about rather than only
-- the log: it is another BATTLE ROYALE, it will happen on every wire bump,
-- and from this side it is indistinguishable from a peer who simply never
-- moves.  Matching on a formatted string would be the alternative.
decoders.place = function(m)
  if m.v ~= Wire.PROTOCOL then
    return nil, ("protocol %s, expected %d"):format(tostring(m.v), Wire.PROTOCOL),
           "protocol"
  end
  if m.map ~= nil and not isMapId(m.map) then return nil, "bad map" end
  if m.map ~= nil and not (isCell(m.x) and isCell(m.y)) then return nil, "bad cell" end
  if m.f ~= nil and not Wire.DIRS[m.f] then return nil, "bad facing" end
  if not Wire.STATUS[m.st] then return nil, "bad status" end
  local engine, modv = Wire.cleanVersion(m.ev), Wire.cleanVersion(m.mv)
  return { t = "place", map = m.map, x = m.x, y = m.y, facing = m.f or "down",
           status = m.st, as = actorOf(m),
           sprite = type(m.sprite) == "string" and #m.sprite <= MAX_ID
                    and m.sprite or nil,
           build = (engine or modv) and { engine = engine, mod = modv } or nil }
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
  -- the Safari opening's length in seconds; absent or 0 is the plain drop
  local safari = m.safari
  if safari ~= nil and not (type(safari) == "number" and safari == safari
                            and safari >= 0 and safari <= 3600) then
    return nil, "bad safari"
  end
  -- an absent or nonsense fog length falls back to the reader's own option,
  -- which is what every client did before the field existed
  local fog = m.fog
  if fog ~= nil and not (type(fog) == "number" and fog == fog
                         and fog > 0 and fog <= 86400) then
    fog = nil
  end
  return { t = "start", seed = math.floor(m.seed), spawns = spawns,
           safari = math.floor(safari or 0), fog = fog }
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

-- a bag's contents: { id=, n= } stacks, capped the way the bag itself is
local function decodeItems(list)
  if type(list) ~= "table" then return nil end
  local items = {}
  for i, it in ipairs(list) do
    if i > MAX_STACKS then break end
    if type(it) ~= "table" or type(it.id) ~= "string" or it.id == ""
       or #it.id > MAX_ID or type(it.n) ~= "number" then
      return nil
    end
    local n = math.floor(it.n)
    if n >= 1 then items[#items + 1] = { id = it.id, n = math.min(99, n) } end
  end
  return items
end

decoders.botout = function(m)
  if not isId(m.id) then return nil, "bad id" end
  return { t = "botout", id = m.id }
end

decoders.botrec = function(m)
  if not isId(m.id) then return nil, "bad id" end
  if type(m.mons) ~= "table" then return nil, "bad mons" end
  local record = {}
  for i, r in ipairs(m.mons) do
    if i > 6 then break end
    if type(r) ~= "table" or type(r.s) ~= "string" or r.s == ""
       or #r.s > MAX_ID then
      return nil, "bad record row"
    end
    local f = tonumber(r.f)
    if not f then return nil, "bad record hp" end
    record[#record + 1] = { species = r.s,
                            hpFrac = math.max(0, math.min(1, f)) }
  end
  if #record == 0 then return nil, "empty record" end
  if m.bag ~= nil then
    if type(m.bag) ~= "table" then return nil, "bad bag" end
    local items = decodeItems(m.bag.items or {})
    if not items then return nil, "bad bag items" end
    record.bag = { items = items,
                   money = math.max(0, math.floor(tonumber(m.bag.money) or 0)) }
  end
  return { t = "botrec", id = m.id, record = record }
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
  local bag
  if m.bag ~= nil then
    local b = m.bag
    if type(b) ~= "table" or type(b.key) ~= "string" or b.key == ""
       or #b.key > MAX_ID or not (isCell(b.x) and isCell(b.y)) then
      return nil, "bad bag"
    end
    local items = decodeItems(b.items or {})
    if not items then return nil, "bad bag items" end
    local money = type(b.money) == "number"
      and math.max(0, math.min(999999, math.floor(b.money))) or 0
    bag = { key = b.key, x = b.x, y = b.y, items = items, money = money,
            name = type(b.name) == "string" and b.name:sub(1, MAX_NAME) or nil }
  end
  -- a trainer with nothing left to spill but a bag still spills the bag
  if #mons == 0 and not bag then return nil, "empty spill" end
  return { t = "spill", map = m.map, mons = mons, bag = bag }
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
  local out = { t = "took", key = m.key }
  if m.item ~= nil then
    if type(m.item) ~= "string" or m.item == "" or #m.item > MAX_ID then
      return nil, "bad item"
    end
    local n = tonumber(m.n)
    if not n or n < 1 or n ~= math.floor(n) or n > 99 then return nil, "bad count" end
    out.item, out.n = m.item, n
    out.cash = m.cash == true or nil
  end
  return out
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
  -- a clock that is absent, negative or not finite is simply not a clock;
  -- the heir falls back to the phase it can see
  local elapsed = nil
  if type(m.e) == "number" and m.e == m.e and m.e >= 0 and m.e < 1e7 then
    elapsed = m.e
  end
  return { t = "ring", phase = math.floor(m.phase), cx = m.cx, cy = m.cy,
           r = m.r, elapsed = elapsed,
           place = type(m.place) == "string" and m.place:sub(1, MAX_ID) or nil }
end

decoders.safari = function(m)
  if type(m.left) ~= "number" or m.left ~= m.left or m.left < 0 or m.left > 3600 then
    return nil, "bad clock"
  end
  return { t = "safari", left = math.floor(m.left) }
end

decoders.winner = function(m)
  if m.id ~= nil and not isId(m.id) then return nil, "bad id" end
  return { t = "winner", id = m.id }
end

decoders.again = function() return { t = "again" } end

decoders.busy = function(m)
  -- an unknown kind is not a protocol error -- it is a peer saying
  -- something this build has no mark for, and the honest answer is "not
  -- busy" rather than dropping the message and keeping the old mark up
  if m.k ~= nil and (type(m.k) ~= "string" or not Wire.BUSY[m.k]) then
    return { t = "busy", kind = nil, as = actorOf(m) }
  end
  return { t = "busy", kind = m.k, as = actorOf(m) }
end

decoders.peek = function() return { t = "peek" } end

local function clampInt(v, lo, hi, default)
  if type(v) ~= "number" or v ~= v then return default end
  return math.max(lo, math.min(hi, math.floor(v)))
end

-- Every party that arrives over the wire is the same shape of untrusted:
-- at most six rows, each naming a species, and a peer that says otherwise
-- is refused rather than clamped.  What each row BECOMES differs -- a
-- state row carries health and moves, a fame row carries a nickname -- so
-- that part stays with the decoder; `row` builds it.
--
-- The cap is a hard six, not a truncation to be tidied up later: a party of
-- two hundred marching past the Hall of Fame is the thing being prevented
-- (POK-107).
local function decodeParty(rows, row)
  if type(rows) ~= "table" then return nil, "bad party" end
  local party = {}
  for i, r in ipairs(rows) do
    if i > 6 then break end
    if type(r) ~= "table" or type(r.sp) ~= "string" or r.sp == "" or #r.sp > MAX_ID then
      return nil, "bad party row"
    end
    party[#party + 1] = row(r)
  end
  return party
end

decoders.state = function(m)
  local party, bad = decodeParty(m.party, function(r)
    local moves = {}
    for j, mv in ipairs(type(r.mv) == "table" and r.mv or {}) do
      if j > 4 then break end
      if type(mv) == "string" and mv ~= "" and #mv <= MAX_ID then moves[#moves + 1] = mv end
    end
    return {
      species = r.sp, level = clampInt(r.lv, 1, 100, 1),
      hp = clampInt(r.hp, 0, 999, 0), maxHp = clampInt(r.mhp, 1, 999, 1),
      status = type(r.st) == "string" and r.st:sub(1, MAX_ID) or nil,
      moves = moves,
    }
  end)
  if not party then return nil, bad end
  local items = decodeItems(m.items or {})
  if not items then return nil, "bad items" end
  return { t = "state", party = party, items = items,
           money = clampInt(m.money, 0, 999999, 0) }
end

-- The parade is drawn, never trusted: every field is clamped to what the
-- Hall of Fame can put on a screen, so a peer cannot stretch the card or
-- march a party of two hundred past everyone (POK-107).
decoders.fame = function(m)
  local party, bad = decodeParty(m.party, function(r)
    return {
      species = r.sp,
      nickname = type(r.nm) == "string" and r.nm ~= "" and r.nm:sub(1, MAX_ID)
                 or r.sp,
      level = clampInt(r.lv, 1, 100, 1),
    }
  end)
  if not party then return nil, bad end
  local st = type(m.stats) == "table" and m.stats or {}
  return { t = "fame", party = party, stats = {
    catches = clampInt(st.catches, 0, 99999, 0),
    beats   = clampInt(st.beats,   0, 99999, 0),
    steps   = clampInt(st.steps,   0, 9999999, 0),
    rings   = clampInt(st.rings,   1, 64, 1),
    seconds = clampInt(st.seconds, 0, 999999, 0),
    money   = clampInt(st.money,   0, 999999, 0),
  } }
end

function Wire.decode(m)
  if type(m) ~= "table" then return nil, "not a table" end
  local decoder = decoders[m.t]
  if not decoder then return nil, "unknown type: " .. tostring(m.t) end
  return decoder(m)
end

return Wire
