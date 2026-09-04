-- POK-173: the last turn's text must not flash over this one.
--
-- A bot fight, played by pressing the first move every turn.  Every frame
-- the driver computes what BattleState:drawTextArea would draw -- the
-- `shown` lines, while phase == "messages" and (current or animPlaying or
-- msgHold) -- and records the FIRST text drawn after each move pick.  If
-- that first text is the previous turn's last line ("PONYTA used EMBER"
-- ahead of "CUBONE used TACKLE"), the flash is there.
--
-- Solo room, no relay.  Run from a gen1recomp checkout root:
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-battle-text POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/battle_text_smoke.lua \
--   <path to>/lovec . > battle_text.log 2>&1
--
-- Exit 0 with a `TEXT OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  local function wall() return love.timer.getTime() end

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
  -- a wall with one weak move, so the fight runs several turns
  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, "GEODUDE", 12)
  mon.moves = { { id = "TACKLE", pp = 35 } }
  game.save.party = { mon }

  U.teleport(game, "PEWTER_CITY", 12, 18, "right")
  U.wait(30)
  local ps = E.players() or {}
  local bot = ps[1] and ps[1].id
  if not bot then return C.fail("no bot to fight") end
  E.debugPlaceBot(bot, "PEWTER_CITY", 14, 18)
  U.wait(30)
  U.hold(game, "right", 4)
  local function battleTop()
    local top = game.stack:top()
    return type(top) == "table" and top.enemyParty and top or nil
  end
  local t0 = wall()
  while (wall() - t0) < 40 and not battleTop() do U.wait(1) end
  local b = battleTop()
  if not b then return C.fail("the bot fight never opened") end
  U.log("TEXT: fight open; playing turns and watching the text area")

  local Font = require("src.render.Font")
  local function drawnText()
    if b.phase ~= "messages" or not (b.current or b.animPlaying or b.msgHold) then
      return nil
    end
    local out = {}
    for _, line in ipairs(b.shown or {}) do
      local s = {}
      for i = 1, #line do s[#s + 1] = Font.decode and Font.decode({ line[i] }) or "?" end
      out[#out + 1] = table.concat(s)
    end
    -- the glyph codes are enough of a fingerprint without a decoder
    if not Font.decode then
      out = {}
      for _, line in ipairs(b.shown or {}) do
        local s = {}
        for i = 1, #line do s[#s + 1] = tostring(line[i]) end
        out[#out + 1] = table.concat(s, ".")
      end
    end
    local text = table.concat(out, "|")
    if text == "" then return nil end
    return text
  end

  local lastDrawn = nil          -- the last non-empty text drawn
  local turns, flashes = 0, 0
  local awaitingFirst, prevLast = false, nil
  local frames = 0
  while frames < 60 * 90 do
    frames = frames + 1
    if not battleTop() then break end
    local text = drawnText()
    if text then
      if awaitingFirst then
        awaitingFirst = false
        if prevLast and text == prevLast then
          flashes = flashes + 1
          U.log(("TEXT: turn %d opened on the LAST turn's text: %s"):format(turns, text:sub(1, 60)))
        else
          U.log(("TEXT: turn %d opened on fresh text"):format(turns))
        end
      end
      lastDrawn = text
    end
    if b.phase == "menu" then
      U.tap(game, "a")           -- FIGHT
    elseif b.phase == "moveSelect" then
      turns = turns + 1
      prevLast = lastDrawn
      awaitingFirst = true
      U.tap(game, "a")           -- the first move
    elseif b.msgWaiting or b.msgPrompt then
      U.tap(game, "a")
    end
    if turns >= 4 and b.phase == "menu" then break end
    U.wait(1)
  end
  U.log(("TEXT: %d turns played, %d flash(es) of the last turn's text"):format(turns, flashes))
  if turns < 2 then return C.fail("not enough turns to see a second one open") end
  if flashes > 0 then return C.fail("the last turn's text flashed before this turn's") end
  U.log("TEXT OK: every turn opened on its own text")
  love.event.quit(0)
  U.wait(10)
end
