-- Does the sandbox arena load, draw, and walk?
local U = require("tests.drivers.util")

return function(game)
  local SHOTS = os.getenv("BR_SHOTS")
  game:startNewGame({ intro = false })
  U.wait(5)

  local def = game.data and game.data.maps and game.data.maps.BR_ARENA
  U.log("registered:", tostring(def ~= nil),
        def and ("%dx%d blocks outdoor=%s objects=%d signs=%d"):format(
          def.width, def.height, tostring(def.outdoor),
          #(def.objects or {}), #(def.signs or {})) or "")
  if not def then love.event.quit(1) return end

  local Spawn = require("mods.battle_royale.lib.spawn")
  local pool = Spawn.outdoorMaps(game.data.maps)
  local inPool = false
  for _, id in ipairs(pool) do if id == "BR_ARENA" then inPool = true end end
  U.log("drop pool:", #pool, "maps; arena in it =", tostring(inPool))

  U.teleport(game, "BR_ARENA", 12, 10, "down")
  U.wait(20)
  local ow = game.stack:top()
  local function at() return ow.player.cellX, ow.player.cellY end
  U.log("standing at", ow.map and ow.map.id, at())
  U.log("npcs on map:", #(ow.npcs or {}))

  U.hold(game, "left", 60) U.wait(15)
  U.log("after left:", at())
  U.hold(game, "up", 240) U.wait(15)
  U.log("after up into the ring:", at())

  if SHOTS then U.shot(game, SHOTS .. "/arena.png") end
  U.log("ARENA OK")
  love.event.quit(0)
end
