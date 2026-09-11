-- The match's pace (POK-186): TEXT SPEED and BATTLE ANIMATION, chosen by
-- the host in the lobby and played by EVERY client for the length of the
-- match.
--
-- The game's own OPTION screen is a door out of a match (POK-99), so it is
-- hidden for the session -- but until this file, nothing set the two rows
-- it hides, and each client ran the match at whatever its own options.lua
-- said.  Two trainers in a lockstep duel at different text speeds were
-- simply out of step; a spectator's replica of that fight had to hurry or
-- wait.  Now the host's choice rides the `start` message the way the fog
-- length does (lib/wire.lua), lands in every client's live options table
-- when their throwaway world comes up, and is handed back on the way out.
--
-- Where the choice lives: `mod.cache`, beside the career (lib/career.lua
-- says why not mod.storage -- a match is a throwaway NEW GAME, and
-- storage does not survive one).  Set it once and it is there next
-- launch; REVERT TO DEFAULT puts the mod's core settings back.
--
-- The core settings are the game's own defaults -- MEDIUM text, animation
-- ON -- and they are what the daily game and quick play run at whatever
-- the host has saved: a stranger's match is never somebody else's slow
-- text.  Solo and hosted rooms are the host's to shape.
--
-- BATTLE STYLE is not here on purpose: a match is SET whatever anyone
-- says (main.lua, the battle.style hook), because SHIFT's free swap
-- softens party-as-health.  Speed multipliers are pinned at 1X for the
-- same reason (POK-144).
--
-- Pure where it matters: everything but load/save/apply/restore is a
-- plain function over plain tables, so tests/br_test.lua can check the
-- file format, the wire fields and the ladder without an engine.

local KeyFile = require("mods.battle_royale.lib.keyfile")

local Pace = {}

-- Versioned in the key, like the career: a format that has to change gets
-- a new file and leaves the old one for a migration to read.
Pace.KEY = "pace/v1"

-- TextSpeedOptionData frame delays with the OPTION screen's own labels
-- (src/ui/OptionsMenu.lua SPEEDS); the engine's text loops accept exactly
-- these three and fall back to MEDIUM for anything else.
Pace.SPEEDS = { { 1, "FAST" }, { 3, "MEDIUM" }, { 5, "SLOW" } }

-- the mod's core settings: what the game itself ships with
Pace.DEFAULT = { textSpeed = 3, animations = true }

-- ...and what a match nobody hosts runs at (QUICK PLAY, the DAILY GAME):
-- FAST text and no battle animations, the user's call after a night of
-- both (2026-09-11) -- the animations are loved and the match is faster
-- without them, and a room with no host has nobody to choose.
Pace.QUICK = { textSpeed = 1, animations = false }

local function speedIndex(v)
  for i, s in ipairs(Pace.SPEEDS) do
    if s[1] == v then return i end
  end
  return nil
end

-- A pace with both fields sensible, whatever it was read from: a file
-- poked by hand, a message from an older build, nil.  Always a fresh
-- table, so a caller may write into it.
function Pace.clean(p)
  p = type(p) == "table" and p or {}
  local ts = tonumber(p.textSpeed)
  return {
    textSpeed = (ts and speedIndex(ts)) and ts or Pace.DEFAULT.textSpeed,
    animations = p.animations ~= false,
  }
end

function Pace.isDefault(p)
  p = Pace.clean(p)
  return p.textSpeed == Pace.DEFAULT.textSpeed
     and p.animations == Pace.DEFAULT.animations
end

function Pace.speedLabel(p)
  return Pace.SPEEDS[speedIndex(Pace.clean(p).textSpeed)][2]
end

-- FAST -> MEDIUM -> SLOW -> FAST, the OPTION screen's own order
function Pace.cycleSpeed(p)
  p = Pace.clean(p)
  p.textSpeed = Pace.SPEEDS[speedIndex(p.textSpeed) % #Pace.SPEEDS + 1][1]
  return p
end

function Pace.toggleAnimations(p)
  p = Pace.clean(p)
  p.animations = not p.animations
  return p
end

-- one line for the log: "text MEDIUM, animation ON"
function Pace.describe(p)
  p = Pace.clean(p)
  return ("text %s, animation %s"):format(Pace.speedLabel(p),
                                          p.animations and "ON" or "OFF")
end

-- ------- the file
--
-- Two lines; lib/keyfile.lua owns the format.  Order is fixed so the file
-- does not reshuffle itself on every write.

function Pace.encode(p)
  p = Pace.clean(p)
  return KeyFile.encode({
    { "text", tostring(p.textSpeed) },
    { "anim", p.animations and "on" or "off" },
  })
end

function Pace.decode(str)
  local field = KeyFile.parse(str)
  return Pace.clean({ textSpeed = tonumber(field.text),
                      animations = field.anim ~= "off" })
end

-- Best effort by contract, the career's contract (lib/keyfile.lua): a
-- reader always gets a pace, a writer always gets a boolean, and a
-- filesystem that will not cooperate costs one warning.
function Pace.load(mod)
  return Pace.clean(KeyFile.load(mod, Pace.KEY, Pace.decode))
end

function Pace.save(mod, p, log)
  return KeyFile.save(mod, Pace.KEY, Pace.encode(p), log, "match options")
end

-- ------- the wire
--
-- Two short fields on the host's `start` (`ts`, `an`).  Additive: an older
-- reader's decoder drops fields it does not name and keeps its own
-- settings, which is what every client did before the fields existed.

function Pace.toWire(p)
  p = Pace.clean(p)
  return p.textSpeed, p.animations
end

-- nil for anything that is not exactly a pace: the reader then keeps its
-- own settings rather than guessing at half of the host's
function Pace.fromWire(ts, an)
  if not (type(ts) == "number" and speedIndex(ts)) then return nil end
  if type(an) ~= "boolean" then return nil end
  return { textSpeed = ts, animations = an }
end

-- ------- the game
--
-- The engine reads both rows live off game.save.options (TextBox and
-- BattleState for the delay, BattleState:animationsOn for the toggle), so
-- writing there is the whole mechanism.  What was there comes back as a
-- table for restore -- nil included, so a field the player never set stays
-- unset afterwards rather than becoming an explicit default.

function Pace.apply(game, p)
  local o = game and game.save and game.save.options
  if type(o) ~= "table" then return nil end
  p = Pace.clean(p)
  local saved = { textSpeed = o.textSpeed, animations = o.animations }
  o.textSpeed = p.textSpeed
  o.animations = p.animations
  return saved
end

function Pace.restore(game, saved)
  local o = game and game.save and game.save.options
  if not (type(o) == "table" and type(saved) == "table") then return false end
  o.textSpeed = saved.textSpeed
  o.animations = saved.animations
  -- The engine persists the WHOLE options table whenever a display hotkey
  -- (2-5, and a pipeline's own) is pressed, so a match in which one was
  -- pressed has written the host's pace into this player's options.lua.
  -- Writing once more, with their own values back in place, undoes that.
  if type(game.writeOptions) == "function" then
    pcall(game.writeOptions, game)
  end
  return true
end

return Pace
