-- The fight a spectator is shown, on the battle screen itself.
--
-- A spectator used to sit on the map for the length of somebody else's
-- battle, looking at two sprites with a mark over their heads.  Now the
-- trainer being watched RECORDS their fight as it happens -- the seed their
-- battle rolls on, both parties as they stood at the first turn, and every
-- choice they make -- and the spectator REPLAYS it through the engine's own
-- BattleState: the same screen, text, animations and HP bars the player is
-- looking at, one relay hop behind.
--
-- Why a replay and not a stream of pictures: the engine already runs every
-- battle through one injected RNG (BattleState.rng) precisely so that a
-- link battle can be simulated on both cables from a shared seed, and it
-- ships a read-only observer for exactly that (LinkBattle.newSpectator, the
-- tournament's).  Identical party copies + identical RNG stream + the same
-- actions in the same order = the same battle.  So a wild fight or a
-- trainer fight -- which resolve on ONE client from that RNG -- is fully
-- described by a seed and the player's choices, a few dozen bytes a turn,
-- and a duel is described by the lockstep messages the two cables already
-- exchange.  A spectator who arrives mid-fight is sent the whole log and
-- fast-forwards through it.
--
-- Two sides live here.  `record` wraps the live battle on the watched
-- client and turns its committed choices into frames; `open` builds the
-- replica on the spectator's client and drives it from those frames.  The
-- frames' shape is the contract between them, and lib/wire.lua checks it
-- at the door.
--
-- What a replica never does: touch the spectator's save (a caught mon stays
-- on the screen and goes nowhere), take the spectator's input (the battle
-- reads a stand-in that only ever presses A to turn a page), or report
-- itself as a battle to the rest of this mod (`mirror = true`, which the
-- battle.started / battle.ended handlers in main.lua step around).
--
-- Known limits, deliberately: a move learned mid-fight is not learned on
-- the replica (the menu is skipped), and a nickname prompt after a catch is
-- skipped too.  Neither changes what the fight looks like from outside.
-- Every action frame carries both actives' HP, and the replica snaps to it
-- before applying the action, so any drift heals at the next turn.

local Mirror = {}

Mirror.KINDS = { wild = true, trainer = true, link = true }
-- frames a player's turn can be: the shapes lib/wire.lua accepts
Mirror.ACTS = { move = true, struggle = true, locked = true, switch = true,
                run = true, ball = true, item = true, replace = true,
                choice = true, link = true }
-- ...and what a lockstep message riding a `link` frame may be
Mirror.LINK_TYPES = { action = true, replace = true, bye = true, forfeit = true }
Mirror.LINK_KINDS = { move = true, struggle = true, locked = true,
                      switch = true, run = true }

-- a page of text holds this long before the replica turns it (a reading
-- pace; the real player presses A whenever they like)
Mirror.PAGE_SECONDS = 1.1
-- frames are fast-forwarded when this many are waiting
Mirror.CATCHUP_AT = 2
-- how many engine ticks a catch-up may run per real frame
Mirror.CATCHUP_TICKS = 40
-- a replica waiting this long for a frame that never comes closes itself
Mirror.IDLE_SECONDS = 45
-- frames carry the fight's roll-by-roll trace and a drifting replica logs
-- both traces side by side: a diagnostic, off in a release
Mirror.DEBUG = false

-- Deterministic Park-Miller PRNG -- LinkBattle.lua's, which is local there.
-- Both ends must roll identical streams, so love.math.random cannot be it.
function Mirror.makeRng(seed)
  local s = tonumber(seed) or 1
  if s ~= s or s == math.huge or s == -math.huge then s = 1 end
  s = math.floor(s) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(a, b)
    s = (s * 16807) % 2147483647
    if a == nil then return s / 2147483647 end
    if b == nil then a, b = 1, a end
    return a + (s % (b - a + 1))
  end
end

function Mirror.newSeed()
  if love and love.math and love.math.random then
    return love.math.random(1, 2 ^ 30)
  end
  return math.random(1, 2 ^ 30)
end

local function copyList(list, max)
  local out = {}
  for i, v in ipairs(list or {}) do
    if max and i > max then break end
    out[i] = v
  end
  return out
end

local STAGES = { "attack", "defense", "speed", "special", "accuracy", "evasion" }

-- what an item can change on the active mon, so the replica can apply the
-- bag's work without running the bag
local function snapshotOf(b)
  if not (b and b.mon) then return nil end
  local stages = {}
  for _, k in ipairs(STAGES) do stages[k] = (b.stages or {})[k] or 0 end
  return { hp = b.mon.hp, status = b.mon.status, stages = stages }
end

local function indexIn(list, mon)
  for i, m in ipairs(list or {}) do if m == mon then return i end end
  return nil
end

-- The state a turn starts from, as a short string: both actives (species,
-- HP, status, stat stages, PP) and both benches (species, HP).  Every
-- action frame carries the fight's; the replica compares it with its own
-- before applying the action, and a mismatch names the field that drifted
-- -- the same idea as LinkBattle's per-turn hash, kept readable.
local function battlerSig(b)
  if not (b and b.mon) then return "-" end
  local st = {}
  for _, k in ipairs(STAGES) do st[#st + 1] = tostring((b.stages or {})[k] or 0) end
  local pp = {}
  for _, mv in ipairs(b.mon.moves or {}) do pp[#pp + 1] = tostring(mv.id) .. "=" .. tostring(mv.pp or 0) end
  return ("%s:%d:%s:%s:%s"):format(tostring(b.mon.species), b.mon.hp or 0,
                                   tostring(b.mon.status), table.concat(st, ","),
                                   table.concat(pp, ","))
end

local function benchSig(list)
  local out = {}
  for _, mon in ipairs(list or {}) do
    out[#out + 1] = tostring(mon.species) .. ":" .. tostring(mon.hp or 0)
  end
  return table.concat(out, "|")
end

function Mirror.signature(battle)
  local mine = type(battle.playerPartyView) == "function" and battle:playerPartyView()
               or battle.playerParty
  return (battlerSig(battle.player) .. " / " .. battlerSig(battle.enemy) .. " // "
          .. benchSig(mine) .. " / " .. benchSig(battle.enemyParty)):sub(1, 300)
end

-- ------- recording (the watched client)

-- battle: a live BattleState (wild or trainer; a duel goes through
-- recordLink).  opts: { kind, pack, seed, myName, foeName, badges, hooked,
-- send }.  `pack` is Protocol.packMon, injected so the recorder can be
-- driven against a plain table in br_test.
function Mirror.record(battle, opts)
  opts = opts or {}
  local rec = { battle = battle, log = {}, send = opts.send or function() end,
                stopped = false, pendingSwitch = false, link = false }
  local function emit(frame)
    if rec.stopped then return end
    frame.n = #rec.log + 1
    rec.log[frame.n] = frame
    rec.send(frame)
  end
  rec.emit = emit

  local seed = opts.seed or Mirror.newSeed()
  -- from here on the battle rolls on a stream the replica can follow; the
  -- rolls are counted so a frame can say how far along the stream it sits
  -- (a replica that disagrees has drifted, and says where)
  local stream = Mirror.makeRng(seed)
  rec.rolls = 0
  rec.trace = {}
  battle.rng = function(a, b)
    rec.rolls = rec.rolls + 1
    if Mirror.DEBUG then rec.trace[#rec.trace + 1] = tostring(a) .. ":" .. tostring(b) end
    return stream(a, b)
  end
  local pack = opts.pack or function(m) return m end
  local function packParty(list)
    local out = {}
    for i, mon in ipairs(list or {}) do if i <= 6 then out[#out + 1] = pack(mon) end end
    return out
  end
  local me = packParty(type(battle.playerPartyView) == "function"
                         and battle:playerPartyView() or battle.playerParty)
  local foe = packParty(battle.enemyParty
                          or (battle.enemy and { battle.enemy.mon }) or {})
  local trainer
  if opts.kind == "trainer" and battle.trainer then
    trainer = { class = battle.oppClass, name = battle.trainer.name,
                aiClass = battle.trainer.aiClass,
                aiMods = copyList(battle.trainer.aiMods, 8) }
  end
  emit({ k = "start", kind = opts.kind or "wild", seed = seed, me = me, foe = foe,
         myName = opts.myName, foeName = opts.foeName, trainer = trainer,
         badges = copyList(opts.badges, 8), hooked = opts.hooked and true or nil })

  local function hpNow()
    return { me = battle.player and battle.player.mon and battle.player.mon.hp,
             foe = battle.enemy and battle.enemy.mon and battle.enemy.mon.hp }
  end
  local function act(frame)
    frame.hp = hpNow()
    frame.rolls = rec.rolls
    frame.sig = Mirror.signature(battle)
    if Mirror.DEBUG then
      frame.trace = table.concat(rec.trace, "|"):sub(1, 400)
      rec.trace = {}
    end
    emit(frame)
  end

  local function wrap(name, fn)
    local base = battle[name]
    if type(base) ~= "function" then return end
    battle[name] = function(s, ...)
      fn(s, ...)
      return base(s, ...)
    end
  end

  -- the same encoding LinkBattle puts on its cable
  wrap("resolveTurn", function(s, action)
    if type(action) ~= "table" then return end
    if action.struggle then
      act({ k = "struggle" })
    elseif action.special then
      act({ k = "locked" })
    else
      local slot = indexIn(s.player and s.player.curMoves, action)
      if slot then act({ k = "move", slot = slot }) else act({ k = "locked" }) end
    end
  end)
  wrap("resolveSwitch", function(s, newMon)
    local list = type(s.playerPartyView) == "function" and s:playerPartyView() or s.playerParty
    local idx = indexIn(list, newMon)
    if idx then
      rec.pendingSwitch = true
      act({ k = "switch", index = idx })
    end
  end)
  wrap("tryRun", function() act({ k = "run" }) end)
  wrap("throwBall", function(_, ball) act({ k = "ball", item = ball }) end)
  wrap("itemUsed", function(s, messages)
    act({ k = "item", msgs = copyList(messages, 6), snap = snapshotOf(s.player) })
  end)
  -- a yes/no the player answers (SHIFT's "will you change?", and any
  -- other prompt the engine phrases through sayChoice)
  do
    local base = battle.sayChoice
    if type(base) == "function" then
      battle.sayChoice = function(s, text, onChoose, o)
        return base(s, text, function(yes)
          emit({ k = "choice", yes = yes and true or false })
          if onChoose then return onChoose(yes) end
        end, o)
      end
    end
  end

  -- main.lua forwards battle.battler_switched here: a send-out on our side
  -- that no resolveSwitch announced is a replacement picked after a faint
  function rec:onSwitched(ev)
    if self.stopped or not ev or ev.battle ~= self.battle then return end
    if not (ev.side and ev.side.index == 1) then return end
    if self.pendingSwitch then
      self.pendingSwitch = false
      return
    end
    local list = type(self.battle.playerPartyView) == "function"
                   and self.battle:playerPartyView() or self.battle.playerParty
    local idx = ev.battler and ev.battler.mon and indexIn(list, ev.battler.mon)
    if idx then emit({ k = "replace", index = idx }) end
  end

  function rec:stop(result)
    if self.stopped then return end
    emit({ k = "end", result = result and tostring(result) or nil })
    self.stopped = true
  end

  return rec
end

-- A duel: the lockstep messages themselves are the record.  channel is
-- lib/channel.lua's (its send is tapped; main.lua hands inbound `bt` to
-- rec:onTheirs).  opts: { seed, isHost, me, foe (packed), myName, foeName,
-- send }.
function Mirror.recordLink(channel, opts)
  opts = opts or {}
  local rec = { log = {}, send = opts.send or function() end, stopped = false,
                link = true, channel = channel }
  local function emit(frame)
    if rec.stopped then return end
    frame.n = #rec.log + 1
    rec.log[frame.n] = frame
    rec.send(frame)
  end
  rec.emit = emit
  local mySide = opts.isHost and "host" or "guest"
  local theirSide = opts.isHost and "guest" or "host"
  emit({ k = "start", kind = "link", seed = opts.seed, host = opts.isHost and "me" or "foe",
         me = copyList(opts.me, 6), foe = copyList(opts.foe, 6),
         myName = opts.myName, foeName = opts.foeName })

  local function relevant(m)
    return type(m) == "table" and Mirror.LINK_TYPES[m.type] == true
  end
  local function slim(m)
    return { type = m.type, kind = m.kind, slot = m.slot, index = m.index }
  end
  if channel then
    local baseSend = channel.send
    channel.send = function(ch, msg)
      if relevant(msg) then emit({ k = "link", side = mySide, m = slim(msg) }) end
      return baseSend(ch, msg)
    end
  end
  function rec:onTheirs(inner)
    if relevant(inner) then emit({ k = "link", side = theirSide, m = slim(inner) }) end
  end
  function rec:onSwitched() end
  function rec:stop(result)
    if self.stopped then return end
    emit({ k = "end", result = result and tostring(result) or nil })
    self.stopped = true
    if self.channel and self.channel.send and rawget(self.channel, "send") then
      self.channel.send = nil   -- back to the metatable's
    end
  end
  return rec
end

-- ------- replaying (the spectator)

-- The input the replica reads instead of the spectator's: nothing is ever
-- down, and A is pressed exactly when the replica decides a page has been
-- read.  Everything else falls through to the real input object.
local function standIn(real)
  local proxy = { fireA = false, fast = false }
  proxy.wasPressed = function(_, btn)
    if btn == "a" and proxy.fireA then
      proxy.fireA = false
      return true
    end
    return false
  end
  proxy.isDown = function(_, btn)
    return proxy.fast and (btn == "a" or btn == "b")
  end
  return setmetatable(proxy, { __index = real })
end

-- a screen the replica pushes where the engine wanted a menu: it draws the
-- battle under it and either waits for a frame or leaves at once
local function stub(game, battle, wait)
  local st = { transparent = true }
  function st:enter() end
  function st:exit() end
  function st:draw() if battle.draw then battle:draw() end end
  function st:update(dt)
    local done = (not wait) or wait(dt)
    if done and game.stack:top() == self then game.stack:pop() end
  end
  return st
end

local function firstHealthy(list)
  for _, m in ipairs(list or {}) do if (m.hp or 0) > 0 then return m end end
  return list and list[1]
end

-- ------- a battle's view of the client it runs on
--
-- BattleState reads its player's name, party, badges and options off
-- game.save, and pushes its menus on game.stack.  A replica or a headless
-- fight is somebody ELSE's battle, so it gets a game whose save says that
-- somebody's name and party (and no badges: the copies hit as the
-- recording says), whose input is the stand-in above, and -- for a fight
-- nobody is looking at -- a private stack where its menus can come and go
-- without touching the screen.  Everything else falls through.
function Mirror.fakeStack()
  local st = { states = {} }
  function st:push(s) self.states[#self.states + 1] = s; if s.enter then s:enter() end end
  function st:pop()
    local s = table.remove(self.states)
    if s and s.exit then s:exit() end
    return s
  end
  function st:top() return self.states[#self.states] end
  return st
end

-- opts: { name, party, options, stack } -- stack nil means a private one
function Mirror.proxyGame(game, opts)
  opts = opts or {}
  local realSave = game.save or {}
  local save = setmetatable({
    player = setmetatable({ name = opts.name or "?" }, { __index = realSave.player or {} }),
    party = opts.party or {},
    inventory = {},
    options = setmetatable(opts.options or {}, { __index = realSave.options or {} }),
  }, { __index = realSave })
  local pg = setmetatable({ save = save, input = standIn(game.input),
                            stack = opts.stack or Mirror.fakeStack() }, { __index = game })
  return pg
end

-- run fn with the engine's sound and music silenced: a fight nobody is
-- looking at must not be heard either
function Mirror.muted(fn)
  local saved = {}
  local mods = {}
  for _, name in ipairs({ "src.core.Sound", "src.core.Music" }) do
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then mods[#mods + 1] = m end
  end
  local function noop() end
  for _, m in ipairs(mods) do
    for k, v in pairs(m) do
      if type(v) == "function" then saved[#saved + 1] = { m, k, v }; m[k] = noop end
    end
  end
  local ok, err = pcall(fn)
  for _, s in ipairs(saved) do s[1][s[2]] = s[3] end
  if not ok then error(err, 0) end
end

-- shared by both replicas: the frame queue, the stand-in input, the page
-- turner, catch-up, the idle close
local function install(game, s, opts, applyFrame, frozen)
  local log = opts.log or function() end
  s.mirror = true
  s.mirrorPending = {}
  s.mirrorInput = s.game.input       -- the proxy game's stand-in
  s.mirrorHold = 0
  s.mirrorIdle = 0
  s.mirrorEnd = nil
  s.mirrorClosed = false

  function s:feed(frame)
    if type(frame) ~= "table" then return end
    if frame.k == "end" then
      self.mirrorEnd = frame.result or "ended"
      return
    end
    self.mirrorPending[#self.mirrorPending + 1] = frame
  end

  function s:peekFrame() return self.mirrorPending[1] end
  function s:takeFrame() return table.remove(self.mirrorPending, 1) end

  -- pop the head only when it is one of `kinds`; a head of another kind is
  -- somebody else's to take (a replace while the picker waits, a choice
  -- while the prompt waits)
  function s:takeIf(kinds)
    local f = self.mirrorPending[1]
    if f and kinds[f.k] then return table.remove(self.mirrorPending, 1) end
    return nil
  end

  local baseUpdate = s.update
  local function tick(self, dt, fast)
    self.mirrorInput.fast = fast
    if frozen(self) then
      -- between turns: the real player is at their menu.  Apply the next
      -- action if one is here; otherwise hold the picture.
      if not applyFrame(self) then
        if self.phase == "menu" then self.phase = "waitBoth" end
        self:tickFx()
        self.mirrorIdle = self.mirrorIdle + dt
        return
      end
    end
    self.mirrorIdle = 0
    -- turn the page once it has been read
    if self.msgWaiting or self.msgPrompt then
      self.mirrorHold = self.mirrorHold + dt
      if fast or self.mirrorHold >= Mirror.PAGE_SECONDS then
        self.mirrorHold = 0
        self.mirrorInput.fireA = true
      end
    else
      self.mirrorHold = 0
    end
    baseUpdate(self, dt)
    self.mirrorInput.fireA = false
  end

  s.update = function(self, dt)
    if self.mirrorClosed then
      -- closed before the entry wipe put us on the stack: leave at once
      if game.stack:top() == self then game.stack:pop() end
      return
    end
    local ok, err = pcall(function()
      -- Catch-up is for the BACKLOG a late arrival is handed, never for
      -- live lag: a fight that runs a shade faster on the other end must
      -- not turn into a blur here.  The backlog is whatever was waiting
      -- before the first frame of ours had played.
      if self.mirrorBacklog == nil then
        self.mirrorBacklog = #self.mirrorPending >= Mirror.CATCHUP_AT
      end
      if self.mirrorBacklog and #self.mirrorPending >= Mirror.CATCHUP_AT then
        local n = 0
        while n < Mirror.CATCHUP_TICKS and #self.mirrorPending >= Mirror.CATCHUP_AT do
          n = n + 1
          tick(self, 1 / 60, true)
          if self.mirrorClosed then break end
        end
      else
        self.mirrorBacklog = false
        tick(self, dt, false)
      end
    end)
    if not ok then
      log("mirror: replica threw (%s); closing", tostring(err))
      self:mirrorClose("error")
      return
    end
    if self.mirrorClosed then return end
    -- the fight is over on their side and the replica has shown all of it
    if self.mirrorEnd and #self.mirrorPending == 0 and frozen(self) then
      self:mirrorClose(self.mirrorEnd)
    elseif self.mirrorIdle > Mirror.IDLE_SECONDS then
      log("mirror: no frame for %ds; closing", Mirror.IDLE_SECONDS)
      self:mirrorClose("idle")
    end
  end

  function s:mirrorClose(why)
    if self.mirrorClosed then return end
    self.mirrorClosed = true
    self.mirrorWhy = why
    if self.mirrorNet and game.linkNet == self.mirrorNet then game.linkNet = nil end
    pcall(function() require("src.core.Sound").stopLoop("Low_Health_Alarm") end)
    pcall(function() require("src.core.Music").restoreMap(game.data) end)
    -- whatever the engine stacked over us (a stub) leaves with us
    local states = game.stack.states or {}
    local onStack = false
    for i = #states, 1, -1 do
      if states[i] == self then
        while #states > i do game.stack:pop() end
        game.stack:pop()
        onStack = true
        break
      end
    end
    -- the fade back in from white every battle leaves through
    if onStack then
      pcall(function()
        game.stack:push(require("src.render.Transition").battleReturn(game, function() end))
      end)
    end
    if opts.onClosed then opts.onClosed(self, why) end
  end
end

-- unpack a packed party into fresh mon copies; a mon this build cannot
-- rebuild is dropped rather than refused -- a spectator with five of six is
-- better served than one told nothing
local function unpackParty(game, packed)
  local Protocol = require("src.link.Protocol")
  local out = {}
  for _, p in ipairs(packed or {}) do
    local ok, mon = pcall(Protocol.unpackMon, game.data, p, {})
    if ok and mon then out[#out + 1] = mon end
  end
  return out
end

-- a wild or trainer fight: a BattleState of the same kind, every menu
-- replaced by a wait for the frame that says what the player chose
local function openLocal(game, start, opts)
  local BattleState = require("src.battle.BattleState")
  local Strings = require("src.core.Strings")
  local me, foe = unpackParty(game, start.me), unpackParty(game, start.foe)
  if #me == 0 or #foe == 0 then return nil, "nothing to show" end

  -- the watched trainer's name and party, on the real screen stack
  local pg = Mirror.proxyGame(game, { name = start.myName, party = me, stack = game.stack })
  local s = BattleState.newWild(pg, foe[1].species, foe[1].level)
  s.dead = false
  local stream = Mirror.makeRng(start.seed)
  s.mirrorRolls = 0
  s.mirrorTrace = {}
  s.rng = function(a, b)
    s.mirrorRolls = s.mirrorRolls + 1
    if Mirror.DEBUG then s.mirrorTrace[#s.mirrorTrace + 1] = tostring(a) .. ":" .. tostring(b) end
    return stream(a, b)
  end
  s.playerParty = me
  s.playerPartyIndices = nil
  -- the watched trainer's badges, so the copies hit as hard as theirs
  local inv = {}
  for _, b in ipairs(start.badges or {}) do inv[b] = true end
  s.player = BattleState.makeBattler(game.data, firstHealthy(me), true, { inventory = inv })
  s.enemyParty = foe
  s.enemyIndex = 1
  s.enemy = BattleState.makeBattler(game.data, foe[1], false)
  s.onFinish = nil
  if start.kind == "trainer" then
    local t = start.trainer or {}
    local base = t.class and game.data.trainers and game.data.trainers[t.class]
    if not base then return nil, "unknown trainer class " .. tostring(t.class) end
    s.kind = "trainer"
    s.oppClass = t.class
    s.partyIndex = 1
    s.trainer = setmetatable({ name = t.name, aiClass = t.aiClass, aiMods = t.aiMods },
                             { __index = base })
    s.enemyAIMods = s.trainer.aiMods
    s.aiUses = s:aiUsesFor()
    s.trainerPic = BattleState.trainerSprite(game.data, s.trainer, t.class, 1)
    s.introText = Strings("%s wants\nto fight!", s.trainer.name or base.name or "?")
  else
    s.kind = "wild"
    if start.hooked then
      s.introText = s:romText("_HookedMonAttackedText", "The hooked\n%s\nattacked!", s.enemy.name)
    else
      s.introText = s:romText("_WildMonAppearedText", "Wild %s\nappeared!", s.enemy.name)
    end
  end

  -- a caught mon joins the ball row and nothing else
  s.storeCaughtMon = function(self)
    if #me < 6 and self.enemy and self.enemy.mon then me[#me + 1] = self.enemy.mon end
  end
  -- the engine's menus, answered by frames.  The replacement picker keeps
  -- the engine's own send-out closure (opts.onSwitch) so a replacement
  -- looks exactly as it did for the player; every other screen -- learn a
  -- move, nickname, the bag -- leaves at once.
  s.buildScreen = function(self, id, sopts)
    if id == "PartyMenu" and type(sopts) == "table" and sopts.forceSwitch then
      return stub(game, self, function()
        local f = self:takeIf({ replace = true })
        if not f then return false end
        local mon = me[f.index]
        if mon and sopts.onSwitch then sopts.onSwitch(mon) end
        return true
      end)
    end
    return stub(game, self, nil)
  end
  -- the engine appends the prompt to the queue; so does this, and the wait
  -- re-inserts itself right behind the current row (actNext) so nothing
  -- queued after the prompt runs before it is answered
  s.sayChoice = function(self, text, onChoose)
    self:say(text)
    local function await()
      local f = self:takeIf({ choice = true })
      if f then
        if onChoose then onChoose(f.yes and true or false) end
      elseif not self.mirrorEnd then
        self:actNext(await)
      end
    end
    self:act(await)
  end
  -- nobody drives the replica from the keyboard
  s.openItems = function(self) self.phase = "waitBoth" end
  s.openParty = function(self) self.phase = "waitBoth" end

  local function frozen(self)
    return self.phase == "menu" or self.phase == "waitBoth"
  end
  local ACTIONS = { move = true, struggle = true, locked = true, switch = true,
                    run = true, ball = true, item = true }
  local log = opts.log or function() end
  local function snap(self, hp)
    if type(hp) ~= "table" then return end
    for _, pair in ipairs({ { self.player, hp.me, "ours" }, { self.enemy, hp.foe, "theirs" } }) do
      local b, want = pair[1], pair[2]
      if b and b.mon and type(want) == "number" and b.mon.hp ~= want then
        log("mirror: turn %d, %s %s at %d HP, the fight says %d; snapped",
            self.turnCount or 0, pair[3], tostring(b.name), b.mon.hp, want)
        b.mon.hp = math.max(0, math.min(b.mon.stats.hp, math.floor(want)))
        b.shownHP = b.mon.hp
        b.shownPx = require("src.core.Timing").hpBarPixels(b.mon.hp, math.max(1, b.mon.stats.hp))
      end
      if b and b.mon then b.shownStatus = b.mon.status end
    end
  end
  local function applyFrame(self)
    -- Out of step: the fight replaced a fainted mon while ours still
    -- stands, or answered a prompt we never asked.  Rather than wait for
    -- an action that cannot come, take the replacement through the
    -- engine's own picker (the stub answers it from the frame) and drop
    -- the stray answer.
    local head = self:peekFrame()
    if head and head.k == "replace" then
      log("mirror: turn %d, a replacement arrived with %s still standing; sending it out",
          self.turnCount or 0, tostring(self.player and self.player.name))
      self.phase = "menu"
      self:openReplacementMenu()
      return true
    elseif head and head.k == "choice" then
      self:takeFrame()
      return true
    end
    local f = self:takeIf(ACTIONS)
    if not f then return false end
    self.phase = "menu"
    self:clearTurnFlinches()
    if f.rolls and f.rolls ~= self.mirrorRolls then
      log("mirror: turn %d, %d rolls here against %d in the fight (%s)",
          self.turnCount or 0, self.mirrorRolls, f.rolls, tostring(f.k))
      if Mirror.DEBUG then
        log("mirror:   here  %s", table.concat(self.mirrorTrace, "|"):sub(1, 400))
        log("mirror:   fight %s", tostring(f.trace))
      end
      self.mirrorRolls = f.rolls
    end
    self.mirrorTrace = {}
    if f.sig then
      local mine = Mirror.signature(self)
      if mine ~= f.sig then
        log("mirror: turn %d, the state differs before %s", self.turnCount or 0, tostring(f.k))
        log("mirror:   here  %s", mine)
        log("mirror:   fight %s", f.sig)
      end
    end
    snap(self, f.hp)
    if f.k == "move" then
      local mv = self.player.curMoves[f.slot]
      if mv then
        self.playerMoveListIndex = f.slot
        self:resolveTurn(mv)
      else
        self:resolveTurn({ id = "STRUGGLE", pp = 1, struggle = true })
      end
    elseif f.k == "struggle" then
      self:resolveTurn({ id = "STRUGGLE", pp = 1, struggle = true })
    elseif f.k == "locked" then
      local a = self:lockedAction(self.player) or self:fightLockedAction(self.player)
      if a then self:resolveTurn(a)
      else self:resolveTurn({ id = "STRUGGLE", pp = 1, struggle = true }) end
    elseif f.k == "switch" then
      local mon = me[f.index]
      if mon then self:resolveSwitch(mon) else self.phase = "waitBoth" end
    elseif f.k == "run" then
      self:tryRun()
    elseif f.k == "ball" then
      if game.data.items[f.item] then self:throwBall(f.item) else self.phase = "waitBoth" end
    elseif f.k == "item" then
      local sn = f.snap
      if type(sn) == "table" and self.player and self.player.mon then
        local mon = self.player.mon
        if type(sn.hp) == "number" then
          mon.hp = math.max(0, math.min(mon.stats.hp, math.floor(sn.hp)))
        end
        mon.status = sn.status
        if type(sn.stages) == "table" then
          self.player.stages = self.player.stages or {}
          for _, k in ipairs(STAGES) do
            if type(sn.stages[k]) == "number" then self.player.stages[k] = sn.stages[k] end
          end
        end
      end
      self:itemUsed(f.msgs or {})
    end
    return true
  end

  install(game, s, opts, applyFrame, frozen)
  -- finish is the engine's own exit -- money, the save, battle.ended -- and
  -- none of it is ours.  Leave the way the replica leaves.
  s.finish = function(self) self:mirrorClose(self.result or "ended") end
  return s
end

-- a duel: the engine's tournament observer, fed the two cables' messages
local function openLink(game, start, opts)
  local LinkBattle = require("src.link.LinkBattle")
  local net = { closed = false, inbox = {} }
  function net:update() end
  function net:poll() local m = self.inbox; self.inbox = {}; return m end
  function net:send() end
  function net:close() end
  local hostIsMe = start.host == "me"
  local pg = Mirror.proxyGame(game, { name = start.myName, party = {}, stack = game.stack })
  local s, why = LinkBattle.newSpectator(pg, net, {
    hostParty = hostIsMe and start.me or start.foe,
    guestParty = hostIsMe and start.foe or start.me,
    hostName = hostIsMe and start.myName or start.foeName,
    guestName = hostIsMe and start.foeName or start.myName,
    seed = start.seed,
  })
  if not s then return nil, why end
  s.mirrorNet = net
  local function frozen(self)
    return self.phase == "waitBoth" or self.phase == "menu"
  end
  local function applyFrame(self)
    local f = self:takeIf({ link = true })
    if not f then return false end
    net.inbox[#net.inbox + 1] = { type = "spectate", side = f.side, msg = f.m }
    return true
  end
  install(game, s, opts, applyFrame, frozen)
  -- newSpectator's own finish pops the stack and emits battle.ended; ours
  -- must not announce anything
  s.finish = function(self) self:mirrorClose(self.result or "ended") end
  return s
end

-- ------- a fight nobody is driving (two bots)
--
-- A bot-versus-bot fight used to be one weighted coin flip on the host.
-- Now it is a real BattleState the host runs off screen: `s` was built by
-- BattleState.newTrainer against a proxy game (Mirror.proxyGame) whose
-- party is the first bot's team and whose stack is private, so the fight's
-- menus come and go unseen.  The first bot stands where the player would
-- and picks its moves through `chooser` (the same trainer AI the other
-- side uses, aimed the other way); the engine's own AI drives the trainer
-- side as in any fight against a bot.  Ticked once per host frame at the
-- pace a person would play, so the recorder next door sees a fight that
-- takes as long as a fight takes -- and whoever is watching either bot
-- gets it on their screen exactly as they would a player's.
--
-- opts: { chooser = fn(s) -> move slot or nil, log = fn(fmt, ...) }.
-- Returns sim: { battle, done, result, elapsed, tick(dt), abort() }.
function Mirror.simulate(pg, s, opts)
  opts = opts or {}
  local log = opts.log or function() end
  s.botSim = true
  s.onFinish = nil
  local party = s:playerPartyView()
  -- a fainted lead is replaced by the first standing mon, through the
  -- engine's own send-out closure; every other menu leaves at once
  s.buildScreen = function(self, id, sopts)
    if id == "PartyMenu" and type(sopts) == "table" and sopts.forceSwitch then
      return stub(pg, self, function()
        local mon = firstHealthy(party)
        if mon and (mon.hp or 0) > 0 and sopts.onSwitch then sopts.onSwitch(mon) end
        return true
      end)
    end
    return stub(pg, self, nil)
  end
  -- a bot never takes the SHIFT offer (the style is SET in a match anyway)
  s.sayChoice = function(self, text, onChoose)
    self:say(text)
    self:act(function() if onChoose then onChoose(false) end end)
  end
  s.openItems = function(self) self.phase = "menu" end
  s.openParty = function(self) self.phase = "menu" end
  -- finish is the engine's exit: it pops the stack and pays the player.
  -- Off screen there is nothing to pop and nobody to pay.
  s.finish = function(self)
    self.simDone = true
    self.result = self.result or "run"
  end

  local sim = { battle = s, done = false, result = nil, elapsed = 0, hold = 0 }
  local input = pg.input
  input.fast = false
  pg.stack:push(s)   -- enter(): the intro, and battle.started (botSim set)

  function sim:tick(dt)
    if self.done then return end
    self.elapsed = self.elapsed + dt
    local ok, err = pcall(Mirror.muted, function()
      -- a menu stacked over the battle (the replacement picker) runs first
      local top = pg.stack:top()
      if top and top ~= s then
        if top.update then top:update(dt) end
        return
      end
      if s.phase == "menu" then
        -- the first bot's turn: pick like a trainer, click like a player
        local slot = opts.chooser and opts.chooser(s) or nil
        if not s:chooseMenu("fight") then
          -- the menu is not ours to open (a locked move): the lock plays
          local a = s:menuLockedAction(s.player) or s:lockedAction(s.player)
          if a then s:resolveTurn(a) else s:update(dt) end
          return
        end
        if s.phase == "moveSelect" then
          if not (slot and s.player.curMoves[slot] and s.player.curMoves[slot].pp > 0
                  and s.player.disabledSlot ~= slot) then
            slot = nil
            for i, mv in ipairs(s.player.curMoves) do
              if mv.pp > 0 and s.player.disabledSlot ~= i then slot = i break end
            end
          end
          if slot then
            s:chooseMove(slot)
          else
            s:resolveTurn({ id = "STRUGGLE", pp = 1, struggle = true })
          end
        end
        return
      end
      if s.msgWaiting or s.msgPrompt then
        self.hold = self.hold + dt
        if self.hold >= Mirror.PAGE_SECONDS then
          self.hold = 0
          input.fireA = true
        end
      else
        self.hold = 0
      end
      s:update(dt)
      input.fireA = false
    end)
    if not ok then
      log("bot duel: the fight threw (%s)", tostring(err))
      self.done, self.error = true, err
      return
    end
    if s.simDone then
      self.done, self.result = true, s.result
    end
  end

  function sim:abort()
    self.done = true
  end

  return sim
end

-- start: the decoded `start` frame.  opts: { onClosed = fn(state, why),
-- log = fn(fmt, ...) }.  Returns the state to push, or nil and why.
function Mirror.open(game, start, opts)
  opts = opts or {}
  if type(start) ~= "table" or start.k ~= "start" then return nil, "not a start frame" end
  if start.kind == "link" then return openLink(game, start, opts) end
  return openLocal(game, start, opts)
end

return Mirror
