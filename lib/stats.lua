-- What the relay learns about play, and the one number that makes it mean
-- anything (POK-124).
--
-- The relay already sees every hosted room, every join and every match
-- start, so multiplayer counts itself.  SOLO VS BOTS does not: it runs on a
-- LocalRoom and never opens a socket, so the mode most likely to be
-- somebody's entire experience of this mod is the one nothing can see.
--
-- What this does NOT do is open a connection to say so.  Net:connectTCP is
-- a BLOCKING connect with a five-second timeout, and its own comment says
-- why that is acceptable: "this runs once, from a single explicit user
-- action, not from a per-frame poll".  Starting a solo match is precisely
-- the wrong place to break that promise -- someone who chose the offline
-- mode, on a laptop with no wifi, would watch the game freeze for five
-- seconds before their bot match began.
--
-- So nothing in here ever touches the network.  A solo match bumps a
-- counter in mod.cache, and that count rides along the NEXT time a real
-- relay connection exists for its own reasons -- host, join, quick play.
-- Zero new sockets, so it cannot delay a match even in principle.
--
-- The cost of that choice, stated plainly rather than buried: someone who
-- only ever plays solo is never counted.  The first time they touch
-- multiplayer their whole solo history arrives at once, which is the more
-- useful signal anyway; until then they are invisible.  Closing that gap
-- needs a non-blocking connect in the engine, which is a different change
-- and a different PR.
--
-- On the wire: a random install id, the mod version, a count, a date.  Not
-- the trainer name -- the player chose that and it may be their handle.
--
-- Pure where it matters: encode/decode/message are plain functions over
-- plain tables, so tests/br_test.lua can check the format and the wire
-- shape without an engine or a socket.

local Stats = {}

Stats.KEY = "stats/v1"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Stats.cleanCount(n)
  return math.max(0, math.floor(tonumber(n) or 0))
end

-- 16 hex characters of nothing in particular.  love.math.random when the
-- game is up, math.random under the headless tests; seeded off the clock
-- because an id that is the same on every install counts one player.
local seeded = false
function Stats.newId(rand)
  if not rand then
    if love and love.math and love.math.random then
      rand = love.math.random
    else
      if not seeded then
        local t = (os and os.time and os.time()) or 0
        local c = (os and os.clock and math.floor(os.clock() * 1000)) or 0
        pcall(math.randomseed, t + c)
        seeded = true
      end
      rand = math.random
    end
  end
  local out = {}
  for i = 1, 16 do out[i] = ("%x"):format(rand(0, 15)) end
  return table.concat(out)
end

local function today()
  local ok, s = pcall(function() return os.date("%Y-%m-%d") end)
  if ok and type(s) == "string" then return s end
  return ""
end

-- ------- the file
--
-- `k=v` a line, first `=` splits, unknown keys ignored -- the same shape
-- lib/career.lua uses, for the same reason: a file poked by hand loses a
-- field at worst.

function Stats.encode(s)
  s = s or {}
  local out = {}
  if type(s.id) == "string" and s.id ~= "" then out[#out + 1] = "id=" .. s.id end
  if type(s.since) == "string" and s.since ~= "" then
    out[#out + 1] = "since=" .. s.since
  end
  out[#out + 1] = "solo=" .. tostring(Stats.cleanCount(s.solo))
  out[#out + 1] = "off=" .. (s.off and "1" or "0")
  return table.concat(out, "\n") .. "\n"
end

function Stats.decode(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in text:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then
      key, value = trim(key), trim(value)
      if key == "id" and value ~= "" then out.id = value
      elseif key == "since" and value ~= "" then out.since = value
      elseif key == "solo" and tonumber(value) then out.solo = Stats.cleanCount(value)
      elseif key == "off" then out.off = (value == "1" or value == "true")
      end
    end
  end
  return out
end

-- ------- the store
--
-- Best effort, like the career: a reader always gets a table, a writer
-- always gets a boolean, and a filesystem that will not cooperate costs a
-- warning rather than a throw on the path into a match.

function Stats.load(mod)
  local cache = mod and mod.cache
  if not cache then return {} end
  local ok, bytes = pcall(cache.read, cache, Stats.KEY)
  if not ok or type(bytes) ~= "string" then return {} end
  return Stats.decode(bytes)
end

function Stats.save(mod, s, log)
  local cache = mod and mod.cache
  if not cache then return false, "no mod.cache on this engine" end
  local ok, wrote, err = pcall(cache.write, cache, Stats.KEY, Stats.encode(s))
  if not ok then wrote, err = nil, wrote end
  if not wrote then
    if log then log:warn("stats not saved (%s)", tostring(err or "unknown")) end
    return false, err
  end
  return true
end

-- Load, minting an id and a first-seen date in MEMORY the first time.
--
-- Deliberately does not write: this runs at boot, and a boot that touches
-- the disk to say nothing has happened yet is a boot that warns on every
-- launch of an engine whose cache will not take a write.  The id is
-- persisted by the first thing that actually has something to report --
-- recordSolo, or the flush after a stat goes out -- which is the first
-- moment it means anything.  An install that never reports never needs a
-- stable id.
function Stats.ensure(mod)
  local s = Stats.load(mod)
  if not s.id then s.id = Stats.newId() end
  if not s.since then s.since = today() end
  return s
end

-- A solo match started.  A local counter bump and a file write -- no
-- socket, no connect, nothing that can take a five-second timeout on the
-- way into somebody's game.
function Stats.recordSolo(mod, s, log)
  if not s or s.off then return false end
  s.solo = Stats.cleanCount(s.solo) + 1
  Stats.save(mod, s, log)
  return true
end

-- ------- the wire
--
-- nil when there is nothing to say or the player said not to, so the
-- caller's flush is a single `if`.

function Stats.message(s, version)
  if not s or s.off or not s.id then return nil end
  local solo = Stats.cleanCount(s.solo)
  return { type = "stat", id = s.id, v = version, solo = solo,
           since = s.since ~= "" and s.since or nil }
end

-- The count is only cleared once the relay has actually been handed it, so
-- a refused send keeps the number for next time rather than losing it.
function Stats.flushed(mod, s, log)
  if not s then return false end
  s.solo = 0
  return Stats.save(mod, s, log)
end

function Stats.setOff(mod, s, off, log)
  if not s then return false end
  s.off = off and true or false
  Stats.save(mod, s, log)
  return s.off
end

return Stats
