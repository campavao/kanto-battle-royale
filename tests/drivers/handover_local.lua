-- Not a test: sets the relay to the local one and hands the game to a
-- person.  The harness quits the moment a driver coroutine dies (main.lua's
-- driver loop), so this one never returns -- it yields forever, pressing
-- nothing, and every real keypress plays the game as usual.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-hands POKEPORT_DRIVER=... lovec .
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local E = C.E()
  if E then
    E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
    U.log("HANDOVER: relay preset to the local one; the game is yours")
  end
  while true do
    coroutine.yield()
  end
end
