-- The shim has to be indistinguishable from the engine seam.
--
-- This runs the SAME assertions in both worlds: on an engine that has the
-- seams natively (where lib/shim.lua stands down and the engine's own call
-- site answers) and on a stock engine (where the shim installs the call site
-- itself).  It is the only way to know the fallback is honest, so it is
-- meant to be run in both trees:
--
--   luajit mods/battle_royale/tests/shim_test.lua
--
-- The header line it prints says which engine it found, so a passing run in
-- the wrong tree cannot be mistaken for coverage of the other one.

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.modkit")
local Shim = require("mods.battle_royale.lib.shim")

-- what the engine looked like BEFORE we touched it
local Game = require("src.core.Game")
local nativeEngine = Game.startNewGame ~= nil

-- On a stock engine the shim wraps BattleState:enter/finish to swap the
-- battle-style OPTION.  Those originals run a whole battle's worth of
-- setup and teardown, so for the fixture-driven checks below they are
-- replaced with counters first -- the shim wraps whatever it finds.
local stubCalls = { enter = 0, finish = 0 }
if not nativeEngine then
  local BS = require("src.battle.BattleState")
  if not BS.battleStyle then
    BS.enter = function() stubCalls.enter = stubCalls.enter + 1 end
    BS.finish = function() stubCalls.finish = stubCalls.finish + 1 end
  end
end

Shim.apply()
io.write(("\n-- engine: %s --\n-- %s --\n\n")
  :format(nativeEngine and "has the seams natively" or "stock (no seams)",
          Shim.summary()))

local OverworldState = require("src.world.OverworldController")

-- ------- the seams the shim promises are present either way

T.check(require("src.core.Game").startNewGame ~= nil,
  "Game:startNewGame is callable")
T.check(require("src.link.LinkState").newFromSession ~= nil,
  "LinkState.newFromSession is callable")
local CodeEntry = require("src.link.CodeEntry")
T.check(CodeEntry.charAt ~= nil, "CodeEntry.charAt is callable")

-- a sized widget, which is what a six-character room code needs
local sized = CodeEntry.new({ length = 6, charset = "ABC" })
T.eq(#sized.chars, 6, "CodeEntry.new honours an explicit length")
T.eq(CodeEntry.text(sized), "AAAAAA", "and an explicit charset")
CodeEntry.up(sized)
T.eq(CodeEntry.text(sized), "BAAAAA", "stepping a character wraps in that charset")
-- ...while the vanilla widget is untouched, which matters because ordinary
-- link play builds one with no options at all
local plain = CodeEntry.new()
T.eq(#plain.chars, CodeEntry.LENGTH, "CodeEntry.new() is still the link widget")
T.eq(#CodeEntry.text(plain), CodeEntry.LENGTH, "and still renders at that length")

-- ------- world.talk behaves the same on both engines

local FIXTURE = {
  ["mods/talk_probe/manifest.json"] = [[{
    "id": "talk_probe",
    "name": "Talk Probe",
    "version": "1.0.0",
    "entry": "main.lua",
    "api": 2
  }]],
  ["mods/talk_probe/main.lua"] = [[
    local mod = ...
    mod.hooks:wrap("world.talk", function(next, ow, target)
      if target and target.claimedByMod then
        mod.exports.claimed = (mod.exports.claimed or 0) + 1
        mod.exports.last = target.id
        return
      end
      return next(ow, target)
    end)
  ]],
}

local function fixtureOverworld(npc)
  local ow
  ow = setmetatable({
    npcs = { npc },
    player = { facing = "up", facingCell = function() return 4, 5 end },
    map = { id = "FIX_ROUTE", isCounterCell = function() return false end },
    talked = {},
  }, { __index = OverworldState })
  ow.talkTo = function(_, target) ow.talked[#ow.talked + 1] = target.id end
  return ow
end

local function objectAt(id, claimed)
  return { id = id, cellX = 4, cellY = 5, targetX = 4, targetY = 5,
           moving = false, claimedByMod = claimed or nil, def = {} }
end

-- with nothing wrapped, the A press must reach the vanilla text path
local vanilla = T.sdk.loadNone({})
local plainOw = fixtureOverworld(objectAt("SIGNPOST_MAN"))
plainOw:interact()
T.eq(#plainOw.talked, 1, "unhooked: the A press reaches talkTo")
T.eq(plainOw.talked[1], "SIGNPOST_MAN", "unhooked: with the object it faced")
vanilla.release()

local run = T.sdk.loadMods({ "mods/talk_probe" }, { fs = T.sdk.memfs(FIXTURE) })
T.eq(#run.errors, 0, "the probe loads clean (" .. tostring(run.errors[1]) .. ")")

local owned = fixtureOverworld(objectAt("GHOST_PLAYER", true))
owned:interact()
local out = run.loader.exports.talk_probe or {}
T.eq(out.claimed, 1, "a mod that owns the object is offered the press ONCE")
T.eq(out.last, "GHOST_PLAYER", "and told which object")
T.eq(#owned.talked, 0, "and the vanilla text path is skipped")

-- The once matters more than it looks.  The shim raises the hook and then
-- hands the press back to the untouched original when nobody claims it -- so
-- on an engine that ALSO has the call site, a mistake here means the hook
-- fires twice for one press.
local other = fixtureOverworld(objectAt("NURSE_JOY"))
other:interact()
T.eq(out.claimed, 1, "an object the mod ignores raises no extra claim")
T.eq(#other.talked, 1, "and still reaches talkTo")
T.eq(other.talked[1], "NURSE_JOY", "unchanged")

local walking = fixtureOverworld(objectAt("WALKER", true))
walking.npcs[1].moving = true
walking:interact()
T.eq(out.claimed, 1, "an object mid-step is not talkable, on either engine")
T.eq(#walking.talked, 0, "and reaches no talk path at all")

run.release()

-- ------- the two battle-rule hooks behave the same on both engines
--
-- The engine's seam is a method (BattleState:battleStyle / :offerNickname);
-- the stock fallback is a patch on askNicknameUI plus an OPTION swap around
-- each battle.  Same question to both: what does the player actually see?

local BattleState = require("src.battle.BattleState")
local TextBox = require("src.render.TextBox")

local RULES = {
  ["mods/rules_probe/manifest.json"] = [[{
    "id": "rules_probe",
    "name": "Rules Probe",
    "version": "1.0.0",
    "entry": "main.lua",
    "api": 2
  }]],
  ["mods/rules_probe/main.lua"] = [[
    local mod = ...
    mod.exports.style = "set"
    mod.exports.nickname = false
    mod.hooks:wrap("battle.style", function(next, battle)
      mod.exports.styleAsked = (mod.exports.styleAsked or 0) + 1
      if mod.exports.style ~= nil then return mod.exports.style end
      return next(battle)
    end)
    mod.hooks:wrap("catch.nickname", function(next, mon, ctx)
      mod.exports.nameAsked = (mod.exports.nameAsked or 0) + 1
      mod.exports.nameFor = ctx and ctx.name
      if mod.exports.nickname ~= nil then return mod.exports.nickname end
      return next(mon, ctx)
    end)
    mod.hooks:wrap("catch.party_full", function(next, ctx)
      mod.exports.fullAsked = (mod.exports.fullAsked or 0) + 1
      mod.exports.fullMon = ctx and ctx.mon
      if mod.exports.fullAnswer ~= nil then return mod.exports.fullAnswer end
      return next(ctx)
    end)
  ]],
}

local function fixtureBattle(style)
  local data = { pokemon = {}, text = {} }
  return setmetatable({
    game = { save = { options = { battleStyle = style or "shift" } },
             stack = { push = function() end }, data = data },
    data = data,
    queue = {}, nextInsert = 0,
  }, { __index = BattleState })
end

-- the catch flow as the engine runs it: the prompt is queued, then the queue
-- pops it.  Either engine ends up with a prompt on screen or not.
local function catchFlow(battle, mon)
  if BattleState.offerNickname then
    battle:offerNickname(mon, "RATTATA")
  else
    battle:uiNext(function() return battle:askNicknameUI(mon, "RATTATA") end)
  end
  local prompt = false
  for _, item in ipairs(battle.queue) do
    if item.ui then
      local state = item.ui()
      -- the real prompt is a yes/no box; the shim's stand-in closes itself
      if getmetatable(state) == TextBox and state.choice then prompt = true end
    end
  end
  return prompt
end

-- the style the engine will use when the foe's Pokemon faints.  The seam
-- and the shim both answer through BattleState:battleStyle(); on a stock
-- engine the shim then has to make the inline OPTION read agree, which the
-- stock-only block further down exercises.
local function styleInUse(battle) return battle:battleStyle() end

local quiet = T.sdk.loadNone({})
T.eq(catchFlow(fixtureBattle(), { species = "RATTATA" }), true,
  "unhooked: a catch asks for a nickname")
local b = fixtureBattle("shift")
T.eq(styleInUse(b), "shift", "unhooked: the OPTION row decides the style")
T.eq(b.game.save.options.battleStyle, "shift", "and is left as it was")
T.eq(styleInUse(fixtureBattle("set")), "set", "unhooked: SET when the row says SET")
quiet.release()

local rules = T.sdk.loadMods({ "mods/rules_probe" }, { fs = T.sdk.memfs(RULES) })
T.eq(#rules.errors, 0, "the rules probe loads clean (" .. tostring(rules.errors[1]) .. ")")
local probe = rules.loader.exports.rules_probe

local mon = { species = "RATTATA" }
T.eq(catchFlow(fixtureBattle(), mon), false, "false: no prompt on a catch")
T.eq(mon.nickname, nil, "and the species name is kept")
T.eq(probe.nameAsked, 1, "the hook was asked once for that catch")
T.eq(probe.nameFor, "RATTATA", "and told the display name")

probe.nickname = "SPIKE"
local named = { species = "RATTATA" }
T.eq(catchFlow(fixtureBattle(), named), false, "a string: no prompt either")
T.eq(named.nickname, "SPIKE", "and it is the nickname")

probe.nickname = "TOOLONGFORTHEGRID"
local clipped = { species = "RATTATA" }
catchFlow(fixtureBattle(), clipped)
T.eq(clipped.nickname, "TOOLONGFOR", "a long string is clipped to the grid's ten")

probe.nickname = nil
local asked = { species = "RATTATA" }
T.eq(catchFlow(fixtureBattle(), asked), true, "falling through asks as usual")

local forced = fixtureBattle("shift")
T.eq(styleInUse(forced), "set", "\"set\" wins over a SHIFT row")
T.eq(forced.game.save.options.battleStyle, "shift",
  "without the row itself being written")
probe.style = "shift"
T.eq(styleInUse(fixtureBattle("set")), "shift", "\"shift\" wins over a SET row")
probe.style = "banana"
T.eq(styleInUse(fixtureBattle("set")), "set",
  "an answer that is neither falls back to the row")
probe.style = nil
T.eq(styleInUse(fixtureBattle("shift")), "shift", "falling through reads the row")

-- Stock only: the engine's inline read cannot be hooked, so the shim swaps
-- the OPTION value for the battle's duration.  enter/finish are the real
-- methods wrapped by the shim; the originals are far too heavy to drive on
-- a fixture, so they were stubbed above BEFORE Shim.apply() saw them.
if not nativeEngine then
  probe.style = "set"
  local one = fixtureBattle("shift")
  one:enter()
  T.eq(one.game.save.options.battleStyle, "set",
    "stock: the row reads SET while the battle runs")
  -- a second battle before the first finishes (a dead one never does) must
  -- not learn "set" as the player's choice
  local two = fixtureBattle("set")
  two.game = one.game
  two:enter()
  one:finish()
  T.eq(one.game.save.options.battleStyle, "shift",
    "stock: the row is back to the player's choice once a battle finishes")
  two:finish()
  T.eq(one.game.save.options.battleStyle, "shift",
    "stock: a second finish does not restore a stale baseline")
  T.eq(stubCalls.enter, 2, "stock: the real enter still ran for each battle")
  T.eq(stubCalls.finish, 2, "stock: and the real finish")
end

-- ------- catch.party_full behaves the same on both engines
--
-- The engine's seam is BattleState:partyFullDestination(), asked from the
-- middle of storeCaughtMon; the stock fallback wraps Boxes.deposit so a
-- claim shows as a refused deposit.  Same question to both: does a caught
-- mon reach a box once a mod owns the choice?

local Boxes = require("src.pokemon.Boxes")

local function fullSave()
  local party = {}
  for i = 1, 6 do party[i] = { species = "RATTATA", level = 5 } end
  return { party = party, options = { battleStyle = "shift" } }
end

if BattleState.partyFullDestination then
  probe.fullAnswer = true
  T.eq(fixtureBattle():partyFullDestination({ species = "ABRA" }), "mod",
    "seam: a claim answers \"mod\"")
  T.eq(probe.fullAsked, 1, "the hook was asked once for that catch")
  probe.fullAnswer = false
  T.eq(fixtureBattle():partyFullDestination({ species = "ABRA" }), "box",
    "seam: a decline answers \"box\"")
  probe.fullAnswer = nil
  T.eq(fixtureBattle():partyFullDestination({ species = "ABRA" }), "box",
    "seam: falling through answers \"box\"")
  T.eq(Boxes.__brPartyFullShim, nil, "the shim left Boxes.deposit alone")
  probe.fullAnswer = true
  T.eq(Boxes.deposit(fullSave(), { species = "ABRA" }), 1,
    "seam: deposit itself still deposits -- the call site decides, not the box")
  T.eq(probe.fullAsked, 3, "so the box code never asked the hook")
  probe.fullAnswer = nil
end

-- Stock only: there is no method to ask, so the shim's Boxes.deposit wrap
-- IS the call site, and custody shows as a refused deposit.
if not nativeEngine then
  T.eq(Boxes.__brPartyFullShim, true, "stock: the deposit wrap is installed")
  probe.fullAnswer = true
  local save = fullSave()
  local caught = { species = "ABRA" }
  T.eq(Boxes.deposit(save, caught), nil, "stock: a claim refuses the deposit")
  T.eq(#Boxes.active(save), 0, "and the box stays empty")
  T.eq(probe.fullMon, caught, "and the hook was handed the refused mon")
  probe.fullAnswer = nil
  T.eq(Boxes.deposit(save, caught), 1, "stock: falling through deposits")
  T.eq(#Boxes.active(save), 1, "into the box, as it always did")
end

rules.release()

T.finish("battle royale shim")
