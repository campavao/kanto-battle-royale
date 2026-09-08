-- POK-193 smoke: a gym leader talks for one page in a match.
--
-- Vanilla BROCK opens with a four-page speech and closes a win with the
-- badge pages and the TM34 hand-over; in a match he says one page, the
-- battle carries no end text, and the only box after the win is the
-- purse line.  The driver counts text pages before the battle screen and
-- text boxes after it, in a match and then outside one:
--
--   1. in a match: <= 1 page before, <= 1 box after, the match's prize TM
--      and purse in the bag, no vanilla TM34 (BIDE);
--   2. after leaving: the full speech (more than one page) is back.
--
-- Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-gym-talk POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/gym_talk_smoke.lua \
--   <path to>/lovec . > gym_talk.log 2>&1
--
-- Exit 0 with a `TALK OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")
local TextBox = require("src.render.TextBox")

return function(game)
  local C = L.ctx(game)

  -- every text box the game pushes, with its page count
  local boxes = {}
  local baseNew = TextBox.new
  TextBox.new = function(g, text, onDone, opts)
    local pages = 1
    for _ in tostring(text or ""):gmatch("\f") do pages = pages + 1 end
    boxes[#boxes + 1] = { text = tostring(text or ""), pages = pages }
    return baseNew(g, text, onDone, opts)
  end
  local function pagesSince(from)
    local n = 0
    for i = from + 1, #boxes do n = n + boxes[i].pages end
    return n
  end

  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("TALKER")
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

  -- a fight BROCK cannot win, so the count is about the talk
  local function fightBrock(label)
    L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")
    U.teleport(game, "PEWTER_GYM", 4, 2, "up")
    U.wait(40)
    for _ = 1, 10 do U.tap(game, "b") U.wait(5) end   -- anything open on arrival
    U.wait(20)
    local mark = #boxes
    U.tap(game, "a")
    local battle
    for _ = 1, 400 do
      local top = game.stack:top()
      if type(top) == "table" and top.trainer and top.enemy then battle = top break end
      U.tap(game, "a")
      U.wait(5)
    end
    if not battle then return nil, label .. ": BROCK never fought (top " .. tostring(game.stack:top()) .. ")" end
    local before = pagesSince(mark)
    local endText = battle.endBattleText
    mark = #boxes
    -- through the fight: FIGHT is the default row and A picks the move
    local back = false
    for _ = 1, 3000 do
      if game.stack:top() == C.ow() then back = true break end
      U.tap(game, "a")
      U.wait(4)
    end
    if not back then return nil, label .. ": the fight never ended" end
    -- and the boxes that follow, until the screen is quiet
    local quiet = 0
    for _ = 1, 400 do
      if game.stack:top() == C.ow() then quiet = quiet + 1 else quiet = 0 end
      if quiet >= 60 then break end
      U.tap(game, "a")
      U.wait(4)
    end
    local after = #boxes - mark
    return { before = before, after = after, endText = endText,
             afterTexts = (function()
               local t = {}
               for i = mark + 1, #boxes do t[#t + 1] = boxes[i].text:gsub("\n", " ") end
               return table.concat(t, " | ")
             end)() }
  end

  -- ----------------------------------------------------------- 1. in a match
  local inv = game.save.inventory
  local money0 = game.save.money or 0
  local r, err = fightBrock("match")
  if not r then return C.fail(err) end
  U.log(("TALK: match -- %d page(s) before, end text %s, %d box(es) after: %s"):format(
    r.before, tostring(r.endText), r.after, r.afterTexts))
  if r.before > 1 then return C.fail("BROCK said " .. r.before .. " pages before the fight") end
  if r.endText then return C.fail("the battle carried an end text: " .. tostring(r.endText)) end
  if r.after > 1 then return C.fail(r.after .. " boxes after the win") end
  if not inv.TM_ROCK_SLIDE then return C.fail("the match's prize TM did not land") end
  if inv.TM_BIDE then return C.fail("the vanilla TM34 was handed over") end
  if (game.save.money or 0) <= money0 then return C.fail("no purse") end
  -- talking again: one line
  local mark = #boxes
  U.teleport(game, "PEWTER_GYM", 4, 2, "up")
  U.wait(40)
  U.tap(game, "a")
  U.wait(30)
  local again = pagesSince(mark)
  U.log(("TALK: beaten BROCK says %d page(s)"):format(again))
  if again > 1 then return C.fail("a beaten BROCK said " .. again .. " pages") end
  for _ = 1, 6 do U.tap(game, "a") U.wait(5) end

  -- ---------------------------------------------------------- 2. outside one
  E.leave()
  U.wait(60)
  for _ = 1, 10 do U.tap(game, "a") U.wait(10) end
  -- the save the title keeps is the match's: BROCK beaten and hidden in
  -- it.  A fresh playthrough's view of him, by hand.
  local sv = game.save
  if sv then
    if sv.flags then sv.flags.EVENT_BEAT_BROCK = nil end
    sv.defeatedTrainers = {}
    sv.objectToggles = {}
  end
  local mark2 = #boxes
  L.armParty(C, "MEWTWO", 100, "PSYCHIC_M")
  U.teleport(game, "PEWTER_GYM", 4, 2, "up")
  U.wait(40)
  for _ = 1, 10 do U.tap(game, "b") U.wait(5) end
  mark2 = #boxes
  U.tap(game, "a")
  local battle
  for _ = 1, 400 do
    local top = game.stack:top()
    if type(top) == "table" and top.trainer and top.enemy then battle = top break end
    U.tap(game, "a")
    U.wait(5)
  end
  if not battle then return C.fail("outside the match BROCK never fought") end
  local vanilla = pagesSince(mark2)
  U.log(("TALK: outside a match BROCK says %d page(s) before the fight"):format(vanilla))
  if vanilla < 2 then return C.fail("the vanilla speech was cut outside a match") end
  U.log("TALK OK: one page before, no end text, the purse after; the full speech outside")
  love.event.quit(0)
  U.wait(30)
end
