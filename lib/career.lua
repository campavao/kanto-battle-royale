-- The career that outlives a playthrough (POK-120): the trainer name, the
-- skin they wear, and the wins that unlock the wardrobe.
--
-- These belong to the person at the keyboard, not to a save file, and that
-- is exactly what the first version got wrong.  `mod.storage` reads like
-- the right home and is not: the engine scopes every storage key by
-- "opaque playthrough identity" (docs/modding.md, and Loader.lua's own
-- note where it hands out the cache), and a battle royale is entered
-- through a throwaway NEW GAME -- a fresh playthrough every launch.  So
-- each session wrote into a namespace the next one could not find, and the
-- name, the skin and the win count all read back blank.
--
-- `mod.cache` is keyed by mod id alone (ImportAccess.makeCache roots it at
-- `mod_cache/<id>`), so it survives a new playthrough, which is the one
-- property a career needs.  The docs frame the cache as the home for
-- artifacts that can be rebuilt from a declared source, and a career
-- cannot be; there is no other cross-playthrough writable store in the mod
-- API, so this is a deliberate trade.  Losing the file costs the wardrobe,
-- never a match, and every path here degrades to "no career yet" rather
-- than to an error in the middle of one.
--
-- Pure where it matters: encode/decode are plain functions over plain
-- tables, so tests/br_test.lua can check the format without an engine.

local Career = {}

-- Versioned in the key, not in the body: a format that has to change gets
-- a new file and leaves the old one for a migration to read.
Career.KEY = "career/v1"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- `key=value`, one per line, first `=` splits so a value may contain more.
-- Wire.cleanName already strips every control character, so a name cannot
-- carry the newline that would forge a second row -- and decode ignores
-- what it does not recognise anyway, so a hand-edited file loses a field
-- at worst.
function Career.encode(career)
  career = career or {}
  local out = {}
  if type(career.name) == "string" and career.name ~= "" then
    out[#out + 1] = "name=" .. career.name
  end
  if type(career.skin) == "string" and career.skin ~= "" then
    out[#out + 1] = "skin=" .. career.skin
  end
  out[#out + 1] = "wins=" .. tostring(Career.cleanWins(career.wins))
  return table.concat(out, "\n") .. "\n"
end

function Career.decode(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in text:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then
      key, value = trim(key), trim(value)
      if key == "name" and value ~= "" then
        out.name = value
      elseif key == "skin" and value ~= "" then
        out.skin = value
      elseif key == "wins" and tonumber(value) then
        out.wins = Career.cleanWins(value)
      end
    end
  end
  return out
end

-- a win count is a whole number of wins or it is zero; a file poked by
-- hand cannot hand the wardrobe a fraction or a negative
function Career.cleanWins(n)
  return math.max(0, math.floor(tonumber(n) or 0))
end

-- ------- the store
--
-- Best effort by contract: a reader always gets a table, a writer always
-- gets a boolean, and a filesystem that will not cooperate costs one
-- warning rather than a throw inside a match tick.

function Career.load(mod)
  local cache = mod and mod.cache
  if not cache then return {} end
  local ok, bytes = pcall(cache.read, cache, Career.KEY)
  if not ok or type(bytes) ~= "string" then return {} end
  return Career.decode(bytes)
end

function Career.save(mod, career, log)
  local cache = mod and mod.cache
  if not cache then return false, "no mod.cache on this engine" end
  local ok, wrote, err = pcall(cache.write, cache, Career.KEY,
                               Career.encode(career))
  if not ok then wrote, err = nil, wrote end
  if not wrote then
    -- the old code swallowed this in a bare pcall, which is why the bug
    -- was silent for as long as it was
    if log then log:warn("career not saved (%s)", tostring(err or "unknown")) end
    return false, err
  end
  return true
end

return Career
