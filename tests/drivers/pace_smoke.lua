-- POK-186: the host's match options -- TEXT SPEED and BATTLE ANIMATION --
-- reach the live game for the length of a match and go back afterwards.
--
-- Solo, so it needs no relay: the solo start goes through the same
-- onStart as a guest's, with the same pace on the message.  What it
-- proves, in order:
--
--   1. setPace is what the lobby reports, and a solo room plays at it
--   2. after the drop, game.save.options carries the host's pace
--   3. LEAVE hands this player's own rows back, nil included
--   4. REVERT TO DEFAULT: a second match plays at MEDIUM / ON
--   5. ...and leaving that one hands the rows back again
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-pace POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/pace_smoke.lua \
--   <path to>/lovec . > pace.log 2>&1
--
-- `PACE OK` passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  local function rows()
    local o = game.save and game.save.options or {}
    return o.textSpeed, o.animations
  end
  local function show(what)
    local t, a = rows()
    U.log(("PACE: %s: text %s, animation %s"):format(what, tostring(t), tostring(a)))
  end
  local mineText, mineAnim = rows()
  show("my own rows before any match")

  E.setName("PACER")
  E.setSafari(0)
  E.setFog(600)

  -- one solo match at the host's pace, then one at the defaults
  local function runMatch(wantText, wantAnim, label)
    if not E.hostSolo() then return C.fail("hostSolo refused (" .. label .. ")") end
    E.setBots(1)
    local hosted = false
    for _ = 1, 300 do
      U.wait(10)
      if (E.memberCount() or 0) >= 1 then hosted = true break end
    end
    if not hosted then return C.fail("the solo room never came up (" .. label .. ")") end
    local p = E.pace()
    if not (p and p.textSpeed == wantText and p.animations == wantAnim) then
      return C.fail(("the lobby reports text %s, animation %s; wanted %s / %s (%s)"):format(
        tostring(p and p.textSpeed), tostring(p and p.animations),
        tostring(wantText), tostring(wantAnim), label))
    end
    E.start()
    if not L.mashUntil(C, function() return E.phase() == "match" end, 400) then
      return C.fail("never reached the match (phase " .. tostring(E.phase()) .. ", " .. label .. ")")
    end
    U.wait(30)
    show("in the match (" .. label .. ")")
    local t, a = rows()
    if t ~= wantText or a ~= wantAnim then
      return C.fail(("the match plays at text %s, animation %s; wanted %s / %s (%s)"):format(
        tostring(t), tostring(a), tostring(wantText), tostring(wantAnim), label))
    end
    E.leave()
    U.wait(90)
    show("after leaving (" .. label .. ")")
    t, a = rows()
    if t ~= mineText or a ~= mineAnim then
      return C.fail(("leaving left text %s, animation %s; mine were %s / %s (%s)"):format(
        tostring(t), tostring(a), tostring(mineText), tostring(mineAnim), label))
    end
    return true
  end

  -- 1-3: SLOW and OFF, the two values furthest from the defaults
  local set = E.setPace({ textSpeed = 5, animations = false })
  if not (set and set.textSpeed == 5 and set.animations == false) then
    return C.fail("setPace did not take")
  end
  if not runMatch(5, false, "host's pace") then return end

  -- 4-5: REVERT TO DEFAULT
  local back = E.revertPace()
  if not (back and back.textSpeed == 3 and back.animations == true) then
    return C.fail("revertPace is not MEDIUM / ON")
  end
  if not runMatch(3, true, "defaults") then return end

  U.log("PACE OK: the host's pace reaches the match and leaves with it")
  love.event.quit(0)
  U.wait(10)
end
