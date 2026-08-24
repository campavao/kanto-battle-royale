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

Gyms.BOSS_BONUS = 10   -- a leader fights above the rung: a boss, not a bot
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

-- the leader behind a broadcast npcout, from the map data every client has
function Gyms.leaderOfObject(maps, mapId, objName)
  local def = maps and maps[mapId]
  for _, o in ipairs((def and def.objects) or {}) do
    if o.name == objName then return Gyms.leader(o.trainerClass) end
  end
  return nil
end

return Gyms
