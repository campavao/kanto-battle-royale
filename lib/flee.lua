-- Fleeing a PvP battle is not free (POK-24, DESIGN D9).
--
-- A lockstep battle ends as a draw the moment either side submits a `run`
-- action, and the engine's own escape roll never runs for it -- so RUN was
-- a free exit for whoever was losing, which blunts the forced-eyeline
-- premise.  The fix needs no engine change and stays deterministic: only
-- the RUNNER's machine decides whether a run action is submitted at all.
-- The other side only ever sees a submitted run, which ends the battle as
-- it always did.
--
--   * Speed-gated and rare: one in four at equal speed, half at twice the
--     pursuer's speed, never better than five in eight, +8% per retry
--     within the battle.  A failed attempt says "Can't escape!" and hands
--     the menu back -- this turn is fought (the lockstep needs an action
--     from us, so a Gen 1 lost turn is not expressible without a seam).
--   * Escalating pursuit: every earlier escape from the SAME pursuer halves
--     the odds.  A determined pursuer wears down prey.
--   * A POKe DOLL is a guaranteed bail, and it is spent.
--   * After a flee, neither of the pair engages the other for a few
--     seconds (the runner gets the head start a flee promises), and the
--     runner cannot initiate on who they fled from for longer -- fleeing
--     is not a way to pick when a fight restarts.

local Flee = {}

Flee.BASE = 64             -- x out of 256 at equal speed: one in four
Flee.CAP = 160             -- the ceiling, however fast you are: five in eight
Flee.RETRY = 20            -- each earlier attempt in this battle adds this
Flee.CEILING = 240         -- retries never make an escape certain
-- the third line rides a \v scroll: three \n in a two-line box drop it
-- (the engine's own _NoRunningText lesson, BattleState:tryRun)
Flee.NO_DOLL_TEXT = "No POKe DOLL left!\nThere's no other\vway to run!"
Flee.GRACE_SECONDS = 4     -- neither of the pair engages the other
Flee.LOCKOUT_SECONDS = 30  -- the runner does not initiate on who they fled from

-- The escape chance as x out of 256 (compare rng(0, 255) <= x, the Gen 1
-- shape): speed-gated, capped, better with each retry, halved for every
-- earlier escape from this pursuer.
function Flee.chance(pSpd, eSpd, attempts, prior)
  pSpd = math.max(1, math.floor(tonumber(pSpd) or 1))
  eSpd = math.max(1, math.floor(tonumber(eSpd) or 1))
  local x = math.min(Flee.CAP, math.floor(Flee.BASE * pSpd / eSpd))
  x = math.min(Flee.CEILING, x + Flee.RETRY * math.max(0, (attempts or 1) - 1))
  for _ = 1, math.max(0, math.floor(tonumber(prior) or 0)) do
    x = math.floor(x / 2)
  end
  return x
end

-- rng(a, b) -> integer in [a, b]; love.math.random by default
function Flee.roll(pSpd, eSpd, attempts, prior, rng)
  rng = rng or love.math.random
  return rng(0, 255) <= Flee.chance(pSpd, eSpd, attempts, prior)
end

-- Spend one POKe DOLL from the bag.  True when there was one to spend.
function Flee.spendDoll(save)
  local inv = save and save.inventory
  if not (inv and (inv.POKE_DOLL or 0) > 0) then return false end
  inv.POKE_DOLL = inv.POKE_DOLL - 1
  if inv.POKE_DOLL <= 0 then inv.POKE_DOLL = nil end
  save.bagOrder = nil            -- rebuilt from the inventory on the next open
  return true
end

-- The escape a POKe DOLL buys from a battle the engine would not let you
-- run from: the fields BagMenu's own consumed_escape branch sets for a
-- wild one.  pokeDollEscape is the engine's flag for "this run was a
-- doll", so anything reading the result afterwards can tell.
function Flee.escape(battle)
  battle.pokeDollEscape = true
  battle.result = "run"
  battle.afterQueue = "finish"
  battle.phase = "messages"
end

-- Wrap a lockstep battle's tryRun (an instance field on LinkBattle) so a
-- run action is only submitted when the roll -- or a POKe DOLL -- says so.
--   ctx = { save = <save>, prior = <earlier escapes from this pursuer>,
--           rng = <optional>, onFlee = function(how) end }
-- Returns true when the battle was wrappable.
function Flee.wrap(battle, ctx)
  local base = battle and battle.tryRun
  if type(base) ~= "function" then return false end
  ctx = ctx or {}
  local attempts = 0
  battle.tryRun = function(s)
    if Flee.spendDoll(ctx.save) then
      if ctx.onFlee then ctx.onFlee("doll") end
      return base(s)
    end
    attempts = attempts + 1
    local TurnOrder = require("src.battle.TurnOrder")
    local pSpd = s.player and TurnOrder.effectiveSpeed(s.player) or 1
    local eSpd = s.enemy and TurnOrder.effectiveSpeed(s.enemy) or 1
    if Flee.roll(pSpd, eSpd, attempts, ctx.prior or 0, ctx.rng) then
      if ctx.onFlee then ctx.onFlee("ran") end
      return base(s)
    end
    -- a failed attempt: the menu comes back, and this turn is fought
    if s.say then
      s:say(s.romText and s:romText("_CantEscapeText", "Can't escape!") or "Can't escape!")
    end
    s.phase = "messages"
    s.afterQueue = "menu"
    return false
  end
  return true
end

-- The bot-fight wrap (POK-194).  A fight against a bot is an engine
-- trainer battle, and BattleState:tryRun refuses one ("No! There's no
-- running from a trainer battle!") before any roll -- so no roll: a POKe
-- DOLL is the one way out, spent, and without one RUN is the engine's
-- own refusal.  The bag's doll lands here too: using it in a bot fight
-- closes the bag and calls tryRun, so the two are one path.
--   ctx = { save = <save>, text = <the escape line>, onFlee = function(how) end }
-- Returns true when the battle was wrappable.
function Flee.wrapTrainer(battle, ctx)
  local base = battle and battle.tryRun
  if type(base) ~= "function" then return false end
  ctx = ctx or {}
  battle.tryRun = function(s)
    if not Flee.spendDoll(ctx.save) then
      -- the engine's line is "No! There's no running from a trainer
      -- battle!", which is true and useless here: the player has a way
      -- out and is short of it (the user, 2026-09-08)
      if not s.say then return base(s) end
      s.phase = "messages"
      s.afterQueue = "menu"
      s:say(ctx.noDoll or Flee.NO_DOLL_TEXT)
      return false
    end
    if s.say then s:say(ctx.text or "Got away safely!") end
    Flee.escape(s)
    if ctx.onFlee then ctx.onFlee("doll") end
    return true
  end
  return true
end

return Flee
