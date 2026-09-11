-- The ticker (2026-09-10): news that does not stop the game, and the
-- three presses it replaced.  Staged in the sandbox arena (mods/br_sandbox),
-- which has a flat floor, a nurse with no counter, and no fog.
--
--   1. A bag on the ground: face it and the ticker holds "DEBUG's BAG";
--      A takes the lot -- POTION and money -- and the ticker says what
--      came, one line a beat.  No list, no box.
--   2. A ball: face it and the ticker holds the POKeMON's name with its
--      party icon; A takes it, no "Do you want it?", and the ticker says
--      it joined.  (BR_SHOTS=<dir> screenshots the held line.)
--   3. The nurse: A asks HEAL/CANCEL and nothing else; HEAL runs the
--      machine (the screen is busy for exactly that long -- busy() says
--      "menu" -- and quiet again after), the party is whole, no box
--      follows, the ticker says fighting fit.
--   4. POK-199: sitting in the START menu is not immunity.  A bot planted
--      in sight of us while the menu is up pops the menu and gets its
--      fight -- which opens and closes in the bot's own words
--      (Bots.lines): its dealt intro, and its lose line after "defeated".
--   5. The fog, last: a forced shrink is announced on the ticker, and the
--      rung it moves names the POKeMON it evolved -- CATERPIE at Lv5
--      cannot stay one at Lv15 -- with no box at any point.  Last because
--      the ring's phase is wall time over the fog length: once shortened
--      it runs to the end, and there is no pausing it.
--
--   tools/drive.sh ticker_smoke
--
-- Exit 0 with a `TICKER OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local SHOTS = os.getenv("BR_SHOTS")
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("TICKER")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(4)
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
  local matchAt = love.timer.getTime()   -- the ring's clock is wall time from here
  local Pokemon = require("src.pokemon.Pokemon")
  -- a lead that wins the bot fight below, and a CATERPIE the rung will
  -- not leave alone once the fog moves (leg 4, last: the ring derives
  -- its phase from wall time over the fog length, so a one-second fog
  -- runs it to the end and cannot be "paused" -- everything else goes
  -- before it)
  local lead = Pokemon.new(game.data, "MEWTWO", 100)
  lead.moves = { { id = "PSYCHIC_M", pp = 99 } }   -- one move, never out of PP under a mash
  game.save.party = { lead, Pokemon.new(game.data, "CATERPIE", 5) }
  -- one bot per town, none in reach of another: two in one town duel,
  -- and a match of two bots plus us is OVER the moment we beat one --
  -- which is what the fog leg (last) found.  The bot for leg 4 is placed
  -- by hand later; the rest sit out the whole run
  local TOWNS = { "PALLET_TOWN", "VIRIDIAN_CITY", "PEWTER_CITY", "CERULEAN_CITY",
                  "VERMILION_CITY", "LAVENDER_TOWN" }
  for i, b in ipairs(E.bots() or {}) do
    local town = TOWNS[((i - 1) % #TOWNS) + 1]
    local def = game.data.maps[town]
    E.debugPlaceBot(b.id, town, def and math.floor(def.width) or 5, def and math.floor(def.height) or 5)
  end

  -- into the arena
  U.teleport(game, "BR_ARENA", 12, 12, "up")
  U.wait(30)
  if C.map() ~= "BR_ARENA" then return C.fail("not in the arena; at " .. tostring(C.map())) end
  local ARENA = "BR_ARENA"

  local function news() return E.news() or {} end
  local function said(text)
    for _, line in ipairs(news().log or {}) do if line == text then return true end end
    return false
  end
  -- wait for a line, and while waiting insist nothing but the overworld
  -- is on top: the whole point is that no box opens
  local function waitSaid(text, ticks, allowBusy)
    for _ = 1, (ticks or 120) do
      if said(text) then return true end
      if not allowBusy and game.stack:top() ~= C.ow() then
        return false, "a screen opened: " .. tostring(game.stack:top() and (game.stack:top().kind or game.stack:top().title or getmetatable(game.stack:top())))
      end
      U.wait(5)
    end
    return false, "never said"
  end
  local function face(dir)
    local ow = C.ow()
    for _ = 1, 10 do
      if ow.player.facing == dir then return true end
      U.hold(game, dir, 1) U.wait(6)
    end
    return ow.player.facing == dir
  end

  -- ------- 1 + 2: the spill
  local spill, why = E.debugSpill(0, -3, true)
  if not spill then return C.fail("debugSpill refused: " .. tostring(why)) end
  U.wait(30)
  local bag, ball
  for _, p in ipairs(E.spills() or {}) do
    if tostring(p.key):sub(1, 4) == "999:" then
      if p.bag then bag = p else ball = p end
    end
  end
  if not (bag and ball) then return C.fail("the spill is not a bag plus a ball") end
  U.log(("TICKER: bag at %d,%d, ball at %d,%d; we stand at %d,%d")
    :format(bag.x, bag.y, ball.x, ball.y, C.x(), C.y()))

  -- stand on the bag, face away from the ball: the bag is what we look at
  if not L.goTo(C, ARENA, bag.x, bag.y, 200) then
    return C.fail(("could not step onto the bag; at %d,%d"):format(C.x(), C.y()))
  end
  local away = "down"
  if ball.y > bag.y then away = "up" elseif ball.y == bag.y then away = ball.x > bag.x and "left" or "right" end
  if not face(away) then return C.fail("could not face " .. away) end
  U.wait(10)
  if news().held ~= "DEBUG's BAG" then
    return C.fail("on the bag the ticker holds " .. tostring(news().held) .. ", not DEBUG's BAG")
  end
  U.log("TICKER: the bag is named before the press")
  local money0, potions0 = game.save.money or 0, game.save.inventory.POTION or 0
  U.tap(game, "a") U.wait(15)
  if game.stack:top() ~= C.ow() then
    return C.fail("A on the bag opened something: " .. tostring(game.stack:top()))
  end
  if SHOTS then
    -- a news line on row 0, the count stepped aside under it
    for _ = 1, 60 do
      if (news().text or ""):sub(1, 4) == "Took" then break end
      U.wait(2)
    end
    U.shot(game, SHOTS .. "/ticker_news.png")
  end
  if (game.save.money or 0) ~= money0 + 500 then return C.fail("A did not take the money") end
  if (game.save.inventory.POTION or 0) ~= potions0 + 1 then return C.fail("A did not take the POTION") end
  local okS, whyS = waitSaid("Took POTION x1!", 60)
  if not okS then return C.fail("the POTION line: " .. tostring(whyS)) end
  okS, whyS = waitSaid("Took ¥500!", 60)
  if not okS then return C.fail("the money line: " .. tostring(whyS)) end
  local bagLeft = false
  for _, p in ipairs(E.spills() or {}) do if p.bag and tostring(p.key):sub(1, 4) == "999:" then bagLeft = true end end
  if bagLeft then return C.fail("the bag is still on the ground") end
  U.log("TICKER: A took the bag whole, and the ticker said what came")

  -- the ball: named with its icon, taken on one press
  if not L.goTo(C, ARENA, ball.x, ball.y, 200) then
    return C.fail(("could not step onto the ball; at %d,%d"):format(C.x(), C.y()))
  end
  U.wait(10)
  local held = news()
  if held.held ~= "RATTATA" or held.heldIcon ~= "RATTATA" then
    return C.fail(("on the ball the ticker holds %s (icon %s), not RATTATA")
      :format(tostring(held.held), tostring(held.heldIcon)))
  end
  -- the shot wants the held line ON SHOW: let the bag's news lines pass
  for _ = 1, 60 do
    if news().text == "RATTATA" then break end
    U.wait(5)
  end
  if SHOTS then U.shot(game, SHOTS .. "/ticker_ball.png") end
  U.tap(game, "a") U.wait(15)
  if #game.save.party ~= 3 then return C.fail("A did not take the ball") end
  if game.stack:top() ~= C.ow() then
    return C.fail("A on the ball opened something: " .. tostring(game.stack:top()))
  end
  okS, whyS = waitSaid("RATTATA joined\nyour party!", 60)
  if not okS then return C.fail("the joined line: " .. tostring(whyS)) end
  U.wait(20)
  if news().held ~= nil then return C.fail("the ball is gone but the ticker still holds " .. tostring(news().held)) end
  U.log("TICKER: A took the ball with no question, and the line cleared with it")

  -- ------- 3: the nurse at (8,6); we stand below her
  for _, mon in ipairs(game.save.party) do mon.hp = 1 end
  if not L.goTo(C, ARENA, 8, 7, 300) then
    return C.fail(("could not reach the counter; at %d,%d"):format(C.x(), C.y()))
  end
  if not face("up") then return C.fail("could not face the nurse") end
  U.wait(10)
  U.tap(game, "a") U.wait(15)
  local top = game.stack:top()
  local TextBox = require("src.render.TextBox")
  if getmetatable(top) ~= TextBox or not top.choice then
    return C.fail("A on the nurse did not open the HEAL/CANCEL box (top " .. tostring(top) .. ")")
  end
  -- the ask is a menu: a challenge could pop it (POK-199)
  if not E.yankScreen() then return C.fail("the HEAL/CANCEL box refused to be popped") end
  if game.stack:top() ~= C.ow() then return C.fail("the box did not come down") end
  U.log("TICKER: the nurse's question is a menu, and it pops for a fight")
  U.tap(game, "a") U.wait(15)
  top = game.stack:top()
  if getmetatable(top) ~= TextBox then return C.fail("the second ask did not open") end
  -- HEAL: the box prints before it asks, so press until the machine runs
  local ow = C.ow()
  for _ = 1, 12 do
    if ow.healAnim then break end
    U.tap(game, "a") U.wait(8)
  end
  local busyWhile = 0
  for _ = 1, 200 do
    if not ow.healAnim then break end
    if E.busy() == "menu" then busyWhile = busyWhile + 1 end
    U.wait(2)
  end
  if busyWhile == 0 then return C.fail("the machine never ran, or never read as busy") end
  if ow.healAnim then return C.fail("the machine never finished") end
  if game.stack:top() ~= C.ow() then
    return C.fail("a box followed the machine: " .. tostring(game.stack:top()))
  end
  for _, mon in ipairs(game.save.party) do
    if mon.hp ~= mon.stats.hp then return C.fail("the party is not whole after the heal") end
  end
  if E.busy() ~= nil then return C.fail("still busy after the machine: " .. tostring(E.busy())) end
  okS, whyS = waitSaid("Your POKeMON are\nfighting fit!", 60)
  if not okS then return C.fail("the fighting fit line: " .. tostring(whyS)) end
  U.log("TICKER: HEAL ran the machine, busy for " .. busyWhile .. " beats, and no box followed")

  -- ------- 4: POK-199, from the START menu (and the bot's own lines)
  if not L.goTo(C, ARENA, 12, 12, 300) then return C.fail("could not get back to the post") end
  if not face("right") then return C.fail("could not face right") end
  U.tap(game, "start") U.wait(15)
  if game.stack:top() == C.ow() then return C.fail("START did not open the menu") end
  local roster = E.bots() or {}
  if #roster == 0 then return C.fail("no bots") end
  local victim = roster[1]
  local engaged = false
  for _ = 1, 40 do
    E.debugPlaceBot(victim.id, ARENA, 12, 9)
    for _ = 1, 15 do
      if E.status() == "battle" or E.walkUp() then engaged = true break end
      U.wait(4)
    end
    if engaged then break end
  end
  if not engaged then return C.fail("the bot never spotted us from the menu") end
  if game.stack:top() ~= C.ow() and E.status() ~= "battle" then
    return C.fail("the bot spotted us but the menu is still up: " .. tostring(game.stack:top()))
  end
  U.log("TICKER: the START menu came down for the bot's sight")
  local fought = false
  for _ = 1, 300 do
    if E.status() == "battle" then fought = true break end
    U.wait(5)
  end
  if not fought then return C.fail("the fight never opened after the yank") end
  U.log("TICKER: the fight opened (POK-199)")
  -- ...in the bot's own words (Bots.lines): the intro is its dealt line
  local Bots = require("mods.battle_royale.lib.bots")
  local want = Bots.lines(E.matchSeed(), victim.id)
  local bt = {}
  for _ = 1, 300 do
    bt = E.battleText() or {}
    if bt.intro then break end
    U.wait(2)
  end
  if bt.intro ~= want.intro then
    return C.fail(("the bot's intro should be %q, got %s"):format(want.intro, tostring(bt.intro)))
  end
  U.log(("TICKER: the bot opened with its own line, %q"):format((want.intro:gsub("\n", " "))))
  -- ...and closes on one: mash A through the fight, then read what the
  -- ending said -- its lose line after "defeated", or its win line
  -- around the blackout, whichever way it went
  local ended = false
  for tick = 1, 1200 do
    if E.status() ~= "battle" then ended = true break end
    if tick % 100 == 0 then
      local top = game.stack:top()
      U.log(("fight: tick %d top=%s phase=%s waiting=%s prompt=%s result=%s queue=%d")
        :format(tick, tostring(top and (top.kind or getmetatable(top))), tostring(top and top.phase),
                tostring(top and top.msgWaiting), tostring(top and top.msgPrompt),
                tostring(top and top.result), top and top.queue and #top.queue or -1))
    end
    U.tap(game, "a") U.wait(15)
  end
  if not ended then return C.fail("the bot fight never ended") end
  local outro = (E.battleText() or {}).outro
  if not outro then return C.fail("the ending said no bot line") end
  local won = E.status() == "alive"
  local line = won and want.lose or want.win
  if not outro:find(line, 1, true) then
    return C.fail(("the ending (%s) should carry %q, read %q"):format(
      won and "our win" or "our loss", line, (outro:gsub("\n", " "):gsub("\f", " / "))))
  end
  U.log(("TICKER: the fight ended (%s) on the bot's own line, %q"):format(
    won and "won" or "lost", (line:gsub("\n", " "))))
  -- back on the map before the fog leg: the battle-return transition and
  -- the victory text are still on top the frame the status flips
  for _ = 1, 600 do
    if game.stack:top() == C.ow() then break end
    U.tap(game, "b") U.wait(10)
  end
  if game.stack:top() ~= C.ow() then
    return C.fail("still off the map after the fight: " .. tostring(game.stack:top()))
  end

  -- ------- 5: the fog, last: it runs to the end from here
  local phase0 = (E.ring() or {}).phase or 1
  -- The ring's phase is elapsed wall time over the fog length, so a
  -- one-second fog from here would be phase twenty -- the all-fog page,
  -- and every bot dead a beat later, which ends the match under the rung
  -- check.  A length of two thirds of the elapsed time lands phase 2 now
  -- and phase 3 a few seconds on: "The fog spreads!", and rung 15.
  local fogLen = math.max(2, math.floor((love.timer.getTime() - matchAt) / 1.5))
  if not E.debugRoundFog(fogLen) then return C.fail("debugRoundFog refused") end
  local moved = false
  for _ = 1, 200 do
    if ((E.ring() or {}).phase or 1) > phase0 then moved = true break end
    U.wait(5)
  end
  if not moved then return C.fail("the ring never moved") end
  okS, whyS = waitSaid("The fog spreads!\nAll grew stronger!", 120)
  if not okS then return C.fail("the fog line: " .. tostring(whyS)) end
  local evoLine
  for _ = 1, 200 do
    for _, line in ipairs(news().log or {}) do
      if line:sub(1, 16) == "CATERPIE evolved" then evoLine = line end
    end
    if evoLine then break end
    if game.stack:top() ~= C.ow() then return C.fail("a box opened on the rung: " .. tostring(game.stack:top())) end
    U.wait(5)
  end
  if not evoLine then return C.fail("the rung moved but the ticker never named the evolution") end
  if game.save.party[2].species == "CATERPIE" then return C.fail("CATERPIE did not evolve at the rung") end
  U.log(("TICKER: the shrink and the rung were news, not boxes: %q, %s")
    :format((evoLine:gsub("\n", " ")), game.save.party[2].species))

  U.log("TICKER OK")
  love.event.quit(0)
  U.wait(30)
end
