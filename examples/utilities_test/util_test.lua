-- HD2-Addon: mods/test/util_test
-- HD2-Requires: chef-shared-loader >= 1.0.0
-- Exercises the api 3 utilities in the simulator (and in game as a test mod): every result goes to its own log.
local chef = ...
local M = { version = '1.0.1' }
chef.own_log('util_test')
chef.log('api %s; has units %s, spawn %s, timers %s, shapes %s', tostring(chef.api), tostring(chef.has('units')),
  tostring(chef.has('spawn')), tostring(chef.has('timers')), tostring(chef.has('shapes')))
chef.budget(0.0001)                       -- so the status line warns
local MEDAL, PLAYER, RUNTIME = '773c4184e4bad0df', '4d1c334d294dfa97', '46cab355bd8d4d37'
local w = chef.watch({ [MEDAL] = true, [PLAYER] = true }, 2)
local done_world, spawned, sheet = nil, nil, nil
local every_n = 0
chef.every(1, function() every_n = every_n + 1 end)
chef.after(3, function() chef.log('after(3) ran at %.1f s', chef.time()) end)
local tick = chef.every(0.5, function() error('a timer that always fails') end)
chef.after(20, function() tick.cancel(); chef.log('every(1) ran %d times by %.0f s', every_n, chef.time()) end)
local list = {}
for i = 1, 1000 do list[i] = i end
local sum = 0
chef.spread(list, 100, function(v) sum = sum + v end, function(ok) chef.log('spread done %s, sum %d', tostring(ok), sum) end, { keep = true })
local ok = chef.save_table('state', { runs = 1, name = 'x\n"y"', list = { 1, 2, { deep = true } } })
local back = chef.load_table('state')
chef.log('save_table %s, load_table %s %s', tostring(ok), back and back.name == 'x\n"y"' and 'same' or 'different', back and tostring(back.list[3].deep) or '')
chef.log('bad save: %s', select(2, chef.save_table('state', { f = print })) or 'saved?!')
chef.log('settings: render %s, fullscreen %s, render_settings.shadows %s',
  type(chef.setting('render_settings.render_resolution')) == 'table' and table.concat(chef.setting('render_settings.render_resolution'), 'x') or tostring(chef.setting('render_settings.render_resolution')),
  tostring(chef.setting('fullscreen')), tostring(chef.setting('render_settings.shadows')))
chef.log('key label f9: %s', chef.key_label('f9'))
chef.after_startup(function()
  local parts = {}
  for _, m in ipairs(chef.mods()) do parts[#parts + 1] = m.name .. (m.on and ' on' or ' off') .. ' ' .. m.kind end
  chef.log('mods: %s', table.concat(parts, ', '))
end)
chef.notify('util test running', 3)
function M.update(dt)
  local typed = chef.typed()
  if typed ~= '' then chef.log('typed: %s', typed) end
  if not chef.in_mission() then return end
  local wid = chef.world_id()
  if done_world ~= wid and #w.items > 0 then
    done_world = wid
    chef.log('session: in %s, host %s, players %d', tostring(chef.in_session()), tostring(chef.is_host()), chef.players())
    local near = chef.units_near(0, 0, 0, 1000)
    chef.log('units_near: %d (nearest %s at %.1f m)', #near, near[1] and near[1].kind or '-', near[1] and near[1].d or -1)
    local me
    for _, it in ipairs(w.items) do if it.kind == PLAYER then me = it.unit end end
    local x, y, z = chef.unit_position(me)
    local fx, fy, fz, yaw = chef.unit_rotation(me)
    chef.log('me at %s %s %s, facing %s; kind %s; node head %s', tostring(x), tostring(y), tostring(z), tostring(yaw), tostring(chef.unit_kind(me)), tostring(chef.unit_node(me, 'head')))
    -- the refusals
    local all = chef.call('World.units', chef.world())
    local rt
    for _, u in ipairs(all or {}) do if chef.unit_kind(u) == RUNTIME then rt = u break end end
    chef.log('runtime unit: position %s; call %s', tostring(chef.unit_position(rt)), tostring(select(2, chef.call('Unit.world_position', rt, 1))))
    chef.log('has_camera without a name: %s', tostring(select(2, chef.call('Unit.has_camera', me))))
    chef.log('Http.get: %s', tostring(select(2, chef.call('Http.get', 'http://example.com'))))
    -- spawning and the rest
    local u, err = chef.spawn('beefbeefbeefbeef', 1, 2, 3)
    local nope, why = chef.spawn('0123456789abcdef', 1, 2, 3)
    spawned = u
    chef.log('spawn: %s (%s); not loaded: %s (%s)', tostring(u ~= nil), tostring(err), tostring(nope), tostring(why))
    chef.log('link to head: %s', tostring(chef.link(u, me, 'head')))
    chef.log('particles: %s', tostring(chef.particles('beefbeefbeefbeef', 0, 0, 0)))
    chef.log('lights: %d; color %s', chef.lights(u), tostring(chef.light(u, 1).set_color(255, 120, 40)))
    sheet = chef.sprite_sheet('0123456789abcdef', 4, 2)
  end
  local c = chef.color(40, 120, 255, 200)
  chef.circle(300, 300, 40, c, 900)
  chef.ring(400, 300, 30, 40, c, 900)
  chef.arc(500, 300, 30, 40, 0, 90, c, 900)
  chef.triangle(600, 260, 680, 260, 640, 340, c, 900)
  if sheet then sheet.draw(3, 700, 300, 32, 32, chef.color(255, 255, 255, 255), 900) end
end
function M.shutdown() chef.log('shutdown; spawned unit still kept: %s', tostring(spawned ~= nil)) end
return M
