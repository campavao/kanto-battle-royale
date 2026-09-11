-- A trainer's own battle text (2026-09-10): what the fight says when they
-- walk up to you, when they beat you, and when you beat them.
--
-- Three lines, each up to two rows of eighteen -- the battle box's own
-- width -- typed on the Gen 1 naming grid from the ROYALE menu.  The
-- intro REPLACES "X wants to fight!" on the other trainer's screen; the
-- outro replaces "X wins!": after "X is out of POKeMON!" comes the
-- winner's win line, then the loser's lose line, one page each.  A line
-- nobody set falls back to the vanilla page, so a trainer with none is
-- exactly the trainer of yesterday.
--
-- The lines ride the challenge and the accept (lib/wire.lua), so each side
-- holds the other's before the lockstep opens, with no relay change and
-- no roster field; a client that predates them ignores the extra key.
-- They live in the career file beside the name and the skin.
--
-- Pure: strings in, strings out, so br_test pins the clip, the file and
-- the wire shapes, and the page arithmetic.

local Lines = {}

Lines.WIDTH = 18
Lines.ROWS = 2
Lines.KINDS = { "intro", "win", "lose" }

-- the first `n` characters of a UTF-8 string, never a torn sequence
local function clip(s, n)
  local out, count = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if count >= n then break end
    out[#out + 1] = ch
    count = count + 1
  end
  return table.concat(out)
end

-- One line, canonical: rows joined by "\n", each trimmed and clipped to
-- WIDTH, at most ROWS of them, control characters gone.  nil for nothing.
function Lines.clean(v)
  if type(v) ~= "string" then return nil end
  local rows = {}
  for row in (v .. "\n"):gmatch("(.-)\n") do
    row = row:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if row ~= "" and #rows < Lines.ROWS then
      rows[#rows + 1] = clip(row, Lines.WIDTH)
    end
  end
  if #rows == 0 then return nil end
  return table.concat(rows, "\n")
end

-- A set of them, cleaned; nil when none is set.
function Lines.cleanSet(t)
  if type(t) ~= "table" then return nil end
  local out, any = {}, false
  for _, k in ipairs(Lines.KINDS) do
    local c = Lines.clean(t[k])
    if c then out[k] = c; any = true end
  end
  return any and out or nil
end

-- ------- the wire: short keys, and nothing at all when nothing is set

function Lines.pack(t)
  local c = Lines.cleanSet(t)
  if not c then return nil end
  return { i = c.intro, w = c.win, l = c.lose }
end

function Lines.unpack(m)
  if type(m) ~= "table" then return nil end
  return Lines.cleanSet({ intro = m.i, win = m.w, lose = m.l })
end

-- ------- the file: a keyfile value is one row, so "|" stands for the break

function Lines.toFile(text)
  local c = Lines.clean(text)
  return c and (c:gsub("\n", "|")) or nil
end

function Lines.fromFile(v)
  if type(v) ~= "string" then return nil end
  return Lines.clean((v:gsub("|", "\n")))
end

-- the rows of one line, for an entry screen to edit
function Lines.rows(text)
  local out = {}
  local c = Lines.clean(text)
  if not c then return out end
  for row in (c .. "\n"):gmatch("(.-)\n") do out[#out + 1] = row end
  return out
end

-- ------- what the fight says

-- the other trainer's intro, or nil for the vanilla page
function Lines.intro(theirs)
  return theirs and theirs.intro or nil
end

-- The vanilla outro is "<loser> is out of\nPOKeMON!\f<winner> wins!".  The
-- first page stays; the winner's win line takes the second (else the
-- vanilla "wins!" page); the loser's lose line, if any, is a third.
-- `iWon` says whose win it was; `mine` and `theirs` are the two sets.
function Lines.outro(text, iWon, mine, theirs)
  if type(text) ~= "string" then return text end
  local first, rest = text:match("^(.-)\f(.*)$")
  if not first then return text end
  local winner = iWon and mine or theirs
  local loser = iWon and theirs or mine
  local pages = { first, (winner and winner.win) or rest }
  if loser and loser.lose then pages[#pages + 1] = loser.lose end
  return table.concat(pages, "\f")
end

-- is this the vanilla outro line?  (the wrap asks before rewriting)
function Lines.isOutro(text)
  return type(text) == "string" and text:find("is out of", 1, true) ~= nil
         and text:find("wins!", 1, true) ~= nil
end

-- ------- the corpus: Kanto's own lines, to pick from
--
-- Typing on the Gen 1 grid is slow enough that the user set one line and
-- gave up on the other two (2026-09-11).  So a line is CHOSEN, not typed:
-- every page of dialogue in the ROM that fits the box -- two rows of
-- eighteen, no RAM placeholder -- sorted into four shelves.  Trainer
-- intros (what a route trainer says before the fight) make intros;
-- what a beaten trainer says makes lose lines; what they say afterwards,
-- and what the townsfolk say, make anything.  Deduplicated across the
-- shelves in that order, sorted within, built once per data table.

Lines.SHELVES = {
  { key = "battle", label = "TRAINER INTROS" },
  { key = "won",    label = "BEATEN TRAINERS" },
  { key = "after",  label = "AFTER A FIGHT" },
  { key = "npc",    label = "TOWNSFOLK" },
}

local corpusFor = setmetatable({}, { __mode = "k" })

-- one page of ROM text as a line, or nil when it does not fit
local function pageLine(page)
  if type(page) ~= "string" or page:find("{", 1, true) then return nil end
  page = page:gsub("\11", "\n")
  local rows = {}
  for r in (page .. "\n"):gmatch("(.-)\n") do
    r = r:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if r ~= "" then rows[#rows + 1] = r end
  end
  if #rows == 0 or #rows > Lines.ROWS then return nil end
  for _, r in ipairs(rows) do
    local n = 0
    for _ in r:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    if n > Lines.WIDTH then return nil end
  end
  local line = table.concat(rows, "\n")
  return Lines.clean(line) == line and line or nil
end

function Lines.corpus(data)
  if type(data) ~= "table" then return nil end
  local hit = corpusFor[data]
  if hit then return hit end
  local text = data.text or {}
  local shelves, seen = {}, {}
  local byKey = {}
  for _, s in ipairs(Lines.SHELVES) do
    local shelf = { key = s.key, label = s.label, lines = {} }
    shelves[#shelves + 1] = shelf
    byKey[s.key] = shelf
  end
  local function take(shelf, str)
    if type(str) ~= "string" then return end
    for page in (str .. "\f"):gmatch("(.-)\f") do
      local line = pageLine(page)
      if line and not seen[line] then
        seen[line] = true
        shelf.lines[#shelf.lines + 1] = line
      end
    end
  end
  -- the trainers first, one header key per shelf, in shelf order
  for _, key in ipairs({ "battle", "won", "after" }) do
    for _, perMap in pairs(data.trainer_headers or {}) do
      for _, h in pairs(perMap) do
        if type(h) == "table" then take(byKey[key], text[h[key]]) end
      end
    end
  end
  -- then everyone with a line and no counter
  for _, perMap in pairs(data.text_pointers or {}) do
    for _, e in pairs(perMap) do
      if type(e) == "table" and e.text and not (e.nurse or e.mart or e.pc or e.cableClub) then
        take(byKey.npc, text[e.text])
      end
    end
  end
  for _, shelf in ipairs(shelves) do table.sort(shelf.lines) end
  corpusFor[data] = shelves
  return shelves
end

-- where a line sits in the corpus (shelf index, line index), or 1, 1
function Lines.locate(shelves, line)
  for si, shelf in ipairs(shelves or {}) do
    for li, l in ipairs(shelf.lines) do
      if l == line then return si, li end
    end
  end
  return 1, 1
end

-- ------- the picker screen
--
-- A stack state, like Skins.Picker: the line on show in a Gen 1 text box
-- at the bottom of the screen, the shelf and the count above it.
-- LEFT/RIGHT step a line (held, they run); UP/DOWN change shelf; SELECT
-- deals a random one; A takes it; B leaves it as it was.

local Picker = {}
Picker.__index = Picker
Lines.Picker = Picker

Picker.REPEAT_AFTER = 18   -- frames a direction is held before it runs
Picker.REPEAT_EVERY = 3

-- opts: { title=, shelves=, current=, onPick= }
function Picker.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, Picker)
  self.game = game
  self.title = opts.title or "LINE"
  self.shelves = opts.shelves or Lines.corpus(game and game.data) or {}
  self.onPick = opts.onPick
  self.si, self.li = Lines.locate(self.shelves, opts.current)
  self.held, self.heldFor = nil, 0
  self.isOpaque = true
  return self
end

function Picker:shelf() return self.shelves[self.si] end
function Picker:line()
  local shelf = self:shelf()
  return shelf and shelf.lines[self.li] or nil
end

function Picker:step(d)
  local shelf = self:shelf()
  local n = shelf and #shelf.lines or 0
  if n == 0 then return end
  self.li = ((self.li - 1 + d) % n) + 1
end

function Picker:update(dt)
  local input = self.game.input
  if not input then return end
  if input:wasPressed("a") then
    local line = self:line()
    self.game.stack:pop()
    if line and self.onPick then self.onPick(line) end
    return
  end
  if input:wasPressed("b") or input:wasPressed("start") then
    self.game.stack:pop()
    return
  end
  if input:wasPressed("up") then
    self.si = ((self.si - 2) % #self.shelves) + 1
    self.li = 1
  elseif input:wasPressed("down") then
    self.si = (self.si % #self.shelves) + 1
    self.li = 1
  elseif input:wasPressed("select") then
    local shelf = self:shelf()
    if shelf and #shelf.lines > 0 then self.li = math.random(1, #shelf.lines) end
  end
  -- a held direction runs after a beat, the way a list scrolls
  local dir = (input.state and input.state.left and "left")
           or (input.state and input.state.right and "right") or nil
  if input:wasPressed("left") then self:step(-1) self.held, self.heldFor = "left", 0
  elseif input:wasPressed("right") then self:step(1) self.held, self.heldFor = "right", 0
  elseif dir and dir == self.held then
    self.heldFor = self.heldFor + 1
    if self.heldFor >= Picker.REPEAT_AFTER
       and (self.heldFor - Picker.REPEAT_AFTER) % Picker.REPEAT_EVERY == 0 then
      self:step(dir == "left" and -1 or 1)
    end
  else
    self.held, self.heldFor = nil, 0
  end
end

function Picker:draw()
  local g = love.graphics
  local Font = require("src.render.Font")
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, 160, 144)
  Font.drawBox(0, 0, 20, 12)
  local shelf = self:shelf()
  local n = shelf and #shelf.lines or 0
  Font.draw(self.title, 80 - #self.title * 4, 12)
  if shelf then
    Font.draw(shelf.label, 80 - #shelf.label * 4, 32)
    Font.draw(("%d/%d"):format(self.li, n), 80 - #(("%d/%d"):format(self.li, n)) * 4, 44)
  end
  Font.draw("UP/DOWN: SHELF", 8, 62)
  Font.draw("SELECT: RANDOM", 8, 72)
  Font.draw("A: TAKE IT", 8, 82)
  -- the line, in the box it will be read from
  Font.drawBox(0, 12, 20, 6)
  local line = self:line()
  if line then
    local y = 112
    for row in (line .. "\n"):gmatch("(.-)\n") do
      Font.draw(row, 8, y)
      y = y + 16
    end
  end
end

return Lines
