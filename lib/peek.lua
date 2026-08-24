-- What a spectator may see of the trainer they watch (POK-18): a summary
-- of the party and the bag, on request.
--
-- Pull, not push: only a spectator asks (`peek`), and only the one trainer
-- they watch answers (`state`), so nothing rides on everybody's presence
-- stream and the size of a six-Pokemon summary is paid by two clients at a
-- time.  The summary carries what a spectator wants to know -- species,
-- level, HP, status, moves, the bag, the money -- and nothing that would
-- let them rebuild the record (no DVs, no EXP).  A bot has no client to
-- ask, so its state is derived the way its team already is.

local Peek = {}

Peek.SECONDS = 3   -- how often a spectator re-asks while watching

local function monSummary(mon)
  local moves = {}
  for j, mv in ipairs(mon.moves or {}) do
    if j > 4 then break end
    local id = type(mv) == "table" and mv.id or mv
    if type(id) == "string" then moves[#moves + 1] = id end
  end
  local maxHp = (mon.stats and mon.stats.hp) or mon.maxHp or mon.hp or 1
  return {
    species = mon.species, level = mon.level or 1,
    hp = math.max(0, math.floor(mon.hp or 0)),
    maxHp = math.max(1, math.floor(maxHp)),
    status = mon.status, moves = moves,
  }
end

-- the answer a trainer gives: their party and, from the caller, their bag
-- ({ items = { { id, n } }, money }) -- badges and HMs already left out
function Peek.summary(save, bag)
  local party = {}
  for i, mon in ipairs((save and save.party) or {}) do
    if i > 6 then break end
    if mon.species then party[#party + 1] = monSummary(mon) end
  end
  return { party = party, items = (bag and bag.items) or {}, money = (bag and bag.money) or 0 }
end

-- a bot's party, derived: its team at the rung, at full HP.  Bots.party
-- hands back species and level; the fight builds the real Pokemon from
-- them, and so does this, when the data is there to build from -- a
-- spectator should see the stats and the moves the fight would.
function Peek.botParty(Bots, seed, id, data, level)
  local party = {}
  local okP, Pokemon = pcall(require, "src.pokemon.Pokemon")
  for i, mon in ipairs(Bots.party(seed, id, data, level) or {}) do
    if i > 6 then break end
    local built = mon
    if okP and data and data.pokemon and data.pokemon[mon.species] and Pokemon.new then
      local okB, real = pcall(Pokemon.new, data, mon.species, mon.level or level or 5)
      if okB and real then built = real end
    end
    local m = monSummary(built)
    m.hp = m.maxHp
    party[#party + 1] = m
  end
  return party
end

-- ------- rows for a ListMenu

local function speciesName(data, species)
  local def = data and data.pokemon and data.pokemon[species]
  return (def and def.name) or tostring(species)
end

-- "PIDGEY L12" with "23/40" -- and the status, when there is one
function Peek.partyRows(data, party)
  local rows = {}
  for i, m in ipairs(party or {}) do
    local right = ("%d/%d"):format(m.hp or 0, m.maxHp or 0)
    if m.status then right = right .. " " .. tostring(m.status):sub(1, 3) end
    rows[#rows + 1] = { label = ("%s L%d"):format(speciesName(data, m.species), m.level or 1),
                        right = right, value = i }
  end
  if #rows == 0 then rows[1] = { label = "(no POKeMON)" } end
  return rows
end

function Peek.moveRows(data, mon)
  local rows = {}
  for _, id in ipairs((mon and mon.moves) or {}) do
    local def = data and data.moves and data.moves[id]
    rows[#rows + 1] = { label = (def and def.name) or tostring(id) }
  end
  if #rows == 0 then rows[1] = { label = "(no moves)" } end
  return rows
end

-- "POTION" with "x2", and the money as its own row
function Peek.bagRows(data, items, money)
  local rows = {}
  for _, it in ipairs(items or {}) do
    local def = data and data.items and data.items[it.id]
    rows[#rows + 1] = { label = (def and def.name) or tostring(it.id), right = "x" .. tostring(it.n or 0) }
  end
  if (money or 0) > 0 then rows[#rows + 1] = { label = ("¥%d"):format(money) } end
  if #rows == 0 then rows[1] = { label = "(nothing)" } end
  return rows
end

return Peek
