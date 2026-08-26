-- An in-memory stand-in for relay/server.js, for headless tests.
--
-- Implements the same room protocol (host_room / join_room / to / all ->
-- room_hosted / room_joined / roster / recv / room_closed / pong) over
-- transports that satisfy the src/link/Net.lua surface lib/relay.lua uses:
-- send / update / poll / close, plus .closed and .error.  Delivery is
-- synchronous on send, which is all a single-threaded test needs.
--
-- This is deliberately a second implementation of the room rules rather
-- than a binding to server.js: it keeps the Lua tests free of Node and
-- proves lib/relay.lua against the protocol, while relay/relay.test.js
-- proves server.js against the same protocol from the other side.

local Hub = {}
Hub.__index = Hub

function Hub.new()
  return setmetatable({ rooms = {}, codeSeq = 0 }, Hub)
end

local function makeCode(hub)
  hub.codeSeq = hub.codeSeq + 1
  return ("ROOM%02d"):format(hub.codeSeq)
end

local Transport = {}
Transport.__index = Transport

local room_roster  -- forward declaration; defined below

function Hub:connect()
  return setmetatable({
    hub = self, inbox = {}, closed = false, error = nil,
    id = nil, room = nil,
  }, Transport)
end

function Transport:_deliver(msg)
  self.inbox[#self.inbox + 1] = msg
end

function Transport:send(msg)
  if self.closed then return end
  local hub = self.hub
  local t = type(msg) == "table" and msg.type
  if t == "host_room" then
    local code = makeCode(hub)
    local room = { code = code, host = self, members = {}, order = {}, nextId = 1, locked = false }
    hub.rooms[code] = room
    self.id = room.nextId; room.nextId = room.nextId + 1
    self.room = room
    self.name = msg.name or "PLAYER"
    room.members[self.id] = self
    room.order[#room.order + 1] = self.id
    self:_deliver({ type = "room_hosted", code = code, id = self.id })
    room_roster(room)
  elseif t == "join_room" then
    local room = hub.rooms[msg.code]
    if not room then self:_deliver({ type = "room_error", reason = "not_found" }); return end
    if room.locked then self:_deliver({ type = "room_error", reason = "locked" }); return end
    self.id = room.nextId; room.nextId = room.nextId + 1
    self.room = room
    self.name = msg.name or "PLAYER"
    room.members[self.id] = self
    room.order[#room.order + 1] = self.id
    self:_deliver({ type = "room_joined", code = room.code, id = self.id, host = room.host.id })
    room_roster(room)
  elseif t == "leave_room" then
    self:_leave("left")
  elseif t == "lock_room" then
    if self.room and self.room.host == self then self.room.locked = msg.locked ~= false end
  elseif t == "can_host" then
    self.canHost = msg.ok ~= false
  elseif t == "to" then
    local room = self.room
    if not room then return end
    local target = room.members[msg.id]
    if target and target ~= self then
      target:_deliver({ type = "recv", from = self.id, m = msg.m })
    end
  elseif t == "all" then
    local room = self.room
    if not room then return end
    for _, m in pairs(room.members) do
      if m ~= self then m:_deliver({ type = "recv", from = self.id, m = msg.m }) end
    end
  elseif t == "ping" then
    self:_deliver({ type = "pong", t = msg.t })
  end
end

room_roster = function(room)
  local members = {}
  for _, id in ipairs(room.order) do
    local m = room.members[id]
    if m then members[#members + 1] = { id = id, name = m.name } end
  end
  local msg = { type = "roster", code = room.code, host = room.host.id, members = members }
  for _, id in ipairs(room.order) do
    local m = room.members[id]
    if m then m:_deliver(msg) end
  end
end

function Transport:_leave(reason)
  local room = self.room
  if not room then return end
  room.members[self.id] = nil
  for i = #room.order, 1, -1 do
    if room.order[i] == self.id then table.remove(room.order, i) end
  end
  self.room = nil
  if room.host == self then
    -- host migration (POK-116), the same election server.js runs: the
    -- longest-standing member that said it could take the room over
    local heir
    for _, id in ipairs(room.order) do
      local m = room.members[id]
      if m and m.canHost and (not heir or m.id < heir.id) then heir = m end
    end
    if heir then
      room.host = heir
      room_roster(room)
      return
    end
    for _, m in pairs(room.members) do
      m:_deliver({ type = "room_closed", reason = reason })
      m.room = nil
    end
    self.hub.rooms[room.code] = nil
  else
    room_roster(room)
  end
end

function Transport:update() end

function Transport:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

function Transport:close()
  if self.closed then return end
  self:_leave("host_gone")
  self.closed = true
end

return Hub
