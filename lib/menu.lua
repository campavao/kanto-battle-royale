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
        -- A row that changes a setting keeps the menu open and rewrites its
        -- own label, because Menu draws item.label every frame.  Closing and
        -- re-pushing meant every adjustment cost two more button presses to
        -- see, which read as the setting not having taken.
        local function setting(label, onPress)
          local item
          item = { label = label(), keepOpen = true,
                   onSelect = function() onPress() item.label = label() end }
          items[#items + 1] = item
          return item
        end
        local host = relay:isHost()

        -- A solo room has no code worth reading out, no roster to watch fill
        -- and nobody to keep seats for, so it shows the two things that
        -- actually decide the match and nothing else.
        if not BR.solo then
          items[#items + 1] = {
            label = "CODE " .. tostring(relay.code),
            keepOpen = true, onSelect = function() end,
          }
          for _, m in ipairs(relay.members) do
            local tag = (m.id == relay.hostId) and "*" or ""
            items[#items + 1] = { label = "- " .. m.name .. tag,
                                  keepOpen = true, onSelect = function() end }
          end
          if host then
            -- an open room is one strangers can QUICK PLAY into without ever
            -- being told the code
            setting(function() return "OPEN: " .. (BR:isOpen() and "YES" or "NO") end,
                    function() BR:setOpen(not BR:isOpen()) end)
          end
        end

        if host then
          -- steps the ladder 0,1,2,3,5,8,...,30 and wraps
          setting(function() return "BOTS: " .. tostring(BR.botCount) end,
                  function() BR.botCount = BR:nextBotCount() end)
          -- Only meaningful when humans might still arrive: it holds seats
          -- open for them and lets bots take whatever is left.  In a solo
          -- room nobody can arrive, so it would only ever be a second, more
          -- confusing way to say BOTS.
          if not BR.solo then
            setting(function()
                      return BR.fillTo > 0 and ("FILL TO: " .. BR.fillTo)
                             or "FILL TO: OFF"
                    end,
                    function() BR:setFill(BR:nextFill()) end)
            items[#items + 1] = {
              label = "TRAINERS: " .. (#relay.members + BR:botsAtStart()),
              keepOpen = true, onSelect = function() end,
            }
          end
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
