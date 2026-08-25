-- The BATTLE ROYALE screen, reached from the title and the START menu.
--
-- One lobby, not a menu round-trip (POK-32).  The screen is a Menu whose
-- rows are rebuilt from BR every frame, so picking SOLO VS BOTS turns this
-- same screen into the lobby -- the roster filling in, BOTS / FILL TO,
-- OPEN, the countdown -- instead of closing and making you reopen it to
-- see what happened.  You leave it by starting the match or backing out.
-- Once the match is live it only reports; everything that happens then
-- happens in the overworld.

local Entry = require("mods.battle_royale.lib.entry")

local Menu = {}

local function say(mod, text)
  -- the script runner owns the dialogue box, so status lands in a real
  -- Gen 1 text box rather than a bespoke overlay; refused mid-cutscene,
  -- which is correct
  -- true when the runner took it; nil, err when it was busy -- the
  -- caller (BR's tickSays) retries a say nothing may swallow (POK-49)
  return (mod.world:queueScript({ { "show_text", text } }))
end

Menu.say = say

-- Which face the screen is showing: the match report, the lobby, the
-- connecting placeholder, or the first menu.  A change of face is what
-- resets the cursor; anything else keeps it where you left it.
function Menu.view(BR)
  local phase, relay = BR.phase, BR.relay
  if phase == "safari" or phase == "drop" or phase == "match" or phase == "over" then
    return "match"
  end
  if relay and relay:isOpen() then return "lobby" end
  if relay and relay.status == "connecting" then return "connecting" end
  return "menu"
end

-- The rows for the current face.  Pure in the sense that matters: nothing
-- here pushes a screen or touches a socket until a row is chosen, so the
-- list can be rebuilt every frame.
function Menu.items(mod, BR, game)
  local items = {}
  local view = Menu.view(BR)
  local function row(label)
    items[#items + 1] = { label = label, keepOpen = true, onSelect = function() end }
  end
  -- a row that changes a setting stays open; its label is rebuilt next frame
  local function setting(label, onPress)
    items[#items + 1] = { label = label, keepOpen = true, onSelect = onPress }
  end

  if view == "match" then
    -- A finished match is a place you have LEFT (POK-82): the champion is
    -- sent here once the Hall of Fame closes, so the rows have to read as
    -- a result, not as a glance at a match still running.  Alive at "over"
    -- means the last one standing -- one survivor is what ends it.
    if BR.phase == "over" then
      row(BR.status == "out" and "MATCH OVER" or "YOU WIN!")
    else
      row(BR.status == "out" and "SPECTATING" or ("ALIVE: " .. BR:aliveCount()))
    end
    if BR.phase == "safari" and BR.safariLeft then
      local left = BR:safariLeft()
      row(("SAFARI %d:%02d"):format(math.floor(left / 60), left % 60))
    end
    if BR.phase ~= "over" then
      row("LEVEL: " .. tostring(BR:level()))
      -- where the fog is, and whether you are standing in it
      local ring = BR.ring
      if ring and ring.phase and ring.phase > 1 then
        row("FOG: " .. tostring((ring.center and ring.center.name) or "CLOSING"))
      end
    end
    -- the host can run it back (POK-20); everyone else waits to be sent
    if BR.phase == "over" and BR.relay and BR.relay:isHost() then
      items[#items + 1] = { label = "PLAY AGAIN", onSelect = function() BR:playAgain() end }
    end
    items[#items + 1] = {
      label = "LEAVE MATCH",
      onSelect = function() BR:teardown("You left the match.") end,
    }

  elseif view == "lobby" then
    local relay = BR.relay
    local host = relay:isHost()
    -- A solo room has no code worth reading out, no roster to watch fill
    -- and nobody to keep seats for, so it shows the two things that
    -- actually decide the match and nothing else.
    if not BR.solo then
      row("CODE " .. tostring(relay.code))
      for _, m in ipairs(relay.members) do
        row("- " .. m.name .. ((m.id == relay.hostId) and "*" or ""))
      end
      if host then
        -- an open room is one strangers can QUICK PLAY into without ever
        -- being told the code
        setting("OPEN: " .. (BR:isOpen() and "YES" or "NO"),
                function() BR:setOpen(not BR:isOpen()) end)
      end
    end
    if host then
      -- steps the ladder 0,1,2,3,5,8,...,30 and wraps
      setting("BOTS: " .. tostring(BR.botCount),
              function() BR.botCount = BR:nextBotCount() end)
      -- the match's two clocks, right here in the lobby (POK-44)
      setting("FOG: " .. tostring(BR:fogSeconds()) .. "s",
              function() BR:cycleFog() end)
      setting(BR:safariSeconds() > 0
              and ("SAFARI: " .. BR:safariSeconds() .. "s") or "SAFARI: OFF",
              function() BR:cycleSafari() end)
      -- Only meaningful when humans might still arrive: it holds seats
      -- open for them and lets bots take whatever is left.  In a solo
      -- room nobody can arrive, so it would only ever be a second, more
      -- confusing way to say BOTS.
      if not BR.solo then
        setting(BR.fillTo > 0 and ("FILL TO: " .. BR.fillTo) or "FILL TO: OFF",
                function() BR:setFill(BR:nextFill()) end)
        row("TRAINERS: " .. (#relay.members + BR:botsAtStart()))
      end
      local countdown = BR:startsIn()
      items[#items + 1] = {
        label = countdown and ("START MATCH (" .. countdown .. ")") or "START MATCH",
        onSelect = function() BR:startMatch() end,
      }
    else
      row("WAIT FOR HOST")
    end
    items[#items + 1] = { label = "LEAVE", onSelect = function() BR:teardown() end }

  elseif view == "connecting" then
    row("CONNECTING...")
    items[#items + 1] = { label = "CANCEL", onSelect = function() BR:teardown() end }

  else
    -- Every row here keeps the screen open: the room it starts turns this
    -- screen into the lobby on the next frame, and a failure lands in a
    -- text box over it.
    --
    -- first, because it is the one that asks least of a newcomer: no
    -- code from a friend, no server of their own, no decision
    setting("QUICK PLAY", function()
      local ok, err = BR:quickPlay()
      if not ok then say(mod, err or "Couldn't reach\nthe relay.") end
    end)
    setting("SOLO VS BOTS", function()
      local ok, err = BR:hostSolo()
      if not ok then say(mod, err or "Couldn't start.") end
    end)
    setting("HOST GAME", function()
      local ok, err = BR:host()
      if not ok then say(mod, err or "Couldn't host.") end
    end)
    setting("JOIN BY CODE", function()
      game.stack:push(Entry.new(game, {
        title = "ROOM CODE",
        shape = Entry.CODE,
        onDone = function(code)
          if not code or code == "" then return end
          local ok, err = BR:join(code)
          if not ok then say(mod, err or "Couldn't join.") end
        end,
      }))
    end)
    -- the name every other trainer sees (and the winner banner uses);
    -- the Gen 1 naming grid handles it since names are letters
    setting("NAME: " .. BR:playerName(), function()
      game.stack:push(mod.ui.NamingScreen.new(game, {
        title = "YOUR NAME?",
        maxLen = 7,
        default = BR:playerName(),
        onDone = function(name)
          if name and name ~= "" then BR:setName(name) end
        end,
      }))
    end)
    -- the sprite every other trainer sees; wins unlock the wardrobe (POK-79)
    setting("SKIN: " .. BR:skinLabel(), function()
      local Skins = require("mods.battle_royale.lib.skins")
      game.stack:push(Skins.Picker.new(game, {
        wins = BR:winCount(), current = BR:skinId(),
        onPick = function(id) BR:setSkin(id) end,
      }))
    end)
    -- the relay address is a mod option; this row surfaces it and lets
    -- you point at a different server without editing files
    setting("SERVER...", function()
      game.stack:push(Entry.new(game, {
        title = "RELAY HOST:PORT",
        shape = Entry.ADDRESS,
        default = BR:relayAddress(),
        onDone = function(addr)
          if addr and addr ~= "" then BR:setRelayAddress(addr) end
        end,
      }))
    end)
  end

  return items, view
end

-- Size the box to the rows it holds now, the way Menu.new sized it to the
-- rows it was born with (widest label + 3, nudged on-screen, one row step
-- per item plus the border).
local function fit(mod, menu)
  local Font = mod.ui.Font
  local widest = 0
  for _, it in ipairs(menu.items) do
    local n = #Font.split(it.label)
    if n > widest then widest = n end
  end
  menu.tw = math.max(10, widest + 3)
  menu.tx = 10
  if menu.tx + menu.tw > 20 then menu.tx = math.max(0, 20 - menu.tw) end
  menu.th = #menu.items * menu.rowStep + 2
end

function Menu.build(mod, BR)
  return {
    new = function(game)
      local items, view = Menu.items(mod, BR, game)
      local menu = mod.ui.Menu.new(game, items, { startCloses = true })
      local baseUpdate = mod.ui.Menu.update
      menu.view = view
      -- re-read BR before every frame's input: the rows, the box and --
      -- when the face changes -- the cursor
      menu.update = function(self, dt)
        local fresh, now = Menu.items(mod, BR, game)
        self.items = fresh
        if now ~= self.view then
          self.view = now
          self.index = 1
        elseif self.index > #fresh then
          self.index = math.max(1, #fresh)
        end
        fit(mod, self)
        return baseUpdate(self, dt)
      end
      return menu
    end,
  }
end

return Menu
