-- The BATTLE ROYALE screen, reached from the start menu.
--
-- Deliberately thin: it hosts or joins a room, shows the roster while you
-- wait, and lets the host start the match.  Once the match is live this
-- screen only reports -- everything that happens then happens in the
-- overworld.

local Entry = require("mods.battle_royale.lib.entry")

local Menu = {}

local function say(mod, text)
  -- the script runner owns the dialogue box, so status lands in a real
  -- Gen 1 text box rather than a bespoke overlay; refused mid-cutscene,
  -- which is correct
  mod.world:queueScript({ { "show_text", text } })
end

Menu.say = say

function Menu.build(mod, BR)
  return {
    new = function(game)
      local items = {}
      local relay = BR.relay

      if BR.phase == "match" or BR.phase == "over" then
        local alive = BR:aliveCount()
        items[#items + 1] = {
          label = BR.status == "out" and "SPECTATING" or ("ALIVE: " .. alive),
          keepOpen = true, onSelect = function() end,
        }
        items[#items + 1] = {
          label = "LEVEL: " .. tostring(BR:level()),
          keepOpen = true, onSelect = function() end,
        }
        -- where the fog is, and whether you are standing in it
        local ring = BR.ring
        if ring and ring.phase and ring.phase > 1 then
          items[#items + 1] = {
            label = "FOG: " .. tostring((ring.center and ring.center.name)
                                        or "CLOSING"),
            keepOpen = true, onSelect = function() end,
          }
        end
        items[#items + 1] = {
          label = "LEAVE MATCH",
          onSelect = function() BR:teardown("You left the match.") end,
        }
      elseif relay and relay:isOpen() then
        items[#items + 1] = {
          label = BR.solo and "SOLO MATCH" or ("CODE " .. tostring(relay.code)),
          keepOpen = true, onSelect = function() end,
        }
        for _, m in ipairs(relay.members) do
          local tag = (m.id == relay.hostId) and "*" or ""
          items[#items + 1] = { label = "- " .. m.name .. tag,
                                keepOpen = true, onSelect = function() end }
        end
        if relay:isHost() then
          -- an open room is one strangers can QUICK PLAY into without ever
          -- being told the code
          if not BR.solo then
            items[#items + 1] = {
              label = "OPEN: " .. (BR:isOpen() and "YES" or "NO"),
              onSelect = function()
                BR:setOpen(not BR:isOpen())
                mod.ui.push(game, "BattleRoyaleMenu")
              end,
            }
          end
          -- steps up the ladder (0,1,2,3,5,8,...,30) and wraps; the menu
          -- closes on select, so reopening it is what shows the new count
          items[#items + 1] = {
            label = "BOTS: " .. tostring(BR.botCount),
            onSelect = function()
              BR.botCount = BR:nextBotCount()
              mod.ui.push(game, "BattleRoyaleMenu")
            end,
          }
          -- ...and the same thing counted in trainers, which is what you
          -- want when you cannot know how many people turn up
          items[#items + 1] = {
            label = BR.fillTo > 0 and ("FILL TO: " .. BR.fillTo) or "FILL TO: OFF",
            onSelect = function()
              BR:setFill(BR:nextFill())
              mod.ui.push(game, "BattleRoyaleMenu")
            end,
          }
          local countdown = BR:startsIn()
          items[#items + 1] = {
            label = countdown and ("START MATCH (" .. countdown .. ")")
                    or "START MATCH",
            onSelect = function() BR:startMatch() end,
          }
        else
          items[#items + 1] = {
            label = "WAIT FOR HOST",
            keepOpen = true, onSelect = function() end,
          }
        end
        -- how many trainers the drop will actually hold, humans and bots
        if relay:isHost() then
          local bots = BR:botsAtStart()
          items[#items + 1] = {
            label = "TRAINERS: " .. (#relay.members + bots),
            keepOpen = true, onSelect = function() end,
          }
        end
        items[#items + 1] = {
          label = "LEAVE",
          onSelect = function() BR:teardown() end,
        }
      elseif relay and relay.status == "connecting" then
        items[#items + 1] = { label = "CONNECTING...", keepOpen = true,
                              onSelect = function() end }
        items[#items + 1] = { label = "CANCEL",
                              onSelect = function() BR:teardown() end }
      else
        -- first, because it is the one that asks least of a newcomer: no
        -- code from a friend, no server of their own, no decision
        items[#items + 1] = {
          label = "QUICK PLAY",
          onSelect = function()
            local ok, err = BR:quickPlay()
            if not ok then say(mod, err or "Couldn't reach\nthe relay.") end
          end,
        }
        items[#items + 1] = {
          label = "SOLO VS BOTS",
          onSelect = function()
            local ok, err = BR:hostSolo()
            if not ok then say(mod, err or "Couldn't start.") end
          end,
        }
        items[#items + 1] = {
          label = "HOST GAME",
          onSelect = function()
            local ok, err = BR:host()
            if not ok then say(mod, err or "Couldn't host.") end
          end,
        }
        items[#items + 1] = {
          label = "JOIN BY CODE",
          onSelect = function()
            game.stack:push(Entry.new(game, {
              title = "ROOM CODE",
              shape = Entry.CODE,
              onDone = function(code)
                if not code or code == "" then return end
                local ok, err = BR:join(code)
                if not ok then say(mod, err or "Couldn't join.") end
              end,
            }))
          end,
        }
        -- the name every other trainer sees (and the winner banner uses);
        -- the Gen 1 naming grid handles it since names are letters
        items[#items + 1] = {
          label = "NAME: " .. BR:playerName(),
          onSelect = function()
            game.stack:push(mod.ui.NamingScreen.new(game, {
              title = "YOUR NAME?",
              maxLen = 7,
              default = BR:playerName(),
              onDone = function(name)
                if name and name ~= "" then BR:setName(name) end
              end,
            }))
          end,
        }
        -- the relay address is a mod option; this row surfaces it and lets
        -- you point at a different server without editing files
        items[#items + 1] = {
          label = "SERVER...",
          onSelect = function()
            game.stack:push(Entry.new(game, {
              title = "RELAY HOST:PORT",
              shape = Entry.ADDRESS,
              default = BR:relayAddress(),
              onDone = function(addr)
                if addr and addr ~= "" then BR:setRelayAddress(addr) end
              end,
            }))
          end,
        }
      end

      return mod.ui.Menu.new(game, items, { startCloses = true })
    end,
  }
end

return Menu
