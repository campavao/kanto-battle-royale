-- Other mods that act on the overworld, stood down for the length of a match.
--
-- A match is a takeover.  The mod enters through a throwaway NEW GAME, moves
-- everyone into the SAFARI with an empty party, renames every TM, despawns
-- trainers as the ring closes, and draws other players as ghosts.  Any other
-- mod that also acts on the overworld is doing its own thing on top of that,
-- and the two are not composing -- they are competing.
--
-- The first one found (POK-134) breaks the opening outright.  "Wilds of
-- Kanto" puts wild POKeMON in the overworld, and it does two things that
-- happen to be exactly wrong for the SAFARI opening:
--
--   1. it wraps `encounter.roll` to suppress vanilla encounters while its
--      spawn system is up.  The engine only calls `encounter.species` when
--      the roll returned something (OverworldController:rollEncounter), so
--      suppressing the roll means BR's own species hook never runs -- and
--      that hook is where the ghost lead is lent.
--   2. its overworld mon starts a battle with the script command
--      `start_battle` (its GameCompat.startWildBattle queues
--      { "start_battle", "wild", species, level }), which never goes near
--      the encounter hooks at all.
--
-- So: no stand-in is lent, and a wild battle opens anyway against an empty
-- party.  BattleState.newWild marks that battle dead and the engine reports
-- it as a LOSS -- which the mod used to turn into an elimination, every time
-- the player touched a wild mon.  Reported by a player who could not catch
-- anything in the SAFARI; confirmed by him turning his other mods off.
--
-- Neither mod is wrong.  They are both right about a world they each assume
-- they own.  So for the length of a match this one asks the other to stand
-- down through its OWN published API, and puts it back on the way out.
--
-- THE WAY BACK IS THE WHOLE JOB.  Everything here is built around not
-- losing it:
--
--   * only what was actually suspended is restored.  If removeHooks() was
--     absent or threw, installHooks() is not called -- reinstalling hooks
--     that were never removed is its own bug.
--   * every call is pcall'd and every export is checked before it is
--     called.  Another mod's API changing between versions must degrade to
--     "not suspended", never to an error part-way through a match start.
--   * suspend() must not run twice, and NOTHING HERE STOPS IT.  A second
--     call finds the same mod again, calls removeHooks on it again, and
--     hands back a second live token -- restore both and installHooks runs
--     twice, which is the double-install this file exists to avoid.  The
--     only thing preventing it is the caller: main.lua suspends solely
--     under `if not self.suspendedMods`.  (Machines.apply guards the same
--     way but genuinely is idempotent -- it returns {} the second time.
--     This is NOT that, so do not reason from it.)  Asserted in br_test so
--     it stays true rather than aspirational.
--   * restore() takes the token, not an id, so it cannot depend on the
--     other mod still being findable at teardown.
--
-- Worth knowing: a suspend does not survive the process.  These mods install
-- their hooks on load, so if the game dies mid-match the next launch brings
-- them back by itself.  The exposure is a single session -- a player whose
-- match ended badly might have to restart the game to get their overworld
-- mons back, which is a bad afternoon, not a broken save.

local Coexist = {}

-- Each entry names a mod and the exports to call on the way in and the way
-- out.  Keep `suspend` and `restore` as lists of export NAMES, not
-- functions: this table is data, and br_test drives it against a fake.
Coexist.MODS = {
  {
    id = "overworld_wild_spawns",          -- "Wilds of Kanto"
    -- removeHooks uninstalls its encounter/collision wraps, which is what
    -- gives the SAFARI its vanilla encounters -- and BR's ghost lead --
    -- back.  clearAll takes its overworld mon off the map, which a match
    -- wants anyway: they would otherwise stand among the ghosts, the
    -- spills and the bots, and the ring's NPC sweep would be deciding what
    -- to do about them.
    suspend = { "removeHooks", "clearAll" },
    restore = { "installHooks" },
    -- The one suspend call the restore is the undo OF.  Named rather than
    -- assumed to be suspend[1]: clearAll is a courtesy with no way back and
    -- reordering the list must not silently re-point what gets reinstalled.
    restoreIf = "removeHooks",
  },
}

-- `find` is mod.find: id -> { id, version, exports } or nil when the other
-- mod is absent, disabled, failed, or has not run yet.  All four are
-- ordinary and silent -- most players have none of these installed.
local function callExport(handle, name, log)
  local fn = handle.exports and handle.exports[name]
  if type(fn) ~= "function" then
    if log then
      log:say("coexist: %s has no %s(); skipping", tostring(handle.id), name)
    end
    return false
  end
  local ok, err = pcall(fn)
  if not ok and log then
    log:warn("coexist: %s %s() failed: %s", tostring(handle.id), name,
             tostring(err))
  end
  return ok
end

-- Stand every known overworld mod down.  Returns a token to hand back to
-- restore() -- never nil, so a caller can always guard on "have I got one"
-- rather than on what is inside it.
function Coexist.suspend(find, log)
  local token = { entries = {} }
  if type(find) ~= "function" then return token end
  for _, spec in ipairs(Coexist.MODS) do
    local ok, handle = pcall(find, spec.id)
    -- An ABSENT mod is ordinary and silent; a find that THREW is not, and
    -- with no line here the whole feature no-ops with nothing to point at.
    if not ok and log then
      log:warn("coexist: looking up %s failed: %s -- not suspended",
               tostring(spec.id), tostring(handle))
    end
    if ok and type(handle) == "table" and handle.exports then
      -- record ONLY the calls that actually landed; restore reads this
      local done = {}
      for _, name in ipairs(spec.suspend) do
        if callExport(handle, name, log) then done[name] = true end
      end
      if next(done) then
        token.entries[#token.entries + 1] =
          { id = spec.id, handle = handle, spec = spec, done = done }
        -- Only the restoreIf call is "stood down" -- the rest are extras.
        -- Saying so unconditionally once reported a mod as suspended while
        -- its hooks were still live, which is worse than saying nothing.
        if log then
          if done[spec.restoreIf] then
            log:say("coexist: %s stood down for the match", tostring(spec.id))
          else
            log:warn("coexist: %s only partly stood down (no %s) -- its "
                     .. "hooks are still live", tostring(spec.id),
                     tostring(spec.restoreIf))
          end
        end
      end
    end
  end
  return token
end

-- Put back exactly what was taken away.  Safe to call with a nil or an
-- already-spent token: every exit path in main.lua runs through resetMatch,
-- and some of them arrive twice.
function Coexist.restore(token, log)
  if type(token) ~= "table" then return end
  for _, entry in ipairs(token.entries or {}) do
    -- the hooks only go back if this run is the one that took them out
    if entry.done and entry.done[entry.spec.restoreIf] then
      local back = true
      for _, name in ipairs(entry.spec.restore) do
        if not callExport(entry.handle, name, log) then back = false end
      end
      if log then
        if back then
          log:say("coexist: %s restored", tostring(entry.id))
        else
          -- the token is spent either way (below), so this line is the
          -- only record that the player is owed a restart
          log:warn("coexist: %s NOT restored -- it stays stood down until "
                   .. "the game is restarted", tostring(entry.id))
        end
      end
    end
  end
  token.entries = {}
end

-- what is currently stood down, for the log line and for tests
function Coexist.suspended(token)
  local out = {}
  for _, entry in ipairs((type(token) == "table" and token.entries) or {}) do
    out[#out + 1] = entry.id
  end
  table.sort(out)
  return out
end

return Coexist
