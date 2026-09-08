-- Gyms as contested one-shot bosses (POK-26, DESIGN D14).
--
-- A gym leader is a landmark: first trainer to fell them takes the prize
-- -- a themed TM straight into the bag (the POK-58 economy: machine moves
-- are only teachable from the bag, and teaching spends the TM) plus a
-- purse -- and the leader despawns everywhere on the npcout the beaten
-- path already speaks, so the gym is closed for the rest of the match.
-- The fog can fell a leader too; then the prize burned with them, which
-- is the race's clock.
--
-- The prizes mix canon and worth-racing-for: SURGE, KOGA and BLAINE hand
-- out their cartridge TMs; the others trade a dud canon TM for the power
-- pick of their type (BROCK's BIDE becomes ROCK SLIDE, GIOVANNI's
-- FISSURE becomes EARTHQUAKE).  SABRINA keeps PSYWAVE -- no psychic TM
-- item exists in the generated data.

local Gyms = {}

-- A leader fights AT the rung, like everything else in a match (POK-76).
-- There used to be a flat +10 on top -- "a boss, not a bot" -- and a flat
-- number is the one shape that cannot mean the same thing twice on a
-- ladder that runs 5 to 100: +10 over a rung-5 party is triple their
-- level and an instant wall, +10 over a rung-80 party is noise.  It made
-- the earliest gym the hardest and the last one free, which is backwards.
--
-- What makes a leader a boss is not the number: it is that there is ONE
-- of them, everyone wants the TM, and whoever gets there first closes the
-- gym for the rest of the match.  That contest is untouched.
Gyms.PURSE = 1000      -- the gym's money, on top of the TM

Gyms.LEADERS = {
  OPP_BROCK    = { name = "BROCK",    tm = "TM_ROCK_SLIDE",  label = "ROCK SLIDE TM" },
  OPP_MISTY    = { name = "MISTY",    tm = "TM_ICE_BEAM",    label = "ICE BEAM TM" },
  OPP_LT_SURGE = { name = "LT.SURGE", tm = "TM_THUNDERBOLT", label = "THUNDERBOLT TM" },
  OPP_ERIKA    = { name = "ERIKA",    tm = "TM_SOLARBEAM",   label = "SOLARBEAM TM" },
  OPP_KOGA     = { name = "KOGA",     tm = "TM_TOXIC",       label = "TOXIC TM" },
  OPP_SABRINA  = { name = "SABRINA",  tm = "TM_PSYWAVE",     label = "PSYWAVE TM" },
  OPP_BLAINE   = { name = "BLAINE",   tm = "TM_FIRE_BLAST",  label = "FIRE BLAST TM" },
  OPP_GIOVANNI = { name = "GIOVANNI", tm = "TM_EARTHQUAKE",  label = "EARTHQUAKE TM" },
}

function Gyms.leader(class)
  if not class then return nil end
  return Gyms.LEADERS[class]
end

-- The Elite Four are bosses of the same shape once their rooms stand
-- open (POK-143): no TM, no purse, but the same speech problem.
Gyms.ELITE = {
  OPP_LORELEI = { name = "LORELEI" },
  OPP_BRUNO   = { name = "BRUNO" },
  OPP_AGATHA  = { name = "AGATHA" },
  OPP_LANCE   = { name = "LANCE" },
}

-- a gym leader or an Elite Four member, by trainer class
function Gyms.boss(class)
  if not class then return nil end
  return Gyms.LEADERS[class] or Gyms.ELITE[class]
end

-- Bosses talk too much for a match (POK-193): a gym leader opens with the
-- whole vanilla speech and closes with the badge pages and the TM
-- explanation, several presses each side of one contested fight while
-- the fog keeps closing.  The match keeps ONE page before the fight --
-- the speech's first, which is the leader's name and gym -- and after a
-- win prints the purse line and nothing else.

-- the first page (up to the first \f) of a multi-page speech
function Gyms.firstPage(text)
  if type(text) ~= "string" or text == "" then return nil end
  local page = text:match("^(.-)\f") or text
  if page == "" then return nil end
  return page
end

-- what a beaten boss says when talked to again
function Gyms.beatenLine(name)
  return ("%s: You've\nbeaten me.\nGo on!"):format(tostring(name or "LEADER"))
end

-- the leader behind a broadcast npcout, from the map data every client has
function Gyms.leaderOfObject(maps, mapId, objName)
  local def = maps and maps[mapId]
  for _, o in ipairs((def and def.objects) or {}) do
    if o.name == objName then return Gyms.leader(o.trainerClass) end
  end
  return nil
end

return Gyms
