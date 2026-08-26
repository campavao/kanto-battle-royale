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

-- ------- the launcher can actually offer an update (POK-103)
--
-- "Check for updates" in the launcher walks the INSTALLED mods and skips
-- any without a `github` field outright -- RomImporter:_syncModUpdateInfo
-- does `if m.github and m.github ~= ""` and otherwise clears the row.  This
-- manifest never had one, so the mod was invisible to the updater for its
-- whole life: eleven releases that no player could be offered.
--
-- Manifest.parseGithub is what the loader ran it through, so this asserts
-- the parsed value on the loaded mod rather than the raw JSON.

do
  local gh = run.mod and run.mod.manifest and run.mod.manifest.github
  T.check(gh ~= nil and gh ~= "",
          "the manifest declares a github repo (got " .. tostring(gh) .. ")")
  T.eq(gh, "campavao/kanto-battle-royale", "and it is the mod's own repo")

  -- the parse is strict; a value the launcher would reject must not ship
  local Manifest = require("src.mods.Manifest")
  T.eq(Manifest.parseGithub(gh), gh, "the launcher's own parser accepts it")
  T.check(Manifest.parseGithub(nil) == nil, "absent means no updates")
  T.check(Manifest.parseGithub("") == nil, "and so does empty")
end

-- ------- the START menu rows the mod owns (POK-99 / POK-100)
--
-- Driven through the REAL hook chain, which is the only place the anchor
-- bug is visible: mod.ui.insertBefore APPENDS when its anchor is missing,
-- and the mod's own ROYALE row used to anchor on OPTION -- a row POK-99
-- now removes for the length of a match.  Anchored there it would have
-- landed BELOW QUIT.
--
-- No room is open here, so this is the out-of-match shape: every vanilla
-- row survives and only ROYALE is added.  The in-match shape (OPTION and
-- MODS gone, MAP added) is a live-game check -- inSession() needs a relay.

do
  local Runtime = require("src.mods.Runtime")
  local function labels(items)
    local out = {}
    for i, it in ipairs(items) do out[i] = it.label end
    return table.concat(out, ",")
  end
  local vanilla = { { label = "POKeDEX" }, { label = "POKeMON" },
                    { label = "ITEM" }, { label = "RED" }, { label = "SAVE" },
                    { label = "OPTION" }, { label = "LINK" },
                    { label = "MODS" }, { label = "QUIT" } }
  local game = { save = { party = {} }, data = {} }
  local out = Runtime.call("ui.start_menu.items",
                           function(_, items) return items end, game, vanilla)
  T.check(type(out) == "table", "the start-menu hook returns a table")
  local shown = labels(out)
  T.check(shown:find("ROYALE", 1, true) ~= nil,
          "the mod adds its own row (" .. shown .. ")")
  local royaleAt, quitAt
  for i, it in ipairs(out) do
    if it.label and it.label:find("ROYALE", 1, true) then royaleAt = i end
    if it.label == "QUIT" then quitAt = i end
  end
  T.check(royaleAt and quitAt and royaleAt < quitAt,
          "and puts it above QUIT, not after it (" .. shown .. ")")
  T.check(out[#out].label == "QUIT", "QUIT stays the last row (" .. shown .. ")")
end

-- ------- and the in-match removals, read off the source
--
-- inSession() needs a live relay, so the branch itself cannot run headless.
-- What can be checked is that the branch exists and names the right rows,
-- which is what a future edit would break.

do
  local f = io.open("mods/battle_royale/main.lua", "r")
  if not f then
    io.write("  (skipping the start-menu scan: main.lua not found)\n")
  else
    local src = f:read("*a")
    f:close()
    local hook = src:match('mod%.hooks:wrap%("ui%.start_menu%.items".-\n  end%)')
    T.check(hook ~= nil, "found the start_menu hook")
    if hook then
      for _, row in ipairs({ "LINK", "SAVE", "OPTION", "MODS" }) do
        T.check(hook:find('removeLabel%(out, "' .. row .. '"%)') ~= nil,
                row .. " leaves the menu during a match")
      end
      T.check(hook:find('label = "MAP"', 1, true) ~= nil,
              "the map gets its own row")
      T.check(hook:find('insertBefore%(out, "OPTION"') == nil,
              "nothing anchors on OPTION any more -- it is not there to anchor on")
    end
  end
end

run.release()
T.finish("br_load")
