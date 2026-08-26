-- TMs and HMs that say what they teach (POK-110).
--
-- Vanilla Kanto calls them TM01..TM50 and HM01..HM05, which is a lookup
-- table you are expected to have memorised or to own a guide for.  In a
-- twenty-minute match nobody is looking anything up: a TM is loot you
-- either grab or walk past, and "TM19" tells you nothing about whether it
-- is worth the detour.  So for the length of a match every machine is
-- named after the move it teaches, and TM19 reads SEISMIC TOSS.
--
-- Just the move, with no number in front.  The number is the part nobody
-- can read anything off; carrying it would also cost five characters of a
-- box that already has to fit a quantity beside the name.  SEISMIC TOSS is
-- the longest of the 55 at twelve characters, which vanilla already spends
-- on FULL RESTORE and THUNDERSTONE.
--
-- This is a DATA rename rather than a UI hook, because the bag draws
-- `game.data.items[id].name` straight (src/ui/BagMenu.lua) -- and so does
-- every loot line, a fallen trainer's bag, the shop and the MOVES row.
-- One rename covers all of them and there is no seam that would.
--
-- The catch, and the reason apply() hands back what it changed: game.data
-- is the ENGINE's, shared with the player's real save, not something the
-- match owns.  A rename left behind would follow them out of the match and
-- into an ordinary game.  So every exit restores.

local Machines = {}

-- The move a machine teaches, by name, or nil if this is not a machine (or
-- the build has no such move -- a rename is never worth an assert).
function Machines.nameFor(data, def)
  local machine = type(def) == "table" and def.machine
  local moveId = type(machine) == "table" and machine.move
  if type(moveId) ~= "string" then return nil end
  local moves = type(data) == "table" and data.moves
  local move = type(moves) == "table" and moves[moveId]
  local name = type(move) == "table" and move.name
  if type(name) ~= "string" or name == "" then return nil end
  return name
end

-- Rename every machine in `data.items`, and return a table of exactly what
-- was changed: item id -> the name it had.  That table is the ONLY way
-- back, so a caller must hold it until it restores.
--
-- Only items whose current name is a string are touched, so `saved` can
-- never carry a nil that would silently drop an entry and strand a rename.
-- Calling twice without restoring in between is a no-op the second time
-- (the names already match), which means the second call's `saved` is
-- EMPTY -- a caller that overwrote its first one with it would lose the
-- way back, so guard the call site rather than relying on this.
function Machines.apply(data)
  local saved = {}
  local items = type(data) == "table" and data.items
  if type(items) ~= "table" then return saved end
  for id, def in pairs(items) do
    local name = Machines.nameFor(data, def)
    if name and type(def.name) == "string" and def.name ~= name then
      saved[id] = def.name
      def.name = name
    end
  end
  return saved
end

-- Put back what apply() changed.  Returns how many it restored, which is
-- what a log line wants; an item that has since vanished is skipped rather
-- than recreated.
function Machines.restore(data, saved)
  local items = type(data) == "table" and data.items
  if type(items) ~= "table" or type(saved) ~= "table" then return 0 end
  local n = 0
  for id, name in pairs(saved) do
    local def = items[id]
    if type(def) == "table" and type(name) == "string" then
      def.name = name
      n = n + 1
    end
  end
  return n
end

return Machines
