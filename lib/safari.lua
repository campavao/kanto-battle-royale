-- The Safari opening's rotating pool (POK-118).
--
-- The two minutes in the zone are where a whole run is decided: whatever
-- you catch there is the team you drop with, and party-is-health means it
-- is also your life total.  Running that draft off the ROM's own Safari
-- table made every match open the same way -- the same handful of species,
-- the same obvious best pick, the same opening fight.
--
-- So the pool ROTATES: each match draws its own set of species from the
-- match seed.  Derived, never sent -- the seed is already on every client
-- (lib/wire.lua's `start`), exactly as bot names, bot teams, bot faces and
-- the ring's eye are.  Everyone drafts from the same list without a byte
-- crossing the wire, and nobody can be handed a better zone than anybody
-- else.
--
-- Pure over plain tables: pool() and pick() take a seed and a data handle
-- and return species names, so br_test checks the rotation without a ROM,
-- a map, or a running match.

local Spawn = require("mods.battle_royale.lib.spawn")

local Safari = {}

-- The candidates.  Deliberately NOT all of Kanto: this is a draft for a
-- level-5 opening in a mode where your party is your health, so the list is
-- things that can carry an early fight and grow into the rungs -- the
-- common routes' catchables, the Safari's own residents, and a few that
-- are worth the walk.  No legendaries, no starters, nothing that only
-- exists behind a trade or a fossil: a pool entry has to be somebody's
-- reasonable first catch, or the rotation is just a slot machine.
--
-- Every name is checked against live data before it reaches a player, so a
-- build without one of these degrades rather than asserting mid-catch.
Safari.CANDIDATES = {
  -- the routes' own
  "RATTATA", "PIDGEY", "SPEAROW", "EKANS", "SANDSHREW", "MANKEY",
  "MEOWTH", "ZUBAT", "GEODUDE", "MACHOP", "BELLSPROUT", "ODDISH",
  "CATERPIE", "WEEDLE", "NIDORAN_M", "NIDORAN_F", "JIGGLYPUFF",
  "CLEFAIRY", "ABRA", "GASTLY", "DIGLETT", "PSYDUCK", "POLIWAG",
  "TENTACOOL", "KRABBY", "GOLDEEN", "MAGIKARP", "SHELLDER",
  "GROWLITHE", "VULPIX", "PONYTA", "SLOWPOKE", "MAGNEMITE",
  "DODUO", "SEEL", "GRIMER", "ONIX", "DROWZEE", "VOLTORB",
  "CUBONE", "KOFFING", "RHYHORN", "HORSEA", "STARYU",
  -- the Safari's own, which is where the mode's name comes from
  "NIDORINO", "NIDORINA", "PARAS", "VENONAT", "EXEGGCUTE", "CHANSEY",
  "SCYTHER", "PINSIR", "TAUROS", "KANGASKHAN", "DRATINI",
}

-- How many species one match's zone holds.  Small enough that the pool has
-- a character you can read in two minutes -- "this is a bug match" -- and
-- large enough that two people rarely walk out with the same team.
Safari.POOL_SIZE = 12

-- Every candidate this build actually has.  A pool entry the data does not
-- know is dropped rather than handed to Pokemon.new to assert on.
local function known(data)
  local out = {}
  for _, s in ipairs(Safari.CANDIDATES) do
    if not data or not data.pokemon or data.pokemon[s] then out[#out + 1] = s end
  end
  return out
end

-- This match's zone: `size` species drawn from the candidates, in a stable
-- order, decided entirely by the seed.
--
-- A partial Fisher-Yates over a copy, so a species is drawn at most once --
-- a pool that could hold RATTATA three times would read as a shorter pool
-- with worse luck.  Sorted before shuffling so the answer never depends on
-- the order the candidate list happens to be written in.
function Safari.pool(seed, data, size)
  local cand = known(data)
  table.sort(cand)
  if #cand == 0 then return { "RATTATA" } end
  local rng = Spawn.rng((tonumber(seed) or 1) + 104729)
  local n = math.max(1, math.min(tonumber(size) or Safari.POOL_SIZE, #cand))
  for i = 1, n do
    local j = rng(i, #cand)
    cand[i], cand[j] = cand[j], cand[i]
  end
  local out = {}
  for i = 1, n do out[i] = cand[i] end
  table.sort(out)   -- the zone is a set, not a running order
  return out
end

-- One encounter out of a pool.  `rng` is the caller's, so a client that
-- wants a reproducible zone can have one and the live game can pass a
-- fresh roll: WHAT is in the zone is everybody's business, but WHICH of
-- them walks into your grass this step is nobody's -- rolling it from the
-- match seed would hand every player the same catches in the same order.
function Safari.pick(pool, rng)
  if not (pool and #pool > 0) then return nil end
  if not rng then return pool[1] end
  return pool[rng(1, #pool)]
end

-- The zone in one line, for the log and for the message at the buzzer.
function Safari.describe(pool)
  return table.concat(pool or {}, ", ")
end

return Safari
