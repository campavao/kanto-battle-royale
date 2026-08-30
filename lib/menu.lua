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
    items[#items + 1] = { label = label, keepOpen = true, onSelect = function() end }
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
  if view ~= "match" and view ~= "menu" and BR.lastResult then
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
        row("FOG: " .. tostring((ring.center and ring.center.name) or "CLOSING"))
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
    local relay = BR.relay
    local host = relay:isHost()
    -- A solo room has no code worth reading out, no roster to watch fill
    -- and nobody to keep seats for, so it shows the two things that
    -- actually decide the match and nothing else.
    if not BR.solo then
      row("CODE " .. tostring(relay.code))
      -- A "!" against anyone the door flagged (POK-142): their engine
      -- release, or their copy of this mod, is not ours -- so the room
      -- works, the ghosts walk, and the FIGHT is the one thing that will
      -- not.  Marked on the roster rather than only said in a text box,
      -- for two reasons: the lobby is where somebody is actually looking
      -- while they wait, and this screen opens from the TITLE as well as
      -- from the start menu -- with no overworld under it there is nothing
      -- to queue a say onto at all.
      --
      -- The "!" goes BEFORE the host's "*", which looks backwards and is
      -- not: the Gen 1 font has no asterisk, so the host marker draws as a
      -- blank cell (it always has -- this is not new).  With the "!" last
      -- a flagged host read "- HOSTA !", the mark floating a space away
      -- from the name it belongs to.  Caught in a screenshot from the
      -- two-client `door` run, which is the only place it could be.
      -- a stale arm dies with the member it pointed at
      if BR.armKick then
        local still = false
        for _, m in ipairs(relay.members) do
          if m.id == BR.armKick then still = true break end
        end
        if not still then BR.armKick = nil end
      end
      for _, m in ipairs(relay.members) do
        local label = "- " .. m.name .. (BR:buildTrouble(m.id) and "!" or "")
            .. ((m.id == relay.hostId) and "*" or "")
            -- a watcher of this match, a player of the next (POK-133)
            .. (m.spectate and " NEXT" or "")
        -- keyed on hostId, not our own id: only the host sees these
        -- settings, and the one row that must never arm is their own
        if host and m.id ~= relay.hostId then
          -- The way out of an open room (POK-130): A on a guest arms the
          -- question, A again removes them -- two presses, so a slip of
          -- the thumb never ejects a friend.  Their IP stays out for the
          -- life of the room, so this is not a revolving door.
          if BR.armKick == m.id then
            setting("REMOVE " .. m.name .. "?", function() BR:kick(m.id) end)
          else
            setting(label, function() BR.armKick = m.id end)
          end
        else
          row(label)
        end
      end
      -- ...and, under the live roster, whoever the door turned away.  On
      -- the host this is the only trace of them: a refused guest is out of
      -- the room a moment after arriving, so without this a host running
      -- something nobody else has just watches people fail to appear.
      for _, f in ipairs(BR:flaggedAbsent()) do
        row("! " .. tostring(f.name))
      end
      -- ...and when it has found something, our own two numbers under it,
      -- because the next thing that happens is somebody reading them out
      -- to somebody else.  Only under a warning: a fightable room needs
      -- none of this, and the lobby grows a row per trainer already.
      local trouble = BR:buildTroubleLabel()
      if trouble then
        row(trouble)
        local mine = BR.buildOf and BR:buildOf()
        if mine then
          -- three short rows rather than two long ones: fit() sizes the
          -- box to the widest label + 3 and the canvas is 20 tiles, so
          -- anything past 17 characters is quietly clipped off the right
          row("YOU ARE ON:")
          row("ROYALE v" .. tostring(mine.mod or "?"))
          if mine.engine then row("GAME v" .. tostring(mine.engine)) end
        end
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
      -- the log's deep tier, where the other knobs already are (POK-86).
      -- It was an environment variable for one release, which a mod cannot
      -- read: the sandbox hides the environment.  The log it thickens is
      -- this client's own, so it sits with the host's other switches.
      setting("DEBUG LOG: " .. (BR:isDebug() and "ON" or "OFF"),
              function() BR:setDebug(not BR:isDebug()) end)
      -- How many matches get played, so there is some idea whether anyone
      -- is out there (POK-124).  A random install id, the version and a
      -- count -- never the name you picked.  Off stops the counting as
      -- well as the sending.
      setting("SEND STATS: " .. (BR:statsOn() and "ON" or "OFF"),
              function() BR:setStatsOn(not BR:statsOn()) end)
      -- Only meaningful when humans might still arrive: it holds seats
      -- open for them and lets bots take whatever is left.  In a solo
      -- room nobody can arrive, so it would only ever be a second, more
      -- confusing way to say BOTS.
      if not BR.solo then
        -- "TRAINERS", spelled out (POK-148): FILL TO counts the whole
        -- roster, humans included, and the bare number read as a bot cap
        -- -- a host saw "31" and reported the 30-bot clamp broken
        setting(BR.fillTo > 0 and ("FILL: " .. BR.fillTo .. " TRAINERS")
                  or "FILL: OFF",
                function() BR:setFill(BR:nextFill()) end)
        row("TRAINERS: " .. (#relay.members + BR:botsAtStart()))
      end
      local countdown = BR:startsIn()
      -- PLAY AGAIN and START MATCH are the same button (POK-144): once
      -- every client returns to the lobby on its own, the host's "run it
      -- back" IS the lobby's start row.  Only the label changes, so nobody
      -- has to learn that the room they are looking at is the one they
      -- just played in.
      local start = BR.lastResult and "PLAY AGAIN" or "START MATCH"
      items[#items + 1] = {
        label = countdown and (start .. " (" .. countdown .. ")") or start,
        onSelect = function() BR:startMatch() end,
      }
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
    -- Which build this actually is.  Everyone in a match has to be on the
    -- same one, and "check your version" is a useless thing to say to
    -- somebody with no way to read it -- the launcher's MODS tab knows,
    -- but that is outside the game.  Read from mod.version (the loader
    -- hands each mod its own manifest version) rather than written here,
    -- so it cannot drift from the manifest the way a hand-kept copy would.
    --
    -- The ENGINE release is the other half of the answer (POK-142), and it
    -- is NOT here: this face has to fit one screen without scrolling
    -- (POK-104) and it is already full.  It shows up in the lobby, where
    -- the question is actually asked -- and only when the door has found
    -- something, which is the only time anyone needs to read it out.
    --
    -- "Already full" is the literal truth: eight rows against
    -- Menu.maxRows(2) == 8.  So the result of the match that sent a player
    -- here -- which is where a relay that closed mid-match lands them
    -- (POK-144) -- rides ON this row rather than above it.  A ninth row
    -- would push the build number off the bottom behind a scroll arrow, on
    -- the one line a refused player is asked to read out.
    --
    -- Shorter wording than the other faces' "YOU WIN!" / "MATCH OVER"
    -- because the two share seventeen characters here: at eight each they
    -- still fit beside a two-digit patch version.  The winner's name does
    -- not fit at all and is dropped -- with no room left there is nobody to
    -- play again with, so who won is the least of what this face is for.
    local build = "v" .. tostring(mod.version or "?")
    if BR.lastResult then
      row((BR.lastResult.won and "YOU WIN!" or "YOU LOST") .. " " .. build)
    else
      row(build)
    end
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
