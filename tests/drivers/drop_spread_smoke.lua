-- POK-147: a full-lobby drop must not resolve itself.
--
-- Thirty bots dealt over the eleven fly towns wrapped into 2-3 per town,
-- every pair in sight-line at t=0, and 18 of 31 trainers were gone before
-- the player met anybody.  The deal now draws from every outdoor map the
-- Town Map can place (BR:botDropSpots), so at the cap each bot starts a
-- map of its own and nobody can meet before a roam clock fires.
--
-- Host a solo room at the cap, land, and check two things:
--
--   1. at the drop, every live bot stands on a map of its own, and
--   2. for the first dozen seconds -- less than the fastest seam clock --
--      nobody is eliminated at all.
--
-- On the pre-fix code both fail loudly (towns hold 2-3 bots each and the
-- roster collapses immediately).  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-drop-spread POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/drop_spread_smoke.lua \
--   <path to>/lovec . > drop_spread.log 2>&1
--
-- Exit 0 with a `SPREAD OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("SCOUT")
  E.setSafari(0)
  E.setFog(600)              -- the fog must not thin anybody for us
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(Bots.MAX)

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

  -- 1. the deal: one map each
  local roster = E.bots() or {}
  local alive, seen, shared = 0, {}, nil
  for _, b in ipairs(roster) do
    if b.status == "alive" then
      alive = alive + 1
      if b.map and seen[b.map] then
        shared = ("%s and %s both dropped on %s"):format(
          tostring(seen[b.map]), tostring(b.name), tostring(b.map))
      end
      seen[b.map or ("?" .. alive)] = b.name
    end
  end
  if alive < Bots.MAX then
    return C.fail(("only %d of %d bots alive at the drop"):format(alive, Bots.MAX))
  end
  if shared then return C.fail("the deal wrapped: " .. shared) end
  U.log(("SPREAD: %d bots on %d distinct maps at t=0"):format(alive, alive))

  -- 2. the quiet dozen seconds.  The fastest seam clock is an ACE's
  -- (roamSeconds * 0.6), so before it fires nobody can have crossed into
  -- anybody and the count must hold.  A bot engaging ME is fine -- that
  -- does not eliminate anyone -- so the watch only reads the count.
  local want = E.aliveCount()
  local horizon = math.floor(Bots.roamSeconds(want, Bots.TIERS[3]) * 0.8)
  for i = 1, horizon * 2 do
    U.wait(30)
    local now = E.aliveCount()
    if now < want then
      return C.fail(("%d eliminations inside the first %ds -- the drop is "
        .. "still resolving itself"):format(want - now, math.ceil(i / 2)))
    end
  end
  U.log(("SPREAD OK: %d trainers, one map each, nobody out inside %ds")
    :format(want, horizon))
  love.event.quit(0)
  U.wait(30)
end
