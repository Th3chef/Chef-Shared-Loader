-- Chef Shared Loader: shared services
-- What every mod gets on top of the basic helpers, so a mod doesn't have to build these
-- itself:
--   * after_startup(fn), a read-only capabilities table, has(name)
--   * a log file of its own per mod (own_log), saved settings per mod (one file next to the log), shared values and
--     events between mods, require() of another mod's exports with version requirements ("-- HD2-Requires:" lines)
--   * key bindings players can change, with conflicts flagged
--   * an in-game options menu (F9 by default) listing every mod's options and bindings, saved between launches
--   * look-alikes of the other loaders' APIs (CowboyBingusModLoader / HD2ModLoader, ModOptionsMenu,
--     ModBindingsMenu, BingusRuntime), so Lua-only mods written for them run
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

-- the pixel font has capitals, digits and . , : - + / % ( ) ! ? only (a UTF-8 character shows as one '?'); the game's
-- font takes the text as it is (in capitals, like the pixel font)
local function plain(s)
  s = tostring(s or ''):upper()
  return (s:gsub('[^A-Z0-9%.,:%-%+/%%%(%)!%?<> \128-\255]', ' '))   -- (UTF-8 kept: the pixel font shows it as '?')
end
local function caps(s) return tostring(s or ''):upper() end
-- without the loader's measured fit (a host that has none): cut by the pixel font's fixed 6 cells a letter
local function fit_cells(s, px, maxw)
  local n = math.floor((maxw + px) / (6 * px))
  return #s > n and s:sub(1, math.max(0, n)) or s
end

-- The menu's hint lines, made once, as pairs: the keys, each drawn as a light chip like the option rows' keys (false:
-- the menu's own key, named when drawn), and what they do. A pair is drawn whole or not at all; opt: a pair left out
-- when the whole line doesn't fit. Each key and word is translated on its own.
local KEY_NOW = false
local HINTS = {
  capture_default = { { word = 'PRESS A KEY' }, { 'ESC', word = 'CANCEL' }, { 'DEL', word = 'DEFAULT' } },
  capture_none = { { word = 'PRESS A KEY' }, { 'ESC', word = 'CANCEL' }, { 'DEL', word = 'NONE' } },
  typing = { { word = 'TYPE TO SEARCH', opt = true }, { 'ENTER', word = 'SEARCH' }, { 'BKSP', word = 'ERASE' },
             { '/', 'ESC', word = 'EXIT' } },
  group = { { 'ARROWS', word = 'MOVE', opt = true }, { 'ENTER', word = 'CHANGE' }, { 'DEL', word = 'DEFAULT' },
            { 'BKSP', word = 'BACK' }, { 'ESC', word = 'CLOSE' } },
  list = { { 'ARROWS', word = 'MOVE', opt = true }, { 'ENTER', word = 'OPEN' }, { '/', word = 'SEARCH' },
           { KEY_NOW, word = 'CLOSE' } },
  mouse = { { 'CLICK', word = 'PICK' }, { '<', '>', word = 'CHANGE' }, { 'RIGHT CLICK', word = 'BACK' },
            { 'WHEEL', word = 'SCROLL' }, { KEY_NOW, word = 'CLOSE' } },
}
-- A hint line from x (y its row's bottom, rh its height) up to x_end: in a pair its keys a little apart and the word
-- close after them, the next pair further off; a chip is at least as wide as a capital letter. When the whole line
-- doesn't fit, the optional pairs go, then the gaps narrow (a pair's word still closer to its keys than the next
-- pair); past that, the pairs that don't fit are left off the end.
-- (each hint text's width, measured once per measure, font and size: the line is laid out every frame the menu is
-- open)
local HINT_W = setmetatable({}, { __mode = 'k' })
local function hint_line(ctx, x, y, rh, px, x_end, pairs_, key, word_c, chip_c, ink, layer, P)
  local by_fn = HINT_W[ctx.text_width]
  if not by_fn then by_fn = {}; HINT_W[ctx.text_width] = by_fn end
  local font = ctx.text_native and ctx.text_native() and 'native' or 'mine'
  local by_font = by_fn[font]
  if not by_font then by_font = {}; by_fn[font] = by_font end
  local known = by_font[px]
  if not known then known = {}; by_font[px] = known end
  local function tw(t)
    local w = known[t]
    if not w then
      w = ctx.text_width(t, px)
      if type(w) == 'number' then known[t] = w end
    end
    return w
  end
  local ty = y + math.floor((rh - 7 * px) / 2)
  local function chip_w(k) return math.max(tw(P(k or key or '')), 5 * px) + 4 * px end
  local wgap = 6 * px                                -- (between a pair's keys and its word)
  local function pair_w(pr)                          -- (its width, the gap after it not counted)
    local w = 0
    for k = 1, #pr do w = w + chip_w(pr[k]) + (k > 1 and 3 * px or 0) end
    if pr.word then w = w + (#pr > 0 and wgap or 0) + tw(P(pr.word)) end
    return w
  end
  local function line_w(with_opt, gap)
    local w, any = 0, false
    for _, pr in ipairs(pairs_) do
      if with_opt or not pr.opt then w = w + (any and gap or 0) + pair_w(pr); any = true end
    end
    return w
  end
  local room = x_end - x
  local with_opt, gap = true, 12 * px
  if line_w(true, gap) > room then
    with_opt = false
    if line_w(false, gap) > room then gap, wgap = 8 * px, 4 * px end
  end
  local first = true
  for _, pr in ipairs(pairs_) do
    if with_opt or not pr.opt then
      local pw = pair_w(pr)
      if (first and 0 or gap) + pw > x_end - x then break end
      if not first then x = x + gap end
      first = false
      for k = 1, #pr do
        local t = P(pr[k] or key or '')
        local w = tw(t)
        local cw = math.max(w, 5 * px)
        if k > 1 then x = x + 3 * px end
        ctx.rect(x, y + 2 * px, cw + 4 * px, rh - 4 * px, chip_c, layer)
        ctx.text(x + 2 * px + math.floor((cw - w) / 2), ty, t, px, ink, layer + 1)
        x = x + cw + 4 * px
      end
      if pr.word then
        if #pr > 0 then x = x + wgap end
        local t = P(pr.word)
        ctx.text(x, ty, t, px, word_c, layer)
        x = x + tw(t)
      end
    end
  end
  return x
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
  local ver = { layout = 0, keys = 0, rows = 0 }
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
    ver.rows = ver.rows + 1
    row = { id = full, key = row_key(id), mod = mod, spec = spec, owner = owner, changed = {}, n = ver.rows, short = id }
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
    -- (a trusted mod's exports never: nothing it holds goes to other mods)
    function chef.require(name, want)
      local other = ctx.addon(name)
      if not other or not other.on or type(other.module) ~= 'table' then return nil, name .. ' is not running' end
      local sbx = svc.sandbox
      if sbx and sbx.trusted and sbx.trusted(name) then return nil, name .. ' shares nothing' end
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
    -- once (mods may read their .log .txt .json .csv .dat .ini .marker .fatal files there); nil when nothing moved
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
  local menu_key = add_row('loader', loader_mod, ctx.LOADER, 'menu_key', { type = 'key', default = 'f9', label = 'Open this menu',
    menu = true, section = 'menu' })
  -- (where the compact panel sits: the player keeps it clear of what they want to see)
  local menu_place = add_row('loader', loader_mod, ctx.LOADER, 'menu_place', { type = 'choice', label = 'Menu position (Compact look)',
    choices = { 'Left', 'Center', 'Right' }, default = 1, section = 'menu' })
  local reload_key = nil
  -- more rows in the loader's own group (the frame budget)
  function svc.loader_option(id, spec)
    local r, err = add_row('loader', loader_mod, ctx.LOADER, id, spec)
    if not r then log('loader option ' .. id .. ': ' .. tostring(err)) end
    return r
  end
  function svc.set_row(r, v) set_row(r, v) end
  -- every text of my options menu (the mods' titles, the options' labels and choices, the headings), for a language
  -- to note the ones it has no entry for; and the version of that list (it changes with the menu's layout)
  function svc.option_texts()
    local out = { 'MENU', 'PERFORMANCE', 'PERMISSIONS', 'MOD OPTIONS', 'ALL MODS', 'ALSO USED BY:' }
    for _, g in ipairs(groups) do
      if #g.rows > 0 then
        out[#out + 1] = text_of(g.title)
        for _, r in ipairs(g.rows) do
          out[#out + 1] = text_of(r.spec.label or r.id)
          if r.spec.type == 'choice' and type(r.spec.choices) == 'table' then
            for _, c in ipairs(r.spec.choices) do out[#out + 1] = text_of(c) end
          end
        end
      end
    end
    return out
  end
  function svc.layout_ver() return ver.layout end
  -- the loader's own saved values that aren't a row (the language picked, by name)
  function svc.loader_get(key) return get(loader_mod, key) end
  function svc.loader_put(key, v) return put(loader_mod, key, v) end
  function svc.menu_key_name() return menu_key.value end
  -- ---------------------------------------------- the menu's look, controller and mouse
  -- Rows of their own in the loader's group. The controller: the engine's own pads (Pad1..Pad8, the first one active,
  -- its buttons found by the names the pad itself lists), the D-pad moves, cross/A picks, circle/B goes back (and closes
  -- at the list of mods), square/X puts the default back, L1/R1 a page. The mouse: my own cursor (moved by the
  -- engine's cursor axis while I hold the mouse from the camera, below, else by its delta axis), hover picks, a left
  -- click acts, a right click goes back, the wheel scrolls, a slider's bar takes a drag. The game still sees every key
  -- and button (Lua can't take input from it), so in a mission the menu is the compact panel, the mouse is off by
  -- default and the controller never opens it; the full screen look is for the ship. While the menu is closed (off a
  -- mission) only the touchpad / View button is read (held two seconds it opens the menu; it's the one button the game
  -- leaves free off a mission), and not even that when the controller row says so. Only plain numbers are kept between
  -- frames: the pad's number and button indexes, the cursor, the boxes drawn last frame; every engine table and value
  -- is fetched in the frame it's used.
  local look_row = add_row('loader', loader_mod, ctx.LOADER, 'menu_look', { type = 'choice', label = 'Menu look',
    choices = { 'Full screen', 'Compact' }, default = 1, section = 'menu' })
  local mouse_row = add_row('loader', loader_mod, ctx.LOADER, 'menu_mouse', { type = 'choice', label = 'Mouse in this menu',
    choices = { 'On the ship', 'Always', 'Off' }, default = 1, section = 'menu' })
  local pad_row = add_row('loader', loader_mod, ctx.LOADER, 'menu_pad', { type = 'choice', label = 'Controller in this menu',
    choices = { 'On, hold touchpad / View 2 s to open', 'On', 'Off' }, default = 1, section = 'menu' })
  local nav = { pad = nil, look_at = 0, ix = {}, held = {}, rep = {}, act = {}, ps = false,
                mx = nil, my = nil, moved = false, wheel = 0, mouse = false, axes = nil, lmb = true, rmb = true,
                click = false, rclick = false, hits = {}, nhits = 0, ltop = 1 }
  local PAD_NAMES = { up = { 'd_up', 'up', 'dpad_up' }, down = { 'd_down', 'down', 'dpad_down' },
    left = { 'd_left', 'left', 'dpad_left' }, right = { 'd_right', 'right', 'dpad_right' },
    enter = { 'a', 'cross' }, back = { 'b', 'circle' }, delete = { 'x', 'square' },
    ['page up'] = { 'left_shoulder', 'l1' }, ['page down'] = { 'right_shoulder', 'r1' },
    touch = { 'touch', 'touchpad', 'back', 'view', 'select' } }
  local PAD_ORDER = { 'up', 'down', 'left', 'right', 'enter', 'back', 'delete', 'page up', 'page down', 'touch' }
  local PAD_REPEAT = { up = true, down = true, left = true, right = true }
  local function eng(name, ...) return guarded('loader', name, fn_of(name), ...) end
  -- the first pad that answers, looked for once a second until one does. Its buttons come from the names the pad
  -- lists itself (num_buttons, button_name), so no name a pad doesn't know is ever asked about; the call names are
  -- made once per pad found.
  function nav.pad_find()
    local t = ctx.now()
    if t < nav.look_at then return end
    nav.look_at = t + 1
    for n = 1, 8 do
      local p = 'Pad' .. n
      if eng(p .. '.active') == true or eng(p .. '.connected') == true then
        local count, by = eng(p .. '.num_buttons'), {}
        if type(count) == 'number' and count > 0 and count <= 64 then
          for i = 0, count - 1 do
            local nm = eng(p .. '.button_name', i)
            if type(nm) == 'string' and nm ~= '' then by[nm:lower()] = i end
          end
        end
        local ix, miss, ps = {}, {}, false
        for _, a in ipairs(PAD_ORDER) do
          for k, c in ipairs(PAD_NAMES[a]) do
            if by[c] then ix[a] = by[c]; if a == 'enter' and k == 2 then ps = true end; break end
          end
          if not ix[a] then miss[#miss + 1] = a end
        end
        if ix.enter and ix.up then
          local name = eng(p .. '.name')
          nav.pad, nav.ix, nav.held, nav.ps, nav.pname = n, ix, {}, ps, type(name) == 'string' and name or '?'
          nav.calls = { active = p .. '.active', connected = p .. '.connected', button = p .. '.button', name = p .. '.name' }
          nav.name_at = t + 1
          log(fmt('options menu: controller %s (%s)%s', p, nav.pname,
            #miss > 0 and ('; no button for ' .. concat(miss, ', ')) or ''))
          return
        end
      end
    end
  end
  -- this frame's presses into nav.act (the D-pad repeats while held); nav.held[a]: since when a button is down
  -- (closed: the touchpad / View only: one call a frame)
  function nav.pad_read(closed)
    if not nav.pad then nav.pad_find(); if not nav.pad then return end end
    local C, now = nav.calls, ctx.now()
    if eng(C.active) ~= true and eng(C.connected) ~= true then nav.pad, nav.look_at, nav.held = nil, 0, {}; return end
    -- (another pad put in the same slot: its buttons are found again; asked once a second)
    if now >= nav.name_at then
      nav.name_at = now + 1
      local nm = eng(C.name)
      if (type(nm) == 'string' and nm or '?') ~= nav.pname then nav.pad, nav.look_at, nav.held = nil, 0, {}; return end
    end
    -- (the first read after the menu opened: a button already down is held, not pressed, and never repeats)
    local seed = nav.seed and not closed
    if seed then nav.seed = nil end
    for a, i in pairs(nav.ix) do
      local v = false
      if not closed or a == 'touch' then v = eng(C.button, i) end
      if v == true or (type(v) == 'number' and v > 0.5) then
        if seed and not nav.held[a] then
          nav.held[a] = now; nav.rep[a] = math.huge
        elseif not nav.held[a] then
          nav.held[a] = now; nav.rep[a] = now + 0.4; nav.act[a] = true
          if not closed then menu.dev = 'pad' end          -- (the hints show the controller's buttons)
        elseif PAD_REPEAT[a] and now >= nav.rep[a] then nav.rep[a] = now + 0.09; nav.act[a] = true end
      else nav.held[a] = nil end
    end
  end
  -- On the ship (or the title screen), told by what I know, never guessed: a settled world, not being looked at again,
  -- not a mission, and with a level count (the ship's few or none), else no bigger than the ship (about 3,800 units; the
  -- smallest missions are about 4,800). Anything else counts as a mission: a world still loading, a small mission not
  -- recognized as one.
  local SHIP_UNITS = 4300
  function nav.on_ship()
    local w = ctx.world
    return w.stable == true and not w.checking and w.mission ~= true
      and (w.levels ~= nil or (w.last_n or w.units or 0) <= SHIP_UNITS)
  end
  function nav.mouse_on()
    local m = mouse_row.value
    return m == 2 or (m == 1 and nav.on_ship())
  end
  -- The mouse held from the game while my menu has it: a dead zone far above any movement on the mouse's delta axis
  -- (the one the game's camera reads) leaves the camera still, and my cursor follows the engine's cursor axis instead,
  -- which keeps moving. What the axis had is put back as soon as the menu lets the mouse go (closed, the mouse off for
  -- it, a mission without it) and at shutdown. HOLD is a size of my own (an odd one, exact as a float): a dead zone
  -- found at it later (another mod put back what it found while I held the mouse) is mine again while the menu is
  -- open, and put back to what I found once it's closed, checked once a second. A dead zone already far up (another mod
  -- holds the mouse) is left alone, and my cursor follows the cursor axis all the same (other: asked again once a
  -- second). No dead zone or cursor answer: the camera turns with the mouse, as before.
  -- on: mine; had: what I found; off: not this session; paused: not until the menu closes; ever: a cursor was read
  local HOLD = 917351
  nav.hold = { on = false, had = nil, off = false, paused = false, other = nil, ever = false, heal_at = 0, bad = 0 }
  function nav.hold_take()
    local H, A = nav.hold, nav.axes
    if H.on or H.off or H.paused or not (A and A.move and A.cursor) then return end
    if H.other and ctx.now() < H.other then return end
    local mode, size = eng('Mouse.dead_zone', A.move)
    if type(mode) ~= 'number' or type(size) ~= 'number' then
      H.off = true
      log('options menu: the mouse turns the camera while the menu is open (no dead zone answer)')
      return
    end
    if size == HOLD and H.had then                      -- (mine, put back by another mod: what I found is still under it)
      H.on, H.other, H.px, H.py, H.bad = true, nil, nil, nil, 0
      return
    end
    if size >= 1e5 then
      if not H.other then H.px, H.py, H.bad = nil, nil, 0 end
      H.other = ctx.now() + 1
      return
    end
    H.other = nil
    eng('Mouse.set_dead_zone', A.move, 1, HOLD)
    local _, now = eng('Mouse.dead_zone', A.move)
    if now ~= HOLD then
      H.off = true
      log('options menu: the mouse turns the camera while the menu is open (the dead zone stayed ' .. tostring(now) .. ')')
      return
    end
    H.on, H.had, H.px, H.py, H.bad = true, { mode, size }, nil, nil, 0
    if not H.said then
      H.said = true
      log(fmt('options menu: the mouse is held from the game while the menu has it (its dead zone was %s, %s)', tostring(mode),
        tostring(size)))
    end
  end
  function nav.hold_give()
    local H, A = nav.hold, nav.axes
    if not H.on then return end
    H.on = false
    local _, size = eng('Mouse.dead_zone', A.move)
    if size == HOLD then eng('Mouse.set_dead_zone', A.move, H.had[1], H.had[2]) end
    if ctx.TEST then
      local m2, s2 = eng('Mouse.dead_zone', A.move)
      log(fmt('options menu (test): the mouse given back to the game (dead zone now %s, %s)', tostring(m2), tostring(s2)))
    end
  end
  function nav.hold_heal()
    local H, A = nav.hold, nav.axes
    if H.on or not H.had then return end
    local t = ctx.now()
    if t < H.heal_at then return end
    H.heal_at = t + 1
    local _, size = eng('Mouse.dead_zone', A.move)
    if size == HOLD then
      eng('Mouse.set_dead_zone', A.move, H.had[1], H.had[2])
      log('options menu: the mouse\'s dead zone was found held after the menu let it go: put back')
    end
  end
  -- the engine's cursor (window pixels from the bottom left) as menu pixels, or nil when it isn't in the window
  function nav.cursor_at(w, h)
    local v = eng('Mouse.axis', nav.axes.cursor)
    if v == nil then return nil end
    local x, y = eng('Vector3.to_elements', v)
    local H = nav.hold
    if not H.res_at or ctx.now() >= H.res_at then        -- (the window's size, asked once a second)
      local a, b = eng('Application.resolution')
      H.rw, H.rh, H.res_at = tonumber(a), tonumber(b), ctx.now() + 1
    end
    local rw, rh
    x, y, rw, rh = tonumber(x), tonumber(y), H.rw, H.rh
    if not (x and y and rw and rh and rw > 0 and rh > 0 and x >= 0 and y >= 0 and x <= rw and y <= rh) then
      H.res_at = 0                                       -- (asked again next frame: the window may have changed size)
      return nil
    end
    local mx, my = x * w / rw, y * h / rh
    if ctx.TEST and (H.logs or 0) < 40 and ctx.now() >= (H.log_at or 0) then        -- (test builds: where it reads)
      H.logs, H.log_at = (H.logs or 0) + 1, ctx.now() + 1
      log(fmt('options menu (test): cursor %.0f, %.0f of %.0f x %.0f -> menu %.0f, %.0f of %d x %d', x, y, rw, rh, mx, my, w, h))
    end
    return mx, my
  end
  -- the cursor (screen pixels, y up like the drawing), the wheel, and this frame's clicks
  function nav.mouse_read(w, h)
    -- (no answer yet, the mouse not ready in the first frames on some setups: asked again every 2 s)
    if not nav.axes or (not nav.axes.move and ctx.now() >= nav.axes.at) then
      local had = nav.axes
      nav.axes = { move = eng('Mouse.axis_index', 'mouse') or false, wheel = eng('Mouse.axis_index', 'wheel') or false,
                   cursor = eng('Mouse.axis_index', 'cursor') or false,
                   l = eng('Mouse.button_index', 'left') or false, r = eng('Mouse.button_index', 'right') or false,
                   at = ctx.now() + 2 }
      if not had or nav.axes.move then log('options menu: mouse ' .. (nav.axes.move and 'found' or 'missing')) end
    end
    local A = nav.axes
    nav.moved, nav.wheel, nav.click, nav.rclick = false, 0, false, false
    if not A.move then return end
    if not nav.mx then nav.mx, nav.my = w / 2, h / 2 end
    local function xy(i)
      local v = eng('Mouse.axis', i)
      if v == nil then return 0, 0 end
      local x, y = eng('Vector3.to_elements', v)
      return tonumber(x) or 0, tonumber(y) or 0
    end
    -- (the game showing its own cursor, its pause screen: the cursor axis is where the mouse really is, and the game
    -- turns no camera with it; my cursor sits on it, and the mouse isn't held)
    local win = eng('Window.get_main_window')
    local shown = win ~= nil and eng('Window.show_cursor', win) == true
    nav.game_cursor = shown                             -- (then the game's own cursor is the one drawn: not mine)
    local H = nav.hold
    if not shown then nav.hold_take() end
    if shown then
      if H.on then nav.hold_give() end
      local cx, cy = nav.cursor_at(w, h)
      if cx then
        nav.moved = cx ~= nav.mx or cy ~= nav.my
        nav.mx, nav.my = cx, cy
      end
      H.px, H.py = nil, nil                             -- (held again later: from a fresh sample, no jump)
    elseif H.on or H.other then
      -- (held, by me or another mod: the delta reads nothing now; the cursor axis's movement moves my cursor. The game
      -- puts its hidden cursor back in the middle of the window when it moves far, so a frame whose cursor lands in the
      -- middle, or jumps more than a third of the screen, moves nothing. Ten frames running with no usable cursor (out
      -- of the window) give the mouse back until the menu closes; for the session when no cursor was ever read)
      local cx, cy = nav.cursor_at(w, h)
      if cx then
        H.bad, H.ever = 0, true
        local px, py = H.px, H.py
        H.px, H.py = cx, cy
        if px then
          local dx, dy = cx - px, cy - py
          local mid = cx - w / 2 <= 3 and w / 2 - cx <= 3 and cy - h / 2 <= 3 and h / 2 - cy <= 3
          local jump = dx > w / 3 or -dx > w / 3 or dy > h / 3 or -dy > h / 3
          if (dx ~= 0 or dy ~= 0) and not mid and not jump then
            nav.moved = true
            nav.mx = max(0, min(w - 1, nav.mx + dx))
            nav.my = max(0, min(h - 1, nav.my + dy))
          end
        end
      else
        H.bad = H.bad + 1
        if H.bad >= 10 then
          nav.hold_give(); H.other, H.bad = nil, 0
          if H.ever then H.paused = true
          else
            H.off = true
            log('options menu: the mouse turns the camera while the menu is open (no cursor position)')
          end
        end
      end
    else
      local dx, dy = xy(A.move)
      nav.moved = dx ~= 0 or dy ~= 0
      local k = h / 1080
      -- (the delta counts y down; the menu's y grows upward)
      nav.mx = max(0, min(w - 1, nav.mx + dx * k))
      nav.my = max(0, min(h - 1, nav.my - dy * k))
    end
    if A.wheel then local _, wy = xy(A.wheel); nav.wheel = wy end
    local function down(i) if not i then return false end local v = eng('Mouse.button', i); return type(v) == 'number' and v > 0.5 end
    local l, r = down(A.l), down(A.r)
    nav.click, nav.rclick = l and not nav.lmb, r and not nav.rmb
    nav.lmb, nav.rmb = l, r
    if nav.moved or nav.click or nav.rclick or nav.wheel ~= 0 then menu.dev = 'mouse' end   -- (the hints show the mouse's)
  end
  -- the boxes drawn this frame, for the mouse next frame: x, y, w, h, kind, index (flat, no table per box)
  function nav.hit(x, y, w, h, kind, i)
    local H, b = nav.hits, nav.nhits * 6
    H[b + 1], H[b + 2], H[b + 3], H[b + 4], H[b + 5], H[b + 6] = x, y, w, h, kind, i
    nav.nhits = nav.nhits + 1
  end
  -- the box under the cursor (the last drawn wins): kind, index, its x and width
  function nav.under()
    local x, y, H = nav.mx, nav.my, nav.hits
    if not (nav.mouse and x) then return nil end
    if svc.util and svc.util.pm_over and svc.util.pm_over(x, y) then return nil end   -- (the monitor drawn over me)
    for j = nav.nhits, 1, -1 do
      local b = (j - 1) * 6
      if x >= H[b + 1] and x < H[b + 1] + H[b + 3] and y >= H[b + 2] and y < H[b + 2] + H[b + 4] then
        return H[b + 5], H[b + 6], H[b + 1], H[b + 3]
      end
    end
  end
  -- the controller's buttons as small pictures: each shape a distance function sampled once a screen pixel, the edge
  -- coverage as alpha (4 levels), runs of equal alpha merged into one rect, and rows of the same runs into one taller
  -- rect. Pads with shape buttons: the shape in a ring; pads with letter buttons: the letter in a ring; the D-pad as an
  -- outlined cross. Worked out once a size into plain numbers.
  local GLYPH_OF = { enter = { 'cross', 'A' }, back = { 'circle', 'B' }, delete = { 'square', 'X' }, dpad = { 'dpad' } }
  local glyph_cache = {}
  local function glyph_runs(kind, s)
    local key = kind .. s
    if glyph_cache[key] then return glyph_cache[key] end
    local sqrt, abs = math.sqrt, math.abs
    local function seg(px, py, ax, ay, bx, by)
      local dx, dy = bx - ax, by - ay
      local t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
      local ex, ey = px - ax - t * dx, py - ay - t * dy
      return sqrt(ex * ex + ey * ey)
    end
    local function box(px, py, hx, hy)
      local qx, qy = abs(px) - hx, abs(py) - hy
      local ox, oy = max(qx, 0), max(qy, 0)
      return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0)
    end
    local SHAPES = {
      cross = function(x, y, r) local k, w = r * 0.36, r * 0.085; return min(seg(x, y, -k, -k, k, k), seg(x, y, -k, k, k, -k)) - w end,
      circle = function(x, y, r) return abs(sqrt(x * x + y * y) - r * 0.36) - r * 0.08 end,
      square = function(x, y, r) return abs(box(x, y, r * 0.33, r * 0.33)) - r * 0.075 end,
      ring = function(x, y, r) return abs(sqrt(x * x + y * y) - r * 0.9) - r * 0.07 end,
      dpad = function(x, y, r) return abs(min(box(x, y, r * 0.30, r * 0.9), box(x, y, r * 0.9, r * 0.30))) - r * 0.06 end }
    local f, ring = SHAPES[kind], kind ~= 'dpad' and kind ~= 'ring' and SHAPES.ring
    if kind == 'letter' then f = SHAPES.ring; ring = nil end
    local r, rows, out = s / 2, {}, {}
    for j = 0, s - 1 do                        -- each row's runs: x, width, alpha (as one string, to merge rows)
      local py, runs, run_a, run_i = (j + 0.5) - r, {}, 0, 0
      for i = 0, s do
        local a = 0
        if i < s then
          local px = (i + 0.5) - r
          local d = f(px, py, r)
          if ring then d = min(d, ring(px, py, r)) end
          a = floor(max(0, min(1, 0.5 - d)) * 4 + 0.5)
        end
        if a ~= run_a then
          if run_a > 0 then runs[#runs + 1] = run_i .. ',' .. (i - run_i) .. ',' .. run_a end
          run_a, run_i = a, i
        end
      end
      rows[j] = runs
    end
    local j = 0
    while j < s do                             -- rows with the same runs become one rect each, x, y from the top, w, h, alpha
      local sig, h = concat(rows[j], ';'), 1
      while j + h < s and concat(rows[j + h], ';') == sig do h = h + 1 end
      for _, run in ipairs(rows[j]) do
        local x, wd, a = run:match('(%d+),(%d+),(%d+)')
        out[#out + 1] = tonumber(x); out[#out + 1] = j; out[#out + 1] = tonumber(wd); out[#out + 1] = h; out[#out + 1] = tonumber(a)
      end
      j = j + h
    end
    glyph_cache[key] = out
    return out
  end
  -- draws one at x, y (its bottom left), 9 c pixels square; returns its width
  function nav.glyph(what, x, y, c, layer)
    local g = GLYPH_OF[what]
    if not g then return 0 end
    local s, col = 9 * c, ctx.color
    local letter = not nav.ps and g[2]
    local R = glyph_runs(letter and 'letter' or g[1], s)
    local cols = { col(232, 232, 226, 64), col(232, 232, 226, 128), col(232, 232, 226, 191), col(232, 232, 226, 255) }
    for i = 1, #R, 5 do ctx.rect(x + R[i], y + s - R[i + 1] - R[i + 3], R[i + 2], R[i + 3], cols[R[i + 4]], layer) end
    if letter and ctx.text then
      local lp = max(1, floor(c * 0.75))
      local lw = ctx.text_width(letter, lp)
      ctx.text(x + floor((s - lw) / 2), y + floor((s - 7 * lp) / 2), letter, lp, cols[4], layer + 1)
    end
    return s
  end
  -- the title picture: 534 x 74 pixels, a texture in my own patch (BANNER_TEX, the resource
  -- mods/chef_shared_loader/menu_banner; tools/build.py checks the id), drawn one screen pixel a picture pixel at 1080p
  -- (two at 4K) through the bitmap path: one draw a frame. BANNER_AH: the height of its figure, at the bottom. No
  -- texture (not loaded, or a host without bitmaps): nil, and the caller writes the title instead.
  local BANNER_W, BANNER_H, BANNER_AH = 534, 74, 64
  local BANNER_TEX = 'b20c9c97bcd6c5d8'
  function nav.banner(x, y, c, layer)
    local white = ctx.color(255, 255, 255, 255)
    if ctx.bitmap and white and ctx.bitmap(BANNER_TEX, x, y, BANNER_W * c, BANNER_H * c, white, layer) then return BANNER_W * c end
    return nil
  end
  -- the cursor: an arrow, ink edged
  function nav.draw_cursor(top, h)
    if not (nav.mouse and nav.mx) or nav.game_cursor then return end
    local c = max(2, floor(h / 400 + 0.5))
    local x, y, col = floor(nav.mx), floor(nav.my), ctx.color
    local edge, fill = col(17, 17, 17, 255), col(255, 231, 16, 255)
    for i = 0, 9 do
      local wd = (i < 7) and (i + 1) or (10 - i) * 2 - 1
      ctx.rect(x - c, y - (i + 2) * c, (wd + 2) * c, 2 * c, edge, top + 8)
    end
    for i = 0, 8 do
      local wd = (i < 7) and i or (9 - i) * 2 - 2
      if wd > 0 then ctx.rect(x, y - (i + 1) * c, wd * c, c, fill, top + 9) end
    end
  end
  -- the mods with rows, by title in alphabetical order (case ignored; the mod's name breaks a tie)
  -- (kept until the layout changes: the full screen look asks for it every frame)
  local sorted_cache = { ver = -1, gs = nil }
  local function sorted_groups()
    if sorted_cache.ver == ver.layout then return sorted_cache.gs end
    local gs = {}
    for _, g in ipairs(groups) do if #g.rows > 0 then gs[#gs + 1] = g end end
    -- (mine first, under a divider; the mods in alphabetical order after it)
    table.sort(gs, function(a, b)
      if (a.mod == loader_mod) ~= (b.mod == loader_mod) then return a.mod == loader_mod end
      local ta, tb = text_of(a.title):lower(), text_of(b.title):lower()
      if ta ~= tb then return ta < tb end
      return a.mod < b.mod
    end)
    sorted_cache.ver, sorted_cache.gs = ver.layout, gs
    return gs
  end
  -- the lines shown: the list of mods; the open mod's options; or, with a search typed after '/', every mod whose
  -- title has it (whole) and every option whose label has it, under its mod's title
  local lines_cache = { ver = -1, search = nil, group = nil, out = nil }
  -- A group's rows as lines. My own rows carry a section: they're shown by section, each under its heading, in the
  -- order below (any other row of a section after those, in the order it was made).
  local SECTIONS = { menu = { 1, 'MENU' }, monitor = { 2, 'PERFORMANCE' }, permissions = { 3, 'PERMISSIONS' } }
  local ORDER = { menu_key = 1, menu_look = 2, menu_place = 3, menu_mouse = 4, menu_pad = 5, font = 6, lang = 7,
                  perf = 1, perf_place = 2, budget = 3, perf_hide = 4 }
  local function section_of(r) return r.owner == 'loader' and SECTIONS[r.spec.section] or nil end
  local function group_lines(g, out)
    local rows, any = {}, false
    for i, r in ipairs(g.rows) do rows[i] = r; if section_of(r) then any = true end end
    if not any then
      for _, r in ipairs(rows) do out[#out + 1] = { row = r } end
      return out
    end
    table.sort(rows, function(a, b)
      local sa, sb = section_of(a), section_of(b)
      local ka, kb = sa and sa[1] or 99, sb and sb[1] or 99
      if ka ~= kb then return ka < kb end
      local oa, ob = ORDER[a.short] or 50, ORDER[b.short] or 50
      if oa ~= ob then return oa < ob end
      return a.n < b.n
    end)
    local last = nil
    for _, r in ipairs(rows) do
      local sec = section_of(r)
      if sec and sec ~= last then out[#out + 1] = { head = true, text = sec[2] } end
      last = sec
      out[#out + 1] = { row = r }
    end
    return out
  end
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
      group_lines(menu.group, out)
    else
      for _, g in ipairs(sorted_groups()) do out[#out + 1] = { pick = g, text = g.title } end
    end
    lines_cache.ver, lines_cache.search, lines_cache.group, lines_cache.out = ver.layout, menu.search, menu.group, out
    return out
  end
  -- the hint for a key row marked '!' (its key bound more than once): which other options use the key, by mod and
  -- label, two at most then a count ('F7 ALSO USED BY: SOME MOD (TOGGLE) +2'); nil for any other line. Worked out
  -- again only when a binding, the selected row or the language changes.
  -- (with a language on, its parts are translated before they're joined, and the joined line, as drawn, is kept as it
  -- is: the language translates 'ALSO USED BY:' and the mods' titles and labels once each, never every pairing. A part
  -- the frame's pattern budget cut leaves the line uncached, so it's made again next frame.)
  local clash_cache = { ver = -1, row = nil, lv = nil, text = nil }
  local function clash_hint(l, users)
    local r = l and l.row
    if not r or r.spec.type ~= 'key' or r.value == 'off' or (users[r.value] or 0) < 2 or menu.capture then return nil end
    local lv = ctx.lang_v and ctx.lang_v()
    if clash_cache.ver ~= ver.keys or clash_cache.row ~= r or clash_cache.lv ~= lv then
      local tr = ctx.tr or text_of
      if ctx.tr_cut then ctx.tr_cut(true) end
      local others, n = {}, 0
      for _, g in ipairs(groups) do
        for _, o in ipairs(g.rows) do
          if o ~= r and o.spec.type == 'key' and o.value == r.value then
            n = n + 1
            if n <= 2 then others[#others + 1] = tr(text_of(g.title)) .. ' (' .. tr(text_of(o.spec.label or o.id)) .. ')' end
          end
        end
      end
      local key = svc.util and svc.util.key_label(r.value) or r.value
      clash_cache.text = n > 0 and (key .. ' ' .. tr('ALSO USED BY:') .. ' ' .. concat(others, ', ')
                                    .. (n > 2 and fmt(' +%d', n - 2) or '')) or nil
      clash_cache.ver, clash_cache.row, clash_cache.lv = ver.keys, r, lv
      if ctx.tr_cut and ctx.tr_cut() then clash_cache.ver = -1 end
    end
    return clash_cache.text
  end
  -- the clash hint as drawn (in the look's capitals), kept as it is each time it's shown: the language's list of texts
  -- drawn as they are is two generations
  local function clash_drawn(clash, P)
    local s = P(clash)
    if ctx.tr_keep then ctx.tr_keep(s) end
    return s
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
  -- (a key pressed: the hints show the keys)
  local function pressed(name) local v = ctx.key_pressed(name); if v then menu.dev = 'keys' end; return v end
  -- a menu action this frame: its key, or the controller's button or the mouse standing in for it
  local function act(name) return nav.act[name] == true or pressed(name) end
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
  -- the search: '/' starts typing; letters, digits and spaces go in, Backspace (or Delete) takes one off, Enter keeps
  -- it (the list filtered by it), '/' again or Escape leaves it (the typed text comes from Keyboard.keystrokes,
  -- through the utilities)
  local function search_input()
    local typed = svc.util and svc.util.typed() or ''
    if not menu.typing then
      if typed:find('/', 1, true) then menu.typing, menu.search, menu.sel, menu.top, nav.drag = true, '', 2, 1, nil end
      if menu.typing then menu.group = nil end
      return false
    end
    for ch in typed:gmatch('[%w ]') do
      if #menu.search < 20 then menu.search = menu.search .. ch:lower(); menu.sel, menu.top = 2, 1 end
    end
    if pressed('delete') or pressed('backspace') then menu.search = menu.search:sub(1, -2); menu.sel, menu.top = 2, 1 end
    if pressed('enter') then menu.typing = false end
    -- ('/' again or Escape leaves the search: the whole list back)
    if typed:find('/', 1, true) or pressed('escape') then
      menu.typing, menu.search, menu.sel, menu.top = false, '', 1, 1
    end
    return true
  end
  -- a mod opened (from the list's line `back`): the cursor on its first row, past any heading
  local function open_group(back, g)
    menu.back, menu.group, menu.search, menu.top, nav.drag = back, g, '', 1, nil
    local ls, i = lines(), 2
    while ls[i] and ls[i].head do i = i + 1 end
    menu.sel = ls[i] and i or 1
  end
  -- back to the list of mods, where its cursor was (the Back row, or Backspace)
  local function go_back()
    nav.drag = nil
    if menu.group then menu.sel, menu.top = menu.back, 1 else menu.sel, menu.top = 1, 1 end
    menu.group, menu.search = nil, ''
  end
  local function menu_input(ls)
    if menu.capture then
      local k = capture_key()
      local r = menu.capture
      if k == 'escape' or nav.act.back then menu.capture = nil
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
    -- the mouse: hover picks a line, a click acts on it (a choice or a slider steps on), the arrows step it, a slider's
    -- bar takes the value under the cursor while the button is held, a click on another mod opens it, the wheel scrolls
    if nav.mouse then
      local kind, i, bx, bw = nav.under()
      -- a slider's bar held: that row keeps the drag until the button is let go (or its line isn't that row any more)
      local d = nav.drag
      if d and (not nav.lmb or not ls[d.i] or ls[d.i].row ~= d.r) then nav.drag = nil end
      -- The wheel scrolls the lines in view, a line a notch (parts of a notch add up), and keeps the picked line among
      -- them. In a frame the wheel turns I skip the hover and the clicks: last frame's boxes are under the old
      -- scroll, and a hover after the scroll would put the picked line back. Not while a slider is held.
      if nav.wheel ~= 0 and not nav.drag then
        local vis = nav.visible or 8
        if (nav.wacc or 0) * nav.wheel > 0 then nav.wacc = 0 end   -- (turned the other way: a part kept from before goes)
        nav.wacc = (nav.wacc or 0) - nav.wheel
        local whole = nav.wacc >= 0 and floor(nav.wacc) or -floor(-nav.wacc)
        nav.wacc = nav.wacc - whole
        local top = max(1, min(menu.top + whole, n - vis + 1))
        menu.top = top
        if menu.sel < top then menu.sel = top; if ls[top].head then step(1) end
        elseif menu.sel > top + vis - 1 then menu.sel = top + vis - 1; if ls[menu.sel].head then step(-1) end end
        kind = nil
      end
      if not nav.drag and kind == 'line' and ls[i] and not ls[i].head and (nav.moved or nav.click) then menu.sel = i end
      if nav.click then
        if kind == 'line' and ls[i] then
          local t = ls[i].row and ls[i].row.spec.type
          if t == 'choice' or t == 'slider' then nav.act.right = true else nav.act.enter = true end
        elseif (kind == 'dec' or kind == 'inc') and ls[i] then
          menu.sel = i; nav.act[kind == 'dec' and 'left' or 'right'] = true
        elseif kind == 'group' then
          local g = sorted_groups()[i]
          if g then open_group(i, g); return end
        end
      end
      if not nav.drag and kind == 'bar' and nav.lmb and ls[i] and ls[i].row and bw > 0 then
        nav.drag = { r = ls[i].row, i = i, bx = bx, bw = bw }
        menu.sel = i
      end
      if nav.drag then
        d = nav.drag
        set_row(d.r, d.r.spec.min + max(0, min(1, (nav.mx - d.bx) / d.bw)) * (d.r.spec.max - d.r.spec.min))
        return
      end
    end
    if act('down') then step(1) elseif act('up') then step(-1)
    elseif act('page down') then for _ = 1, 8 do step(1) end
    elseif act('page up') then for _ = 1, 8 do step(-1) end end
    local l = ls[menu.sel]
    -- a mod in the list: Enter (or Right) opens its options, the cursor on its first option (Back is just above it)
    if l and l.pick then
      if act('enter') or act('right') then open_group(menu.sel, l.pick) end
      return
    end
    if l and l.back then
      if act('enter') or act('left') then go_back() end
      return
    end
    local r = l and l.row
    if not r then return end
    local s = r.spec
    local dir = act('right') and 1 or (act('left') and -1 or 0)
    if act('delete') then set_row(r, r.default); return end
    if s.type == 'toggle' and (dir ~= 0 or act('enter')) then set_row(r, not r.value)
    elseif s.type == 'choice' and dir ~= 0 then
      local v = r.value + dir
      if v < 1 then v = #s.choices elseif v > #s.choices then v = 1 end
      set_row(r, v)
    elseif s.type == 'slider' and dir ~= 0 then set_row(r, r.value + dir * ((s.step or 0) > 0 and s.step or (s.max - s.min) / 20))
    elseif s.type == 'key' and act('enter') then menu.capture = r end
  end
  -- The look: a dark panel in a yellow frame, the title on a yellow bar, the
  -- picked row lit with a yellow edge, values in green (OFF in gray), keys as light chips, the hints under a thin line.
  local function menu_draw(ls)
    local w, h = ctx.screen()
    local px = max(2, floor(h / 540 + 0.5))
    local top = ctx.TOP + 950
    local rh, cols = 12 * px, 40
    local pw = (cols * 6 + 10) * px
    local place = menu_place and tonumber(menu_place.value) or 1
    local x0 = max(0, (place == 2 and floor((w - pw) / 2)) or (place == 3 and w - pw - floor(w * 0.05)) or floor(w * 0.05))
    local visible = max(4, floor((h * 0.7) / rh) - 4)
    nav.visible = visible                      -- (the wheel keeps the picked line among the lines in view)
    if menu.sel < menu.top then menu.top = menu.sel elseif menu.sel >= menu.top + visible then menu.top = menu.sel - visible + 1 end
    -- (a section's heading kept in view with its first row, when keys or the pad got there: under the mouse the
    -- list never moves)
    if menu.dev ~= 'mouse' and menu.top == menu.sel and menu.sel > 1 and ls[menu.sel - 1] and ls[menu.sel - 1].head then
      menu.top = menu.sel - 1
    end
    local shown = min(visible, #ls - menu.top + 1)
    local hb = rh + 2 * px                     -- the title bar
    local ph = hb + shown * rh + 3 * px + rh + 2 * px
    local y0 = floor(h * 0.85)                 -- the panel's top edge (y grows upward)
    local col = ctx.color
    local yellow, ink = col(255, 231, 16, 255), col(17, 17, 17, 255)
    local white, green, gray = col(232, 232, 226, 255), col(143, 224, 143, 255), col(125, 135, 127, 255)
    local tx = 7 * px                          -- the text's left inset
    local function midy(y, hgt) return y + floor((hgt - 7 * px) / 2) end
    -- text cut to the room it has, measured (the game's font is proportional), in the font's characters
    local P = ctx.text_native and ctx.text_native() and caps or plain
    local fit, tw = ctx.text_fit or fit_cells, ctx.text_width
    local inner = pw - 2 * tx                  -- the width between the insets
    -- panel, frame, title bar
    ctx.rect(x0, y0 - ph, pw, ph, col(9, 11, 10, 238), top)
    local b = max(1, floor(px * 0.75))
    ctx.rect(x0, y0 - ph, pw, b, yellow, top + 3); ctx.rect(x0, y0 - b, pw, b, yellow, top + 3)
    ctx.rect(x0, y0 - ph, b, ph, yellow, top + 3); ctx.rect(x0 + pw - b, y0 - ph, b, ph, yellow, top + 3)
    ctx.rect(x0, y0 - hb, pw, hb, yellow, top + 1)
    local head = menu.group and text_of(menu.group.title) or (ctx.LOADER .. ' OPTIONS')
    local right = fit((menu.typing or menu.search ~= '') and P('/' .. menu.search .. (menu.typing and '_' or ''))
      or P(menu_key.value ~= 'off' and menu_key.value or ''), px, floor(inner * 0.45))
    local rw = right ~= '' and tw(right, px) or 0
    ctx.text(x0 + tx, midy(y0 - hb, hb), fit(P(head), px, inner - rw - (rw > 0 and 4 * px or 0)), px, ink, top + 2)
    if rw > 0 then ctx.text(x0 + pw - tx - rw, midy(y0 - hb, hb), right, px, ink, top + 2) end
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
      if not l.head then nav.hit(x0 + b, y, pw - 2 * b, rh, 'line', i) end
      if l.head then
        ctx.text(x0 + tx, ty, fit(P(l.text), px, inner), px, yellow, top + 2)
      elseif l.back then
        ctx.text(x0 + tx + 2 * px, ty, fit(P(l.text), px, inner - 2 * px), px, yellow, top + 2)
      elseif l.pick then
        local aw = tw('>', px)
        ctx.text(x0 + tx + 2 * px, ty, fit(P(text_of(l.text)), px, inner - 2 * px - aw - 4 * px), px, white, top + 2)
        ctx.text(x0 + pw - tx - aw, ty, '>', px, green, top + 2)
        -- (a thin line under my own entry, between it and the mods)
        if l.pick.mod == loader_mod and ls[i + 1] then
          ctx.rect(x0 + tx, y, inner, max(1, floor(px / 2)), col(255, 231, 16, 90), top + 2)
        end
      else
        local r = l.row
        -- the value first (at most 40% of the row), then the label in what's left
        local v = fit(P(value_text(r, users)), px, floor(inner * 0.4))
        local vw = tw(v, px)
        local vx = x0 + pw - tx - vw
        ctx.text(x0 + tx + 2 * px, ty, fit(P(text_of(r.spec.label or r.id)), px, vx - 6 * px - (x0 + tx + 2 * px)), px, white, top + 2)
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
    local clash = clash_hint(ls[menu.sel], users)
    local hy = y0 - ph + px
    if clash and not menu.capture and not menu.typing then
      ctx.text(x0 + tx, midy(hy, rh), fit(clash_drawn(clash, P), px, inner), px, yellow, top + 2)
    else
      local segs = menu.capture and (menu.capture.spec.menu and HINTS.capture_default or HINTS.capture_none)
        or (menu.typing and HINTS.typing) or ((menu.group or menu.search ~= '') and HINTS.group) or HINTS.list
      hint_line(ctx, x0 + tx, hy, rh, px, x0 + tx + inner, segs,
        svc.util and svc.util.key_label(menu_key.value) or menu_key.value, white, white, ink, top + 2, P)
    end
    nav.draw_cursor(top, h)
  end
  -- The full screen look: an opaque terminal, the mods on the left, the open mod's options on the right (at the list
  -- of mods, a preview of the picked one's), the hints at the bottom. The same lines, keys and rows as the compact
  -- panel; only the drawing differs (and the mouse's boxes).
  local function menu_draw_full(ls)
    local w, h = ctx.screen()
    local s = h / 1080
    local px = max(2, floor(h / 360 + 0.5))
    local tpx = max(px + 1, floor(px * 1.6 + 0.5))
    local top = ctx.TOP + 950
    local col = ctx.color
    local yellow, ink = col(255, 231, 16, 255), col(17, 17, 17, 255)
    local white, green, gray, dim = col(232, 232, 226, 255), col(143, 224, 143, 255), col(125, 135, 127, 255), col(80, 88, 82, 255)
    local panel, line, glow = col(17, 21, 19, 255), col(255, 231, 16, 70), col(255, 231, 16, 42)
    local P = ctx.text_native and ctx.text_native() and caps or plain
    local fit, tw = ctx.text_fit or fit_cells, ctx.text_width
    local function midy(y, hgt, p) return y + floor((hgt - 7 * (p or px)) / 2) end
    local m = floor(48 * s)                    -- the outer margin
    -- The game's own bands still draw over mine (the ship's name and the menus' keys along the top, and the
    -- player card and the dispatches along the bottom), so the title and the hints sit just inside those bands:
    -- the header and the hints' strip are taller than what's written in them.
    local hh, fh = floor(150 * s), floor(190 * s)  -- the header's and the hints' height
    local band = floor(66 * s)                 -- the header's written band (under the game's top row)
    local hy = floor(128 * s)                  -- the hints' line (above the player card)
    local rh = 13 * px
    local b = max(1, floor(s * 1.5))
    ctx.rect(0, 0, w, h, col(9, 11, 10, 255), top)
    -- the header: the title, the search (or the loader's name) on the right, a yellow rule under it
    ctx.rect(0, h - hh, w, hh, panel, top + 1)
    ctx.rect(0, h - hh - 2 * b, w, 2 * b, yellow, top + 1)
    local searching = menu.typing or menu.search ~= ''
    local rtext = searching and P('SEARCH /' .. menu.search .. (menu.typing and '_' or '')) or P(ctx.LOADER .. ' ' .. tostring(ctx.VERSION))
    rtext = fit(rtext, px, floor(w * 0.4))
    local rw = tw(rtext, px)
    ctx.text(w - m - rw, midy(h - hh, band), rtext, px, searching and yellow or gray, top + 2)
    -- the title picture (a texture in my patch), centered on the written band (the title in the game's font if the
    -- screen is too narrow for it or the texture isn't there)
    local hc = max(1, floor(band / BANNER_AH + 0.25))
    if not (BANNER_W * hc <= w - 3 * m - rw and nav.banner(m, h - hh + floor((band - BANNER_AH * hc) / 2), hc, top + 2)) then
      ctx.text(m, midy(h - hh, band, tpx), fit(P('MOD OPTIONS'), tpx, w - 3 * m - rw), tpx, yellow, top + 2)
    end
    -- the two panes, side by side
    local py0, py1 = fh + floor(8 * s), h - hh - floor(24 * s)
    local lw = floor(w * 0.27)
    local lx, rx = m, m + lw + floor(24 * s)
    local rwid = w - m - rx
    local function pane(x, wd, title, note)
      ctx.rect(x, py0, wd, py1 - py0, panel, top + 1)
      ctx.rect(x, py1 - b, wd, b, line, top + 2); ctx.rect(x, py0, wd, b, line, top + 2)
      ctx.rect(x, py0, b, py1 - py0, line, top + 2); ctx.rect(x + wd - b, py0, b, py1 - py0, line, top + 2)
      local nw = note and tw(note, px) or 0
      ctx.text(x + 4 * px, midy(py1 - rh - 2 * px, rh), fit(P(title), px, wd - 12 * px - nw), px, gray, top + 3)
      if note then ctx.text(x + wd - 4 * px - nw, midy(py1 - rh - 2 * px, rh), note, px, gray, top + 3) end
      ctx.rect(x + 3 * px, py1 - rh - 3 * px, wd - 6 * px, b, line, top + 2)
    end
    local function lit(x, wd, y)
      ctx.rect(x + b, y, wd - 2 * b, rh, glow, top + 3)
      ctx.rect(x + b, y, 2 * px, rh, yellow, top + 4)
    end
    local visible = max(3, floor((py1 - py0 - rh - 6 * px) / rh))
    nav.visible = visible                      -- (the wheel keeps the picked line among the lines in view)
    -- (ls: the lines, when a section's heading should stay in view with its first row; not under the mouse)
    local function scroll(sel, first, n, ls)
      if sel < first then first = sel elseif sel >= first + visible then first = sel - visible + 1 end
      if ls and menu.dev ~= 'mouse' and first == sel and sel > 1 and ls[sel - 1] and ls[sel - 1].head then first = sel - 1 end
      return max(1, min(first, n - visible + 1))
    end
    local users, gs = key_users(), sorted_groups()
    local listing = not menu.group and menu.search == ''       -- at the list of mods the lines are the mods
    -- (the thin line under my own entry, between it and the mods)
    local function divider(dx, dy, dw) ctx.rect(dx, dy, dw, max(1, floor(px / 2)), col(255, 231, 16, 90), top + 4) end
    -- the left pane: the mods (at the list, the lines themselves; else every mod, the open one lit, a click opens another)
    pane(lx, lw, 'MODS', tostring(#gs))
    local y = py1 - rh - 4 * px - rh
    if listing then
      menu.top = scroll(menu.sel, menu.top, #ls)
      for i = menu.top, min(#ls, menu.top + visible - 1) do
        local l = ls[i]
        if i == menu.sel then lit(lx, lw, y) end
        local n = tostring(#l.pick.rows)
        local nw = tw(n, px)
        ctx.text(lx + 6 * px, midy(y, rh), fit(P(text_of(l.text)), px, lw - 16 * px - nw), px, i == menu.sel and yellow or white, top + 4)
        ctx.text(lx + lw - 5 * px - nw, midy(y, rh), n, px, gray, top + 4)
        nav.hit(lx, y, lw, rh, 'line', i)
        if l.pick.mod == loader_mod and ls[i + 1] then divider(lx + 4 * px, y, lw - 8 * px) end
        y = y - rh
      end
    else
      local open = 1
      for i, g in ipairs(gs) do if g == menu.group then open = i end end
      nav.ltop = scroll(open, nav.ltop, #gs)
      for i = nav.ltop, min(#gs, nav.ltop + visible - 1) do
        local g = gs[i]
        local on = g == menu.group
        if on then lit(lx, lw, y) end
        ctx.text(lx + 6 * px, midy(y, rh), fit(P(text_of(g.title)), px, lw - 12 * px), px, on and yellow or gray, top + 4)
        nav.hit(lx, y, lw, rh, 'group', i)
        if g.mod == loader_mod and gs[i + 1] then divider(lx + 4 * px, y, lw - 8 * px) end
        y = y - rh
      end
    end
    -- the right pane: the open mod's rows (or the search's), or at the list a preview of the picked mod's, dimmed
    local rows, title
    if listing then
      local l = ls[menu.sel]
      rows = {}
      if l and l.pick then
        if nav.pv_g ~= l.pick or nav.pv_ver ~= ver.layout then
          nav.pv_g, nav.pv_ver, nav.pv = l.pick, ver.layout, group_lines(l.pick, {})
        end
        rows = nav.pv
      end
      title = l and l.pick and text_of(l.pick.title) or ''
    else
      rows, title = ls, menu.group and text_of(menu.group.title) or 'SEARCH'
      menu.top = scroll(menu.sel, menu.top, #ls, ls)
    end
    pane(rx, rwid, title, listing and #rows > 0 and P('ENTER OPENS') or nil)
    local inner = rwid - 12 * px
    local vmax = floor(inner * 0.42)
    local first = listing and 1 or menu.top
    y = py1 - rh - 4 * px - rh
    for i = first, min(#rows, first + visible - 1) do
      local l = rows[i]
      local sel = not listing and i == menu.sel and not l.head
      if sel then lit(rx, rwid, y) end
      local ty, x = midy(y, rh), rx + 6 * px
      if l.head then
        ctx.text(rx + 4 * px, ty, fit(P(text_of(l.text)), px, inner), px, yellow, top + 4)
      elseif l.back then
        ctx.text(x, ty, fit(P(l.text), px, inner), px, yellow, top + 4)
        nav.hit(rx, y, rwid, rh, 'line', i)
      else
        local r = l.row
        local sp = r.spec
        local x1 = rx + rwid - 6 * px                 -- the value's right edge
        local v = fit(P(value_text(r, users)), px, vmax - 12 * px)
        local vw = tw(v, px)
        local live = not listing
        local lcol = live and white or dim
        local vcol = not live and dim or ((sp.type == 'toggle' and not r.value) and gray or (menu.capture == r and yellow or green))
        if live then nav.hit(rx, y, rwid, rh, 'line', i) end
        if sp.type == 'choice' or sp.type == 'slider' then
          -- < value >, each arrow a box of its own for the mouse; a slider's bar under them takes a click or a drag
          local aw = tw('>', px)
          local ax = x1 - aw
          local vx = ax - 4 * px - vw
          local bx = vx - 4 * px - aw
          ctx.text(bx, ty, '<', px, sel and yellow or gray, top + 4)
          ctx.text(vx, ty, v, px, vcol, top + 4)
          ctx.text(ax, ty, '>', px, sel and yellow or gray, top + 4)
          if live then
            nav.hit(bx - 2 * px, y, aw + 4 * px, rh, 'dec', i)
            nav.hit(ax - 2 * px, y, aw + 4 * px, rh, 'inc', i)
          end
          if sp.type == 'slider' then
            local sx, sw, th = x1 - vmax, vmax, max(1, floor(px / 2))
            local f = max(0, min(1, (r.value - sp.min) / (sp.max - sp.min)))
            ctx.rect(sx, y + px, sw, th, live and gray or dim, top + 4)
            if f > 0 then ctx.rect(sx, y + px, max(1, floor(sw * f)), th, live and yellow or dim, top + 5) end
            if live then nav.hit(sx, y, sw, 2 * px + th, 'bar', i) end
          end
          ctx.text(x, ty, fit(P(text_of(sp.label or r.id)), px, bx - 8 * px - x), px, lcol, top + 4)
        else
          local vx = x1 - vw
          ctx.text(x, ty, fit(P(text_of(sp.label or r.id)), px, vx - 8 * px - x), px, lcol, top + 4)
          if sp.type == 'key' and menu.capture ~= r then
            -- a key: a light chip with the key's name in ink
            ctx.rect(vx - 2 * px, y + 2 * px, vw + 4 * px, rh - 4 * px, live and white or dim, top + 4)
            ctx.text(vx, ty, v, px, ink, top + 5)
          else
            ctx.text(vx, ty, v, px, vcol, top + 4)
          end
        end
      end
      y = y - rh
    end
    -- the hints: for what was used last, the keyboard, the mouse or the controller (its buttons as pictures)
    ctx.rect(0, fh, w, b, line, top + 1)
    local dev = menu.dev
    if dev == 'pad' and (not nav.pad or menu.capture or menu.typing) then dev = 'keys' end
    if dev == 'mouse' and not nav.mouse then dev = 'keys' end
    local close_key = svc.util and svc.util.key_label(menu_key.value) or menu_key.value
    -- (a key bound more than once: the hint line says what else uses it, whatever was used last)
    local clash = not menu.typing and clash_hint(ls[menu.sel], key_users())
    if clash then
      ctx.text(m, midy(hy, rh), fit(clash_drawn(clash, P), px, w - 2 * m), px, yellow, top + 2)
    elseif dev == 'pad' then
      local x, c = m, px
      local gy = hy + floor((rh - 9 * c) / 2)
      local parts = { 'dpad', 'MOVE', 'enter', 'PICK', 'back', 'BACK', 'delete', 'DEFAULT', nil, nav.ps and 'L1/R1 PAGE' or 'LB/RB PAGE' }
      for k = 1, 10 do
        local it = parts[k]
        if it and GLYPH_OF[it] then x = x + nav.glyph(it, x, gy, c, top + 3) + 2 * px
        elseif it then x = x + (ctx.text(x, midy(hy, rh), P(it), px, white, top + 2) or 0) + 6 * px end
      end
    else
      local segs = menu.capture and (menu.capture.spec.menu and HINTS.capture_default or HINTS.capture_none)
        or (menu.typing and HINTS.typing) or (dev == 'mouse' and HINTS.mouse)
        or ((menu.group or menu.search ~= '') and HINTS.group) or HINTS.list
      hint_line(ctx, m, hy, rh, px, w - m, segs, close_key, white, white, ink, top + 2, P)
    end
    nav.draw_cursor(top, h)
  end
  -- where the menu's cursor is (menu pixels, y up; nil before the mouse was read)
  function svc.menu_cursor() return nav.mx, nav.my end
  -- open now? (mods' key and mouse-button reads answer nothing while it is: sandbox.lua, runtime.lua, chef.typed)
  function svc.menu_open() return menu.open == true end
  -- the menu's cursor and left button, for the performance monitor to be dragged with: only on the ship, while the
  -- menu is open and has the mouse (nil otherwise)
  function svc.menu_mouse()
    if menu.open and nav.mouse and nav.mx and nav.on_ship() then return nav.mx, nav.my, nav.lmb == true end
  end
  -- the layer my full screen menu covers from, while it's open (nil while it isn't)
  function svc.covering()
    if menu.open and look_row.value == 1 and nav.on_ship() then return ctx.TOP + 950 end
  end
  local function menu_frame()
    local mk = menu_key.value
    -- the controller: read only while the menu is open, or while closed when the touchpad / View held two seconds opens it
    for k in pairs(nav.act) do nav.act[k] = nil end
    local pv = pad_row.value
    local in_mission = not nav.on_ship()
    -- (a new world: nothing held from the last one carries over)
    local wk = (ctx.world.instance or 0) * 65536 + (ctx.world.id or 0)
    if wk ~= nav.wk then nav.wk = wk; if next(nav.held) then nav.held, nav.seed = {}, true end end
    if pv ~= 3 and (menu.open or (pv == 1 and not in_mission)) then nav.pad_read(not menu.open)
    elseif next(nav.held) then nav.held = {} end   -- (no reads: no hold kept from before, it would open the menu by itself)
    local combo = pv == 1 and not in_mission and nav.held.touch
    if not menu.open and combo and not nav.combo and ctx.now() - combo >= 2 then
      nav.combo = true
      menu.open, menu.group, menu.search, menu.sel, menu.top, menu.typing = true, nil, '', 1, 1, false
      nav.drag = nil
      nav.lmb, nav.rmb, menu.dev, nav.nhits, nav.seed = true, true, 'pad', 0, true
      log('options menu opened (controller)')
    end
    if not combo then nav.combo = false end
    -- the mouse (only while open): the cursor, the wheel and the clicks of this frame
    nav.mouse = menu.open and nav.mouse_on()
    if nav.mouse then local w, h = ctx.screen(); nav.mouse_read(w, h) else
      nav.click, nav.rclick, nav.wheel = false, false, 0
      local H = nav.hold
      H.paused, H.other = false, nil
      if H.on then nav.hold_give() elseif H.had then nav.hold_heal() end
    end
    -- the controller's back (circle/B) or a right click: one level back, at the list of mods it closes (Start isn't
    -- used: the game would open its own pause menu with it too)
    -- (a step back is still drawn this frame, so the menu never leaves a frame with nothing drawn: no flash)
    local stepped = false
    if menu.open and menu.capture == nil and not menu.typing and (nav.act.back or nav.rclick) then
      if menu.group or menu.search ~= '' then go_back(); stepped = true else menu.open = false; return end
    end
    if not stepped and menu.open and menu.capture == nil and not menu.typing and pressed('backspace')
       and (menu.group or menu.search ~= '') then
      -- Backspace steps back too: from a mod's options (or a kept search) to the list of mods, where the cursor was
      go_back(); stepped = true
    end
    if not stepped and menu.open and menu.capture == nil and ((pressed('escape') and not menu.typing) or (mk ~= 'off' and pressed(mk))) then
      menu.open, menu.typing, nav.drag = false, false, nil
      return
    end
    if not menu.open then
      if mk ~= 'off' and pressed(mk) then
        -- it always opens on the list of mods
        menu.open, menu.group, menu.search, menu.sel, menu.top = true, nil, '', 1, 1
        nav.drag = nil
        -- (a mouse button or pad button already down when it opens is no press; no old boxes)
        nav.lmb, nav.rmb, nav.nhits, nav.seed = true, true, 0, true
        if not menu.said then menu.said = true; log('options menu opened') end
      else
        return
      end
    end
    -- the open mod stopped and its options went: back to the list
    if menu.group and #menu.group.rows == 0 then menu.group, menu.sel, menu.top = nil, 1, 1 end
    local typing = not stepped and menu.capture == nil and search_input()
    local ls = lines()
    if #ls == 0 and menu.search == '' then return end
    local g0, s0 = menu.group, menu.search
    if not typing and not stepped then menu_input(ls) end
    nav.nhits = 0
    -- (the lines again when what was picked this frame opened a mod or went back: both looks draw the new screen in
    -- this same frame, so the compact panel's size and hint line never trail it by a frame)
    if menu.group ~= g0 or menu.search ~= s0 then ls = lines() end
    -- (the full screen look covers the game: on the ship only; in a mission the compact panel)
    if look_row.value == 1 and nav.on_ship() then
      -- (texts of the top world under it aren't drawn while it's open: the game's font would show through it)
      if ctx.cover then ctx.cover(ctx.TOP + 950) end
      menu_draw_full(ls)
    else menu_draw(ls) end
  end

  -- ---------------------------------------------- the look-alikes of the other loaders' APIs
  -- Lua-only mods written for the other loaders find the API they call: CowboyBingusModLoader (and its alias
  -- HD2ModLoader), ModOptionsMenu, ModBindingsMenu and BingusRuntime, with the same names, call shapes and answers.
  -- I give every locked-down mod its own set (bind_lookalikes, as the loader makes the mod's environment), always,
  -- even when another loader's tables sit in the game's globals (the sandbox hides those): fresh functions that know
  -- which mod calls them, over the one set of rows and hooks, so no mod can change another's, and a mod that stops has
  -- its callbacks end with it. The set in the game's globals is for full-access boot scripts.
  -- Each callback a mod registers here runs as that mod: timed as its own (the performance monitor and its budget) and
  -- crash-guarded under "<mod>|<what>:<id>" like its hooks, so one that ends the game is skipped from the next launch.
  -- shim.bingus / .mom / .keys_ok: false when something else had the name in the game's globals (then I leave that
  -- global alone; the mods still get mine).
  -- upd / down: the on_update / on_shutdown(id, fn) hooks ({ order, hooks, pos }): one id namespace across the mods,
  -- where an id belongs to the mod that set it first, and only that mod can replace or clear it (refused: what);
  -- last: the on_shutdown(fn) list; logs: the open_log names opened this launch; guards: the running BingusRuntime
  -- guards (ended: the stopped ones, which only take part in shutdown); keys: the ModBindingsMenu bindings by id
  -- (rel: those that trigger on release); rt: the one runtime table every mod's BingusRuntime reads through; seeded:
  -- the other loaders' settings files, read once each; home: a mod's first options heading (its bindings join it);
  -- titles: the heading each title went to first; per: options per mod and heading; frame: my frame count (for the
  -- release sampling and the once-a-frame guards); ml: the mod list by name, built at most once a frame.
  local shim = { count = { rows = 0, mods = 0, keys = 0 }, upd = { order = {}, hooks = {}, pos = {} },
                 down = { order = {}, hooks = {}, pos = {} }, last = {}, logs = {}, guards = {}, ended = {}, keys = {},
                 rel = {}, kidx = {}, kat = {}, rev = 0, seeded = {}, said = {}, pending = {}, home = {}, titles = {}, per = {},
                 refused = {}, frame = 0, ml = { at = -1 },
                 rt = { hashes = {}, statuses = {}, versions = { [1] = true }, hash_reads = 0 } }
  local MOM_PER_MOD, MOM_MODS = 32, 112
  local REVISION = 'chef-shared-loader-' .. tostring(ctx.VERSION)
  local BINGUS_CAPS = { api = 1, logs = true, discovery = true, after_startup = true, on_update = true, on_shutdown = true,
                        open_log = true, mod_options = true, mod_bindings = true,
                        health = false, jit_budget = false, build_gate = false, ffi = false, jit = false }
  local function read_only(t, what)
    return setmetatable({}, { __index = t, __metatable = 'locked', __newindex = function() error(what .. ' is read-only', 2) end })
  end
  -- (a callback's crash key: no '|' or control characters, so it reads back from the trace as one owner|key)
  local function key_for(what, id) return what .. ':' .. tostring(id):gsub('[%c|]', '_'):sub(1, 64) end
  -- a look-alike callback run as the mod that registered it -> ok, err (pcall's answer; false, 'skipped' when it
  -- crashed an earlier launch). The box carries the inner pcall's answer out of the timed call.
  local box = {}
  local function boxed(owner, key, fn, ...) box[1], box[2] = guarded(owner, key, pcall, fn, ...) end
  local function run_as(owner, key, fn, ...)
    box[1], box[2] = nil, nil
    local a, u = recs[owner], svc.util
    if a and u then u.timed(a, boxed, owner, key, fn, ...) else boxed(owner, key, fn, ...) end
    local ok, err = box[1], box[2]
    if ok == nil then return false, err or 'skipped' end
    return ok, err
  end

  -- on_update(id, fn) / on_shutdown(id, fn): fn nil removes the id. Each id is in the order once (set, cleared and set
  -- again keeps its one place); a cleared one leaves the order at once, or at the end of a walk that's running.
  local function compact_hooks(L)
    local j = 0
    for i = 1, #L.order do
      local id = L.order[i]
      L.order[i] = nil
      if L.hooks[id] then j = j + 1; L.order[j] = id else L.pos[id] = nil end
    end
    L.stale = false
  end
  local function hook_set(L, what, owner, id, fn)
    if type(id) ~= 'string' or id == '' then return false, what .. ' needs a string id' end
    if fn ~= nil and type(fn) ~= 'function' then return false, what .. ' needs a function or nil' end
    local h = L.hooks[id]
    if h and h.owner ~= owner then
      local said = owner .. '|' .. what .. '|' .. id
      if not shim.refused[said] then
        shim.refused[said] = true
        log(fmt('[%s] %s "%s": refused, the id is %s\'s', owner, what, id, h.owner))
      end
      return false, "id '" .. id .. "' is another mod's"
    end
    if fn == nil then
      if h then
        L.hooks[id], L.stale = nil, true
        if not L.walking then compact_hooks(L) end
      end
      return true
    end
    if not L.pos[id] then
      if #L.order >= 1024 then return false, what .. ': 1024 ids already registered' end
      L.order[#L.order + 1], L.pos[id] = id, true
    end
    L.hooks[id] = { owner = owner, fn = fn, key = key_for(what, id) }
    return true
  end
  -- every hook of a list once, in the order registered; an on_update hook that raises is dropped (logged)
  local function run_hooks(L, what, ...)
    L.walking = true
    for i = 1, #L.order do
      local id = L.order[i]
      local h = L.hooks[id]
      if h then
        local ok, err = run_as(h.owner, h.key, h.fn, ...)
        if not ok and what == 'on_update' then
          if L.hooks[id] == h then L.hooks[id], L.stale = nil, true end
          log(err == 'skipped' and fmt('[%s] on_update "%s" skipped (it crashed the game)', h.owner, id)
            or fmt('[%s] on_update "%s" dropped after an error: %s', h.owner, id, err_text(err)))
        elseif not ok then
          log(fmt('[%s] %s "%s": %s', h.owner, what, id, err_text(err)))
        end
      end
    end
    L.walking = false
    if L.stale then compact_hooks(L) end
  end
  -- the loader's mod list by name, built at most once a frame once start-up is over (while mods start, every read
  -- builds it: their states change within the one start-up frame)
  local function mod_list()
    local ml = shim.ml
    if ml.at == shim.frame and started then return ml end
    ml = { at = shim.frame, n = 0, by = {} }
    if svc.util and svc.util.mod_list then
      for _, m in ipairs(svc.util.mod_list()) do ml.n = ml.n + 1; ml.by[m.name] = m end
    end
    shim.ml = ml
    return ml
  end
  -- what a mod's modules entry says, in the API's words: loaded, loading, or load failed and why; nil for a name I
  -- never found. A mod another loader started before handing off to me counts as loaded.
  local function module_state(name)
    if type(name) ~= 'string' then return nil end
    local a, st, why, on = ctx.addon(name), nil, nil, nil
    if a then
      st, why, on = a.state, a.why, a.on
    else
      if name:sub(1, 5) ~= 'mods/' then return nil end
      local m = mod_list().by[name]
      if not m then return nil end
      st, why, on = m.state, m.why, m.on
    end
    if st == 'started elsewhere' then return 'loaded' end
    if on and st == 'running' then return 'loaded' end
    if on and st == nil then return 'loading' end
    return 'load failed: ' .. tostring(why or st or 'off')
  end
  -- the game's build, asked once (the look-alike's game table): checked is always true, as I carry no copy of the
  -- game's own boot that a game update could leave stale
  local function game_info()
    if not shim.game then
      local v = guarded('loader', 'Application.build_identifier', fn_of('Application.build_identifier'))
      shim.game = { build_identifier = (type(v) == 'string' or type(v) == 'number') and v or nil, checked = true }
    end
    return shim.game
  end
  local function make_bingus(owner)
    local dir = ctx.DIR:gsub('\\$', '')
    local b = {
      api = 1, version = 17, revision = REVISION, loader = ctx.LOADER .. ' ' .. ctx.VERSION, log_directory = dir,
      capabilities = read_only(BINGUS_CAPS, 'CowboyBingusModLoader.capabilities'),
      game = read_only(game_info(), 'CowboyBingusModLoader.game'),
      -- (a view: each read asks the loader's mod list as it is then; it can't be walked with pairs)
      modules = setmetatable({}, { __index = function(_, name) return module_state(name) end, __metatable = 'locked',
        __newindex = function() error('CowboyBingusModLoader.modules is read-only', 2) end }),
      jit = read_only({ managed = false, reason = 'Lua 5.1 standard interpreter (no JIT)' }, 'CowboyBingusModLoader.jit'),
      build = read_only({ supported = true }, 'CowboyBingusModLoader.build'),
      after_startup = function(fn) return after_startup(owner, fn) end,
      on_update = function(id, fn) return hook_set(shim.upd, 'on_update', owner, id, fn) end,
      -- both forms: (id, fn) runs with the mods' shutdown hooks, (fn) after everything else, before the logs close
      on_shutdown = function(a1, a2)
        if type(a1) == 'string' then return hook_set(shim.down, 'on_shutdown', owner, a1, a2) end
        if type(a1) ~= 'function' then return false, 'on_shutdown needs (id, fn) or (fn)' end
        if #shim.last >= 1024 then return false, 'on_shutdown: 1024 functions already registered' end
        shim.last[#shim.last + 1] = { owner = owner, fn = a1, key = 'on_shutdown#' .. (#shim.last + 1) }
        return true
      end,
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
        -- a fresh file on a name's first open each launch, added to after that (and always a mod's own_log)
        local f = ctx.open(ctx.DIR .. name, (shim.logs[base] or o) and 'a' or 'w')
        if f then shim.logs[base] = true end
        return f
      end,
    }
    -- discovery: how many mods I found, counted when it's read (the list is complete once start-up is over)
    return setmetatable(b, { __metatable = 'locked', __index = function(_, k)
      if k == 'discovery' then return mod_list().n .. ' declared entries' end
    end })
  end

  -- ModOptionsMenu's rules: an id up to 96 characters, a label, toggle / choice (2 to 16) / slider; the same id again
  -- is fine only with the same kind, default and range. o: { kind, s (the row's spec), default, n, min, max, step }.
  -- (gap, profile and profiles are the other loader's window layout: taken and left unused.) A slider step is
  -- optional here: without one the row moves in twentieths, as it always did in my menu.
  local function mom_option(id, spec)
    if type(id) ~= 'string' or id == '' or #id > 96 or id:find('%c') or type(spec) ~= 'table' then return nil, 'invalid option registration' end
    local ty, label = spec.type, spec.label
    if not ((type(label) == 'string' and label:find('%S')) or type(label) == 'function') then return nil, 'invalid option registration' end
    if ty ~= 'toggle' and ty ~= 'choice' and ty ~= 'slider' then return nil, 'type must be toggle, choice or slider' end
    if ty == 'choice' and (type(spec.choices) ~= 'table' or #spec.choices < 2 or #spec.choices > 16) then return nil, 'choices must list 2 to 16 names' end
    local st = ty == 'slider' and spec.step or nil
    if ty == 'slider' and not (finite(spec.min) and finite(spec.max) and spec.min < spec.max
        and (st == nil or st == 0 or (finite(st) and st > 0 and st <= spec.max - spec.min))) then
      return nil, 'slider needs min < max and 0 < step <= max - min'
    end
    local s = { type = ty, label = label, default = spec.default, choices = spec.choices, min = spec.min, max = spec.max,
                step = st, description = spec.description }
    local d = spec.default
    if ty == 'toggle' then d = d == true elseif ty == 'choice' then d = d or 1 else d = d or spec.min end
    return { kind = ty, s = s, default = clean(s, d), n = ty == 'choice' and #spec.choices or nil, min = s.min, max = s.max, step = st }
  end
  local function mom_same(a, b)
    if a.kind ~= b.kind or a.default ~= b.default then return false end
    if a.kind == 'choice' then return a.n == b.n end
    if a.kind == 'slider' then return a.min == b.min and a.max == b.max and a.step == b.step end
    return true
  end
  -- a number as an option's value, or nil when it isn't one (a slider's is snapped into its range)
  local function mom_number(o, v)
    if type(v) ~= 'number' or v ~= v then return nil end
    if o.kind == 'choice' then return (v % 1 == 0 and v >= 1 and v <= o.n) and v or nil end
    if o.kind == 'slider' and finite(v) then return clean(o.s, v) end
    return nil
  end
  local function mom_decode(o, text)
    if type(text) ~= 'string' then return nil end
    text = text:match('^%s*(.-)%s*$')
    if o.kind == 'toggle' then
      if text == 'true' then return true elseif text == 'false' then return false end
      return nil
    end
    return mom_number(o, tonumber(text))
  end
  -- key=value or id<TAB>value lines of another loader's settings file (1 MB at most), read once; {} when it's not there
  local function old_values(path, tab)
    local t = shim.seeded[path]
    if t then return t end
    t = {}
    local f = ctx.open(path, 'rb')
    if f then
      local ok, text = pcall(f.read, f, 1048576)
      pcall(f.close, f)
      if ok and type(text) == 'string' then
        for k, v in text:gmatch(tab and '([^\t\r\n]+)\t([^\r\n]*)' or '([^=\r\n]+)=([^\r\n]*)') do t[k] = v end
      end
    end
    shim.seeded[path] = t
    return t
  end
  -- An option I have no value saved for yet takes the one a player set with the other loaders: the settings
  -- window's mom_<mod>_settings.txt next to my log, else the old menu's ModOptionsMenu.values in %LOCALAPPDATA%.
  -- Once carried over it's mine (marked, so going back to the default later never brings the old value back).
  local function seed(r, o, id, base)
    if get('ModOptionsMenu', r.key) ~= nil or get('ModOptionsMenu.seeded', r.key) ~= nil then return end
    local v, from = nil, nil
    local gdir, ldir = M.GAME_DIR or ctx.DIR, M.OLD_DIR or ctx.OLD_DIR
    if gdir and base then
      from = 'mom_' .. base .. '_settings.txt'
      v = mom_decode(o, old_values(gdir .. from)[(id:gsub('[^%w_]', '_'))])
    end
    if v == nil and ldir then
      local p = ldir .. 'CowboyBingus\\Helldivers2\\Logs\\ModOptionsMenu.values'
      local t = old_values(p, true)
      if next(t) == nil then t = old_values(p .. '.bak', true) end
      from = 'ModOptionsMenu.values'
      v = mom_decode(o, t[id])
    end
    if v == nil then return end
    put('ModOptionsMenu.seeded', r.key, true)
    if v ~= r.value then
      r.value = v
      if v ~= r.default then put('ModOptionsMenu', r.key, v) end
    end
    if not shim.said[from] then shim.said[from] = true; log('ModOptionsMenu: carried over the values set in ' .. from) end
  end
  -- a row moved out of its look-alike's home group into the mod's own
  -- (once: a binding registered again after its mod was started again keeps the place its row has)
  local function place(r, home, key, title)
    if r.placed then return group_of[r.placed] end
    local g = group(key, title)
    local h = group_of[home]
    if h and h ~= g then
      for i = #h.rows, 1, -1 do if h.rows[i] == r then table.remove(h.rows, i) end end
      g.rows[#g.rows + 1] = r
      ver.layout = ver.layout + 1
    end
    r.placed = key
    return g
  end
  local function mom_row(id) return rows_by_id['ModOptionsMenu|' .. tostring(id)] end
  local function make_mom(owner)
    local mom = { api = 1, version = 3, max_mods = MOM_MODS, max_options = MOM_PER_MOD, revision = REVISION,
                  window = ctx.LOADER .. ' options menu' }
    -- (the mod's own short name for its heading: mods/<author>/<name> -> "name")
    local tail = owner:match('^mods/') and owner:match('([%w_]+)$') or nil
    function mom.register_option(id, spec)
      local o, why = mom_option(id, spec)
      if not o then return false, why end
      local r = mom_row(id)
      if r then
        if not r.mom or mom_same(r.mom, o) then return true end
        return false, 'option already registered differently'
      end
      local mod_id = spec.mod_id
      if mod_id ~= nil and (type(mod_id) ~= 'string' or #mod_id > 64 or not mod_id:find('^[%w_%.%-/:]+$')) then return false, 'invalid mod_id' end
      local title = spec.mod ~= nil and text_of(spec.mod) or (tail and (tail:gsub('_', ' '))) or 'MODS'
      -- (without a mod_id, an option joins the heading of that title, the one a mod_id made too)
      local key = mod_id and ('mom#' .. mod_id) or shim.titles[title] or ('mom:' .. title)
      local count, g, per = shim.count, group_of[key], owner .. '|' .. key
      if count.rows >= MOM_PER_MOD * MOM_MODS then return false, 'register_option: ' .. MOM_PER_MOD * MOM_MODS .. ' options already' end
      if (shim.per[per] or 0) >= MOM_PER_MOD then return false, 'mod already has ' .. MOM_PER_MOD .. ' options' end
      if not g and count.mods >= MOM_MODS then return false, 'all ' .. MOM_MODS .. ' mod categories are in use' end
      local err
      r, err = add_row(owner, 'ModOptionsMenu', 'MODS', id, o.s)
      if not r then return false, err end
      r.mom = o
      count.rows = count.rows + 1
      if not g then count.mods = count.mods + 1 end
      -- each mod (mod_id, else spec.mod, else the mod itself) gets its own heading: the row moves there
      place(r, 'ModOptionsMenu', key, title)
      shim.per[per] = (shim.per[per] or 0) + 1
      shim.home[owner] = shim.home[owner] or key
      shim.titles[title] = shim.titles[title] or key
      local base = (mod_id or tail or title):lower():gsub('[^%w]+', '_'):match('^_*(.-)_*$')
      seed(r, o, id, base ~= '' and base or 'mod')
      -- on_change callbacks asked for before the option existed
      local p = shim.pending[id]
      if p then
        shim.pending[id] = nil
        for _, c in ipairs(p) do on_change(r, c.owner, function(v) return c.fn(v, id) end) end
      end
      return true
    end
    function mom.get(id) local r = mom_row(id); if r then return r.value end end
    function mom.set(id, v)
      local r = mom_row(id)
      if not r then return false, 'unknown option' end
      local o = r.mom
      if o then
        if o.kind ~= 'toggle' then v = mom_number(o, v) end
        if (o.kind == 'toggle' and type(v) ~= 'boolean') or v == nil then return false, 'invalid value' end
      end
      local a = recs[owner]
      if a then as_caller(a, set_row, r, v) else set_row(r, v) end
      return true
    end
    function mom.on_change(id, fn)
      if type(id) ~= 'string' or type(fn) ~= 'function' then return false, 'invalid callback' end
      local r = mom_row(id)
      if r then return on_change(r, owner, function(v) return fn(v, id) end) end
      local p = shim.pending[id] or {}
      if #p >= 64 then return false end
      p[#p + 1] = { owner = owner, fn = fn }
      shim.pending[id] = p
      return true
    end
    function mom.ready() return true end
    return mom
  end

  -- ModBindingsMenu: each binding is a key row in my menu (the rows chef.bind makes), under the mod's heading.
  -- A default is a key name or a { button, device, trigger, modifiers } spec, or a list of them: the first keyboard or
  -- mouse one without modifiers counts (mouse middle / extra_1 / extra_2 are "mouse 3/4/5"); press by default.
  local MOUSE_NAMES = { middle = 'mouse 3', extra_1 = 'mouse 4', extra_2 = 'mouse 5' }
  local MOUSE_BUTTONS = { ['mouse 3'] = { 'middle', 'middle button' }, ['mouse 4'] = { 'extra_1', 'x button 1' },
                          ['mouse 5'] = { 'extra_2', 'x button 2' } }
  local function mbm_default(spec)
    if spec == nil then return '', 'press' end
    local list = (type(spec) == 'table' and spec.button == nil) and spec or { spec }
    for _, x in ipairs(list) do
      local button, device, trigger = x, 'keyboard', 'press'
      if type(x) == 'table' then
        if type(x.modifiers) == 'table' and x.modifiers[1] ~= nil then button = nil end
        button, device, trigger = button and x.button, x.device or 'keyboard', x.trigger or 'press'
      end
      if type(button) == 'string' and (trigger == 'press' or trigger == 'release' or trigger == 'hold') then
        button = button:lower()
        if device == 'mouse' then button = MOUSE_NAMES[button] elseif device ~= 'keyboard' then button = nil end
        if button then return button, trigger end
      end
    end
    return '', 'press'
  end
  -- a key's engine index ({ index, the pressed call, the held call }), asked once per name. No index (the keyboard
  -- isn't ready in the first frames on some setups) is false for 2 s, then asked again; a call that failed or was
  -- skipped (it crashed a launch for the mod asking) isn't an answer: nothing is kept, and the next mod asks again.
  local function key_ref(owner, name)
    local k = shim.kidx[name]
    if k or (k == false and ctx.now() < (shim.kat[name] or 0)) then return k end
    local answered = true
    k = false
    if MOUSE_BUTTONS[name] then
      for _, n in ipairs(MOUSE_BUTTONS[name]) do
        local i, e = guarded(owner, 'Mouse.button_index', fn_of('Mouse.button_index'), n)
        if type(i) == 'number' then k = { i, 'Mouse.pressed', 'Mouse.button' }; break end
        if e ~= nil then answered = false end
      end
    else
      local i, e = guarded(owner, 'Keyboard.button_index', fn_of('Keyboard.button_index'), name)
      if i ~= nil then k = { i, 'Keyboard.pressed', 'Keyboard.button' } elseif e ~= nil then answered = false end
    end
    if k then shim.kidx[name] = k elseif answered then shim.kidx[name], shim.kat[name] = false, ctx.now() + 2 end
    return k
  end
  -- went down this frame (how 2) or held (how 3); the engine call is the asking mod's
  local function key_state(owner, b, how)
    local name = b.row.value
    if name == 'off' then return false end
    local k = key_ref(owner, name)
    if not k then return false end
    local v = guarded(owner, k[how], fn_of(k[how]), k[1])
    return v == true or (type(v) == 'number' and v > 0.5)
  end
  local function mbm_is_down(owner, id)
    local b = shim.keys[id]
    if b == nil then return nil end
    if b.row.value == 'off' then return false end
    if menu.open then return false end                       -- my menu has the keys while it's open
    if b.trigger == 'press' then return key_state(owner, b, 2) end
    if b.trigger == 'hold' then return key_state(owner, b, 3) end
    -- release: down last frame, up this one (sampled in svc.frame while some mod keeps asking)
    b.asked = shim.frame
    return b.prev == true and not b.now
  end
  local function make_mbm(owner)
    local tail = owner:match('^mods/') and owner:match('([%w_]+)$') or nil
    local k = { api = 1, version = 4, capacity = 36, loader = REVISION, window = ctx.LOADER .. ' options menu',
                extended = setmetatable({ devices = { 'keyboard', 'mouse' }, triggers = { 'press', 'release', 'hold' } },
                  { __index = function(_, f) if f == 'count' then return shim.count.keys end end }) }
    function k.register_binding(id, label, slot, options)
      if type(id) ~= 'string' or id == '' or #id > 96 or id:find('%c') or (slot ~= nil and type(slot) ~= 'number')
         or (options ~= nil and type(options) ~= 'table') then
        return false, 'invalid binding registration'
      end
      options = options or {}
      local text = type(label) == 'number' and id or ((type(label) == 'string' or type(label) == 'function') and text_of(label)) or nil
      if not text or not text:find('%S') or #text > 127 then return false, 'invalid binding registration' end
      local category = nil
      if options.category ~= nil then
        category = type(options.category) == 'string' and options.category:find('%S') and options.category or nil
        if not category or #category > 64 then return false, 'invalid binding category' end
      end
      local b = shim.keys[id]
      if b then
        if b.label == text and b.slot == slot then return true end
        return false, 'binding already registered differently'
      end
      if shim.count.keys >= 36 * MOM_MODS then return false, 'all ' .. 36 * MOM_MODS .. ' bindings are in use' end
      local name, trigger = mbm_default(options.default)
      local r, err = add_row(owner, 'ModBindingsMenu', 'KEYS', id, { type = 'key', default = name ~= '' and name or 'off', label = text })
      if not r then return false, err end
      local title = category or (tail and (tail:gsub('_', ' '))) or 'MODS'
      local key = category and (shim.titles[category] or 'mom:' .. category) or shim.home[owner] or shim.titles[title] or ('mom:' .. title)
      place(r, 'ModBindingsMenu', key, title)
      shim.titles[title] = shim.titles[title] or key
      b = { id = id, label = text, slot = slot, trigger = trigger, row = r, owner = owner }
      shim.keys[id] = b
      if trigger == 'release' then shim.rel[#shim.rel + 1] = b end
      shim.count.keys, shim.rev = shim.count.keys + 1, shim.rev + 1
      note_conflicts()
      return true
    end
    function k.is_down(id) return mbm_is_down(owner, id) end
    function k.ready() return true end
    -- poll(ids, out): is_down of each, with pressed / released since this out table's last poll
    function k.poll(ids, out)
      if type(ids) ~= 'table' or type(out) ~= 'table' then return false, 'invalid poll arguments' end
      for _, f in ipairs({ 'down', 'pressed', 'released', 'last' }) do
        if out[f] == nil then out[f] = {} elseif type(out[f]) ~= 'table' then return false, 'invalid poll arguments' end
      end
      for i = 1, #ids do
        local down = mbm_is_down(owner, ids[i])
        local was = out.last[i] == true
        out.down[i], out.pressed[i], out.released[i], out.last[i] = down, down == true and not was, was and down ~= true, down == true
      end
      return true
    end
    -- set_binding(id, spec): {} clears it, nil gives the default back
    function k.set_binding(id, spec)
      local b = shim.keys[id]
      if b == nil then return false, 'not an extended binding' end
      local name
      if spec == nil then name = b.row.default
      elseif type(spec) == 'table' and spec.button == nil and spec[1] == nil then name = 'off'
      else
        name = mbm_default(spec)
        if name == '' then return false, 'invalid binding' end
      end
      local a = recs[owner]
      if a then as_caller(a, set_row, b.row, name) else set_row(b.row, name) end
      return true
    end
    function k.binding(id)
      local b = shim.keys[id]
      if b == nil then return nil end
      local name = b.row.value
      if name == 'off' then return {} end
      local button = name
      for m, n in pairs(MOUSE_NAMES) do if n == name then button = m end end
      return { { MOUSE_BUTTONS[name] and 'mouse' or 'keyboard', button, modifiers = {}, trigger = b.trigger } }
    end
    function k.binding_info(id)
      local b = shim.keys[id]
      if b == nil then return nil end
      local v, d = b.row.value, b.row.default
      return { backend = 'extended', state = (v == 'off' and d ~= 'off') and 'cleared' or (v == d and 'default' or 'set') }
    end
    -- revision: one more for every binding registered (any mod's)
    return setmetatable(k, { __index = function(_, f) if f == 'revision' then return shim.rev end end })
  end

  -- BingusRuntime: one runtime table for every mod (hashes, statuses, versions, hash_reads), read through each mod's
  -- own BingusRuntime, which has its own shared() and guard(). A guard's install() puts its step / after on my frame
  -- (never on the mod's update, which only runs as a hook for some mods), at most once a frame, and its stop on my
  -- shutdown, with the API's error and clean-frame counting. (A failed update below the mod can't happen here, so a
  -- guard never pauses.) Mods read the statuses (and each guard's status) as read-only views, each mod its own (a
  -- rawset into a view changes only that mod's view, never what another mod reads); hashes and versions are each
  -- mod's own writable tables over the shared ones; the shared table takes no new names, only a number for
  -- hash_reads. (5.1 has no __pairs: a view can't be listed with pairs.)
  local function list_without(list, drop)
    local out = {}
    for _, x in ipairs(list) do if not drop(x) then out[#out + 1] = x end end
    return out
  end
  local function make_rt(owner, env)
    local core = shim.rt
    local own = {}
    -- this mod's views: of the statuses, of each guard's status (by the status table), of the other shared tables
    local views, status_views = {}, {}
    views.statuses = setmetatable({}, { __metatable = 'locked',
      __index = function(_, n)
        local st = core.statuses[n]
        if type(st) ~= 'table' then return st end
        local v = status_views[st]
        if not v then v = read_only(st, 'a guard\'s status'); status_views[st] = v end
        return v
      end,
      __newindex = function() error('BingusRuntime.statuses is read-only', 2) end })
    -- (only into the mod's own environment: another table could be one that other mods read)
    function own.shared(e)
      core.versions[1] = true
      rawset(env, 'BingusRuntime', own)
      return own
    end
    function own.guard(spec)
      local name = type(spec) == 'table' and spec.name
      if type(name) ~= 'string' or name == '' then error('guard name required', 0) end
      own.shared(spec.env)
      local had = core.statuses[name]
      if had ~= nil and had.installed then error('guard ' .. name .. ' already installed', 0) end
      -- (status is mine to write; the mods read it through their own views)
      local status = { errors = 0, installed = false, lower_errors = 0, pauses = 0, state = 'new', name = name, version = 1 }
      core.statuses[name] = status
      local step, after, stop_fn, log_fn = spec.step, spec.after, spec.stop, spec.log
      local most, clean_at = tonumber(spec.errors) or 8, tonumber(spec.clean) or 3600
      -- (the counts are the guard's own; status shows them)
      local g = { owner = owner, key = key_for('guard', name), stopped = false, errors = 0, clean = 0, bad = false, at = -1 }
      local function say(msg) if type(log_fn) == 'function' then pcall(log_fn, msg) end end
      local function stop(reason)
        if g.stopped then return end
        g.stopped = true
        status.first_failure = status.first_failure or reason
        status.state = 'stopped: ' .. reason
        say(name .. ' stopped: ' .. reason)
        if type(stop_fn) == 'function' then
          local ok, e = pcall(stop_fn, reason)
          if not ok then status.stop_error = err_text(e) end
        end
      end
      local function failed(e)
        g.bad, g.clean = true, 0
        g.errors = g.errors + 1
        status.errors = g.errors
        local msg = err_text(e)
        status.first_error = status.first_error or msg
        if g.errors == 1 then status.burst_error = msg; say(name .. ' error: ' .. msg) end
        if g.errors >= most then stop('stopped after ' .. most .. ' errors: ' .. tostring(status.burst_error)) end
      end
      function g.tick(dt)
        if g.stopped or g.at == shim.frame then return end
        g.at, g.bad = shim.frame, false
        if type(step) == 'function' then local ok, e = pcall(step, dt); if not ok then failed(e) end end
        if g.stopped then return end
        if type(after) == 'function' then local ok, e = pcall(after); if not ok then failed(e) end end
        if not g.bad then
          g.clean = g.clean + 1
          if g.clean == clean_at then g.errors, status.errors = 0, 0 end
        end
      end
      function g.down()
        if not g.stopped then
          g.stopped = true
          if type(stop_fn) == 'function' then
            local ok, e = pcall(stop_fn, 'shutdown')
            if not ok then status.stop_error = err_text(e) end
          end
        end
        status.state = status.first_failure and ('stopped after: ' .. status.first_failure) or 'stopped'
      end
      local handle = { status = views.statuses[name] }
      function handle.install()
        if g.installed then error('guard ' .. name .. ' already installed', 0) end
        if #shim.guards >= 256 then error('256 guards already installed', 0) end
        g.installed, status.installed, status.state = true, true, 'running'
        shim.guards[#shim.guards + 1] = g
        return handle
      end
      function handle.stop(reason) stop(tostring(reason)) end
      function handle.running() return g.installed == true and not g.stopped end
      return handle
    end
    -- reads: the shared table (its statuses as a read-only view); writes: hash_reads only (a number), anything else
    -- is refused and logged once per mod and name
    local mine = {}
    return setmetatable(own, { __metatable = 'locked',
      __index = function(_, k)
        -- (hashes and versions: the mod's own writable table over the shared one, so what it writes stays its own)
        if k == 'hashes' or k == 'versions' then
          local t = mine[k]
          if not t then t = setmetatable({}, { __index = core[k], __metatable = false }); mine[k] = t end
          return t
        end
        local v = views[k]
        if v then return v end
        v = core[k]
        if type(v) == 'table' then v = read_only(v, 'BingusRuntime.' .. tostring(k)); views[k] = v end
        return v
      end,
      __newindex = function(_, k, v)
        if k == 'hash_reads' and type(v) == 'number' then rawset(core, k, v); return end
        local said = owner .. '|rt|' .. tostring(k)
        if not shim.refused[said] then
          shim.refused[said] = true
          log(fmt('[%s] BingusRuntime.%s = ...: refused (the shared table keeps hashes, statuses, versions and hash_reads)',
            owner, tostring(k)))
        end
      end })
  end
  -- a stopped mod's look-alike hooks, guards, bindings (their release sampling with them; the key rows and their
  -- saved values stay in my menu) and waiting on_change callbacks go. Lists a loop may be walking are replaced, not
  -- changed in place.
  function shim.forget(owner)
    local mine = function(x) return x.owner == owner end
    for _, L in ipairs({ shim.upd, shim.down }) do
      for id, h in pairs(L.hooks) do if h.owner == owner then L.hooks[id], L.stale = nil, true end end
      if L.stale and not L.walking then compact_hooks(L) end
    end
    shim.last, shim.rel = list_without(shim.last, mine), list_without(shim.rel, mine)
    for _, g in ipairs(shim.guards) do if g.owner == owner then g.gone = true end end
    shim.guards, shim.ended = list_without(shim.guards, mine), list_without(shim.ended, mine)
    for id, b in pairs(shim.keys) do
      if b.owner == owner then shim.keys[id], shim.count.keys = nil, shim.count.keys - 1 end
    end
    for id, p in pairs(shim.pending) do
      for i = #p, 1, -1 do if p[i].owner == owner then table.remove(p, i) end end
      if #p == 0 then shim.pending[id] = nil end
    end
  end
  -- package.loaded's fallback in every mod's environment: another addon's module (true while it starts, or when it
  -- returned nothing), nil when it isn't running
  function svc.module_of(name)
    if type(name) ~= 'string' or name:sub(1, 5) ~= 'mods/' then return nil end
    local a = ctx.addon(name)
    if not a or not a.on then return nil end
    local m = a.module
    -- (a trusted mod's module stays its own: only that it's running)
    local sbx = svc.sandbox
    if sbx and sbx.trusted and sbx.trusted(name) then return true end
    if a.state == 'running' and type(m) == 'table' and (next(m) ~= nil or getmetatable(m) ~= nil) then return m end
    return true
  end
  function svc.install_shims(G)
    shim.bingus = rawget(G, 'CowboyBingusModLoader') == nil
    if shim.bingus then
      local b = make_bingus('bingus look-alike')
      rawset(G, 'CowboyBingusModLoader', b)
      if rawget(G, 'HD2ModLoader') == nil then rawset(G, 'HD2ModLoader', b) end
      log('look-alike: CowboyBingusModLoader and HD2ModLoader (the Bingus Shared Loader v21 / Boot Mod Loader API: '
        .. 'on_update, on_shutdown, after_startup, open_log, game, modules, capabilities)')
    end
    shim.mom = rawget(G, 'ModOptionsMenu') == nil
    if shim.mom then
      rawset(G, 'ModOptionsMenu', make_mom('ModOptionsMenu'))
      log('look-alike: ModOptionsMenu (register_option, get, set, on_change, ready; rows in the ' .. ctx.LOADER .. ' options menu)')
    end
    shim.keys_ok = rawget(G, 'ModBindingsMenu') == nil
    if shim.keys_ok then
      rawset(G, 'ModBindingsMenu', make_mbm('ModBindingsMenu'))
      log('look-alike: ModBindingsMenu (register_binding, is_down, poll, set_binding, binding; keys in the ' .. ctx.LOADER .. ' options menu)')
    end
  end
  -- one mod's own set, put straight into its environment, whatever the game's globals hold (another loader's tables
  -- there would hand a mod that loader's unchecked file access). A trusted mod gets no BingusRuntime: its shared
  -- table is a place other mods read.
  function svc.bind_lookalikes(env, owner)
    if type(env) ~= 'table' or type(owner) ~= 'string' then return false end
    local b = make_bingus(owner)
    rawset(env, 'CowboyBingusModLoader', b)
    rawset(env, 'HD2ModLoader', b)
    rawset(env, 'ModOptionsMenu', make_mom(owner))
    rawset(env, 'ModBindingsMenu', make_mbm(owner))
    local sb = svc.sandbox
    if not (sb and sb.trusted and sb.trusted(owner)) then rawset(env, 'BingusRuntime', make_rt(owner, env)) end
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
        if mod and mod:match(ctx.ALLOW) and not mod:find('//', 1, true) and (kind == 'Addon' or kind == 'Boot' or kind == 'Options') then
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
  -- end, the utilities drop its timers, jobs and what it spawned, the HD2Runtime look-alike undoes what it made, and its
  -- look-alike hooks (on_update, on_shutdown, guards) end.
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
    if svc.runtime then svc.runtime.forget(owner) end
    shim.forget(owner)
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
  -- dt: the game's update argument, handed on to the look-alike on_update hooks and guards
  function svc.frame(dt)
    -- the look-alike hooks first: the bindings that trigger on release, sampled (only while a mod that's on has asked
    -- about one in the last 30 frames, and never while my menu has the keys); on_update(id, fn); the guards
    local fno = shim.frame + 1
    shim.frame = fno
    if shim.rel[1] and not menu.open then
      for i = 1, #shim.rel do
        local b = shim.rel[i]
        local a = recs[b.owner]
        if b.asked and fno - b.asked <= 30 and (not a or a.on ~= false) then
          local d = key_state(b.owner, b, 3)
          -- (sampling that starts again begins from what the key is now: no release out of a stale sample)
          b.prev, b.now, b.at = (b.at == fno - 1) and b.now or d, d, fno
        end
      end
    end
    if shim.upd.order[1] then run_hooks(shim.upd, 'on_update', dt) end
    if shim.guards[1] then
      local list, stopped = shim.guards, false
      for i = 1, #list do
        local g = list[i]
        if not (g.stopped or g.gone) then run_as(g.owner, g.key, g.tick, dt) end
        if g.stopped then stopped = true end
      end
      -- a stopped guard costs nothing a frame from then on: it waits in ended for my shutdown
      if stopped then
        for _, g in ipairs(shim.guards) do if g.stopped and not g.gone then shim.ended[#shim.ended + 1] = g end end
        shim.guards = list_without(shim.guards, function(g) return g.stopped end)
      end
    end
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
    pcall(nav.hold_give)                   -- (the mouse back to the game first: nothing below may keep it)
    -- the guards stop first, then the look-alike's on_shutdown(id, fn) hooks; its on_shutdown(fn) ones run last (after
    -- every mod's and boot script's shutdown), before the settings are saved and the mods' logs close
    for _, list in ipairs({ shim.guards, shim.ended }) do
      for i = 1, #list do run_as(list[i].owner, list[i].key, list[i].down) end
    end
    if shim.down.order[1] then run_hooks(shim.down, 'on_shutdown') end
    emit('shutdown')
    for i = 1, #shim.last do
      local c = shim.last[i]
      local ok, err = run_as(c.owner, c.key, c.fn)
      if not ok then log(fmt('[%s] on_shutdown(fn) #%d: %s', c.owner, i, err_text(err))) end
    end
    if dirty then save_now() end
    for _, o in pairs(own_logs) do pcall(o.f.close, o.f) end
  end
  return svc
end

return M