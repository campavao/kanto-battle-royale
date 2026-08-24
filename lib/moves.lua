-- Free move management (POK-19): any move a Pokemon could learn, any time
-- outside battle, from the party menu.  No tutor, no TM item, no ceremony.
--
-- A match hands you a disposable team under time pressure; the four moves
-- a wild catch happened to have are campaign friction in a mode with no
-- campaign.  HMs included: catch a water type, teach it SURF, cross the
-- water -- the traversal is still earned by catching the right Pokemon.

local Moves = {}

-- data/moves/hm_moves.asm (IsMoveHM)
Moves.HM = { CUT = true, FLY = true, SURF = true, STRENGTH = true, FLASH = true }

-- Everything this species can learn that it does not know yet: its level-1
-- moves, the level-up learnset at any level, and every TM/HM it is
-- compatible with -- in that order, each once.  { id=, name=, how= },
-- where `how` is "L<n>" for a level-up move, "HM" or "TM" for a machine.
function Moves.learnable(data, mon)
  local def = data and data.pokemon and mon and data.pokemon[mon.species]
  if not (def and data.moves) then return {} end
  local known = {}
  for _, mv in ipairs(mon.moves or {}) do known[mv.id] = true end
  local out, seen = {}, {}
  local function add(id, how)
    if not id or seen[id] or known[id] then return end
    local mdef = data.moves[id]
    if not mdef then return end
    seen[id] = true
    out[#out + 1] = { id = id, name = mdef.name or id, how = how }
  end
  for _, id in ipairs(def.level1Moves or {}) do add(id, "L1") end
  for _, entry in ipairs(def.learnset or {}) do
    add(entry.move, "L" .. tostring(entry.level or "?"))
  end
  for _, id in ipairs(def.tmhm or {}) do add(id, Moves.HM[id] and "HM" or "TM") end
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
