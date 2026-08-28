-- POK-144 scenario "again", guest side: the client the bug stranded.
--
-- This side WINS match 1 and then does the one thing a real player does
-- with a Hall of Fame -- it reads it.  From the moment the MATCH RECORD
-- card comes up until the host's `start` lands, it presses NOTHING: that
-- card waits for A forever and holds phase at "over" with started = true,
-- which is exactly the state the dropped `start` was refused in.
--
-- The assertion is that match 2 arrives anyway.  The career is the second
-- half: wins are pinned to 1 before match 1, so winning it makes 2 -- and
-- LASS unlocks at exactly 3 (lib/skins.lua:18), so a SECOND win banked for
-- a match this client never played flips it.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local function wall() return love.timer.getTime() end

  local function fameCard()
    local top = game.stack:top()
    if type(top) ~= "table" then return nil end
    if top.pages == nil or top.showPage == nil then return nil end
    local pg = top.pages[top.i]
    return top, pg and pg.kind
  end
  local function fameOnStack()
    for _, s in ipairs((game.stack and game.stack.states) or {}) do
      if type(s) == "table" and s.pages and s.showPage then return s end
    end
    return nil
  end
  local function skins()
    local out, byId = {}, {}
    for _, e in ipairs(C.E().skinState() or {}) do
      byId[e.id] = e
      out[#out + 1] = ("%s@%s=%s"):format(tostring(e.id), tostring(e.wins),
                                          e.unlocked and "UNLOCKED" or "locked")
    end
    return table.concat(out, " "), byId
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("GUESTA")

  local code = L.waitFor(DIR, "code.txt", 1800)
  if not code then return C.fail("no room code was ever published") end
  E.join(code)
  local joined = false
  for _ = 1, 1800 do
    U.wait(10)
    if E.memberCount() >= 2 then joined = true break end
  end
  if not joined then
    return C.fail("never joined room " .. tostring(code) .. ": "
      .. tostring(E.lastError()))
  end

  -- 1 win, so this client's OWN win in match 1 makes 2 and LASS (3) stays
  -- locked unless a second one is banked
  local pinned = E.debugSetWins(1)
  local before, byBefore = skins()
  U.log(("PVP guest: in room %s; career pinned to %s -- %s")
    :format(tostring(code), tostring(pinned), before))
  if pinned ~= 1 then return C.fail("debugSetWins(1) returned " .. tostring(pinned)) end
  if not (byBefore.LASS and byBefore.LASS.wins == 3) then
    return C.fail("LASS is no longer the 3-win skin; pick a new boundary")
  end
  if byBefore.LASS.unlocked then return C.fail("LASS is unlocked at 1 win") end
  L.put(DIR, "guestready.txt", "1")

  -- ---------------------------------------------------------- match 1
  if not L.waitPhase(C, "match", 600) then
    return C.fail("match 1 never reached this client")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.log(("PVP guest: match 1, on %s at %s,%s")
    :format(tostring(C.map()), tostring(C.x()), tostring(C.y())))
  L.put(DIR, "guestm1.txt", "1")

  -- the host crowns us.  NOT ONE PRESS from here.
  local cardAt
  local tw = wall()
  while (wall() - tw) < 90 do
    local _, kind = fameCard()
    if kind == "card" then cardAt = wall() break end
    U.wait(1)
  end
  if not cardAt then
    return C.fail(("the MATCH RECORD card never came up (phase %s, top %s)")
      :format(tostring(E.phase()), tostring(game.stack:top() == C.ow()
              and "overworld" or "other")))
  end
  local mid, midBy = skins()
  U.log(("PVP guest: MATCH RECORD card up %.2fs after match 1 started to end; "
         .. "phase=%s, career now %s"):format(cardAt - tw, tostring(E.phase()), mid))
  if not (midBy.YOUNGSTER and midBy.YOUNGSTER.unlocked) then
    return C.fail("winning match 1 did not bank a win at all")
  end
  if midBy.LASS.unlocked then
    return C.fail("match 1 banked more than one win: LASS (3) is unlocked")
  end
  L.put(DIR, "guestcard.txt", "1")

  -- ---------------------------------------------------------- match 2
  -- Zero input.  The card is still up; the host is about to press PLAY
  -- AGAIN.  Under the bug the `start` is dropped here and this client
  -- sits on this screen for the whole of the next match.
  local tCard = wall()
  local heldFor, gotMatch = 0, nil
  while (wall() - tCard) < 120 do
    if E.phase() == "match" then gotMatch = wall() break end
    local _, kind = fameCard()
    if kind == "card" then heldFor = wall() - tCard end
    U.wait(1)
  end
  if not gotMatch then
    return C.fail(("MATCH 2 NEVER REACHED THIS CLIENT: %.1fs on the MATCH "
      .. "RECORD card with zero input, phase still %s -- the `start` was dropped")
      :format(wall() - tCard, tostring(E.phase())))
  end
  U.log(("PVP guest: MATCH 2 ARRIVED %.2fs after the card came up (%.1fs of "
         .. "which the card was still on screen), with zero input from this side")
    :format(gotMatch - tCard, heldFor))
  U.wait(30)
  local leftover = fameOnStack()
  U.log(("PVP guest: match 2 -- phase=%s status=%s on %s at %s,%s; "
         .. "match 1's Hall of Fame on the stack: %s")
    :format(tostring(E.phase()), tostring(E.status()), tostring(C.map()),
            tostring(C.x()), tostring(C.y()), tostring(leftover ~= nil)))
  if leftover ~= nil then
    return C.fail("match 1's Hall of Fame is still on the stack in match 2")
  end
  if E.status() ~= "alive" then
    return C.fail("status in match 2 is " .. tostring(E.status()) .. ", not alive")
  end
  if C.map() == nil then
    return C.fail("no overworld in match 2 -- there is no spawn under this client")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end

  -- walk, so the host can see this client is a real broadcaster and not a
  -- roster row: the phantom's whole signature is never moving again
  local tWalk = wall()
  local i = 0
  while (wall() - tWalk) < 24 do
    i = i + 1
    U.hold(game, (i % 4 < 2) and "left" or "right", 14)
    U.wait(6)
    if E.phase() ~= "match" then break end
  end
  U.log(("PVP guest: walked match 2 for %.1fs, now on %s at %s,%s (phase %s)")
    :format(wall() - tWalk, tostring(C.map()), tostring(C.x()), tostring(C.y()),
            tostring(E.phase())))

  -- end match 2 by STEPPING OUT, on the host's word: the host is then the
  -- only survivor and its checkWinner does the crowning, so this client
  -- must land on the lobby with NO second win banked
  if not L.waitFor(DIR, "m2go.txt", 1800) then
    return C.fail("the host never called time on match 2")
  end
  local st = E.debugOut("driver")
  U.log(("PVP guest: stepped out of match 2 (status %s)"):format(tostring(st)))
  if st ~= "out" then return C.fail("debugOut left status " .. tostring(st)) end
  -- The no-input window is OVER: it covered match 1's card through match
  -- 2's arrival, which is the whole point.  From here a card may come up
  -- again -- the room watches ONE ending (POK-107), so the host's `fame`
  -- parades on this side too -- and it waits for A like any other.
  local tEnd = wall()
  local lobby, cardAt2, pressed2 = false, nil, false
  while (wall() - tEnd) < 120 do
    if E.phase() == "lobby" then lobby = true break end
    local top = game.stack:top()
    if type(top) == "table" and top.pages and top.showPage then
      local pg = top.pages[top.i]
      if pg and pg.kind == "card" then
        cardAt2 = cardAt2 or wall()
        if not pressed2 and (wall() - cardAt2) > 1.0 then
          pressed2 = true
          U.log("PVP guest: the host's MATCH RECORD card is up here too; "
                .. "pressing A once")
          U.tap(game, "a")
        end
      end
    end
    U.wait(1)
  end
  if not lobby then
    return C.fail("match 2 never brought this client back to the lobby (phase "
      .. tostring(E.phase()) .. ")")
  end
  U.wait(60)
  local after, byAfter = skins()
  local res = E.lastResult()
  U.log(("PVP guest: lobby after match 2; career %s; lastResult{won=%s winnerId=%s}")
    :format(after, tostring(res and res.won), tostring(res and res.winnerId)))
  if byAfter.LASS.unlocked then
    return C.fail("A SECOND CAREER WIN WAS BANKED -- LASS (3 wins) unlocked; "
      .. "this client won match 1 only")
  end
  if not byAfter.YOUNGSTER.unlocked then
    return C.fail("the career lost match 1's win: YOUNGSTER (1) is locked")
  end
  if res and res.won ~= false then
    return C.fail("this client thinks it won match 2: won=" .. tostring(res.won))
  end
  L.put(DIR, "guestdone.txt", "1")
  U.log("PVP OK")
  love.event.quit(0)
  U.wait(30)
end
