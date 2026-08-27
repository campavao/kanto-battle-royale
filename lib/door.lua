-- What a build mismatch MEANS, and what to say about it (POK-142).
--
-- lib/wire.lua carries the two version strings and answers whether they
-- differ; this answers the question a player actually has, which is "what
-- do I do about it".  Kept out of main.lua because it is all branches and
-- all copy, and both are worth testing without a room.
--
-- The two numbers, and why each one refuses a fight:
--
--   GAME    the engine release.  src/link/Handshake.lua checkCompat
--           compares the version STRING -- not the major, not the minor --
--           and returns `engine_skew` for any difference; battleAllowed
--           refuses it.  Deliberate: battle logic changes between minor
--           releases, so two installs a release apart would otherwise pair
--           as compatible and desync mid-fight.  A player fixes this
--           wherever they installed the game.
--
--   ROYALE  this mod's version.  src/link/Fingerprint.lua modKey folds
--           `id@version` of every enabled mod that has not declared
--           affects_link = false into the link digest -- and this mod has
--           not -- so a different version is a different digest, verdict
--           `subset`, battle refused.  A player fixes this from the
--           launcher's own Check for updates.
--
-- They are chased in two different places, which is the whole reason this
-- module bothers to tell them apart instead of saying "cannot battle".
--
-- EVERY authored line here fits 18 columns, the Gen 1 text box
-- (src/render/TextBox.lua MAX_COLS).  The box does soft-wrap, and on the
-- last space rather than mid-word, so a long line degrades into a tidy one
-- -- but a version number is exactly the thing worth never gambling on,
-- and a line break chosen here reads better than one chosen by arithmetic.

local Door = {}

-- How long the host keeps a note about a trainer it turned away.
--
-- It has to expire, and the reason is not tidiness.  A refused guest is
-- gone in about ONE FRAME -- the relay clocked 17-18ms between "GUESTB
-- joined" and "GUESTB left" -- so the note is the only thing the host ever
-- sees, and it has to sit there long enough to be read.  But it is keyed
-- on a relay id, and a player who goes away, updates and comes back gets a
-- NEW id: without an expiry the host would show a live "- GUESTB" and a
-- stale "! GUESTB" at once, with the mismatch row still up over a room
-- that had just been fixed.  Ninety seconds is long enough to notice and
-- short enough that it cannot outlive the problem it describes.
Door.NOTE_SECONDS = 90

-- The mismatches between two builds, structured: { label, theirs, mine }.
-- Empty when they agree, and empty for anything either side left unknown
-- -- a bot's place carries no build, and an absent number is not a
-- disagreement.
function Door.diffs(mine, theirs)
  local out = {}
  if type(mine) ~= "table" or type(theirs) ~= "table" then return out end
  if mine.engine and theirs.engine and mine.engine ~= theirs.engine then
    out[#out + 1] = { label = "GAME", theirs = theirs.engine, mine = mine.engine }
  end
  if mine.mod and theirs.mod and mine.mod ~= theirs.mod then
    out[#out + 1] = { label = "ROYALE", theirs = theirs.mod, mine = mine.mod }
  end
  return out
end

-- One flat clause per mismatch, for the log, where width is nobody's
-- problem and one grep-able line per event is worth more than layout.
function Door.parts(mine, theirs)
  local out = {}
  for _, d in ipairs(Door.diffs(mine, theirs)) do
    out[#out + 1] = ("%s v%s (you v%s)"):format(d.label, d.theirs, d.mine)
  end
  return out
end

-- ...and the same thing for a text box, or nil when there is nothing to
-- say.  Their number first on its own line, ours under it: the comparison
-- is the message, so the two want to be read one above the other.
function Door.sentence(name, mine, theirs)
  local diffs = Door.diffs(mine, theirs)
  if #diffs == 0 then return nil end
  local lines = { ("%s is on"):format(name or "A trainer") }
  for i, d in ipairs(diffs) do
    if i > 1 then lines[#lines + 1] = "...and on" end
    lines[#lines + 1] = ("%s v%s,"):format(d.label, d.theirs)
    lines[#lines + 1] = ("not your v%s."):format(d.mine)
  end
  lines[#lines + 1] = "You can't BATTLE."
  return table.concat(lines, "\n")
end

-- A peer we could not even decode.  Their versions rode the message we
-- threw away, so this is the one case with no numbers in it -- but the
-- PROTOCOL that refused them is this mod's own, so it is still a mod
-- mismatch and still says which way to look.
function Door.oldSentence(name)
  return ("%s is on\nanother BATTLE\nROYALE. You can't\nBATTLE."):format(
    name or "A trainer")
end

-- What a reader would have to change, given a set of mismatches.  Reader-
-- addressed, so it only belongs where we know the reader is the one who is
-- behind -- which is exactly the refusal screen and nowhere else.
function Door.action(diffs)
  local engineBad, modBad = false, false
  for _, d in ipairs(diffs or {}) do
    if d.label == "GAME" then engineBad = true else modBad = true end
  end
  if engineBad and modBad then return "UPDATE BOTH" end
  if engineBad then return "UPDATE THE GAME" end
  if modBad then return "UPDATE ROYALE" end
  return nil
end

-- The screen a guest gets INSTEAD of the room (POK-142).  Rows, not a text
-- box: a refusal happens on the ROYALE screen, which opens from the TITLE
-- as well as the start menu, and teardown's own message is documented as
-- lost on the way to the title (POK-115).  A screen the player is already
-- looking at cannot be swallowed.
--
-- Both builds in full, ours under theirs, because the numbers are the
-- whole content -- and because a player who has to ask someone else "what
-- are you on?" needs to be able to read their own off the same screen.
function Door.refusalRows(mine, theirs)
  local diffs = Door.diffs(mine, theirs)
  if #diffs == 0 then return nil end
  local rows = { "CANNOT JOIN", Door.action(diffs), "ROOM HAS" }
  for _, d in ipairs(diffs) do
    rows[#rows + 1] = ("%s v%s"):format(d.label, d.theirs)
  end
  rows[#rows + 1] = "YOU HAVE"
  for _, d in ipairs(diffs) do
    rows[#rows + 1] = ("%s v%s"):format(d.label, d.mine)
  end
  return rows
end

-- The lobby's summary row for a whole room, or nil when it is fightable.
-- `peers` is an array of { build = { engine =, mod = } } or { old = true };
-- a peer with neither is one we have nothing to say about yet, which is
-- not the same as one we agree with.
--
-- STATES A FACT, and deliberately does not tell the reader to update.
-- Once a mismatched guest is refused the room outright, the only person
-- who ever reads this row is the HOST -- and a host whose guest is the one
-- running something old must not be told to go and change their own
-- install.  The actionable wording lives on the refusal screen, where we
-- know who is behind because they are the one being turned away.
function Door.label(mine, peers)
  local engineBad, modBad = false, false
  for _, peer in ipairs(peers or {}) do
    if peer.old then
      modBad = true
    else
      for _, d in ipairs(Door.diffs(mine, peer.build)) do
        if d.label == "GAME" then engineBad = true else modBad = true end
      end
    end
  end
  if engineBad and modBad then return "! BUILD MISMATCH" end
  if engineBad then return "! GAME MISMATCH" end
  if modBad then return "! ROYALE MISMATCH" end
  return nil
end

return Door
