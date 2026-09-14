-- The lobby list (2026-09-13): every room a stranger may walk into, as a
-- screen you scroll rather than a code you have to be told.
--
--   +----------------------------------+
--   |             LOBBIES              |
--   | > DAILY            IN 27M        |   <- the DAILY GAME, inside its half hour
--   |   [hiker] RED       3/30         |
--   |   [lass]  MAY       1/8    [lock]|   <- a lock is a passcoded room
--   |   [red]   JOEY     12/30         |
--   |   ...                            |
--   |            NO OPEN GAMES         |   <- the status line, when there is one
--   | v                           BACK |
--   +----------------------------------+
--
-- One row a room: the host as their sprite and name (the relay is told
-- the walk sheet when the room opens, and again when the host changes
-- skin), how many TRAINERS are in it over the host's MAX -- humans, never
-- bots, so 1/30 is one person waiting for you and twenty-nine bot seats
-- -- and a padlock when the host put a passcode on the door.  A on a row
-- knocks; a locked row asks for the passcode first.  Five rows a page;
-- the page scrolls with the cursor the way the room does.
--
-- The list itself is lib/relay.lua's `rooms`, re-asked every few seconds
-- while this screen is up, so a room that filled or started drops off on
-- its own.  The connection is the one the join goes over: joinListed
-- knocks on the same socket the list came in on, so "I'll take that one"
-- is one message, not a reconnect.
--
-- Pure where it matters: rows(), status(), count(), move() and scrollFor()
-- are plain functions over a BR table so tests/br_test.lua can read the
-- list without an engine.  Screen is the stack state (new/update/draw),
-- modeled on lib/lobby.lua's.

local Browse = {}

Browse.ROWS = 5
Browse.NAME_MAX = 7

-- ------- the list, as data

-- What the relay last said, or nothing yet.  Each row:
--   { code=, host=, skin=, players=, seats=, pass= }
function Browse.rows(BR)
  local relay = BR.relay
  return (relay and relay.rooms) or {}
end

function Browse.header(BR)
  return "LOBBIES"
end

-- "3/30": trainers in the room over the seats the host set -- or, on
-- the DAILY GAME's row, how long until its hour
function Browse.count(row)
  if row.daily then return Browse.countdown(row.secs) end
  return ("%d/%d"):format(tonumber(row.players) or 0, tonumber(row.seats) or 0)
end

-- "IN 27M", down to "NOW": the daily's row is a promise, not a headcount
function Browse.countdown(secs)
  secs = tonumber(secs) or 0
  if secs <= 0 then return "NOW" end
  return ("IN %dM"):format(math.ceil(secs / 60))
end

-- What a shut door says, in the seventeen cells a status line has.  The
-- relay's own text is a paragraph for a text box; the list has one line.
Browse.REFUSALS = {
  passcode = "WRONG PASSCODE",
  full = "THAT GAME IS FULL",
  locked = "THAT GAME STARTED",
  not_found = "THAT GAME IS GONE",
  removed = "HOST REMOVED YOU",
  already_in_room = "ALREADY IN A GAME",
}

-- The line under the list, or nil.  Most urgent first: the connection
-- still being made, a knock in flight, the last refusal, an empty list.
function Browse.status(BR)
  local relay = BR.relay
  if not relay then return nil end
  if relay.status == "connecting" then return "CONNECTING..." end
  if relay.joining then return "JOINING..." end
  if relay.joinReason then
    return Browse.REFUSALS[relay.joinReason] or "COULDN'T JOIN"
  end
  if #Browse.rows(BR) == 0 then return "NO OPEN GAMES" end
  return nil
end

-- ------- the cursor
--
-- `cur` is a row index, or 0 for the button.  Up and down walk the rows
-- and the button joins the bottom to the top, as the room's does.
function Browse.move(cur, n, dir)
  if n <= 0 then return 0 end
  if dir == "up" then
    if cur == 0 then return n end
    return cur - 1
  elseif dir == "down" then
    if cur == 0 then return 1 end
    if cur < n then return cur + 1 end
    return 0
  end
  return cur
end

-- The first row on screen (0-based), so the cursor's row is in view.
function Browse.scrollFor(scroll, cur, n)
  local maxScroll = math.max(0, n - Browse.ROWS)
  scroll = math.max(0, math.min(scroll or 0, maxScroll))
  if cur and cur > 0 then
    local row = cur - 1
    if row < scroll then scroll = row end
    if row >= scroll + Browse.ROWS then scroll = row - Browse.ROWS + 1 end
  end
  return scroll
end

-- ------- the screen

local Screen = {}
Screen.__index = Screen
Browse.Screen = Screen

-- geometry, in pixels, inside the 20x18 box
local HEADER_Y = 8
local ROW_Y = 20           -- the first row's sprite
local ROW_PITCH = 18       -- sprite (16) + a breath
local TEXT_DY = 4          -- text centred on the sprite
local CURSOR_X = 8
local SPRITE_X = 16
local NAME_X = 36
local COUNT_RIGHT = 136    -- the count ends here
local LOCK_X = 140
local STATUS_Y = 114
local BUTTON_Y = 128

function Screen.new(game, mod, BR, owner)
  local self = setmetatable({}, Screen)
  self.game, self.mod, self.BR = game, mod, BR
  self.owner = owner    -- the stack state this draws for
  self.cur = 0
  self.scroll = 0
  self.cache = {}       -- walk sheet id -> { img, quad } | false
  return self
end

-- the standing frame of a walk sheet, cached (lib/lobby.lua's recipe)
function Screen:walkFrame(walkId)
  if not walkId then return nil end
  local hit = self.cache[walkId]
  if hit ~= nil then return hit or nil end
  local data = self.game and self.game.data
  local def = data and data.sprites and data.sprites[walkId]
  local ok, img = pcall(function() return love.graphics.newImage(def.image) end)
  if not (def and ok and img) then
    self.cache[walkId] = false
    return nil
  end
  local quad = love.graphics.newQuad(0, 0, 16, 16, img:getDimensions())
  self.cache[walkId] = { img = img, quad = quad }
  return self.cache[walkId]
end

-- Backing out closes the connection: the list is nothing without it,
-- and the first face is where the ways in are.
function Screen:leave()
  self.BR:teardown()
end

-- A on a row: knock.  A locked row asks for the passcode first, on the
-- same widget the room code is typed on; a blank or a B leaves the list
-- where it was.
function Screen:pick(row)
  local BR = self.BR
  if not (row and row.code) then return end
  -- the DAILY GAME's row: its own door, which makes the room if nobody
  -- has yet
  if row.daily then
    if BR.joinDaily then BR:joinDaily() end
    return
  end
  if row.pass then
    local Entry = require("mods.battle_royale.lib.entry")
    self.game.stack:push(Entry.new(self.game, {
      title = "PASSCODE",
      shape = Entry.PASS,
      onDone = function(pass)
        if not pass or pass == "" then return end
        if BR.joinListed then BR:joinListed(row.code, pass) end
      end,
    }))
  else
    if BR.joinListed then BR:joinListed(row.code) end
  end
end

function Screen:update(dt)
  local input = self.game.input
  local BR = self.BR
  local rows = Browse.rows(BR)
  local n = #rows
  if self.cur > n then self.cur = n end
  if not input then return end
  if input:wasPressed("up") then
    self.cur = Browse.move(self.cur, n, "up")
  elseif input:wasPressed("down") then
    self.cur = Browse.move(self.cur, n, "down")
  elseif input:wasPressed("a") then
    pcall(function()
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end)
    if self.cur == 0 then
      self:leave()
    elseif not (BR.relay and BR.relay.joining) then
      self:pick(rows[self.cur])
    end
  elseif input:wasPressed("b") then
    self:leave()
  elseif input:wasPressed("start") then
    -- the screen closes; the connection stays for the START menu's
    -- ROYALE row to come back to, exactly as the room does
    if self.game.stack:top() == self.owner then self.game.stack:pop() end
  end
  self.scroll = Browse.scrollFor(self.scroll, self.cur, n)
end

local function drawCentred(Font, text, cx, y)
  local w = Font.width and Font.width(text) or (#text * 8)
  local x = math.floor(cx - w / 2)
  Font.draw(text, x, y)
  return x, w
end

-- An 8x8 padlock in the ink colour: the font has no such glyph, and a
-- letter would read as part of a name.
local function drawLock(g, x, y)
  g.rectangle("line", x + 2.5, y + 0.5, 3, 4)   -- the shackle
  g.rectangle("fill", x + 1, y + 3, 6, 5)       -- the body
end

function Screen:draw()
  local g = love.graphics
  local Font = require("src.render.Font")
  local Theme = require("src.ui.Theme")
  local BR = self.BR
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, 160, 144)
  Font.drawBox(0, 0, 20, 18)
  g.setColor(0, 0, 0, 1)

  drawCentred(Font, Browse.header(BR), 80, HEADER_Y)

  local rows = Browse.rows(BR)
  local n = #rows
  self.scroll = Browse.scrollFor(self.scroll, self.cur, n)
  for i = 1, Browse.ROWS do
    local idx = self.scroll + i
    local row = rows[idx]
    if not row then break end
    local sy = ROW_Y + (i - 1) * ROW_PITCH
    local ty = sy + TEXT_DY
    g.setColor(1, 1, 1, 1)
    local walk = not row.daily and self:walkFrame(row.skin)
    if walk then
      g.draw(walk.img, walk.quad, SPRITE_X, sy)
    elseif not row.daily then
      -- a host whose sheet this build lacks: the outline, so the row
      -- still reads as a trainer
      g.setColor(0.55, 0.55, 0.6, 1)
      g.rectangle("line", SPRITE_X + 0.5, sy + 0.5, 15, 15)
    end
    g.setColor(0, 0, 0, 1)
    Font.draw(tostring(row.host):sub(1, Browse.NAME_MAX), NAME_X, ty)
    local count = Browse.count(row)
    local cw = Font.width and Font.width(count) or (#count * 8)
    Font.draw(count, COUNT_RIGHT - cw, ty)
    if row.pass then drawLock(g, LOCK_X, ty) end
    if idx == self.cur then Font.drawCode(Theme.cursor, CURSOR_X, ty) end
  end

  local status = Browse.status(BR)
  if status then drawCentred(Font, status, 80, STATUS_Y) end

  if self.scroll + Browse.ROWS < n then
    Font.drawCode(Theme.moreArrow, 8, BUTTON_Y)
  end
  local label = "BACK"
  local bx = 152 - #label * 8
  Font.draw(label, bx, BUTTON_Y)
  if self.cur == 0 then Font.drawCode(Theme.cursor, bx - 8, BUTTON_Y) end
  g.setColor(1, 1, 1, 1)
end

return Browse
