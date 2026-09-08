-- The shops during a match: the stone counter (POK-178) and the tiered
-- general stores (POK-192).
--
-- POK-178.  Celadon Dept. Store's 4F clerk sells FIRE, THUNDER, WATER and
-- LEAF STONEs; the MOON STONE is a hidden item in Kanto and never for
-- sale.  In a match the stone lines (NIDORAN, CLEFAIRY, JIGGLYPUFF -- and
-- the zone draws them often) had no way up short of luck on the floor, so
-- for the length of a match the counter carries ALL five.
--
-- POK-192.  Every other Mart sold exactly its vanilla list, so a Viridian
-- drop shopped POKe BALL and POTION while a Celadon drop shopped far
-- better -- the story's flow, not the match's.  Now every general store
-- sells the same tier, and the tier climbs on the FOG'S PHASE: the one
-- clock the match has (lib/levels.lua indexes its rungs by it too, "ONE
-- CLOCK, NOT TWO"), announced by the host and held by every client, so a
-- shrink, a power spike and a better shelf are the same beat.  Balls
-- climb POKe -> GREAT -> ULTRA -> MASTER and potions POTION -> SUPER ->
-- HYPER -> MAX, cumulatively: a late shelf still carries the cheap rungs,
-- so money stays a decision rather than a threshold.  Where you dropped
-- stops deciding what you can buy.
--
-- Pure: every rule takes the clerk's text label, the mart's own list and
-- the phase, so br_test checks it without a map or a running match.
-- Nothing here mutates a list; the prices it sets (game.data is shared
-- with the real save) come with a restore, and resetMatch calls it on
-- every exit.

local Shops = {}

-- ------- the stone counter (POK-178)

-- the counter, by the text entry's own label (data.textEntry)
Shops.STONE_COUNTER = "CeladonMart4FClerkText"

-- every evolution stone Kanto has
Shops.STONES = { "MOON_STONE", "FIRE_STONE", "THUNDER_STONE", "WATER_STONE", "LEAF_STONE" }

-- The MOON STONE's ROM price is 0 (it was never sold); on the counter it
-- costs what the other stones cost.
Shops.MOON_STONE_PRICE = 2100

-- ------- the tiered stores (POK-192)

-- The ladders, one rung per tier.  A store at tier t sells rungs 1..t.
Shops.BALLS   = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "MASTER_BALL" }
Shops.POTIONS = { "POTION", "SUPER_POTION", "HYPER_POTION", "MAX_POTION" }
-- ...and what comes onto the shelf beside them at each tier: a REVIVE
-- once teams are worth reviving, a FULL HEAL once status decides
-- fights, a FULL RESTORE at the top.  Cumulative like the ladders.
Shops.EXTRAS  = { {}, { "REVIVE" }, { "FULL_HEAL" }, { "FULL_RESTORE" } }

-- The tier at each fog phase; past the end of the table, the last.
-- Phase 1 is the drop and 2 the first shrink -- both still POKe BALLs
-- and POTIONs, the way the level ladder's Lv5 and Lv15 are still the
-- opening.  GREAT at the Lv30 rung, ULTRA at Lv50, MASTER from Lv75:
-- the shelf reads like the ladder because it IS the ladder's clock.
Shops.TIER_AT = { 1, 1, 2, 3, 4 }

-- The MASTER BALL's ROM price is 0 (never sold); on a match shelf it is
-- the most expensive thing in Kanto short of a bike.  A dropped rival's
-- ball is a gift, not a catch, so this only ever buys a wild Pokemon --
-- a convenience priced as a real decision, and there is no per-shop
-- count in the engine's mart, so the price is the only limiter.
Shops.MASTER_BALL_PRICE = 5000

function Shops.tier(phase)
  local i = math.floor(tonumber(phase) or 1)
  if i < 1 then i = 1 end
  if i > #Shops.TIER_AT then i = #Shops.TIER_AT end
  return Shops.TIER_AT[i]
end

-- every item any ladder ever sells, for stripping a ROM list of them
local LADDERED = {}
for _, id in ipairs(Shops.BALLS) do LADDERED[id] = true end
for _, id in ipairs(Shops.POTIONS) do LADDERED[id] = true end
for _, tier in ipairs(Shops.EXTRAS) do
  for _, id in ipairs(tier) do LADDERED[id] = true end
end

-- Is this mart a general store?  One that sells a ball or a potion in
-- the ROM.  Celadon's specialty counters (TMs, vitamins, X items, the
-- stones) sell neither and are left exactly alone.
function Shops.isStore(stock)
  for _, id in ipairs(stock or {}) do
    if LADDERED[id] then return true end
  end
  return false
end

-- The shelf at a tier: the ladders' rungs 1..tier, balls then potions
-- then the extras, and after them whatever else the ROM's list sold, in
-- its order, minus anything a ladder already covers.
function Shops.tiered(stock, tier)
  tier = tier or 1
  local out, seen = {}, {}
  local function add(id)
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  for t = 1, tier do if Shops.BALLS[t] then add(Shops.BALLS[t]) end end
  for t = 1, tier do if Shops.POTIONS[t] then add(Shops.POTIONS[t]) end end
  for t = 1, tier do
    for _, id in ipairs(Shops.EXTRAS[t] or {}) do add(id) end
  end
  for _, id in ipairs(stock or {}) do
    if not LADDERED[id] then add(id) end
  end
  return out
end

-- The stock a clerk sells during a match, or nil when the clerk is
-- neither the stone counter nor a general store (left exactly alone).
-- `phase` is the fog's; nil is the drop.
function Shops.stock(label, stock, phase)
  if label == Shops.STONE_COUNTER then
    -- the ROM's list stays in its order; the stones it lacks go on the
    -- end, each once
    local out, seen = {}, {}
    for _, id in ipairs(stock or {}) do
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
    for _, id in ipairs(Shops.STONES) do
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
    return out
  end
  if Shops.isStore(stock) then return Shops.tiered(stock, Shops.tier(phase)) end
  return nil
end

-- ------- prices

-- What a match prices that the ROM never sold, and what it costs there.
Shops.PRICES = { MOON_STONE = Shops.MOON_STONE_PRICE,
                 MASTER_BALL = Shops.MASTER_BALL_PRICE }

-- Price them for the match; returns what they were, keyed by id, so the
-- match can put them back (game.data is shared with the real save).  A
-- build whose item already has a price keeps it.  nil with no items.
function Shops.price(data)
  local items = data and data.items
  if not items then return nil end
  local was = {}
  for id, price in pairs(Shops.PRICES) do
    local def = items[id]
    if def then
      was[id] = def.price or 0
      if (def.price or 0) <= 0 then def.price = price end
    end
  end
  return was
end

function Shops.restore(data, was)
  local items = data and data.items
  if not (items and was) then return end
  for id, price in pairs(was) do
    if items[id] then items[id].price = price end
  end
end

-- the POK-178 names, kept for the driver and anything else that learned them
function Shops.priceMoonStone(data)
  local was = Shops.price(data)
  return was and was.MOON_STONE
end
function Shops.restoreMoonStone(data, was)
  if was ~= nil then Shops.restore(data, { MOON_STONE = was }) end
end

return Shops
