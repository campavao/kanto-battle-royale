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

local KeyFile = require("mods.battle_royale.lib.keyfile")

local Career = {}

-- Versioned in the key, not in the body: a format that has to change gets
-- a new file and leaves the old one for a migration to read.
Career.KEY = "career/v1"

-- Three lines; lib/keyfile.lua owns the format and this owns what the
-- fields MEAN.  Order is fixed so the file does not reshuffle itself on
-- every write, and an unset name or skin writes no line at all.
function Career.encode(career)
  career = career or {}
  return KeyFile.encode({
    { "name", KeyFile.str(career.name) },
    { "skin", KeyFile.str(career.skin) },
    { "wins", tostring(Career.cleanWins(career.wins)) },
  })
end

function Career.decode(str)
  local field, out = KeyFile.parse(str), {}
  if field.name and field.name ~= "" then out.name = field.name end
  if field.skin and field.skin ~= "" then out.skin = field.skin end
  -- absent and unparseable both mean "no win count in this file", which the
  -- caller reads as zero -- never as a reset of one it already had
  if tonumber(field.wins) then out.wins = Career.cleanWins(field.wins) end
  return out
end

-- a win count is a whole number of wins or it is zero; a file poked by
-- hand cannot hand the wardrobe a fraction or a negative
Career.cleanWins = KeyFile.count

-- ------- the store
--
-- Best effort by contract -- a reader always gets a table, a writer always
-- gets a boolean, and a filesystem that will not cooperate costs one
-- warning rather than a throw inside a match tick.  lib/keyfile.lua holds
-- that contract; these two say which file it is about.

function Career.load(mod)
  return KeyFile.load(mod, Career.KEY, Career.decode)
end

function Career.save(mod, career, log)
  return KeyFile.save(mod, Career.KEY, Career.encode(career), log, "career")
end

return Career
