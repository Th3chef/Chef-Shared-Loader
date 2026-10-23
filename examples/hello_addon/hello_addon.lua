-- HD2-Addon: mods/example/hello_addon
-- A Chef Shared Loader addon, the smallest useful one: it logs once a mission starts and draws a small label in missions.
-- Chef Shared Loader runs this file in its own environment and hands it `chef` (the helpers) as its argument; the file
-- returns a table whose update(dt) is called every frame and shutdown() when the game closes.
local chef = ...
local M = { version = '1.0.0' }

local said_for = nil
local LABEL = (chef.options.label or 'HELLO FROM AN ADDON'):upper()

function M.update(dt)
  if not chef.in_mission() then return end            -- idle outside missions
  if said_for ~= chef.world_id() then
    said_for = chef.world_id()
    chef.log('mission started (world %d)', said_for)
  end
  local w, h = chef.screen()
  local px = math.max(2, math.floor(h / 540 + 0.5))
  local tw = chef.text_width(LABEL, px)
  -- colors live for one frame: make them in the frame that draws
  chef.rect(w / 2 - tw / 2 - 3 * px, h - 30 * px, tw + 6 * px, 11 * px, chef.color(10, 10, 10, 160), 900)
  chef.text(w / 2 - tw / 2, h - 28 * px, LABEL, px, chef.color(255, 230, 90, 255), 910)
end

function M.shutdown() chef.log('bye') end

return M
