-- The lobby as a room you can see, not a list you scroll (the user's
-- sketch, 2026-09-05).
--
--   +----------------------------------+
--   |            CODE 1234             |
--   |   [red]  RED      [bot]  JOEY    |
--   |   [gary] GARY     [ ]            |   <- an outline is a seat a bot
--   |   ...                            |      (or a late human) will fill
--   |           STARTS IN 12           |
--   | v                        OPTIONS |   <- LEAVE for a guest
--   +----------------------------------+
--
-- Two columns, four rows.  The sketch drew three columns, and three do not
-- fit: a column is 72 pixels once the box border is paid for, and the Gen
-- 1 font is 8 pixels a glyph with no narrower face, so a cursor, a seven
-- letter name and the door's "!" after it are 72 pixels exactly -- three
-- across would be 53 each and the names would sit on top of each other.
-- Eight seats a page is the same four pages for a full thirty as nine
-- would have been.
--
-- Every trainer is their own sprite and name: a human wears the skin they
-- picked (it rides the place message everyone already sends in the lobby),
-- a bot that has not been rolled yet is an outline where it will stand.
-- The host's OPTIONS button opens the settings as a menu over the room --
-- FILL, MAX, OPEN, the clocks, DEBUG, START MATCH, LEAVE -- which is
-- lib/menu.lua's lobby face, kept there so the same rows are what the
-- unit suite reads.
--
-- Pure where it matters: seats(), header(), status() and move() are plain
-- functions over a BR table so tests/br_test.lua can check the room
-- without an engine.  Screen is the stack state (new/update/draw), modeled
-- on lib/skins.lua's Picker.

local Lobby = {}

Lobby.COLS, Lobby.ROWS = 2, 4
Lobby.PAGE = Lobby.COLS * Lobby.ROWS

-- The longest a seat's name may be: the Gen 1 name box.  A bot's name is
-- dealt from a list that fits it; a human's is cleaned to it on the wire.
Lobby.NAME_MAX = 7

-- what a seat whose trainer is not known yet is drawn as, faded
Lobby.EMPTY_SPRITE = "SPRITE_RED"

-- ------- the room, as data

-- Who is here, in roster order, then whoever the door turned away (dim,
-- flagged), then the bots that will take the seats still open -- by name
-- and face, the same ones the match will spawn (the user's sketch had
-- "BOT" in a seat like anyone else).  Each seat:
--   { id=, name=, sprite=, me=, host=, flag=, next=, wins=, absent=, bot=, empty= }
-- A seat with an id is a trainer you can open; a bot's is a picture, and
-- an empty one is a seat whose bot is not known yet (a guest before the
-- host's place has arrived).
--
-- A bot is dealt from the room's seed and its position, exactly as
-- onStart deals it: the host rolls the seed when the room opens rather
-- than at START MATCH, and says it on its place message (lib/wire.lua's
-- `sd`), so every client shows the same bots the drop will hold.
function Lobby.seats(BR)
  local relay = BR.relay
  local out = {}
  if not relay then return out end
  local members = relay.members or {}
  for _, m in ipairs(members) do
    local p = BR.players and BR.players[m.id]
    local me = relay.id ~= nil and m.id == relay.id
    out[#out + 1] = {
      id = m.id, name = tostring(m.name or "?"),
      me = me or nil,
      host = (m.id == relay.hostId) or nil,
      -- my own seat wears what I picked, before any place has gone out
      sprite = (me and BR.skinWalk and BR:skinWalk()) or (p and p.sprite) or nil,
      flag = (BR.buildTrouble and BR:buildTrouble(m.id)) and true or nil,
      next = m.spectate or nil,
      wins = (me and BR.winCount and BR:winCount()) or (p and p.wins) or nil,
    }
  end
  for _, f in ipairs((BR.flaggedAbsent and BR:flaggedAbsent()) or {}) do
    out[#out + 1] = { name = tostring(f.name or "?"), absent = true, flag = true }
  end
  -- MAX minus the humans here: bots when FILL is on and the seed is
  -- known, open seats otherwise (the user's call: a MAX of thirty with
  -- FILL off is twenty-nine faded seats, so the size of the game is on
  -- the screen whether or not bots will take it)
  local seed = Lobby.fillOn(BR) and Lobby.seedOf(BR) or nil
  local Bots = require("mods.battle_royale.lib.bots")
  local data = BR.game and BR.game.data
  for i = 1, Lobby.emptySeats(BR, #members) do
    if seed then
      local id = Bots.idFor(i)
      local look = Bots.look(seed, id, data)
      out[#out + 1] = { bot = true, name = Bots.name(seed, id),
                        sprite = look and look.walk or nil }
    else
      out[#out + 1] = { empty = true }
    end
  end
  return out
end

-- The seed the room's bots are dealt from: the host's own, or the one the
-- host's place message carried.  nil until it is known.
function Lobby.seedOf(BR)
  local relay = BR.relay
  if not relay then return nil end
  if relay:isHost() then return BR.lobbySeed end
  local hp = BR.players and BR.players[relay.hostId]
  return hp and hp.lobbySeed or nil
end

-- The seats past the humans: MAX less who is here.  A solo room's MAX is
-- its bot count outright; a hosted room's is the size the relay holds it
-- to, which the roster carries (relay.max) and the host has locally as
-- fillMax.  The host's place message says whether FILL is on (`fl` > 0),
-- which decides whether those seats draw as bots or as open seats -- a
-- guest's own fillTo is whatever their last room left in it.
function Lobby.emptySeats(BR, humans)
  local Bots = require("mods.battle_royale.lib.bots")
  local relay = BR.relay
  local n
  if BR.solo then
    n = tonumber(BR.botCount) or 0
  else
    n = Lobby.roomMax(BR) - (tonumber(humans) or 0)
  end
  return math.max(0, math.min(Bots.MAX, math.floor(n)))
end

-- The room's size as this client knows it: the host's own MAX; a guest's
-- roster (an older relay sends none -- then the host's FILL target, if
-- on, since that is at least what the drop will hold).
function Lobby.roomMax(BR)
  local relay = BR.relay
  if not relay then return 0 end
  if relay:isHost() then
    return tonumber(BR.fillMax and BR:fillMax()) or 0
  end
  local hp = BR.players and BR.players[relay.hostId]
  return tonumber(relay.max) or tonumber(hp and hp.fill) or 0
end

-- Whether the open seats will be bots: the host's own switch, or the
-- FILL target the host's place message carried.
function Lobby.fillOn(BR)
  local relay = BR.relay
  if not relay then return false end
  if BR.solo then return true end
  if relay:isHost() then return (tonumber(BR.fillTo) or 0) > 0 end
  local hp = BR.players and BR.players[relay.hostId]
  return (tonumber(hp and hp.fill) or 0) > 0
end

-- The line over the room.
function Lobby.header(BR)
  if BR.dailyLobby then
    local left = BR.dailyStartsIn and BR:dailyStartsIn()
    if not left then return "AWAITING TIME..." end
    local h = math.floor(left / 3600)
    if h > 0 then
      return ("STARTS IN %dH%02dM"):format(h, math.floor((left % 3600) / 60))
    end
    return ("STARTS IN %d:%02d"):format(math.floor(left / 60), left % 60)
  end
  if BR.solo then return "SOLO VS BOTS" end
  local code = BR.relay and BR.relay.code
  return "CODE " .. tostring(code or "...")
end

-- The line under the room, or nil.  One thing at a time, most urgent
-- first: a room that cannot fight, a clock that is running, the result
-- of the match this room just played, then what a guest is waiting on.
function Lobby.status(BR)
  local relay = BR.relay
  local host = relay and relay:isHost()
  local trouble = BR.buildTroubleLabel and BR:buildTroubleLabel()
  if trouble then return trouble end
  -- (the daily's clock is the header; it armed the same countdown, and
  -- saying it twice on one screen was the first thing the user saw)
  local countdown = not BR.dailyLobby and Lobby.startsIn(BR)
  if countdown then return "STARTS IN " .. tostring(countdown) end
  if BR.lastResult then
    if BR.lastResult.won then return "YOU WIN!" end
    if BR.lastResult.name then return tostring(BR.lastResult.name) .. " WON" end
    return "MATCH OVER"
  end
  if BR.dailyLobby then return nil end
  if BR.isSpectating and BR:isSpectating() then return "YOU PLAY NEXT" end
  if not host then return "WAIT FOR HOST" end
  return nil
end

-- Seconds until the clock starts the match, or nil: the host's own, or
-- the one the host's place message carried, counted down on this
-- client's wall clock from the moment it arrived.
function Lobby.startsIn(BR)
  local relay = BR.relay
  if relay and relay:isHost() then return BR.startsIn and BR:startsIn() end
  local hp = BR.players and relay and BR.players[relay.hostId]
  if not (hp and hp.startsAt) then return nil end
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime())
    or (BR.now and BR:now()) or 0
  return math.max(0, math.ceil(hp.startsAt - now))
end

-- What the bottom-right button says.  OPTIONS is the host's, and only
-- where there are options: the daily game has none (the clock starts
-- it), so its host leaves like everyone else.
--
-- QUICK PLAY has no host to speak of (the user's call, 2026-09-05): the
-- room fills itself with bots and counts itself down, so whoever the
-- relay made host sees the same button as everyone else.  The one thing
-- that room needs a hand for is the match after the first (POK-167), so
-- once there is a result and no clock running, that host's button arms
-- it -- and then it is LEAVE again while the clock runs.
function Lobby.button(BR)
  local relay = BR.relay
  local host = relay and relay:isHost()
  if BR.quick then
    if host and BR.lastResult and not (BR.startsIn and BR:startsIn()) then
      return "READY UP"
    end
    return "LEAVE"
  end
  if host and not BR.dailyLobby then return "OPTIONS" end
  return "LEAVE"
end

-- ------- the cursor
--
-- `cur` is a seat index, or 0 for the button.  Left and right walk the
-- seats in reading order; up and down walk the rows, and the button is
-- one more row that joins the bottom to the top: down off the last row
-- lands on it, up off the first row lands on it, and from it up is the
-- last seat and down the first -- so the room scrolls both ways (the
-- user's call, 2026-09-05).
function Lobby.move(cur, n, dir)
  local COLS = Lobby.COLS
  if n <= 0 then return 0 end
  if dir == "up" then
    if cur == 0 then return n end
    if cur - COLS >= 1 then return cur - COLS end
    return 0
  elseif dir == "down" then
    if cur == 0 then return 1 end
    if cur + COLS <= n then return cur + COLS end
    return 0
  elseif dir == "left" then
    if cur > 1 then return cur - 1 end
    return cur
  elseif dir == "right" then
    if cur ~= 0 and cur < n then return cur + 1 end
    return cur
  end
  return cur
end

-- The first row on screen (0-based), so the cursor's row is in view.
function Lobby.scrollFor(scroll, cur, n)
  local rows = math.ceil(n / Lobby.COLS)
  local maxScroll = math.max(0, rows - Lobby.ROWS)
  scroll = math.max(0, math.min(scroll or 0, maxScroll))
  if cur and cur > 0 then
    local row = math.floor((cur - 1) / Lobby.COLS)
    if row < scroll then scroll = row end
    if row >= scroll + Lobby.ROWS then scroll = row - Lobby.ROWS + 1 end
  end
  return scroll
end

-- ------- a seat, opened
--
-- The rows behind A on a trainer: who they are, what is known about them,
-- and -- for the host, on a guest -- the door.  REMOVE is one press here:
-- opening the seat is already the deliberate step the old two-press arm
-- stood in for.
function Lobby.seatItems(BR, seat)
  local items = {}
  local function row(label)
    items[#items + 1] = { label = label, dead = true, keepOpen = true,
                          onSelect = function() end }
  end
  row(tostring(seat.name))
  if seat.bot then row("BOT") end
  if seat.host then row("HOST") end
  if seat.next then row("PLAYS NEXT") end
  if seat.wins then row("WINS: " .. tostring(seat.wins)) end
  if seat.flag then
    row("CANNOT BATTLE")
    local p = BR.players and BR.players[seat.id]
    local theirs = p and p.build
    if theirs then
      if theirs.mod then row("ROYALE v" .. tostring(theirs.mod)) end
      if theirs.engine then row("GAME v" .. tostring(theirs.engine)) end
    end
  end
  local relay = BR.relay
  if relay and relay:isHost() and seat.id and not seat.me and not seat.absent then
    items[#items + 1] = {
      label = "REMOVE",
      onSelect = function() if BR.kick then BR:kick(seat.id) end end,
    }
  end
  -- the box pops itself on any row that does not keep it open (Menu's
  -- own rule), so BACK has nothing left to do
  items[#items + 1] = { label = "BACK", onSelect = function() end }
  return items
end

-- ------- the screen

local Screen = {}
Screen.__index = Screen
Lobby.Screen = Screen

-- geometry, in pixels, inside the 20x18 box
local HEADER_Y = 8
local GRID_Y = 18          -- the first row's sprite
local NAME_DY = 17         -- the name, a pixel under the sprite (readability)
local ROW_PITCH = 25       -- sprite (16) + gap (1) + name (8)
local STATUS_Y = 119
local BUTTON_Y = 128
local COL_X = { 8, 80 }    -- the interior split in two
local COL_W = 72

function Screen.new(game, mod, BR, owner)
  local self = setmetatable({}, Screen)
  self.game, self.mod, self.BR = game, mod, BR
  self.owner = owner    -- the stack state this draws for (popped on LEAVE)
  self.cur = 0
  self.scroll = 0
  self.cache = {}       -- walk sheet id -> { img, quad } | false
  return self
end

-- the standing frame of a walk sheet, cached (lib/skins.lua's recipe)
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

function Screen:leave()
  local game = self.game
  if game.stack:top() == self.owner then game.stack:pop() end
  self.BR:teardown()
end

function Screen:openSeat(seat)
  local Menu = require("mods.battle_royale.lib.menu")
  local game = self.game
  game.stack:push(Menu.live(self.mod, game, function()
    return Lobby.seatItems(self.BR, seat)
  end))
end

function Screen:openOptions()
  local Menu = require("mods.battle_royale.lib.menu")
  local game, mod, BR = self.game, self.mod, self.BR
  local owner = self.owner
  game.stack:push(Menu.live(mod, game, function()
    local items = Menu.items(mod, BR, game)
    -- START MATCH and LEAVE close the room screen under the box as well:
    -- the box pops itself (Menu's own not-keepOpen rule) and then these
    -- run, with the room screen on top
    for _, it in ipairs(items) do
      if not it.keepOpen then
        local inner = it.onSelect
        it.onSelect = function()
          if game.stack:top() == owner then game.stack:pop() end
          if inner then inner() end
        end
      end
    end
    return items
  end))
end

function Screen:update(dt)
  local input = self.game.input
  local BR = self.BR
  local seats = Lobby.seats(BR)
  local n = #seats
  if self.cur > n then self.cur = n end
  if not input then return end
  if input:wasPressed("up") then
    self.cur = Lobby.move(self.cur, n, "up")
  elseif input:wasPressed("down") then
    self.cur = Lobby.move(self.cur, n, "down")
  elseif input:wasPressed("left") then
    self.cur = Lobby.move(self.cur, n, "left")
  elseif input:wasPressed("right") then
    self.cur = Lobby.move(self.cur, n, "right")
  elseif input:wasPressed("a") then
    pcall(function()
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end)
    if self.cur == 0 then
      local button = Lobby.button(BR)
      if button == "OPTIONS" then
        self:openOptions()
      elseif button == "READY UP" then
        if BR.readyUp then BR:readyUp() end
      else
        self:leave()
      end
    else
      local seat = seats[self.cur]
      if seat and (seat.id or seat.bot) then self:openSeat(seat) end
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    -- the screen closes; the room stays (the START menu's ROYALE row
    -- reopens it), exactly as the list did
    if self.game.stack:top() == self.owner then self.game.stack:pop() end
  end
  self.scroll = Lobby.scrollFor(self.scroll, self.cur, n)
end

local function drawCentred(Font, text, cx, y)
  local w = Font.width and Font.width(text) or (#text * 8)
  local x = math.floor(cx - w / 2)
  Font.draw(text, x, y)
  return x, w
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

  drawCentred(Font, Lobby.header(BR), 80, HEADER_Y)

  local seats = Lobby.seats(BR)
  local n = #seats
  self.scroll = Lobby.scrollFor(self.scroll, self.cur, n)
  local first = self.scroll * Lobby.COLS
  for i = 1, Lobby.PAGE do
    local idx = first + i
    local seat = seats[idx]
    if not seat then break end
    local col = (i - 1) % Lobby.COLS
    local row = math.floor((i - 1) / Lobby.COLS)
    local cx = COL_X[col + 1] + COL_W / 2
    local sy = GRID_Y + row * ROW_PITCH
    local ny = sy + NAME_DY
    if seat.empty then
      -- a seat whose trainer is not known yet: a faded RED, the one
      -- sprite every build has.  The cursor sits beside it, since there
      -- is no name for it to lead.
      local ghost = self:walkFrame(Lobby.EMPTY_SPRITE)
      if ghost then
        g.setColor(1, 1, 1, 0.3)
        g.draw(ghost.img, ghost.quad, cx - 8, sy)
      else
        g.setColor(0.55, 0.55, 0.6, 1)
        g.rectangle("line", cx - 8 + 0.5, sy + 0.5, 15, 15)
      end
      g.setColor(0, 0, 0, 1)
      if idx == self.cur then Font.drawCode(Theme.cursor, cx - 20, sy + 4) end
    else
      local dim = seat.absent or seat.next
      if dim then g.setColor(0.45, 0.45, 0.5, 1) else g.setColor(1, 1, 1, 1) end
      local walk = self:walkFrame(seat.sprite)
      if walk then
        g.draw(walk.img, walk.quad, cx - 8, sy)
      else
        -- a trainer whose sheet has not arrived yet: the outline, so the
        -- seat still reads as taken
        g.setColor(0.55, 0.55, 0.6, 1)
        g.rectangle("line", cx - 8 + 0.5, sy + 0.5, 15, 15)
      end
      g.setColor(0, 0, 0, 1)
      local name = tostring(seat.name):sub(1, Lobby.NAME_MAX)
      local x, w = drawCentred(Font, name, cx, ny)
      if seat.flag then Font.draw("!", x + w, ny) end
      if idx == self.cur then Font.drawCode(Theme.cursor, x - 8, ny) end
    end
  end

  local status = Lobby.status(BR)
  if status then drawCentred(Font, status, 80, STATUS_Y) end

  -- more below: the same glyph every scrolling menu uses, at the left of
  -- the bottom row so the button keeps the right
  if (self.scroll + Lobby.ROWS) * Lobby.COLS < n then
    Font.drawCode(Theme.moreArrow, 8, BUTTON_Y)
  end
  local label = Lobby.button(BR)
  local bx = 152 - #label * 8
  Font.draw(label, bx, BUTTON_Y)
  if self.cur == 0 then Font.drawCode(Theme.cursor, bx - 8, BUTTON_Y) end
  g.setColor(1, 1, 1, 1)
end

return Lobby
