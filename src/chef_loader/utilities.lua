-- Chef Shared Loader: utilities (api 3)
-- More helpers every mod gets, on top of services.lua's:
--   1 safe unit access: unit_kind / unit_alive / unit_position / unit_rotation / unit_node, the calls known to crash the
--     game refused centrally (in chef.call too), units_near over the shared unit scan
--   2 spawn / despawn / link / unlink, particles and unit lights, all cleaned up at a world change or when the mod
--     stops
--   3 timers (after, every), spread (a list worked through over frames) and a frame budget per mod (warned in the log)
--   4 setting (the game's settings file), in_session / is_host / players
--   5 triangle / circle / ring / arc, sprite sheets (bitmap_uv) and notify (a message on screen)
--   6 typed (the text typed this frame) and key_label (a key's name on the player's keyboard)
--   7 save_table / load_table
--   8 mods (every mod the loader found, with its version and state)
-- It only reaches the loader through ctx (services' table) and L (the loader's drawing and world internals). Lua 5.1.

local M = { version = '0.1.0' }

local pairs, ipairs, pcall, type, tostring, tonumber = pairs, ipairs, pcall, type, tostring, tonumber
local loadstring, setfenv, setmetatable = loadstring, setfenv, setmetatable
local floor, ceil, max, min, sqrt, sin, cos, pi = math.floor, math.ceil, math.max, math.min, math.sqrt, math.sin, math.cos, math.pi
local fmt, concat, sort = string.format, table.concat, table.sort

-- ------------------------------------------------------------------ the game's settings file (SJSON)
-- Stingray's simplified JSON: key = value lines, bare keys, { } objects, [ ] arrays without commas, // and /* */
-- comments. Numbers, strings, true/false; null leaves the key out.
function M.sjson(s)
  local i, n = 1, #s
  local sub, find = string.sub, string.find
  local function ws()
    while i <= n do
      local c = sub(s, i, i)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',' then
        i = i + 1
      elseif sub(s, i, i + 1) == '//' then
        local e = find(s, '\n', i, true); i = e and e + 1 or n + 1
      elseif sub(s, i, i + 1) == '/*' then
        local e = find(s, '*/', i + 2, true); i = e and e + 2 or n + 1
      else
        return
      end
    end
  end
  local function str()
    local out, j = {}, i + 1
    while j <= n do
      local c = sub(s, j, j)
      if c == '\\' then
        local e = sub(s, j + 1, j + 1)
        out[#out + 1] = (e == 'n' and '\n') or (e == 't' and '\t') or e
        j = j + 2
      elseif c == '"' then
        i = j + 1
        return concat(out)
      else
        out[#out + 1] = c; j = j + 1
      end
    end
    error('a string runs to the end')
  end
  local value
  local function object(closed)
    local t = {}
    while true do
      ws()
      if i > n then
        if closed then error('an object runs to the end') end
        return t
      end
      if sub(s, i, i) == '}' then
        if not closed then error('a } too many at ' .. i) end
        i = i + 1
        return t
      end
      local k
      if sub(s, i, i) == '"' then k = str()
      else
        local a, b = find(s, '^[%w_%-%.]+', i)
        if not a then error('a key expected at ' .. i) end
        k, i = sub(s, a, b), b + 1
      end
      ws()
      local c = sub(s, i, i)
      if c ~= '=' and c ~= ':' then error('= expected at ' .. i) end
      i = i + 1
      t[k] = value()
    end
  end
  value = function()
    ws()
    local c = sub(s, i, i)
    if c == '{' then i = i + 1; return object(true) end
    if c == '[' then
      i = i + 1
      local t = {}
      while true do
        ws()
        if i > n then error('an array runs to the end') end
        if sub(s, i, i) == ']' then i = i + 1; return t end
        t[#t + 1] = value()
      end
    end
    if c == '"' then return str() end
    local a, b = find(s, '^[^%s,%]}]+', i)
    if not a then error('a value expected at ' .. i) end
    local w = sub(s, a, b)
    i = b + 1
    if w == 'true' then return true elseif w == 'false' then return false elseif w == 'null' then return nil end
    return tonumber(w) or w
  end
  return object(false)
end

-- ------------------------------------------------------------------ saving tables
-- Plain data only: booleans, numbers (no NaN or infinity), strings, and tables of them with string or number keys; no
-- functions, no cycles, at most 16 deep. Written as a Lua table, keys sorted, so the file reads well and diffs well.
function M.serialize(v)
  local out, seen = {}, {}
  local function put(x, depth, indent)
    local t = type(x)
    if t == 'boolean' then out[#out + 1] = tostring(x)
    elseif t == 'number' then
      if x ~= x or x == math.huge or x == -math.huge then error('a number that can not be saved', 0) end
      out[#out + 1] = (x == floor(x) and x > -1e15 and x < 1e15) and fmt('%d', x) or fmt('%.17g', x)
    elseif t == 'string' then out[#out + 1] = fmt('%q', x)
    elseif t == 'table' then
      if seen[x] then error('a table inside itself', 0) end
      if depth > 16 then error('more than 16 tables deep', 0) end
      seen[x] = true
      local keys = {}
      for k in pairs(x) do
        local kt = type(k)
        if kt ~= 'string' and kt ~= 'number' then error('a ' .. kt .. ' key', 0) end
        keys[#keys + 1] = k
      end
      sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta == 'number' end
        return a < b
      end)
      out[#out + 1] = '{\n'
      for _, k in ipairs(keys) do
        out[#out + 1] = indent .. '  '
        if type(k) == 'string' and k:match('^[%a_][%w_]*$') then out[#out + 1] = k
        else out[#out + 1] = '['; put(k, depth + 1, indent); out[#out + 1] = ']' end
        out[#out + 1] = ' = '
        put(x[k], depth + 1, indent .. '  ')
        out[#out + 1] = ',\n'
      end
      out[#out + 1] = indent .. '}'
      seen[x] = nil
    else
      error('a ' .. t .. ' can not be saved', 0)
    end
  end
  put(v, 0, '')
  return concat(out)
end

-- ------------------------------------------------------------------ install
-- ctx: services' table (log, guarded, fn_of, open, DIR, world, now ...). L: the loader's own parts: api, xyz, rect,
-- color, tri (an engine triangle or false), bitmap (with uv), key_index, notify, addons, boots(), frame_no(),
-- clock (seconds, for timing), os, new_world_hooks, bad_kinds, settings_text, TOP.
function M.install(ctx, L)
  local util = {}
  local log, guarded, fn_of, api, xyz = ctx.log, ctx.guarded, ctx.fn_of, L.api, L.xyz
  local world = ctx.world

  -- the calls known to end the game (Boot Probe 2, Oct 21 2026): refused before they reach the engine
  -- runtime-built units (not a unit file; e.g. #ID[46cab355bd8d4d37], about 1,400 a mission): asking their position,
  -- rotation or meshes, or setting them, ends the game. The set is the loader's, so its unit scan skips them too.
  local BAD_KINDS = L.bad_kinds
  local UNIT_ASKS = { ['Unit.world_position'] = true, ['Unit.world_rotation'] = true, ['Unit.world_pose'] = true,
                      ['Unit.num_meshes'] = true, ['Unit.mesh'] = true, ['Unit.local_position'] = true,
                      ['Unit.local_rotation'] = true, ['Unit.local_pose'] = true, ['Unit.set_local_position'] = true,
                      ['Unit.set_local_rotation'] = true, ['Unit.set_local_scale'] = true,
                      ['Unit.set_local_pose'] = true, ['Unit.set_mesh_visibility'] = true }
  -- (and every Unit.teleport_..., below)
  -- whole engine tables that aren't for mods: the Localizer (Localizer.lookup ended the game in my tests; the game
  -- doesn't use the engine's Localizer, so there's nothing to look up), native code and the network
  local NEVER_TABLES = { Localizer = 'it ends the game', PluginManager = 'native code', Http = 'the network',
                         WebSocket = 'the network' }
  -- and single calls: writing other players' game
  local NEVER = { ['GameSession.set_game_object_field'] = "other players' game",
                  ['GameSession.create_game_object'] = "other players' game",
                  ['GameSession.destroy_game_object'] = "other players' game",
                  ['GameSession.migrate_game_object'] = "other players' game",
                  ['GameSession.migrate_game_session_host'] = "other players' game",
                  ['Network.write_dump_tag'] = 'the network' }
  -- What a call name is, worked out once per name (chef.call is hot): false (fine), 'unit' (refused on some units),
  -- 'camera' (Unit.has_camera) or { why = the refusal }.
  local class_of = {}
  local function class(name)
    local c = class_of[name]
    if c ~= nil then return c end
    c = false
    if type(name) == 'string' then
      local t = name:match('^([%w_]+)%.')
      local why = NEVER[name] or (t and NEVER_TABLES[t])
      if why then c = { why = name .. ' is not available to mods (' .. why .. ')' }
      elseif UNIT_ASKS[name] or name:match('^Unit%.teleport_') then c = 'unit'
      elseif name == 'Unit.has_camera' then c = 'camera' end
      class_of[name] = c
    end
    return c
  end

  -- unit -> its kind (the resource id in its debug name), or false; forgotten at every world change, so a handle the
  -- engine hands out again can't keep an old kind across worlds
  local kind_of = setmetatable({}, { __mode = 'k' })
  local function unit_kind(u)
    if u == nil then return nil end
    local k = kind_of[u]
    if k == nil then
      local nm = api('Unit.debug_name', u)
      k = type(nm) == 'string' and nm:match('#ID%[(%x+)%]') or false
      if k then k = k:lower() end
      kind_of[u] = k
    end
    return k or nil
  end
  -- Units are stamped with the engine world they were seen in. Within one engine world every unit stays usable (the
  -- ship loaded into the mission's world is the same engine world: the same units, re-stamped as they're seen). A
  -- unit seen in the engine world before this one is never touched again (any call on one ends the game). Only two
  -- worlds are kept, so the stamps can't pile up.
  local seen = { inst = -1, now = setmetatable({}, { __mode = 'k' }), before = setmetatable({}, { __mode = 'k' }) }
  local function roll()
    if seen.inst ~= world.instance then
      seen.inst, seen.before, seen.now = world.instance, seen.now, setmetatable({}, { __mode = 'k' })
    end
  end
  local function current(u)
    if u == nil or not world.stable then return false end
    roll()
    if seen.now[u] then return true end
    if seen.before[u] then return false end
    seen.now[u] = true
    return true
  end
  -- a unit I know is new in this world (one a mod just spawned)
  local function fresh(u)
    roll()
    seen.now[u], seen.before[u] = true, nil
  end
  local said = {}
  local function once(key, line) if not said[key] then said[key] = true; log(line) end end
  -- nil = fine; else why it's refused (fixed strings, built once each)
  local GONE = 'a unit from a world that is gone'
  local NO_CAMERA = 'Unit.has_camera needs a camera name (without one it ends the game)'
  local bad_why = {}
  local function refused(owner, name, ...)
    local c = class(name)
    if not c then return nil end
    if c == 'unit' then
      local u = ...
      if not current(u) then return GONE end
      local k = unit_kind(u)
      if k and BAD_KINDS[k] then
        local why = bad_why[k]
        if not why then why = 'a runtime-built unit (' .. k .. '): asking it that ends the game'; bad_why[k] = why end
        return why
      end
      return nil
    elseif c == 'camera' then
      local _, cam = ...
      if cam == nil then return NO_CAMERA end
      return nil
    end
    return c.why
  end
  util.refused = refused

  -- ---------------------------------------------------------------- spawned things, cleaned up
  -- { owner, kind = 'unit' | 'particles', h = handle, instance }
  local made = {}
  local sweep = { at = 0 }
  -- Is this effect still there to destroy? A one-shot effect ends by itself, and destroying one that's gone may end
  -- the game, so I ask first (no answer counts as gone: then it's left alone).
  local function playing(h) return api('World.are_particles_playing', world.main, h) == true end
  local function drop_made(filter, touch)
    local keep = {}
    for _, m in ipairs(made) do
      if filter(m) then
        -- only in the engine world it was made in; a world that's gone is never touched
        if touch and m.instance == world.instance and world.main then
          if m.kind == 'unit' then
            if api('Unit.alive', m.h) == true then api('World.destroy_unit', world.main, m.h) end
          elseif playing(m.h) then
            api('World.destroy_particles', world.main, m.h)
          end
        end
      else
        keep[#keep + 1] = m
      end
    end
    made = keep
  end
  -- every 2 s while anything is kept: units the game destroyed, effects that ended and anything from a world that's
  -- gone leave the list (nothing is destroyed here), so it can't grow over a long mission
  local function sweep_made(now)
    if #made == 0 or now < sweep.at then return end
    sweep.at = now + 2
    local keep = {}
    for _, m in ipairs(made) do
      local here = m.instance == world.instance and world.main ~= nil and world.stable
      if here and m.kind == 'unit' then here = api('Unit.alive', m.h) == true
      elseif here then here = playing(m.h) end
      if here then keep[#keep + 1] = m end
    end
    made = keep
  end

  -- ---------------------------------------------------------------- timers and spread jobs
  -- New timers and jobs wait in `incoming` until the next frame (a timer can make timers while the list is walked).
  -- The timers are only walked when one is due (or one was cancelled), each list compacted in place.
  local timers, jobs, incoming, incoming_jobs = {}, {}, {}, {}
  local tsched = { next_at = math.huge, dirty = false }
  local function run(a, what, fn, ...)
    local t0 = L.clock()
    local ok, err = pcall(fn, ...)
    local ms = (L.clock() - t0) * 1000
    a.ms = (a.ms or 0) + ms
    if ms > (a.max_ms or 0) then a.max_ms = ms end
    if not ok then
      a.timer_errors = (a.timer_errors or 0) + 1
      if a.timer_errors <= 3 then log(fmt('[%s] %s error: %s', a.short, what, tostring(err))) end
    end
    return ok
  end

  -- ---------------------------------------------------------------- the frame, world changes, mods stopping
  local frame_cache = { n = -1 }
  local NO_KEYS = {}                      -- the raw list on a frame nothing was typed (read only)
  local session = { at = -100 }
  L.new_world_hooks[#L.new_world_hooks + 1] = function()
    kind_of = setmetatable({}, { __mode = 'k' })
    -- a new world inside the same engine world (the ship loaded into the mission's): what mods made is destroyed; a new
    -- engine world: it's simply forgotten
    drop_made(function() return true end, true)
    for _, j in ipairs(incoming_jobs) do jobs[#jobs + 1] = j end
    incoming_jobs = {}
    local keep = {}
    for _, j in ipairs(jobs) do
      if j.keep then keep[#keep + 1] = j
      elseif j.on then
        j.on = false
        if j.done then run(j.a, 'spread done', j.done, false) end
      end
    end
    jobs = keep
    session.at = -100
  end
  local function timers_frame(now)
    if #incoming > 0 then
      for _, t in ipairs(incoming) do timers[#timers + 1] = t end
      incoming = {}
      tsched.dirty = true
    end
    if #timers == 0 or (now < tsched.next_at and not tsched.dirty) then return end
    tsched.dirty = false
    local n, j, nxt = #timers, 0, math.huge
    for i = 1, n do
      local t = timers[i]
      timers[i] = nil
      if t.on and t.a.on then
        if now >= t.at then
          local ok = run(t.a, t.every and 'every' or 'after', t.fn)
          if not ok then t.errors = t.errors + 1 end
          if t.every and t.errors < 20 then t.at = max(t.at + t.every, now) else t.on = false end
        end
        if t.on then
          j = j + 1; timers[j] = t
          if t.at < nxt then nxt = t.at end
        end
      end
    end
    tsched.next_at = nxt
  end
  local function jobs_frame()
    if #incoming_jobs > 0 then
      for _, j in ipairs(incoming_jobs) do jobs[#jobs + 1] = j end
      incoming_jobs = {}
    end
    local n, k = #jobs, 0
    if n == 0 then return end
    for i = 1, n do
      local j = jobs[i]
      jobs[i] = nil
      if j.on and j.a.on then
        local last = min(#j.list, j.i + j.per)
        for x = j.i + 1, last do
          if not run(j.a, 'spread', j.fn, j.list[x], x) then j.errors = j.errors + 1 end
          if j.errors >= 20 then j.on = false; break end
        end
        j.i = last
        if j.on and j.i >= #j.list then
          j.on = false
          if j.done then run(j.a, 'spread done', j.done, true) end
        end
        if j.on then k = k + 1; jobs[k] = j end
      end
    end
  end
  function util.frame()
    local now = ctx.now()
    timers_frame(now)
    jobs_frame()
    sweep_made(now)
  end
  -- a mod's average a frame against its budget, from the loader's status line (once every 10 minutes at most)
  function util.budget_check(a, avg, worst)
    local b = a.budget or util.default_budget()
    if avg > b and ctx.now() >= (a.budget_said or -1e9) + 600 then
      a.budget_said = ctx.now()
      log(fmt('[%s] over its frame budget: avg %.3f ms a frame, worst %.2f ms (budget %.3g ms)', a.name, avg, worst, b))
    end
  end
  -- (at shutdown nothing is touched: the game is closing its worlds)
  function util.shutdown()
    drop_made(function() return true end, false)
    timers, jobs, incoming, incoming_jobs = {}, {}, {}, {}
  end
  -- a mod that stopped (the loader calls this through services' forget): its timers, jobs and spawned things go
  function util.forget(owner)
    drop_made(function(m) return m.owner == owner end, true)
    for _, list in ipairs({ timers, incoming, jobs, incoming_jobs }) do
      for _, t in ipairs(list) do if t.a.name == owner then t.on = false end end
    end
    tsched.dirty = true
  end

  -- ---------------------------------------------------------------- shared per-frame reads
  local function typed_now()
    local n = L.frame_no()
    if frame_cache.n == n then return frame_cache.text, frame_cache.raw end
    frame_cache.n, frame_cache.text, frame_cache.raw = n, '', NO_KEYS
    local ks = api('Keyboard.keystrokes')
    if type(ks) == 'table' and #ks > 0 then
      local parts, raw = {}, {}
      for _, k in ipairs(ks) do
        raw[#raw + 1] = k
        if type(k) == 'string' and #k > 0 and k:byte(1) >= 32 then parts[#parts + 1] = k end
      end
      frame_cache.text, frame_cache.raw = concat(parts), raw
    end
    return frame_cache.text, frame_cache.raw
  end
  util.typed = typed_now
  local labels = {}
  local function key_label(name)
    if type(name) ~= 'string' then return '' end
    local l = labels[name]
    if l == nil then
      local ix = L.key_index(name)
      local s = ix and api('Keyboard.button_locale_name', ix)
      if type(s) ~= 'string' or s == '' then s = ix and api('Keyboard.button_name', ix) end
      l = (type(s) == 'string' and s ~= '') and s or name
      labels[name] = l
    end
    return l
  end
  util.key_label = key_label

  local function session_now()
    local now = ctx.now()
    if now < session.at + 1 then return session end
    session.at = now
    local s = api('Network.game_session')
    local me = api('Network.peer_id')
    session.me = me
    session.on, session.host, session.peers = false, nil, 0
    if s then
      session.on = api('GameSession.in_session', s) == true
      if session.on then
        session.host = api('GameSession.game_session_host', s)
        local ps = api('GameSession.peers', s)
        session.peers = type(ps) == 'table' and #ps or 0
      end
    end
    return session
  end

  -- The game's settings file comes from the loader's one cache of it (read again on a world change or a new screen
  -- size, else at most every 30 s); I only parse it again when its text changed.
  local settings = { n = -1, data = nil }
  local function settings_now()
    local text, n = L.settings_text()
    if n ~= settings.n then
      settings.n = n
      if type(text) == 'string' then
        local okp, t = pcall(M.sjson, text)
        if okp and type(t) == 'table' then settings.data = t
        else once('settings:' .. tostring(t), 'the game settings file could not be read: ' .. tostring(t)) end
      end
    end
    return settings.data
  end
  util.setting = function(path)
    local t = settings_now()
    if type(t) ~= 'table' or type(path) ~= 'string' then return nil end
    for part in path:gmatch('[^%.]+') do
      if type(t) ~= 'table' then return nil end
      t = t[tonumber(part) or part]
    end
    return t
  end

  -- ---------------------------------------------------------------- shapes
  -- Engine triangles when the game draws them (L.tri: true when one was drawn); else rows of rects.
  local function tri_spans(rect, x1, y1, x2, y2, x3, y3, c, layer, step)
    -- sort by y, then fill one row of `step` pixels at a time
    if y1 > y2 then x1, y1, x2, y2 = x2, y2, x1, y1 end
    if y1 > y3 then x1, y1, x3, y3 = x3, y3, x1, y1 end
    if y2 > y3 then x2, y2, x3, y3 = x3, y3, x2, y2 end
    if y3 - y1 < 0.5 then return end
    local function at(ya, xa, yb, xb, y) if yb == ya then return xa end return xa + (xb - xa) * (y - ya) / (yb - ya) end
    local y = floor(y1)
    while y < y3 do
      local ym = y + step / 2
      local xa = at(y1, x1, y3, x3, ym)
      local xb = ym < y2 and at(y1, x1, y2, x2, ym) or at(y2, x2, y3, x3, ym)
      if xa > xb then xa, xb = xb, xa end
      if xb - xa >= 0.5 then rect(floor(xa + 0.5), y, floor(xb + 0.5) - floor(xa + 0.5), step, c, layer) end
      y = y + step
    end
  end
  local function triangle(x1, y1, x2, y2, x3, y3, c, layer)
    if not c then return end
    if L.tri(x1, y1, x2, y2, x3, y3, c, layer) then return true end
    tri_spans(L.rect, x1, y1, x2, y2, x3, y3, c, layer, 1)
    return false
  end
  util.triangle = triangle
  -- angles in degrees, 0 = up, clockwise (like a compass and the radar)
  local function polar(cx, cy, r, deg) local a = deg * pi / 180; return cx + r * sin(a), cy + r * cos(a) end
  local function segments(r, sweep_deg) return max(3, min(96, ceil(max(12, r * 0.6) * sweep_deg / 360))) end
  -- an annulus piece from a0 to a1 (degrees), r_in may be 0
  local function arc(cx, cy, r_in, r_out, a0, a1, c, layer)
    if not c or r_out <= 0 then return end
    if a1 < a0 then a0, a1 = a1, a0 end
    local span = min(360, a1 - a0)
    local n = segments(r_out, span)
    if L.tri_ok() ~= false then
      -- a fan of engine triangles; if the first one isn't drawn, rects instead
      local px, py = polar(cx, cy, r_out, a0)
      local qx, qy = polar(cx, cy, r_in, a0)
      local drew = true
      for i = 1, n do
        local d = a0 + span * i / n
        local nx, ny = polar(cx, cy, r_out, d)
        if r_in <= 0 then
          drew = L.tri(cx, cy, px, py, nx, ny, c, layer)
        else
          local mx, my = polar(cx, cy, r_in, d)
          drew = L.tri(qx, qy, px, py, nx, ny, c, layer)
          if drew then L.tri(qx, qy, nx, ny, mx, my, c, layer) end
          qx, qy = mx, my
        end
        if not drew then break end
        px, py = nx, ny
      end
      if drew then return end
    end
    -- rects: a full disc or ring row by row; a part of one as small squares along its middle
    local step = max(1, ceil(r_out / 48))
    if span >= 360 then
      local y = -r_out
      while y < r_out do
        local ym = y + step / 2
        local wo = sqrt(max(0, r_out * r_out - ym * ym))
        if r_in > 0 and math.abs(ym) < r_in then
          local wi = sqrt(max(0, r_in * r_in - ym * ym))
          L.rect(floor(cx - wo + 0.5), floor(cy + y), floor(wo - wi + 0.5), step, c, layer)
          L.rect(floor(cx + wi + 0.5), floor(cy + y), floor(wo - wi + 0.5), step, c, layer)
        elseif wo >= 0.5 then
          L.rect(floor(cx - wo + 0.5), floor(cy + y), floor(2 * wo + 0.5), step, c, layer)
        end
        y = y + step
      end
    else
      local th = max(1, r_out - r_in)
      local rm = (r_out + r_in) / 2
      local k = max(2, ceil(rm * span * pi / 180 / max(1, th * 0.6)))
      for i = 0, k do
        local x, y = polar(cx, cy, rm, a0 + span * i / k)
        L.rect(floor(x - th / 2 + 0.5), floor(y - th / 2 + 0.5), ceil(th), ceil(th), c, layer)
      end
    end
  end
  util.arc = arc

  -- ---------------------------------------------------------------- the helpers each mod gets
  function util.extend(chef, a)
    local owner = a.name
    local base_call, base_call_kind = chef.call, chef.call_kind
    -- chef.call and chef.call_kind refuse the known game-ending calls and the ones mods shouldn't make (each refusal
    -- logged once per mod; no strings built for one already logged)
    local said_refused = {}
    local function refuse(name, why)
      local s = said_refused[name]
      if not s then s = {}; said_refused[name] = s end
      if not s[why] then s[why] = true; log(fmt('[%s] refused %s: %s', owner, name, why)) end
      return nil, why
    end
    function chef.call(name, ...)
      local why = refused(owner, name, ...)
      if why then return refuse(name, why) end
      return base_call(name, ...)
    end
    function chef.call_kind(name, kind, ...)
      local why = refused(owner, name, ...)
      if why then return refuse(name, why) end
      return base_call_kind(name, kind, ...)
    end

    -- 1 units
    function chef.unit_kind(u) if current(u) then return unit_kind(u) end end
    function chef.unit_alive(u)
      if not current(u) then return false end
      return base_call('Unit.alive', u) == true
    end
    local function asked(name, u, ...)
      if not current(u) then return nil end
      local k = unit_kind(u)
      if not k or BAD_KINDS[k] then return nil end
      if base_call('Unit.alive', u) ~= true then return nil end
      return base_call_kind(name, k, u, ...)
    end
    function chef.unit_position(u, node) return xyz((asked('Unit.world_position', u, node or 1))) end
    -- forward x, y, z and yaw (radians, 0 = +y)
    function chef.unit_rotation(u, node)
      local q = asked('Unit.world_rotation', u, node or 1)
      if q == nil then return nil end
      local fx, fy, fz = xyz((base_call('Quaternion.forward', q)))
      if not fx then return nil end
      return fx, fy, fz, math.atan2(fx, fy)
    end
    function chef.unit_node(u, name)
      if type(name) ~= 'string' or not current(u) then return nil end
      local k = unit_kind(u)
      if not k or BAD_KINDS[k] then return nil end
      if base_call_kind('Unit.has_node', k, u, name) ~= true then return nil end
      return base_call_kind('Unit.node', k, u, name)
    end
    local mine = {}                  -- this mod's watches (chef.watch is wrapped to note them)
    local base_watch = chef.watch
    function chef.watch(kinds, every)
      if type(kinds) == 'table' then
        for k in pairs(kinds) do
          if type(k) == 'string' and BAD_KINDS[k:lower()] then
            once(owner .. '|watch|' .. k, fmt('[%s] watch: %s is skipped (asking where a runtime-built unit is ends the game)', owner, k))
          end
        end
      end
      local w = base_watch(kinds, every)
      if not w then return nil end
      mine[#mine + 1] = w
      local stop = w.stop
      function w.stop()
        stop()
        for i = #mine, 1, -1 do if mine[i] == w then table.remove(mine, i) end end
      end
      return w
    end
    -- the units of the given watch (or every watch of this mod) within r of a point, nearest first:
    -- { { unit, kind, x, y, z, d }, ... } (positions from the watch's last list)
    function chef.units_near(x, y, z, r, w)
      local out = {}
      if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' or type(r) ~= 'number' then return out end
      local list = w and { w } or mine
      local r2 = r * r
      for _, wt in ipairs(list) do
        for _, it in ipairs(wt.items or {}) do
          local dx, dy, dz = it.x - x, it.y - y, it.z - z
          local d2 = dx * dx + dy * dy + dz * dz
          if d2 <= r2 then out[#out + 1] = { unit = it.unit, kind = it.kind, x = it.x, y = it.y, z = it.z, d = sqrt(d2) } end
        end
      end
      sort(out, function(p, q) return p.d < q.d end)
      return out
    end

    -- 2 spawning, linking, particles, lights
    local function id_of(res)
      if type(res) == 'string' and #res == 16 and res:match('^%x+$') then return api('IdString64.from_hex', res:lower()) end
      return res
    end
    function chef.spawn(res, x, y, z)
      if not world.stable then return nil, 'no world yet' end
      local id = id_of(res)
      if id == nil then return nil, 'no id' end
      if api('Application.can_get', 'unit', id) ~= true then return nil, 'unit ' .. tostring(res) .. ' is not loaded' end
      local p = api('Vector3', x or 0, y or 0, z or 0)
      if not p then return nil, 'no position' end
      local u, err = base_call('World.spawn_unit', world.main, id, p)
      if not u then return nil, err end
      fresh(u)
      made[#made + 1] = { owner = owner, kind = 'unit', h = u, instance = world.instance }
      return u
    end
    function chef.despawn(u)
      for i, m in ipairs(made) do
        if m.h == u and m.kind == 'unit' and m.owner == owner then
          table.remove(made, i)
          if m.instance == world.instance and world.main and api('Unit.alive', u) == true then
            base_call('World.destroy_unit', world.main, u)
          end
          return true
        end
      end
      return false
    end
    -- child's node (default 1, its root) onto parent's node (a name or an index; default 1)
    function chef.link(child, parent, parent_node, child_node)
      if not (world.stable and current(child) and current(parent)) then return nil, 'not in this world' end
      local pn = parent_node or 1
      if type(pn) == 'string' then
        pn = chef.unit_node(parent, pn)
        if not pn then return nil, 'no node ' .. tostring(parent_node) end
      end
      local _, err = base_call('World.link_unit', world.main, child, child_node or 1, parent, pn)
      if err then return nil, err end
      return true
    end
    function chef.unlink(child)
      if not (world.stable and current(child)) then return nil, 'not in this world' end
      local _, err = base_call('World.unlink_unit', world.main, child)
      if err then return nil, err end
      return true
    end
    function chef.particles(res, x, y, z)
      if not world.stable then return nil, 'no world yet' end
      local id = id_of(res)
      local p = api('Vector3', x or 0, y or 0, z or 0)
      if not (id and p) then return nil, 'no id or position' end
      local h, err = base_call('World.create_particles', world.main, id, p)
      if h == nil then return nil, err end
      made[#made + 1] = { owner = owner, kind = 'particles', h = h, instance = world.instance }
      return h
    end
    function chef.stop_particles(h)
      for i, m in ipairs(made) do
        if m.h == h and m.kind == 'particles' and m.owner == owner then
          table.remove(made, i)
          if m.instance == world.instance and world.main and playing(h) then
            base_call('World.destroy_particles', world.main, h)
          end
          return true
        end
      end
      return false
    end
    -- a unit's lights: chef.lights(u) -> how many; chef.light(u, i) -> { set_color(r, g, b) (0-255), set_intensity(v),
    -- set_enabled(on), set_falloff(start, end), set_shadows(on) }, each asked fresh (no handle kept)
    function chef.lights(u)
      local k = current(u) and unit_kind(u)
      if not k or BAD_KINDS[k] then return 0 end
      local n = base_call_kind('Unit.num_lights', k, u)
      return type(n) == 'number' and n or 0
    end
    function chef.light(u, i)
      local L2 = {}
      local function get()
        local k = current(u) and unit_kind(u)
        if not k or BAD_KINDS[k] then return nil end
        return base_call_kind('Unit.light', k, u, i or 1)
      end
      local function set(name, ...)
        local l = get()
        if l == nil then return false end
        local _, err = base_call(name, l, ...)
        return err == nil
      end
      function L2.set_color(r, g, b)
        local v = api('Vector3', (r or 255) / 255, (g or 255) / 255, (b or 255) / 255)
        return v and set('Light.set_color', v) or false
      end
      function L2.set_intensity(v) return set('Light.set_intensity', v) end
      function L2.set_enabled(on) return set('Light.set_enabled', on == true) end
      function L2.set_falloff(s, e) return set('Light.set_falloff_start', s) and set('Light.set_falloff_end', e) end
      function L2.set_shadows(on) return set('Light.set_casts_shadows', on == true) end
      return L2
    end

    -- 3 timers, spread, budget
    local function timer(delay, every, fn)
      if type(fn) ~= 'function' or type(delay) ~= 'number' then return nil end
      if #timers + #incoming >= 512 then once('timers', 'timers: 512 running already; no more'); return nil end
      local t = { a = a, at = ctx.now() + max(0, delay), every = every and max(0.0, delay) or nil, fn = fn, on = true, errors = 0 }
      incoming[#incoming + 1] = t
      return { cancel = function() if t.on then t.on = false; tsched.dirty = true end end,
               active = function() return t.on end }
    end
    function chef.after(s, fn) return timer(s, false, fn) end
    function chef.every(s, fn) return timer(s, true, fn) end
    -- fn(item, i) for per_frame items a frame; done(true) at the end, done(false) when a new world stops it
    -- (opts.keep = true: it carries on across worlds; only for lists without units)
    function chef.spread(list, per_frame, fn, done, opts)
      if type(list) ~= 'table' or type(fn) ~= 'function' then return nil end
      local j = { a = a, list = list, per = max(1, floor(tonumber(per_frame) or 50)), fn = fn,
                  done = type(done) == 'function' and done or nil, i = 0, on = true, errors = 0,
                  keep = type(opts) == 'table' and opts.keep == true }
      incoming_jobs[#incoming_jobs + 1] = j
      return { cancel = function() j.on = false end, active = function() return j.on end,
               progress = function() return j.i, #j.list end }
    end
    function chef.budget(ms) if type(ms) == 'number' and ms > 0 then a.budget = ms end return a.budget or util.default_budget() end

    -- 4 game and session
    function chef.setting(path) return util.setting(path) end
    function chef.in_session() return session_now().on end
    function chef.is_host()
      local s = session_now()
      if not s.on then return true end
      return s.host ~= nil and s.host == s.me
    end
    function chef.players()
      local s = session_now()
      if not s.on then return 1 end
      return max(1, s.peers)
    end
    function chef.peer_id() return session_now().me end
    -- (no localize: the whole Localizer is refused, see above)

    -- 5 drawing
    function chef.triangle(x1, y1, x2, y2, x3, y3, c, layer) return triangle(x1, y1, x2, y2, x3, y3, c, layer) end
    function chef.circle(x, y, r, c, layer) arc(x, y, 0, r, 0, 360, c, layer) end
    function chef.ring(x, y, r_in, r_out, c, layer) arc(x, y, r_in, r_out, 0, 360, c, layer) end
    function chef.arc(x, y, r_in, r_out, a0, a1, c, layer) arc(x, y, r_in, r_out, a0, a1, c, layer) end
    function chef.bitmap_uv(tex, u0, v0, u1, v1, x, y, w, h, c, layer)
      return L.bitmap(tex, x, y, w, h, c, layer, u0, v0, u1, v1)
    end
    -- a texture holding cols x rows pictures, numbered from 1 left to right, top to bottom
    function chef.sprite_sheet(tex, cols, rows)
      cols, rows = max(1, floor(cols or 1)), max(1, floor(rows or 1))
      local sheet = { tex = tex, cols = cols, rows = rows }
      function sheet.draw(i, x, y, w, h, c, layer)
        i = floor(i or 1) - 1
        if i < 0 or i >= cols * rows then return false end
        local cx, cy = i % cols, floor(i / cols)
        return L.bitmap(tex, x, y, w, h, c, layer, cx / cols, cy / rows, (cx + 1) / cols, (cy + 1) / rows)
      end
      return sheet
    end
    -- (three at a time per mod)
    function chef.notify(text, seconds, r, g, b)
      if type(text) ~= 'string' or text == '' then return false end
      if L.notes_of(owner) >= 3 then return false end
      L.notify({ text = text:upper():sub(1, 80), dur = min(30, max(1, tonumber(seconds) or 4)), owner = owner,
                 rgb = { r or 235, g or 235, b or 235 } })
      return true
    end

    -- 6 input
    function chef.typed() return typed_now() end
    function chef.key_label(name) return key_label(name) end

    -- 7 tables saved between launches (one file per mod and name, next to the loader's log)
    local function data_file(name)
      if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 48 then return nil end
      return ctx.DIR .. 'chef_data_' .. owner:gsub('^mods/', ''):gsub('[^%w_%-]', '_') .. '_' .. name .. '.lua'
    end
    function chef.save_table(name, t)
      local path = data_file(name)
      if not path then return false, 'names are letters, digits, _ - (48 at most)' end
      if type(t) ~= 'table' then return false, 'only a table' end
      local ok, text = pcall(M.serialize, t)
      if not ok then return false, tostring(text) end
      if #text > 256 * 1024 then return false, 'more than 256 KB' end
      local tmp = path .. '.tmp'
      local f = ctx.open(tmp, 'w')
      if not f then return false, 'could not write ' .. tmp end
      local okw, werr = pcall(f.write, f, 'return ', text, '\n')
      pcall(f.close, f)
      if not okw then return false, 'could not write ' .. tmp .. ': ' .. tostring(werr) end
      -- Windows' rename won't replace a file: the old one goes first (a crash in between leaves the .tmp, which
      -- load_table reads). os.rename answers nil and why when it fails, so its answer is checked, not just the pcall.
      if L.os then
        pcall(L.os.remove, path)
        local okr, renamed, rerr = pcall(L.os.rename, tmp, path)
        if not (okr and renamed) then return false, 'rename failed: ' .. tostring(okr and rerr or renamed) end
      end
      return true
    end
    function chef.load_table(name)
      local path = data_file(name)
      if not path then return nil, 'bad name' end
      local f = ctx.open(path, 'r') or ctx.open(path .. '.tmp', 'r')
      if not f then return nil, 'none saved' end
      local text = f:read('*a')
      f:close()
      if type(text) ~= 'string' or #text > 256 * 1024 then return nil, 'too big' end
      local chunk, err = loadstring(text, '=' .. name)
      if not chunk then return nil, tostring(err) end
      setfenv(chunk, {})               -- plain data: it runs with nothing to reach
      local ok, t = pcall(chunk)
      if ok and type(t) == 'table' then return t end
      return nil, ok and 'not a table' or tostring(t)
    end

    -- 8 the mods the loader found
    function chef.mods()
      local out = {}
      for _, m in ipairs(L.addons) do
        out[#out + 1] = { name = m.name, kind = 'addon', on = m.on == true, dev = m.dev == true, file = m.file,
                          version = m.module and m.module.version and tostring(m.module.version) or nil }
      end
      for _, b in ipairs(L.boots()) do
        out[#out + 1] = { name = b.owner or b.file, kind = 'boot', on = b.on ~= false, file = b.file }
      end
      return out
    end
  end

  -- the frame budget behind chef.budget: the loader's own "Budget warning (ms)" row (util.budget_row, set by the
  -- loader), 2 ms until it's there
  util.default_budget = function() return util.budget_row and util.budget_row.value or 2.0 end

  util.caps = { units = true, spawn = true, timers = true, budget = true, session = true, settings_file = true,
                shapes = true, sprite_sheets = true, notify = true, typed = true, key_labels = true, save_table = true,
                mods = true }
  return util
end

return M
