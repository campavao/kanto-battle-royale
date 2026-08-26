-- Shared plumbing for the two-client PvP regression drivers (POK-64).
--
-- Each driver runs inside its own LOVE instance via POKEPORT_DRIVER and
-- coordinates with the other through plain files in BR_PVP_DIR.  The walk
-- helpers are the gym-smoke recipe, graduated: a one-step BFS over
-- Spawn.walkable, repathed every call, with a stuck-detector that turns a
-- hold that moved nothing into an A tap (dialogs eat walk input).

local U = require("tests.drivers.util")
local Spawn = require("mods.battle_royale.lib.spawn")

local L = {}

function L.ctx(game)
  -- line-buffer stdout: a driver killed by the harness timeout would
  -- otherwise take its whole log down with it
  pcall(function() io.stdout:setvbuf("line") end)
  -- and belt-and-braces: mirror every driver line into a flushed side
  -- file, because a terminated LOVE process can still eat its stdout
  local dir, role = os.getenv("BR_PVP_DIR"), os.getenv("BR_PVP_ROLE")
  if dir and role and not L.plog then
    local f = io.open(dir .. "/" .. role .. ".plog", "a")
    if f then
      L.plog = f
      local baseLog = U.log
      U.log = function(msg)
        baseLog(msg)
        f:write(tostring(msg), "\n")
        f:flush()
      end
    end
  end
  local C = { game = game }
  function C.fail(msg)
    U.log("PVP FAIL: " .. msg)
    love.event.quit(1)
    U.wait(10)
  end
  function C.ow() return game.overworld end
  function C.map()
    local o = C.ow()
    return o and o.map and o.map.id
  end
  function C.x()
    local o = C.ow()
    return o and o.player and o.player.cellX
  end
  function C.y()
    local o = C.ow()
    return o and o.player and o.player.cellY
  end
  function C.busy() return game.stack:top() ~= C.ow() end
  function C.E()
    return game.mods and game.mods.exports and game.mods.exports.battle_royale
  end
  return C
end

-- one BFS step toward a goal cell, repathed from scratch every call
function L.stepToward(C, mapId, gx, gy)
  local game = C.game
  local def = game.data.maps[mapId]
  local sx, sy = C.x(), C.y()
  if not (def and sx and sy) then return false end
  if sx == gx and sy == gy then return true end
  local w, h = def.width * 2, def.height * 2
  local function key(x, y) return y * 4096 + x end
  local prev, q, qi, found = {}, { { x = gx, y = gy } }, 1, false
  prev[key(gx, gy)] = true
  while q[qi] and not found do
    local c = q[qi]
    qi = qi + 1
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local nx, ny = c.x + d[1], c.y + d[2]
      if nx == sx and ny == sy then
        prev[key(nx, ny)] = c
        found = true
        break
      end
      if nx >= 0 and ny >= 0 and nx < w and ny < h
         and not prev[key(nx, ny)]
         and Spawn.walkable(game.data.maps, game.data.tilesets, mapId, nx, ny) then
        prev[key(nx, ny)] = c
        q[#q + 1] = { x = nx, y = ny }
      end
    end
  end
  local nxt = prev[key(sx, sy)]
  if type(nxt) ~= "table" then return false end
  local dir = (nxt.x > sx and "right") or (nxt.x < sx and "left")
    or (nxt.y > sy and "down") or "up"
  U.hold(C.game, dir, 12)
  U.wait(8)
  return true
end

-- walk to a cell; false if the rounds run out before arrival
function L.goTo(C, mapId, gx, gy, rounds)
  for _ = 1, rounds or 300 do
    if C.map() ~= mapId then
      U.hold(C.game, "down", 30)   -- walked into a building; back out
      U.wait(90)
    elseif C.x() == gx and C.y() == gy then
      return true
    else
      local px, py = C.x(), C.y()
      if not L.stepToward(C, mapId, gx, gy) then
        U.tap(C.game, "a")   -- something in the way; talk it down
        U.wait(20)
      elseif C.x() == px and C.y() == py then
        U.tap(C.game, "a")   -- a dialog is eating the walk
        U.wait(10)
      end
    end
  end
  return false
end

-- FLY with the busy-refusal retry (drop dialogs make flyTo a no-op)
-- FLY, with a landing that does not depend on where the drop put us.
--
-- The A-mashing handles POK-49's busy refusal (flyTo declines while the
-- drop dialog is up).  What it cannot handle is a drop onto a map FLY will
-- not leave -- a run that landed the host on ROUTE_19, a water route, spent
-- all ten retries being refused and failed the scenario on staging rather
-- than on anything under test.  So the last resort is a teleport, which
-- works mid-match and is what the other drivers here use to stage a
-- position anyway.  Fly first regardless: it exercises the real path, and
-- the fallback only ever runs where this used to give up.
function L.flyTo(C, town)
  for _ = 1, 10 do
    if C.map() == town then return true end
    for _ = 1, 4 do
      U.tap(C.game, "a")
      U.wait(15)
    end
    pcall(function() C.game.overworld:flyTo(town) end)
    U.wait(450)
  end
  if C.map() == town then return true end
  local def = C.game.data and C.game.data.maps and C.game.data.maps[town]
  local warp = def and def.warps and def.warps[1]
  if warp then
    U.log(("PVP: FLY would not leave %s; teleporting to %s")
          :format(tostring(C.map()), tostring(town)))
    U.teleport(C.game, town, warp.x, warp.y, "down")
    U.wait(60)
  end
  return C.map() == town
end

-- the handshake files: tiny, line-oriented, best-effort
function L.put(dir, name, text)
  local f = io.open(dir .. "/" .. name, "w")
  if f then
    f:write(text or "1")
    f:close()
  end
end

function L.get(dir, name)
  local f = io.open(dir .. "/" .. name, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if s and #s > 0 then return s end
  return nil
end

function L.waitFor(dir, name, ticks)
  for _ = 1, ticks or 3600 do
    local s = L.get(dir, name)
    if s then return s end
    U.wait(10)
  end
  return nil
end

-- a party built for the script, not the ladder: one mon, one move, so
-- mash-A always picks an attack (P.new at high levels can be all status
-- moves -- see the smoke-recipe notes)
function L.armParty(C, species, level, moveId)
  local P = require("src.pokemon.Pokemon")
  local mon = P.new(C.game.data, species, level)
  mon.moves = { { id = moveId, pp = 99 } }
  C.game.save.party = { mon }
end

function L.mashUntil(C, pred, ticks)
  for _ = 1, ticks or 2400 do
    if pred() then return true end
    U.tap(C.game, "a")
    U.wait(15)
  end
  return false
end

function L.waitPhase(C, phase, ticks)
  local E = C.E()
  for _ = 1, ticks or 240 do
    U.wait(30)
    if E.phase() == phase then return true end
  end
  return false
end

return L
