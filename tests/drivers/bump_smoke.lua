-- POK-165: ghosts are not solid, and a bump is a challenge.
--
-- Two halves, on one bot in Pewter's street:
--
--   1. WALK-THROUGH.  The bot is marked mid-fight (its grass dwell's own
--      mark, held here by hand): nothing may start a fight with it -- not
--      the eyeline, not the bump -- so it has to be walked THROUGH.  The
--      player's cell has to pass the bot's.
--   2. THE BUMP.  With the mark gone, walking back into it starts the
--      fight, and the step is refused so the two stand face to face.
--
-- (A trainer battle cannot be RUN from, so the flee's grace is not the
-- lever here; the mark is.)
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-bump POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/bump_smoke.lua \
--   <path to>/lovec . > bump.log 2>&1
--
-- Exit 0 with a `BUMP OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SCOUT")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(1)
  local hosted = false
  for _ = 1, 300 do
    U.wait(10)
    if (E.memberCount() or 0) >= 1 then hosted = true break end
  end
  if not hosted then return C.fail("the solo room never came up") end
  E.start()
  if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
    return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ")")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "MACHOP", 20) }

  local function battleTop()
    local top = game.stack:top()
    return type(top) == "table" and top.enemyParty and top or nil
  end
  local function botX()
    local p = (E.players() or {})[1]
    return p and p.x
  end

  -- the street: player at 12,18 facing right, the bot two cells on
  U.teleport(game, "PEWTER_CITY", 12, 18, "right")
  U.wait(30)
  local ps = E.players() or {}
  local bot = ps[1] and ps[1].id
  if not bot then return C.fail("no bot to bump") end
  E.debugPlaceBot(bot, "PEWTER_CITY", 14, 18)
  -- its own roam clears a mark it did not make, so hold the mark by hand
  for _ = 1, 60 do
    E.debugBusy(bot, "battle")
    U.wait(1)
  end

  -- ------- 1. mid-fight: walk THROUGH it
  local startX = C.x()
  local passed, bx = false, botX()
  for _ = 1, 60 do
    E.debugBusy(bot, "battle")
    U.hold(game, "right", 12)
    E.debugBusy(bot, "battle")
    U.wait(3)
    if battleTop() or E.pending() then
      return C.fail("a fight started with a bot marked mid-fight")
    end
    bx = botX() or bx
    if bx and C.x() > bx then passed = true break end
  end
  if not passed then
    return C.fail(("never got past the bot: started %d, now %d, bot at %s")
      :format(startX, C.x(), tostring(bx)))
  end
  U.log(("BUMP: walked through the bot -- from %d to %d, past its cell %d"):format(startX, C.x(), bx))

  -- ------- 2. the mark gone: walking back into it is the challenge
  E.debugBusy(bot, nil)
  U.wait(10)
  local before = C.x()
  local opened = false
  for _ = 1, 120 do
    if battleTop() then opened = true break end
    U.hold(game, "left", 12)
    U.wait(3)
  end
  if not opened then
    return C.fail(("walking back into the bot started nothing (from %d to %d, pending %s)")
      :format(before, C.x(), tostring(E.pending() and E.pending().to)))
  end
  U.log(("BUMP: the fight opened after walking back into it (from %d to %d)"):format(before, C.x()))
  U.log("BUMP OK: walked through a bot mid-fight, fought on the bump once it was free")
  love.event.quit(0)
  U.wait(10)
end
