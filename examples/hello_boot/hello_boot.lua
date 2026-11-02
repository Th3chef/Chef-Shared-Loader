-- HD2-Boot: mods/example/hello_boot
-- A boot-style script under Chef Shared Loader: written the way the game's own `boot` script is (global init, update,
-- render and shutdown), but shipped under its own resource name with the line above instead of replacing `boot`.
-- Chef Shared Loader runs it next to everything else, in its own environment, and gives it a `chef` global with the
-- helpers. To port a mod that replaces boot, give it that first line and a new resource name (see docs/MODDING.md).
local frames = 0

function init()
  chef.log('init')
end

function update(dt)
  frames = frames + 1
  if frames == 600 then chef.log('600 frames in; options: %s', tostring(chef.options.mode)) end
end

function render() end

function shutdown()
  chef.log('shutdown after %d frames', frames)
end
