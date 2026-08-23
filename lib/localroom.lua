-- A room with nobody else in it: solo play, no server.
--
-- lib/relay.lua only ever talks to a transport through send / update / poll
-- / close plus the closed and error fields, so a match against bots does not
-- need a socket at all -- it needs something that answers the room protocol
-- for a room of one.  This is that, and it means "host, add bots, start" is
-- a thing you can do with nothing running but the game.
--
-- Every message that would go to other players (to / all) is a no-op here,
-- because there is nobody to send it to.  That is the whole trick: the mod
-- above is unchanged, broadcasting into a room that happens to be empty.

local LocalRoom = {}
LocalRoom.__index = LocalRoom

LocalRoom.CODE = "SOLO"

function LocalRoom.new()
  return setmetatable({
    inbox = {},
    closed = false,
    error = nil,
    paired = true,
    code = nil,
    address = nil,
    target = nil,
    name = "PLAYER",
  }, LocalRoom)
end

function LocalRoom:_deliver(msg)
  self.inbox[#self.inbox + 1] = msg
end

function LocalRoom:send(msg)
  if self.closed or type(msg) ~= "table" then return end
  local t = msg.type
  if t == "host_room" then
    self.name = type(msg.name) == "string" and msg.name or "PLAYER"
    self.code = LocalRoom.CODE
    self:_deliver({ type = "room_hosted", code = LocalRoom.CODE, id = 1 })
    self:_deliver({ type = "roster", code = LocalRoom.CODE, host = 1,
                    members = { { id = 1, name = self.name } } })
  elseif t == "join_room" then
    -- there is no room to join but this one, and we are already in it
    self:_deliver({ type = "room_error", reason = "not_found" })
  elseif t == "quick_join" then
    -- nobody is hosting in here either, so the caller gets to be first
    self:_deliver({ type = "no_open_rooms" })
  elseif t == "ping" then
    self:_deliver({ type = "pong", t = msg.t })
  end
  -- to / all / lock_room / leave_room: nobody is listening, so nothing to do
end

function LocalRoom:update() end

function LocalRoom:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

function LocalRoom:close()
  self.closed = true
end

return LocalRoom
