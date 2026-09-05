-- The relay client: one TCP line connection to relay/server.js, one room.
--
-- Owns a src/link/Net.lua transport in its relay (TCP) mode and nothing
-- else.  Net already does non-blocking luasocket framing with line caps, so
-- this module never touches a socket; it speaks the room protocol on top
-- (host_room / join_room / to / all / roster / recv, see relay/server.js)
-- and turns it into callbacks.  The `network` permission in manifest.json
-- is what lets a mod reach src.link at all.
--
-- Transport-injectable: pass opts.transport and Net is never required,
-- which is how tests/br_test.lua drives several clients against the
-- in-memory tests/fake_relay.lua under plain luajit.
--
-- Threading model: none.  update() runs from the engine's 60 Hz fixed step
-- (the input.step hook), so every callback fires on the game thread.

local Relay = {}
Relay.__index = Relay

-- Keepalive: a ping every PING_EVERY seconds, and a relay that has said
-- nothing at all for SILENT_FOR is treated as gone.  A wedged TCP socket
-- can stay "open" forever, so the timeout is ours rather than the OS's.
local PING_EVERY = 5.0
local SILENT_FOR = 25.0

-- control types that are ours; anything else from the relay is ignored
-- rather than fatal so a newer relay can add chatter without breaking us
local CONTROL = {
  room_hosted = true, room_joined = true, room_error = true, roster = true,
  recv = true, room_closed = true, pong = true, no_open_rooms = true,
  match_in_progress = true, info = true,
}

-- how often a connected client re-asks for the server's info line
-- (POK-161): the motd never changes mid-session, but `conns` is the
-- "somebody else is online" signal and it should not go stale in the
-- lobby where it matters
local INFO_EVERY = 15.0

local ERRORS = {
  not_found = "That code wasn't\nfound.",
  full = "That game is\nfull.",
  locked = "That game has\nalready started.",
  already_in_room = "Already in a\ngame.",
  -- the host showed you out (POK-130); the room will not take you back
  removed = "The host removed\nyou from that\ngame.",
  -- the relay is at its room ceiling: not the player's fault, and
  -- SOLO VS BOTS still works, so say something that points at the way out
  server_full = "That server is\nbusy. Try SOLO\nor try again\nlater.",
}

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  local ok, socket = pcall(require, "socket")
  if ok and socket and socket.gettime then return socket.gettime() end
  return os.clock()
end

-- opts.address   -> "host:port" of the relay (ignored with opts.transport)
-- opts.transport -> a preconstructed Net-alike (tests); otherwise made here
-- opts.log       -> mod.log
function Relay.new(opts)
  opts = opts or {}
  return setmetatable({
    address = opts.address,
    net = opts.transport,
    log = opts.log,
    status = "idle",      -- idle | connecting | lobby | closed
    id = nil,             -- our member id in the room
    code = nil,           -- the room code
    hostId = nil,
    open = false,         -- is the relay listing this room for quick_join?
    members = {},         -- ordered { id=, name= }, as the relay last said
    error = nil,
    handlers = {},
    lastHeard = 0,
    lastPing = 0,
    pingSentAt = nil,
    rtt = nil,
  }, Relay)
end

-- on("roster", fn(members)) / on("joined", fn(self)) / on("message",
-- fn(fromId, m)) / on("closed", fn(reason)).  One handler per event.
function Relay:on(event, fn)
  assert(self.handlers[event] == nil, "duplicate relay handler: " .. event)
  self.handlers[event] = fn
  return self
end

function Relay:_fire(event, ...)
  local fn = self.handlers[event]
  if not fn then return end
  local ok, err = pcall(fn, ...)
  if not ok and self.log then
    self.log:warn("battle royale handler %s failed: %s", event, tostring(err))
  end
end

local function newNet(address)
  local ok, Net = pcall(require, "src.link.Net")
  if not ok or not Net then return nil, "link transport unavailable" end
  local net = Net.new()
  if not net:connectTCP(address) then
    return nil, net.error or "couldn't reach the relay"
  end
  return net
end

function Relay:_open(control)
  if not self.net then
    local net, err = newNet(self.address)
    if not net then
      self.error = err
      self.status = "closed"
      return false, err
    end
    self.net = net
  end
  self.status = "connecting"
  self.lastHeard = now()
  self.lastPing = self.lastHeard
  self.net:send(control)
  return true
end

-- open = true lists the room for quick_join.  It stays private otherwise:
-- being findable by strangers is something a host opts into.
-- max = the room's size; the relay refuses joins past it (and clamps it
-- to its own member ceiling).  Absent means the ceiling.
function Relay:host(name, opts)
  return self:_open({ type = "host_room", name = name,
                      open = (opts and opts.open) == true,
                      max = opts and tonumber(opts.max) or nil })
end

-- the host's MAX, after the room is up (the lobby's MAX row)
function Relay:setMax(n)
  n = tonumber(n)
  if not n then return false end
  return self:_raw({ type = "set_max", max = math.floor(n) })
end

-- Ask the relay for any open room.  If there are none it answers
-- no_open_rooms rather than closing, so the caller can host on this same
-- connection -- which is exactly what "quick play" needs to do.
function Relay:quickJoin(name)
  return self:_open({ type = "quick_join", name = name })
end

function Relay:setOpen(open)
  self.open = open == true
  return self:_raw({ type = "set_open", open = self.open })
end

function Relay:join(code, name)
  return self:_open({ type = "join_room", code = code, name = name })
end

-- The one shared DAILY GAME room (POK-161): join it, or become its host.
-- The relay answers room_joined or room_hosted, both already handled; a
-- daily match already running answers match_in_progress like quick play.
function Relay:dailyJoin(name)
  return self:_open({ type = "daily_join", name = name })
end

-- Enter a LOCKED room as a watcher who plays the next match (POK-133).
-- Sent raw, not through _open: the one caller already holds the live
-- connection quick_join answered on.
function Relay:spectate(code, name)
  return self:_raw({ type = "join_room", code = code, name = name,
                     spectate = true })
end

-- Show a member the door (POK-130).  Host only, and the relay enforces
-- that too; their IP stays out for the life of the room.
function Relay:kick(id)
  return self:_raw({ type = "kick", id = id })
end

function Relay:isOpen() return self.status == "lobby" end
function Relay:isHost() return self.id ~= nil and self.id == self.hostId end

function Relay:member(id)
  for _, m in ipairs(self.members) do
    if m.id == id then return m end
  end
  return nil
end

function Relay:nameOf(id)
  local m = self:member(id)
  return m and m.name or ("P" .. tostring(id))
end

-- ------- sending

function Relay:_raw(msg)
  if not self.net or self.net.closed or self.status == "closed" then return false end
  self.net:send(msg)
  return true
end

function Relay:send(toId, m)
  return self:_raw({ type = "to", id = toId, m = m })
end

-- A room of one has nobody to forward to (POK-102).  The relay fans `all`
-- out to every OTHER member, so in a solo room -- Quick Play that found no
-- open room and hosted its own, or a bot match -- every frame is forwarded
-- to nobody: one session pushed 11,672 of them across 45 minutes, dominated
-- by the per-tile Wire.step of the player and of every bot.
--
-- The guard is local and needs no protocol: the roster the relay sends is
-- already kept in self.members.  It is deliberately narrow -- suppress only
-- when the roster is KNOWN, names exactly one member, and that member is us
-- -- so an empty or not-yet-arrived roster still sends rather than silently
-- swallowing the room.  Pings are a separate path, so the connection is
-- carried on its own and this cannot idle it out.
--
-- `to` sends are untouched: only the room-wide fan-out is gated.
function Relay:broadcast(m)
  if self.id ~= nil and #self.members == 1
     and self.members[1] and self.members[1].id == self.id then
    self.suppressed = (self.suppressed or 0) + 1
    return true
  end
  return self:_raw({ type = "all", m = m })
end

function Relay:lock(locked)
  return self:_raw({ type = "lock_room", locked = locked ~= false })
end

-- A stat rides a connection that already exists, or it does not go at all
-- (POK-124).  Refused without an address, which is exactly the LocalRoom a
-- solo match runs on: it has no listener and drops types it does not know
-- silently, so a solo room could otherwise swallow the very count it was
-- meant to be carrying.  Refused outside the lobby too -- there is no
-- reason to spend a line mid-match on something that can wait.
function Relay:stat(fields)
  if not self.address then return false end
  if self.status ~= "lobby" then return false end
  local msg = { type = "stat" }
  for k, v in pairs(fields or {}) do
    if k ~= "type" then msg[k] = v end
  end
  return self:_raw(msg)
end

-- Offer (or withdraw) this client as the room's next host (POK-116).  The
-- relay hands the room to the longest-standing member that has said yes, so
-- saying nothing is how an older client keeps the old ending -- the room
-- closing when its host goes.
function Relay:canHost(ok)
  return self:_raw({ type = "can_host", ok = ok ~= false })
end

-- ------- the pump

function Relay:update()
  local net = self.net
  if not net or self.status == "closed" or self.status == "idle" then return end

  local ok, err = pcall(net.update, net)
  if not ok then
    self:_close("transport error: " .. tostring(err))
    return
  end
  if net.error and not self.error then self.error = net.error end
  if net.closed then
    self:_close(self.error or "Lost the relay.")
    return
  end

  local pollOk, msgs = pcall(net.poll, net)
  if not pollOk then
    self:_close("transport error: " .. tostring(msgs))
    return
  end
  for _, raw in ipairs(msgs or {}) do
    if type(raw) == "table" and CONTROL[raw.type] then
      self.lastHeard = now()
      self:_receive(raw)
      if self.status == "closed" then return end
    end
  end

  local t = now()
  if t - self.lastPing >= PING_EVERY then
    self.lastPing = t
    self.pingSentAt = t
    self:_raw({ type = "ping", t = t })
  end
  -- the info line rides the same cadence machinery (POK-161); an old
  -- relay ignores the unknown type and serverInfo simply stays nil
  if self.status == "lobby" and t - (self.lastInfo or 0) >= INFO_EVERY then
    self.lastInfo = t
    self:_raw({ type = "info" })
  end
  if t - self.lastHeard >= SILENT_FOR then
    self:_close("Lost the relay.")
  end
end

local function cleanMembers(list)
  local out = {}
  for _, m in ipairs(type(list) == "table" and list or {}) do
    if type(m) == "table" and type(m.id) == "number" then
      out[#out + 1] = { id = math.floor(m.id),
                        name = type(m.name) == "string" and m.name or "PLAYER",
                        -- a watcher of this match, a player of the next
                        -- one (POK-133); cleared by the relay at unlock
                        spectate = m.spectate == true or nil }
    end
  end
  return out
end

function Relay:_receive(msg)
  local t = msg.type
  if t == "room_hosted" then
    self.id, self.code, self.hostId = msg.id, msg.code, msg.id
    self.status = "lobby"
    self:_fire("joined", self)
  elseif t == "room_joined" then
    self.id, self.code, self.hostId = msg.id, msg.code, msg.host
    self.status = "lobby"
    self:_fire("joined", self)
  elseif t == "room_error" then
    self:_close(ERRORS[msg.reason] or ("Couldn't join:\n" .. tostring(msg.reason)))
  elseif t == "no_open_rooms" then
    -- not an error: nobody is hosting yet, so the caller gets to be first
    self:_fire("noopen", self)
  elseif t == "match_in_progress" then
    -- quick_join's third answer (POK-133): nothing joinable, but a match
    -- is live -- the caller may enter it as a spectator and play the next
    self:_fire("running", self, msg.code,
                type(msg.members) == "number" and msg.members or nil)
  elseif t == "roster" then
    if type(msg.host) == "number" then self.hostId = msg.host end
    if type(msg.open) == "boolean" then self.open = msg.open end
    if type(msg.max) == "number" then self.max = msg.max end
    self.members = cleanMembers(msg.members)
    self:_fire("roster", self.members)
  elseif t == "recv" then
    if type(msg.from) == "number" and type(msg.m) == "table" then
      self:_fire("message", math.floor(msg.from), msg.m)
    end
  elseif t == "room_closed" then
    self:_close(msg.reason == "left" and "The host left\nthe game."
                or "The host\ndisconnected.")
  elseif t == "pong" then
    if self.pingSentAt then self.rtt = now() - self.pingSentAt end
  elseif t == "info" then
    -- the server's own line (POK-161): the motd rows come pre-bounded,
    -- but a client trusts nothing it renders into a 17-cell box
    local rows = {}
    for _, l in ipairs(type(msg.motd) == "table" and msg.motd or {}) do
      if type(l) == "string" and l ~= "" then
        rows[#rows + 1] = l:sub(1, 17)
        if #rows >= 3 then break end
      end
    end
    local daily
    if type(msg.daily) == "table" and tonumber(msg.daily.secs) then
      -- the receipt clock rides along so a countdown can be computed
      -- without another round trip (POK-161)
      daily = { secs = tonumber(msg.daily.secs),
                label = type(msg.daily.label) == "string"
                  and msg.daily.label:sub(1, 17) or nil,
                at = now() }
    end
    self.serverInfo = { motdRows = rows,
                        rooms = tonumber(msg.rooms) or 0,
                        conns = tonumber(msg.conns) or 0,
                        daily = daily }
    -- (relay, info), like "running": the daily smoke caught this firing
    -- with info alone while its one consumer read the second argument --
    -- the start clock was never armed and the hour sailed past
    self:_fire("info", self, self.serverInfo)
  end
end

function Relay:_close(reason)
  if self.status == "closed" then return end
  self.status = "closed"
  self.error = self.error or reason
  if self.log then
    -- one line that says why the room went away: the difference between
    -- "the relay dropped us" and "we dropped the relay" is undebuggable
    -- without it
    self.log:warn("relay connection closed: %s (net.error: %s, net.closed: %s)",
      tostring(reason), tostring(self.net and self.net.error),
      tostring(self.net and self.net.closed))
  end
  if self.net then pcall(self.net.close, self.net) end
  self:_fire("closed", reason)
end

-- Leaving on purpose: tell the relay first so the roster updates at once
-- instead of waiting out the idle sweep.
function Relay:leave()
  if self.net and not self.net.closed and self.status ~= "closed" then
    pcall(function() self:_raw({ type = "leave_room" }) end)
    pcall(self.net.update, self.net) -- flush the write buffer
  end
  if self.status == "closed" then return end
  self.status = "closed"
  if self.net then pcall(self.net.close, self.net) end
  self:_fire("closed", nil)
end

return Relay
