-- POK-161: the empty lobby carries the server's game-time line.
--
-- Needs a relay running with a motd, which the runner provides:
--
--   cd mods/battle_royale/relay && BR_MOTD="GAME NIGHT DAILY\n7PM CENTRAL" \
--     node server.js &   (port 7790)
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-motd POKEPORT_SPEED=3 BR_PVP_RELAY=127.0.0.1:7790 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/motd_smoke.lua \
--   <path to>/lovec . > motd.log 2>&1
--
-- Exit 0 with a `MOTD OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("ASKER")
  E.host()

  local info
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 30 do
    info = E.serverInfo()
    if info and info.motdRows and #info.motdRows > 0 then break end
    U.wait(10)
  end
  if not (info and info.motdRows and #info.motdRows > 0) then
    return C.fail("no motd arrived (err " .. tostring(E.lastError()) .. ")")
  end
  if info.motdRows[1] ~= "GAME NIGHT DAILY"
     or info.motdRows[2] ~= "7PM CENTRAL" then
    return C.fail("motd rows wrong: " .. table.concat(info.motdRows, "|"))
  end
  if (info.conns or 0) < 1 then
    return C.fail("conns missing from the info line")
  end
  U.log(("MOTD OK: %s / %s (conns %d)")
    :format(info.motdRows[1], info.motdRows[2], info.conns))
  love.event.quit(0)
  U.wait(30)
end
