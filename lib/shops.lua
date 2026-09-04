-- The stone counter (POK-178).
--
-- Celadon Dept. Store's 4F clerk sells FIRE, THUNDER, WATER and LEAF
-- STONEs; the MOON STONE is a hidden item in Kanto and never for sale.
-- In a match the stone lines (NIDORAN, CLEFAIRY, JIGGLYPUFF -- and the
-- zone draws them often) had no way up short of luck on the floor, so
-- for the length of a match the counter carries ALL five.  Pure: the
-- stock rule takes the clerk's text label and the mart's own list, so
-- br_test checks it without a map or a running match.

local Shops = {}

-- the counter, by the text entry's own label (data.textEntry)
Shops.STONE_COUNTER = "CeladonMart4FClerkText"

-- every evolution stone Kanto has
Shops.STONES = { "MOON_STONE", "FIRE_STONE", "THUNDER_STONE", "WATER_STONE", "LEAF_STONE" }

-- The MOON STONE's ROM price is 0 (it was never sold); on the counter it
-- costs what the other stones cost.
Shops.MOON_STONE_PRICE = 2100

-- The stock this clerk sells during a match, or nil when the clerk is
-- not the stone counter (every other mart is left exactly alone).  The
-- ROM's list stays in its order; the stones it lacks go on the end, each
-- once.
function Shops.stock(label, stock)
  if label ~= Shops.STONE_COUNTER then return nil end
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

-- Price the MOON STONE for the counter; returns what it was so the match
-- can put it back (game.data is shared with the real save).  A build
-- whose MOON STONE already has a price keeps it.
function Shops.priceMoonStone(data)
  local def = data and data.items and data.items.MOON_STONE
  if not def then return nil end
  local was = def.price
  if (was or 0) <= 0 then def.price = Shops.MOON_STONE_PRICE end
  return was or 0
end

function Shops.restoreMoonStone(data, was)
  local def = data and data.items and data.items.MOON_STONE
  if def and was ~= nil then def.price = was end
end

return Shops
