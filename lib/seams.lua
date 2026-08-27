-- The engine seams this mod is built on, and whether this build has them.
--
-- This file replaces `lib/shim.lua` (POK-29), which installed the seams from
-- OUTSIDE on an engine that lacked them — 562 lines of patching engine
-- modules from a mod, which was always a fallback rather than a design: two
-- mods patching one function clobber each other instead of chaining, and
-- there is no version contract to reason about.
--
-- There is one now.  All three RFCs are upstream and shipped:
--
--   RFC 0014  WorldAPI + world.talk + LinkState + Game:startNewGame +
--             CodeEntry            (PR #1746, merged 2026-08-24)
--   RFC 0015  battle.style + catch.nickname
--                                  (PR #1798, merged 2026-08-25)
--   RFC 0018  catch.party_full     (PR #1799, merged 2026-08-25)
--
-- all of them in gen1recomp v0.2.26, which manifest.json now requires.  So
-- the mod no longer installs anything; it only LOOKS, and says so.
--
-- Why look at all, when the manifest already gates the version?  Because a
-- version string is a promise and this is the fact: a fork, a local build,
-- or a release that moved a function leaves the mod running against an
-- engine that does not have what it needs, and one honest line at boot
-- beats a mysterious failure three screens later.

local Seams = {}

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

-- Each seam, and the thing whose presence proves it.  Every one of these is
-- a plain value on a module: either the engine exposes it or it does not.
local function probes()
  local CodeEntry   = tryRequire("src.link.CodeEntry")
  local LinkState   = tryRequire("src.link.LinkState")
  local Game        = tryRequire("src.core.Game")
  local BattleState = tryRequire("src.battle.BattleState")
  return {
    { rfc = "0014", name = "CodeEntry",        have = (CodeEntry   or {}).charAt },
    { rfc = "0014", name = "LinkState",        have = (LinkState   or {}).newFromSession },
    { rfc = "0014", name = "Game:startNewGame", have = (Game       or {}).startNewGame },
    { rfc = "0015", name = "catch.nickname",   have = (BattleState or {}).offerNickname },
    { rfc = "0015", name = "battle.style",     have = (BattleState or {}).battleStyle },
    { rfc = "0018", name = "catch.party_full", have = (BattleState or {}).partyFullDestination },
  }
end

-- What this build has and has not.  `inferred` carries the two seams that
-- cannot be seen directly: world.talk is a Runtime.call in the middle of
-- OverworldState:interact, and the WorldAPI handle's stepNow lives on a
-- class a mod never gets handed.  Neither is a value to test, so both ride
-- on the RFC 0014 trio they shipped with — the same inference lib/shim.lua
-- made, and the same caveat: an engine that took those three without the
-- call site would look complete here and would not be.
function Seams.check()
  local report = { native = {}, missing = {}, inferred = { "world.talk", "WorldAPI handle" } }
  for _, p in ipairs(probes()) do
    local into = p.have ~= nil and report.native or report.missing
    into[#into + 1] = ("%s (RFC %s)"):format(p.name, p.rfc)
  end
  return report
end

function Seams.ok()
  return #Seams.check().missing == 0
end

-- Which engine RELEASE this is, for the room door.  pcall'd through the
-- same tryRequire as every probe above: a missing Version module is
-- "unknown", never a crash.
--
-- Worth knowing what this returns and when.  src/core/Version.lua ships
-- the placeholder "0.0.0-dev" in the working tree and says CI stamps the
-- real X.Y.Z "into the packed game.love only, never the working tree".
-- So two checkouts always agree with each other and never with a released
-- build -- which is exactly what the engine's own handshake does with the
-- same value, and exactly why a local checkout can never link-battle a
-- packed build.  The door reports what it reads; it does not try to be
-- cleverer than the gate it is explaining.
function Seams.engineVersion()
  local Version = tryRequire("src.core.Version")
  local v = Version and Version.engine
  if type(v) ~= "string" or v == "" then return nil end
  return v
end

-- One line for the boot log, so an engine that cannot run this mod says so
-- in a bug report rather than in a stack trace.
function Seams.summary()
  local report = Seams.check()
  if #report.missing == 0 then return "engine has every seam natively" end
  return "MISSING ENGINE SEAMS: " .. table.concat(report.missing, ", ")
       .. " — this build predates gen1recomp v0.2.26"
end

return Seams
