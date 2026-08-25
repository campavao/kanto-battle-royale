-- Run on an engine that does not have the seams yet.
--
-- The mod needs eight things the stock engine has no public way to do (five
-- are proposed upstream as RFC 0014, two more -- the battle.style and
-- catch.nickname hooks -- as RFC 0015, and the catch.party_full hook as
-- RFC 0018).  On a build that has them, this file does nothing at all.  On
-- a build that does not, it installs the same behaviour from outside, so
-- one mod folder works on both.
--
-- Everything here is a LAST RESORT and says so.  Patching engine modules
-- from a mod is worse than a hook in every way that matters: two mods
-- patching the same function clobber each other instead of chaining, and
-- there is no version contract, so an upstream refactor breaks this
-- silently.  Each patch is therefore written to touch one function and to
-- delete itself the day the seam lands -- Shim.summary() names what it had
-- to do, so "still shimming X" stays visible instead of becoming the
-- permanent normal.
--
-- The sandbox permits require("src.*"); that is what makes this possible at
-- all.  It does not make it a good idea.

local Shim = {}

local applied = false
local report = { native = {}, patched = {}, failed = {} }

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local function note(bucket, name, detail)
  local list = report[bucket]
  list[#list + 1] = detail and (name .. " (" .. detail .. ")") or name
end

-- Do we already have the seams?  Four of the five are values that are either
-- there or not, and all five ship in one commit -- so this one question
-- answers for the fifth (world.talk), which is a call site in the middle of a
-- function and therefore invisible to a mod.  Answering it wrong would raise
-- that hook twice for a single press, so it is asked BEFORE anything here
-- installs its own version, or it would see this file's work and stand down.
local function seamsAreNative()
  local CodeEntry = tryRequire("src.link.CodeEntry")
  local LinkState = tryRequire("src.link.LinkState")
  local Game = tryRequire("src.core.Game")
  return (CodeEntry and CodeEntry.charAt) ~= nil
     and (LinkState and LinkState.newFromSession) ~= nil
     and (Game and Game.startNewGame) ~= nil
end

-- ---------------------------------------------------------------- CodeEntry
--
-- Pure data: every function takes a state table, so the seam's versions drop
-- straight in and a state built without options behaves exactly as before.

local function shimCodeEntry()
  local CodeEntry = tryRequire("src.link.CodeEntry")
  if not CodeEntry then return note("failed", "CodeEntry", "not requirable") end
  if CodeEntry.charAt then return note("native", "CodeEntry") end

  local function charsetOf(s) return s.charset or CodeEntry.CHARSET end
  local function lengthOf(s) return s.length or CodeEntry.LENGTH end

  function CodeEntry.new(opts)
    local charset = (opts and opts.charset) or CodeEntry.CHARSET
    local length = (opts and opts.length) or CodeEntry.LENGTH
    local chars = {}
    for i = 1, length do chars[i] = 1 end
    return { chars = chars, pos = 1, charset = charset, length = length }
  end

  function CodeEntry.fromText(text, opts)
    local state = CodeEntry.new(opts)
    local blank = state.charset:find(" ", 1, true) or 1
    for i = 1, state.length do
      local ch = tostring(text or ""):sub(i, i)
      state.chars[i] = (ch ~= "" and state.charset:find(ch, 1, true)) or blank
    end
    return state
  end

  function CodeEntry.up(state)
    local n = #charsetOf(state)
    state.chars[state.pos] = state.chars[state.pos] % n + 1
  end

  function CodeEntry.down(state)
    local n = #charsetOf(state)
    state.chars[state.pos] = (state.chars[state.pos] - 2) % n + 1
  end

  function CodeEntry.left(state) state.pos = math.max(1, state.pos - 1) end

  function CodeEntry.right(state)
    state.pos = math.min(lengthOf(state), state.pos + 1)
  end

  function CodeEntry.charAt(state, i)
    return charsetOf(state):sub(state.chars[i], state.chars[i])
  end

  function CodeEntry.text(state)
    local out = {}
    for i = 1, lengthOf(state) do out[i] = CodeEntry.charAt(state, i) end
    return table.concat(out)
  end

  note("patched", "CodeEntry", "length/charset options")
end

-- ------------------------------------------------------------- WorldAPI
--
-- Handle is a file-local, so there is no module to reach.  But
-- Handle.__index = Handle, so any handle's metatable IS the class, and
-- installing on it reaches every handle including ones already handed out.
--
-- WorldAPI:npc() is the only place a Handle is built -- spawnNpc returns an
-- id, not a handle -- so that is the one function worth wrapping to get hold
-- of the first one.

local handleReady = false

local function installHandle(Handle)
  if not Handle then return end
  if Handle.stepNow then
    handleReady = true
    return note("native", "WorldAPI handle")
  end
  local Collision = require("src.world.Collision")

  function Handle:stepNow(dir)
    local npc = self.npc
    if not Collision.DELTA[dir] then
      return nil, "bad direction: " .. tostring(dir)
    end
    if npc.moving then return nil, "already moving" end
    npc.facing = dir
    npc.targetX, npc.targetY = Collision.target(npc.cellX, npc.cellY, dir)
    npc.moving = true
    npc.progress = 0
    return true
  end

  function Handle:canStep(dir)
    local ow = self.ow
    if not (ow and ow.map) then return false end
    return Collision.canMove(ow.map, ow.entities, self.npc, dir) and true or false
  end

  function Handle:placeAt(x, y, facing)
    local npc = self.npc
    npc.moving = false
    npc.marching = false
    npc.targetX, npc.targetY = nil, nil
    npc.progress = 0
    npc.cellX, npc.cellY = x, y
    npc.px, npc.py = x * 16, y * 16
    if facing then npc.facing = facing end
    return true
  end

  function Handle:isMoving() return self.npc.moving and true or false end

  function Handle:setPassable(passable)
    self.npc.passable = passable and true or false
    return true
  end

  handleReady = true
  note("patched", "WorldAPI handle",
       "stepNow/canStep/placeAt/isMoving/setPassable")
end

local function shimWorldAPI()
  -- On an engine that has the seams there is nothing to install, and the
  -- wrapper would then sit on every npc lookup forever to discover that.
  if seamsAreNative() then
    handleReady = true
    return note("native", "WorldAPI handle")
  end
  local WorldAPI = tryRequire("src.world.WorldAPI")
  if not WorldAPI or type(WorldAPI.npc) ~= "function" then
    return note("failed", "WorldAPI", "no npc() to wrap")
  end
  local original = WorldAPI.npc
  WorldAPI.npc = function(self, ...)
    local handle, err = original(self, ...)
    if handle and not handleReady then
      local ok, whyNot = pcall(installHandle, getmetatable(handle))
      if not ok then
        handleReady = true   -- do not retry on every lookup
        note("failed", "WorldAPI handle", tostring(whyNot))
      end
    end
    return handle, err
  end
end

-- --------------------------------------------------- OverworldState.interact
--
-- The one seam with no additive shape: world.talk is a new call site in the
-- MIDDLE of interact(), so there is nothing to extend.  Rather than copy the
-- whole method (counter cells, the follower branch, signs, tiles -- all of
-- which would then drift from upstream), this raises the hook first and
-- hands the press back to the untouched original whenever nobody claims it.
--
-- Known gap: the engine's own call site also covers an object reached ACROSS
-- a counter.  This one only checks the faced cell, because the counter
-- lookup is a map method whose result the original re-derives anyway.  A mod
-- object standing behind a mart counter would not be claimed here.
--
-- Detection is the awkward part.  The other four seams are values that are
-- either there or not; a call site in the middle of a function is neither,
-- and a mod cannot read the engine's source to look for it.  So this asks
-- the other four: they all ship in one commit, so an engine with
-- CodeEntry.charAt, LinkState.newFromSession and Game.startNewGame has the
-- hook too.  Getting that wrong would raise world.talk twice for one press
-- -- once here and once at the engine's own site -- so it fails toward NOT
-- patching, and says which way it decided.

local function shimWorldTalk()
  if seamsAreNative() then return note("native", "world.talk") end
  local OverworldState = tryRequire("src.world.OverworldController")
  local Runtime = tryRequire("src.mods.Runtime")
  if not (OverworldState and Runtime) then
    return note("failed", "world.talk", "modules not requirable")
  end
  if OverworldState.__brTalkShim then return end

  local original = OverworldState.interact
  if type(original) ~= "function" then
    return note("failed", "world.talk", "no interact to wrap")
  end

  OverworldState.interact = function(self)
    -- nothing wrapped it: leave the press completely alone
    if Runtime.wantsHook("world.talk") then
      local ok, claimed, npc, fx, fy = pcall(function()
        local cx, cy = self.player:facingCell()
        local target = self:npcAtCell(cx, cy)
        if not target or target.moving or target.pikachuFollower then
          return false, nil, cx, cy
        end
        -- vanilla runs only if every wrapper called next(), which is how we
        -- learn that nobody wanted it
        local fellThrough = false
        Runtime.call("world.talk", function() fellThrough = true end,
                     self, target)
        return not fellThrough, target, cx, cy
      end)
      if ok and claimed then
        -- the engine reports the press either way; match it
        Runtime.emit("world.interacted", { mapId = self.map and self.map.id,
                                           x = fx, y = fy, kind = "npc",
                                           target = npc })
        return
      end
    end
    return original(self)
  end

  OverworldState.__brTalkShim = true
  note("patched", "world.talk", "interact wrapper")
end

-- ------------------------------------------------------------- LinkState
--
-- Two additions: a constructor that adopts an already-paired transport, and
-- the outcome event.  The adopted stage has to be handled before the
-- original sees it, because the original has no case for it.

local function shimLinkState()
  local LinkState = tryRequire("src.link.LinkState")
  local Runtime = tryRequire("src.mods.Runtime")
  if not (LinkState and Runtime) then
    return note("failed", "LinkState", "modules not requirable")
  end
  if LinkState.newFromSession then return note("native", "LinkState") end
  local Session = tryRequire("src.link.Session")
  if not Session then return note("failed", "LinkState", "no Session") end

  function LinkState.newFromSession(game, transport, mode, isHost, opts)
    local self = LinkState.new(game)
    self.net = Session.new(transport, { role = isHost and "host" or "guest",
                                        kind = "link" })
    self.adopted = true
    self.adoptedMode, self.adoptedHost = mode, isHost and true or false
    self.forceLevel = opts and opts.forceLevel or nil
    self.stage = "adopted"
    self:sendHello(isHost and mode or nil)
    return self
  end

  local original = LinkState.update
  LinkState.update = function(self, dt)
    if self.stage == "adopted" then
      if self:pollHello() then
        self:decideCompat(self.adoptedMode, self.adoptedHost)
        -- the engine's version skips the level-rule menu for an adopted
        -- session, because the rule was passed in; without that condition we
        -- land on the menu, so step past it here
        if self.stage == "battleOptions" then
          self:startMode(self.adoptedMode, self.adoptedHost)
        end
      end
      return
    end

    local ending = self.stage == "battleRunning" and self.battle
      and self.game and self.game.stack and self.game.stack:top() == self
    local battle = ending and self.battle or nil
    local result = original(self, dt)
    if battle and self.battle == nil and Runtime.wants("link.battle_ended") then
      Runtime.emit("link.battle_ended", {
        result = battle.result or "ended",
        myParty = battle.playerParty,
        theirParty = battle.enemyParty,
        peerName = self.peerName,
        role = self.isHost and "host" or "guest",
      })
    end
    return result
  end

  note("patched", "LinkState", "newFromSession + adopted stage + battle_ended")
end

-- ------------------------------------------------------------------ Game
--
-- The title's NEW GAME closure, as a callable.  Only opts.intro == false is
-- reproduced faithfully: that is the path a mode supplying its own starting
-- state uses, and the intro branch needs a file-local screen table this
-- cannot see.

local function shimStartNewGame()
  local Game = tryRequire("src.core.Game")
  if not Game then return note("failed", "Game", "not requirable") end
  if Game.startNewGame then return note("native", "Game:startNewGame") end
  local SaveData = tryRequire("src.core.SaveData")
  local Runtime = tryRequire("src.mods.Runtime")
  local Screens = tryRequire("src.ui.Screens")
  if not (SaveData and Runtime) then
    return note("failed", "Game", "no SaveData/Runtime")
  end

  function Game:startNewGame(opts)
    local OverworldState = require("src.world.OverworldController")
    while self.stack:top() do self.stack:pop() end
    -- the engine also stamps sessionStartedAt here; os.time is denied to
    -- mods, so a shimmed session keeps whatever it had.  Only a throwaway
    -- match world calls this, and nothing reads it there.
    self.save = SaveData.newGame(self:bootConfig())
    self:adoptSave(self.save)
    Runtime.emit("save.created", { save = self.save })
    self:applyOptions(self.save.options)
    self.stack:push(OverworldState, self.save.player.map,
                    self.save.player.x, self.save.player.y,
                    self.save.player.facing,
                    { via = "boot", freshBoot = true })
    if not (opts and opts.intro == false) and Screens then
      pcall(Screens.push, self, "OakSpeech", function() end)
    end
  end

  note("patched", "Game:startNewGame", "intro=false path")
end

-- ---------------------------------------------------------- BattleState
--
-- Two rule hooks (RFC 0015).  The engine's versions are methods on the
-- class, so "native" is a plain presence check.
--
-- catch.nickname: the prompt is its own method, so the patch sits on it and
-- asks the hook first.  When the hook declines, the queue slot the engine
-- already reserved for the prompt still has to be filled with a state --
-- BattleState pushes whatever the slot's factory returns -- so it gets a
-- text box that closes itself on its first frame.
--
-- battle.style: the stock engine reads save.options.battleStyle inline at
-- the moment the foe's Pokemon faints, inside a function far too big to
-- replace.  So BattleState:battleStyle() is installed (the same method the
-- seam adds, so the question reads the same on both engines), and
-- enter/finish are wrapped: when a battle starts the hook is asked and, if
-- it answers "set"/"shift", the OPTION value is swapped for that battle and
-- put back when it finishes.  One baseline for all battles, not one per
-- battle, so a battle that never reaches finish (a dead one, a link
-- teardown) cannot make the next one remember "set" as what the player
-- chose.  The window is one battle wide; the one way it can leak is the
-- speed hotkey, which rewrites the options file whenever it is pressed, and
-- the restore at finish repairs that on the next press.  The engine's seam
-- has none of this, which is the argument for the seam.

local function shimBattleRules()
  local BattleState = tryRequire("src.battle.BattleState")
  local Runtime = tryRequire("src.mods.Runtime")
  if not (BattleState and Runtime) then
    return note("failed", "BattleState", "not requirable")
  end

  if BattleState.offerNickname then
    note("native", "catch.nickname")
  else
    local TextBox = tryRequire("src.render.TextBox")
    local original = BattleState.askNicknameUI
    if not (TextBox and original) then
      note("failed", "catch.nickname", "no askNicknameUI/TextBox")
    else
      local function alwaysAsk() return true end
      BattleState.askNicknameUI = function(self, mon, displayName)
        local verdict = Runtime.call("catch.nickname", alwaysAsk, mon,
          { battle = self, name = displayName, game = self.game })
        if verdict == false or type(verdict) == "string" then
          if type(verdict) == "string" then
            verdict = verdict:sub(1, 10)
            if #verdict > 0 then mon.nickname = verdict end
          end
          return TextBox.new(self.game, "", nil,
                             { auto = { delay = 0 }, instant = true })
        end
        return original(self, mon, displayName)
      end
      note("patched", "catch.nickname", "askNicknameUI asks the hook first")
    end
  end

  if BattleState.battleStyle then
    note("native", "battle.style")
  else
    local enter, finish = BattleState.enter, BattleState.finish
    if not (enter and finish) then
      note("failed", "battle.style", "no enter/finish to wrap")
    else
      local function styleFromOptions(battle)
        return tostring(((battle.game.save or {}).options or {}).battleStyle
                        or "shift"):lower()
      end

      function BattleState:battleStyle()
        if not Runtime.wantsHook("battle.style") then return styleFromOptions(self) end
        local style = Runtime.call("battle.style", styleFromOptions, self)
        if style == "set" then return "set" end
        if style == "shift" then return "shift" end
        return styleFromOptions(self)
      end

      local baseline = nil   -- what the row said before any swap

      local function optionsOf(battle)
        local save = battle and battle.game and battle.game.save
        return save and save.options
      end

      BattleState.enter = function(self, ...)
        local result = enter(self, ...)
        local opts = optionsOf(self)
        if opts and not (self.dead and not self.player) then
          local style = self:battleStyle()
          if style ~= opts.battleStyle then
            if baseline == nil then baseline = opts.battleStyle end
            opts.battleStyle = style
          end
        end
        return result
      end

      BattleState.finish = function(self, ...)
        local opts = optionsOf(self)
        if opts and baseline ~= nil then
          opts.battleStyle = baseline
          baseline = nil
        end
        return finish(self, ...)
      end

      note("patched", "battle.style", "battleStyle() + OPTION swapped per battle")
    end
  end
end

-- ----------------------------------------------------------- Boxes.deposit
--
-- catch.party_full (RFC 0018): the seam is a call site in the middle of
-- storeCaughtMon, invisible to a mod on a build that predates it -- the same
-- shape of problem as world.talk, and with the same answer: raise the hook
-- from the one call the old branch makes that a patch can reach.  A claim
-- refuses the deposit, so nothing reaches a box on either engine; on a seam
-- engine the call site raises first and a claim never gets here, so this
-- fires a second time only for a hook that already declined, which is
-- stateless and declines again.  The mod takes custody from the
-- pokemon.caught emit, which carries the mon the deposit refused.
--
-- What the shim cannot repair is the text: the old branch answers a refused
-- deposit with "But every BOX is full!" before the mod's picker opens --
-- the wrong reason for the right decision, and the argument for the seam.

local function shimCatchPartyFull()
  local BattleState = tryRequire("src.battle.BattleState")
  if BattleState and BattleState.partyFullDestination then
    return note("native", "catch.party_full")
  end
  local Boxes = tryRequire("src.pokemon.Boxes")
  local Runtime = tryRequire("src.mods.Runtime")
  if not (Boxes and Runtime) then
    return note("failed", "catch.party_full", "no Boxes/Runtime")
  end
  if Boxes.__brPartyFullShim then return end
  local original = Boxes.deposit
  if type(original) ~= "function" then
    return note("failed", "catch.party_full", "no deposit to wrap")
  end

  Boxes.deposit = function(save, mon)
    if Runtime.wantsHook("catch.party_full") then
      local claimed = Runtime.call("catch.party_full", function() return false end,
                                   { save = save, mon = mon })
      if claimed then return nil end
    end
    return original(save, mon)
  end

  Boxes.__brPartyFullShim = true
  note("patched", "catch.party_full", "deposit asks the hook first")
end

-- ------------------------------------------------------------------ apply

-- Idempotent: safe to call from more than one place, and a second call is a
-- no-op rather than a second layer of wrappers.
function Shim.apply()
  if applied then return report end
  applied = true
  -- world.talk first, and deliberately: it decides whether it is needed by
  -- asking whether the OTHER seams are native, so it has to look before
  -- they are installed or it would see this file's own work and stand down.
  shimWorldTalk()
  shimCodeEntry()
  shimWorldAPI()
  shimLinkState()
  shimStartNewGame()
  shimBattleRules()
  shimCatchPartyFull()
  return report
end

function Shim.report() return report end

-- one line for the log, so a shimmed build is obvious in a bug report
function Shim.summary()
  local parts = {}
  if #report.patched > 0 then
    parts[#parts + 1] = "shimmed: " .. table.concat(report.patched, ", ")
  end
  if #report.failed > 0 then
    parts[#parts + 1] = "COULD NOT SHIM: " .. table.concat(report.failed, ", ")
  end
  if #parts == 0 then return "engine has every seam natively" end
  return table.concat(parts, "; ")
end

return Shim
