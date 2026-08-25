-- Trainer skins (POK-79): the walk sheet every other trainer sees, and the
-- battle face that goes with it, unlocked by career wins.
--
-- Pure where it matters: the LADDER and the unlock arithmetic are plain
-- tables and functions so tests/br_test.lua can check the wardrobe without
-- an engine.  The Picker (new/update/draw) is the same state shape the
-- engine's own menus take on the stack, modeled on lib/fame.lua.
--
-- Every entry pairs an overworld sheet (data.sprites) with a trainer class
-- (data.trainers) whose front pic is the "what my opponent sees" preview.
-- RED is the original and has no class: you ARE the player sprite.

local Skins = {}

Skins.LADDER = {
  { id = "RED",       label = "RED",       walk = "SPRITE_RED",       class = nil,             wins = 0 },
  { id = "YOUNGSTER", label = "YOUNGSTER", walk = "SPRITE_YOUNGSTER", class = "OPP_YOUNGSTER", wins = 1 },
  { id = "LASS",      label = "LASS",      walk = "SPRITE_GIRL",      class = "OPP_LASS",      wins = 3 },
  { id = "SAILOR",    label = "SAILOR",    walk = "SPRITE_SAILOR",    class = "OPP_SAILOR",    wins = 5 },
  { id = "HIKER",     label = "HIKER",     walk = "SPRITE_HIKER",     class = "OPP_HIKER",     wins = 10 },
  { id = "CHANNELER", label = "CHANNELER", walk = "SPRITE_CHANNELER", class = "OPP_CHANNELER", wins = 15 },
  { id = "ROCKET",    label = "ROCKET",    walk = "SPRITE_ROCKET",    class = "OPP_ROCKET",    wins = 20 },
  { id = "GENTLEMAN", label = "GENTLEMAN", walk = "SPRITE_GENTLEMAN", class = "OPP_GENTLEMAN", wins = 25 },
  { id = "GIOVANNI",  label = "GIOVANNI",  walk = "SPRITE_GIOVANNI",  class = "OPP_GIOVANNI",  wins = 30 },
}

-- an unknown id is the original: a save poked by hand cannot brick the menu
function Skins.get(id)
  for _, e in ipairs(Skins.LADDER) do
    if e.id == id then return e end
  end
  return Skins.LADDER[1]
end

function Skins.isUnlocked(entry, wins)
  return (tonumber(wins) or 0) >= (entry and entry.wins or 0)
end

-- The trainer class a walk sprite belongs to, for the PvP battle pic
-- (POK-80): a peer advertises its walk sheet on the wire, and this maps it
-- back to the OPP_ class whose front pic the skin picker previews.  nil for
-- RED (no class -- you ARE the player) or an unrecognised sheet, so the
-- link battle keeps its vanilla RED default in those cases.
function Skins.classForWalk(walkId)
  if not walkId then return nil end
  for _, e in ipairs(Skins.LADDER) do
    if e.walk == walkId then return e.class end
  end
  return nil
end

-- what crossing from `before` to `after` wins just opened, for the banner
function Skins.justUnlocked(before, after)
  local out = {}
  for _, e in ipairs(Skins.LADDER) do
    if e.wins > 0 and (before or 0) < e.wins and e.wins <= (after or 0) then
      out[#out + 1] = e
    end
  end
  return out
end

-- ------- the picker
--
-- LEFT/RIGHT cycle the wardrobe.  Each page shows the walking sprite and
-- the trainer front pic side by side; a locked page draws both darkened
-- with the wins it costs.  A wears an unlocked skin (the menu stays up so
-- WORN is seen to move); B closes.

local Picker = {}
Picker.__index = Picker
Skins.Picker = Picker

function Picker.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, Picker)
  self.game = game
  self.wins = tonumber(opts.wins) or 0
  self.current = Skins.get(opts.current).id
  self.onPick = opts.onPick
  self.idx = 1
  for i, e in ipairs(Skins.LADDER) do
    if e.id == self.current then self.idx = i break end
  end
  self.cache = {}   -- walk sheet id -> { img, quad }
  return self
end

function Picker:update(dt)
  local input = self.game.input
  if not input then return end
  if input:wasPressed("left") then
    self.idx = ((self.idx - 2) % #Skins.LADDER) + 1
  elseif input:wasPressed("right") then
    self.idx = (self.idx % #Skins.LADDER) + 1
  elseif input:wasPressed("a") then
    local entry = Skins.LADDER[self.idx]
    if Skins.isUnlocked(entry, self.wins) then
      self.current = entry.id
      if self.onPick then self.onPick(entry.id) end
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    self.game.stack:pop()
  end
end

-- the standing frame of a walk sheet, cached; frame 0 is facing-down
function Picker:walkFrame(walkId)
  local hit = self.cache[walkId]
  if hit ~= nil then return hit or nil end
  local data = self.game.data
  local def = data and data.sprites and data.sprites[walkId]
  local ok, img = pcall(function()
    return love.graphics.newImage(def.image)
  end)
  if not (def and ok and img) then
    self.cache[walkId] = false
    return nil
  end
  local quad = love.graphics.newQuad(0, 0, 16, 16, img:getDimensions())
  self.cache[walkId] = { img = img, quad = quad }
  return self.cache[walkId]
end

function Picker:trainerPic(class)
  if not class then return nil end
  local key = "pic:" .. class
  local hit = self.cache[key]
  if hit ~= nil then return hit or nil end
  local data = self.game.data
  local ok, img = pcall(function()
    local BattleState = require("src.battle.BattleState")
    return BattleState.trainerSprite(data, data.trainers[class], class, 1)
  end)
  self.cache[key] = (ok and img) or false
  return self.cache[key] or nil
end

function Picker:draw()
  local g = love.graphics
  local Font = require("src.render.Font")
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, 160, 144)
  Font.drawBox(0, 0, 20, 18)
  local entry = Skins.LADDER[self.idx]
  local unlocked = Skins.isUnlocked(entry, self.wins)
  Font.draw("TRAINER SKIN", 32, 12)
  -- the font has no angle brackets; the pager reads as text
  Font.draw(("PAGE %d/%d"):format(self.idx, #Skins.LADDER), 44, 26)
  -- the two faces of the skin, dimmed while it is still a prize
  if not unlocked then g.setColor(0.35, 0.35, 0.4, 1) end
  local walk = self:walkFrame(entry.walk)
  if walk then g.draw(walk.img, walk.quad, 30, 56, 0, 2, 2) end
  local pic = self:trainerPic(entry.class)
  if pic then g.draw(pic, 84, 40) end
  g.setColor(1, 1, 1, 1)
  Font.draw(entry.label, 80 - #entry.label * 4, 100)
  if not unlocked then
    Font.draw(("UNLOCK: %d WINS"):format(entry.wins), 24, 114)
  elseif entry.id == self.current then
    Font.draw("WORN", 64, 114)
  else
    Font.draw("A: WEAR IT", 40, 114)
  end
  Font.draw(("WINS: %d"):format(self.wins), 8, 130)
  Font.draw("B: CLOSE", 96, 130)
end

return Skins
