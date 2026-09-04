-- The Hall of Fame (POK-47): the winner's team, one Pokemon at a time --
-- sprite, cry, name and level, the way the game crowns a Champion -- and
-- then the record of the run.  Winner-only, local data, nothing on the
-- wire.  Closing the last page calls `onDone`, because the parade is the
-- end of the match and not merely the end of a screen (POK-82).
--
-- Pure where it can be: Fame.pages and Fame.cardLines are plain functions
-- over plain tables, so the tests can check the parade order and the card
-- without a screen.  The state object (new/update/draw) is the same shape
-- the engine's own DexEntryMenu takes on the stack.

local Fame = {}
Fame.__index = Fame

Fame.MON_SECONDS = 3     -- a parade page turns itself, or on A

function Fame.timeString(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- one page per party Pokemon -- the fainted included, they carried the run
-- too -- then the record card
function Fame.pages(party, stats)
  local out = {}
  for _, mon in ipairs(party or {}) do
    if mon.species then
      out[#out + 1] = { kind = "mon", species = mon.species,
                        name = mon.nickname or mon.species,
                        level = mon.level or 1 }
    end
  end
  out[#out + 1] = { kind = "card", lines = Fame.cardLines(stats) }
  return out
end

function Fame.cardLines(stats)
  local s = stats or {}
  return {
    { "CAUGHT", tostring(s.catches or 0) },
    { "BEAT",   tostring(s.beats or 0) },
    { "STEPS",  tostring(s.steps or 0) },
    { "RINGS",  tostring(s.rings or 1) },
    { "TIME",   Fame.timeString(s.seconds) },
    { "MONEY",  tostring(s.money or 0) },
  }
end

-- ------- the screen

function Fame.new(game, party, stats, onDone)
  local self = setmetatable({ game = game, pages = Fame.pages(party, stats),
                              i = 0, t = 0, onDone = onDone }, Fame)
  self:advance()
  return self
end

function Fame:showPage(page)
  self.sprite = nil
  if page.kind ~= "mon" then return end
  local ok, Sprites = pcall(require, "src.pokemon.Sprites")
  if ok and Sprites and Sprites.path then
    local path = Sprites.path(self.game.data, page.species, "front", { kind = "dex" })
    if path then
      local okImg, img = pcall(love.graphics.newImage, path)
      if okImg then self.sprite = img end
    end
  end
  pcall(function()
    require("src.core.Sound").playCry(self.game.data, page.species)
  end)
end

function Fame:advance()
  self.i = self.i + 1
  self.t = 0
  local page = self.pages[self.i]
  if not page then
    self.game.stack:pop()
    -- the parade is the end of the run, not just a screen: whoever
    -- pushed it decides where the champion goes next (POK-82).  Shielded
    -- because it runs after the pop -- a throw here would strand them on
    -- a screen that is already gone.
    if self.onDone then pcall(self.onDone) end
    return
  end
  self:showPage(page)
end

function Fame:update(dt)
  local page = self.pages[self.i]
  if not page then return end
  self.t = self.t + (dt or 0)
  local input = self.game.input
  if input and (input:wasPressed("a") or input:wasPressed("b")) then
    self:advance()
  elseif page.kind == "mon" and self.t >= Fame.MON_SECONDS then
    self:advance()   -- the parade walks itself; the card waits for A
  end
end

function Fame:draw()
  local g = love.graphics
  local Font = require("src.render.Font")
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, 160, 144)
  g.setColor(1, 1, 1, 1)
  local page = self.pages[self.i]
  if not page then return end
  Font.drawBox(0, 0, 20, 18)
  if page.kind == "mon" then
    Font.draw("HALL OF FAME", 32, 16)
    if self.sprite then g.draw(self.sprite, 52, 36) end
    -- No level (POK-168).  POK-111 hid levels from the battle HUD, the
    -- party and the summary for the length of a match, and this parade is
    -- only ever shown at the end of one -- the roll shows the team the way
    -- the match let its trainer see it.
    Font.draw(tostring(page.name), 36, 104)
  else
    Font.draw("MATCH RECORD", 32, 16)
    local y = 36
    for _, row in ipairs(page.lines) do
      Font.draw(row[1], 24, y)
      Font.draw(row[2], 136 - #row[2] * 8, y)
      y = y + 12
    end
    Font.draw("A: CLOSE", 48, 124)
  end
end

return Fame
