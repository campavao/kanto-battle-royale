-- The little `key=value` store the career and the stats both keep.
--
-- Two files, one shape.  Both live in `mod.cache` (keyed by mod id alone,
-- so it survives the throwaway NEW GAME a match is entered through, which
-- is the property neither of them can do without -- see lib/career.lua for
-- why mod.storage is the wrong home).  Both are `key=value` one per line.
-- Both are best effort by contract: a reader always gets a table, a writer
-- always gets a boolean, and a filesystem that will not cooperate costs one
-- warning rather than a throw in the middle of a match.
--
-- That was two copies of trim, two copies of the line parser, two copies of
-- the read/pcall/decode dance and two copies of the write/pcall/warn one --
-- byte for byte the same, and drifting apart is the only thing they could
-- ever have done.  A third file wanting the same store should need nothing
-- here but its own field list.
--
-- What is deliberately NOT here: the field lists themselves.  Which keys a
-- file has, which are optional, and what a value means are the caller's --
-- this module only knows lines.
--
-- Pure where it matters: trim/parse/encode are plain functions over plain
-- strings, so tests/br_test.lua can check the format without an engine, and
-- load/save are the only two that touch a mod at all.

local KeyFile = {}

function KeyFile.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A whole number of things, or none: a file poked by hand cannot hand a
-- count a fraction, a negative, or a word.
function KeyFile.count(n)
  return math.max(0, math.floor(tonumber(n) or 0))
end

-- A value worth writing, or nil for "leave the line out".  An empty string
-- and a non-string are the same answer here: a field nobody has set.
function KeyFile.str(v)
  return type(v) == "string" and v ~= "" and v or nil
end

-- `key=value`, one per line, FIRST `=` splits so a value may contain more.
-- Both sides are trimmed; a later line wins over an earlier one with the
-- same key, and a line that is not `key=value` at all is dropped.
--
-- Every value comes back as the string it was written as -- parsing "1" as
-- a number or as a boolean is the caller's business, because only the
-- caller knows which key means which.
--
-- Values are not escaped and do not need to be: Wire.cleanName strips every
-- control character before a name can reach a file, so nothing can carry
-- the newline that would forge a second row, and an unrecognised key is
-- ignored anyway -- a hand-edited file loses a field at worst.
function KeyFile.parse(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in text:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then out[KeyFile.trim(key)] = KeyFile.trim(value) end
  end
  return out
end

-- The other direction: an ORDERED list of { key, value } pairs, because a
-- file whose lines move around on every write is a file nobody can diff.
-- A nil value drops its line entirely, which is how an unset optional field
-- stays unset rather than being written back as an empty one.
function KeyFile.encode(fields)
  local out = {}
  for _, field in ipairs(fields) do
    if field[2] ~= nil then out[#out + 1] = field[1] .. "=" .. field[2] end
  end
  return table.concat(out, "\n") .. "\n"
end

-- ------- the store
--
-- `decode` is the caller's: this reads the bytes and hands them over, so a
-- cache that is absent, unreadable or holding something that is not a
-- string all arrive at the same place -- an empty table, no warning, which
-- is the ordinary state on a first launch.

function KeyFile.load(mod, key, decode)
  local cache = mod and mod.cache
  if not cache then return {} end
  local ok, bytes = pcall(cache.read, cache, key)
  if not ok or type(bytes) ~= "string" then return {} end
  return decode(bytes)
end

-- `what` names the file in the warning ("career not saved (...)"), which is
-- the only thing the player or a bug report ever sees of a failed write.
-- The old code swallowed this in a bare pcall, which is why the bug it was
-- hiding stayed hidden for as long as it did.
function KeyFile.save(mod, key, text, log, what)
  local cache = mod and mod.cache
  if not cache then return false, "no mod.cache on this engine" end
  local ok, wrote, err = pcall(cache.write, cache, key, text)
  if not ok then wrote, err = nil, wrote end
  if not wrote then
    if log then
      log:warn("%s not saved (%s)", what, tostring(err or "unknown"))
    end
    return false, err
  end
  return true
end

return KeyFile
