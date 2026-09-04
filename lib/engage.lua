-- The forced-battle rule -- the predatory eyeline (DESIGN D10) -- as pure
-- functions over plain tables.
--
-- Cross another trainer's line of sight and the battle starts: no A press,
-- no consent, the way a Gen 1 trainer spots you.  The line runs RANGE cells
-- out along the way you are facing.  Each client only ever tests its OWN
-- sight, which is what makes it predatory rather than mutual: they do not
-- have to be looking back at you, they only have to be in front of you.
-- Their client is testing its own line at the same time, so creeping up
-- behind someone gets you seen the moment they turn round.
--
-- SIGHT IS BLOCKED BY TERRAIN, which the engine's own trainers do not
-- bother with: CheckSpriteCanSeePlayer is a straight facing-axis range test,
-- and OverworldController notes that the original marches a trainer through
-- a Strength boulder standing on the sight line.  That is fine for
-- hand-placed trainers on deliberately clear lines and wrong here, where
-- players stand wherever they like and being engaged through the side of a
-- building reads as a bug rather than an ambush.
--
-- Two players can notice each other on the same tick and both challenge.
-- That is fine: a challenge from the player you are already challenging is
-- read as an acceptance, and the lower id is always the battle host (the
-- side that deals the shared RNG seed), so both machines start the same
-- battle the same way round no matter who spoke first.

local Engage = {}

-- Per D10, tuned by POK-60.  A Game Boy screen is ten cells wide but only
-- nine tall, and the camera centers you: six cells along a row is a
-- visible hunt, but six down a column reaches two cells past the screen
-- edge -- an ambush by something the prey could never have seen.  So the
-- eyeline is as long as the screen lets BOTH sides see: six across, four
-- down the column.
Engage.RANGE = 6            -- along a row (left/right)
Engage.RANGE_Y = 4          -- along a column (up/down)

-- the default reach for a facing: the axis decides
function Engage.rangeFor(facing)
  return (facing == "up" or facing == "down") and Engage.RANGE_Y or Engage.RANGE
end

-- YOU NEVER ENGAGE WHAT YOU CANNOT SEE (POK-96).
--
-- The tuning above reasons about a Game Boy screen -- ten cells across,
-- nine down -- but reasons slightly wrong: the camera centres you, so half
-- a screen is five cells, and a trainer six cells along a row is off the
-- edge.  Players kept getting jumped by somebody who was never drawn, and
-- the walk-up beat (POK-85) was wasted on a bot that stepped in from
-- outside the frame.
--
-- So the reach is capped by what is actually on screen.  `span` is the
-- world view in PIXELS along the axis being looked down; a cell `d` away
-- is at least partly visible while d * 16 < span / 2 + 8.
--
-- Capped, never extended: min() with the tuned range is the whole point.
-- The view grows when a player zooms out or widens the window, and reach
-- that grew with it would hand the biggest monitor the longest eyeline --
-- one client seeing further than another in a game about spotting people
-- first.  A smaller window only ever costs you reach you could not have
-- used fairly anyway.
function Engage.visibleRange(facing, span)
  local base = Engage.rangeFor(facing)
  span = tonumber(span)
  if not span or span <= 0 then return base end
  local reach = math.ceil((span / 2 + 8) / 16) - 1
  if reach < 1 then reach = 1 end
  return math.min(base, reach)
end

local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

-- The cell immediately in front of a player table { x=, y=, facing= }.
function Engage.inFront(p)
  local d = DELTA[p.facing]
  if not d then return nil end
  return p.x + d[1], p.y + d[2]
end

-- Every cell along the eyeline, nearest first, stopping at the first one
-- sight cannot pass.  `blocked(x, y)` is supplied by the caller so this
-- module stays free of the engine; with no predicate the line is clear.
function Engage.sightLine(p, range, blocked)
  local out = {}
  local d = DELTA[p.facing]
  if not d then return out end
  for step = 1, (range or Engage.rangeFor(p.facing)) do
    local x, y = p.x + d[1] * step, p.y + d[2] * step
    out[#out + 1] = { x = x, y = y }
    if blocked and blocked(x, y) then break end
  end
  return out
end

local function canFight(p)
  return p ~= nil and p.status == "alive" and not p.moving and not p.busy
end

-- me:     { id=, map=, x=, y=, facing=, moving=, status=, busy= }
-- others: array of the same shape
-- opts:   { range =, blocked = function(x, y), avoid = { [id] = true } }
-- Returns the id of the nearest trainer in our sights, or nil.  An avoided
-- trainer (a flee's grace or lockout, POK-24) is not a target, and does not
-- shield anyone standing behind them either.
function Engage.target(me, others, opts)
  if not canFight(me) then return nil end
  local line = Engage.sightLine(me, opts and opts.range, opts and opts.blocked)
  local avoid = opts and opts.avoid
  -- nearest cell first, so someone standing between us and a further
  -- trainer is the one we engage
  for _, cell in ipairs(line) do
    local best
    for _, o in ipairs(others or {}) do
      if o.map == me.map and o.x == cell.x and o.y == cell.y and canFight(o)
         and not (avoid and avoid[o.id]) then
        if not best or o.id < best then best = o.id end
      end
    end
    if best then return best end
  end
  return nil
end

-- Whichever of the two ids is lower hosts the lockstep battle.
function Engage.isHost(myId, theirId)
  return myId < theirId
end

-- What to do with an incoming challenge.
--   "accept"  -> answer and start (also when it crosses our own challenge
--                to the same player)
--   "busy"    -> decline: we are fighting, pending with someone else, not
--                able to fight, or inside a flee's grace with them (POK-24)
function Engage.answer(me, fromId, pending, avoid)
  if me.status ~= "alive" or me.inBattle then return "busy" end
  if pending and pending.to ~= fromId then return "busy" end
  if avoid and avoid[fromId] then return "busy" end
  return "accept"
end

-- A challenge is not held forever (POK-162).  BR.pending gates every
-- battle path on a client -- the eyeline, a bot's sight, a walk-up talk,
-- even a field move -- so one reply that never lands used to wedge that
-- client for the rest of the match, and the bots, hunting the nearest
-- live trainer, hunted the two nobody could beat.  Past this many seconds
-- with no answer the challenge is dropped and the other side told.
--
-- Longer than Events.HOLD_SECONDS by a margin that covers the flash and
-- the relay both ways: the side holding the challenge must still be
-- holding it when the deferred answer lands, or an accept opens a battle
-- nobody joins.
Engage.PENDING_SECONDS = 12

-- ...and neither is a lockstep nobody joined.  LinkState says hello the
-- moment it opens, so a peer silent this long is never coming and the
-- battle is closed the way a pulled cable closes one.  Wider than the
-- two above put together, since it is the net under them.
Engage.LINK_OPEN_SECONDS = 20

-- Has a pending challenge outlived its answer?  `at` is when it was
-- made; one made before anybody was counting (no `at`) is not stale --
-- the caller stamps it and asks again next tick.
function Engage.stale(pending, now, limit)
  if not (pending and pending.at and now) then return false end
  return (now - pending.at) >= (limit or Engage.PENDING_SECONDS)
end

return Engage
