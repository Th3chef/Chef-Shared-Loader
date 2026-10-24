-- Chef Shared Loader: shared services
-- What every mod gets on top of the basic helpers, so a mod doesn't have to build these
-- itself:
--   * after_startup(fn), a read-only capabilities table, has(name)
--   * a log file of its own per mod (own_log), saved settings per mod (one file next to the log), shared values and
--     events between mods, require() of another mod's exports with version requirements ("-- HD2-Requires:" lines)
--   * key bindings players can change, with conflicts flagged
--   * an in-game options menu (F9 by default) listing every mod's options and bindings, saved between launches
--   * look-alikes of CowboyBingusModLoader and ModOptionsMenu, so Lua-only mods written for them run
--   * dev mode (test builds of the loader only): mods loaded from loose files listed in chef_loader_dev.txt, reloaded
--     with a key
-- It only reaches the loader through the ctx table install() is given. Lua 5.1 syntax only.

local M = { version = '0.1.1', api = 3 }

local pairs, ipairs, pcall, type, tostring, tonumber, next = pairs, ipairs, pcall, type, tostring, tonumber, next
local floor, max, min = math.floor, math.max, math.min
local fmt, concat, sort = string.format, table.concat, table.sort

-- "1.2.10" -> comparable parts; anything that isn't a number counts as 0
local function vparts(v)
  local t = {}
  -- (a version is a string or a number; anything else a mod put there counts as none)
  local s = (type(v) == 'string' or type(v) == 'number') and tostring(v) or ''
  for n in s:gmatch('%d+') do t[#t + 1] = tonumber(n) end
  return t
end
function M.version_at_least(have, want)
  local a, b = vparts(have), vparts(want)
  for i = 1, max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then return x > y end
  end
  return true
end

-- "-- HD2-Requires: mods/x/lib >= 1.2" (or "chef-shared-loader >= 1.0", also "chef-loader"), lines near the top
function M.requirements(src)
  local out = {}
  -- (spaces and tabs only between the name and its version: a line without one must not reach into the next line)
  for name, want in src:sub(1, 1200):gmatch('\n%-%- HD2%-Requires: ([%w_/%.%-]+)[ \t]*>?=?[ \t]*([%d%.]*)') do
    out[#out + 1] = { name = name, version = want ~= '' and want or nil }
  end
  return out
end

-- Dependencies first, then the given order; a cycle or a missing requirement is reported, never looped on.
function M.order(list)
  local by, out, state = {}, {}, {}
  for _, r in ipairs(list) do if not by[r.name] then by[r.name] = r end end
  local function visit(r, depth)
    if state[r] == 'done' or depth > 32 then return end
    if state[r] == 'busy' then r.cycle = true; return end
    state[r] = 'busy'
    for _, q in ipairs(M.requirements(r.src)) do
      local d = by[q.name]
      if d and d ~= r then visit(d, depth + 1) end
    end
    state[r] = 'done'
    out[#out + 1] = r
  end
  for _, r in ipairs(list) do visit(r, 0) end
  return out
end

-- the pixel font has capitals, digits and . , : - + / % ( ) ! ? only
local function plain(s)
  s = tostring(s or ''):upper()
  return (s:gsub('[^A-Z0-9%.,:%-%+/%%%(%)!%?<> ]', ' '))
end

-- A mod's error as text for the log. tostring alone can raise (an error object whose __tostring errors or doesn't
-- return a string), and that must never stop the other mods' callbacks.
local function err_text(e)
  if type(e) == 'string' then return e end
  local ok, s = pcall(tostring, e)
  if ok and type(s) == 'string' then return s end
  return '(an error that can not be shown as text)'
end
M.err_text = err_text
-- a file write or close went through: pcall's ok, then what the call answered (nil and why when it failed)
local function io_ok(ok, r, e)
  if not ok or r == false then return false end
  return not (r == nil and e ~= nil)
end
M.io_ok = io_ok
-- Windows' device names: a file "con.log" is the console, not a file
local DEVICES = { con = true, prn = true, aux = true, nul = true, ['clock$'] = true, ['conin$'] = true, ['conout$'] = true }
for n = 0, 9 do DEVICES['com' .. n] = true; DEVICES['lpt' .. n] = true end
-- the keys the options menu itself uses: none of them can be the key that opens it
local MENU_KEYS = { enter = true, ['numpad enter'] = true, up = true, down = true, left = true, right = true,
                    backspace = true, escape = true, delete = true, ['page up'] = true, ['page down'] = true }

function M.install(ctx)
  local svc = { ctx = ctx }
  local log, guarded, fn_of = ctx.log, ctx.guarded, ctx.fn_of
  local SETTINGS_FILE, DEV_FILE = ctx.DIR .. ctx.FILES .. '_settings.txt', ctx.DIR .. ctx.FILES .. '_dev.txt'

  -- ---------------------------------------------------------------- saved settings
  -- One file next to the log: "<mod>\t<key>\t<b|n|s>\t<value>" per line. Written at most every 3 s while something
  -- changed, and at shutdown. It's written whole to a .tmp first and then put in place, so a full or locked disk never
  -- leaves it cut short; a write that didn't go through is tried again 3 s later.
  local store, dirty, save_at = {}, false, 0
  local saving = { failed = 0 }
  do
    -- (only the .tmp is there when the game ended between taking the old file away and putting the new one in place)
    local f = ctx.open(SETTINGS_FILE, 'r') or ctx.open(SETTINGS_FILE .. '.tmp', 'r')
    if f then
      local UNESCAPE = { n = '\n', t = '\t', ['\\'] = '\\' }
      for line in f:lines() do
        local mod, key, ty, v = line:match('^([^\t]+)\t([^\t]+)\t([bns])\t(.*)$')
        if mod then
          local val
          -- strings: one pass over the escapes, so "C:\new" (saved as C:\\new) comes back as it was
          if ty == 'b' then val = v == 'true' elseif ty == 'n' then val = tonumber(v) else val = (v:gsub('\\(.)', UNESCAPE)) end
          if val ~= nil then store[mod] = store[mod] or {}; store[mod][key] = val end
        end
      end
      f:close()
    end
  end
  -- a number as text that reads back as the same number (tostring alone keeps 14 digits)
  local function num_text(v)
    local s = tostring(v)
    if tonumber(s) == v then return s end
    return fmt('%.17g', v)
  end
  local function save_now()
    -- with the utilities there (always, in the game) I write it to .tmp and put it in place; without them, in place
    local replace = svc.util and svc.util.replace
    local tmp = SETTINGS_FILE .. '.tmp'
    local f = ctx.open(replace and tmp or SETTINGS_FILE, 'w')
    local ok = f ~= nil
    if f then
      local mods = {}
      for m in pairs(store) do mods[#mods + 1] = m end
      sort(mods)
      for _, m in ipairs(mods) do
        local keys = {}
        for k in pairs(store[m]) do keys[#keys + 1] = k end
        sort(keys)
        for _, k in ipairs(keys) do
          local v = store[m][k]
          local ty = type(v) == 'boolean' and 'b' or (type(v) == 'number' and 'n' or 's')
          local text = ty == 's' and (v:gsub('\\', '\\\\'):gsub('\n', '\\n'):gsub('\t', '\\t')) or (ty == 'n' and num_text(v) or tostring(v))
          if ok then ok = io_ok(pcall(f.write, f, m, '\t', k, '\t', ty, '\t', text, '\n')) end
        end
      end
      ok = io_ok(pcall(f.close, f)) and ok
      if ok and replace then ok = replace(tmp, SETTINGS_FILE) end
    end
    if ok then
      dirty = false
      if saving.failed > 0 then log('settings saved again'); saving.failed = 0 end
    else
      saving.failed = saving.failed + 1
      if saving.failed == 1 then log('the settings could not be saved to ' .. SETTINGS_FILE .. '; trying again every 3 s') end
    end
    return ok
  end
  local function put(mod, key, v)
    if type(key) ~= 'string' or not key:match('^[%w_%.%-]+$') or #key > 64 then return false, 'keys are letters, digits, _ . - (64 at most)' end
    local t = type(v)
    if v ~= nil and t ~= 'boolean' and t ~= 'number' and t ~= 'string' then return false, 'only booleans, numbers and strings are saved' end
    if t == 'string' and #v > 512 then return false, 'strings are saved up to 512 characters' end
    if t == 'number' and (v ~= v or v == math.huge or v == -math.huge) then return false, 'only finite numbers are saved' end
    store[mod] = store[mod] or {}
    if store[mod][key] ~= v then store[mod][key] = v; dirty = true end
    return true
  end
  local function get(mod, key, default)
    local t = store[mod]
    local v = t and t[key]
    if v == nil then return default end
    return v
  end

  -- ---------------------------------------------------------------- after_startup, shared values, events
  -- I time a mod's callbacks (events, on_change, after_startup) as that mod's own (its record, from extend), so the
  -- performance monitor and its frame budget count them for it, not for the loader.
  local recs = {}
  local function call_as(owner, fn, ...)
    local a, u = recs[owner], svc.util
    if a and u then return u.timed(a, fn, ...) end
    return pcall(fn, ...)
  end
  -- a mod's own call that runs other mods' callbacks (emit, set): their time already went to them, so it comes off
  -- the caller's, which its hook or timer counts whole
  local function as_caller(a, fn, ...)
    local u = svc.util
    if not u then return fn(...) end
    local t0 = u.clock()
    local r = fn(...)
    u.discount(a, (u.clock() - t0) * 1000)
    return r
  end
  local after, started = {}, false
  local function after_startup(owner, fn)
    if type(fn) ~= 'function' then return false, 'after_startup needs a function' end
    if started then
      local ok, err = call_as(owner, fn)
      if not ok then log(fmt('[%s] after_startup: %s', owner, err_text(err))) end
      return true
    end
    if #after >= 256 then return false, 'after_startup: 256 callbacks already registered' end
    after[#after + 1] = { owner = owner, fn = fn }
    return true
  end
  local shared = {}
  local subs = {}                           -- event -> { { owner, fn, on, errors }, ... }
  -- Ended subscriptions leave the lists right away, except while an emit is walking them: then at the end of it.
  local emitting, stale = 0, {}
  local function compact(event)
    local list = subs[event]
    if not list then return end
    local j = 0
    for i = 1, #list do
      local sb = list[i]
      list[i] = nil
      if sb.on then j = j + 1; list[j] = sb end
    end
    if j == 0 then subs[event] = nil end
  end
  local function ended(event)
    if emitting > 0 then stale[event] = true else compact(event) end
  end
  local function emit(event, ...)
    local list = subs[event]
    if not list then return 0 end
    local n = 0
    emitting = emitting + 1
    for i = 1, #list do
      local sb = list[i]
      if sb and sb.on then
        local ok, err = call_as(sb.owner, sb.fn, ...)
        n = n + 1
        if not ok then
          sb.errors = sb.errors + 1
          if sb.errors <= 3 then log(fmt('[%s] event %s: %s', sb.owner, event, err_text(err))) end
          if sb.errors >= 20 then sb.on = false; stale[event] = true; log(fmt('[%s] event %s: switched off after 20 errors', sb.owner, event)) end
        end
      end
    end
    emitting = emitting - 1
    if emitting == 0 and next(stale) then
      for e in pairs(stale) do compact(e) end
      stale = {}
    end
    return n
  end
  svc.emit = emit

  -- ---------------------------------------------------------------- options (the menu's rows) and key bindings
  -- groups: in the order mods first register; each group { title, mod, rows = { row, ... } }. A row: { id (full),
  -- key (saved under), spec, value, owner, changed = { fn, ... } }.
  local groups, group_of, rows_by_id = {}, {}, {}
  -- the menu's line list and the key users are kept until a row is added or moved (layout) or a binding changes (keys)
  local ver = { layout = 0, keys = 0 }
  local function group(mod, title)
    local g = group_of[mod]
    if not g then
      g = { mod = mod, title = title or mod, rows = {} }
      group_of[mod] = g; groups[#groups + 1] = g
      ver.layout = ver.layout + 1
    elseif title and g.title == mod then g.title = title; ver.layout = ver.layout + 1 end
    return g
  end
  -- The saved name of a row: 'opt.<id>' when the id is a plain one, else a hash of it, so any id saves (the look-alike
  -- takes ids with spaces, colons and the like). Two 31-bit hashes: string.format's %x only goes to 2^31 on Windows.
  local function row_key(id)
    if #id <= 60 and id:match('^[%w_%.%-]+$') then return 'opt.' .. id end
    local a, b = 5381, #id
    for i = 1, #id do
      local c = id:byte(i)
      a = (a * 33 + c) % 2147483647
      b = (b * 65599 + c) % 2147483647
    end
    return fmt('opt.h_%08x%08x', a, b)
  end
  -- a label, title or choice as text (a mod's function or odd value can't raise into the menu)
  local function text_of(v)
    if type(v) == 'function' then
      local ok, s = pcall(v)
      if not ok then return '?' end
      v = s
    end
    if type(v) == 'string' then return v end
    local ok, s = pcall(tostring, v or '')
    return ok and type(s) == 'string' and s or '?'
  end
  local function clean(spec, value)
    local ty = spec.type
    if ty == 'toggle' then return value == true end
    if ty == 'choice' then
      local n = #spec.choices
      local v = floor(tonumber(value) or 1)
      return (v >= 1 and v <= n) and v or 1
    end
    if ty == 'slider' then
      -- anything that isn't a number (a value saved when the row was something else, say) gives the default
      local v = tonumber(value) or tonumber(spec.default) or spec.min
      if v ~= v then v = spec.min end
      v = max(spec.min, min(spec.max, v))
      if spec.step and spec.step > 0 then v = spec.min + floor((v - spec.min) / spec.step + 0.5) * spec.step end
      -- (after the snap too: a step that doesn't divide the range would snap past max)
      return max(spec.min, min(spec.max, v))
    end
    if ty == 'key' then
      local k = type(value) == 'string' and value or 'off'
      -- the menu's own key is never none or one of the keys the menu uses (it could never be opened again)
      if spec.menu and (k == 'off' or MENU_KEYS[k]) then return spec.default end
      return k
    end
    return value
  end
  local function finite(n) return type(n) == 'number' and n == n and n > -math.huge and n < math.huge end
  local function check_spec(spec)
    if type(spec) ~= 'table' then return 'the spec must be a table' end
    local ty = spec.type
    if ty ~= 'toggle' and ty ~= 'choice' and ty ~= 'slider' and ty ~= 'key' then return 'type must be toggle, choice, slider or key' end
    if ty == 'choice' and (type(spec.choices) ~= 'table' or #spec.choices < 2 or #spec.choices > 32) then return 'a choice needs 2 to 32 choices' end
    if ty == 'slider' then
      if not (finite(spec.min) and finite(spec.max) and spec.max > spec.min) then return 'a slider needs min < max' end
      if spec.step ~= nil and not (finite(spec.step) and spec.step >= 0) then return 'a slider step is a number, 0 or more' end
    end
    return nil
  end
  local function add_row(owner, mod, title, id, spec)
    local err = check_spec(spec)
    if err then return nil, err end
    local full = mod .. '|' .. id
    local row = rows_by_id[full]
    if row then return row end
    local default = spec.default
    if spec.type == 'toggle' then default = default == true
    elseif spec.type == 'choice' then default = default or 1
    elseif spec.type == 'slider' then default = default or spec.min
    elseif spec.type == 'key' then default = default or 'off' end
    row = { id = full, key = row_key(id), mod = mod, spec = spec, owner = owner, changed = {} }
    row.default = clean(spec, default)
    row.value = clean(spec, get(mod, row.key, row.default))
    rows_by_id[full] = row
    local g = group(mod, title)
    g.rows[#g.rows + 1] = row
    ver.layout = ver.layout + 1
    if spec.type == 'key' then ver.keys = ver.keys + 1 end
    return row
  end
  local function set_row(row, v)
    v = clean(row.spec, v)
    if v == row.value then return end
    row.value = v
    if row.spec.type == 'key' then ver.keys = ver.keys + 1 end
    -- the default isn't stored (so a new default reaches players who never changed the row); anything else is, false too
    local ok, err
    if v == row.default then ok, err = put(row.mod, row.key, nil) else ok, err = put(row.mod, row.key, v) end
    if not ok then log(fmt('[%s] option %s not saved: %s', row.owner, row.id, tostring(err))) end
    -- each callback runs as the mod that asked for it ({ fn, owner, on }; a mod that stops has its own switched off)
    for _, c in ipairs(row.changed) do
      if c.on then
        local ok, err = call_as(c.owner, c.fn, v)
        if not ok then log(fmt('[%s] on_change %s: %s', c.owner, row.id, err_text(err))) end
      end
    end
  end
  local function on_change(row, owner, fn)
    if #row.changed >= 64 then return false end
    row.changed[#row.changed + 1] = { fn = fn, owner = owner, on = true }
    return true
  end
  -- every key some binding uses, for the conflict marks
  local users_cache = { ver = -1, users = nil }
  local function key_users()
    if users_cache.ver == ver.keys then return users_cache.users end
    local users = {}
    for _, g in ipairs(groups) do
      for _, row in ipairs(g.rows) do
        if row.spec.type == 'key' and row.value ~= 'off' then
          users[row.value] = (users[row.value] or 0) + 1
        end
      end
    end
    users_cache.ver, users_cache.users = ver.keys, users
    return users
  end
  local conflicts_said = {}
  local function note_conflicts()
    for k, n in pairs(key_users()) do
      if n > 1 and not conflicts_said[k] then
        conflicts_said[k] = true
        log(fmt('key %s is bound %d times (see the options menu: it marks them)', k, n))
      end
    end
  end

  -- ---------------------------------------------------------------- a mod's own log file
  -- chef.own_log(name): from then on the mod's chef.log lines go to <name>.log next to chef_loader.log instead of into
  -- it (a fresh file each launch once it passes 1 MB, the same cap per launch). The loader's own lines about the mod
  -- (started, errors, crashes, timings) stay in chef_loader.log.
  local own_logs = {}                       -- name -> { f, written, owner }
  local function own_open(owner, name)
    local o = own_logs[name]
    if o then
      if o.owner ~= owner then return nil, name .. '.log is ' .. o.owner .. "'s" end
      return o
    end
    local path = ctx.DIR .. name .. '.log'
    local f, big = ctx.open(path, 'r'), false
    if f then local size = f:seek('end'); big = size and size > 1024 * 1024; f:close() end
    f = ctx.open(path, big and 'w' or 'a')
    if not f then return nil, 'could not open ' .. path end
    o = { f = f, written = 0, owner = owner }
    own_logs[name] = o
    -- a log of the same name in the old folder (%LOCALAPPDATA%) gets one last line saying
    -- where the log went, once
    if ctx.OLD_DIR then
      local old = ctx.OLD_DIR .. name .. '.log'
      local g = ctx.open(old, 'r')
      if g then
        local size = g:seek('end') or 0
        g:seek('set', math.max(0, size - 300))
        local tail = g:read('*a') or ''
        g:close()
        if not tail:find('this log is no longer written', 1, true) then
          local w = ctx.open(old, 'a')
          if w then
            pcall(w.write, w, fmt('%s %s.log moved to %%APPDATA%%\\Arrowhead\\Helldivers2 with %s; this log is no longer written\n',
              ctx.clock(), name, ctx.LOADER))
            w:close()
          end
        end
      end
    end
    return o
  end
  local function own_write(o, text)
    if o.written > ctx.LOG_CAP then return end
    local line = fmt('%s %6.1f s | %s', ctx.clock(), ctx.now(), text)
    o.written = o.written + #line + 1
    if o.written > ctx.LOG_CAP then line = line .. '\n(the log is full for this launch)' end
    pcall(o.f.write, o.f, line .. '\n'); pcall(o.f.flush, o.f)
  end

  -- ---------------------------------------------------------------- the helpers each mod gets
  function svc.extend(chef, a)
    local owner = a.name
    local title = a.title
    recs[owner] = a
    chef.api = M.api
    local caps = { api = M.api, after_startup = true, settings = true, share = true, events = true, require = true,
                   bind = true, menu = true, shims = true, dev = true, logs = true, own_log = true }
    if svc.util then for k, v in pairs(svc.util.caps) do caps[k] = v end end
    -- this mod runs with the game's whole Lua ("-- HD2-Requires: full-access", the lockdown off)
    caps.full_access = a.full_access == true
    chef.capabilities = setmetatable({}, { __index = caps,
      __newindex = function() error('chef.capabilities is read-only', 2) end })
    function chef.has(name) return chef.capabilities[name] == true or (name == 'api' and true) end
    function chef.after_startup(fn) return after_startup(owner, fn) end
    -- saved settings
    function chef.save(key, value) return put(owner, key, value) end
    function chef.load(key, default) return get(owner, key, default) end
    -- shared values and events
    function chef.share(name, value)
      if type(name) ~= 'string' then return false end
      local was = shared[name]
      if was and was.owner ~= owner then log(fmt('[%s] replaced shared "%s" (it was %s\'s)', owner, name, was.owner)) end
      shared[name] = { owner = owner, value = value }
      return true
    end
    function chef.shared(name) local s = shared[name]; return s and s.value end
    -- returns a function that ends the subscription (the entry leaves the list)
    function chef.on(event, fn)
      if type(event) ~= 'string' or type(fn) ~= 'function' then return nil end
      subs[event] = subs[event] or {}
      local sb = { owner = owner, fn = fn, on = true, errors = 0 }
      subs[event][#subs[event] + 1] = sb
      return function()
        if sb.on then sb.on = false; ended(event) end
      end
    end
    function chef.emit(event, ...) if type(event) == 'string' then return as_caller(a, emit, event, ...) end end
    -- another mod's exports (the table it returned), optionally at a version or newer
    function chef.require(name, want)
      local other = ctx.addon(name)
      if not other or not other.on or type(other.module) ~= 'table' then return nil, name .. ' is not running' end
      if want and not M.version_at_least(other.version, want) then
        return nil, fmt('%s is %s, %s or newer is needed', name, tostring(other.version), want)
      end
      return other.module
    end
    -- the options menu: a group under the mod's title (chef.title, or its name)
    -- (a title set after the first option renames the group it made)
    function chef.title(t)
      if type(t) ~= 'string' then return end
      title = t
      local g = group(owner, t)
      if g.title ~= t then g.title = t; ver.layout = ver.layout + 1 end
    end
    function chef.option(id, spec)
      if type(id) ~= 'string' or not id:match('^[%w_%.%-]+$') then return nil, 'ids are letters, digits, _ . -' end
      local row, err = add_row(owner, owner, title or a.short, id, spec)
      if not row then log(fmt('[%s] option %s: %s', owner, id, err)); return nil, err end
      return row.value
    end
    function chef.get(id) local r = rows_by_id[owner .. '|' .. tostring(id)]; if r then return r.value end end
    function chef.set(id, v) local r = rows_by_id[owner .. '|' .. tostring(id)]; if r then as_caller(a, set_row, r, v); return r.value end end
    function chef.on_change(id, fn)
      local r = rows_by_id[owner .. '|' .. tostring(id)]
      if r and type(fn) == 'function' then return on_change(r, owner, fn) end
      return false
    end
    -- a key binding: a 'key' row in the menu; b.key() is its key ('off' for none), b.pressed() / b.down() this frame
    -- (key names are the engine's, in lower case: 'F6' is taken as 'f6'; a name the keyboard doesn't know is logged)
    function chef.bind(id, default_key, label)
      local dk = type(default_key) == 'string' and default_key:lower() or 'off'
      if dk ~= 'off' and svc.util and svc.util.known_key and not svc.util.known_key(dk) then
        log(fmt('[%s] bind %s: "%s" is not a key name the keyboard knows (players can pick another in the menu)', owner, tostring(id), dk))
      end
      local row = chef.option(id, { type = 'key', default = dk, label = label or id })
      local r = rows_by_id[owner .. '|' .. id]
      if not r then return nil end
      note_conflicts()
      local b = {}
      function b.key() return r.value end
      function b.pressed() return r.value ~= 'off' and chef.key_pressed(r.value) end
      function b.down() return r.value ~= 'off' and chef.key_down(r.value) end
      return b, row
    end
    chef.log_directory = ctx.DIR:gsub('\\$', '')
    chef.log_file = ctx.DIR .. ctx.FILES .. '.log'
    -- the loader's old folder (%LOCALAPPDATA%), so a mod can pick up its own old files
    -- once (mods may read their .log .txt .json .csv .dat files there); nil when nothing moved
    chef.previous_directory = ctx.OLD_DIR and ctx.OLD_DIR:gsub('\\$', '') or nil
    function chef.own_log(name)
      if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 48 or name:lower():find('^chef_loader') then
        return false, 'log names are letters, digits, _ - (48 at most), and not chef_loader'
      end
      local o, err = own_open(owner, name)
      if not o then log(fmt('[%s] own log: %s; its lines stay here', owner, tostring(err))); return false, err end
      if not o.said then
        o.said = true
        own_write(o, fmt('==== %s, run by %s %s', owner, ctx.LOADER, ctx.VERSION))
        log(fmt('[%s] logs to %s.log', owner, name))
      end
      function chef.log(...) local ok, s = pcall(fmt, ...); own_write(o, ok and s or tostring((...))) end
      chef.log_file = ctx.DIR .. name .. '.log'
      return true
    end
  end

  -- ---------------------------------------------------------------- the options menu (drawn over everything)
  -- Two levels: the mods (in alphabetical order), then the options of the one picked (in the mod's own order). A search
  -- shows every match across the mods at once. menu.group: the mod open now (nil: the list); menu.back: where the
  -- list's cursor was, so Backspace returns to it. (Escape closes the whole menu; Backspace goes back one level, so
  -- going back never touches the game's own Escape menu.)
  local menu = { open = false, sel = 1, top = 1, capture = nil, said = false, search = '', typing = false, group = nil, back = 1 }
  local loader_mod = '_loader'
  local menu_key = add_row('loader', loader_mod, ctx.LOADER, 'menu_key', { type = 'key', default = 'f9', label = 'Open this menu', menu = true })
  local reload_key = nil
  -- more rows in the loader's own group (the frame budget)
  function svc.loader_option(id, spec)
    local r, err = add_row('loader', loader_mod, ctx.LOADER, id, spec)
    if not r then log('loader option ' .. id .. ': ' .. tostring(err)) end
    return r
  end
  function svc.set_row(r, v) set_row(r, v) end
  function svc.menu_key_name() return menu_key.value end
  -- the mods with rows, by title in alphabetical order (case ignored; the mod's name breaks a tie)
  local function sorted_groups()
    local gs = {}
    for _, g in ipairs(groups) do if #g.rows > 0 then gs[#gs + 1] = g end end
    table.sort(gs, function(a, b)
      local ta, tb = text_of(a.title):lower(), text_of(b.title):lower()
      if ta ~= tb then return ta < tb end
      return a.mod < b.mod
    end)
    return gs
  end
  -- the lines shown: the list of mods; the open mod's options; or, with a search typed after '/', every mod whose
  -- title has it (whole) and every option whose label has it, under its mod's title
  local lines_cache = { ver = -1, search = nil, group = nil, out = nil }
  local function lines()
    if lines_cache.ver == ver.layout and lines_cache.search == menu.search and lines_cache.group == menu.group then
      return lines_cache.out
    end
    local out = {}
    local q = menu.search ~= '' and menu.search or nil
    -- every screen under the list starts with a Back row (to the list of mods)
    if q or menu.group then out[1] = { back = true, text = '< BACK' } end
    if q then
      for _, g in ipairs(sorted_groups()) do
        local whole = text_of(g.title):lower():find(q, 1, true) ~= nil
        local rows = {}
        for _, r in ipairs(g.rows) do
          if whole or text_of(r.spec.label or r.id):lower():find(q, 1, true) then rows[#rows + 1] = r end
        end
        if #rows > 0 then
          out[#out + 1] = { head = true, text = g.title }
          for _, r in ipairs(rows) do out[#out + 1] = { row = r } end
        end
      end
    elseif menu.group then
      for _, r in ipairs(menu.group.rows) do out[#out + 1] = { row = r } end
    else
      for _, g in ipairs(sorted_groups()) do out[#out + 1] = { pick = g, text = g.title } end
    end
    lines_cache.ver, lines_cache.search, lines_cache.group, lines_cache.out = ver.layout, menu.search, menu.group, out
    return out
  end
  local function value_text(r, users)
    local s, v = r.spec, r.value
    if s.type == 'toggle' then return v and 'ON' or 'OFF' end
    if s.type == 'choice' then return text_of(s.choices[v]) end
    if s.type == 'slider' then
      local st = s.step or 0
      return (st >= 1 or st == 0 and floor(v) == v) and tostring(floor(v + 0.5)) or fmt('%.2f', v)
    end
    if s.type == 'key' then
      if menu.capture == r then return 'PRESS A KEY' end
      return (v == 'off' and 'NONE' or v) .. ((v ~= 'off' and (users[v] or 0) > 1) and ' !' or '')
    end
    return tostring(v)
  end
  local function pressed(name) return ctx.key_pressed(name) end
  local function capture_key()
    -- any key pressed this frame, by its engine name (Escape cancels, Delete clears)
    local n = guarded('loader', 'Keyboard.num_buttons', fn_of('Keyboard.num_buttons'))
    if type(n) ~= 'number' then return nil end
    for i = 0, n - 1 do
      if guarded('loader', 'Keyboard.pressed', fn_of('Keyboard.pressed'), i) == true then
        local name = guarded('loader', 'Keyboard.button_name', fn_of('Keyboard.button_name'), i)
        if type(name) == 'string' and name ~= '' then return name end
      end
    end
  end
  -- the search: '/' starts typing; letters, digits and spaces go in, Backspace takes one off, Enter keeps it, Escape
  -- clears it (the typed text comes from Keyboard.keystrokes, through the utilities)
  local function search_input()
    local typed = svc.util and svc.util.typed() or ''
    if not menu.typing then
      if typed:find('/', 1, true) then menu.typing, menu.search, menu.sel, menu.top = true, '', 2, 1 end
      if menu.typing then menu.group = nil end
      return false
    end
    for ch in typed:gmatch('[%w ]') do
      if #menu.search < 20 then menu.search = menu.search .. ch:lower(); menu.sel, menu.top = 2, 1 end
    end
    if pressed('backspace') then menu.search = menu.search:sub(1, -2); menu.sel, menu.top = 2, 1 end
    if pressed('enter') then menu.typing = false end
    if pressed('escape') then menu.typing, menu.search, menu.sel, menu.top = false, '', 1, 1 end
    return true
  end
  -- back to the list of mods, where its cursor was (the Back row, or Backspace)
  local function go_back()
    if menu.group then menu.sel, menu.top = menu.back, 1 else menu.sel, menu.top = 1, 1 end
    menu.group, menu.search = nil, ''
  end
  local function menu_input(ls)
    if menu.capture then
      local k = capture_key()
      local r = menu.capture
      if k == 'escape' then menu.capture = nil
      -- Delete: none (the menu's own key goes back to its default instead)
      elseif k == 'delete' then set_row(r, r.spec.menu and r.default or 'off'); menu.capture = nil
      -- the menu's own key can't be one the menu uses: it keeps waiting for another
      elseif k and not (r.spec.menu and MENU_KEYS[k]) then set_row(r, k); menu.capture = nil; conflicts_said = {}; note_conflicts() end
      return
    end
    local n = #ls
    local function step(d)
      local i = menu.sel
      for _ = 1, n do
        i = i + d
        if i < 1 then i = n elseif i > n then i = 1 end
        if not ls[i].head then menu.sel = i; return end
      end
    end
    if ls[menu.sel] == nil or ls[menu.sel].head then step(1) end
    if pressed('down') then step(1) elseif pressed('up') then step(-1)
    elseif pressed('page down') then for _ = 1, 8 do step(1) end
    elseif pressed('page up') then for _ = 1, 8 do step(-1) end end
    local l = ls[menu.sel]
    -- a mod in the list: Enter (or Right) opens its options, the cursor on its first option (Back is just above it)
    if l and l.pick then
      if pressed('enter') or pressed('right') then menu.back, menu.group, menu.sel, menu.top = menu.sel, l.pick, 2, 1 end
      return
    end
    if l and l.back then
      if pressed('enter') or pressed('left') then go_back() end
      return
    end
    local r = l and l.row
    if not r then return end
    local s = r.spec
    local dir = pressed('right') and 1 or (pressed('left') and -1 or 0)
    if pressed('delete') then set_row(r, r.default); return end
    if s.type == 'toggle' and (dir ~= 0 or pressed('enter')) then set_row(r, not r.value)
    elseif s.type == 'choice' and dir ~= 0 then
      local v = r.value + dir
      if v < 1 then v = #s.choices elseif v > #s.choices then v = 1 end
      set_row(r, v)
    elseif s.type == 'slider' and dir ~= 0 then set_row(r, r.value + dir * ((s.step or 0) > 0 and s.step or (s.max - s.min) / 20))
    elseif s.type == 'key' and pressed('enter') then menu.capture = r end
  end
  -- The look: a dark panel in a yellow frame, the title on a yellow bar, the
  -- picked row lit with a yellow edge, values in green (OFF in gray), keys as light chips, the hints under a thin line.
  local function menu_draw(ls)
    local w, h = ctx.screen()
    local px = max(2, floor(h / 540 + 0.5))
    local top = ctx.TOP + 950
    local rh, cols = 12 * px, 40
    local pw = (cols * 6 + 10) * px
    local x0 = floor(w * 0.05)
    local visible = max(4, floor((h * 0.7) / rh) - 4)
    if menu.sel < menu.top then menu.top = menu.sel elseif menu.sel >= menu.top + visible then menu.top = menu.sel - visible + 1 end
    local shown = min(visible, #ls - menu.top + 1)
    local hb = rh + 2 * px                     -- the title bar
    local ph = hb + shown * rh + 3 * px + rh + 2 * px
    local y0 = floor(h * 0.85)                 -- the panel's top edge (y grows upward)
    local col = ctx.color
    local yellow, ink = col(255, 231, 16, 255), col(17, 17, 17, 255)
    local white, green, gray = col(232, 232, 226, 255), col(143, 224, 143, 255), col(125, 135, 127, 255)
    local tx = 7 * px                          -- the text's left inset
    local function midy(y, hgt) return y + floor((hgt - 7 * px) / 2) end
    -- panel, frame, title bar
    ctx.rect(x0, y0 - ph, pw, ph, col(9, 11, 10, 238), top)
    local b = max(1, floor(px * 0.75))
    ctx.rect(x0, y0 - ph, pw, b, yellow, top + 3); ctx.rect(x0, y0 - b, pw, b, yellow, top + 3)
    ctx.rect(x0, y0 - ph, b, ph, yellow, top + 3); ctx.rect(x0 + pw - b, y0 - ph, b, ph, yellow, top + 3)
    ctx.rect(x0, y0 - hb, pw, hb, yellow, top + 1)
    local head = menu.group and text_of(menu.group.title) or (ctx.LOADER .. ' OPTIONS')
    ctx.text(x0 + tx, midy(y0 - hb, hb), plain(head):sub(1, cols - 8), px, ink, top + 2)
    local right = (menu.typing or menu.search ~= '') and plain('/' .. menu.search .. (menu.typing and '_' or '')):sub(1, 22)
      or plain(menu_key.value ~= 'off' and menu_key.value or '')
    ctx.text(x0 + pw - tx - ctx.text_width(right, px), midy(y0 - hb, hb), right, px, ink, top + 2)
    local users = key_users()
    local y = y0 - hb - rh
    for i = menu.top, menu.top + shown - 1 do
      local l = ls[i]
      local sel = i == menu.sel and not l.head
      if sel then
        ctx.rect(x0 + b, y, pw - 2 * b, rh, col(255, 231, 16, 42), top + 1)
        ctx.rect(x0 + b, y, 2 * px, rh, yellow, top + 2)
      end
      local ty = midy(y, rh)
      if l.head then
        ctx.text(x0 + tx, ty, plain(l.text):sub(1, cols - 2), px, yellow, top + 2)
      elseif l.back then
        ctx.text(x0 + tx + 2 * px, ty, l.text, px, yellow, top + 2)
      elseif l.pick then
        ctx.text(x0 + tx + 2 * px, ty, plain(text_of(l.text)):sub(1, cols - 6), px, white, top + 2)
        ctx.text(x0 + pw - tx - ctx.text_width('>', px), ty, '>', px, green, top + 2)
      else
        local r = l.row
        ctx.text(x0 + tx + 2 * px, ty, plain(text_of(r.spec.label or r.id)):sub(1, 24), px, white, top + 2)
        local v = plain(value_text(r, users)):sub(1, 14)
        local vw = ctx.text_width(v, px)
        local vx = x0 + pw - tx - vw
        if r.spec.type == 'key' and menu.capture ~= r then
          -- a key: a light chip with the key's name in ink
          ctx.rect(vx - 2 * px, y + 2 * px, vw + 4 * px, rh - 4 * px, white, top + 2)
          ctx.text(vx, ty, v, px, ink, top + 3)
        else
          ctx.text(vx, ty, v, px, (r.spec.type == 'toggle' and not r.value) and gray or (menu.capture == r and yellow or green), top + 2)
        end
      end
      y = y - rh
    end
    -- the hints under a thin line
    ctx.rect(x0 + b, y0 - ph + rh + 2 * px, pw - 2 * b, max(1, floor(px / 2)), col(255, 231, 16, 70), top + 1)
    local hint = menu.capture and (menu.capture.spec.menu and 'PRESS A KEY  ESC CANCEL  DEL DEFAULT' or 'PRESS A KEY  ESC CANCEL  DEL NONE')
      or (menu.typing and 'TYPE TO SEARCH  ENTER KEEP  ESC CLEAR')
      or ((menu.group or menu.search ~= '') and 'ARROWS  ENTER  DEL DEFAULT  BKSP BACK')
      or ('ARROWS  ENTER OPEN  / SEARCH  ' .. (svc.util and svc.util.key_label(menu_key.value) or menu_key.value) .. ' CLOSE')
    ctx.text(x0 + tx, midy(y0 - ph + px, rh), plain(hint):sub(1, cols), px, gray, top + 2)
  end
  local function menu_frame()
    local mk = menu_key.value
    if menu.open and menu.capture == nil and not menu.typing and pressed('backspace') and (menu.group or menu.search ~= '') then
      -- Backspace steps back too: from a mod's options (or a kept search) to the list of mods, where the cursor was
      go_back()
      return
    end
    if menu.open and menu.capture == nil and ((pressed('escape') and not menu.typing) or (mk ~= 'off' and pressed(mk))) then
      menu.open, menu.typing = false, false
      return
    end
    if not menu.open then
      if mk ~= 'off' and pressed(mk) then
        -- it always opens on the list of mods
        menu.open, menu.group, menu.search, menu.sel, menu.top = true, nil, '', 1, 1
        if not menu.said then menu.said = true; log('options menu opened') end
      else
        return
      end
    end
    -- the open mod stopped and its options went: back to the list
    if menu.group and #menu.group.rows == 0 then menu.group, menu.sel, menu.top = nil, 1, 1 end
    local typing = menu.capture == nil and search_input()
    local ls = lines()
    if #ls == 0 and menu.search == '' then return end
    if not typing then menu_input(ls) end
    menu_draw(ls)
  end

  -- ---------------------------------------------- the CowboyBingusModLoader / ModOptionsMenu look-alikes
  -- Only when nothing of that name exists. A Lua-only mod that calls these globals gets:
  -- CowboyBingusModLoader.after_startup / capabilities / log_directory / open_log, and ModOptionsMenu's
  -- register_option(id, spec) / get / set / on_change / ready, with its rows in this menu under spec.mod.
  -- I give every locked-down mod its own pair (bind_lookalikes, as the loader makes the mod's environment): fresh
  -- functions that know which mod calls them, over the one set of rows, so no mod can change another's, and a mod
  -- that stops has its callbacks end with it. The pair in the game's globals is for full-access boot scripts.
  local shim = { count = { rows = 0, mods = 0 } }       -- .bingus / .mom: false when something else had the name
  local MOM_OPTIONS, MOM_MODS = 128, 64
  local BINGUS_CAPS = { api = 1, discovery = true, logs = true, health = false, jit_budget = false, after_startup = true }
  local function read_only(t, what)
    return setmetatable({}, { __index = t, __metatable = 'locked', __newindex = function() error(what .. ' is read-only', 2) end })
  end
  local function make_bingus(owner)
    local dir = ctx.DIR:gsub('\\$', '')
    return {
      api = 1, version = ctx.LOADER .. ' ' .. ctx.VERSION .. ' (look-alike)', log_directory = dir,
      capabilities = read_only(BINGUS_CAPS, 'CowboyBingusModLoader.capabilities'),
      after_startup = function(fn) return after_startup(owner, fn) end,
      open_log = function(name)
        if type(name) ~= 'string' or not name:match('^[%w_%-]+%.log$') or #name > 52 then
          return nil, 'log names are letters, digits, _ - and end in .log'
        end
        local base = name:lower():sub(1, -5)
        -- never the loader's own log, a device (con.log is the console) or another mod's own_log
        if base:find('chef_loader', 1, true) == 1 or base:find(ctx.FILES:lower(), 1, true) == 1 then return nil, 'that log is the loader\'s own' end
        if DEVICES[base] then return nil, 'device names are off limits' end
        local o = own_logs[name:sub(1, -5)]
        if o and o.owner ~= owner then return nil, name .. ' is ' .. o.owner .. "'s" end
        return ctx.open(ctx.DIR .. name, 'a')
      end,
    }
  end
  local function mom_row(id) return rows_by_id['ModOptionsMenu|' .. tostring(id)] end
  local function make_mom(owner)
    local mom = { api = 1, version = 2, max_mods = MOM_MODS, max_options = MOM_OPTIONS }
    function mom.register_option(id, spec)
      if type(id) ~= 'string' or type(spec) ~= 'table' then return false, 'register_option(id, spec)' end
      local s = { type = spec.type, label = spec.label, default = spec.default, choices = spec.choices, min = spec.min,
                  max = spec.max, step = spec.step, description = spec.description }
      if mom_row(id) then return true end
      local title = text_of(spec.mod or 'MODS')
      local key = 'mom:' .. title
      local count = shim.count
      if count.rows >= MOM_OPTIONS then return false, 'register_option: ' .. MOM_OPTIONS .. ' options already' end
      if not group_of[key] and count.mods >= MOM_MODS then return false, 'register_option: ' .. MOM_MODS .. ' mods already' end
      local r, err = add_row(owner, 'ModOptionsMenu', 'MODS', id, s)
      if not r then return false, err end
      count.rows = count.rows + 1
      -- each spec.mod gets its own heading: move the row there
      if not group_of[key] then count.mods = count.mods + 1 end
      local g = group(key, title)
      local home = group_of['ModOptionsMenu']
      if home and home ~= g then
        for i = #home.rows, 1, -1 do if home.rows[i] == r then table.remove(home.rows, i) end end
        g.rows[#g.rows + 1] = r
        ver.layout = ver.layout + 1
      end
      return true
    end
    function mom.get(id) local r = mom_row(id); if r then return r.value end end
    function mom.set(id, v)
      local r = mom_row(id)
      if not r then return false end
      local a = recs[owner]
      if a then as_caller(a, set_row, r, v) else set_row(r, v) end
      return true
    end
    function mom.on_change(id, fn)
      local r = mom_row(id)
      if r and type(fn) == 'function' then return on_change(r, owner, function(v) return fn(v, id) end) end
      return false
    end
    function mom.ready() return true end
    return mom
  end
  function svc.install_shims(G)
    shim.bingus = rawget(G, 'CowboyBingusModLoader') == nil
    if shim.bingus then
      rawset(G, 'CowboyBingusModLoader', make_bingus('bingus look-alike'))
      log('look-alike: CowboyBingusModLoader (after_startup, capabilities, log_directory, open_log)')
    end
    shim.mom = rawget(G, 'ModOptionsMenu') == nil
    if shim.mom then
      rawset(G, 'ModOptionsMenu', make_mom('ModOptionsMenu'))
      log('look-alike: ModOptionsMenu (register_option, get, set, on_change, ready; rows in the ' .. ctx.LOADER .. ' options menu)')
    end
  end
  -- one mod's own pair, put straight into its environment (so the game's pair is never reached from it)
  function svc.bind_lookalikes(env, owner)
    if type(env) ~= 'table' or type(owner) ~= 'string' then return false end
    if shim.bingus ~= false then rawset(env, 'CowboyBingusModLoader', make_bingus(owner)) end
    if shim.mom ~= false then rawset(env, 'ModOptionsMenu', make_mom(owner)) end
    return true
  end

  -- ---------------------------------------------------------------- dev mode (test builds only: the loader only calls
  -- dev_files when it is a test build)
  -- chef_loader_dev.txt next to the log: one Lua file path a line (absolute), "#" comments, and optionally
  -- "reload = f11". Each file needs its header line like any mod; a dev file wins over a deployed mod of the same name.
  local dev = { files = {}, on = false }
  function svc.dev_files()
    local f = ctx.open(DEV_FILE, 'r')
    dev.files = {}
    if not f then dev.on = false; return {} end
    local out = {}
    for line in f:lines() do
      line = line:gsub('^%s+', ''):gsub('%s+$', '')
      local k = line:match('^reload%s*=%s*(.+)$')
      if k then reload_key = k
      elseif line ~= '' and not line:match('^#') then dev.files[#dev.files + 1] = line end
    end
    f:close()
    dev.on = #dev.files > 0
    for _, path in ipairs(dev.files) do
      local g = ctx.open(path, 'rb')
      local src = g and g:read('*a')
      if g then g:close() end
      if type(src) == 'string' then
        local kind, mod = src:match('^%-%- HD2%-(%a+): ([%w_/%.%-]+)')
        if mod and mod:match(ctx.ALLOW) and (kind == 'Addon' or kind == 'Boot' or kind == 'Options') then
          out[#out + 1] = { kind = kind, name = mod, file = 'dev:' .. (path:match('[^\\/]+$') or path), src = src, dev = true, path = path }
        else
          log('dev mode: ' .. path .. ' has no "-- HD2-Addon/Boot/Options: mods/<author>/<name>" first line')
        end
      else
        log('dev mode: could not read ' .. path)
      end
    end
    reload_key = reload_key or 'f11'
    if dev.on then log(fmt('dev mode: %d file(s) from %s; %s reloads them', #out, DEV_FILE, reload_key)) end
    return out
  end

  -- A mod that stopped (switched off after errors, failed to start, or about to be started again in dev mode): its menu
  -- rows keep their values but drop its change callbacks, its event subscriptions and waiting after_startup callbacks
  -- end, and the utilities drop its timers, jobs and what it spawned.
  function svc.forget(owner)
    -- (its change callbacks on any row, a look-alike's shared ones too)
    for _, row in pairs(rows_by_id) do
      local keep, any = {}, false
      for _, c in ipairs(row.changed) do
        if c.owner == owner then c.on = false; any = true else keep[#keep + 1] = c end
      end
      if any then row.changed = keep end
    end
    for event, list in pairs(subs) do
      local any = false
      for _, sb in ipairs(list) do if sb.owner == owner and sb.on then sb.on = false; any = true end end
      if any then ended(event) end
    end
    for i = #after, 1, -1 do if after[i].owner == owner then after[i].off = true; table.remove(after, i) end end
    if svc.util then svc.util.forget(owner) end
  end

  -- ---------------------------------------------------------------- the loader's hooks
  local last_world, last_mission = nil, false
  function svc.startup_done()
    started = true
    if #after > 0 then log(fmt('after startup: running %d callback(s)', #after)) end
    local list = after
    after = {}
    for _, c in ipairs(list) do
      -- (one that a mod stopping in an earlier callback took away is skipped)
      if not c.off then
        local ok, err = call_as(c.owner, c.fn)
        if not ok then log(fmt('[%s] after_startup: %s', c.owner, err_text(err))) end
      end
    end
    emit('startup')
    note_conflicts()
  end
  function svc.frame()
    local w = ctx.world
    if w.stable and w.id ~= last_world then last_world = w.id; emit('world', w.id, w.mission == true) end
    -- while the loader looks again at a mission that may have ended (w.checking), it's still the mission it was: no
    -- mission_end and mission_start for a look
    if not w.checking then
      local m = w.stable and w.mission and true or false
      if m ~= last_mission then
        last_mission = m
        emit(m and 'mission_start' or 'mission_end', w.id)
      end
    end
    if dirty and ctx.now() >= save_at then save_at = ctx.now() + 3; save_now() end
    if dev.on and reload_key and pressed(reload_key) then
      log('dev mode: reloading')
      ctx.dev_reload(svc.dev_files())
    end
    menu_frame()
  end
  function svc.shutdown()
    emit('shutdown')
    if dirty then save_now() end
    for _, o in pairs(own_logs) do pcall(o.f.close, o.f) end
  end
  return svc
end

return M
