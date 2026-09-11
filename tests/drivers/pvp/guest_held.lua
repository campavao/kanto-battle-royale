-- POK-162 scenario "held", guest side: the trainer who is busy.
--
-- Stand at (11,18) in Pewter, under the GYM sign, three cells down the
-- row from the host's post.  Put a script's text up (debugSay: the
-- runner's own box, the one a challenge may NOT pop), and while it is up
-- the host's challenge lands.  (A MENU is popped for a challenge since
-- POK-199 -- see the "menu" scenario; a running script is not, and this
-- is the script case.)  It has to be QUEUED here, not answered under
-- the dialog -- and the moment the dialog closes it has to be answered,
-- with the lockstep opening on this screen too.  Then win the duel and
-- ride the funnel back to the lobby.
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
  E.setName("GUESTB")

  local code = L.waitFor(DIR, "code.txt", 3600)
  if not code then return C.fail("no room code ever appeared") end
  code = code:gsub("%s", "")
  local joined = false
  for _ = 1, 10 do
    E.join(code)
    for _ = 1, 120 do
      U.wait(10)
      if E.memberCount() >= 2 then
        joined = true
        break
      end
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
  for _ = 1, 8 do
    U.tap(game, "a")
    U.wait(20)
  end
  U.wait(30)

  -- the champion: this side is here to win the duel
  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")
  if not L.waitFor(DIR, "posted.txt", 3600) then
    return C.fail("the host never posted")
  end
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  -- From the SOUTH, in two legs.  The first run walked in along row 18
  -- from the west and arrived facing east -- straight down the row at
  -- the host, three cells away -- and this side's own eyeline fired the
  -- duel before the menu was ever opened.  Coming up column 11 arrives
  -- facing the sign, whose cell blocks the eyeline on its first step.
  if not L.goTo(C, "PEWTER_CITY", 11, 20, 300) then
    return C.fail(("never reached the approach; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  if not L.goTo(C, "PEWTER_CITY", 11, 18, 60) then
    return C.fail(("never reached the sign; at %s,%s"):format(
      tostring(C.x()), tostring(C.y())))
  end
  U.hold(game, "up", 6)     -- face the sign at (11,17), not the host
  U.wait(30)
  if E.status() ~= "alive" or E.pending() then
    return C.fail("staging: something fired on the walk in (status "
                  .. tostring(E.status()) .. ", pending "
                  .. tostring(E.pending() and E.pending().to) .. ")")
  end

  local function backOnTheMap(ticks)
    for _ = 1, ticks or 200 do
      if game.stack:top() == C.ow() then return true end
      U.tap(game, "b")
      U.wait(12)
    end
    return game.stack:top() == C.ow()
  end
  local function runnerBusy()
    local ow = C.ow()
    return ow and ow.runner and ow.runner.isRunning and ow.runner:isRunning()
  end

  -- (the START-menu leg moved to the "menu" scenario, 2026-09-10: a
  -- menu is no longer held off, it is popped -- POK-199)
  L.put(DIR, "menu.txt", "1")

  -- ------- 2. reading a SCRIPT's text when the challenge lands
  -- Not the sign: a sign is a bare TextBox, which POK-199 pops for a
  -- challenge (and did, 2026-09-10).  The runner's own box is the case
  -- that must still queue -- popping it would strand the script -- so
  -- the text is put up through the runner (debugSay), two pages long.
  E.debugSay("Reading a\nsign here.\fStill reading\nit.")
  local up = false
  for _ = 1, 120 do
    if runnerBusy() then up = true break end
    U.wait(1)
  end
  if not up then return C.fail("the runner never took the say") end
  if E.busy() ~= "menu" then
    return C.fail("a script's text should read as a menu, got " .. tostring(E.busy()))
  end
  L.put(DIR, "reading.txt", "1")
  -- the host answers within a tick or two of seeing the file; each page
  -- lives three seconds (tickAutoResolve's patience), so the challenge
  -- lands while the text is up
  if not L.waitFor(DIR, "challenged.txt", 300) then
    return C.fail("the host never sent the challenge")
  end
  local queued = false
  for _ = 1, 120 do
    if E.queued() > 0 then
      queued = true
      break
    end
    if E.status() == "battle" then break end
    U.wait(1)
  end
  if not queued then
    if not runnerBusy() then
      return C.fail("staging: the script closed before the challenge landed")
    end
    return C.fail("the challenge was not queued behind the dialog (status "
                  .. tostring(E.status()) .. ", queued " .. tostring(E.queued()) .. ")")
  end
  if E.status() == "battle" then
    return C.fail("the battle opened UNDER the dialog -- the very wedge")
  end
  U.log("PVP guest: challenge queued behind the script's text")

  -- close the text ourselves (B advances it like A and chooses nothing),
  -- and the queue has to answer: the flash, the accept, the lockstep
  local closedAt = nil
  for _ = 1, 200 do
    if not (runnerBusy() or C.busy()) then
      closedAt = U.frame()
      break
    end
    U.tap(game, "b")
    U.wait(10)
  end
  if not closedAt then return C.fail("the script's text would not close") end
  local opened = false
  for _ = 1, 600 do
    if E.status() == "battle" then
      opened = true
      break
    end
    U.wait(1)
  end
  if not opened then
    return C.fail("the dialog closed but the queued challenge never opened a battle (queued "
                  .. tostring(E.queued()) .. ", status " .. tostring(E.status()) .. ")")
  end
  U.log(("PVP guest: lockstep battle open %d frames after the dialog closed")
        :format(U.frame() - closedAt))

  if not L.mashUntil(C, function() return E.phase() == "over" end, 4800) then
    return C.fail("the match never ended (the guest should have won)")
  end
  U.log("PVP guest: match over")
  if not L.mashUntil(C, function() return E.phase() == "lobby" end, 1200) then
    return C.fail("the finished match never returned the guest to the lobby")
  end
  U.log("PVP OK guest: mid-dialog challenge queued and answered, won, lobby again")
  love.event.quit(0)
  U.wait(10)
end
