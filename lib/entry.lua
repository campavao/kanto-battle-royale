-- A slot-scrub entry screen for a room code.
--
-- It exists because the Gen 1 naming grid has no digits (letters and
-- punctuation only), so NamingScreen physically cannot enter one.
-- src/link/CodeEntry.lua already owns this interaction for the vanilla link
-- menu; this is the screen around it, drawn to match LinkState's own code
-- entry so the two do not look like different games.
--
--   up/down     scrub the character under the cursor
--   left/right  move between slots
--   A           confirm -> onDone(text)
--   B           cancel

local CodeEntry = require("src.link.CodeEntry")

local Entry = {}
Entry.__index = Entry

Entry.CODE = { charset = CodeEntry.CHARSET, length = CodeEntry.LENGTH }
-- Wide enough for a real hostname, not just a dotted IPv4: a hosted relay
-- hands out names like "roundhouse.proxy.rlwy.net:23456", which is 31
-- characters with letters and a hyphen in it.  Blank is the first character
-- so a fresh entry starts empty rather than showing forty A's, and blanks are
-- trimmed on confirm so nothing has to be padded out by hand.  Uppercase is
-- what the Gen 1 glyphs have and DNS does not care, so the value is lowered
-- on the way out.
Entry.ADDRESS = { charset = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:", length = 40 }

-- opts: { title=, shape=Entry.CODE|Entry.ADDRESS, default=, onDone= }
function Entry.new(game, opts)
  opts = opts or {}
  local shape = opts.shape or Entry.CODE
  local self = setmetatable({}, Entry)
  self.game = game
  self.title = opts.title or "ENTER CODE"
  self.shape = shape
  self.onDone = opts.onDone
  -- the grid has the Gen 1 glyphs, which are uppercase; a stored address is
  -- lowercase, and fromText blanks any character its charset does not hold,
  -- so an address has to be raised before it can be shown at all
  local default = opts.default
  if default and shape == Entry.ADDRESS then default = default:upper() end
  self.state = default
    and CodeEntry.fromText(default, shape)
    or CodeEntry.new(shape)
  self.isOpaque = true
  return self
end

function Entry:update()
  local input = self.game.input
  if input:wasPressed("b") then
    self.game.stack:pop()
  elseif input:wasPressed("up") then
    CodeEntry.up(self.state)
  elseif input:wasPressed("down") then
    CodeEntry.down(self.state)
  elseif input:wasPressed("left") then
    CodeEntry.left(self.state)
  elseif input:wasPressed("right") then
    CodeEntry.right(self.state)
  elseif input:wasPressed("a") then
    -- spaces are the address shape's padding, not part of the value
    local text = CodeEntry.text(self.state):gsub("%s+$", ""):gsub("^%s+", "")
    if self.shape == Entry.ADDRESS then text = text:lower() end
    self.game.stack:pop()
    if self.onDone then self.onDone(text) end
  end
end

function Entry:draw()
  local Font = require("src.render.Font")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(self.title, 8, 6)

  -- A hostname does not fit on one line at any readable pitch, so long
  -- shapes wrap.  The pitch and the per-row count both follow the slot
  -- count, and every row stays centred, so a 6-slot code and a 40-slot
  -- address are the same screen with different arithmetic.
  local n = self.state.length
  local pitch = n > 8 and 7 or 16
  local perRow = math.min(n, math.floor(152 / pitch))
  local rows = math.ceil(n / perRow)
  -- the cursor hangs 12px under its own character, so rows need more than
  -- that between them or it reads as if it belongs to the row below.  A
  -- single row lands on 64 either way, which is where the code screen has
  -- always drawn it.
  local ROW_PITCH = 26
  local topY = 64 - (rows - 1) * math.floor(ROW_PITCH / 2)
  for i = 1, n do
    local row = math.floor((i - 1) / perRow)
    local col = (i - 1) % perRow
    local inRow = math.min(perRow, n - row * perRow)
    local originX = math.floor((160 - inRow * pitch) / 2)
    local x = originX + col * pitch
    local y = topY + row * ROW_PITCH
    Font.draw(CodeEntry.charAt(self.state, i), x, y)
    if i == self.state.pos then
      Font.drawCode(0xEE, x, y + 12) -- the same cursor LinkState uses
    end
  end

  Font.draw("A: OK  B: BACK", 8, 112)
  Font.draw("UP/DOWN change", 8, 128)
end

return Entry
