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
-- a dotted IPv4 plus a port fits in 21 slots; trailing blanks are trimmed
-- on confirm so "10.0.0.5:7790" does not have to be padded out by hand
Entry.ADDRESS = { charset = "0123456789.: ", length = 21 }

-- opts: { title=, shape=Entry.CODE|Entry.ADDRESS, default=, onDone= }
function Entry.new(game, opts)
  opts = opts or {}
  local shape = opts.shape or Entry.CODE
  local self = setmetatable({}, Entry)
  self.game = game
  self.title = opts.title or "ENTER CODE"
  self.shape = shape
  self.onDone = opts.onDone
  self.state = opts.default
    and CodeEntry.fromText(opts.default, shape)
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

  -- 21 address slots do not fit at the code screen's 16px pitch, so the
  -- pitch follows the slot count and the row stays centred either way
  local n = self.state.length
  local pitch = n > 8 and 7 or 16
  local originX = math.floor((160 - n * pitch) / 2)
  for i = 1, n do
    local x = originX + (i - 1) * pitch
    Font.draw(CodeEntry.charAt(self.state, i), x, 64)
    if i == self.state.pos then
      Font.drawCode(0xEE, x, 76) -- the same cursor LinkState uses
    end
  end

  Font.draw("A: OK  B: BACK", 8, 112)
  Font.draw("UP/DOWN change", 8, 128)
end

return Entry
