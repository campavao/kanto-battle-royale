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

-- Six cells, per D10.  A Game Boy screen is ten cells wide, so six is far
-- enough to be hunted across open ground and short enough that a town's
-- buildings still break the sight lines.
Engage.RANGE = 6

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
  for step = 1, (range or Engage.RANGE) do
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

return Engage
