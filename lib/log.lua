-- The match's own log (POK-86).
--
-- Two things a log needs before anyone can debug a playtest from it, and
-- mod.log has neither.
--
-- **A tier below info.**  mod.log is info/warn/error and nothing quieter, so
-- anything worth printing only when you are hunting something either drowns
-- the default stream or does not get written at all.
--
--   say()   the match's STORY, at info: the phases, the drop, each ring,
--           every elimination and what did it, the winner, the teardown.  A
--           handful of lines per match.  This is what you read first.
--   deep()  everything else.  Off unless BR_DEBUG is set in the environment
--           (or setDeep is called), because it is exactly the tier that
--           would otherwise bury the story.
--   warn()  straight through: a warning is always worth printing.
--
-- **Correlation.**  Every line carries the room code and the match seed once
-- they exist -- "[A7QK/91823] ..." -- and the relay prints the same code on
-- every room line of its own.  That is what lets a client log and a server
-- log for the same game be lined up afterwards, which is the whole point of
-- the ticket.
--
-- Nothing here belongs on the hot path: these are called at events, never
-- per frame.  deep() returns before it formats when it is off, so the cost
-- of a line nobody asked for is one boolean test -- but an argument that is
-- expensive to BUILD is still built by the caller, so keep those out of the
-- call or guard them with isDeep().

local Log = {}
Log.__index = Log

-- os.getenv is not guaranteed under every host the mod runs in, so the
-- read is guarded; a log that throws while starting up is worse than a
-- quiet one.
local function envDeep()
  local ok, v = pcall(os.getenv, "BR_DEBUG")
  if not ok or v == nil then return false end
  return v ~= "" and v ~= "0" and v ~= "false" and v ~= "no"
end

Log.envDeep = envDeep

function Log.new(out)
  return setmetatable({ out = out, deepOn = envDeep() }, Log)
end

-- Which game this client is in, for the prefix.  Called when the room comes
-- up (code, no seed yet) and again when the match starts (both).
function Log:match(code, seed)
  if code ~= nil then self.code = code end
  if seed ~= nil then self.seed = seed end
end

function Log:forget() self.code, self.seed = nil, nil end

function Log:setDeep(on) self.deepOn = on and true or false end
function Log:isDeep() return self.deepOn == true end

-- "" until there is something to correlate ON: a prefix of all dashes is
-- noise on every line of a menu nobody has hosted from yet.
function Log:prefix()
  if self.code == nil and self.seed == nil then return "" end
  return ("[%s/%s] "):format(tostring(self.code or "-"), tostring(self.seed or "-"))
end

function Log:say(fmt, ...)
  if not self.out then return end
  self.out:info(self:prefix() .. tostring(fmt), ...)
end

function Log:deep(fmt, ...)
  if not (self.deepOn and self.out) then return end
  self.out:info(self:prefix() .. "· " .. tostring(fmt), ...)
end

function Log:warn(fmt, ...)
  if not self.out then return end
  self.out:warn(self:prefix() .. tostring(fmt), ...)
end

return Log
