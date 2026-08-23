-- A battle's transport: one pair of players, tunnelled through the room.
--
-- LinkState and LinkBattle talk to a transport through src/link/Session.lua,
-- which only asks for update/poll/send/close and the paired/closed/error
-- fields.  This is the smallest object that satisfies that, carrying each
-- message as a {t="bt", m=...} unicast over the relay to the opponent.
--
-- Why a channel rather than handing LinkState the relay connection: the
-- relay socket is shared with every other player's presence traffic and
-- must outlive the battle.  Session closes its transport when the battle
-- ends; closing a channel costs nothing, closing the room would end the
-- match.  This is also what lifts the old co-op limit of "a battle ends the
-- session".
--
-- update() is a no-op on purpose: the relay is pumped once per tick by
-- main.lua, which then pushes any `bt` from the right peer into here.

local Channel = {}
Channel.__index = Channel

-- relay: lib/relay.lua (or anything with :send(id, m))
-- peerId: the opponent's room id
-- opts.onClose: called once when the battle side closes the channel
function Channel.new(relay, peerId, opts)
  return setmetatable({
    relay = relay,
    peerId = peerId,
    inbox = {},
    paired = true,   -- the room already connected us
    closed = false,
    error = nil,
    code = nil, address = nil, target = nil, -- Session mirrors these
    onClose = opts and opts.onClose,
  }, Channel)
end

function Channel:update() end

function Channel:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

function Channel:send(msg)
  if self.closed then return end
  local ok = self.relay:send(self.peerId, { t = "bt", m = msg })
  if not ok then
    self.error = "the relay went away"
    self.closed = true
  end
end

-- main.lua feeds inbound battle traffic here
function Channel:push(inner)
  if self.closed then return end
  self.inbox[#self.inbox + 1] = inner
end

-- The opponent dropped out of the room: the battle sees a closed
-- transport and ends the way a pulled cable would (a draw, "left the
-- battle"), rather than waiting forever on a move that is never coming.
function Channel:peerGone()
  if self.closed then return end
  self.closed = true
end

function Channel:close()
  if self.closed and not self.onClose then return end
  self.closed = true
  local cb = self.onClose
  self.onClose = nil
  if cb then cb(self) end
end

return Channel
