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

T.finish("battle royale shim")
