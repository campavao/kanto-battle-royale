-- POK-179: a ball that changed hands is a trade.
--
-- Two KADABRA balls in a solo match.  The first is somebody else's
-- (debugSpill's owner 999): A on it, YES, and after "joined your party"
-- the engine's own evolution movie plays and an ALAKAZAM is in the
-- party.  The second is OUR OWN drop (owner "me"): picked back up, it
-- stays a KADABRA.
--
--   POKEPORT_GAME=red POKEPORT_IMPORT_ROM=<rom.gb> \
--   POKEPORT_IDENTITY=br-trade POKEPORT_SPEED=3 \
--   POKEPORT_DRIVER=mods/battle_royale/tests/drivers/trade_evo_smoke.lua \
--   <path to>/lovec . > trade_evo.log 2>&1
--
-- Exit 0 with a `TRADE OK` line passes; any `PVP FAIL` line fails.

local U = require("tests.drivers.util")
local L = require("mods.battle_royale.tests.drivers.pvp.pvplib")

return function(game)
  local C = L.ctx(game)
  U.newGame(game)
  local E = C.E()
  if not E then return C.fail("no battle_royale exports") end
  E.setName("TRADER")
  E.setSafari(0)
  E.setFog(600)
  if not E.hostSolo() then return C.fail("hostSolo refused") end
  E.setBots(2)
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
  game.save.party = { Pokemon.new(game.data, "MACHOP", 15) }
  for _, b in ipairs(E.bots() or {}) do E.debugPlaceBot(b.id, "CINNABAR_ISLAND", 10, 10) end
  if not L.flyTo(C, "PEWTER_CITY") then
    return C.fail("FLY did not land in Pewter; at " .. tostring(C.map()))
  end
  if not L.goTo(C, "PEWTER_CITY", 16, 18, 300) then
    return C.fail(("never reached the post; at %s,%s"):format(tostring(C.x()), tostring(C.y())))
  end
  U.wait(30)

  local function ballOf(prefix)
    for _, p in ipairs(E.spills() or {}) do
      if not p.bag and tostring(p.key):sub(1, #prefix) == prefix then return p end
    end
    return nil
  end
  -- Back to the overworld, pressing A only through boxes that want a
  -- press: the evolution intro is a `stay` box that pops itself, and the
  -- movie (EvolutionState, ~370 frames) polls no A at all -- a press
  -- there is harmless but a press on the intro can cut it short.
  local TextBox = require("src.render.TextBox")
  local EvolutionState = require("src.ui.EvolutionState")
  local function settle()
    local t0 = love.timer.getTime()
    local taps, lastSig = 0, nil
    while love.timer.getTime() - t0 < 60 do
      local top = game.stack:top()
      if top == C.ow() then return true end
      -- a trace of what the presses walked through
      local sig = {}
      for _, st in ipairs(game.stack.states) do
        sig[#sig + 1] = (st == C.ow()) and "ow" or (st.kind or st.title
          or (type(st.text) == "string" and st.text:sub(1, 16):gsub("\n", " ")) or "?")
      end
      sig = table.concat(sig, ">")
      if sig ~= lastSig and taps < 60 then
        U.log("settle: " .. sig)
        lastSig = sig
        taps = taps + 1
      end
      -- A through everything but the intro box and the movie itself:
      -- the result text, and the move-learn boxes the evolved species
      -- can open behind it
      local intro = getmetatable(top) == TextBox and top.stay
      if not intro and getmetatable(top) ~= EvolutionState then
        U.tap(game, "a")
      end
      U.wait(10)
    end
    -- what is it?  name every state on the stack by its class
    local classes = {
      TextBox = TextBox, EvolutionState = EvolutionState,
      ChoiceBox = require("src.ui.ChoiceBox"), Menu = require("src.ui.Menu"),
      ListMenu = require("src.ui.ListMenu"), PartyMenu = require("src.ui.PartyMenu"),
    }
    local names = {}
    for i, st in ipairs(game.stack.states) do
      local name = st == C.ow() and "overworld" or "?"
      for cname, cls in pairs(classes) do
        if getmetatable(st) == cls then name = cname end
      end
      local keys = {}
      if name == "?" then
        for k in pairs(st) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
      end
      local tag = st.kind or st.title or (type(st.text) == "string" and st.text:sub(1, 24):gsub("\n", " ")) or ""
      names[#names + 1] = ("%d:%s[%s]%s"):format(i, name, tostring(tag),
        #keys > 0 and ("{" .. table.concat(keys, ",") .. "}") or "")
    end
    U.log(("settle: stuck; stack = %s; party tail %s"):format(table.concat(names, " "),
      tostring(game.save.party[#game.save.party] and game.save.party[#game.save.party].species)))
    return false
  end
  local function pickUp(owner, prefix, label)
    local spill, why = E.debugSpill(0, 2, "KADABRA", owner)
    if not spill then return C.fail("debugSpill refused: " .. tostring(why)) end
    U.wait(30)
    local ball = ballOf(prefix)
    if not ball then return C.fail("no " .. label .. " ball on the ground") end
    if not L.goTo(C, "PEWTER_CITY", ball.x, ball.y, 200) then
      return C.fail(("could not reach the %s ball at %d,%d"):format(label, ball.x, ball.y))
    end
    -- face a cell that holds nothing: facing wins, and the bag that came
    -- with the spill sits one cell from the ball -- face it and A opens
    -- the bag list instead of the ball under our feet
    local bagAt
    for _, p in ipairs(E.spills() or {}) do if p.bag then bagAt = p end end
    local away = "down"
    for _, d in ipairs({ { "up", 0, -1 }, { "left", -1, 0 }, { "right", 1, 0 }, { "down", 0, 1 } }) do
      local tx, ty = ball.x + d[2], ball.y + d[3]
      if not (bagAt and bagAt.x == tx and bagAt.y == ty) then away = d[1] break end
    end
    for _ = 1, 10 do
      if C.ow().player.facing == away then break end
      U.hold(game, away, 1) U.wait(6)
    end
    if C.x() ~= ball.x or C.y() ~= ball.y then
      return C.fail(("turning walked us off the ball to %d,%d"):format(C.x(), C.y()))
    end
    local before = #game.save.party
    U.tap(game, "a") U.wait(12)      -- "Do you want it?"
    U.tap(game, "a") U.wait(12)      -- YES
    for _ = 1, 10 do
      if #game.save.party > before then break end
      U.tap(game, "a") U.wait(10)
    end
    if #game.save.party ~= before + 1 then
      return C.fail("the " .. label .. " ball did not join the party")
    end
    -- the joined line, then -- for a trade -- the movie: A through it all
    -- (a trade evolution does not honour B, so A is what a player does)
    if not settle() then
      return C.fail("the screen never settled after the " .. label .. " pickup (top "
        .. tostring(game.stack:top()) .. ")")
    end
    -- the bag that came with the debug spill: take it off the ground so
    -- the next spill's ball has a clean cell
    for _, p in ipairs(E.spills() or {}) do
      if p.bag then E.openSpill(p.key) U.wait(10)
        U.tap(game, "a") U.wait(10) U.tap(game, "down") U.wait(6) U.tap(game, "a") U.wait(12)
        U.tap(game, "a") U.wait(10) U.tap(game, "a") U.wait(12)
        settle()
      end
    end
    return game.save.party[#game.save.party].species
  end

  local got = pickUp(nil, "999:", "stranger's")
  if not got then return end
  if got ~= "ALAKAZAM" then
    return C.fail("a stranger's KADABRA came up as " .. tostring(got) .. ", not ALAKAZAM")
  end
  U.log("TRADE: a stranger's KADABRA evolved into ALAKAZAM on pickup")

  local mine = pickUp("me", tostring(E.myId and E.myId() or 1) .. ":", "own")
  if not mine then return end
  if mine ~= "KADABRA" then
    return C.fail("our own dropped KADABRA came up as " .. tostring(mine))
  end
  U.log("TRADE: our own KADABRA stayed a KADABRA")
  U.log("TRADE OK: a change of hands evolves, a pickup of your own does not")
  love.event.quit(0)
  U.wait(30)
end
