-- POK-144 scenario "again", host side: the phantom survivor, staged with
-- two real clients.
--
-- The cascade this reproduces: the host STEPS OUT of match 1 in a room
-- with no bots, so checkWinner finds exactly one survivor and broadcasts
-- `winner` for the GUEST -- a real ending over the wire, not a local
-- declaration.  The guest's Hall of Fame runs and parks on the MATCH
-- RECORD card, which waits for A forever (lib/fame.lua) and pushes the
-- exit's clocks out every frame it is up.  The host, who did not win,
-- lands back on the lobby in seconds
-- and presses PLAY AGAIN.  The `start` that goes out finds the guest still
-- at "over" with started = true -- which used to be a reason to DROP the
-- message (main.lua onMessage), with no log line and nothing on screen.
-- startMatch had already allocated that guest a spawn, every client seeded
-- them "alive", and nothing they owned ever broadcast again: the fog could
-- not reach them, checkWinner counted them to the end, and the phantom was
-- crowned -- a career win on a machine that never played the match.
--
-- This side asserts the half only the host can see: that the guest is a
-- REAL participant in match 2 -- allocated a spawn AND broadcasting from
-- it.  A phantom is "alive" on the roster and never moves, so the test is
-- distinct positions over time, not the status word.
local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local Bots = require("mods.battle_royale.lib.bots")

return function(game)
  local C = L.ctx(game)
  local DIR = os.getenv("BR_PVP_DIR")
  if not DIR then return C.fail("no BR_PVP_DIR") end
  local function wall() return love.timer.getTime() end

  -- The room watches ONE ending (POK-107): the champion broadcasts `fame`
  -- and every other client parades it, so this side lands on a MATCH
  -- RECORD card of its own after a match it did not win -- and that card
  -- waits for A and pushes the exit's clocks out while it is up.  One
  -- press, a second after it appears; the card's own no-input behaviour is
  -- the `card` scenario's job, not this one's.
  local function waitLobby(seconds, what)
    local E0 = C.E()
    local t = love.timer.getTime()
    local cardAt, pressed = nil, false
    while (love.timer.getTime() - t) < seconds do
      if E0.phase() == "lobby" then return true, love.timer.getTime() - t end
      local top = game.stack:top()
      if type(top) == "table" and top.pages and top.showPage then
        local pg = top.pages[top.i]
        if pg and pg.kind == "card" then
          cardAt = cardAt or love.timer.getTime()
          if not pressed and (love.timer.getTime() - cardAt) > 1.0 then
            pressed = true
            U.log(("PVP host: a MATCH RECORD card is up after %s; pressing A once")
              :format(what))
            U.tap(game, "a")
          end
        end
      end
      U.wait(1)
    end
    return false
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setRelay(os.getenv("BR_PVP_RELAY") or "127.0.0.1:7790")
  E.setName("HOSTA")
  E.setBots(0)          -- nobody but the two of us: stepping out crowns
                        -- the other side, and checkWinner does the sending
  E.setSafari(0)
  E.setFog(600)
  E.host()

  local code
  for _ = 1, 600 do
    U.wait(10)
    code = E.code()
    if code then break end
  end
  if not code then
    return C.fail("hosting never produced a code: " .. tostring(E.lastError()))
  end
  L.put(DIR, "code.txt", tostring(code))
  U.log("PVP host: room " .. tostring(code))

  local both = false
  for _ = 1, 1800 do
    U.wait(10)
    if E.memberCount() >= 2 then both = true break end
  end
  if not both then return C.fail("the guest never joined") end
  if not L.waitFor(DIR, "guestready.txt", 1800) then
    return C.fail("the guest never armed itself")
  end

  -- ---------------------------------------------------------- match 1
  U.log("PVP host: starting match 1")
  E.start()
  if not L.waitPhase(C, "match", 240) then
    return C.fail("match 1 never started on the host")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end

  local guestId
  for _ = 1, 300 do
    for _, p in ipairs(E.players() or {}) do
      if p.id and not Bots.isBot(p.id) then guestId = p.id end
    end
    if guestId then break end
    U.wait(10)
  end
  if not guestId then
    return C.fail("the host never saw a human peer on the roster")
  end
  U.log(("PVP host: match 1 up; the guest is %s"):format(tostring(guestId)))
  if not L.waitFor(DIR, "guestm1.txt", 1800) then
    return C.fail("the guest never reached match 1")
  end

  -- crown the GUEST the only way the wire can carry: step out, and let
  -- checkWinner find the one survivor and broadcast it
  U.log(("PVP host: stepping OUT of match 1 so the guest (%s) is crowned")
    :format(tostring(guestId)))
  local st = E.debugOut("driver")
  if st ~= "out" then return C.fail("debugOut left status " .. tostring(st)) end
  local over = false
  for _ = 1, 2000 do
    if E.phase() == "over" then over = true break end
    U.wait(1)
  end
  if not over then
    return C.fail("stepping out did not end match 1 (phase " .. tostring(E.phase())
      .. ", alive " .. tostring(E.aliveCount()) .. ")")
  end
  local landed, took = waitLobby(60, "match 1")
  if not landed then
    return C.fail("the host never got back to the lobby after match 1 (phase "
      .. tostring(E.phase()) .. ")")
  end
  U.log(("PVP host: back on the lobby %.2fs after match 1 ended"):format(took))

  if not L.waitFor(DIR, "guestcard.txt", 1800) then
    return C.fail("the guest never reported parking on the MATCH RECORD card")
  end
  U.log("PVP host: the guest is parked on the MATCH RECORD card and has not "
        .. "pressed anything.  PLAY AGAIN now.")

  -- ---------------------------------------------------------- match 2
  E.playAgain()
  U.wait(30)
  E.start()
  L.put(DIR, "m2.txt", "1")
  if not L.waitPhase(C, "match", 240) then
    return C.fail("match 2 never started on the host")
  end
  for _ = 1, 8 do U.tap(game, "a") U.wait(20) end
  U.log(("PVP host: match 2 up, %s in the room, %s alive")
    :format(tostring(E.memberCount()), tostring(E.aliveCount())))

  -- Does the guest actually LIVE in match 2?  A phantom sits "alive" on
  -- the roster at the spawn startMatch allocated it and never sends
  -- another byte, so the honest question is how many distinct cells this
  -- side ever sees them on.
  local seen, order, status1 = {}, {}, nil
  local tw = wall()
  while (wall() - tw) < 25 do
    for _, p in ipairs(E.players() or {}) do
      if p.id == guestId then
        status1 = p.status
        local key = ("%s@%s,%s"):format(tostring(p.map), tostring(p.x), tostring(p.y))
        if not seen[key] then
          seen[key] = true
          order[#order + 1] = ("t+%.1f %s"):format(wall() - tw, key)
        end
      end
    end
    U.wait(2)
  end
  U.log(("PVP host: the guest's status in match 2 is %s; %d distinct cells seen")
    :format(tostring(status1), #order))
  for _, s in ipairs(order) do U.log("PVP host:   " .. s) end
  if status1 ~= "alive" then
    return C.fail("the guest is " .. tostring(status1) .. " in match 2, not alive")
  end
  if #order < 2 then
    return C.fail(("THE GUEST IS A PHANTOM: \"alive\" on the roster and seen on "
      .. "%d cell(s) in 25s -- it never broadcast"):format(#order))
  end

  -- and end match 2 the other way round: the GUEST steps out, so this
  -- side is crowned and the guest banks nothing
  L.put(DIR, "m2go.txt", "1")
  U.log("PVP host: told the guest to step out of match 2")
  local back, took2 = waitLobby(90, "match 2")
  if not back then
    return C.fail("the host never got back to the lobby after match 2 (phase "
      .. tostring(E.phase()) .. ")")
  end
  local res = E.lastResult()
  U.log(("PVP host: lobby %.2fs after match 2; lastResult{won=%s winnerId=%s}")
    :format(took2, tostring(res and res.won), tostring(res and res.winnerId)))
  if not res then return C.fail("no lastResult on the lobby after match 2") end
  -- the guest stepping out leaves this side the only survivor, and
  -- checkWinner ran here: a match 2 the guest was never really in could
  -- not have ended at all
  if res.won ~= true then
    return C.fail("match 2 did not end with this side crowned: won="
      .. tostring(res.won))
  end
  if res.winnerId == guestId then
    return C.fail("match 2 crowned the guest, who stepped out")
  end
  L.put(DIR, "hostdone.txt", "1")
  -- Do NOT quit yet.  This process leaving takes the room down with it,
  -- and the guest's own ending -- winner over the wire, then the exit --
  -- lands a couple of seconds after this side's.  Quitting here dropped
  -- the guest to phase "off" mid-teardown and failed the run on the
  -- harness rather than on the mod.
  if not L.waitFor(DIR, "guestdone.txt", 1800) then
    return C.fail("the guest never finished; holding the room open did not help")
  end
  U.log("PVP host: the guest is done too; closing the room")
  U.log("PVP OK")
  love.event.quit(0)
  U.wait(30)
end
