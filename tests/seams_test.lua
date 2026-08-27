-- The engine seams are present (POK-29).
--
-- This replaces shim_test.lua, which ran the mod's behaviour against BOTH a
-- seamed engine and a stock one to prove lib/shim.lua installed the same
-- thing from outside.  There is no stock path any more: all three RFCs are
-- upstream and shipped in gen1recomp v0.2.26, manifest.json requires it,
-- and the shim is gone.
--
-- What is left to test is the CONTRACT, and it is worth testing: this is a
-- regression test against the ENGINE rather than against the mod.  If an
-- upstream change renames or drops one of these, the mod would otherwise
-- fail far away from the cause -- at runtime, mid-match -- instead of here.
--
--   luajit mods/battle_royale/tests/seams_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Seams = require("mods.battle_royale.lib.seams")

-- Which engine release this is, for the room door (POK-142).  In a
-- checkout this is always the "0.0.0-dev" placeholder -- src/core/
-- Version.lua says CI stamps the real X.Y.Z into the packed game.love and
-- never into the working tree -- which is exactly why a local checkout can
-- never link-battle a packed build, and exactly what the door reports.
do
  local v = Seams.engineVersion()
  T.check(type(v) == "string" and v ~= "",
          "the engine names a release: " .. tostring(v))
  T.eq(v, require("src.core.Version").engine,
       "and it is the engine's own number, not a copy")
end

local report = Seams.check()

-- the headline, and each miss named so a failure says WHICH
for _, name in ipairs(report.missing) do
  T.check(false, "seam missing from this engine: " .. name)
end
T.eq(#report.missing, 0, "every seam this mod needs is native")
T.check(Seams.ok(), "Seams.ok() agrees")
T.eq(Seams.summary(), "engine has every seam natively", "and the boot line says so")

local want = {
  "CodeEntry (RFC 0014)",
  "LinkState (RFC 0014)",
  "Game:startNewGame (RFC 0014)",
  "catch.nickname (RFC 0015)",
  "battle.style (RFC 0015)",
  "catch.party_full (RFC 0018)",
}
local have = {}
for _, n in ipairs(report.native) do have[n] = true end
for _, n in ipairs(want) do
  T.check(have[n], "native: " .. n)
end
T.eq(#report.native, #want, "and no seam is counted twice")

-- the two that cannot be probed are declared as such rather than quietly
-- assumed -- world.talk is a Runtime.call in the middle of a function, and
-- the WorldAPI handle's stepNow is on a class a mod never gets handed
T.eq(#report.inferred, 2, "world.talk and the WorldAPI handle are inferred, not seen")

-- ...and the probes really read the engine, rather than being typos that
-- happen to be nil-safe on both sides
local BattleState = require("src.battle.BattleState")
T.eq(type(BattleState.battleStyle), "function", "battle.style is a real method")
T.eq(type(BattleState.offerNickname), "function", "catch.nickname is a real method")
T.eq(type(BattleState.partyFullDestination), "function",
     "catch.party_full is a real method")
T.check(require("src.link.CodeEntry").charAt ~= nil, "CodeEntry.charAt is really there")
T.eq(type(require("src.link.LinkState").newFromSession), "function",
     "LinkState.newFromSession is real")
T.eq(type(require("src.core.Game").startNewGame), "function",
     "Game:startNewGame is real")

-- a build that lost one must be REPORTED, not limped past
do
  local fake = { native = {}, missing = { "battle.style (RFC 0015)" }, inferred = {} }
  local realCheck = Seams.check
  Seams.check = function() return fake end
  T.check(not Seams.ok(), "a missing seam is not ok()")
  T.check(Seams.summary():find("MISSING ENGINE SEAMS", 1, true) ~= nil,
          "and the boot line shouts about it")
  T.check(Seams.summary():find("battle.style", 1, true) ~= nil,
          "...naming the one that is gone")
  Seams.check = realCheck
end

T.finish("battle royale seams")
