-- The ticker: news that does not stop the game.
--
-- A match has a clock, and every text box the mod used to push -- the fog
-- moved, somebody's GRAVELER became a GOLEM, a leader fell across town --
-- cost the player an A press and (POK-169) up to three seconds of standing
-- still.  None of that was a decision.  So it goes here instead: a small
-- box in the top-left corner, one item at a time, each shown for a beat
-- and then replaced by the next, and nothing under it waits.  A queued
-- line is drawn over the overworld only (the HUD hook that draws it asks),
-- so its clock runs while it can be read and not while a battle hides it.
--
-- Two kinds of line share the box:
--
--   push  -- news.  Queued, shown in order, each for SECONDS.
--   hold  -- a standing line: what the player is looking at right now (a
--            spilled ball's POKeMON and its icon, a fallen trainer's BAG),
--            set every frame by whoever knows and cleared when they look
--            away.  It outranks the news: a ball underfoot is a decision
--            being made now, and the drop's four lines of news were
--            hiding it for ten seconds.  News waits, its clock stopped,
--            and goes on from a fresh beat when the player looks away.
--
-- Pure: no love, no game, so br_test can pin the queue and the wrap.

local Ticker = {}

Ticker.SECONDS = 2.5    -- one item stays this long
Ticker.WIDTH = 18       -- text columns: the row is 20 tiles, two are border
Ticker.ROWS = 2         -- a line wraps once; anything longer is cut
Ticker.MAX_QUEUE = 8    -- news that piled up behind a long fight is old news

function Ticker.new()
  return { q = {}, line = nil, since = nil, held = nil }
end

-- Wrap `text` to at most ROWS rows of WIDTH columns.  An explicit "\n" is a
-- row break; a row too long breaks at its last space, and one word that is
-- itself too long is cut.  Returns the rows, or nil for nothing to show.
function Ticker.fit(text, width, rows)
  width, rows = width or Ticker.WIDTH, rows or Ticker.ROWS
  if type(text) ~= "string" then return nil end
  local out = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    para = para:gsub("^%s+", ""):gsub("%s+$", "")
    while para ~= "" and #out < rows do
      if #para <= width then
        out[#out + 1] = para
        para = ""
      else
        local cut = width
        local sp = para:sub(1, width + 1):match(".*()%s")
        if sp and sp > 1 then cut = sp - 1 end
        out[#out + 1] = para:sub(1, cut)
        para = para:sub(cut + 1):gsub("^%s+", "")
      end
    end
    if #out >= rows then break end
  end
  if #out == 0 then return nil end
  return out
end

-- Queue a line.  `icon` names a species whose party icon rides beside the
-- text.  The same text as the item last queued is dropped: a beat that two
-- paths both announce (a fog shrink and the rung it moved) is one item.
function Ticker.push(t, text, icon)
  local rows = Ticker.fit(text)
  if not rows then return false end
  local last = t.q[#t.q] or t.line
  if last and last.text == text then return false end
  if #t.q >= Ticker.MAX_QUEUE then table.remove(t.q, 1) end
  t.q[#t.q + 1] = { text = text, rows = rows, icon = icon }
  return true
end

-- Advance the clock: the item on show comes down after SECONDS and the
-- next goes up.  Called from the draw, so a beat only elapses while the
-- box can be seen.  Returns what is on show now: the held line if there
-- is one (the news waits under it, clock stopped), else the news.
function Ticker.tick(t, now)
  if t.held then
    if t.line then t.paused = true end
    return t.held
  end
  if t.paused then
    t.paused = nil
    t.since = now
  end
  if t.line and t.since and (now - t.since) >= Ticker.SECONDS then
    t.line, t.since = nil, nil
  end
  if not t.line and t.q[1] then
    t.line = table.remove(t.q, 1)
    t.since = now
  end
  return t.line
end

function Ticker.showing(t) return t.held or t.line end

-- The standing line, or nil to clear it.
function Ticker.hold(t, text, icon)
  if not text then t.held = nil return end
  local rows = Ticker.fit(text)
  if not rows then t.held = nil return end
  if t.held and t.held.text == text and t.held.icon == icon then return end
  t.held = { text = text, rows = rows, icon = icon }
end

function Ticker.pending(t) return #t.q end

function Ticker.clear(t)
  t.q, t.line, t.since, t.held, t.paused = {}, nil, nil, nil, nil
end

-- The box for an item: width in tiles and height in tiles.  An icon is
-- two tiles square, so an item with one is always two rows tall; a plain
-- item is as tall as its text.
function Ticker.boxOf(item)
  local w = 0
  for _, r in ipairs(item.rows) do if #r > w then w = #r end end
  local rows = #item.rows
  if item.icon then
    rows = 2
    return w + 2 + 2 + 1, rows + 2
  end
  return w + 2, rows + 2
end

return Ticker
