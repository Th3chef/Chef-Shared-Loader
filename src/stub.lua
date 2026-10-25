-- Chef Shared Loader start-up stub, version 1 --@@LOADER@@
-- The game runs only the `boot` in the highest-numbered patch. This does what the game's own boot does, then starts
-- Chef Shared Loader when it's installed (mods/chef_shared_loader/core_1), so a mod can ship this as its `boot` and
-- every loader mod keeps running whatever the load order. Without the loader it does nothing more than the game's.
-- License: anyone may copy and ship this file unchanged, byte for byte, as their mod's `boot`, free and with no credit
-- needed. A changed copy isn't this stub: it must not carry this stub's name or the marker on the first line.
function init() end
function shutdown() end
function update(dt) end
function render() end
local S, CORE = rawget(_G, 'stingray'), 'mods/chef_shared_loader/core_1'
local A = type(S) == 'table' and S.Application or {}
local ok, build = pcall(function() return A.build() end)
if ok and build ~= 'release' then pcall(require, 'debug') end
local has, there = pcall(function() return A.can_get('lua', CORE) end)
if has and there then
  local started, why = pcall(require, CORE)
  if not started then
    -- one line for the player and me in the game's own folder; nothing in here may stop the game
    pcall(function()
      local line = os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. CORE .. ' did not start: '
        .. (type(why) == 'string' and why:gsub('%c', ' ') or type(why)) .. '\n'
      local f = io.open(os.getenv('APPDATA') .. '\\Arrowhead\\Helldivers2\\chef_loader_stub.txt', 'w')
      pcall(f.write, f, line)
      f:close()
    end)
  end
end
