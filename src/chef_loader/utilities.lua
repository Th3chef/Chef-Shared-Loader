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
local loadstring, setfenv, setmetatable, rawget = loadstring, setfenv, setmetatable, rawget
local floor, ceil, max, min, sqrt, sin, cos, pi = math.floor, math.ceil, math.max, math.min, math.sqrt, math.sin, math.cos, math.pi
local fmt, concat, sort = string.format, table.concat, table.sort
local huge = math.huge

-- A mod's error as text for the log (tostring alone can raise: an error object whose __tostring errors)
local function err_text(e)
  if type(e) == 'string' then return e end
  local ok, s = pcall(tostring, e)
  if ok and type(s) == 'string' then return s end
  return '(an error that can not be shown as text)'
end
local function finite(n) return type(n) == 'number' and n == n and n > -huge and n < huge end
-- a file write or close went through: pcall's ok, then what the call answered (nil and why when it failed)
local function io_ok(ok, r, e)
  if not ok or r == false then return false end
  return not (r == nil and e ~= nil)
end

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
-- Whole numbers are written with %.0f up to 2^53 (%d is 32 bits in the game's Lua on Windows: 3e9 would come back
-- as -2147483648), anything else with 17 digits so it reads back exactly. A key that is a Lua word (end, nil, ...) or
-- not a name is written as ["..."].
local RESERVED = {}
for w in ('and break do else elseif end false for function if in local nil not or repeat return then true until while'):gmatch('%a+') do
  RESERVED[w] = true
end
function M.serialize(v)
  local out, seen = {}, {}
  local function put(x, depth, indent)
    local t = type(x)
    if t == 'boolean' then out[#out + 1] = tostring(x)
    elseif t == 'number' then
      if not finite(x) then error('a number that can not be saved', 0) end
      out[#out + 1] = (x == floor(x) and x >= -9007199254740992 and x <= 9007199254740992) and fmt('%.0f', x) or fmt('%.17g', x)
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
        if type(k) == 'string' and not RESERVED[k] and k:match('^[%a_][%w_]*$') then out[#out + 1] = k
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

-- A mod's saved-table file: chef_data_<owner without mods/>__<name>.lua, where every character that isn't a lower-case
-- letter, a digit or - is written as _ and its two hex digits (_ is _5f, / is _2f, A is _41). So each owner and name
-- pair has its own file, on Windows too (where file names ignore case), and no pair can make another's: "__" only
-- ever stands between the two. Owners are always mods/<author>/<name>; anything else gets no file.
local function data_enc(s) return (s:gsub('[^a-z0-9%-]', function(ch) return fmt('_%02x', ch:byte()) end)) end
function M.data_name(owner, name)
  if type(owner) ~= 'string' or owner:sub(1, 5) ~= 'mods/' or #owner < 6 then return nil end
  return 'chef_data_' .. data_enc(owner:sub(6)) .. '__' .. data_enc(name) .. '.lua'
end
-- the file name before 1.0.1 (not one to one: two pairs could share one), read once to move a table over
function M.old_data_name(owner, name)
  return 'chef_data_' .. owner:gsub('^mods/', ''):gsub('[^%w_%-]', '_') .. '_' .. name .. '.lua'
end

-- ------------------------------------------------------------------ install
-- ctx: services' table (log, guarded, fn_of, open, DIR, world, now ...). L: the loader's own parts: api, xyz, rect,
-- color, tri (an engine triangle or false), bitmap (with uv), key_index, notify, addons, boots(), frame_no(),
-- clock (seconds, for timing), os, new_world_hooks, bad_kinds, settings_text, TOP.
function M.install(ctx, L)
  local util = {}
  local log, guarded, fn_of, api, xyz = ctx.log, ctx.guarded, ctx.fn_of, L.api, L.xyz
  local world = ctx.world

  -- the calls known to end the game, refused before they reach the engine:
  -- runtime-built units (not a unit file; e.g. #ID[46cab355bd8d4d37], about 1,400 a mission): asking their position,
  -- rotation or meshes, or setting them, ends the game. The set is the loader's, so its unit scan skips them too.
  local BAD_KINDS = L.bad_kinds
  local UNIT_ASKS = { ['Unit.world_position'] = true, ['Unit.world_rotation'] = true, ['Unit.world_pose'] = true,
                      ['Unit.num_meshes'] = true, ['Unit.mesh'] = true, ['Unit.local_position'] = true,
                      ['Unit.local_rotation'] = true, ['Unit.local_pose'] = true, ['Unit.set_local_position'] = true,
                      ['Unit.set_local_rotation'] = true, ['Unit.set_local_scale'] = true,
                      ['Unit.set_local_pose'] = true, ['Unit.set_mesh_visibility'] = true }
  -- (and every Unit.teleport_..., below)
  -- whole engine tables that aren't for mods: the Localizer (Localizer.lookup ends the game, and the game doesn't use
  -- the engine's Localizer, so there's nothing to look up), native code and the network
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
  local function unit_kind(u, owner)
    if u == nil then return nil end
    local k = kind_of[u]
    if k == nil then
      local nm = guarded(owner or 'loader', 'Unit.debug_name', fn_of('Unit.debug_name'), u)
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
      local k = unit_kind(u, owner)
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
  local function account(a, ms)
    a.ms = (a.ms or 0) + ms
    if ms > (a.max_ms or 0) then a.max_ms = ms end
    a.pm_ms = (a.pm_ms or 0) + ms
    if ms > (a.pm_max or 0) then a.pm_max = ms end
  end
  local function failed(a, what, err)
    a.timer_errors = (a.timer_errors or 0) + 1
    if a.timer_errors <= 3 then log(fmt('[%s] %s error: %s', tostring(a.short or a.name), what, err_text(err))) end
  end
  local function run(a, what, fn, ...)
    local t0 = L.clock()
    local ok, err = pcall(fn, ...)
    account(a, (L.clock() - t0) * 1000)
    if not ok then failed(a, what, err) end
    return ok
  end
  -- for services: a mod's callback (an event, on_change, after_startup) timed as that mod's own; and a mod's own
  -- call that ran other mods' callbacks, whose time already went to them
  function util.timed(a, fn, ...)
    local t0 = L.clock()
    local ok, err = pcall(fn, ...)
    account(a, (L.clock() - t0) * 1000)
    return ok, err
  end
  function util.discount(a, ms)
    a.ms = (a.ms or 0) - ms
    a.pm_ms = (a.pm_ms or 0) - ms
  end
  util.clock = L.clock
  -- a file written whole as tmp put in place of path. Windows' rename won't replace a file, so the old one goes first
  -- (a crash in between leaves the .tmp, which is read when the file isn't there); os.rename answers nil and why
  -- when it fails, so its answer is checked, not just the pcall.
  -- Without os.rename, or when it fails, the .tmp's text is written in place instead, so path ends up whole (and the
  -- .tmp stays as a second copy until the next save).
  function util.replace(tmp, path)
    local o = L.os
    local why = 'no os.rename'
    if o and o.rename then
      if o.remove then pcall(o.remove, path) end
      local okr, renamed, rerr = pcall(o.rename, tmp, path)
      if okr and renamed then return true end
      why = 'rename failed: ' .. tostring(okr and rerr or renamed)
    end
    local f = ctx.open(tmp, 'r')
    if not f then return false, why end
    local okr, text = pcall(f.read, f, '*a')
    pcall(f.close, f)
    if not (okr and type(text) == 'string') then return false, why end
    local g = ctx.open(path, 'w')
    if not g then return false, why end
    local okw = io_ok(pcall(g.write, g, text))
    local okc = io_ok(pcall(g.close, g))
    if okw and okc then return true end
    -- a cut-off copy would be read before the whole .tmp: it goes
    if o and o.remove then pcall(o.remove, path) end
    return false, why
  end
  -- ---------------------------------------------------------------- the mod list and the health file
  -- Every mod I found, with what it's doing and why: chef.mods() hands out a fresh copy, and chef_loader_health.txt
  -- holds the same, one tab-separated line a mod, so a mod (a report, a menu) or a player can see why one isn't
  -- running. state: running, off, kept off (it crashed the game), not started (a requirement, a compile error ...),
  -- stopped (too many errors), or run by <another loader> for the addons another mod loader starts itself.
  -- ms_avg / ms_max: its time a frame over the last status minute (nil before the first).
  local function state_of(m)
    if m.state == 'running' and not m.on then return 'off' end
    return m.state or (m.on and 'running' or 'off')
  end
  function util.mod_list()
    local out = {}
    for _, m in ipairs(L.addons) do
      -- (another mod's version read raw: its table can't raise into this call)
      local v = type(m.module) == 'table' and rawget(m.module, 'version') or nil
      local req = {}
      for i, q in ipairs(m.requires or {}) do req[i] = q end
      out[#out + 1] = { name = m.name, kind = 'addon', on = m.on == true, dev = m.dev == true, file = m.file,
                        version = (type(v) == 'string' or type(v) == 'number') and tostring(v) or nil,
                        state = state_of(m), why = m.why, errors = m.errors or 0, ms_avg = m.last_avg, ms_max = m.last_max,
                        requires = req, full_access = m.full_access == true }
    end
    for _, b in ipairs(L.boots()) do
      local r = b.a or b
      out[#out + 1] = { name = b.owner or b.file, kind = 'boot', on = b.on ~= false, file = b.file,
                        state = b.on == false and (r.state == 'stopped' and 'stopped' or 'off') or 'running',
                        why = r.why, errors = b.errors or 0, title = b.title, full_access = r.full_access == true }
    end
    -- (on and errors are the other loader's to know: nil)
    for _, g in ipairs(L.guests and L.guests() or {}) do
      out[#out + 1] = { name = g.name, kind = 'guest addon', file = g.file, state = g.state or ('run by ' .. g.loader),
                        why = g.why or 'it sits in the patch of another mod loader, which starts it' }
    end
    return out
  end
  local function field(v) return (tostring(v == nil and '' or v):gsub('[\t\r\n]', ' ')) end
  function util.health_text()
    local out = { 'name\tstate\twhy\tkind\tversion\terrors\tms_avg\tms_max\tfull_access\tfile' }
    for _, m in ipairs(util.mod_list()) do
      out[#out + 1] = concat({ field(m.name), field(m.state), field(m.why), field(m.kind), field(m.version), field(m.errors),
        m.ms_avg and fmt('%.3f', m.ms_avg) or '', m.ms_max and fmt('%.2f', m.ms_max) or '', m.full_access and 'yes' or '',
        field(m.file) }, '\t')
    end
    return concat(out, '\n') .. '\n'
  end
  -- written whole to a .tmp and put in place, like the settings
  function util.write_health()
    local path = ctx.DIR .. ctx.FILES .. '_health.txt'
    local tmp = L.os and path .. '.tmp' or path
    local f = ctx.open(tmp, 'w')
    if not f then return false end
    local okw = io_ok(pcall(f.write, f, util.health_text()))
    local okc = io_ok(pcall(f.close, f))
    if not (okw and okc) then return false end
    if tmp == path then return true end
    return util.replace(tmp, path)
  end

  -- is this a key name the keyboard knows
  function util.known_key(name) return type(name) == 'string' and L.key_index ~= nil and L.key_index(name) ~= nil end

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
    -- Compacted in place: a timer kept moves down to j (never past where the walk is), and the tail is cleared after
    -- the walk, so the list stays whole while timers run. Each runs in its own pcall (run), and its error is logged
    -- through err_text, so one mod's timer can't stop the others'.
    tsched.dirty = false                   -- (a mod stopping while they run sets it again)
    local n, j, nxt = #timers, 0, huge
    for i = 1, n do
      local t = timers[i]
      if t.on and t.a.on then
        if now >= t.at then
          -- (an after timer is done before it runs: a raise can't make it run twice)
          if not t.every then t.on = false end
          local ok = run(t.a, t.every and 'every' or 'after', t.fn)
          if not ok then t.errors = t.errors + 1 end
          if t.every then
            if t.errors < 20 then t.at = max(t.at + t.every, now) else t.on = false end
          end
        end
        if t.on then
          j = j + 1; timers[j] = t
          if t.at < nxt then nxt = t.at end
        end
      end
    end
    for i = n, j + 1, -1 do timers[i] = nil end
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
        -- one time stamp pair for the frame's batch, not one per item (two clock calls and the sums per item would be
        -- most of a cheap item's cost); each item still runs in its own pcall
        local t0, list, fn = L.clock(), j.list, j.fn
        for x = j.i + 1, last do
          local ok, err = pcall(fn, list[x], x)
          if not ok then j.errors = j.errors + 1; failed(j.a, 'spread', err) end
          if j.errors >= 20 then j.on = false; break end
        end
        account(j.a, (L.clock() - t0) * 1000)
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
    if util.monitor_frame then util.monitor_frame(now) end
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
  -- Engine triangles when the game draws them (L.tri: true when one was drawn); else rows of rects. A mod's numbers
  -- drive these, so anything that isn't a finite number draws nothing, and the rects only cover the screen: a shape
  -- far bigger than the screen costs what one the size of the screen does, never millions of rects.
  -- a span x0..x1 of one row, cut to the screen's width
  local function clip_rect(x0, x1, y, hgt, sw, c, layer)
    if x0 < 0 then x0 = 0 end
    if x1 > sw then x1 = sw end
    local l, r = floor(x0 + 0.5), floor(x1 + 0.5)
    if r > l then L.rect(l, y, r - l, hgt, c, layer) end
  end
  local function tri_spans(x1, y1, x2, y2, x3, y3, c, layer, step)
    -- sort by y, then fill one row of `step` pixels at a time, only the rows on the screen
    if y1 > y2 then x1, y1, x2, y2 = x2, y2, x1, y1 end
    if y1 > y3 then x1, y1, x3, y3 = x3, y3, x1, y1 end
    if y2 > y3 then x2, y2, x3, y3 = x3, y3, x2, y2 end
    if y3 - y1 < 0.5 then return end
    local sw, sh = ctx.screen()
    if not (finite(sw) and finite(sh)) then return end
    local function at(ya, xa, yb, xb, y) if yb == ya then return xa end return xa + (xb - xa) * (y - ya) / (yb - ya) end
    local y, top = max(floor(y1), 0), min(y3, sh)
    step = max(step, ceil((top - y) / 4096))       -- (a screen taller than 4096 px gets thicker rows)
    while y < top do
      local ym = y + step / 2
      local xa = at(y1, x1, y3, x3, ym)
      local xb = ym < y2 and at(y1, x1, y2, x2, ym) or at(y2, x2, y3, x3, ym)
      if xa > xb then xa, xb = xb, xa end
      if xb - xa >= 0.5 then clip_rect(xa, xb, y, step, sw, c, layer) end
      y = y + step
    end
  end
  local function triangle(x1, y1, x2, y2, x3, y3, c, layer)
    if not c then return end
    if not (finite(x1) and finite(y1) and finite(x2) and finite(y2) and finite(x3) and finite(y3)) then return false end
    if L.tri(x1, y1, x2, y2, x3, y3, c, layer) then return true end
    tri_spans(x1, y1, x2, y2, x3, y3, c, layer, 1)
    return false
  end
  util.triangle = triangle
  -- angles in degrees, 0 = up, clockwise (like a compass)
  local function polar(cx, cy, r, deg) local a = deg * pi / 180; return cx + r * sin(a), cy + r * cos(a) end
  local function segments(r, sweep_deg) return max(3, min(96, ceil(max(12, r * 0.6) * sweep_deg / 360))) end
  -- an annulus piece from a0 to a1 (degrees), r_in may be 0
  local function arc(cx, cy, r_in, r_out, a0, a1, c, layer)
    if not c then return end
    if not (finite(cx) and finite(cy) and finite(r_in) and finite(r_out) and finite(a0) and finite(a1)) then return end
    if r_in < 0 then r_in = 0 end
    if r_out <= 0 or r_in >= r_out then return end
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
    -- rects: a full disc or ring row by row (about 96 rows, the ones on the screen); a part of one as small squares
    -- along its middle (720 at most, the ones on the screen)
    local sw, sh = ctx.screen()
    if not (finite(sw) and finite(sh)) then return end
    local step = max(1, ceil(r_out / 48))
    if span >= 360 then
      local y, last = -r_out, min(r_out, sh - cy)
      if y < -cy - step then y = -r_out + floor((r_out - cy - step) / step) * step end
      while y < last do
        local ym = y + step / 2
        local wo = sqrt(max(0, r_out * r_out - ym * ym))
        if r_in > 0 and math.abs(ym) < r_in then
          local wi = sqrt(max(0, r_in * r_in - ym * ym))
          clip_rect(cx - wo, cx - wi, floor(cy + y), step, sw, c, layer)
          clip_rect(cx + wi, cx + wo, floor(cy + y), step, sw, c, layer)
        elseif wo >= 0.5 then
          clip_rect(cx - wo, cx + wo, floor(cy + y), step, sw, c, layer)
        end
        y = y + step
      end
    else
      local th = max(1, r_out - r_in)
      local rm = (r_out + r_in) / 2
      local k = min(720, max(2, ceil(rm * span * pi / 180 / max(1, th * 0.6))))
      local half = th / 2
      for i = 0, k do
        local x, y = polar(cx, cy, rm, a0 + span * i / k)
        if x + half >= 0 and x - half <= sw and y + half >= 0 and y - half <= sh then
          L.rect(floor(x - half + 0.5), floor(y - half + 0.5), ceil(th), ceil(th), c, layer)
        end
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
    function chef.unit_kind(u) if current(u) then return unit_kind(u, owner) end end
    function chef.unit_alive(u)
      if not current(u) then return false end
      return base_call('Unit.alive', u) == true
    end
    local function asked(name, u, ...)
      if not current(u) then return nil end
      local k = unit_kind(u, owner)
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
      local k = unit_kind(u, owner)
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
      if type(res) == 'string' and #res == 16 and res:match('^%x+$') then
        return guarded(owner, 'IdString64.from_hex', fn_of('IdString64.from_hex'), res:lower())
      end
      return res
    end
    function chef.spawn(res, x, y, z)
      if not world.stable then return nil, 'no world yet' end
      local id = id_of(res)
      if id == nil then return nil, 'no id' end
      if guarded(owner, 'Application.can_get', fn_of('Application.can_get'), 'unit', id) ~= true then return nil, 'unit ' .. tostring(res) .. ' is not loaded' end
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
      local k = current(u) and unit_kind(u, owner)
      if not k or BAD_KINDS[k] then return 0 end
      local n = base_call_kind('Unit.num_lights', k, u)
      return type(n) == 'number' and n or 0
    end
    function chef.light(u, i)
      local L2 = {}
      local function get()
        local k = current(u) and unit_kind(u, owner)
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
      if #timers + #incoming >= 512 then once('timers:' .. owner, fmt('[%s] timers: 512 running already (all mods together); no more', owner)); return nil end
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

    -- 7 tables saved between launches (one file per mod and name, next to the loader's log; M.data_name)
    local function data_file(name)
      if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 48 then return nil end
      local file = M.data_name(owner, name)
      return file and ctx.DIR .. file
    end
    local function parse(text, name)
      if type(text) ~= 'string' or #text > 256 * 1024 then return nil, 'too big' end
      -- text only: compiled Lua can be made to reach outside any environment
      if text:byte(1) == 27 then return nil, 'not a saved table' end
      local chunk, err = loadstring(text, '=' .. name)
      if not chunk then return nil, err_text(err) end
      setfenv(chunk, {})               -- plain data: it runs with nothing to reach
      local ok, t = pcall(chunk)
      if ok and type(t) == 'table' then return t end
      return nil, ok and 'not a table' or err_text(t)
    end
    local function read_text(path)
      local f = ctx.open(path, 'r') or ctx.open(path .. '.tmp', 'r')
      if not f then return nil end
      local ok, text = pcall(f.read, f, '*a')
      pcall(f.close, f)
      return ok and text or nil
    end
    -- the file written whole to .tmp and put in place (straight in place without os); false and why when any part
    -- of it failed, the old file kept
    local function write_file(path, text)
      local tmp = L.os and path .. '.tmp' or path
      local f = ctx.open(tmp, 'w')
      if not f then return false, 'could not write ' .. tmp end
      local okw = io_ok(pcall(f.write, f, text))
      local okc = io_ok(pcall(f.close, f))
      if not (okw and okc) then
        if L.os and tmp ~= path then pcall(L.os.remove, tmp) end
        return false, 'could not write ' .. tmp
      end
      if tmp == path then return true end
      return util.replace(tmp, path)
    end
    -- The old name isn't one to one (mods/a/b's "c_x" and mods/a/b_c's "x" are one file). An old file is read (and
    -- copied to the new name) only when no other mod the loader found (started yet or not) could have made it; it is
    -- left where it is, so a mod that names itself after another can't take that mod's table away.
    local function old_name_mine(name)
      local mid = M.old_data_name(owner, name):sub(11, -5)
      for _, o in ipairs(L.found and L.found() or {}) do
        if type(o) == 'string' and o ~= owner then
          local p = o:gsub('^mods/', ''):gsub('[^%w_%-]', '_') .. '_'
          if #mid > #p and mid:sub(1, #p) == p then return false end
        end
      end
      return true
    end
    function chef.save_table(name, t)
      local path = data_file(name)
      if not path then return false, 'names are letters, digits, _ - (48 at most)' end
      if type(t) ~= 'table' then return false, 'only a table' end
      local ok, text = pcall(M.serialize, t)
      if not ok then return false, err_text(text) end
      if #text > 256 * 1024 then return false, 'more than 256 KB' end
      return write_file(path, 'return ' .. text .. '\n')
    end
    function chef.load_table(name)
      local path = data_file(name)
      if not path then return nil, 'bad name' end
      local text = read_text(path)
      if text then return parse(text, name) end
      -- not saved under its name yet: the earlier name, here or in the old folder (%LOCALAPPDATA%)
      local old = M.old_data_name(owner, name)
      local here = ctx.DIR .. old
      text = read_text(here)
      if not text and ctx.OLD_DIR then text = read_text(ctx.OLD_DIR .. old) end
      if not text then return nil, 'none saved' end
      if not old_name_mine(name) then
        once('old_data:' .. owner .. name, fmt('[%s] load_table %s: an older saved table could be another mod\'s too; not read', owner, name))
        return nil, 'none saved'
      end
      local t, err = parse(text, name)
      if t then write_file(path, text) end   -- the old file stays (see old_name_mine)
      return t, err
    end

    -- 8 the mods the loader found
    function chef.mods() return util.mod_list() end
  end

  -- the frame budget behind chef.budget: the loader's own "Budget warning (ms)" row (util.budget_row, set by the
  -- loader), 2 ms until it's there
  util.default_budget = function() return util.budget_row and util.budget_row.value or 2.0 end

  -- ---------------------------------------------------------------- the performance monitor
  -- The loader's "Performance monitor" row (util.perf_row, off by default): a panel in the top right with each mod's
  -- cost. Every mod's time (its hooks, timers and spread work) goes into a.pm_ms / a.pm_max as it runs, a boot
  -- script's into b.pm_ms (and an HD2-Boot mod's timers, spread work and callbacks into its own record, b.a, shown on
  -- the same line), and the loader's own share of its update into pm.loader (all from the loader). Once a second I turn the last second into averages a frame: each mod's
  -- milliseconds and its share of the frame (from the game's own frame time), the worst single call, and the total.
  -- Off, it costs one check a frame; nothing is drawn or added up. Its own drawing (the loader's pixel font is rects,
  -- a few hundred a frame) is timed apart and shown on its own line, so it never counts against the loader or a mod.
  local pm = { on = false, at = 0, frames = 0, t0 = 0, loader = 0, self = 0, lines = nil }
  util.pm = pm
  -- the mods' time so far (the loader asks before and after its update, to find its own share)
  function util.pm_sum()
    local s = 0
    for _, a in ipairs(L.addons) do s = s + (a.pm_ms or 0) end
    for _, b in ipairs(L.boots()) do s = s + (b.pm_ms or 0) + (b.a and b.a ~= b and b.a.pm_ms or 0) end
    return s
  end
  local function pm_reset(now)
    pm.at, pm.frames, pm.t0, pm.loader, pm.self = now + 1, 0, now, 0, 0
    -- the time counters keep running (the loader reads them before and after its update, which can straddle this);
    -- each window starts from where they stand
    for _, a in ipairs(L.addons) do a.pm_base, a.pm_max = a.pm_ms or 0, 0 end
    for _, b in ipairs(L.boots()) do
      b.pm_base, b.pm_max = b.pm_ms or 0, 0
      if b.a and b.a ~= b then b.a.pm_base, b.a.pm_max = b.a.pm_ms or 0, 0 end
    end
  end
  local function plain(t) return (tostring(t):upper():gsub('[^A-Z0-9%.,:%-%+/%%%(%)!%? ]', ' ')) end
  -- a boot script's name: an HD2-Boot mod's name, else its first comment line up to a bracket, else its patch file
  local function boot_name(b)
    if b.a and type(b.a.short) == 'string' then return b.a.short end      -- an HD2-Boot mod: its own name
    local t = b.title and b.title:match('^([^%(%[]+)')
    t = t and t:gsub('%s+$', '') or ''
    return t ~= '' and t ~= 'no title' and t or ('BOOT ' .. tostring(b.file or '?'))
  end
  local function pm_lines(now)
    local n = max(1, pm.frames)
    local frame_ms = (now - pm.t0) * 1000 / n
    local rows, total = {}, 0
    for _, a in ipairs(L.addons) do
      local avg = ((a.pm_ms or 0) - (a.pm_base or 0)) / n
      total = total + avg
      rows[#rows + 1] = { name = a.short or a.name, avg = avg, worst = a.pm_max or 0, on = a.on }
    end
    for _, b in ipairs(L.boots()) do
      local a = b.a ~= b and b.a or nil
      local avg = ((b.pm_ms or 0) - (b.pm_base or 0) + (a and (a.pm_ms or 0) - (a.pm_base or 0) or 0)) / n
      local worst = max(b.pm_max or 0, a and a.pm_max or 0)
      total = total + avg
      -- a file-mod installer boot (a helper several mods ship, not a mod a player picks) gets no row of its own; its
      -- time still counts in All Mods
      local name = boot_name(b)
      if not name:lower():find('file%-mod installer') then
        rows[#rows + 1] = { name = name, avg = avg, worst = worst, on = b.on ~= false }
      end
    end
    sort(rows, function(x, y) if x.avg ~= y.avg then return x.avg > y.avg end return x.name < y.name end)
    local self = pm.self / n
    local loader = max(0, pm.loader / n - self)
    local function pct(ms) return frame_ms > 0 and ms / frame_ms * 100 or 0 end
    -- { left, right, color }: 1 header, 2 frame line, 3 total, 4 a mod, 5 a heavy mod (1 ms or more), 6 off or dim
    local out = {
      { fmt('FRAME %.1f MS  %d FPS', frame_ms, frame_ms > 0 and floor(1000 / frame_ms + 0.5) or 0), 'MS  SHARE WORST', 2 },
      { 'ALL MODS', fmt('%.2f %4.1f%%', total + loader, pct(total + loader)), 3 },
    }
    for i, r in ipairs(rows) do
      if i > 12 then break end
      out[#out + 1] = { plain(r.name):sub(1, 20), r.on and fmt('%.2f %4.1f%% %4.1f', r.avg, pct(r.avg), r.worst) or 'OFF',
                        r.on and (r.avg >= 1 and 5 or 4) or 6 }
    end
    out[#out + 1] = { 'LOADER', fmt('%.2f %4.1f%%', loader, pct(loader)), 4 }
    out[#out + 1] = { 'THIS MONITOR', fmt('%.2f %4.1f%%', self, pct(self)), 6 }
    return out
  end
  -- The panel, laid out once a second (when its numbers change) into a list of rects with a color index each; every
  -- frame only makes the few colors and draws the rects. The look matches the options menu: a dark panel in a thin
  -- yellow frame with a yellow bar on top, the title in yellow.
  local PM_COLORS = { { 255, 231, 16, 255 }, { 150, 255, 180, 255 }, { 255, 255, 255, 255 }, { 220, 222, 216, 255 },
                      { 255, 150, 90, 255 }, { 125, 135, 127, 255 }, { 9, 11, 10, 235 }, { 255, 231, 16, 150 } }
  -- The layout is the panel's 5 rects and one text per column of a line ({ x, y, text, color index }); each frame I
  -- draw them through ctx.text, whose fast path takes a whole text through one pcall.
  local function pm_layout(ls, w, h)
    local px = max(2, floor(h / 540 + 0.5))
    local rh, cols = 10 * px, 38
    local pw, ph = (cols * 6 + 10) * px, (#ls + 1) * rh + 5 * px
    local x0, y1 = w - pw - floor(w * 0.02), floor(h * 0.96)        -- top right, clear of the options menu (top left)
    local b = max(1, floor(px * 0.75))
    local out = { px = px, rects = {
      { x0, y1 - ph, pw, ph, 7 },                                                   -- panel
      { x0, y1 - ph, pw, b, 8 }, { x0, y1 - ph, b, ph, 8 }, { x0 + pw - b, y1 - ph, b, ph, 8 },   -- frame
      { x0, y1 - 2 * px, pw, 2 * px, 1 },                                           -- the yellow bar on top
    }, texts = {} }
    local function txt(x, y, s, ci) out.texts[#out.texts + 1] = { x, y, s, ci } end
    local tx = 5 * px
    txt(x0 + tx, y1 - rh - px, 'PERFORMANCE MONITOR', 1)
    local y = y1 - 2 * rh - px
    for _, l in ipairs(ls) do
      txt(x0 + tx, y + px, l[1], l[3])
      if l[2] ~= '' then txt(x0 + pw - tx - (#l[2] * 6 * px - px), y + px, l[2], l[3] == 2 and 6 or l[3]) end
      y = y - rh
    end
    return out
  end
  function util.monitor_frame(now)
    local on = util.perf_row ~= nil and util.perf_row.value == true
    if on ~= pm.on then
      pm.on, pm.lines, pm.rects = on, nil, nil
      if on then pm_reset(now) end
      log(on and 'performance monitor: on (each mod\'s average a frame, its share of the frame and its worst call; once a second)'
        or 'performance monitor: off')
    end
    if not on then return end
    pm.frames = pm.frames + 1
    if now >= pm.at and pm.frames > 0 then pm.lines, pm.rects = pm_lines(now), nil; pm_reset(now) end
    if not pm.lines then return end
    local t0 = L.clock()
    local w, h = ctx.screen()
    if not pm.rects or pm.w ~= w or pm.h ~= h then pm.rects, pm.w, pm.h = pm_layout(pm.lines, w, h), w, h end
    local cs = pm.cs or {}
    pm.cs = cs
    for i, c in ipairs(PM_COLORS) do cs[i] = ctx.color(c[1], c[2], c[3], c[4]) end
    local top = ctx.TOP + 940
    local lay = pm.rects
    for _, r in ipairs(lay.rects) do ctx.rect(r[1], r[2], r[3], r[4], cs[r[5]], r[5] == 7 and top or top + 2) end
    for _, t in ipairs(lay.texts) do ctx.text(t[1], t[2], t[3], lay.px, cs[t[4]], top + 2) end
    pm.self = pm.self + (L.clock() - t0) * 1000
  end

  util.caps = { units = true, spawn = true, timers = true, budget = true, session = true, settings_file = true,
                shapes = true, sprite_sheets = true, notify = true, typed = true, key_labels = true, save_table = true,
                mods = true, health = true }
  return util
end

return M
