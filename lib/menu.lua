-- The BATTLE ROYALE screen, reached from the title and the START menu.
--
-- One lobby, not a menu round-trip (POK-32).  The screen is a Menu whose
-- rows are rebuilt from BR every frame, so picking SOLO VS BOTS turns this
-- same screen into the lobby instead of closing and making you reopen it
-- to see what happened.  You leave it by starting the match or backing
-- out.  Once the match is live it only reports; everything that happens
-- then happens in the overworld.
--
-- The lobby face itself is a drawn room since 2026-09-05 (lib/lobby.lua):
-- every trainer as their sprite and name, empty seats as outlines, and
-- one button.  The rows this file builds for the "lobby" view are the
-- host's OPTIONS box over that room -- FILL, MAX, OPEN, the clocks,
-- DEBUG, START MATCH, LEAVE, in the order of the user's sketch.

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
  -- Ahead of every room face and behind the match one: a refusal happens
  -- in a lobby and leaves the room, so by the time it is read there is no
  -- relay left to be open -- but a match already running outranks it.
  if BR.refused then return "refused" end
  -- quick_join found a match already running (POK-133): the offer face.
  -- Cleared the moment it is taken or the connection goes, so this never
  -- shadows a lobby.
  if BR.runningMatch then return "running" end
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
    -- information, not a control: `dead` keeps the cursor off it (the
    -- build wrapper slides past), so browsing a face only ever stops on
    -- rows that do something
    items[#items + 1] = { label = label, dead = true, keepOpen = true,
                          onSelect = function() end }
  end
  -- a row that changes a setting stays open; its label is rebuilt next frame
  local function setting(label, onPress)
    items[#items + 1] = { label = label, keepOpen = true, onSelect = onPress }
  end

  -- The match you just left, on the screen you land on (POK-144).  Every
  -- terminal state now ends HERE -- a win, a loss, a room that closed under
  -- you -- so the screen has to say which, and it cannot be a text box:
  -- this screen opens from the TITLE, with no overworld to queue a say
  -- onto, which is the same reason the refusal rows below are rows.
  --
  -- A name is at most 7 characters, so "XXXXXXX WON" is 11 -- inside the
  -- 17-character budget the comment further down documents.
  --
  -- NOT on the first face, which has no rows to spare: it is exactly
  -- Menu.maxRows(2) long already and the result rides on its version row
  -- instead (see the bottom of this function).
  -- ...and not on the lobby face either, any more: the room draws the
  -- result on its status line (lib/lobby.lua), and these rows are the
  -- OPTIONS box over it.
  if view ~= "match" and view ~= "menu" and view ~= "lobby" and BR.lastResult then
    row(BR.lastResult.won and "YOU WIN!" or "MATCH OVER")
    if BR.lastResult.name then row(tostring(BR.lastResult.name) .. " WON") end
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
        -- The grid is twenty tiles and the box is the widest row plus
        -- three (fit(), below), so a label may be seventeen at most:
        -- "FOG: VERMILION CITY" is nineteen and ran off the right edge
        -- (POK-171).  The long names go under their label instead.
        local where = tostring((ring.center and ring.center.name) or "CLOSING")
        if #("FOG: " .. where) > Menu.MAX_LABEL then
          row("FOG:")
          row(where)
        else
          row("FOG: " .. where)
        end
      end
    end
    -- No PLAY AGAIN row here any more (POK-144): every client leaves the
    -- finished world on its own, and the host's "run it back" is the
    -- lobby's own start row by the time anyone can press it.  This face is
    -- still reachable, briefly, between onWinner and endMatch -- the START
    -- menu is open at "over" (POK-84) -- so it keeps its own MATCH OVER /
    -- YOU WIN! line above and the way out below, and nothing else.
    items[#items + 1] = {
      label = "LEAVE MATCH",
      onSelect = function() BR:teardown("You left the match.") end,
    }

  elseif view == "lobby" then
    -- The host's OPTIONS box (the room itself is lib/lobby.lua).  A guest
    -- never opens this: their button IS the way out, so their rows are
    -- only what they would be told and LEAVE.
    local relay = BR.relay
    local host = relay:isHost()
    if BR.dailyLobby then
      -- nothing settable, no START: the clock starts THE DAILY GAME, for
      -- host and guest alike (POK-161)
    elseif host then
      -- MAX is the room's size: how many trainers the relay lets in
      -- (it caps joins at this), and, with FILL: ON, how far bots top the
      -- roster up at the start.  A solo room has nobody to fill around or
      -- keep out, so its MAX is the bot count outright.  (BOTS and
      -- TRAINERS were rows of their own until 2026-09-05; the room shows
      -- the seats now, so the number is the picture.)
      if not BR.solo then
        setting("FILL: " .. (BR:fillOn() and "ON" or "OFF"),
                function() BR:setFillOn(not BR:fillOn()) end)
      end
      if BR.solo then
        -- steps the ladder 0,1,2,3,5,8,...,30 and wraps
        setting("MAX: " .. tostring(BR.botCount),
                function() BR.botCount = BR:nextBotCount() end)
      else
        setting("MAX: " .. tostring(BR:fillMax()),
                function() BR:cycleFillMax() end)
      end
      if not BR.solo then
        -- an open room is one strangers can QUICK PLAY into without ever
        -- being told the code
        setting("OPEN: " .. (BR:isOpen() and "YES" or "NO"),
                function() BR:setOpen(not BR:isOpen()) end)
      end
      -- the match's two clocks, right here in the lobby (POK-44)
      setting("FOG: " .. tostring(BR:fogSeconds()) .. "s",
              function() BR:cycleFog() end)
      setting(BR:safariSeconds() > 0
              and ("SAFARI: " .. BR:safariSeconds() .. "s") or "SAFARI: OFF",
              function() BR:cycleSafari() end)
      -- the log's deep tier, where the other knobs already are (POK-86).
      -- It was an environment variable for one release, which a mod cannot
      -- read: the sandbox hides the environment.  The log it thickens is
      -- this client's own, so it sits with the host's other switches.
      -- (SEND STATS left this box for the launcher's mod options on
      -- 2026-09-05: it is a once-per-install choice, not a per-match one.)
      setting("DEBUG: " .. (BR:isDebug() and "ON" or "OFF"),
              function() BR:setDebug(not BR:isDebug()) end)
      local countdown = BR:startsIn()
      -- PLAY AGAIN and START MATCH are the same button (POK-144): once
      -- every client returns to the lobby on its own, the host's "run it
      -- back" IS the lobby's start row.  Only the label changes, so nobody
      -- has to learn that the room they are looking at is the one they
      -- just played in.
      local start = BR.lastResult and "PLAY AGAIN" or "START MATCH"
      if BR.quick and BR.lastResult and not countdown then
        -- READY UP (POK-167): a quick room's second match is ARMED, not
        -- started.  The first lobby counted itself down because Quick
        -- Play promised a game now; the match after it is the one nobody
        -- asked for, so the host says so, and the sixty seconds that
        -- follow are every guest's window to read the result, check the
        -- party, or leave.  Once armed this row is PLAY AGAIN (N) again,
        -- and pressing it starts now.
        items[#items + 1] = {
          label = "READY UP",
          onSelect = function() BR:readyUp() end,
        }
      else
        items[#items + 1] = {
          label = countdown and (start .. " (" .. countdown .. ")") or start,
          onSelect = function() BR:startMatch() end,
        }
      end
    elseif BR.isSpectating and BR:isSpectating() then
      -- the POK-133 seat: the match is running without us, and the relay
      -- makes us a player the moment it ends and the room unlocks
      row("MATCH RUNNING")
      row("YOU PLAY NEXT")
    else
      row("WAIT FOR HOST")
    end
    items[#items + 1] = { label = "LEAVE", onSelect = function() BR:teardown() end }

  elseif view == "running" then
    -- Quick Play found humans -- mid-match (POK-133).  The choice is the
    -- player's: wait for that room's next match (3-6 minutes on measured
    -- match lengths), or a bot game right now.  Never a toll gate.
    row("MATCH IN PROGRESS")
    local n = BR.runningMatch and BR.runningMatch.members
    if n then row(n .. (n == 1 and " TRAINER IN IT" or " TRAINERS IN IT")) end
    setting("JOIN NEXT MATCH", function()
      if not BR:watchNext() then
        say(mod, "Couldn't reach\nthat game.")
      end
    end)
    setting("SOLO VS BOTS", function()
      BR.runningMatch = nil
      local ok, err = BR:hostSolo()
      if not ok then say(mod, err or "Couldn't start\na solo game.") end
    end)
    items[#items + 1] = { label = "LEAVE", onSelect = function() BR:teardown() end }

  elseif view == "refused" then
    -- The room this client was turned away from, and both builds in full
    -- (POK-142).  Rows rather than a text box on purpose: this screen
    -- opens from the TITLE as well as the start menu, so there is not
    -- always an overworld to queue a say onto -- and teardown's own
    -- message is documented as lost on the way to the title (POK-115).
    for _, label in ipairs((BR.refused and BR.refused.rows) or {}) do
      row(label)
    end
    items[#items + 1] = {
      label = "OK", keepOpen = true,
      onSelect = function() BR:clearRefusal() end,
    }

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
    -- The result of the match that sent a player here (POK-144) -- which
    -- is where a relay that closed mid-match lands them -- gets its own
    -- row now: the face is seven rows against maxRows(2) == 8, so the
    -- eighth is free exactly when there is a result to say.
    if BR.lastResult then
      row(BR.lastResult.won and "YOU WIN!" or "MATCH OVER")
    end
    setting("QUICK PLAY", function()
      local ok, err = BR:quickPlay()
      if not ok then say(mod, err or "Couldn't reach\nthe relay.") end
    end)
    -- the official match (POK-161): one shared room for everybody who
    -- presses this, starting at the server's stated hour
    setting("DAILY GAME", function()
      local ok, err = BR:dailyPlay()
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
    -- No SERVER... row and no version row any more (POK-161): the first
    -- face was eight rows against maxRows(2) == 8, DAILY GAME earns a
    -- seat more than either, and the user's call was that the menu had
    -- bloated.  The relay address is still a mod option (edit it in the
    -- launcher's mod options); the version still shows in the launcher's
    -- MODS tab, and the lobby door still names both builds when a
    -- mismatch actually matters (POK-142).
  end

  return items, view
end

-- How many rows the canvas can hold, in Menu's own terms.  Memoised because
-- fit() runs every frame; pcall'd because lib/menu.lua is loaded by the
-- headless test loader, which has no render stack -- and 18 tiles is the
-- Gen 1 canvas either way.
local screenRows
local function canvasRows()
  if not screenRows then
    local ok, Renderer = pcall(require, "src.render.Renderer")
    local h = (ok and Renderer and tonumber(Renderer.HEIGHT)) or 144
    screenRows = math.floor(h / 8)
  end
  return screenRows
end

-- Size the box to the rows it holds now, the way Menu.new sized it to the
-- rows it was born with (widest label + 3, nudged on-screen, one row step
-- per item plus the border) -- but NEVER TALLER THAN THE SCREEN (POK-104).
--
-- The height used to be `#items * rowStep + 2` flat, which is right for a
-- list of fixed length and wrong for this one.  The lobby grows a row per
-- trainer in the room, so a host with a full house had START MATCH and
-- LEAVE pushed off the bottom of the canvas with no way to reach either --
-- the match could not be started from the screen that starts matches.
--
-- Menu has known how to scroll all along (maxVisible + clampScroll + the
-- moreArrow glyph it draws while there is more below); nobody had told it
-- the cap.  This is the same sum src/ui/StartMenu.lua does, for the same
-- reason: its row count is not fixed either.
-- How many rows fit on screen at a given row step (2 is Menu's default and
-- the original's double-spaced style).  Public so the suite can check the
-- faces against it without standing up a live Menu.
-- The widest label a face may carry: the grid is twenty tiles and fit()
-- makes the box the widest row plus three (POK-171).
Menu.MAX_LABEL = 17

function Menu.maxRows(rowStep)
  return math.max(1, math.floor((canvasRows() - 2) / (rowStep or 2)))
end

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

  local maxVisible = Menu.maxRows(menu.rowStep)
  menu.maxVisible = maxVisible
  local visible = math.min(maxVisible, #menu.items)
  menu.th = visible * menu.rowStep + 2
  -- the cursor may have moved (or the face changed) before the cap was
  -- known; Menu:update clamps too, this keeps fit self-consistent
  menu:clampScroll()
end

-- A Menu whose rows are rebuilt from itemsFn before every frame's input,
-- sized to fit (POK-104), with the cursor never resting on a `dead` row.
-- The ROYALE screen's text faces are one of these; so are the OPTIONS box
-- and the seat box the room opens over itself (lib/lobby.lua).
function Menu.live(mod, game, itemsFn, opts)
  local o = { startCloses = true }
  for k, v in pairs(opts or {}) do o[k] = v end
  local menu = mod.ui.Menu.new(game, itemsFn(), o)
  local baseUpdate = mod.ui.Menu.update
  menu.update = function(self, dt)
    local fresh = itemsFn()
    self.items = fresh
    if self.index > #fresh then self.index = math.max(1, #fresh) end
    fit(mod, self)
    local before = self.index
    local r = baseUpdate(self, dt)
    -- The cursor never rests on a dead row (information is not a
    -- control): slide it onward in the direction it was travelling --
    -- downward after a face change or when it did not move -- wrapping
    -- until a selectable row.  Every face keeps at least one (LEAVE
    -- at minimum), and the guard stops a hypothetical all-dead face
    -- from spinning forever.
    local n = #self.items
    if n > 0 and self.items[self.index] and self.items[self.index].dead then
      local down = self.index == before
        or self.index == before + 1
        or (before == n and self.index == 1)
      local step = down and 1 or -1
      for _ = 1, n do
        self.index = ((self.index - 1 + step) % n) + 1
        local it = self.items[self.index]
        if not (it and it.dead) then break end
      end
      self:clampScroll()
    end
    return r
  end
  return menu
end

-- The ROYALE screen: one stack state with two faces.  The text faces
-- (the first menu, connecting, the offer, a refusal, the match report)
-- are the live Menu above; the lobby is the drawn room (lib/lobby.lua).
-- Which one is up is re-read from BR every frame, and a change of face
-- is what resets the cursor.  The state answers for the text menu's
-- fields (items, index, th...) so a driver that reads the rows off the
-- top of the stack still can.
function Menu.build(mod, BR)
  return {
    new = function(game)
      local Lobby = require("mods.battle_royale.lib.lobby")
      local state = {}
      local text = Menu.live(mod, game, function()
        return (Menu.items(mod, BR, game))
      end)
      local room = Lobby.Screen.new(game, mod, BR, state)
      state.room = room
      state.view = Menu.view(BR)
      state.isOpaque = state.view == "lobby"
      function state:update(dt)
        local now = Menu.view(BR)
        if now ~= self.view then
          self.view = now
          text.index = 1
          room.cur, room.scroll = 0, 0
        end
        self.isOpaque = now == "lobby"
        if now == "lobby" then room:update(dt) else text:update(dt) end
      end
      function state:draw()
        if self.view == "lobby" then room:draw() else text:draw() end
      end
      return setmetatable(state, { __index = text })
    end,
  }
end

return Menu
