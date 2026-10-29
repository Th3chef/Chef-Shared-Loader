-- A simulated Helldivers 2 session for trying a Chef Shared Loader mod without the game (Lua 5.1).
-- tools/modsim/modsim.py runs it from a folder laid out like the game's (data/9ba626afa44a3aa3.patch_N), with
-- APPDATA pointing at a folder of its own. The game's way in is kept: the `boot` in the highest patch runs (the
-- loader's start-up stub), and its require() finds the loader's core among the patches' Lua resources.
--
-- The session: the title screen from 0 s, the ship from TITLE_END, a mission from SHIP_END to the end (SIMSECS).
-- SCENARIO = 'next_mission': halfway through the mission a new mission world replaces it, and every unit of the old
-- one is gone. Input from modsim.py: PRESS = { { key, s } }, HOLD = { { key, from, to } }, CLICK = { { button, s } },
-- JOIN = s (a second player starts joining then and is in 3 s later).
--
-- I model what the engine does where a mod is concerned, and end the run where the game would crash:
-- - asking a unit of a world that's gone anything, or a destroyed unit where it is;
-- - asking a runtime-built unit (#ID[46cab355bd8d4d37]) where it is or how it's turned;
-- - Unit.has_camera without a camera name;
-- - a text at a NaN or infinite position or size.
-- Engine values live one frame: a Color drawn in a later frame than it was made in is counted and reported.
local SCENARIO, SIMSECS = SCENARIO or 'normal', SIMSECS or 120
local TITLE_END, SHIP_END = 10, 40
local SWAP_AT = SHIP_END + (SIMSECS - SHIP_END) / 2
local PICKUP_AT = SHIP_END + 20
local W, H = 2560, 1440
PRESS, HOLD, CLICK = PRESS or {}, HOLD or {}, CLICK or {}

local t, frame = 0, 0
local stats = { rects = 0, frame_rects = 0, most_rects = 0, triangles = 0, bitmaps = 0, texts_made = 0, texts_changed = 0,
                stale = 0, spawned = 0, destroyed = 0, linked = 0, particles = 0, lights = 0, lines = 0, rays = 0 }
local seen_texts, seen_n = {}, 0

local function crash(what)
  print('GAME CRASH at ' .. string.format('%.2f', t) .. ' s: ' .. what)
  io.stdout:flush()
  os.exit(3)
end

-- ---------------------------------------------------------------- worlds and units
local function v3(x, y, z) return { x = x, y = y, z = z } end
local M4 = { __tostring = function(m) return string.format('Matrix4x4(%g, %g, %g)', m.t.x, m.t.y, m.t.z) end }
local function m4(x, y, z, tr) return setmetatable({ m4 = true, x = x, y = y, z = z, t = tr }, M4) end
local function unit(kind, x, y, z, extra)
  local u = { name = '#ID[' .. kind .. ']', kind = kind, pos = v3(x, y, z), alive = true }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
local CAMERA, HELLDIVER, MEDAL, RUNTIME = '465f4895f3dc98d1', '4d1c334d294dfa97', '773c4184e4bad0df', '46cab355bd8d4d37'
-- filler units of 40 kinds of my own ('f111000000000000' to 'f111000000000039')
local function filler(list, n, z)
  for i = 1, n do list[#list + 1] = unit(string.format('f1110000000000%02d', i % 40), i % 500, -(i % 400), z) end
end
local function make_mission()
  local m = { t = 0, levels = 600 }
  m.units = { unit(CAMERA, 0, 0, 10, { cam = true }),
              unit(HELLDIVER, 0, 1, 9, { nodes = { head = 2 }, lights = 1 }),
              unit(RUNTIME, 5, 5, 5, { runtime = true }) }
  for i = 1, 8 do m.units[#m.units + 1] = unit(MEDAL, -60 + i * 15, 30 + (i % 3) * 4, 5) end
  filler(m.units, 2000, 30)
  return m
end
local title = { t = 0, levels = 0, units = { unit(CAMERA, 0, 0, 0, { cam = true }) } }
local ship = { t = 0, levels = 1, units = { unit(CAMERA, 0, 12, 22, { cam = true }),
                                            unit(HELLDIVER, 0, 13, 21, { nodes = { head = 2 }, lights = 1 }) } }
filler(ship.units, 1500, 1)
local mission, next_mission = make_mission(), nil
local overlay = { t = 0, levels = 0, units = {} }          -- the UI world: the game's HUD and menus, and chef.TOP
local function main()
  if next_mission then return next_mission end
  if t < TITLE_END then return title elseif t < SHIP_END then return ship end
  return mission
end
-- units the game has loaded and can spawn: every kind in the world, and beefbeefbeefbeef (a stand-in for a unit your
-- own patch ships)
local function loaded(hex)
  if hex == 'beefbeefbeefbeef' then return true end
  for _, u in ipairs(main().units) do if u.kind == hex then return true end end
  return false
end
local function live(u)
  if type(u) ~= 'table' or not u.pos then error('not a unit') end
  if u.dead_world then crash('a unit of a world that is gone was asked something (keep no units across worlds)') end
end

-- ---------------------------------------------------------------- input
local KEYS = { 'escape', 'enter', 'numpad enter', 'backspace', 'delete', 'tab', 'space', 'up', 'down', 'left', 'right',
               'page up', 'page down', 'home', 'end', 'insert', 'left ctrl', 'right ctrl', 'left shift', 'right shift',
               'left alt', 'right alt', 'numpad +', 'numpad -', '/', '.', ',', '-' }
for i = 1, 12 do KEYS[#KEYS + 1] = 'f' .. i end
for c in ('abcdefghijklmnopqrstuvwxyz0123456789'):gmatch('.') do KEYS[#KEYS + 1] = c end
local KEY_INDEX = {}
for i, k in ipairs(KEYS) do KEY_INDEX[k] = i - 1 end
local function at_frame(s) return math.floor(s * 60 + 0.5) end
local function key_state(name)            -- down, pressed, released this frame
  local down, pressed, released = false, false, false
  for _, p in ipairs(PRESS) do
    if p[1] == name then
      local f = at_frame(p[2])
      if frame == f then down, pressed = true, true elseif frame == f + 1 then released = true end
    end
  end
  for _, hd in ipairs(HOLD) do
    if hd[1] == name then
      local a, b = at_frame(hd[2]), at_frame(hd[3])
      if frame >= a and frame < b then down = true; if frame == a then pressed = true end
      elseif frame == b then released = true end
    end
  end
  return down, pressed, released
end
local BUTTONS = { [0] = 'left', 'right', 'middle' }
local function button_state(i)
  local name = BUTTONS[i]
  for _, c in ipairs(CLICK) do
    if c[1] == name then
      local f = at_frame(c[2])
      if frame == f then return true, true, false elseif frame == f + 1 then return false, false, true end
    end
  end
  return false, false, false
end
local dead_zone = { 0, 0 }                -- the mouse's delta axis: mode, size (chef.hold_mouse sets a big one)

-- ---------------------------------------------------------------- drawing
local guis = {}
local fonts = { ['content/fonts/fs_sinclair_medium_runtime'] = true, ['content/fonts/fallback'] = true }
local function drawn_world(w) return w == main() or w == overlay end
local function color_check(c)
  if type(c) ~= 'table' or not c.made then error('not a color') end
  if c.made ~= frame then stats.stale = stats.stale + 1 end
end
local function bad(v) return type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge end
local function gui_check(g, what)
  if type(g) ~= 'table' or g.dead or not drawn_world(g.world) then error(what .. ' on a GUI that is gone') end
end
local function note_text(s)
  if not seen_texts[s] then seen_n = seen_n + 1; seen_texts[s] = seen_n end
end

stingray = {
  Application = {
    main_world = main,
    worlds = function() return { main(), overlay } end,
    back_buffer_size = function() return W, H end,
    build = function() return 'release' end,
    can_get = function(kind, id)
      if kind == 'unit' then return type(id) == 'table' and id.hex ~= nil and loaded(id.hex) end
      if kind == 'runtime_font' then return id == 'content/fonts/fs_sinclair_medium_runtime' or id == 'content/fonts/fallback' end
      return kind == 'material' or kind == 'texture'
    end },
  World = {
    num_units = function(w) return #w.units end,
    num_levels = function(w) return w.levels end,
    time = function(w) return w.t end,
    units = function(w) local r = {} for _, u in ipairs(w.units) do if u.alive then r[#r + 1] = u end end return r end,
    create_screen_gui = function(w, kind, a, b)
      local g = { world = w, texts = {}, n = 0, retained = kind == 'scale' }
      if kind == 'scale' and not (a == 1 and b == 1) then error('scale GUIs take 1, 1') end
      guis[#guis + 1] = g
      return g
    end,
    destroy_gui = function(w, g) if g.world ~= w then error('not this world\'s GUI') end g.dead = true end,
    create_line_object = function(w) return { world = w } end,
    spawn_unit = function(w, id, p)
      if not (type(id) == 'table' and id.hex and p and p.x) then error('spawn_unit takes an id and a position') end
      local u = unit(id.hex, p.x, p.y, p.z, { lights = 1 }); w.units[#w.units + 1] = u; stats.spawned = stats.spawned + 1
      return u
    end,
    destroy_unit = function(w, u)
      live(u)
      if not u.alive then crash('World.destroy_unit on a unit that was destroyed already') end
      u.alive = false
      for i, x in ipairs(w.units) do if x == u then table.remove(w.units, i) break end end
      stats.destroyed = stats.destroyed + 1
    end,
    link_unit = function(w, c, cn, p, pn)
      live(c) live(p)
      if type(cn) ~= 'number' or type(pn) ~= 'number' then error('link_unit takes node indexes') end
      c.linked = p; stats.linked = stats.linked + 1
    end,
    unlink_unit = function(w, c) live(c) c.linked = nil end,
    create_particles = function(w, id, p)
      if not (type(id) == 'table' and id.hex and p) then error('create_particles takes an id and a position') end
      stats.particles = stats.particles + 1; w.parts = w.parts or {}; w.parts[stats.particles] = true
      return stats.particles
    end,
    destroy_particles = function(w, id)
      if not (w.parts and w.parts[id]) then crash('destroying particles that are gone') end
      w.parts[id] = nil
    end,
    are_particles_playing = function(w, id) return w.parts ~= nil and w.parts[id] == true end },
  Unit = {
    debug_name = function(u) live(u) return u.name end,
    alive = function(u) live(u) return u.alive end,
    num_cameras = function(u) live(u) return u.cam and 1 or 0 end,
    camera = function(u) live(u) return { u = u } end,
    has_camera = function(u, name) live(u) if name == nil then crash('Unit.has_camera without a camera name') end return false end,
    world_position = function(u, i)
      live(u)
      if not u.alive then crash('the position of a destroyed unit') end
      if u.runtime then crash('the position of a runtime-built unit (46cab355bd8d4d37)') end
      return u.pos
    end,
    world_rotation = function(u, i)
      live(u)
      if u.runtime then crash('the rotation of a runtime-built unit (46cab355bd8d4d37)') end
      return { q = 1 }
    end,
    has_node = function(u, n) live(u) return u.nodes ~= nil and u.nodes[n] ~= nil end,
    node = function(u, n) live(u) if not (u.nodes and u.nodes[n]) then error('no node ' .. tostring(n)) end return u.nodes[n] end,
    -- its box: 0.4 x 0.4 x 1 m half sizes, its middle 1 m above its position, facing +y
    box = function(u)
      live(u)
      if u.runtime then crash('the box of a runtime-built unit (46cab355bd8d4d37)') end
      return m4(v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1), v3(u.pos.x, u.pos.y, u.pos.z + 1)), v3(0.4, 0.4, 1)
    end,
    num_lights = function(u) live(u) return u.lights or 0 end,
    light = function(u, i) live(u) if i ~= 1 or not u.lights then error('no light ' .. tostring(i)) end return { u = u } end },
  Camera = {
    world_position = function(c) return c.u.pos end,
    world_rotation = function() return { q = 1 } end,
    vertical_fov = function() return 0.9 end,
    projection_type = function() return 1 end,
    near_range = function() return 0.1 end,
    far_range = function() return 1000 end,
    -- a perspective projection through the camera (looking along 0.6, 0.8, 0), in screen pixels
    world_to_screen = function(c, v)
      local cp, fx, fy = c.u.pos, 0.6, 0.8
      local dx, dy, dz = v.x - cp.x, v.y - cp.y, v.z - cp.z
      local depth = dx * fx + dy * fy
      if depth <= 0.001 then return v3(-1e6, -1e6, 0) end
      local focal = H / 2 / math.tan(0.9 / 2)
      return v3(W / 2 + (dx * fy - dy * fx) / depth * focal, H / 2 + dz / depth * focal, 0.5)
    end },
  Quaternion = { forward = function() return v3(0.6, 0.8, 0) end },
  Vector3 = setmetatable({ to_elements = function(v) return v.x, v.y, v.z end },
                         { __call = function(_, x, y, z) return v3(x, y, z) end }),
  Vector2 = setmetatable({}, { __call = function(_, x, y) return v3(x, y, 0) end }),
  -- a pose: its axes and translation, with the engine's own text for its kind
  Matrix4x4 = { identity = function() return m4(v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1), v3(0, 0, 0)) end,
                from_axes = function(x, y, z, tr)
                  if not (x and y and z and tr) then error('Matrix4x4.from_axes takes three axes and a translation') end
                  return m4(x, y, z, tr)
                end },
  -- a real ray against an oriented box (chef.ray_box): the distance along dir (in lengths of dir) to where it goes in,
  -- 0 when it starts inside, -1 for a miss
  Math = { ray_box_intersection = function(from, dir, pose, ext)
    local function vec(v) return type(v) == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number' end
    if not (vec(from) and vec(dir) and vec(ext) and type(pose) == 'table' and pose.m4 and vec(pose.x) and vec(pose.t)) then
      crash('Math.ray_box_intersection takes three Vector3s and a Matrix4x4 (from, dir, pose, half sizes)')
    end
    stats.rays = stats.rays + 1
    local lo, hi = -math.huge, math.huge
    local px, py, pz = from.x - pose.t.x, from.y - pose.t.y, from.z - pose.t.z
    for _, a in ipairs({ { pose.x, ext.x }, { pose.y, ext.y }, { pose.z, ext.z } }) do
      local ax, h = a[1], a[2]
      local o = px * ax.x + py * ax.y + pz * ax.z
      local d = dir.x * ax.x + dir.y * ax.y + dir.z * ax.z
      if math.abs(d) < 1e-12 then
        if o < -h or o > h then return -1 end
      else
        local t1, t2 = (-h - o) / d, (h - o) / d
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > lo then lo = t1 end
        if t2 < hi then hi = t2 end
        if lo > hi then return -1 end
      end
    end
    if hi < 0 then return -1 end
    return math.max(lo, 0)
  end },
  Color = function(a, r, g, b)
    if not (a and r and g and b) then error('Color takes a, r, g, b') end
    return { a, r, g, b, made = frame }
  end,
  IdString64 = { from_hex = function(s) if type(s) ~= 'string' or #s ~= 16 then error('ids are 16 hex digits') end return { hex = s } end },
  Gui = {
    rect = function(g, p, s, c)
      gui_check(g, 'Gui.rect'); color_check(c)
      stats.rects = stats.rects + 1; stats.frame_rects = stats.frame_rects + 1
    end,
    triangle = function(g, a, b, c, layer, col)
      gui_check(g, 'Gui.triangle'); color_check(col)
      if not (a and b and c and type(layer) == 'number') then error('Gui.triangle takes three points and a layer') end
      stats.triangles = stats.triangles + 1
    end,
    material = function(g, id) g.mat = g.mat or { gui = g } return g.mat end,
    bitmap = function(g, id, p, s, c) gui_check(g, 'Gui.bitmap'); color_check(c) stats.bitmaps = stats.bitmaps + 1 end,
    bitmap_uv = function(g, id, a, b, p, s, c) gui_check(g, 'Gui.bitmap_uv'); color_check(c) stats.bitmaps = stats.bitmaps + 1 end,
    -- text in the game's font: retained, made once and then changed in place
    text = function(g, str, font, size, mat, p, c)
      gui_check(g, 'Gui.text'); color_check(c)
      if not g.retained then error('Gui.text on a GUI that keeps no texts') end
      if bad(p.x) or bad(p.y) or bad(p.z) or bad(size) then crash('a text at a NaN or infinite position or size') end
      if not (fonts[font] or (type(font) == 'table' and font.hex == '9ad413a8fea59728')) then error('a font without its material') end
      g.n = g.n + 1; g.texts[g.n] = str; note_text(str); stats.texts_made = stats.texts_made + 1
      return g.n
    end,
    update_text = function(g, id, str, font, size, mat, p, c)
      gui_check(g, 'Gui.update_text'); color_check(c)
      if bad(p.x) or bad(p.y) or bad(p.z) or bad(size) then crash('a text at a NaN or infinite position or size') end
      if not g.texts[id] then error('Gui.update_text with an id this GUI did not make') end
      g.texts[id] = str; note_text(str); stats.texts_changed = stats.texts_changed + 1
    end,
    destroy_text = function(g, id)
      gui_check(g, 'Gui.destroy_text')
      if not g.texts[id] then error('Gui.destroy_text with an id this GUI did not make') end
      g.texts[id] = nil
    end,
    -- advances about those of the game's font: narrow I and space, wide M and W
    text_extents = function(g, str, font, size)
      gui_check(g, 'Gui.text_extents')
      local adv, wide = 0, { I = 0.28, M = 0.82, W = 0.9, [' '] = 0.28, ['.'] = 0.25 }
      for ch in str:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        adv = adv + (#ch > 1 and 0.9 or wide[ch] or (ch:match('%d') and 0.56) or 0.62)
      end
      return v3(0, 0, 0), v3(adv * size, 0.72 * size, 0), v3(adv * size, 0, 0)
    end },
  Material = { set_texture = function(m, slot, tex)
    if not (m.gui and tex and tex.hex) then error('Material.set_texture takes a material, a slot and a texture') end
    m.gui.tex = tex.hex
  end },
  LineObject = { reset = function() end, add_line = function() stats.lines = stats.lines + 1 end, dispatch = function() end },
  Light = { set_color = function(l, v) stats.lights = stats.lights + 1 end, set_intensity = function() end, set_enabled = function() end,
            set_falloff_start = function() end, set_falloff_end = function() end, set_casts_shadows = function() end },
  Keyboard = {
    num_buttons = function() return #KEYS end,
    button_index = function(name) return KEY_INDEX[name] end,
    button_name = function(i) return KEYS[i + 1] end,
    button_locale_name = function(i) local n = KEYS[(tonumber(i) or -1) + 1]; return n and n:upper() end,
    button = function(i) local d = key_state(KEYS[i + 1]) return d and 1 or 0 end,
    pressed = function(i) local _, p = key_state(KEYS[i + 1]) return p end,
    released = function(i) local _, _, r = key_state(KEYS[i + 1]) return r end,
    any_pressed = function() for _, k in ipairs(KEYS) do local _, p = key_state(k) if p then return true end end return false end,
    keystrokes = function() return {} end },
  Mouse = {
    num_buttons = function() return 3 end,
    button_index = function(name) for i = 0, 2 do if BUTTONS[i] == name then return i end end end,
    button_name = function(i) return BUTTONS[i] end,
    button = function(i) local d = button_state(i) return d and 1 or 0 end,
    pressed = function(i) local _, p = button_state(i) return p end,
    released = function(i) local _, _, r = button_state(i) return r end,
    num_axes = function() return 3 end,
    axis_index = function(name) return ({ cursor = 0, mouse = 1, wheel = 2 })[name] end,
    axis_name = function(i) return ({ [0] = 'cursor', 'mouse', 'wheel' })[i] end,
    -- the cursor rests mid-screen; the mouse doesn't move and the wheel doesn't turn
    axis = function(i) if i == 0 then return v3(W / 2, H / 2, 0) end return v3(0, 0, 0) end,
    dead_zone = function(i) return dead_zone[1], dead_zone[2] end,
    set_dead_zone = function(i, mode, size) dead_zone[1], dead_zone[2] = mode, size end },
  Window = { get_main_window = function() return { window = 1 } end, show_cursor = function() return false end,
             mouse_focus = function() return true end, has_focus = function() return true end },
  -- an online session from the ship on: this game hosts it alone (JOIN: a second player comes in)
  Network = { peer_id = function() return 'a1' end, game_session = function() return t >= TITLE_END and { session = 1 } or nil end },
  GameSession = {
    in_session = function() return true end,
    game_session_host = function() return 'a1' end,
    peers = function() if JOIN and t >= JOIN then return { 'a1', 'b2' } end return { 'a1' } end,
    synchronizing_peers = function() if JOIN and t >= JOIN and t < JOIN + 3 then return { 'b2' } end return {} end },
}
-- the engine's tables are globals too, as in the game (Unit, World, Gui ...)
for k, v in pairs(stingray) do _G[k] = v end

-- ---------------------------------------------------------------- the deployed patches' Lua resources
-- As the game resolves them: require(name) finds the Lua resource named name in the highest patch that has one, and
-- Application.can_get('lua', name) says whether one is there.
local BOOT
do
  local function x16(a, b)
    local r, p = 0, 1
    for _ = 1, 16 do local x, y = a % 2, b % 2; if x ~= y then r = r + p end a, b, p = (a - x) / 2, (b - y) / 2, p * 2 end
    return r
  end
  local function xor(a, b) return { x16(a[1], b[1]), x16(a[2], b[2]), x16(a[3], b[3]), x16(a[4], b[4]) } end
  local function mul(a, b)                         -- 64-bit words as four 16-bit limbs, low first; a * b mod 2^64
    local r = { 0, 0, 0, 0 }
    for i = 1, 4 do
      local carry = 0
      for j = 1, 5 - i do local v = r[i + j - 1] + a[i] * b[j] + carry; r[i + j - 1] = v % 65536; carry = math.floor(v / 65536) end
    end
    return r
  end
  local function shr47(a) return { math.floor(a[3] / 32768) + (a[4] % 32768) * 2, math.floor(a[4] / 32768), 0, 0 } end
  local M = { 0xe995, 0x5bd1, 0xa793, 0xc6a4 }
  local function word(s, i, n)
    local w = { 0, 0, 0, 0 }
    for k = 0, n - 1 do local l = math.floor(k / 2) + 1; w[l] = w[l] + s:byte(i + k) * (k % 2 == 0 and 1 or 256) end
    return w
  end
  -- murmur64 (MurmurHash64A, seed 0): a resource name's id, as 16 hex digits
  local function resource_id(name)
    local n = #name
    local h = mul({ n % 65536, math.floor(n / 65536) % 65536, 0, 0 }, M)
    local whole = n - n % 8
    for i = 1, whole, 8 do
      local k = mul(word(name, i, 8), M); k = xor(k, shr47(k)); k = mul(k, M)
      h = mul(xor(h, k), M)
    end
    if n > whole then h = mul(xor(h, word(name, whole + 1, n - whole)), M) end
    h = xor(h, shr47(h)); h = mul(h, M); h = xor(h, shr47(h))
    return string.format('%04x%04x%04x%04x', h[4], h[3], h[2], h[1])
  end
  local rows                                       -- id hex -> { patch number, source }, read once
  local function lua_rows()
    if rows then return rows end
    rows = {}
    local function u32(s, i) local a, b, c, d = s:byte(i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
    local misses = 0
    for p = 0, 4095 do
      local f = io.open('data/9ba626afa44a3aa3.patch_' .. p, 'rb')
      if not f then misses = misses + 1; if misses > 40 then break end
      else
        misses = 0
        local d = f:read('*a'); f:close()
        if #d >= 72 and u32(d, 1) == 0xF0000011 then
          local nt, ne = u32(d, 5), u32(d, 9)
          for e = 0, ne - 1 do
            local at = 72 + nt * 32 + e * 80 + 1
            if d:sub(at + 8, at + 15) == '\226\023\209\044\250\141\078\161' then     -- the Lua type, 0xa14e8dfa2cd117e2
              local off, size = u32(d, at + 16), u32(d, at + 56)
              local id = d:sub(at, at + 7):reverse():gsub('.', function(c) return string.format('%02x', c:byte()) end)
              local env = off + size <= #d and size >= 8 and u32(d, off + 5)
              if env == 1 or env == 2 then rows[id] = { patch = p, src = d:sub(off + 9, off + size) } end
            end
          end
        end
      end
    end
    return rows
  end
  local function resource(name) return type(name) == 'string' and lua_rows()[resource_id(name)] or nil end
  local can_get = stingray.Application.can_get
  stingray.Application.can_get = function(kind, id)
    if kind == 'lua' then return resource(id) ~= nil end
    return can_get(kind, id)
  end
  table.insert(package.loaders, 2, function(name)
    local r = resource(name)
    if not r then return '\n\tno Lua resource \'' .. tostring(name) .. '\' in the deployed patches' end
    return assert(loadstring(r.src, '@' .. name))
  end)
  local boot = resource('boot')
  if not boot then print('modsim: no boot in the patches'); os.exit(2) end
  BOOT = assert(loadstring(boot.src, '@boot'))
end

-- ---------------------------------------------------------------- the session
BOOT()
init()
for i = 1, math.floor(SIMSECS * 60 + 0.5) do
  frame, t = i, i / 60
  for _, w in ipairs({ title, ship, mission, overlay, next_mission }) do w.t = w.t + 1 / 60 end
  if i == at_frame(PICKUP_AT) then
    -- the player picks up two medals: they leave the world
    local n = 0
    for j = #mission.units, 1, -1 do
      local u = mission.units[j]
      if u.kind == MEDAL and n < 2 then u.alive = false; table.remove(mission.units, j); n = n + 1 end
    end
  end
  if SCENARIO == 'next_mission' and not next_mission and t >= SWAP_AT then
    next_mission = make_mission()
    for _, u in ipairs(mission.units) do u.dead_world = true end
  end
  stats.frame_rects = 0
  update(1 / 60)
  render()
  if stats.frame_rects > stats.most_rects then stats.most_rects = stats.frame_rects end
end
shutdown()

-- ---------------------------------------------------------------- what happened
print(string.format('session: %g s (%d frames): title 0-%d s, ship %d-%d s, mission from %d s%s%s', SIMSECS, frame,
  TITLE_END, TITLE_END, SHIP_END, SHIP_END,
  SCENARIO == 'next_mission' and string.format(', a new mission world at %g s', SWAP_AT) or '',
  JOIN and string.format(', a player joining at %g s', JOIN) or ''))
print(string.format('drawn: %d rects (%d in the busiest frame), %d triangles, %d bitmaps, %d world lines; texts made %d, changed %d',
  stats.rects, stats.most_rects, stats.triangles, stats.bitmaps, stats.lines, stats.texts_made, stats.texts_changed))
local on_screen = {}
for _, g in ipairs(guis) do
  if not g.dead and drawn_world(g.world) then for _, s in pairs(g.texts) do on_screen[#on_screen + 1] = s end end
end
table.sort(on_screen)
print('texts on screen at the end: ' .. (on_screen[1] and table.concat(on_screen, ' | ') or 'none'))
local all = {}
for s, n in pairs(seen_texts) do all[n] = s end
print('texts drawn during the session (the first 40): ' .. (all[1] and table.concat(all, ' | ', 1, math.min(#all, 40)) or 'none'))
print(string.format('units: spawned %d, destroyed %d, linked %d; particle effects %d; light colors set %d',
  stats.spawned, stats.destroyed, stats.linked, stats.particles, stats.lights))
if stats.rays > 0 then print(string.format('rays against boxes (chef.ray_box): %d', stats.rays)) end
if stats.stale > 0 then
  print(string.format('WARNING: %d draws used a color made in an earlier frame: in the game those draw white (engine values live one frame: make them in the frame that draws)', stats.stale))
end
