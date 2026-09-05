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

-- a bot's party: its RECORD (POK-158) at the rung -- the team it built
-- and the wounds it carries -- built into real Pokemon when the data is
-- there, so a spectator sees the stats and the moves the fight would.
-- With no record (an engine-data gap) it falls back to the old synth.
function Peek.botParty(Bots, seed, id, data, level, record)
  local party = {}
  local okP, Pokemon = pcall(require, "src.pokemon.Pokemon")
  local rows = {}
  if record then
    -- each line at what it has reached by this rung (POK-181), the same
    -- derivation the fight makes
    local stone, pick = Bots.stoneRung(seed, id)
    for _, m in ipairs(record) do
      rows[#rows + 1] = { species = Bots.evolveAt(data, m.species, level,
                            { stoneRung = stone, pick = pick, traded = m.traded }),
                          level = level, hpFrac = m.hpFrac }
    end
  else
    rows = Bots.party(seed, id, data, level) or {}
  end
  for i, mon in ipairs(rows) do
    if i > 6 then break end
    local built = mon
    if okP and data and data.pokemon and data.pokemon[mon.species] and Pokemon.new then
      local okB, real = pcall(Pokemon.new, data, mon.species, mon.level or level or 5)
      if okB and real then built = real end
    end
    local m = monSummary(built)
    local frac = mon.hpFrac or 1
    m.hp = math.floor(m.maxHp * frac + 0.5)
    if frac > 0 and m.hp < 1 then m.hp = 1 end
    party[#party + 1] = m
  end
  return party
end

-- ------- views for the real screens (POK-53)

-- a party the engine's own PartyMenu can draw: save-mon lookalikes built
-- from the summaries -- only species the receiver's data knows, and
-- stats.hp synthesized for the HP bar.  The screen is the vanilla one;
-- just the data is borrowed.
function Peek.saveView(data, party)
  local view = {}
  for _, m in ipairs(party or {}) do
    if data and data.pokemon and data.pokemon[m.species] then
      view[#view + 1] = {
        species = m.species,
        level = m.level or 1,
        hp = math.max(0, m.hp or 0),
        status = m.status,
        stats = { hp = math.max(1, m.maxHp or 1) },
        moves = m.moves,
      }
    end
  end
  return view
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

-- rows in BagMenu's own shape, for the vanilla floating item box: the
-- item name, "xN" on the right, and the money as a last row of its own.
-- Empty stays empty -- the item box prints the engine's "Nothing here."
function Peek.itemRows(data, items, money)
  local rows = {}
  for _, it in ipairs(items or {}) do
    local def = data and data.items and data.items[it.id]
    rows[#rows + 1] = { value = it.id,
                        label = (def and def.name) or tostring(it.id),
                        right = "x" .. tostring(it.n or 0) }
  end
  if (money or 0) > 0 then rows[#rows + 1] = { label = ("¥%d"):format(money) } end
  return rows
end

return Peek
