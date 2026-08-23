-- Standalone: luajit mods/battle_royale/tests/br_load_test.lua
--
-- Loads the mod through the REAL headless loader against the fixture
-- dataset (no ROM import needed) and asserts it reaches "loaded" with no
-- errors.  That covers what br_test.lua cannot: the manifest validates, the
-- entry chunk runs, the sub-modules resolve, and every hook name, event and
-- registry it touches actually exists on this build.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

local run = T.sdk.loadMod("mods/battle_royale")

T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.eq(run.mod and run.mod.state, "loaded", "reached the loaded state")
T.eq(run.mod and run.mod.manifest.id, "battle_royale", "manifest id")

-- the network permission is what lets the mod reach src.link legitimately
T.check(run.mod and run.mod.manifest.permissionSet.network,
  "declares the network permission")

-- the exports other mods / a driver depend on
local exports = run.loader.exports.battle_royale
T.check(type(exports.phase) == "function", "exports phase")
T.check(type(exports.aliveCount) == "function", "exports aliveCount")
T.eq(exports.phase(), "off", "reports 'off' before any room")

run.release()
T.finish("br_load")
