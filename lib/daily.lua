-- The DAILY GAME's start clock (POK-180).
--
-- The host arms its start from the relay's seconds-until on every info
-- poll (POK-161), so drift never accumulates.  The catch is that the
-- server counts in whole seconds and the answer rides a round trip, so
-- the arm always lands a little AFTER the true hour -- up to a second
-- plus half the RTT.  A poll answered inside that sliver sees the hour
-- already gone and reports the NEXT day's seconds, and the naive re-arm
-- pushed the start out by 86400.  That is how the lone host of the
-- 2026-09-04 daily sat through 00:00Z with nothing happening: the same
-- build had fired the night before, because the sliver is a few percent
-- of the fifteen-second cadence.
--
-- The rule: a re-derivation may move the deadline EARLIER, or later by
-- no more than the jitter two honest answers can disagree by.  A jump
-- past that is the hour arriving between the arm and the answer, and
-- the armed deadline stands -- the tick fires it on the next frame.

local Daily = {}

-- Two consecutive honest answers differ by at most a second of
-- truncation plus the RTT jitter; anything past this is the hour gone by.
Daily.SLACK = 10

-- armed:  the deadline already held (a clock time), or nil
-- at:     the deadline the latest answer works out to
-- Returns the deadline to hold, and true when the answer was refused.
function Daily.rearm(armed, at)
  if armed == nil then return at, false end
  if at <= armed + Daily.SLACK then return at, false end
  return armed, true
end

return Daily
