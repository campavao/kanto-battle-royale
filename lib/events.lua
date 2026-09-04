-- The per-player event queue (POK-162).
--
-- A challenge that landed while this screen was busy -- healing at the
-- nurse, reading a sign, deep in the PACK -- used to be answered on the
-- spot.  Engage.answer only ever asked whether we were alive and not
-- already fighting, so the accept went out and the lockstep opened under
-- an occupied state stack, where StateStack:update never reaches it
-- (src/core/StateStack.lua:60).  Both sides were left holding a
-- challenge nothing would resolve; every battle path on both clients is
-- gated on that challenge; the bots hunt the nearest live trainer, which
-- was now one of two trainers nobody could eliminate.  5 LEFT, for good.
--
-- So an event that needs the overworld waits for the overworld.  main.lua
-- pushes what arrives at a bad moment in here and drains it -- oldest
-- first, one per tick -- the moment the screen is quiet again.  That is
-- the pattern the buzzer uses for menus (tickDrop, POK-161) and tickSays
-- uses for text, except that it DEFERS rather than cancels: the fight the
-- challenger asked for is the next thing that happens when the dialog
-- closes.  A wait is bounded: an event held longer than HOLD_SECONDS is
-- handed back to the caller as expired, so the other side can be told
-- rather than left guessing.
--
-- Pure, like lib/engage.lua: a queue is a table and the clock is passed
-- in, so tests/br_test.lua drives it with a fake one.

local Events = {}

-- How long a deferred event waits for the screen before it is given up
-- on.  Shorter than Engage.PENDING_SECONDS on purpose, with room for the
-- flash and the relay in between: the challenger has to still be holding
-- the challenge when the answer -- either answer -- lands, or an accept
-- opens a battle nobody joins.
Events.HOLD_SECONDS = 8

function Events.new() return { queue = {} } end

-- One event per (kind, from): a second challenge from the same trainer
-- replaces the first -- their nonce moved on, and answering the old one
-- would be answering a challenge they no longer hold.  Its place in the
-- line is kept, so a re-issued challenge cannot queue-jump.
function Events.push(q, ev, now)
  ev.at = now or 0
  local list = q.queue
  for i, old in ipairs(list) do
    if old.kind == ev.kind and old.from == ev.from then
      list[i] = ev
      return ev
    end
  end
  list[#list + 1] = ev
  return ev
end

function Events.find(q, kind, from)
  for _, ev in ipairs(q.queue) do
    if ev.kind == kind and ev.from == from then return ev end
  end
  return nil
end

-- Remove every event of `kind` (from `from`, when given); returns them.
function Events.drop(q, kind, from)
  local kept, gone = {}, {}
  for _, ev in ipairs(q.queue) do
    if ev.kind == kind and (from == nil or ev.from == from) then
      gone[#gone + 1] = ev
    else
      kept[#kept + 1] = ev
    end
  end
  q.queue = kept
  return gone
end

-- Pull out everything held `hold` seconds or longer; returns them, oldest
-- first, so the caller can answer each one.
function Events.expire(q, now, hold)
  hold = hold or Events.HOLD_SECONDS
  local kept, gone = {}, {}
  for _, ev in ipairs(q.queue) do
    if ((now or 0) - (ev.at or 0)) >= hold then gone[#gone + 1] = ev
    else kept[#kept + 1] = ev end
  end
  q.queue = kept
  return gone
end

function Events.pop(q) return table.remove(q.queue, 1) end
function Events.peek(q) return q.queue[1] end
function Events.count(q) return #q.queue end

function Events.clear(q)
  local gone = q.queue
  q.queue = {}
  return gone
end

return Events
