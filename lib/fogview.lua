-- The fog you can see (POK-78): a haze that creeps in from the screen
-- edges as the ring closes on the map you are standing on, and pulses over
-- you once it has you.  The heads-up line and the Town Map ring say WHERE
-- the fog is; this says it on the overworld itself, while you run.
--
-- The ring is per-map -- a whole map is safe or taken, there is no fog line
-- inside one -- so this reads as weather at the borders, not a wall.  It is
-- driven entirely by BR.ring (broadcast to every client), so it needs no
-- match clock and looks the same for a host, a guest, and a spectator
-- watching someone else's map.
--
-- Pure where it matters: state() is the whole intensity rule as plain
-- arithmetic, so tests/br_test.lua can check the curve without a screen.
-- drawVignette() is the only part that touches love.graphics.

local FogView = {}

-- dark purple, the same family the Town Map fog shading uses, so the two
-- reads of the fog match
FogView.COLOR = { 0.20, 0.13, 0.30 }
FogView.MAX_ALPHA = 0.55       -- the deepest the haze ever gets, at the edge
FogView.EDGE_BAND = 46         -- game pixels the vignette reaches in from each edge
FogView.EDGE_STEPS = 16        -- bands it fades across (draw cost = 4x this)
-- grid units of warning before the ring reaches your map: within this, the
-- haze starts creeping in even while you are still (just) safe
FogView.EDGE_MARGIN = 2.5
FogView.EDGE_PEAK = 0.5        -- how strong the pre-arrival creep gets (0..1)

-- The haze strength for a map at signed edge-distance `d` (negative inside
-- the ring, 0 at its edge, positive once the fog has the map), plus whether
-- it should pulse -- only once you are actually in it, on the bite beat.
--
-- coversAll is the final ring, where every map is fog.  A nil distance
-- (no ring, or a map the grid cannot place) is clean.
function FogView.state(d, coversAll)
  if coversAll then return 1, true end
  if d == nil then return 0, false end
  if d >= 0 then return 1, true end                 -- in the fog
  if d > -FogView.EDGE_MARGIN then                  -- safe, but it is nearly here
    return (1 + d / FogView.EDGE_MARGIN) * FogView.EDGE_PEAK, false
  end
  return 0, false                                   -- deep safe: clean screen
end

-- A pulse factor on the fog's own ~2 Hz beat, kept shallow so it breathes
-- rather than strobes.  t is seconds (love.timer.getTime).
function FogView.pulse(t)
  return 0.80 + 0.20 * math.abs(math.sin((t or 0) * 2))
end

-- Draw the edge vignette in 160x144 game-pixel space (the caller has
-- already translated/scaled to the viewport).  alpha is the peak edge
-- alpha; each band inward fades toward the center, so the play area stays
-- readable and the corners -- where two bands overlap -- sit darkest.
function FogView.drawVignette(g, alpha)
  local c = FogView.COLOR
  local steps = FogView.EDGE_STEPS
  local step = FogView.EDGE_BAND / steps
  local t = math.max(1, step)
  for i = 0, steps - 1 do
    local frac = 1 - i / steps            -- strongest at the very edge
    g.setColor(c[1], c[2], c[3], alpha * frac)
    local inset = i * step
    g.rectangle("fill", 0, inset, 160, t)               -- top
    g.rectangle("fill", 0, 144 - inset - t, 160, t)     -- bottom
    g.rectangle("fill", inset, 0, t, 144)               -- left
    g.rectangle("fill", 160 - inset - t, 0, t, 144)     -- right
  end
end

return FogView
