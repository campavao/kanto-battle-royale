-- Free move management (POK-19), priced by POK-58: still any time outside
-- battle, from the party menu -- but the pool is earned.  Level-up moves
-- open with the mon's level (the D12 ladder unlocks them ring by ring),
-- and a machine move is offered only while its TM/HM sits in the bag.
--
-- A match hands you a disposable team under time pressure; the four moves
-- a wild catch happened to have are campaign friction in a mode with no
-- campaign.  HMs included: catch a water type, teach it SURF, cross the
-- water -- the traversal is still earned by catching the right Pokemon.

local Moves = {}

-- data/moves/hm_moves.asm (IsMoveHM)
Moves.HM = { CUT = true, FLY = true, SURF = true, STRENGTH = true, FLASH = true }

-- Everything this species can learn RIGHT NOW that it does not know yet:
-- its level-1 moves, learnset rows at or below the mon's level, and -- when
-- `opts.bag` is given -- machine moves whose TM/HM is in that bag (a TM
-- ignores the level gate, exactly like the cartridge).  In that order,
-- each move once.  { id=, name=, how=, item= }, where `how` is "L<n>",
-- "TM" or "HM", and `item` names the machine that pays for a machine row.
function Moves.learnable(data, mon, opts)
  local def = data and data.pokemon and mon and data.pokemon[mon.species]
  if not (def and data.moves) then return {} end
  local level = tonumber(mon.level) or 1
  local bag = opts and opts.bag
  local known = {}
  for _, mv in ipairs(mon.moves or {}) do known[mv.id] = true end
  local out, seen = {}, {}
  local function add(id, how, item)
    if not id or seen[id] or known[id] then return end
    local mdef = data.moves[id]
    if not mdef then return end
    seen[id] = true
    out[#out + 1] = { id = id, name = mdef.name or id, how = how, item = item }
  end
  for _, id in ipairs(def.level1Moves or {}) do add(id, "L1") end
  for _, entry in ipairs(def.learnset or {}) do
    if (tonumber(entry.level) or 1) <= level then
      add(entry.move, "L" .. tostring(entry.level or "?"))
    end
  end
  if bag then
    local machineFor = {}
    for itemId, it in pairs(data.items or {}) do
      local m = it.machine
      if m and m.move and (bag[itemId] or 0) > 0 then
        machineFor[m.move] = { item = itemId, kind = m.kind }
      end
    end
    for _, id in ipairs(def.tmhm or {}) do
      local mi = machineFor[id]
      if mi then add(id, mi.kind or (Moves.HM[id] and "HM" or "TM"), mi.item) end
    end
  end
  return out
end

-- Teach moveId into a free slot, or over slot `replace` (1-4) when all
-- four are taken.  Returns false when nothing was forgotten, the forgotten
-- move's id when one was, or nil + reason.
function Moves.teach(data, mon, moveId, replace)
  local mdef = data and data.moves and data.moves[moveId]
  if not (mon and mdef) then return nil, "no such move" end
  mon.moves = mon.moves or {}
  for _, mv in ipairs(mon.moves) do
    if mv.id == moveId then return nil, "already known" end
  end
  local slot = { id = moveId, pp = mdef.pp or 0 }
  if #mon.moves < 4 then
    mon.moves[#mon.moves + 1] = slot
    return false
  end
  local i = math.floor(tonumber(replace) or 0)
  if i < 1 or i > #mon.moves then return nil, "which move?" end
  local old = mon.moves[i].id
  mon.moves[i] = slot
  return old
end

return Moves
