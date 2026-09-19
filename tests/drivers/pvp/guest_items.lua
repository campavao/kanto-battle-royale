-- POK-207 scenario "items", guest side: join the room, walk into the
-- host's eyeline in Pewter, and use a POTION in the middle of the duel.
--
-- Cable rules say no items and the engine keeps them by default: before
-- RFC 0021 the ITEM row printed "Items can't be used in a link battle!"
-- and the fog-and-potions economy stopped at the edge of a real fight.
-- So this drives the vanilla bag against a lockstep battle: take a hit,
-- open ITEM, pick the POTION, pick the mon, and let the item BE the turn.
-- The host next door asserts the other half -- that the heal crossed.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("GUESTI")

  local code = L.waitFor(DIR, "code.txt", 3600)
  if not code then return C.fail("no room code ever appeared") end
  code = code:gsub("%s", "")
  local joined = false
  for _ = 1, 10 do
    E.join(code)
    for _ = 1, 120 do
      U.wait(10)
      if E.memberCount() >= 2 then joined = true break end
    end
    if joined then break end
  end
  if not joined then
    return C.fail("could not join " .. code .. ": " .. tostring(E.lastError()))
  end
  U.log("PVP guest: in room " .. code)

  if not L.waitPhase(C, "match", 360) then
    return C.fail("never reached the match")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.wait(30)

  -- an even fight, so there are turns to spend: the same lead the host
  -- took, and a POTION to spend one of them on
  L.armParty(C, "RATTATA", 5, "TACKLE")
  game.save.inventory.POTION = 3
  game.save.bagOrder = nil

  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.waitFor(DIR, "posted.txt", 3600) then
    return C.fail("the host never posted")
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 20, 300) then
    return C.fail(("never reached the approach; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.log("PVP guest: below the post; stepping into the eyeline")

  local fought = false
  for _ = 1, 60 do
    if E.status() == "battle" then fought = true break end
    U.hold(game, "up", 12)
    U.wait(10)
    U.tap(game, "a")
    U.wait(10)
  end
  if not fought then
    fought = L.mashUntil(C, function() return E.status() == "battle" end, 1200)
  end
  if not fought then return C.fail("the duel never started on the guest side") end
  local lb
  for _ = 1, 900 do
    local top = game.stack:top()
    if type(top) == "table" and top.kind == "link" and top.player then lb = top break end
    U.wait(2)
  end
  if not lb then return C.fail("no link battle on the stack") end
  U.log("PVP guest: lockstep battle open")

  -- take a hit first: a POTION on a mon at full HP is refused, and the
  -- host's TACKLE is the damage
  local maxHP = lb.player.mon.stats.hp
  local hurt = false
  for _ = 1, 4000 do
    if lb.player.mon.hp < maxHP - 4 then hurt = true break end
    if E.status() ~= "battle" then break end
    if lb.phase == "menu" and game.stack:top() == lb then
      lb:resolveTurn(lb.player.curMoves[1])
    else
      U.tap(game, "a")
    end
    U.wait(4)
  end
  if not hurt then
    return C.fail(("never took a hit worth healing (%s/%s)")
                  :format(tostring(lb.player.mon.hp), tostring(maxHP)))
  end
  local before = lb.player.mon.hp
  U.log(("PVP guest: down to %d/%d; opening the bag"):format(before, maxHP))

  -- back to our own menu, then the ITEM row
  for _ = 1, 2000 do
    if lb.phase == "menu" and game.stack:top() == lb then break end
    U.tap(game, "a")
    U.wait(4)
  end
  if lb.phase ~= "menu" then
    return C.fail("never got back to the menu (phase " .. tostring(lb.phase) .. ")")
  end
  lb:chooseMenu("item")
  local bag
  for _ = 1, 400 do
    local top = game.stack:top()
    if type(top) == "table" and top.kind == "bag" and top.items then bag = top break end
    U.wait(1)
  end
  if not bag then
    return C.fail("ITEM did not open the bag in a link battle (top "
                  .. tostring(game.stack:top()) .. ")")
  end
  U.log("PVP guest: the bag opened in a link battle")
  local at
  for i, row in ipairs(bag.items) do
    if row.value == "POTION" then at = i break end
  end
  if not at then return C.fail("no POTION row in the battle bag") end
  bag.index = at
  U.wait(2)
  U.tap(game, "a")

  -- the target picker: one mon in the party, so the first pick is ours
  local picker
  for _ = 1, 400 do
    local top = game.stack:top()
    if top ~= bag and top ~= lb and type(top) == "table" then picker = top break end
    U.wait(1)
  end
  if not picker then return C.fail("the POTION never opened a target picker") end
  U.wait(4)
  U.tap(game, "a")

  -- and the turn goes on the wire: healed, and back at a menu (or the
  -- fight over) without the cable refusing anything
  local healed = false
  for _ = 1, 4000 do
    if lb.player.mon.hp > before then healed = true break end
    if E.status() ~= "battle" then break end
    U.tap(game, "a")
    U.wait(4)
  end
  if not healed then
    return C.fail(("the POTION did not heal us (%d, was %d)")
                  :format(lb.player.mon.hp, before))
  end
  U.log(("PVP guest: healed %d -> %d from the bag, mid-duel")
        :format(before, lb.player.mon.hp))

  -- keep playing while the host reads its side: an item that spends the
  -- turn must leave a fight that goes on
  for _ = 1, 600 do
    if L.get(DIR, "host_saw_potion.txt") then break end
    if E.status() ~= "battle" then break end
    if lb.phase == "menu" and game.stack:top() == lb then
      lb:resolveTurn(lb.player.curMoves[1])
    else
      U.tap(game, "a")
    end
    U.wait(6)
  end

  -- the item spent the turn, so the fight must still be running and
  -- still resolving turns with the host
  if not L.waitFor(DIR, "host_saw_potion.txt", 3600) then
    return C.fail("the host never saw the heal cross the cable")
  end
  U.log("PVP guest: the host saw it too")

  -- ...and the recorder carried the item, which is what a spectator
  -- replays (lib/mirror.lua slim)
  local log = E.mirrorLog() or {}
  local items = 0
  for _, f in ipairs(log) do
    if f.k == "link" and f.m and f.m.kind == "item" then
      items = items + 1
      if f.m.item ~= "POTION" then
        return C.fail("the recorded item frame says " .. tostring(f.m.item))
      end
    end
  end
  if items < 1 then
    return C.fail("the recorder logged no item frame in " .. #log .. " frames")
  end
  U.log("PVP guest: the recording carries the POTION for a spectator")

  L.put(DIR, "guest_done.txt", "1")
  U.log("PVP OK guest: the bag works in a real duel and the item rides the wire")
  love.event.quit(0)
  U.wait(10)
end
