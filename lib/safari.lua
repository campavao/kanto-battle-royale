-- The Safari opening's rotating pool (POK-118), given a character (POK-177).
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
-- And it has a SHAPE (POK-177).  Thirty matches in, a player reported the
-- endgame "always comes down to the same ten lines": a uniform draw over a
-- candidate list that was mostly early-route catchables produced, across
-- many matches, mostly early-route teams.  Now each zone is three slices:
--   * a THEME -- one type the seed picks, read off the data's own type
--     table, so a match is "a water match" or "a bug match" and reads that
--     way in two minutes;
--   * a RARE slice -- a few of the entries that a flat roll almost never
--     surfaced (the Safari's own residents, the one-offs), guaranteed a
--     place every match rather than left to luck;
--   * the open slice -- the rest of the candidates, for the familiar
--     first catch.
-- Bots draft their first mon from the same zone (Bots.newRecord), so what
-- a fallen bot drops is the match's own character, not another PIDGEY.
--
-- Pure over plain tables: pool() and pick() take a seed and a data handle
-- and return species names, so br_test checks the rotation without a ROM,
-- a map, or a running match.

local Spawn = require("mods.battle_royale.lib.spawn")

local Safari = {}

-- The candidates.  Deliberately NOT all of Kanto: this is a draft for a
-- level-5 opening in a mode where your party is your health, so the list is
-- things that can carry an early fight and grow into the rungs -- the
-- common routes' catchables, the Safari's own residents, and the one-offs
-- that are worth the walk.  No legendaries, no starters, nothing that only
-- exists behind a fossil: a pool entry has to be somebody's reasonable
-- first catch, or the rotation is just a slot machine.
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
  "CUBONE", "KOFFING", "RHYHORN", "HORSEA", "STARYU", "PIKACHU",
  -- the Safari's own, which is where the mode's name comes from
  "NIDORINO", "NIDORINA", "PARAS", "VENONAT", "EXEGGCUTE", "CHANSEY",
  "SCYTHER", "PINSIR", "TAUROS", "KANGASKHAN", "DRATINI",
  -- the one-offs (POK-177): Kanto's gifts, trades and single nests
  "LICKITUNG", "TANGELA", "ELECTABUZZ", "MAGMAR", "JYNX", "LAPRAS",
  "PORYGON", "EEVEE", "MR_MIME", "FARFETCHD", "DITTO", "SNORLAX",
}

-- The entries a flat roll starved: every zone holds RARE_PER_POOL of
-- these, drawn before the open slice gets its turn.
Safari.RARE = {
  "CHANSEY", "SCYTHER", "PINSIR", "TAUROS", "KANGASKHAN", "DRATINI",
  "LICKITUNG", "TANGELA", "ELECTABUZZ", "MAGMAR", "JYNX", "LAPRAS",
  "PORYGON", "EEVEE", "MR_MIME", "FARFETCHD", "DITTO", "SNORLAX",
}

-- How many species one match's zone holds.  Small enough that the pool has
-- a character you can read in two minutes -- "this is a bug match" -- and
-- large enough that two people rarely walk out with the same team.
Safari.POOL_SIZE = 12
-- ...of which: the theme's share, and the rare slice.  The rest is open.
Safari.THEME_PER_POOL = 5
Safari.RARE_PER_POOL = 3
-- a type is a theme only when enough candidates carry it: five of one type
-- out of four is the whole type, which is fine, but two would be a gimmick
Safari.THEME_MIN = 4
-- NORMAL is most of Kanto; "a normal match" is the thing this is curing
Safari.NO_THEME = { NORMAL = true }

-- Every candidate this build actually has.  A pool entry the data does not
-- know is dropped rather than handed to Pokemon.new to assert on.
local function known(data, list)
  local out = {}
  for _, s in ipairs(list or Safari.CANDIDATES) do
    if not data or not data.pokemon or data.pokemon[s] then out[#out + 1] = s end
  end
  return out
end

local function typesOf(data, species)
  local def = data and data.pokemon and data.pokemon[species]
  return (type(def) == "table" and def.types) or {}
end

-- The themes this build can offer: every type at least THEME_MIN known
-- candidates carry, sorted, so the seed's choice never depends on table
-- order.  Empty without data (br_test's plain case): a zone with no
-- theme is the POK-118 zone.
function Safari.themes(data)
  local count = {}
  for _, s in ipairs(known(data)) do
    for _, t in ipairs(typesOf(data, s)) do
      if type(t) == "string" and not Safari.NO_THEME[t] then
        count[t] = (count[t] or 0) + 1
      end
    end
  end
  local out = {}
  for t, n in pairs(count) do
    if n >= Safari.THEME_MIN then out[#out + 1] = t end
  end
  table.sort(out)
  return out
end

-- Draw up to `n` from `from` (already sorted) that are not in `taken`,
-- through a partial Fisher-Yates, so a species is drawn at most once.
local function draw(rng, from, n, taken, into)
  local cand = {}
  for _, s in ipairs(from) do
    if not taken[s] then cand[#cand + 1] = s end
  end
  local want = math.min(n, #cand)
  for i = 1, want do
    local j = rng(i, #cand)
    cand[i], cand[j] = cand[j], cand[i]
    taken[cand[i]] = true
    into[#into + 1] = cand[i]
  end
  return want
end

-- This match's zone: `size` species drawn from the candidates, in a stable
-- order, decided entirely by the seed -- and the theme it was built
-- around, or nil when the build offers none.
--
-- Sorted before shuffling so the answer never depends on the order the
-- candidate list happens to be written in; the theme's members, the rare
-- slice, then the open slice, so a smaller `size` still keeps the shape.
function Safari.pool(seed, data, size)
  local cand = known(data)
  table.sort(cand)
  if #cand == 0 then return { "RATTATA" }, nil end
  local rng = Spawn.rng((tonumber(seed) or 1) + 104729)
  local n = math.max(1, math.min(tonumber(size) or Safari.POOL_SIZE, #cand))
  local out, taken = {}, {}

  local themes = Safari.themes(data)
  local theme = (#themes > 0) and themes[rng(1, #themes)] or nil
  if theme then
    local members = {}
    for _, s in ipairs(cand) do
      for _, t in ipairs(typesOf(data, s)) do
        if t == theme then members[#members + 1] = s break end
      end
    end
    draw(rng, members, math.min(Safari.THEME_PER_POOL, n), taken, out)
  end
  local rare = known(data, Safari.RARE)
  table.sort(rare)
  draw(rng, rare, math.min(Safari.RARE_PER_POOL, n - #out), taken, out)
  draw(rng, cand, n - #out, taken, out)

  table.sort(out)   -- the zone is a set, not a running order
  return out, theme
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

-- The theme as a person would say it: "WATER", "PSYCHIC" (the data calls
-- that one PSYCHIC_TYPE, because PSYCHIC is also a move).
function Safari.themeName(theme)
  if type(theme) ~= "string" then return nil end
  return (theme:gsub("_TYPE$", ""))
end

-- The zone in one line, for the log and for the message at the buzzer.
function Safari.describe(pool, theme)
  local list = table.concat(pool or {}, ", ")
  local name = Safari.themeName(theme)
  if name then return ("a %s match: %s"):format(name, list) end
  return list
end

return Safari
