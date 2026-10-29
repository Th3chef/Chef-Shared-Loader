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
  local by, out, state, path = {}, {}, {}, {}
  for _, r in ipairs(list) do if not by[r.name] then by[r.name] = r end end
  local function visit(r, depth)
    if state[r] == 'done' or depth > 32 then return end
    -- (a circle: every mod on it is marked, from r round to the one that came back to it, so none of them is started
    -- first only to be told the next one isn't running; a mod that merely needs one of them isn't on it. path: the
    -- mods being visited, in order)
    if state[r] == 'busy' then
      for i = #path, 1, -1 do path[i].cycle = true; if path[i] == r then break end end
      return
    end
    state[r] = 'busy'
    path[#path + 1] = r
    for _, q in ipairs(M.requirements(r.src)) do
      local d = by[q.name]
      if d and d ~= r then visit(d, depth + 1) end
    end
    path[#path] = nil
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
-- The keys shown are the ones the game ignores: the arrows ('<' and '>' are Left and Right, the only arrows both fonts
-- have), Delete, '/' and the menu's own key. Enter, Escape and Backspace still work in my menu but the game hears them
-- too (Enter opens its chat and the letters typed after it go there, Escape and Backspace its pause screen), so the
-- hints never offer them where another key does the same.
local KEY_NOW = false
local HINTS = {
  capture_default = { { word = 'PRESS A KEY' }, { 'ESC', word = 'CANCEL' }, { 'DEL', word = 'DEFAULT' } },
  capture_none = { { word = 'PRESS A KEY' }, { 'ESC', word = 'CANCEL' }, { 'DEL', word = 'NONE' } },
  typing = { { word = 'TYPE TO SEARCH', opt = true }, { 'DOWN', word = 'RESULTS' }, { 'BKSP', word = 'ERASE' },
             { '/', word = 'EXIT' } },
  -- (in an entry or a search: on a key or a button, Right acts and Left goes back; value is a toggle's, a choice's, a
  -- slider's or a color's, where Left and Right change it; back is the Back row's, where both go back)
  group = { { 'ARROWS', word = 'MOVE', opt = true }, { '>', word = 'CHANGE' }, { 'DEL', word = 'DEFAULT' },
            { '<', word = 'BACK' }, { KEY_NOW, word = 'CLOSE' } },
  -- (a key or a button inside an open fold: Left closes the fold, the cursor on its heading)
  group_fold = { { 'ARROWS', word = 'MOVE', opt = true }, { '>', word = 'CHANGE' }, { 'DEL', word = 'DEFAULT' },
                 { '<', word = 'FOLD' }, { KEY_NOW, word = 'CLOSE' } },
  back = { { 'ARROWS', word = 'MOVE', opt = true }, { '<', '>', word = 'BACK' }, { KEY_NOW, word = 'CLOSE' } },
  value = { { 'ARROWS', word = 'MOVE', opt = true }, { '<', '>', word = 'CHANGE' }, { 'DEL', word = 'DEFAULT' },
            { KEY_NOW, word = 'CLOSE' } },
  list = { { 'ARROWS', word = 'MOVE', opt = true }, { '>', word = 'OPEN' }, { '/', word = 'SEARCH' },
           { KEY_NOW, word = 'CLOSE' } },
  -- (on a mod's heading, a fold: closed, Right opens it and Left goes back; open, Left closes it, FOLD so it doesn't
  -- read as the menu's own CLOSE next to it)
  fold_shut = { { 'ARROWS', word = 'MOVE', opt = true }, { '>', word = 'OPEN' }, { '<', word = 'BACK' },
                { KEY_NOW, word = 'CLOSE' } },
  fold_open = { { 'ARROWS', word = 'MOVE', opt = true }, { '<', word = 'FOLD' }, { KEY_NOW, word = 'CLOSE' } },
  mouse = { { 'CLICK', word = 'PICK' }, { '<', '>', word = 'CHANGE' }, { 'RIGHT CLICK', word = 'BACK' },
            { 'WHEEL', word = 'SCROLL' }, { KEY_NOW, word = 'CLOSE' } },
}
-- A hint line from x (y its row's bottom, rh its height) up to x_end: in a pair its keys a little apart and the word
-- close after them, the next pair further off; a chip is at least as wide as a capital letter. When the whole line
-- doesn't fit, the optional pairs go, then the gaps narrow (a pair's word still closer to its keys than the next
-- pair); past that, the pairs that don't fit are left off the end.
-- (a hint text's width, asked of the loader every time: it keeps a text's width in the game's font by the text as
-- translated and for the font it measured it with, never a guessed glyph's, so a language or font changed under the
-- menu lays the line out anew, where a cache of my own would go stale; a key's chip; a pair, the gap after it not
-- counted; the whole line. Plain functions, so a line laid out every frame makes no closures)
local function hint_tw(ctx, t, px) return ctx.text_width(t, px) end
local function hint_chip_w(ctx, k, key, px, P) return math.max(hint_tw(ctx, P(k or key or ''), px), 5 * px) + 4 * px end
local function hint_pair_w(ctx, pr, key, px, P, wgap)
  local w = 0
  for k = 1, #pr do w = w + hint_chip_w(ctx, pr[k], key, px, P) + (k > 1 and 3 * px or 0) end
  if pr.word then w = w + (#pr > 0 and wgap or 0) + hint_tw(ctx, P(pr.word), px) end
  return w
end
local function hint_line_w(ctx, pairs_, with_opt, gap, key, px, P, wgap)
  local w, any = 0, false
  for _, pr in ipairs(pairs_) do
    if with_opt or not pr.opt then w = w + (any and gap or 0) + hint_pair_w(ctx, pr, key, px, P, wgap); any = true end
  end
  return w
end
local function hint_line(ctx, x, y, rh, px, x_end, pairs_, key, word_c, chip_c, ink, layer, P)
  local ty = y + math.floor((rh - 7 * px) / 2)
  local wgap = 6 * px                                -- (between a pair's keys and its word)
  local room = x_end - x
  local with_opt, gap = true, 12 * px
  if hint_line_w(ctx, pairs_, true, gap, key, px, P, wgap) > room then
    with_opt = false
    if hint_line_w(ctx, pairs_, false, gap, key, px, P, wgap) > room then gap, wgap = 8 * px, 4 * px end
  end
  local first = true
  for _, pr in ipairs(pairs_) do
    if with_opt or not pr.opt then
      local pw = hint_pair_w(ctx, pr, key, px, P, wgap)
      if (first and 0 or gap) + pw > x_end - x then break end
      if not first then x = x + gap end
      first = false
      for k = 1, #pr do
        local t = P(pr[k] or key or '')
        local w = hint_tw(ctx, t, px)
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
        x = x + hint_tw(ctx, t, px)
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
-- A binding's value can be a combo, 'ctrl+shift+f6': the modifiers first, always in this order, then the key (either
-- side's key counts for a modifier), or a controller button, 'pad:cross' (the name the pad gives it). MOD_OF: what I
-- take as each modifier when a mod or a look-alike spec names one.
local MODS = { 'ctrl', 'shift', 'alt' }
local MOD_KEYS = { ctrl = { 'left ctrl', 'right ctrl' }, shift = { 'left shift', 'right shift' }, alt = { 'left alt', 'right alt' } }
local MOD_OF = { ctrl = 'ctrl', control = 'ctrl', shift = 'shift', alt = 'alt' }
for m, ks in pairs(MOD_KEYS) do MOD_OF[ks[1]] = m; MOD_OF[ks[2]] = m end
-- a value as I keep it: in lower case, spaces trimmed, the modifiers in their order ('Shift + Ctrl+F6' is
-- 'ctrl+shift+f6', 'Pad: Left Shoulder' is 'pad:left_shoulder'); nil for nothing. A word in front of a '+' that isn't
-- a modifier is part of the key ('numpad +' stays a key).
local function key_value(s)
  if type(s) ~= 'string' then return nil end
  s = s:lower():gsub('%s+', ' ')
  local has = {}
  while true do
    local w, rest = s:match('^ ?([%a ]-) ?%+(.+)$')
    local m = w and MOD_OF[w]
    if not m then break end
    has[m], s = true, rest
  end
  local key = s:match('^ ?(.-) ?$')
  -- (a controller button takes no modifiers)
  local pad = key:match('^pad ?: ?(.+)$')
  if pad then return 'pad:' .. (pad:gsub(' ', '_')) end
  if key == '' then return nil end
  if key == 'off' then return 'off' end
  local front = ''
  for _, m in ipairs(MODS) do if has[m] then front = front .. m .. '+' end end
  return front .. key
end
-- a kept value's parts: false for a plain key (read by its name alone), else { key, mods = { 'ctrl', ... } } or
-- { pad = name }
local function key_parts(v)
  if type(v) ~= 'string' then return false end
  local pad = v:match('^pad:(.+)$')
  if pad then return { pad = pad } end
  local mods, s = {}, v
  while true do
    local w, rest = s:match('^(%a+)%+(.+)$')
    if not (w and MOD_KEYS[w]) then break end
    mods[#mods + 1], s = w, rest
  end
  if not mods[1] then return false end
  return { key = s, mods = mods }
end

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
  -- (src: a label function's chunk name, the mod it belongs to, asked of the debug library once per function: text_of)
  -- (pk: the packages, by patch file: svc.pk_settle)
  local ver = { layout = 0, keys = 0, rows = 0, src = setmetatable({}, { __mode = 'k' }), pk = {} }
  local function group(mod, title)
    local g = group_of[mod]
    if not g then
      g = { mod = mod, title = title or mod, rows = {} }
      group_of[mod] = g; groups[#groups + 1] = g
      ver.layout = ver.layout + 1
    elseif title and g.title == mod then
      g.title = title; ver.layout = ver.layout + 1
      -- (its switch's label is its name: svc.mod_switch)
      local s = rows_by_id[mod .. '|#on']
      if s then s.spec.label = svc.mod_title(mod) end
    end
    return g
  end
  -- A mod's reset button (s.reset, made with its switch) follows the switch: last in the entry the switch is in, once
  -- the mod has an option (b.wanted), so a row added later or a switch moved takes it along. (b.at: the group it's in;
  -- g.reset: the reset button in g, which the full screen look doesn't count among the mod's rows)
  local function reset_tail(mod)
    local s = rows_by_id[mod .. '|#on']
    local b = s and s.reset
    -- (a package's part has none in any list: the main mod's resets its rows, svc.pk_settle)
    if not (b and b.wanted) or s.part then return end
    local to = s.at or group_of[mod]
    if not to or (b.at == to and to.rows[#to.rows] == b) then return end
    if b.at then
      local rows = b.at.rows
      for i = #rows, 1, -1 do if rows[i] == b then table.remove(rows, i) end end
      b.at.reset = nil
    end
    to.rows[#to.rows + 1] = b
    b.at, to.reset = to, b
    ver.layout = ver.layout + 1
  end
  -- A mod's on/off row (svc.mod_switch) sits first in the group that holds its options, so each mod is one entry in
  -- the list: its own group when that holds options of its own (chef.option); else the first look-alike heading (place)
  -- that holds its rows and no other mod's; else its own group, as its only row. A heading two mods share takes
  -- neither switch: that entry is the heading's, not one mod's, and a switch first in it would read as the whole
  -- heading's, so each stays in its mod's own entry. Only the row's place changes (its mod and saved key stay), and
  -- only as rows arrive, never in a frame. (s.at: the group the switch is in; g.own: the owners whose rows place put
  -- in g, g.owners how many). A package's part has no switch in any list (s.part, s.at false: svc.pk_settle), and a
  -- heading only its package's mods fill counts as the main mod's alone.
  local function settle(mod)
    local s, home = rows_by_id[mod .. '|#on'], group_of[mod]
    if not (s and s.switch and home) or s.part then return end
    local to, own = home, false
    for _, r in ipairs(home.rows) do if r ~= s and r ~= s.reset then own = true; break end end
    if not own then
      for _, g in ipairs(groups) do
        local o = g.own
        if o and o[mod] then
          local only = g.owners == 1
          if not only and s.pk then
            only = true
            for m in pairs(o) do
              local q = rows_by_id[m .. '|#on']
              if not (q and q.pk == s.pk) then only = false end
            end
          end
          if only then to = g; break end
        end
      end
    end
    local at = s.at
    if at == nil then at = home end
    if at == to then return end
    if at then for i = #at.rows, 1, -1 do if at.rows[i] == s then table.remove(at.rows, i) end end end
    table.insert(to.rows, 1, s)
    s.at = to
    ver.layout = ver.layout + 1
    reset_tail(mod)
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
  -- a label, title or choice as text (a mod's function or odd value can't raise into the menu). A function runs as its
  -- mod (found by its chunk name, '@mods/...') under the hang watchdog (ctx.dog), and not at all once that mod is off.
  local function text_of(v)
    if type(v) == 'function' then
      local D, a = ctx.dog, nil
      if D and D.armed and D.getinfo then
        -- (a function's chunk never changes: its name is kept, the mod's record looked up live)
        local name = ver.src[v]
        if name == nil then
          local info = D.getinfo(v, 'S')
          name = info and type(info.source) == 'string' and info.source:sub(2) or false
          ver.src[v] = name
        end
        a = name and recs[name] or nil
        if a and a.on == false then return '?' end
      end
      local po, ps, pl, pn
      if a then po, ps, pl, pn = D.enter(a, D.clock()) end
      local ok, s = pcall(v)
      if a then D.leave(po, ps, pl, pn) end
      if not ok then return '?' end
      v = s
    end
    if type(v) == 'string' then return v end
    local ok, s = pcall(tostring, v or '')
    return ok and type(s) == 'string' and s or '?'
  end
  -- a color row's value: six hex digits, in capitals ('#' in front taken too); nil for anything else
  local function hex_color(v)
    local h = type(v) == 'string' and v:match('^#?(%x%x%x%x%x%x)$')
    return h and h:upper() or nil
  end
  -- (a color row without its own palette steps through these: white, the Helldivers yellow, then the usual hues)
  local PALETTE = { 'FFFFFF', 'FFE710', 'FF9500', 'FF3B30', 'FF2D55', 'BF5AF2', '5E5CE6', '0A84FF', '32ADE6', '00C7BE',
                    '34C759', 'A2845E', '8E8E93', '000000' }
  local function clean(spec, value)
    local ty = spec.type
    if ty == 'toggle' then return value == true end
    if ty == 'button' then return false end           -- (a button keeps nothing: it's pressed, not set)
    if ty == 'color' then return hex_color(value) or hex_color(spec.default) or 'FFFFFF' end
    if ty == 'choice' then
      local n = #spec.choices
      local v = floor(tonumber(value) or 0)
      if v >= 1 and v <= n then return v end
      -- (a saved choice the mod has since dropped, or none: the row's default, itself kept in range)
      local d = floor(tonumber(spec.default) or 1)
      return (d >= 1 and d <= n) and d or 1
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
      -- the menu's own key is never none or one of the keys the menu uses (it could never be opened again), and
      -- always one plain key
      if spec.menu and (k == 'off' or MENU_KEYS[k] or key_parts(key_value(k))) then return spec.default end
      -- (a row that takes combos keeps them in my order; one without a controller takes no button)
      if spec.combos then
        k = key_value(k) or 'off'
        if not spec.pads and k:find('^pad:') then k = 'off' end
      end
      return k
    end
    return value
  end
  local function finite(n) return type(n) == 'number' and n == n and n > -math.huge and n < math.huge end
  local function check_spec(spec)
    if type(spec) ~= 'table' then return 'the spec must be a table' end
    local ty = spec.type
    if ty ~= 'toggle' and ty ~= 'choice' and ty ~= 'slider' and ty ~= 'key' and ty ~= 'button' and ty ~= 'color' then
      return 'type must be toggle, choice, slider, key, button or color'
    end
    if ty == 'choice' and (type(spec.choices) ~= 'table' or #spec.choices < 2 or #spec.choices > 32) then return 'a choice needs 2 to 32 choices' end
    if ty == 'button' and spec.run ~= nil and type(spec.run) ~= 'function' then return 'a button\'s run is a function' end
    if ty == 'color' and spec.palette ~= nil then
      if type(spec.palette) ~= 'table' or #spec.palette < 2 or #spec.palette > 32 then return 'a color palette has 2 to 32 colors' end
      for _, c in ipairs(spec.palette) do if not hex_color(c) then return 'palette colors are "RRGGBB" hex' end end
    end
    for _, k in ipairs({ 'heading', 'hint' }) do
      if spec[k] ~= nil and (type(spec[k]) ~= 'string' or #spec[k] > 200) then return k .. ' is a string (200 characters at most)' end
    end
    if spec.fold ~= nil and type(spec.fold) ~= 'boolean' then return 'fold is true or false' end
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
    elseif spec.type == 'key' then default = default or 'off'
    elseif spec.type == 'color' then default = default or 'FFFFFF' end
    ver.rows = ver.rows + 1
    row = { id = full, key = row_key(id), mod = mod, spec = spec, owner = owner, changed = {}, n = ver.rows, short = id }
    row.default = clean(spec, default)
    row.value = clean(spec, get(mod, row.key, row.default))
    rows_by_id[full] = row
    local g = group(mod, title)
    g.rows[#g.rows + 1] = row
    ver.layout = ver.layout + 1
    if spec.type == 'key' then ver.keys = ver.keys + 1 end
    -- (a mod's own option after its switch went to a look-alike heading: the switch comes back first above it)
    local s = owner ~= 'loader' and rows_by_id[mod .. '|#on']
    if s and s.at and s.at ~= g then settle(mod) end
    -- (a mod's option wants its reset button, a button of its own doesn't; either keeps the reset button last)
    if owner ~= 'loader' then
      s = rows_by_id[owner .. '|#on']
      if s and s.reset and spec.type ~= 'button' then s.reset.wanted = true end
      reset_tail(owner)
      -- (a package's mod with options of its own may be its main mod now)
      if s and s.pk and not s.opts then s.opts = true; svc.pk_settle(s.pk) end
    end
    return row
  end
  local function set_row(row, v)
    v = clean(row.spec, v)
    if v == row.value then return end
    row.value = v
    if ctx.opt_changed then ctx.opt_changed(row.id) end   -- (into the crash trace: a launch that dies says it)
    if row.spec.type == 'key' then ver.keys = ver.keys + 1 end
    -- the default isn't stored (a new default reaches players who never changed the row); anything else is, false too
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
  -- a button pressed: its run(), then its on_change callbacks (with true), each as the mod that asked for it. Nothing
  -- runs once its mod is off (stopped, or switched off), as text_of does; my own buttons (a mod's reset button too)
  -- are mine and always run.
  local function press(row)
    local a = recs[row.owner]
    if a and a.on == false then return end
    if ctx.opt_changed then ctx.opt_changed(row.id) end
    local run = row.spec.run
    if type(run) == 'function' then
      local ok, err = call_as(row.owner, run)
      if not ok then log(fmt('[%s] button %s: %s', row.owner, row.id, err_text(err))) end
    end
    for _, c in ipairs(row.changed) do
      if c.on then
        local ok, err = call_as(c.owner, c.fn, true)
        if not ok then log(fmt('[%s] on_change %s: %s', c.owner, row.id, err_text(err))) end
      end
    end
  end
  -- a color row one step along its palette (a value not in it starts from the palette's ends)
  local function step_color(row, dir)
    local pal, at = row.spec.palette or PALETTE, nil
    for i, c in ipairs(pal) do if hex_color(c) == row.value then at = i end end
    local i = at and at + dir or (dir > 0 and 1 or #pal)
    if i < 1 then i = #pal elseif i > #pal then i = 1 end
    set_row(row, pal[i])
  end
  -- a key row's value in its parts (key_parts), kept on the row as row.pv / row.pp and worked out again only when the
  -- value changes
  local function row_parts(row)
    local v = row.value
    if row.pv ~= v then row.pv, row.pp = v, key_parts(v) end
    return row.pp
  end
  -- every key some binding uses, for the conflict marks: users[v] is how many key rows clash on value v, the rows set
  -- to v counted in. A combo clashes with the plain binding of its key, both ways, since Ctrl+F6 fires 'ctrl+f6' and
  -- 'f6' alike; two combos on one key with other modifiers don't clash, and a pad button clashes only with itself.
  -- (same: the rows on each value; on: the combo rows on each key; parts: each value's parts)
  local users_cache = { ver = -1, users = nil }
  local function key_users()
    if users_cache.ver == ver.keys then return users_cache.users end
    local same, on, parts = {}, {}, {}
    for _, g in ipairs(groups) do
      for _, row in ipairs(g.rows) do
        local v = row.value
        if row.spec.type == 'key' and v ~= 'off' then
          same[v] = (same[v] or 0) + 1
          local p = row_parts(row)
          parts[v] = p
          if p and p.key then on[p.key] = (on[p.key] or 0) + 1 end
        end
      end
    end
    local users = {}
    for v, n in pairs(same) do
      local p = parts[v]
      if not p then n = n + (on[v] or 0) elseif p.key then n = n + (same[p.key] or 0) end
      users[v] = n
    end
    users_cache.ver, users_cache.users = ver.keys, users
    return users
  end
  local conflicts_said = {}
  local function note_conflicts()
    for k, n in pairs(key_users()) do
      if n > 1 and not conflicts_said[k] then
        conflicts_said[k] = true
        log(fmt('key %s is bound %d times (a combo and the plain key it also fires count as one key; see the options menu: it marks them)', k, n))
      end
    end
  end

  -- ---------------------------------------------------------------- a mod's own log file
  -- chef.own_log(name): from then on the mod's chef.log lines go to <name>.log next to chef_loader.log instead of into
  -- it (a fresh file each launch once it passes 1 MB, the same cap per launch). The loader's own lines about the mod
  -- (started, errors, crashes, timings) stay in chef_loader.log. A mod opens 8 names at most a launch, and all of its
  -- own logs together take what one log may (ctx.LOG_CAP), so a runaway mod can't fill the disk with many of them.
  local own_logs = {}                       -- name -> { f, owner, use = { written } shared by the mod's own logs }
  local function own_open(owner, name)
    local o = own_logs[name]
    if o then
      if o.owner ~= owner then return nil, name .. '.log is ' .. o.owner .. "'s" end
      return o
    end
    -- (its logs so far: how many, and the count they share; opens are rare, so I walk them)
    local n, use = 0, nil
    for _, q in pairs(own_logs) do if q.owner == owner then n, use = n + 1, q.use end end
    if n >= 8 then return nil, 'a mod opens 8 logs of its own at most' end
    local path = ctx.DIR .. name .. '.log'
    local f, big = ctx.open(path, 'r'), false
    if f then local size = f:seek('end'); big = size and size > 1024 * 1024; f:close() end
    f = ctx.open(path, big and 'w' or 'a')
    if not f then return nil, 'could not open ' .. path end
    o = { f = f, owner = owner, use = use or { written = 0 } }
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
    local u = o.use
    if u.written > ctx.LOG_CAP then return end
    local line = fmt('%s %6.1f s | %s', ctx.clock(), ctx.now(), text)
    u.written = u.written + #line + 1
    if u.written > ctx.LOG_CAP then line = line .. '\n(this mod\'s logs are full for this launch)' end
    pcall(o.f.write, o.f, line .. '\n'); pcall(o.f.flush, o.f)
  end

  -- ---------------------------------------------------------------- the helpers each mod gets
  function svc.extend(chef, a)
    local owner = a.name
    local title = a.title
    recs[owner] = a
    chef.api = M.api
    local caps = { api = M.api, after_startup = true, settings = true, share = true, events = true, require = true,
                   bind = true, menu = true, shims = true, dev = true, logs = true, own_log = true, mouse_hold = true,
                   players_event = true, hang_watchdog = ctx.dog ~= nil and ctx.dog.armed == true,
                   option_buttons = true, option_colors = true, option_headings = true, menu_state = true, mod_stopped_event = true, bind_combos = true,
                   option_folds = true }
    if svc.util then for k, v in pairs(svc.util.caps) do caps[k] = v end end
    chef.capabilities = setmetatable({}, { __index = caps,
      __newindex = function() error('chef.capabilities is read-only', 2) end })
    -- (the hang watchdog as it is now, armed or not: ctx.dog)
    function chef.has(name)
      if name == 'hang_watchdog' then return ctx.dog ~= nil and ctx.dog.armed == true end
      return chef.capabilities[name] == true or (name == 'api' and true)
    end
    function chef.after_startup(fn) return after_startup(owner, fn) end
    -- saved settings
    -- (keys starting with opt. are my options menu's: a mod's rows are saved under them, chef.option)
    function chef.save(key, value)
      if type(key) == 'string' and key:find('^opt%.') then return nil, 'keys starting with opt. are the options menu\'s' end
      return put(owner, key, value)
    end
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
    -- the mouse held from the game's camera, and this frame's movement (svc.hold_mouse, svc.mouse_delta)
    function chef.hold_mouse(on) return svc.hold_mouse(owner, on ~= false) end
    function chef.mouse_held() return svc.mouse_held() end
    function chef.mouse_delta() return svc.mouse_delta() end
    -- my options menu: open now? (the 'menu' event says when it opens and closes)
    function chef.menu_open() return svc.menu_open() end
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
      g.titled = true                          -- (its own title: a runtime spec's name never replaces it)
      if g.title ~= t then
        g.title = t; ver.layout = ver.layout + 1
        local s = rows_by_id[owner .. '|#on']
        if s then s.spec.label = svc.mod_title(owner) end
      end
      -- (a package's mod with a title of its own may be its main mod now)
      local s = rows_by_id[owner .. '|#on']
      if s and s.pk then svc.pk_settle(s.pk) end
    end
    function chef.option(id, spec)
      if type(id) ~= 'string' or not id:match('^[%w_%.%-]+$') then return nil, 'ids are letters, digits, _ . -' end
      local row, err = add_row(owner, owner, title or svc.short_title(owner), id, spec)
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
    -- a button row: Right (Enter too, or a click) runs fn as this mod; text is what the row shows on its right ('RUN')
    function chef.button(id, label, fn, text)
      return chef.option(id, { type = 'button', label = label, run = fn, text = text })
    end
    -- a color row's value ('RRGGBB') as three numbers, 0 to 255; nil for anything else
    function chef.rgb(v)
      local h = hex_color(v)
      if not h then return nil end
      return tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
    end
    -- a key binding: a 'key' row in the menu; b.key() is its key ('off' for none), b.pressed() / b.down() this frame
    -- (key names are the engine's, in lower case: 'F6' is taken as 'f6'; a name the keyboard doesn't know is logged)
    -- A combo, 'ctrl+f6' ('Ctrl + F6' is taken as that): pressed in the frame its key goes down while its modifiers
    -- are held, down while they all are. A modifier held that the combo doesn't name doesn't stop it (Shift is the
    -- game's sprint), and a plain key reads the same whether modifiers are held or not: Ctrl+F6 is both 'ctrl+f6' and
    -- 'f6', so my menu marks a combo and the plain binding of its key as clashing. A controller button, 'pad:cross':
    -- svc.pad_bind.
    function chef.bind(id, default_key, label)
      -- (an id that's no id is refused here, before it's put in a row's name)
      if type(id) ~= 'string' or not id:match('^[%w_%.%-]+$') then return nil, 'ids are letters, digits, _ . -' end
      local dk = key_value(default_key) or 'off'
      local dp = key_parts(dk)
      local dn = dp and dp.key or dk
      if dk ~= 'off' and not (dp and dp.pad) and svc.util and svc.util.known_key and not svc.util.known_key(dn) then
        log(fmt('[%s] bind %s: "%s" is not a key name the keyboard knows (players can pick another in the menu)', owner, tostring(id), dn))
      end
      local row, err = chef.option(id, { type = 'key', default = dk, label = label or id, combos = true, pads = true })
      local r = rows_by_id[owner .. '|' .. id]
      if not r then return nil, err end
      note_conflicts()
      -- seen, p: the value last read and its parts (worked out again only when the value changes)
      local b, seen, p = {}, nil, false
      local function parts()
        local v = r.value
        if v ~= seen then seen, p = v, key_parts(v) end
        return p
      end
      -- (the key first: a combo whose key isn't down costs what a plain binding does)
      local function combo(q, edge)
        if q.pad then return svc.pad_bind(q, edge) end
        local k
        if edge then k = chef.key_pressed(q.key) else k = chef.key_down(q.key) end
        if not k then return false end
        for i = 1, #q.mods do
          local two = MOD_KEYS[q.mods[i]]
          if not (chef.key_down(two[1]) or chef.key_down(two[2])) then return false end
        end
        return true
      end
      function b.key() return r.value end
      -- (false while my menu is open, in a capture too: its keys and buttons are its own then, so a key typed or
      -- captured there never fires a binding; svc.menu_open, as the mod's own chef can't change it)
      function b.pressed()
        local v = r.value
        if v == 'off' or svc.menu_open() then return false end
        local q = parts()
        if not q then return chef.key_pressed(v) end
        return combo(q, true)
      end
      function b.down()
        local v = r.value
        if v == 'off' or svc.menu_open() then return false end
        local q = parts()
        if not q then return chef.key_down(v) end
        return combo(q, false)
      end
      return b, row
    end
    chef.log_directory = ctx.DIR:gsub('\\$', '')
    chef.log_file = ctx.DIR .. ctx.FILES .. '.log'
    -- the loader's old folder (%LOCALAPPDATA%), so a mod can pick up its own old files
    -- once (mods may read their .log .txt .json .csv .dat .ini .marker .fatal files there); it's %LOCALAPPDATA% whenever
    -- that isn't the loader's folder now, nil while the loader still keeps its files there (or can't find it)
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
  local menu_place = add_row('loader', loader_mod, ctx.LOADER, 'menu_place', { type = 'choice', label = 'Menu position',
    choices = { 'Left', 'Center', 'Right' }, default = 1, section = 'compact' })
  -- (how see-through the compact panel is, text included: 100 is as it always was, 30 the least, so it's never lost;
  -- the full screen look stays opaque)
  local menu_alpha = add_row('loader', loader_mod, ctx.LOADER, 'menu_alpha', { type = 'slider',
    label = 'Menu opacity (%)', min = 30, max = 100, step = 10, default = 100, section = 'compact' })
  local reload_key = nil
  -- more rows in the loader's own group (the frame budget)
  function svc.loader_option(id, spec)
    local r, err = add_row('loader', loader_mod, ctx.LOADER, id, spec)
    if not r then log('loader option ' .. id .. ': ' .. tostring(err)) end
    return r
  end
  function svc.set_row(r, v) set_row(r, v) end
  -- a row's label and value text changed by me (a retry button once pressed)
  -- (a search finds it by the label it had first too, r.find: a reset button asking or a retry button pressed stays
  -- in the results it was found in)
  function svc.relabel(r, label, text)
    if r.find == nil then r.find = r.spec.label or false end
    r.spec.label, r.spec.text = label, text
    ver.layout = ver.layout + 1
  end
  -- A reset button asking (on: for 3 s, its own label and text kept as b.was) or back as it was. menu.ask: the one
  -- asking now, put back by menu_frame once its time is up, and when the menu closes (opened again, it asks anew;
  -- no SURE? left from before).
  local function reset_ask(b, on)
    if on then
      if menu.ask and menu.ask ~= b then reset_ask(menu.ask, false) end
      if not b.armed then b.was = { b.spec.label, b.spec.text } end
      b.armed, menu.ask = ctx.now() + 3, b
      svc.relabel(b, 'Press again to reset all options', 'SURE?')
    elseif b.armed then
      b.armed = nil
      if menu.ask == b then menu.ask = nil end
      svc.relabel(b, b.was[1], b.was[2])
    end
  end
  -- Every mod I found gets an on/off row of its own, first in its options, so a mod with no options is listed too
  -- (settle puts it where the options are). Off stops it at once (ctx.mod_switched, the usual stop) and it isn't
  -- started at the next launches; on again, it starts at the next launch. True while it's on (or the row couldn't be
  -- made). Its own group is titled by the mod's short name with spaces, as the look-alikes title a heading. Its label
  -- is the mod's name as its entry shows it (svc.mod_title, set again when the mod's title changes: group, chef.title,
  -- svc.mod_named), with its version drawn after it in a dimmer color (nav.ver_row), the way my own title shows mine.
  -- It stays the mod's name in a look-alike heading too (settle): the heading's title is the mod's to pick and may not
  -- name it.
  -- (the short name callers pass is the path's last part: svc.short_title makes it, so a generic one names the folder)
  -- file: the patch file the mod is deployed in; the mods in one file are one package (svc.pk_settle), and a
  -- package's main switch switches its parts too, each through its own switch (r.along: switched with its package,
  -- so the loader tells no notice of its own for it)
  function svc.mod_switch(name, title, file)
    if title == nil or title == name:match('([^/]+)$') then title = svc.short_title(name)
    elseif type(title) == 'string' then title = (title:gsub('_', ' ')) end
    local r = add_row('loader', name, title, '#on', { type = 'toggle', label = name, default = true,
      hint = 'Off: stops now and stays off. On: starts again the next time you launch the game.' })
    if r and not r.switch then
      r.switch, r.at = true, group_of[name]
      r.spec.label = svc.mod_title(name)
      on_change(r, 'loader', function(v)
        if ctx.mod_switched then ctx.mod_switched(name, v, r.along) end
        local p = r.pk
        if p and p.main == r then
          for _, q in ipairs(p.sw) do
            if q ~= r and q.value ~= v then q.along = true; set_row(q, v); q.along = nil end
          end
        end
      end)
      settle(name)
      -- Its reset button: every option and key the mod registered (its rows, by owner, wherever they're listed, the
      -- ones added after this too: the set is taken at the press) back to its default, through set_row as a player's
      -- change goes (its on_change callbacks run, the settings file is written, the key marks are counted again). The
      -- switch is mine, not the mod's: it stays. Two presses: the first asks, a second within 3 s resets. It's out of
      -- every list until the mod has an option (reset_tail), and then last in its entry, out of the way.
      local b
      b = add_row('loader', name, title, '#reset', { type = 'button', label = 'Reset every option to its default',
        text = 'RESET', hint = 'Press twice to reset every option and key of this mod',
        run = function()
          if not (b.armed and ctx.now() < b.armed) then reset_ask(b, true); return end
          reset_ask(b, false)
          local list, n, keys = {}, 0, false
          -- (a package's main mod: its parts' rows too)
          for _, o in pairs(rows_by_id) do
            local q = r.pk and o.owner ~= name and rows_by_id[o.owner .. '|#on']
            if (o.owner == name or (q and q.pk == r.pk)) and o.spec.type ~= 'button' then list[#list + 1] = o end
          end
          sort(list, function(x, y) return x.n < y.n end)
          for _, o in ipairs(list) do
            if o.value ~= o.default then
              set_row(o, o.default)
              n, keys = n + 1, keys or o.spec.type == 'key'
            end
          end
          if keys then conflicts_said = {}; note_conflicts() end
          log(fmt('options reset to defaults: %s (%d row(s))', name, n))
        end })
      if b then
        local g = group_of[name]
        for i = #g.rows, 1, -1 do if g.rows[i] == b then table.remove(g.rows, i) end end
        ver.layout = ver.layout + 1
        r.reset = b
        -- (a mod whose options came before its switch)
        for _, o in pairs(rows_by_id) do
          if o.owner == name and o.spec.type ~= 'button' then b.wanted = true; break end
        end
        reset_tail(name)
      end
      -- (its package: the mods found in the same patch file; a dev mode file is one of its own)
      if type(file) == 'string' and not file:find('^dev:') then
        local p = ver.pk[file]
        if not p then p = { file = file, sw = {} }; ver.pk[file] = p end
        p.sw[#p.sw + 1] = r
        r.pk = p
        for _, o in pairs(rows_by_id) do if o.owner == name then r.opts = true; break end end
        svc.pk_settle(p, r)
      end
    end
    return r == nil or r.value ~= false
  end
  -- Addons deployed in one patch file are one package (a mod and the helpers it ships, as a mod may ship a notification
  -- helper): one entry in my list, its main mod's. The main mod: the one with options of its own (or its own
  -- title, chef.title), else the one whose name isn't a generic one (core, main, init: svc.short_title), else the first
  -- by name. Its switch is the package's: the other parts' switches and reset buttons leave every list (s.part, s.at
  -- false), its entry lists them as INCLUDED lines (group_lines), their options under their names (nav.pk_lines), and
  -- its reset button resets theirs too. Each part keeps its own switch underneath, set as the main one is (its own
  -- saved off, its own stop, as switched from the menu), so a part's start at the next launch follows the package
  -- whatever order the mods start in. The package's value is the one its mods already decided (started or kept off)
  -- hold: they all agree, as only the main switch is listed and it switches them all, so it's the first one's (the
  -- main mod's own while it's alone). A mod joining (joining) takes it quietly, before the loader decides its start,
  -- even when it becomes the main mod: a newcomer never switches the parts already decided. Only a player's flip of
  -- the main switch changes it. Worked out again as mods join and register options or a title; a package of one mod
  -- is as any mod. (p: { file, sw = its mods' switches, main })
  function svc.pk_settle(p, joining)
    local best, rank = nil, -1
    for _, s in ipairs(p.sw) do
      local g, tail = group_of[s.mod], s.mod:match('([^/]+)$') or s.mod
      local k = (s.opts or (g and g.titled)) and 2 or (svc.short_title(s.mod) == (tail:gsub('_', ' ')) and 1 or 0)
      if k > rank or (k == rank and s.mod < best.mod) then best, rank = s, k end
    end
    if best ~= p.main then p.main = best; ver.layout = ver.layout + 1 end
    local pv = (p.sw[1] ~= joining and p.sw[1] or best).value
    for _, s in ipairs(p.sw) do
      if s ~= best then
        if not s.part then
          s.part = true
          local at, b = s.at, s.reset
          if at then for i = #at.rows, 1, -1 do if at.rows[i] == s then table.remove(at.rows, i) end end end
          s.at = false
          if b and b.at then
            for i = #b.at.rows, 1, -1 do if b.at.rows[i] == b then table.remove(b.at.rows, i) end end
            b.at.reset, b.at = nil, nil
          end
          ver.layout = ver.layout + 1
        end
        if s.reset and s.reset.wanted and best.reset then best.reset.wanted = true end
      elseif s.part then
        s.part = nil
      end
      if s.value ~= pv then
        if s == joining then
          s.value = pv
          if s.value == s.default then put(s.mod, s.key, nil) else put(s.mod, s.key, s.value) end
        else
          s.along = true; set_row(s, pv); s.along = nil
        end
      end
    end
    settle(best.mod)
    reset_tail(best.mod)
  end
  -- a mod's name as its entry in the list shows it: its title (chef.title), else its short name with spaces
  function svc.mod_title(name)
    local g = group_of[name]
    if g and type(g.title) == 'string' and g.title ~= name then return g.title end
    return svc.short_title(name)
  end
  -- A mod's short name, as its entry shows it until it titles itself: its path's last part with spaces; a last part
  -- that names no mod (mods/some_helper/core) gives way to the folder above it ("some helper").
  do
    local GENERIC = { core = true, main = true, init = true, mod = true, boot = true, src = true, lua = true,
                      index = true, script = true, plugin = true }
    function svc.short_title(name)
      local up, last = name:match('([^/]+)/([^/]+)$')
      last = last or name
      if up and up ~= 'mods' and GENERIC[last:lower()] then last = up end
      return (last:gsub('_', ' '))
    end
  end
  -- A runtime mod's own name for itself (HD2Runtime.mod{ name = ... }, its file's first mod) titles its entry, unless
  -- the mod titled it itself (chef.title wins, before or after).
  function svc.mod_named(name, t)
    local g = group_of[name]
    if not g or g.titled or type(t) ~= 'string' then return end
    t = t:gsub('%c', ''):match('^%s*(.-)%s*$')
    if t == '' or #t > 48 then return end
    if g.title ~= t then
      g.title = t; ver.layout = ver.layout + 1
      -- (its switch's label is its name: svc.mod_switch)
      local s = rows_by_id[name .. '|#on']
      if s then s.spec.label = svc.mod_title(name) end
    end
  end
  -- every text of my options menu (the mods' titles, the options' labels and choices, the headings), for a language
  -- to note the ones it has no entry for; and the version of that list (it changes with the menu's layout)
  function svc.option_texts()
    local out = { 'MENU', 'COMPACT LOOK', 'CONTROLS', 'PERFORMANCE', 'MONITOR LOOK', 'CRASH RECOVERY', 'MOD OPTIONS',
                  'ALL MODS', 'ALSO USED BY:',
                  -- (the status's fixed words, on an entry's title bar: nav.status)
                  'RUNNING', 'OFF', 'KEPT OFF BY THE CRASH GUARD', 'STOPPED', 'NOT STARTED', 'ON AGAIN AT THE NEXT LAUNCH',
                  'SWITCHED OFF', 'STARTED IN', 'LAST ERROR:', 'LINE', 'ERRORS:',
                  -- (a package's INCLUDED lines: nav.part)
                  'INCLUDED', 'KEPT OFF' }
    for _, g in ipairs(groups) do
      if #g.rows > 0 then
        out[#out + 1] = text_of(g.title)
        for _, r in ipairs(g.rows) do
          -- (a mod's switch is labeled by the mod's name, never a text of mine: svc.mod_switch)
          if not r.switch then out[#out + 1] = text_of(r.spec.label or r.id) end
          for _, k in ipairs({ 'heading', 'hint', 'text' }) do
            if type(r.spec[k]) == 'string' then out[#out + 1] = r.spec[k] end
          end
          if r.spec.type == 'choice' and type(r.spec.choices) == 'table' then
            for _, c in ipairs(r.spec.choices) do out[#out + 1] = text_of(c) end
          end
        end
      end
    end
    -- (a package's parts: named on their INCLUDED lines, in no list of their own)
    for _, p in pairs(ver.pk) do
      for _, s in ipairs(p.sw) do if s.part then out[#out + 1] = text_of(s.spec.label or s.id) end end
    end
    -- (a switched-off mod's label functions, or ones that raise, give '?': no text of anyone's, left out)
    local n = 0
    for i = 1, #out do if out[i] ~= '?' then n = n + 1; out[n] = out[i] end end
    for i = #out, n + 1, -1 do out[i] = nil end
    return out
  end
  function svc.layout_ver() return ver.layout end
  -- the loader's own saved values that aren't a row (the language picked, by name)
  function svc.loader_get(key) return get(loader_mod, key) end
  function svc.loader_put(key, v) return put(loader_mod, key, v) end
  function svc.menu_key_name() return menu_key.value end
  -- ---------------------------------------------- the menu's look, controller and mouse
  -- Rows of their own in the loader's group. The controller: the engine's own pads (Pad1..Pad8, the first one active,
  -- its buttons found by the names the pad lists), the D-pad moves, cross/A picks, circle/B goes back (and closes
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
    choices = { 'On the ship', 'Always', 'Off' }, default = 1, section = 'controls' })
  local pad_row = add_row('loader', loader_mod, ctx.LOADER, 'menu_pad', { type = 'choice', label = 'Controller in this menu',
    choices = { 'On, hold touchpad / View 2 s to open', 'On', 'Off' }, default = 1, section = 'controls' })
  local nav = { pad = nil, look_at = 0, pr_at = 0, ix = {}, held = {}, rep = {}, act = {}, ps = false,
                mx = nil, my = nil, moved = false, wheel = 0, mouse = false, axes = nil, lmb = true, rmb = true,
                click = false, rclick = false, hits = {}, nhits = 0, ltop = 1, binds = {} }
  local PAD_NAMES = { up = { 'd_up', 'up', 'dpad_up' }, down = { 'd_down', 'down', 'dpad_down' },
    left = { 'd_left', 'left', 'dpad_left' }, right = { 'd_right', 'right', 'dpad_right' },
    enter = { 'a', 'cross' }, back = { 'b', 'circle' }, delete = { 'x', 'square' },
    ['page up'] = { 'left_shoulder', 'l1' }, ['page down'] = { 'right_shoulder', 'r1' },
    touch = { 'touch', 'touchpad', 'back', 'view', 'select' } }
  local PAD_ORDER = { 'up', 'down', 'left', 'right', 'enter', 'back', 'delete', 'page up', 'page down', 'touch' }
  local PAD_REPEAT = { up = true, down = true, left = true, right = true }
  local function eng(name, ...) return guarded('loader', name, fn_of(name), ...) end
  -- the first pad that answers, looked for until one does: once a second while my menu is open, every 5 s while it's
  -- closed (16 calls a look with no pad in; the 2 s touchpad / View hold waits for it at most that long). Its buttons
  -- come from the names the pad lists itself (num_buttons, button_name), so no name a pad doesn't know is ever asked
  -- about; the call names are made once per pad found.
  function nav.pad_find()
    local t = ctx.now()
    if t < nav.look_at then return end
    nav.look_at = t + (menu.open and 1 or 5)
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
          nav.by = by                                  -- (every button by its name: bindings and captures)
          nav.calls = { active = p .. '.active', connected = p .. '.connected', button = p .. '.button', name = p .. '.name' }
          nav.name_at = t + 1
          log(fmt('options menu: controller %s (%s)%s', p, nav.pname,
            #miss > 0 and ('; no button for ' .. concat(miss, ', ')) or ''))
          return
        end
      end
    end
  end
  -- the pad found still there (false: gone, looked for again)
  function nav.pad_live()
    local C, now = nav.calls, ctx.now()
    if eng(C.active) ~= true and eng(C.connected) ~= true then nav.pad, nav.look_at, nav.held = nil, 0, {}; return false end
    -- (another pad put in the same slot: its buttons are found again; asked once a second)
    if now >= nav.name_at then
      nav.name_at = now + 1
      local nm = eng(C.name)
      if (type(nm) == 'string' and nm or '?') ~= nav.pname then nav.pad, nav.look_at, nav.held = nil, 0, {}; return false end
    end
    return true
  end
  -- this frame's presses into nav.act (the D-pad repeats while held); nav.held[a]: since when a button is down
  -- (closed: the touchpad / View only, read ten times a second by menu_frame: its live check and one button)
  -- (fno: the frame number; the pad's live check is shared with the pad bindings through nav.pf, so a frame that reads
  -- both asks the engine once)
  function nav.pad_read(closed, fno)
    if not nav.pad then nav.pad_find(); if not nav.pad then return end end
    local C, now = nav.calls, ctx.now()
    if nav.pf ~= fno then
      nav.pf = fno
      if not nav.pad_live() then return end
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
  -- not a mission, and with a level count (the ship's few or none), else no bigger than the ship (about 3800 units; the
  -- smallest missions are about 4800). Anything else counts as a mission: a world still loading, a small mission not
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
  -- open, and put back to what I found once it's closed, checked once a second for 10 s after each hold. A dead zone
  -- already far up (another mod
  -- holds the mouse) is left alone, and my cursor follows the cursor axis all the same (other: asked again once a
  -- second). No dead zone answer: the camera turns with the mouse. My menu takes the hold only when the mouse has a
  -- cursor axis (mouse_read asks for it; without one the camera turns while the menu is open); a mod's hold needs just
  -- the delta axis, since only svc.mouse_delta reads the cursor while it's held.
  -- on: mine; had: what I found; off: not this session; paused: not until the menu closes; ever: a cursor was read
  local HOLD = 917351
  -- (clean: the looks in a row since the hold was let go that found the dead zone not mine: hold_heal)
  nav.hold = { on = false, had = nil, off = false, paused = false, other = nil, ever = false, heal_at = 0, bad = 0, clean = 0 }
  function nav.hold_take()
    local H, A = nav.hold, nav.axes
    if H.on or H.off or H.paused or not (A and A.move) then return end
    if H.other and ctx.now() < H.other then return end
    local mode, size = eng('Mouse.dead_zone', A.move)
    if type(mode) ~= 'number' or type(size) ~= 'number' then
      H.off = true
      log('options menu: the mouse turns the camera while the menu is open or a mod holds it (no dead zone answer)')
      return
    end
    if size == HOLD and H.had then                      -- (mine, put back by another mod: what I found is still under it)
      H.on, H.other, H.px, H.py, H.bad, H.clean = true, nil, nil, nil, 0, 0
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
    H.on, H.had, H.px, H.py, H.bad, H.clean = true, { mode, size }, nil, nil, 0, 0
    if not H.said then
      H.said = true
      log(fmt('options menu: the mouse is held from the game while the menu has it (its dead zone was %s, %s)', tostring(mode),
        tostring(size)))
    end
  end
  -- Mods hold the mouse with the same hold (chef.hold_mouse, below svc.forget): mine, kept while my menu has the mouse
  -- or any mod asks for it, and given back only once neither does. by: owner -> true; n: how many.
  nav.holds = { by = {}, n = 0 }
  function nav.hold_give()
    if nav.holds.n == 0 then nav.hold_drop() end
  end
  function nav.hold_drop()
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
  -- (after the hold was let go: a look once a second that it wasn't left held, until 10 looks in a row found it not
  -- mine; the next hold starts the looks again)
  function nav.hold_heal()
    local H, A = nav.hold, nav.axes
    if H.on or not H.had or H.clean >= 10 then return end
    local t = ctx.now()
    if t < H.heal_at then return end
    H.heal_at = t + 1
    local _, size = eng('Mouse.dead_zone', A.move)
    if size == HOLD then
      H.clean = 0
      eng('Mouse.set_dead_zone', A.move, H.had[1], H.had[2])
      log('options menu: the mouse\'s dead zone was found held after the menu let it go: put back')
    else H.clean = H.clean + 1 end
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
  -- the mouse's axes and buttons (no answer yet, the mouse not ready in the first frames on some setups: asked again
  -- every 2 s)
  function nav.find_axes()
    if not nav.axes or (not nav.axes.move and ctx.now() >= nav.axes.at) then
      local had = nav.axes
      nav.axes = { move = eng('Mouse.axis_index', 'mouse') or false, wheel = eng('Mouse.axis_index', 'wheel') or false,
                   cursor = eng('Mouse.axis_index', 'cursor') or false,
                   l = eng('Mouse.button_index', 'left') or false, r = eng('Mouse.button_index', 'right') or false,
                   at = ctx.now() + 2 }
      if not had or nav.axes.move then log('options menu: mouse ' .. (nav.axes.move and 'found' or 'missing')) end
    end
    return nav.axes
  end
  -- a mouse axis's two numbers (0, 0 with no answer), and a mouse button down
  function nav.axis_xy(i)
    local v = eng('Mouse.axis', i)
    if v == nil then return 0, 0 end
    local x, y = eng('Vector3.to_elements', v)
    return tonumber(x) or 0, tonumber(y) or 0
  end
  function nav.button_down(i) if not i then return false end local v = eng('Mouse.button', i); return type(v) == 'number' and v > 0.5 end
  -- the cursor (screen pixels, y up like the drawing), the wheel, and this frame's clicks
  function nav.mouse_read(w, h)
    local A = nav.find_axes()
    nav.moved, nav.wheel, nav.click, nav.rclick = false, 0, false, false
    if not A.move then return end
    if not nav.mx then nav.mx, nav.my = w / 2, h / 2 end
    -- (the game showing its own cursor, its pause screen: the cursor axis is where the mouse really is, and the game
    -- turns no camera with it; my cursor sits on it, and the mouse isn't held)
    local win = eng('Window.get_main_window')
    local shown = win ~= nil and eng('Window.show_cursor', win) == true
    nav.game_cursor = shown                             -- (then the game's own cursor is the one drawn: not mine)
    local H = nav.hold
    if not shown and A.cursor then nav.hold_take() end
    if shown then
      if H.on then nav.hold_give() end
      local cx, cy = nav.cursor_at(w, h)
      if cx then
        nav.moved = cx ~= nav.mx or cy ~= nav.my
        nav.mx, nav.my = cx, cy
      end
      H.px, H.py = nil, nil                             -- (held again later: from a fresh sample, no jump)
    elseif (H.on or H.other) and A.cursor then
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
      -- (not held: the delta moves my cursor. A mod's hold on a mouse with no cursor axis lands here too: the delta
      -- reads nothing then, so my cursor stays put and the keys and the controller drive the menu)
      local dx, dy = nav.axis_xy(A.move)
      nav.moved = dx ~= 0 or dy ~= 0
      local k = h / 1080
      -- (the delta counts y down; the menu's y grows upward)
      nav.mx = max(0, min(w - 1, nav.mx + dx * k))
      nav.my = max(0, min(h - 1, nav.my - dy * k))
    end
    if A.wheel then local _, wy = nav.axis_xy(A.wheel); nav.wheel = wy end
    local l, r = nav.button_down(A.l), nav.button_down(A.r)
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
  -- (the full screen look's controller hint line: each button's picture, then its word; ps: a pad with shape buttons)
  nav.pad_hint = { ps = { 'dpad', 'MOVE', 'enter', 'PICK', 'back', 'BACK', 'delete', 'DEFAULT', nil, 'L1/R1 PAGE' },
                   xb = { 'dpad', 'MOVE', 'enter', 'PICK', 'back', 'BACK', 'delete', 'DEFAULT', nil, 'LB/RB PAGE' } }
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
  -- draws one at x, y (its bottom left), 9 c pixels square, its colors from col (the look's: the compact one scales
  -- their alpha by its opacity; ctx.color when none); returns its width. Its four colors are made once in a frame the
  -- menu draws, for the look drawing (nav.gcol, emptied in menu_frame just before it draws), not once a glyph.
  nav.gcol = { col = nil }
  function nav.glyph(what, x, y, c, layer, col)
    local g = GLYPH_OF[what]
    if not g then return 0 end
    local s = 9 * c
    col = col or ctx.color
    local letter = not nav.ps and g[2]
    local R = glyph_runs(letter and 'letter' or g[1], s)
    local cols = nav.gcol
    if cols.col ~= col then
      cols.col, cols[1], cols[2], cols[3], cols[4] = col, col(232, 232, 226, 64), col(232, 232, 226, 128),
        col(232, 232, 226, 191), col(232, 232, 226, 255)
    end
    for i = 1, #R, 5 do ctx.rect(x + R[i], y + s - R[i + 1] - R[i + 3], R[i + 2], R[i + 3], cols[R[i + 4]], layer) end
    if letter and ctx.text then
      local lp = max(1, floor(c * 0.75))
      local lw = ctx.text_width(letter, lp)
      ctx.text(x + floor((s - lw) / 2), y + floor((s - 7 * lp) / 2), letter, lp, cols[4], layer + 1)
    end
    return s
  end
  -- The controller's hint line, in both looks: each button's picture, then its word, from x up to x_end (y: the hint
  -- row's bottom, rh its height); a picture and its word go whole or not at all, and the pairs after one that doesn't
  -- fit go with it (the compact panel is narrower than the whole line). col: the look's colors; wc: the words' color.
  function nav.pad_hints(x, x_end, y, rh, px, P, col, wc, layer)
    local gy = y + floor((rh - 9 * px) / 2)
    local parts = nav.ps and nav.pad_hint.ps or nav.pad_hint.xb
    for k = 1, 9, 2 do
      local it, word = parts[k], parts[k + 1]
      local gw = it and GLYPH_OF[it] and 11 * px or 0
      if x + gw + (word and ctx.text_width(P(word), px) or 0) > x_end then break end
      if gw > 0 then x = x + nav.glyph(it, x, gy, px, layer + 1, col) + 2 * px end
      if word then x = x + (ctx.text(x, nav.midy(y, rh, px), P(word), px, wc, layer) or 0) + 6 * px end
    end
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
  -- the cursor: an arrow, ink edged. Not drawn while the controller is what was used last (a button pressed, or the
  -- menu opened by its hold): the mouse moving, a click or the wheel brings it back in that frame, a key too (the
  -- hints change with them). The pad gone, it's back.
  function nav.draw_cursor(top, h)
    if not (nav.mouse and nav.mx) or nav.game_cursor or (menu.dev == 'pad' and nav.pad) then return end
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
  -- title has it (whole) and every option whose label (or heading) has it, under its mod's title and the headings it's
  -- under in its entry
  local lines_cache = { ver = -1, search = nil, group = nil, out = nil }
  -- A group's rows as lines. My own rows carry a section: they're shown by section, each under its heading, in the
  -- order below (any other row of a section after those, in the order it was made).
  -- (three headings, two with small subheadings under them (sub): the menu, how its compact panel looks and how it's
  -- driven; the monitor's numbers, then how the monitor looks; the crash recovery buttons. A subheading is drawn
  -- indented and dimmer, its rows indented with it)
  local SECTIONS = { menu = { 1, 'MENU' }, compact = { 2, 'COMPACT LOOK', sub = true }, controls = { 3, 'CONTROLS', sub = true },
                     monitor = { 4, 'PERFORMANCE' }, monitor_look = { 5, 'MONITOR LOOK', sub = true },
                     recovery = { 6, 'CRASH RECOVERY' } }
  local ORDER = { menu_key = 1, menu_look = 2, lang = 3, menu_place = 1, menu_alpha = 2, menu_mouse = 1,
                  menu_pad = 2, perf = 1, budget = 2, perf_hide = 3, perf_place = 1, perf_alpha = 2, perf_pause = 3 }
  local function section_of(r) return r.owner == 'loader' and SECTIONS[r.spec.section] or nil end
  -- A separator: a thin rule on a short line of its own, a line like a heading (the cursor, the mouse and the pad pass
  -- over it). One under a mod's switch (and a package's INCLUDED lines), so it stands apart above the mod's
  -- options, and one above its reset button, so that stands apart from them. Only right before a row of the same mod
  -- (and its heading, if it starts one): never at an end, never two in a row, never between a heading and its row.
  -- One table for every separator (nothing is kept on a line).
  nav.sep = { head = true, sep = true }
  function nav.sep_before(p, r, g)
    return p ~= nil and (p.info or (p.row ~= nil and (p.row.switch or r == g.reset))) == true
  end
  -- A group that holds options of a package's part alone (its own, or a look-alike heading only it fills): that part's
  -- switch row, else nil. Such a group isn't an entry of its own: its rows are in the package's (nav.pk_lines).
  function nav.pk_of(g)
    local r1 = g.rows[1]
    local m = r1 and r1.owner
    if not m or m == 'loader' then return nil end
    local q = rows_by_id[m .. '|#on']
    if not (q and q.part) then return nil end
    for _, o in ipairs(g.rows) do if o.owner ~= m then return nil end end
    return q
  end
  -- the entries in my list: the mods with rows (sorted_groups) but a part's own groups (made again with the layout;
  -- the search goes through these too: a part's options are in its package's entry, nav.pk_lines)
  function nav.listed()
    local c = nav.lc
    if c and c.ver == ver.layout then return c.gs end
    local gs = {}
    for _, g in ipairs(sorted_groups()) do if not nav.pk_of(g) then gs[#gs + 1] = g end end
    nav.lc = { ver = ver.layout, gs = gs }
    return gs
  end
  -- the search: a package's entry (g, its main switch first in it) is found by a part's name (q, lower case) as by its
  -- own title (the name in lower case kept on the part's switch while it stays the same, as a row's is)
  function nav.pk_named(g, q)
    local s = g.rows[1]
    if not (s and s.switch and s.pk and s.pk.main == s) then return false end
    for _, o in ipairs(s.pk.sw) do
      if o ~= s then
        local t = text_of(o.spec.label or o.id)
        if o.lw_s ~= t then o.lw_s, o.lw = t, t:lower() end
        if o.lw:find(q, 1, true) then return true end
      end
    end
    return false
  end
  -- A package's parts' options in its entry (s: its main switch), before its reset button: each part's under a small
  -- heading of its name, its rows indented under it (a heading of a row's own a small one too). A rule under the
  -- switch's block, as above a mod's own options.
  function nav.pk_lines(s, out)
    for _, q in ipairs(s.pk.sw) do
      local named = false
      for _, g in ipairs(groups) do
        if q ~= s and #g.rows > 0 and nav.pk_of(g) == q then
          if not named then
            named = true
            if out[#out] and out[#out].info then out[#out + 1] = nav.sep end
            out[#out + 1] = { head = true, sub = true, text = svc.mod_title(q.mod), pn = true }
          end
          for _, o in ipairs(g.rows) do
            local hd = o.spec.heading
            if type(hd) == 'string' and hd ~= '' then out[#out + 1] = { head = true, sub = true, text = hd } end
            out[#out + 1] = { row = o, indent = true }
          end
        end
      end
    end
  end
  -- A mod's state word's color, one pick for the status and a package's part lines: its kind (nav.st_kind: 1
  -- running, the menu's green; 2 kept off or not started, orange; 3 stopped, red; 0 off or any other, the line's own
  -- color c). col: the look's color function; faint: the preview's, fainter as its text is.
  -- The color is made right here, for the call that draws with it (the frame's color cache emptied first), so it never
  -- rides on a Color made earlier in the frame, whose slot the engine may have handed out again since.
  -- The top world (my layers from ctx.TOP: the menu, the monitor, the notices) puts what I draw through its own tone
  -- curve. nav.TONE is that curve as the menu looks on my screen: pairs of a channel as passed and as it shows, read
  -- off screenshots of both looks (the panels, the rules, the grays, the gold, the green and the white). It lifts the
  -- darks a little (10 shows as 31), gives the middle about 1.3 x, and flattens out near white. nav.tone turns the
  -- color I want on screen into the one to pass (the table read backwards, between its two nearest pairs, rounded); I
  -- call it only where a palette is made, never in a frame. Exposure can differ by display and HDR setting (a capture
  -- of the ship once gave me a much steeper curve): this table is the one place to retune it. The whites, the yellow,
  -- the ink, the dark panels, the slider's track, the rules (nav.pal.rule) and the state colors (nav.st_rgb, picked
  -- as passed) go in as they are.
  nav.TONE = { passed = { 0, 10, 19, 39, 64, 88, 134, 230, 255 }, shown = { 19, 31, 41, 58, 84, 113, 170, 226, 255 } }
  function nav.tone(r, g, b)
    local p, s = nav.TONE.passed, nav.TONE.shown
    local function one(v)
      if type(v) ~= 'number' or v <= s[1] then return type(v) == 'number' and 0 or v end
      for i = 2, #s do
        if v <= s[i] then return floor(p[i - 1] + (v - s[i - 1]) * (p[i] - p[i - 1]) / (s[i] - s[i - 1]) + 0.5) end
      end
      return 255
    end
    return one(r), one(g), one(b)
  end
  ctx.tone = nav.tone                          -- (the monitor's colors, utilities.lua, and the notices' red)
  -- The state colors as passed, one place to tune them (nav.st_rgb: running, kept off, stopped; nav.st_rgb.faint: the
  -- preview's, at 150). They show as a clear green (about 122,170,113), orange and red on my screen, and keep their
  -- hue under a steeper curve too, so a light green at full alpha never reads as white.
  nav.st_rgb = { { 95, 134, 88 }, { 134, 70, 16 }, { 134, 43, 32 },
                 faint = { { 143, 224, 143 }, { 255, 134, 40 }, { 255, 90, 70 } } }
  -- The menu's other colors, as I want them on screen (passed toned, made once here), each clearly readable on the
  -- dark panels and under the white labels (about 230): gray (about 150: values off, versions, the arrows, the panes'
  -- titles, titles in the list), dim (about 128, under the gray: the full look's versions, the preview, an old error),
  -- sub (a subheading's muted gold), hint (about 165: a selected row's hint line, and a version on the lit row, where
  -- the gray would sink into the yellow glow), err (a new error on the compact look's yellow bar, a dark red) and
  -- notice (the notices' red, brighter than the state red: it stands alone on a plate over the game). rule (the
  -- separators, the scroll tracks and a live slider's track) goes in as it is: a faint line, not text. nav.pc: one of
  -- them from col at alpha a.
  nav.pal = { gray = { nav.tone(146, 154, 147) }, dim = { nav.tone(126, 133, 127) }, sub = { nav.tone(175, 160, 115) },
              hint = { nav.tone(163, 170, 164) }, err = { nav.tone(150, 24, 16) }, notice = { nav.tone(250, 100, 80) },
              rule = { 37, 42, 38 } }
  svc.pal = nav.pal
  function nav.pc(k, col, a)
    local t = nav.pal[k]
    return col(t[1], t[2], t[3], a or 255)
  end
  function nav.st_kind(s)
    return (s == 'running' and 1) or (s == 'stopped' and 3) or ((s == 'kept off' or s == 'not started' or not s) and 2) or 0
  end
  -- (state k's color from col at full alpha, or the preview's at 150 when faint: the looks' green and orange too)
  function nav.st_c(k, col, faint)
    local t = faint and nav.st_rgb.faint[k] or nav.st_rgb[k]
    return col(t[1], t[2], t[3], faint and 150 or 255)
  end
  function nav.st_col(k, c, col, faint)
    if k ~= 1 and k ~= 2 and k ~= 3 then return c end
    return nav.st_c(k, col, faint)
  end
  -- A package's INCLUDED line (q: a part's switch row), read-only: the part's name (its switch's label, svc.mod_title)
  -- from x, its version dim after it (nav.ver_row), and the word of its state (the status's facts: nav.facts_now)
  -- at wx, else ending at xe, where a switch's ON is: in the status's colors for it (nav.st_col; col, faint as
  -- there). The word goes through the language as the status's does (translated, then kept as drawn). The word as
  -- drawn and its color's kind are kept on the row (q.pw, q.pw_k), made again only with a new list of facts, the other
  -- font or another language.
  function nav.part(q, x, ty, xe, wx, px, c, dimc, col, faint, layer)
    local st, P = nav.facts_now(), (ctx.text_native and ctx.text_native()) and caps or plain
    local lv = ctx.lang_v and ctx.lang_v()
    if q.pw_st ~= st or q.pw_p ~= P or q.pw_lv ~= lv then
      local m = st and st.by[q.mod]
      local s = st and (m and m.state or 'not started')
      local h = s and ((s == 'running' and 'RUNNING') or (s == 'off' and 'OFF') or (s == 'kept off' and 'KEPT OFF')
        or (s == 'stopped' and 'STOPPED') or (s == 'not started' and 'NOT STARTED') or caps(s))
      if ctx.tr_cut then ctx.tr_cut(true) end
      q.pw_st, q.pw_p, q.pw_lv, q.pw, q.pw_k = st, P, lv, h and P((ctx.tr or text_of)(h)), nav.st_kind(s)
      if ctx.tr_cut and ctx.tr_cut() then q.pw_st = nil end   -- (the pattern budget cut it: made again next frame)
    end
    local fit, tw, w = ctx.text_fit or fit_cells, ctx.text_width, q.pw
    if w and ctx.tr_keep then ctx.tr_keep(w) end
    local ww = w and tw(w, px) or 0
    wx = w and (wx or xe - ww) or xe
    -- (the name as drawn kept on the row too, q.pl: made again when its text or the font changes; a label function is
    -- still asked each frame, it can change any time)
    local ls = text_of(q.spec.label or q.id)
    if q.pl_s ~= ls or q.pl_p ~= P then q.pl_s, q.pl_p, q.pl = ls, P, P(ls) end
    local lt = q.pl
    local room = wx - 6 * px - x
    ctx.text(x, ty, fit(lt, px, room), px, c, layer)
    nav.ver_row(q, x, ty, lt, room, px, dimc, layer)
    if w then ctx.text(wx, ty, w, px, nav.st_col(q.pw_k, c, col, faint), layer) end
  end
  local function group_lines(g, out)
    local rows, any = {}, false
    for i, r in ipairs(g.rows) do rows[i] = r; if section_of(r) then any = true end end
    if not any then
      -- (a mod's own headings: a row with spec.heading starts one, drawn above it; spec.sub makes it a small one, its
      -- rows indented under it, until the next heading)
      -- (pk: a package's main switch in this entry, its parts' options to go in before its reset button)
      local sub, pk = false, nil
      for _, r in ipairs(rows) do
        if pk and r == g.reset then nav.pk_lines(pk, out); pk = nil end
        if nav.sep_before(out[#out], r, g) then out[#out + 1] = nav.sep end
        local hd = r.spec.heading
        if type(hd) == 'string' and hd ~= '' then
          sub = r.spec.sub == true
          out[#out + 1] = { head = true, text = hd, sub = sub, fr = r }   -- (fr: its first row, for nav.fold_lines)
        end
        -- (the reset button, under its rule after them all, isn't the last subheading's: not indented)
        out[#out + 1] = { row = r, indent = sub and r ~= g.reset }
        -- (a mod's switch: its status is on the entry's title bar, nav.status_draw, never a line of its own)
        -- (a package's main switch: under it, what else it switches, INCLUDED, a line each: nav.part)
        if r.switch and r.pk and r.pk.main == r and #r.pk.sw > 1 then
          out[#out + 1] = { head = true, sub = true, text = 'INCLUDED', inc = true }
          for _, q in ipairs(r.pk.sw) do
            if q ~= r then out[#out + 1] = { head = true, info = true, pt = q, indent = true } end
          end
          pk = r
        end
      end
      if pk then nav.pk_lines(pk, out) end
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
      if sec and sec ~= last then out[#out + 1] = { head = true, text = sec[2], sub = sec.sub } end
      last = sec
      out[#out + 1] = { row = r, indent = sec ~= nil and sec.sub == true }
    end
    return out
  end
  -- Folds: a mod's own headings (not a subheading; not one whose first row says fold = false) are lines the cursor
  -- stops on, each opening and closing the lines under it, its subheadings' too, up to the next heading, a rule, a
  -- package's part or the reset button. The switch and its INCLUDED block, the rows before the first
  -- heading and the reset button stay in view. An entry with more than nav.FOLD_AT option rows opens with every heading
  -- closed, a shorter one open. What a player picks is kept for the session (nav.folds, by mod and heading text) and
  -- in my settings only while it isn't the default (fold.<mod>.<heading>, made fit my settings' keys). The lines are
  -- made only when the layout or a fold changes (ver.fold); the search lists every row and never folds.
  nav.FOLD_AT, nav.folds, ver.fold = 20, {}, 0
  -- (a heading's text made fit: one of ASCII letters, digits, spaces, . and - keeps the key it always had, so what
  -- players picked stays; only its spaces turn into _. Any other character, an _ too, or no letter or digit at all,
  -- and it has a sum of the text as it is after it, since the replaced characters alone would give two headings one
  -- key ('A/B', 'A B'); old: the key it had before, read while the new one has nothing saved, unless a heading of
  -- that mod keeps it as its own)
  function nav.fold_sum(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return fmt('.%08x', h)
  end
  function nav.fold_key(g, text)
    text = tostring(text)
    local k = ('fold.' .. tostring(g.mod) .. '.' .. text):gsub('[^%w_%.%-]', '_')
    local old = nil
    if text:find('[^%w %.%-]') or not text:find('%w') then
      old, k = k, k .. nav.fold_sum(text)
      -- (the heading that keeps old as its key: this text with its _ as spaces)
      local twin = text:gsub('[^%w_%.%-]', '_'):gsub('_', ' ')
      if twin:find('%w') then
        for _, r in ipairs(g.rows or {}) do if r.spec and r.spec.heading == twin then old = nil; break end end
      end
    end
    -- (too long for a key: cut, with a sum of the whole after it, so two long headings don't share one)
    if #k > 64 then k = k:sub(1, 55) .. nav.fold_sum(k) end
    if old and #old > 64 then old = old:sub(1, 55) .. nav.fold_sum(old) end
    return k, old
  end
  -- a fold closed? what was picked this session, else what my settings keep (under its key, else its old one), else
  -- the entry's default (dflt)
  function nav.fold_shut(key, sk, dflt, old)
    local s = nav.folds[key]
    if s == nil then
      s = svc.loader_get(sk)
      if type(s) ~= 'boolean' and old then s = svc.loader_get(old) end
      if type(s) ~= 'boolean' then return dflt end
      nav.folds[key] = s
    end
    return s
  end
  function nav.fold_set(f, shut)
    nav.folds[f.key] = shut
    if shut == f.dflt then svc.loader_put(f.sk, nil) else svc.loader_put(f.sk, shut) end
    -- (the old key goes once the new one is written: its line isn't left in my settings)
    if f.ok and svc.loader_get(f.ok) ~= nil then svc.loader_put(f.ok, nil) end
    ver.fold = ver.fold + 1
  end
  -- an entry's lines (all: group_lines') with its folds, into out: a fold line in place of each heading that folds
  -- (its count of rows, ct, drawn while it's closed), its lines after it while it's open; each row's line in a fold
  -- knows it (fo)
  -- (two headings with one text in a mod are two folds: the second and later ones have their place among the headings
  -- with that text after the session's key and the saved one, seen; the first keeps the keys it always had)
  function nav.fold_lines(g, all, out)
    local n, f, seen = 0, nil, nil
    for _, l in ipairs(all) do
      local r = l.row
      if r and not r.switch and r ~= g.reset then n = n + 1 end
    end
    for _, l in ipairs(all) do
      local r = l.row
      local top = l.fr ~= nil and not l.sub
      if f and (top or l.sep or l.pn or l.info or l.inc or (r and (r.switch or r == g.reset))) then
        f.ct, f = '(' .. f.n .. ')', nil
      end
      if top and l.fr.spec.fold ~= false then
        local key, sk, old = tostring(g.mod) .. '|' .. l.text, nav.fold_key(g, l.text)
        seen = seen or {}
        local i = (seen[l.text] or 0) + 1
        seen[l.text] = i
        if i > 1 then key, sk, old = key .. '|' .. i, nav.fold_key(g, l.text .. '.' .. i), nil end
        f = { fold = true, text = l.text, key = key, sk = sk, ok = old, dflt = n > nav.FOLD_AT, n = 0 }
        f.open = not nav.fold_shut(key, f.sk, f.dflt, old)
        out[#out + 1] = f
      elseif f then
        if r then f.n, l.fo = f.n + 1, f end
        if f.open then out[#out + 1] = l end
      else
        out[#out + 1] = l
      end
    end
    if f then f.ct = '(' .. f.n .. ')' end
    return out
  end
  local function lines()
    if lines_cache.ver == ver.layout and lines_cache.search == menu.search and lines_cache.group == menu.group
       and lines_cache.fv == ver.fold then
      return lines_cache.out
    end
    local out = {}
    local q = menu.search ~= '' and menu.search or nil
    -- every screen under the list starts with a Back row (to the list of mods)
    if q or menu.group then out[1] = { back = true, text = '< BACK' } end
    if q then
      -- (a title's, a heading's and a row's text in lower case is kept on it while the text stays the same: lw_s, lw.
      -- The rows are gone through as their entry shows them, g.el, its lines made once a layout and used by every
      -- search after: a line never changes. g.sh: the mod's title line, made once. The entries as listed: a package's
      -- parts' options are in its entry, nav.pk_lines)
      for _, g in ipairs(nav.listed()) do
        local t = text_of(g.title)
        if g.lw_s ~= t then g.lw_s, g.lw = t, t:lower() end
        local whole, head = g.lw:find(q, 1, true) ~= nil or nav.pk_named(g, q), false
        if g.el_v ~= ver.layout then g.el_v, g.el = ver.layout, group_lines(g, {}) end
        local el = g.el
        -- (h1, h2: the heading and the subheading the line sits under in the entry; k1, k2: their text has the search;
        -- s1, s2: the last of each put in the results. A part's name over its options starts a run as a heading does,
        -- pn; INCLUDED belongs to the switch above it, never a heading of rows, inc)
        local h1, h2, k1, k2, s1, s2 = nil, nil, false, false, nil, nil
        for i, l in ipairs(el) do
          if l.head and l.text and not l.inc then
            if l.lw_s ~= l.text then l.lw_s, l.lw = l.text, text_of(l.text):lower() end
            if l.sub and not l.pn then h2, k2 = l, l.lw:find(q, 1, true) ~= nil
            else h1, k1, h2, k2 = l, l.lw:find(q, 1, true) ~= nil, nil, false end
          elseif l.row then
            local r = l.row
            -- (the reset button, under its rule after them all, is under no heading)
            local a, b = h1, h2
            if r == g.reset then a, b = nil, nil end
            -- (a heading found lists all its rows, a subheading's too, as a title found lists the mod's)
            local hit = whole or (a ~= nil and k1) or (b ~= nil and k2)
            if not hit then
              local s = text_of(r.spec.label or r.id)
              if r.lw_s ~= s then r.lw_s, r.lw = s, s:lower() end
              hit = r.lw:find(q, 1, true) ~= nil
              -- (a row I relabel is found by its first label too, r.find: it never drops out of the results it's in)
              if not hit and r.find then
                r.fw = r.fw or text_of(r.find):lower()
                hit = r.fw:find(q, 1, true) ~= nil
              end
            end
            if hit then
              -- (its mod's title above its first row found, drawn apart from its headings: mt, the group)
              if not head then
                head = g.sh or { head = true }
                head.text, head.mt, g.sh = g.title, g, head
                out[#out + 1] = head
              end
              -- (the separators as in its entry, among the rows found: never under the mod's title, and before a
              -- heading, never between it and its row)
              if nav.sep_before(out[#out], r, g) then out[#out + 1] = nav.sep end
              -- (the heading and subheading it's under, once, above its first row found: drawn as in its entry, its
              -- line indented under a subheading as there)
              if a and a ~= s1 then out[#out + 1] = a; s1 = a end
              if b and b ~= s2 then out[#out + 1] = b; s2 = b end
              out[#out + 1] = l
              -- (a switch found: the lines under it in its entry too, a package's INCLUDED and part lines; the
              -- search never looks at their text)
              local j = i + 1
              while r.switch and el[j] and (el[j].info or el[j].inc) do out[#out + 1] = el[j]; j = j + 1 end
            end
          end
        end
      end
    elseif menu.group then
      nav.fold_lines(menu.group, group_lines(menu.group, {}), out)
    else
      for _, g in ipairs(nav.listed()) do out[#out + 1] = { pick = g, text = g.title } end
    end
    lines_cache.ver, lines_cache.search, lines_cache.group, lines_cache.out = ver.layout, menu.search, menu.group, out
    lines_cache.fv = ver.fold
    return out
  end
  -- the hint for a key row marked '!' (its key bound more than once, a combo clashing with the plain binding of its key
  -- as key_users counts it): which other options use the key, by mod and
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
      -- (the rows on the same value, and across a combo and its plain key: a plain key's combos, a combo's plain key)
      local others, n, rp = {}, 0, row_parts(r)
      for _, g in ipairs(groups) do
        for _, o in ipairs(g.rows) do
          local hit = o ~= r and o.spec.type == 'key' and o.value ~= 'off'
          if hit and o.value ~= r.value then
            local op = row_parts(o)
            if not rp then hit = op and op.key == r.value
            else hit = rp.key ~= nil and not op and o.value == rp.key end
          end
          if hit then
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
  -- drawn as they are is two generations. The last one made is kept on clash_cache (d_src, d_P, d), so the hint shown
  -- frame after frame is made once.
  local function clash_drawn(clash, P)
    local c = clash_cache
    if c.d_src ~= clash or c.d_P ~= P then c.d_src, c.d_P, c.d = clash, P, P(clash) end
    local s = c.d
    if ctx.tr_keep then ctx.tr_keep(s) end
    return s
  end
  -- A mod's status, on its entry's title bar: what it's doing and why, its start's cost and its last error, one line
  -- a player can screenshot for a bug report (with the title it's next to, which names the mod). The facts
  -- are the utilities' mod list (util.mod_facts), taken at most once a second and only while a status is drawn
  -- (nothing while the menu is closed), and the mod's record (its last error, util.note_error). The line is made again
  -- only when a new list was taken, the switch moved (a fresh list at once: off stops the mod in that frame) or the
  -- language changed, and kept on the switch row (r.st). Its fixed words go through the language before they're
  -- joined, as the clash hint's do. Its pieces are kept on the row, for nav.status_draw: the state word (r.st_h; and
  -- its short form, r.st_hs, as a package's part line says it) and its color's kind (r.st_k), why (r.st_y), the
  -- start's time (r.st_t) and memory (r.st_m), the error (r.st_e).
  -- The memory is the heap's change over the start: in KB under 1024, else in MB (one decimal under 10). A heap that
  -- shrank over it (the collector ran during the start and freed more than the mod kept) says nothing of what the mod
  -- kept, so I show no figure then rather than one that reads as "this mod costs nothing".
  function nav.status(r)
    -- (the facts as nav.facts_now takes them; a switch just moved takes a fresh list at once)
    if r.st_v ~= nil and r.st_v ~= r.value then nav.st = nil end
    local st, lv = nav.facts_now(), ctx.lang_v and ctx.lang_v()
    if r.st_of == st and r.st_v == r.value and r.st_lv == lv then return r.st end
    local tr = ctx.tr or text_of
    if ctx.tr_cut then ctx.tr_cut(true) end
    -- (no facts at all, a host without util.mod_facts: the row says NOT STARTED rather than raising into the menu)
    local m, a = st and st.by and st.by[r.mod] or {}, recs[r.mod]
    local s, why = m.state, m.why
    local head = (s == 'running' and 'RUNNING') or (s == 'off' and 'OFF') or (s == 'kept off' and 'KEPT OFF BY THE CRASH GUARD')
      or (s == 'stopped' and 'STOPPED') or (s == 'not started' and 'NOT STARTED') or s or 'NOT STARTED'
    -- (switched off from this menu: said short, or that it comes back at the next launch once switched on again)
    if why == 'switched off in the options menu' then why = r.value and 'ON AGAIN AT THE NEXT LAUNCH' or 'SWITCHED OFF' end
    r.st_h, r.st_y, r.st_t, r.st_m, r.st_e = tr(head), (type(why) == 'string' and why ~= '') and ': ' .. tr(why) or '', '', '', ''
    r.st_k, r.st_hs = nav.st_kind(s), s == 'kept off' and tr('KEPT OFF') or r.st_h
    if m.start_ms then
      r.st_t = ' - ' .. tr('STARTED IN') .. fmt(m.start_ms < 10 and ' %.1f MS' or ' %.0f MS', m.start_ms)
      local kb = m.start_kb and floor(m.start_kb + 0.5)
      if kb and kb >= 0 then
        r.st_m = kb < 1024 and fmt(', +%d KB', kb) or fmt(kb < 10189 and ', +%.1f MB' or ', +%.0f MB', kb / 1024)
      end
    end
    -- (the error last: the one cut to fit; without its text, the count of the hook errors the loader keeps)
    local e = a and a.last_error
    -- (its own file's name in front, "mods/x/y:12: ...", is said as the line alone: the row it's under names the mod)
    local ln, rest = nil, nil
    if e and e:sub(1, #r.mod) == r.mod then ln, rest = e:match('^:(%d+): (.*)$', #r.mod + 1) end
    if ln then e = tr('LINE') .. ' ' .. ln .. ': ' .. rest end
    if e then r.st_e = tr('LAST ERROR:') .. ' ' .. e
    elseif (m.errors or 0) > 0 then r.st_e = tr('ERRORS:') .. ' ' .. m.errors end
    -- (a last error with no new one for five minutes stays on the line, dim gray instead of red: r.st_eo. Its time is
    -- util.note_error's; one without a time is new. Looked at again with each new list, so it dims while my menu is open)
    r.st_eo = e ~= nil and a.error_at ~= nil and ctx.now() - a.error_at >= 300
    r.st = r.st_h .. r.st_y .. r.st_t .. r.st_m .. (r.st_e ~= '' and ' - ' .. r.st_e or '')
    r.st_of, r.st_v, r.st_lv = st, r.value, lv
    if ctx.tr_cut and ctx.tr_cut() then r.st_of = nil end    -- (a part the pattern budget cut: made again next frame)
    return r.st
  end
  -- (a piece's width, none for an empty one; kept as it is first, as what it's measured for is made of translated
  -- pieces: the language never takes it for a text it lacks)
  function nav.sw(s, px)
    if s == '' then return 0 end
    if ctx.tr_keep then ctx.tr_keep(s) end
    return ctx.text_width(s, px)
  end
  -- A status drawn in pieces, each a text of its own, right-aligned to end at xe (on a title bar, after the title,
  -- which keeps its room: room is what the title leaves): the state word in its color (RUNNING in the menu's green,
  -- OFF in the line's gray, KEPT OFF and NOT STARTED orange, STOPPED red), the rest in the line's color (c) and the
  -- error in red (my notices' red; the looks' dim gray once it's old, r.st_eo). Where the line doesn't fit its room,
  -- the memory goes first, then the start's time; then the error is cut with '...' to what's left after the state
  -- word and why (at least half the room after the state word: a long why is cut for it), so the state word and the
  -- error stay in view the longest; then why goes, then the state word is said short (KEPT OFF), then not at all,
  -- never cut. The pieces as drawn, their places and their whole width (r.sp_w) are worked out only when the line was
  -- made again (nav.status: at most once a second) or its room, size or font changed, and kept on the switch row
  -- (r.sp_*): a frame only draws them. col: the look's color function (the compact look's takes its opacity); faint:
  -- the preview's (the colors fainter, as its text is). ec: the compact look's yellow bar, where colored words don't
  -- read: the state word in c (the bar's dim ink) as the rest, a new error in ec (a dark red), an old one in c.
  -- Returns where it starts (xe: nothing drawn), for the bar's state dot before it.
  function nav.status_draw(r, xe, ty, room, px, P, c, col, faint, layer, ec)
    nav.status(r)
    if r.sp_of ~= r.st_of or r.sp_src ~= r.st or r.sp_room ~= room or r.sp_px ~= px or r.sp_P ~= P then
      r.sp_of, r.sp_src, r.sp_room, r.sp_px, r.sp_P = r.st_of, r.st, room, px, P
      local fit, sw = ctx.text_fit or fit_cells, nav.sw
      local h, y, t, m, e = clash_drawn(r.st_h, P), clash_drawn(r.st_y, P), clash_drawn(r.st_t, P), clash_drawn(r.st_m, P),
        clash_drawn(r.st_e, P)
      local hw, rest, err = sw(h, px), '', ''
      if hw > room then h = clash_drawn(r.st_hs, P); hw = sw(h, px) end
      if hw > room then h, hw = '', 0
      else
        local left, sep = room - hw, e ~= '' and ' - ' or ''
        local yw, ew = sw(y, px), sw(sep .. e, px)
        if sw(y .. t .. m, px) + ew <= left then rest, err = y .. t .. m .. sep, e
        elseif sw(y .. t, px) + ew <= left then rest, err = y .. t .. sep, e
        elseif yw + ew <= left then rest, err = y .. sep, e
        elseif e == '' then rest = fit(y, px, left)
        else
          local er = max(left - yw, floor(left / 2))     -- (the error's room, its ' - ' in it)
          err = fit(e, px, er - sw(sep, px))
          if err == '' then rest = fit(y, px, left)
          else rest = (yw <= left - er and y or fit(y, px, left - er)) .. sep end
        end
      end
      -- (the pixel font's widths end at a letter's last column: the next piece one column on, as joined text has it)
      local g = P == plain and px or 0
      r.sp_h, r.sp_r, r.sp_e = h, rest, err
      r.sp_rx = h ~= '' and hw + g or 0
      local rw = rest ~= '' and sw(rest, px) or 0
      r.sp_ex = r.sp_rx + (rest ~= '' and rw + g or 0)
      r.sp_w = (err ~= '' and r.sp_ex + sw(err, px)) or (rest ~= '' and r.sp_rx + rw) or hw
    end
    local a, keep, x = faint and 150 or 255, ctx.tr_keep, xe - r.sp_w
    if r.sp_h ~= '' then
      if keep then keep(r.sp_h) end
      ctx.text(x, ty, r.sp_h, px, ec and c or nav.st_col(r.st_k, c, col, faint), layer)
    end
    if r.sp_r ~= '' then
      if keep then keep(r.sp_r) end
      ctx.text(x + r.sp_rx, ty, r.sp_r, px, c, layer)
    end
    if r.sp_e ~= '' then
      if keep then keep(r.sp_e) end
      ctx.text(x + r.sp_ex, ty, r.sp_e, px, (ec and (r.st_eo and c or ec)) or (r.st_eo and nav.pc('dim', col, a))
        or nav.st_c(3, col, faint), layer)
    end
    return x
  end
  -- An entry's status on its title bar (r: its switch row; nil, the loader's own or a heading two mods share: none),
  -- right-aligned to end at xe, after the title (and its version), which ends at le and keeps its room: nav.status_draw.
  -- The compact look's yellow bar (ink: its ink, dim then for the text; on a dark bar, nil: the text in its colors)
  -- has a small square of the state's color before it, ringed in the ink so the light green and orange read on the
  -- yellow. Where the bar is too narrow for the state word the square stays alone; narrower still, nothing.
  function nav.status_bar(r, le, xe, ty, px, P, c, col, faint, layer, ink, gray)
    if not (r and r.switch and svc.util) then return end
    if not ink then nav.status_draw(r, xe, ty, xe - le - 6 * px, px, P, c, col, faint, layer); return end
    local d = floor(4.2 * px + 0.5)              -- (about 0.6 of a capital's height)
    local room = xe - le - 6 * px - d - 3 * px
    if room + 3 * px < 0 then return end
    local sx = nav.status_draw(r, xe, ty, room, px, P, c, col, faint, layer, nav.pc('err', col))
    local dx, dy, e = (sx < xe and sx - 3 * px or xe) - d, ty + floor((7 * px - d) / 2), max(1, floor(px / 2))
    ctx.rect(dx, dy, d, d, ink, layer)
    ctx.rect(dx + e, dy + e, d - 2 * e, d - 2 * e, nav.st_col(r.st_k, gray, col, faint), layer + 1)
  end
  -- how many decimals a number has, 3 at most (2.5: 1, 0.25: 2, 4: 0)
  function nav.places(x)
    for d = 0, 2 do
      local m = x * 10 ^ d
      if math.abs(m - floor(m + 0.5)) < 1e-6 then return d end
    end
    return 3
  end
  local function value_text(r, users)
    local s, v = r.spec, r.value
    if s.type == 'toggle' then return v and 'ON' or 'OFF' end
    if s.type == 'choice' then return text_of(s.choices[v]) end
    if s.type == 'slider' then
      -- (a whole number only when the value is one; else as many decimals as its step and min have, 3 at most, 2
      -- for a slider without a step. Worked out once a row and step: r.dp)
      if floor(v) == v and v > -1e9 and v < 1e9 then return fmt('%d', v) end
      local st = s.step or 0
      if r.dp_st ~= st then
        r.dp_st, r.dp = st, st > 0 and max(nav.places(st), nav.places(s.min), nav.places(s.max)) or 2
      end
      local t = fmt(r.dp == 1 and '%.1f' or (r.dp == 2 and '%.2f' or (r.dp == 3 and '%.3f' or '%.0f')), v)
      -- (a value a hair off a whole one, 0.1 * 30, reads as the whole one)
      if r.dp > 0 and t:find('%.0+$') then t = t:gsub('%.0+$', '') end
      return t == '-0' and '0' or t
    end
    if s.type == 'key' then
      if menu.capture == r then return 'PRESS A KEY' end
      -- (a controller button as 'PAD CROSS': the menu's font has no '_'; a combo shows as it's kept, 'CTRL+F6')
      local shown = v == 'off' and 'NONE' or (v:find('^pad:') and 'pad ' .. (v:sub(5):gsub('_', ' '))) or v
      return shown .. ((v ~= 'off' and (users[v] or 0) > 1) and ' !' or '')
    end
    if s.type == 'button' then return text_of(s.text or 'RUN') end
    if s.type == 'color' then return tostring(v) end         -- (the menu's font has no '#')
    return tostring(v)
  end
  -- a color row's swatch, drawn just left of its value (its three numbers kept on the row as r.sw, worked out again
  -- only when the value changes: r.sw_v), toned so it shows the color its value names (nav.tone)
  local function swatch(r, x, y, sz, layer, a)
    local v, s = r.value, r.sw
    if r.sw_v ~= v then
      s = s or {}
      s[1], s[2], s[3] = nav.tone(tonumber(v:sub(1, 2), 16), tonumber(v:sub(3, 4), 16), tonumber(v:sub(5, 6), 16))
      r.sw, r.sw_v = s, v
    end
    ctx.rect(x, y, sz, sz, ctx.color(s[1], s[2], s[3], a or 255), layer)
  end
  -- the selected row's hint (a mod's spec.hint), shown on its own line over the key hints while it's selected
  local function row_hint(l)
    local h = l and l.row and l.row.spec.hint
    return type(h) == 'string' and h ~= '' and h or nil
  end
  -- the key hints for the selected line in an entry or a search: the Back row, a row Left and Right change, or any
  -- other line
  function nav.entry_hints(l)
    if l and l.back then return HINTS.back end
    if l and l.fold then return l.open and HINTS.fold_open or HINTS.fold_shut end
    local t = l and l.row and l.row.spec.type
    if t == 'toggle' or t == 'choice' or t == 'slider' or t == 'color' then return HINTS.value end
    -- (a key or a button in a fold: Left closes the fold, menu_input)
    return l and l.fo and HINTS.group_fold or HINTS.group
  end
  -- (a key pressed: the hints show the keys)
  local function pressed(name) local v = ctx.key_pressed(name); if v then menu.dev = 'keys' end; return v end
  -- a menu action this frame: its key, or the controller's button or the mouse standing in for it
  local function act(name) return nav.act[name] == true or pressed(name) end
  local function capture_key(combos)
    -- any key pressed this frame, by its engine name (Escape cancels, Delete clears); for a row that takes combos,
    -- the first key pressed that isn't a modifier, and the first modifier pressed as the second answer
    local n = guarded('loader', 'Keyboard.num_buttons', fn_of('Keyboard.num_buttons'))
    if type(n) ~= 'number' then return nil end
    -- (the two calls found once a frame, not once a key)
    local mod, kp, kn = nil, fn_of('Keyboard.pressed'), fn_of('Keyboard.button_name')
    for i = 0, n - 1 do
      if guarded('loader', 'Keyboard.pressed', kp, i) == true then
        local name = guarded('loader', 'Keyboard.button_name', kn, i)
        if type(name) == 'string' and name ~= '' then
          if not (combos and MOD_OF[name] and name:find(' ')) then return name end
          mod = mod or name
        end
      end
    end
    return nil, mod
  end
  -- a modifier key held now (its index asked once per capture: menu.kix, false for none)
  function nav.key_held(name)
    local i = menu.kix[name]
    if i == nil then
      i = eng('Keyboard.button_index', name)
      if type(i) ~= 'number' then i = false end
      menu.kix[name] = i
    end
    if not i then return false end
    local v = eng('Keyboard.button', i)
    return v == true or (type(v) == 'number' and v > 0.5)
  end
  -- the key pressed in a capture with the modifiers held now in front of it ('ctrl+shift+f6')
  function nav.with_mods(k)
    local front = ''
    for _, m in ipairs(MODS) do
      local two = MOD_KEYS[m]
      if nav.key_held(two[1]) or nav.key_held(two[2]) then front = front .. m .. '+' end
    end
    return front .. k
  end
  -- A controller button pressed in a capture, as 'pad:<its name>' (rows chef.bind made, while the controller is on
  -- for my menu). Circle/B cancels and square/X sets none, as Escape and Delete do, so neither is ever bound; nor is
  -- the touchpad / View (it opens my menu). The buttons already down when the capture started (cross/A started it)
  -- are held, not pressed. Every button is read, only while a capture waits.
  function nav.cap_pad()
    local by = nav.pad and nav.by
    if not by or pad_row.value == 3 then return nil end
    local seed, was = menu.cpad == nil, menu.cpad
    if seed then was = {}; menu.cpad = was end
    local got
    for nm, i in pairs(by) do
      local v = eng(nav.calls.button, i)
      local d = v == true or (type(v) == 'number' and v > 0.5)
      if d and not seed and not was[nm] and not got then
        if i == nav.ix.delete then got = 'off'
        elseif i ~= nav.ix.back and i ~= nav.ix.touch then got = 'pad:' .. nm end
      end
      was[nm] = d or nil
    end
    return got
  end
  -- the search: '/' starts typing; letters, digits and spaces go in, Backspace (or Delete) takes one off, Down or Up
  -- (or Enter) keeps it (the list filtered by it), '/' again or Escape leaves it (the typed text comes from
  -- Keyboard.keystrokes, through the utilities)
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
    -- Down keeps it with the cursor on the first line found, Up on the last (none found: the Back row; nothing typed:
    -- the list's first mod), so a search never needs Enter, which also opens the game's chat. The keys only: this
    -- frame's press is used up here, the cursor never steps on with it
    local d = pressed('down') and 1 or (pressed('up') and -1 or 0)
    if d ~= 0 then
      menu.typing, menu.sel, menu.top = false, 1, 1
      if menu.search ~= '' then local ls = lines(); nav.step(ls, #ls, d) end
    end
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
  -- the cursor a line on (d: 1 down, -1 up) among the n lines ls, past the headings, round from one end to the other
  function nav.step(ls, n, d)
    local i = menu.sel
    for _ = 1, n do
      i = i + d
      if i < 1 then i = n elseif i > n then i = 1 end
      if not ls[i].head then menu.sel = i; return end
    end
  end
  local function menu_input(ls)
    if menu.capture then
      local r = menu.capture
      -- A row that takes combos (chef.bind's, the look-alike's): a key pressed with modifiers held is that combo. A
      -- modifier pressed waits for the key; let go with none pressed, it's bound on its own ('left ctrl'). Any other
      -- key row (the menu's own key above all) takes the first key pressed, a modifier too, and never makes a combo.
      local combos = r.spec.combos and not r.spec.menu
      if menu.cap_for ~= r then menu.cap_for, menu.cmod, menu.cpad, menu.kix = r, nil, nil, {} end
      local k, m = capture_key(combos)
      local v
      if combos and not k then
        if m then menu.cmod = m end
        v = r.spec.pads and nav.cap_pad() or nil
        if not v and not m and menu.cmod and not nav.key_held(menu.cmod) then v = menu.cmod end
      end
      if k == 'escape' or nav.act.back then menu.capture, menu.cap_for = nil, nil
      -- Delete: none (the menu's own key goes back to its default instead)
      elseif k == 'delete' then set_row(r, r.spec.menu and r.default or 'off'); menu.capture, menu.cap_for = nil, nil
      -- the menu's own key can't be one the menu uses: it keeps waiting for another
      elseif (k and not (r.spec.menu and MENU_KEYS[k])) or v then
        set_row(r, v or (combos and nav.with_mods(k)) or k); menu.capture, menu.cap_for = nil, nil
        conflicts_said = {}; note_conflicts()
      end
      return
    end
    local n = #ls
    local step = nav.step
    if ls[menu.sel] == nil or ls[menu.sel].head then step(ls, n, 1) end
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
        if menu.sel < top then menu.sel = top; if ls[top].head then step(ls, n, 1) end
        elseif menu.sel > top + vis - 1 then menu.sel = top + vis - 1; if ls[menu.sel].head then step(ls, n, -1) end end
        kind = nil
      end
      if not nav.drag and kind == 'line' and ls[i] and not ls[i].head and (nav.moved or nav.click) then menu.sel = i end
      if nav.click then
        if kind == 'line' and ls[i] then
          local t = ls[i].row and ls[i].row.spec.type
          if t == 'choice' or t == 'slider' or t == 'color' then nav.act.right = true else nav.act.enter = true end
        elseif (kind == 'dec' or kind == 'inc') and ls[i] then
          menu.sel = i; nav.act[kind == 'dec' and 'left' or 'right'] = true
        elseif kind == 'group' then
          local g = nav.listed()[i]
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
    if act('down') then step(ls, n, 1) elseif act('up') then step(ls, n, -1)
    elseif act('page down') then for _ = 1, 8 do step(ls, n, 1) end
    elseif act('page up') then for _ = 1, 8 do step(ls, n, -1) end end
    local l = ls[menu.sel]
    -- a mod in the list: Enter (or Right) opens its options, the cursor on its first option (Back is just above it)
    if l and l.pick then
      if act('enter') or act('right') then open_group(menu.sel, l.pick) end
      return
    end
    -- (the Back row: on the keyboard Right goes back too, as it acts on a key or a button row)
    if l and l.back then
      if act('enter') or act('left') or pressed('right') then go_back() end
      return
    end
    -- a fold (a mod's heading): Enter (the pad's confirm, a click) opens or closes it; Right opens it, or steps into it
    -- when it's open; Left closes it, or goes back to the list when it's closed (the keyboard's, as on a key row)
    if l and l.fold then
      if act('enter') or (l.open and act('left')) or (not l.open and act('right')) then nav.fold_set(l, l.open)
      elseif act('right') then step(ls, n, 1)
      elseif pressed('left') then go_back() end
      return
    end
    local r = l and l.row
    if not r then return end
    local s = r.spec
    local dir = act('right') and 1 or (act('left') and -1 or 0)
    if act('delete') then set_row(r, r.default); return end
    -- A key or a button has no value to step: on the keyboard, Right does what Enter does (a capture, a press) and Left
    -- goes back to the list, so neither needs Enter or Backspace, which the game hears too. The controller and the
    -- mouse keep theirs (their arrows step values only).
    local go = act('enter')
    if s.type == 'key' or s.type == 'button' then
      -- (in a fold, Left closes it with the cursor on it, as a file tree does; only then back to the list)
      if pressed('left') then
        local f = l.fo
        if not f then go_back(); return end
        for j = menu.sel, 1, -1 do if ls[j] == f then menu.sel = j; break end end
        nav.fold_set(f, true)
        return
      end
      go = go or pressed('right')
    end
    if s.type == 'toggle' and (dir ~= 0 or act('enter')) then set_row(r, not r.value)
    elseif s.type == 'choice' and dir ~= 0 then
      local v = r.value + dir
      if v < 1 then v = #s.choices elseif v > #s.choices then v = 1 end
      set_row(r, v)
    elseif s.type == 'slider' and dir ~= 0 then set_row(r, r.value + dir * ((s.step or 0) > 0 and s.step or (s.max - s.min) / 20))
    elseif s.type == 'key' and go then menu.capture = r
    elseif s.type == 'button' and go then press(r)
    elseif s.type == 'color' and dir ~= 0 then step_color(r, dir) end
  end
  -- ("Menu opacity (%)": every color of the compact panel has its alpha scaled by it, menu_op set each
  -- frame it's drawn; my cursor, drawn on its own, stays solid)
  local menu_op = 1
  local function menu_col(r, g, bl, a) return ctx.color(r, g, bl, floor(a * menu_op + 0.5)) end
  -- The look: a dark panel in a yellow frame, the title on a yellow bar, the
  -- picked row lit with a yellow edge, values in green (OFF in gray), keys as light chips, the hints under a thin line.
  -- a text's y, to sit centered in a row from y up, hgt high, at size p (the pixel font's 7 rows; the game's font is
  -- placed the same)
  function nav.midy(y, hgt, p) return y + floor((hgt - 7 * p) / 2) end
  -- My version (a test build's number with it, as my log's start line has it) after my title, in my entry in the list
  -- and on its bar when it's open, in a dimmer color: a text of its own, never part of the title (the search, the
  -- language and svc.option_texts see the title alone) and never translated (kept as drawn). Made once, in both
  -- fonts' capitals, with the test number and (a test build) without it; drawn whole after the title as drawn, the
  -- first that fits (x, ty: the title's place, room: its room), else not at all.
  do
    local v, tv = ' ' .. tostring(ctx.VERSION), ctx.TEST and (' Test ' .. tostring(ctx.TEST)) or ''
    nav.ver_c, nav.ver_p = { caps(v .. tv), tv ~= '' and caps(v) or nil }, { plain(v .. tv), tv ~= '' and plain(v) or nil }
  end
  -- (vc, vp: another version to draw so, in the two fonts' capitals: a mod's after its switch, nav.ver_row. Returns
  -- where the version drawn ends, for a status after it: nav.status_bar)
  function nav.ver_after(x, ty, title, room, px, c, layer, vc, vp)
    local vs = (ctx.text_native and ctx.text_native()) and (vc or nav.ver_c) or (vp or nav.ver_p)
    local tw = ctx.text_width
    local w0 = tw(title, px)
    for i = 1, #vs do
      local v = vs[i]
      if ctx.tr_keep then ctx.tr_keep(v) end
      local vw = tw(v, px)
      if w0 + vw <= room then ctx.text(x + w0, ty, v, px, c, layer); return x + w0 + vw end
    end
  end
  -- A mod's version after its switch's label (the mod's name), as mine is after my title: the version its record has
  -- (a.version, read when it started: none for a mod that never started or has no version), as the mod gave it, with no
  -- V. Made in both fonts' capitals only when it changes, kept on the row (r.ver_k: the version it was made from;
  -- r.ver_c, r.ver_p). label: the label uncut, as drawn before fit, so the version goes only after a whole name, and
  -- only where it fits whole before the value (room: the label's room), else not at all.
  function nav.ver_row(r, x, ty, label, room, px, c, layer)
    local a = recs[r.mod]
    local v = a and type(a.version) == 'string' and a.version ~= '' and a.version or nil
    if v ~= r.ver_k then
      local s = v and (' ' .. v):gsub('%c', ' ')
      r.ver_k, r.ver_c, r.ver_p = v, s and { caps(s) }, s and { plain(s) }
    end
    if r.ver_c then return nav.ver_after(x, ty, label, room, px, c, layer, r.ver_c, r.ver_p) end
  end
  -- The compact panel kept clear of the performance monitor (mon: the layout it drew last frame, svc.util.pm.shown;
  -- y up, x0 / y1 its left and top edges): where the two would overlap, the panel's top goes under the monitor, or
  -- it keeps its top and ends above it, whichever leaves more rows (at least 4, else it stays as it was: the monitor
  -- is drawn over it); x never moves, and fewer rows only means it scrolls sooner. y0 / visible: the panel's top and
  -- rows as they'd be, ls: its lines (a short panel under a monitor lower down stays put); its top and rows returned.
  -- Worked out again only when the monitor's rect, the panel's size or its lines change (kept in nav.mc; a new line
  -- list is a new table), and never while the monitor is being dragged: the panel moves once, where it's let go.
  function nav.clear_of(mon, x0, pw, rh, px, h, y0, visible, ls)
    local C = nav.mc
    if not C then C = {}; nav.mc = C end
    local pm = svc.util.pm
    if C.y0 and (pm.drag or (C.mx == mon.x0 and C.my == mon.y1 and C.mw == mon.pw and C.mh == mon.ph and C.x0 == x0
       and C.pw == pw and C.rh == rh and C.ty == y0 and C.vis0 == visible and C.ls == ls)) then
      return C.y0, C.vis
    end
    C.mx, C.my, C.mw, C.mh, C.x0, C.pw, C.rh, C.ty, C.vis0, C.ls = mon.x0, mon.y1, mon.pw, mon.ph, x0, pw, rh, y0, visible, ls
    C.y0, C.vis = y0, visible
    -- (k rows take (k + 2) rows' height and 27 px: the title bar, the hint line, their edges and the gap under the
    -- bar, 7 px, and the room the selected row's hint takes at most, its two lines, 20 px; kept whether a hint shows or
    -- not, so the panel doesn't move as the cursor does. A short panel shows every line: its separators' short lines
    -- counted as they're drawn)
    local gap, bottom, e, n = 4 * px, floor(h * 0.04), 27 * px, #ls
    local ht = (min(visible, n) + 2) * rh + e
    if n <= visible then for i = 1, n do if ls[i].sep then ht = ht - rh + 5 * px end end end
    local mt, mb = mon.y1, mon.y1 - mon.ph
    if mon.x0 >= x0 + pw or mon.x0 + mon.pw <= x0 or mb >= y0 or mt <= y0 - ht then
      return y0, visible
    end
    local under = min(visible, floor((mb - gap - bottom - e) / rh) - 2)
    local above = min(visible, floor((y0 - mt - gap - e) / rh) - 2)
    if under >= 4 and under >= above then C.y0, C.vis = mb - gap, under
    elseif above >= 4 then C.vis = above end
    return C.y0, C.vis
  end
  -- The selected row's hint (or what else its clashing key is bound to) as lines of its own, w wide, at most `most`,
  -- the last one cut with dots when there's more. Wrapped again only when the text, its size, its room, the font or
  -- the language changed: nav.hw keeps the lines and how many, so a frame makes nothing new.
  nav.hw, nav.nf = {}, {}                      -- (nav.nf: the full screen look's note line, as drawn)
  function nav.hwrap(s, P, px, w, fit, most)
    local c, lv = nav.hw, ctx.lang_v and ctx.lang_v() or 0
    if c.s == s and c.px == px and c.w == w and c.P == P and c.lv == lv and c.most == most then return c.n end
    c.s, c.px, c.w, c.P, c.lv, c.most = s, px, w, P, lv, most
    local t, ws = P(s), nil
    if ctx.text_wrap then ws = ctx.text_wrap(t, px, w, most + 1)
    else
      -- (a host without the loader's wrap: at spaces, by the pixel font's fixed cells)
      ws = {}
      local cur, n = '', floor((w + px) / (6 * px))
      for word in t:gmatch('%S+') do
        if cur == '' or #cur + 1 + #word <= n then cur = cur == '' and word or (cur .. ' ' .. word)
        else ws[#ws + 1] = cur; cur = word end
      end
      if cur ~= '' then ws[#ws + 1] = cur end
    end
    c.n = min(#ws, most)
    for i = 1, c.n do c[i] = fit(ws[i], px, w) end
    if ws[most + 1] then c[most] = fit(ws[most] .. '...', px, w) end
    return c.n
  end
  -- A thin scroll track on a list's right edge (xr: its right side, from yt down to yb) with a thumb for the lines in
  -- view (first, vis of n), and a small arrow at an end that has more lines past it. Nothing when they all fit.
  function nav.sbar(xr, yt, yb, first, vis, n, px, layer, trc, thc)
    if n <= vis and first <= 1 then return end
    local u = max(1, floor(px * 0.6 + 0.5))          -- (an arrow's step)
    local tk, cx = max(1, floor(px / 2)), xr - px
    local t1, t0 = yt - 4 * u, yb + 4 * u            -- (the track, between the arrows' room)
    local L = t1 - t0
    if L < 4 * px then return end
    ctx.rect(cx + floor((px - tk) / 2), t0, tk, L, trc, layer)
    local th = min(L, max(2 * px, floor(L * vis / n)))
    local f = n > vis and max(0, min(1, (first - 1) / (n - vis))) or 0
    ctx.rect(cx, t1 - th - floor((L - th) * f), px, th, thc, layer + 1)
    local mid = cx + floor(px / 2)
    for k = 0, 2 do
      local wk = (2 * k + 1) * u
      if first > 1 then ctx.rect(mid - floor(wk / 2), yt - (k + 1) * u, wk, u, thc, layer + 1) end
      if first + vis - 1 < n then ctx.rect(mid - floor(wk / 2), yb + k * u, wk, u, thc, layer + 1) end
    end
  end
  -- a reset button asking: the seconds it has left to be pressed again (3, 2, 1), drawn after its SURE?; the text made
  -- again only when the second changes
  function nav.sure(r)
    local n = max(1, min(9, -floor(ctx.now() - r.armed)))
    if r.sure_n ~= n then r.sure_n, r.sure_s = n, tostring(n) end
    return r.sure_s
  end
  local function menu_draw(ls)
    local w, h = ctx.screen()
    local px = max(2, floor(h / 540 + 0.5))
    local top = ctx.TOP + 950
    local rh, cols = 12 * px, 40
    local pw = (cols * 6 + 10) * px
    local place = menu_place and tonumber(menu_place.value) or 1
    -- (Right: 2% from the edge, as the monitor's places on the right, so the two line up there)
    local x0 = max(0, (place == 2 and floor((w - pw) / 2)) or (place == 3 and w - pw - floor(w * 0.02)) or floor(w * 0.05))
    local visible = max(4, floor((h * 0.7) / rh) - 4)
    local y0 = floor(h * 0.85)                 -- the panel's top edge (y grows upward)
    local mon = svc.util and svc.util.pm and svc.util.pm.shown
    if mon then y0, visible = nav.clear_of(mon, x0, pw, rh, px, h, y0, visible, ls) end
    nav.visible = visible                      -- (the wheel keeps the picked line among the lines in view)
    if menu.sel < menu.top then menu.top = menu.sel elseif menu.sel >= menu.top + visible then menu.top = menu.sel - visible + 1 end
    -- (a section's heading kept in view with its first row, when keys or the pad got there: under the mouse the
    -- list never moves)
    if menu.dev ~= 'mouse' and menu.top == menu.sel and menu.sel > 1 and ls[menu.sel - 1]
       and (ls[menu.sel - 1].head or ls[menu.sel - 1].fold) then
      menu.top = menu.sel - 1
    end
    -- (fewer lines than before, a fold closed: no room left empty under the last one)
    menu.top = max(1, min(menu.top, #ls - visible + 1))
    local shown = min(visible, #ls - menu.top + 1)
    local hb = rh + 2 * px                     -- the title bar
    local sh = 5 * px                          -- a separator's line: under half a row
    local tx = 7 * px                          -- the text's left inset
    -- text cut to the room it has, measured (the game's font is proportional), in the font's characters
    local P = ctx.text_native and ctx.text_native() and caps or plain
    local fit, tw = ctx.text_fit or fit_cells, ctx.text_width
    local inner = pw - 2 * tx                  -- the width between the insets
    -- The selected row's hint, or what else a clashing key is bound to, on lines of their own over the key hints (at
    -- most two, then cut): the key hints stay, and the panel grows down by those lines while it has one.
    local users = key_users()
    local live = not menu.capture and not menu.typing
    local clash = live and clash_hint(ls[menu.sel], users)
    local note = clash and clash_drawn(clash, P) or (live and row_hint(ls[menu.sel]))
    local nl = note and nav.hwrap(note, P, px, inner, fit, 2) or 0
    local lh = 9 * px                          -- (a hint line: a little tighter than a row)
    local nh = nl > 0 and nl * lh + px or 0
    local gap = px                             -- (under the title bar: the Back row lit there never touches it)
    local ph = hb + gap + shown * rh + 3 * px + rh + 2 * px + nh
    for i = menu.top, menu.top + shown - 1 do if ls[i].sep then ph = ph - rh + sh end end
    menu_op = (menu_alpha and tonumber(menu_alpha.value) or 100) / 100
    local col = menu_col
    local yellow, ink = col(255, 231, 16, 255), col(17, 17, 17, 255)
    local white, green, gray = col(232, 232, 226, 255), nav.st_c(1, col), nav.pc('gray', col)
    local subc = nav.pc('sub', col)            -- a subheading: a muted gold, well under the headings' yellow
    local orange = nav.st_c(2, col)            -- a reset button asking SURE?
    local midy = nav.midy
    -- panel, frame, title bar
    ctx.rect(x0, y0 - ph, pw, ph, col(9, 11, 10, 238), top)
    local b = max(1, floor(px * 0.75))
    ctx.rect(x0, y0 - ph, pw, b, yellow, top + 3); ctx.rect(x0, y0 - b, pw, b, yellow, top + 3)
    ctx.rect(x0, y0 - ph, b, ph, yellow, top + 3); ctx.rect(x0 + pw - b, y0 - ph, b, ph, yellow, top + 3)
    ctx.rect(x0, y0 - hb, pw, hb, yellow, top + 1)
    local head = menu.group and text_of(menu.group.title) or 'MOD OPTIONS'
    local right = fit((menu.typing or menu.search ~= '') and P('/' .. menu.search .. (menu.typing and '_' or ''))
      or P(menu_key.value ~= 'off' and menu_key.value or ''), px, floor(inner * 0.45))
    local rw = right ~= '' and tw(right, px) or 0
    local hw = inner - rw - (rw > 0 and 4 * px or 0)
    head = fit(P(head), px, hw)
    ctx.text(x0 + tx, midy(y0 - hb, hb, px), head, px, ink, top + 2)
    if rw > 0 then ctx.text(x0 + pw - tx - rw, midy(y0 - hb, hb, px), right, px, ink, top + 2) end
    -- (my entry open: my version after its title, a small gap after it, in a fainter ink that still reads on yellow)
    if menu.group and menu.group.mod == loader_mod then
      nav.ver_after(x0 + tx + 2 * px, midy(y0 - hb, hb, px), head, hw - 2 * px, px, col(17, 17, 17, 200), top + 2)
    elseif menu.group and menu.search == '' then
      -- (a mod's entry open: its status between its title and the key, in that fainter ink, its state's square before it)
      nav.status_bar(menu.group.rows[1], x0 + tx + tw(head, px), x0 + pw - tx - rw - (rw > 0 and 6 * px or 0),
        midy(y0 - hb, hb, px), px, P, col(17, 17, 17, 200), col, false, top + 2, ink, gray)
    end
    local y = y0 - hb - gap - rh
    for i = menu.top, menu.top + shown - 1 do
      local l = ls[i]
      if l.sep then y = y + rh - sh end        -- (a separator's short line: the top of a row's room)
      local sel = i == menu.sel and not l.head
      if sel then
        ctx.rect(x0 + b, y, pw - 2 * b, rh, col(255, 231, 16, 42), top + 1)
        ctx.rect(x0 + b, y, 2 * px, rh, yellow, top + 2)
      end
      local ty = midy(y, rh, px)
      if not l.head then nav.hit(x0 + b, y, pw - 2 * b, rh, 'line', i) end
      if l.pt then
        -- (a package's INCLUDED line: where a row's label starts, its state where a switch's ON is)
        nav.part(l.pt, x0 + tx + 14 * px, ty, x0 + pw - tx, nil, px, gray, nav.pc('dim', col), col, false, top + 2)
      elseif l.sep then
        -- (a separator: a thin faint rule (rule) from where a row's label starts to where its value ends, mid line)
        local th = max(1, floor(px / 2))
        ctx.rect(x0 + tx + 2 * px, y + floor((sh - th) / 2), inner - 2 * px, th, nav.pc('rule', col), top + 2)
      elseif l.head and l.sub then
        -- (a subheading two letters in from a heading, its rows two letters in from the others)
        ctx.text(x0 + tx + 12 * px, ty, fit(P(l.text), px, inner - 12 * px), px, subc, top + 2)
      elseif l.mt then
        -- (a mod's title in a search's results: white, as in the list of mods, its version in gray after it and a thin
        -- line under it, so it stands apart from its own headings' yellow under it; the mod's status at its right, as
        -- on its entry's bar, in its colors on the dark panel)
        local tt = fit(P(text_of(l.text)), px, inner)
        ctx.text(x0 + tx, ty, tt, px, white, top + 2)
        local s1 = l.mt.rows[1]
        if l.mt.mod == loader_mod then nav.ver_after(x0 + tx, ty, tt, inner, px, gray, top + 2)
        elseif s1 and s1.switch then
          local ve = nav.ver_row(s1, x0 + tx, ty, tt, inner, px, gray, top + 2)
          nav.status_bar(s1, ve or x0 + tx + tw(tt, px), x0 + pw - tx, ty, px, P, gray, col, false, top + 2)
        end
        ctx.rect(x0 + tx, y, inner, max(1, floor(px / 2)), col(255, 231, 16, 90), top + 2)
      elseif l.head then
        ctx.text(x0 + tx, ty, fit(P(l.text), px, inner), px, yellow, top + 2)
      elseif l.fold then
        -- (a fold: a heading, its count of rows in gray after it while it's closed, + (closed) or - (open) where a
        -- mod's > is in the list)
        local mk = l.open and '-' or '+'
        local mw = tw(mk, px)
        local cw = l.open and 0 or tw(l.ct, px) + 4 * px
        local ht = fit(P(l.text), px, inner - mw - 6 * px - cw)
        ctx.text(x0 + tx, ty, ht, px, yellow, top + 2)
        if not l.open then
          if ctx.tr_keep then ctx.tr_keep(l.ct) end
          ctx.text(x0 + tx + tw(ht, px) + 4 * px, ty, l.ct, px, gray, top + 2)
        end
        ctx.text(x0 + pw - tx - mw, ty, mk, px, yellow, top + 2)
      elseif l.back then
        -- (lit, in white: yellow on the yellow glow would melt into the title bar over it)
        ctx.text(x0 + tx + 2 * px, ty, fit(P(l.text), px, inner - 2 * px), px, sel and white or yellow, top + 2)
      elseif l.pick then
        local aw = tw('>', px)
        local room = inner - 2 * px - aw - 4 * px
        local tt = fit(P(text_of(l.text)), px, room)
        ctx.text(x0 + tx + 2 * px, ty, tt, px, white, top + 2)
        ctx.text(x0 + pw - tx - aw, ty, '>', px, green, top + 2)
        -- (my own entry: my version after my title, in gray; on the lit row in the lighter hint gray)
        if l.pick.mod == loader_mod then
          nav.ver_after(x0 + tx + 2 * px, ty, tt, room, px, sel and nav.pc('hint', col) or gray, top + 2)
        end
        -- (a thin line under my own entry, between it and the mods)
        if l.pick.mod == loader_mod and ls[i + 1] then
          ctx.rect(x0 + tx, y, inner, max(1, floor(px / 2)), col(255, 231, 16, 90), top + 2)
        end
      else
        local r = l.row
        local t = r.spec.type
        local lt = P(text_of(r.spec.label or r.id))
        local lx = x0 + tx + (l.indent and 14 or 2) * px  -- (a subheading's rows indented with it)
        -- a choice or a slider picked: < value >, as in the full screen look; a reset button asking: its seconds left
        local arr = sel and (t == 'choice' or t == 'slider')
        local aw = arr and tw('>', px) + 3 * px or 0
        local sz = t == 'color' and rh - 4 * px or 0
        local arm = r.armed and ctx.now() < r.armed
        local cd = arm and nav.sure(r)
        local cw = cd and tw(cd, px) + 2 * px or 0      -- (its seconds close after SURE?, its label a little closer)
        local xe = x0 + pw - tx - aw - (sz > 0 and sz + 3 * px or 0) - cw   -- (the value's right edge)
        -- the value first, in the room the label leaves it (never under 40% of the row, arrows and all), then the
        -- label in what's left
        local v = fit(P(value_text(r, users)), px, max(floor(inner * 0.4) - 2 * aw, xe - aw - 6 * px - lx - tw(lt, px)))
        local vw = tw(v, px)
        local vx = xe - vw
        if sz > 0 then swatch(r, xe + 3 * px, y + 2 * px, sz, top + 3, floor(255 * menu_op + 0.5)) end
        if arr then
          -- (each arrow a box of its own for the mouse: a click steps it that way)
          local ax = xe + 3 * px
          ctx.text(vx - aw, ty, '<', px, yellow, top + 2)
          ctx.text(ax, ty, '>', px, yellow, top + 2)
          nav.hit(vx - aw - px, y, aw, rh, 'dec', i)
          nav.hit(ax - 2 * px, y, aw, rh, 'inc', i)
        end
        local lr = vx - aw - (arm and 4 or 6) * px - lx   -- (the label's room)
        ctx.text(lx, ty, fit(lt, px, lr), px, white, top + 2)
        -- (a mod's switch: its version after its name, in gray; on the lit row in the lighter hint gray)
        if r.switch then nav.ver_row(r, lx, ty, lt, lr, px, sel and nav.pc('hint', col) or gray, top + 2) end
        if t == 'key' and menu.capture ~= r then
          -- a key: a light chip with the key's name in ink
          ctx.rect(vx - 2 * px, y + 2 * px, vw + 4 * px, rh - 4 * px, white, top + 2)
          ctx.text(vx, ty, v, px, ink, top + 3)
        else
          ctx.text(vx, ty, v, px, arm and orange or ((t == 'toggle' and not r.value) and gray or (menu.capture == r and yellow or green)), top + 2)
        end
        if arm then
          ctx.text(xe + 2 * px, ty, cd, px, orange, top + 2)
          ctx.rect(x0 + b, y, 2 * px, rh, orange, top + 3)
        end
      end
      y = y - rh
    end
    -- (more lines than room: a scroll track on the right edge)
    if menu.top > 1 or #ls > visible then
      nav.sbar(x0 + pw - b - px, y0 - hb - gap, y + rh, menu.top, visible, #ls, px, top + 3, nav.pc('rule', col), col(255, 231, 16, 150))
    end
    -- the hints under a thin line: the note's lines (dim gray; a clash in yellow), then the key hints
    local fy = y0 - ph + rh + 2 * px + nh
    ctx.rect(x0 + b, fy, pw - 2 * b, max(1, floor(px / 2)), col(255, 231, 16, 70), top + 1)
    local nc = clash and yellow or nav.pc('hint', col)
    for k = 1, nl do
      local s = nav.hw[k]
      if ctx.tr_keep then ctx.tr_keep(s) end
      ctx.text(x0 + tx, fy - k * lh, s, px, nc, top + 2)
    end
    -- (for what was used last, the keyboard, the mouse or the controller, as the full screen look's)
    local hy = y0 - ph + px
    local dev = menu.dev
    if dev == 'pad' and (not nav.pad or menu.capture or menu.typing) then dev = 'keys' end
    if dev == 'mouse' and not nav.mouse then dev = 'keys' end
    if dev == 'pad' then nav.pad_hints(x0 + tx, x0 + tx + inner, hy, rh, px, P, col, white, top + 2)
    else
      local segs = menu.capture and (menu.capture.spec.menu and HINTS.capture_default or HINTS.capture_none)
        or (menu.typing and HINTS.typing) or (dev == 'mouse' and HINTS.mouse)
        or ((menu.group or menu.search ~= '') and nav.entry_hints(ls[menu.sel])) or HINTS.list
      hint_line(ctx, x0 + tx, hy, rh, px, x0 + tx + inner, segs,
        svc.util and svc.util.key_label(menu_key.value) or menu_key.value, white, white, ink, top + 2, P)
    end
    nav.draw_cursor(top, h)
  end
  -- The full screen look: an opaque terminal, the mods on the left, the open mod's options on the right (at the list
  -- of mods, a preview of the picked one's), the hints at the bottom. The same lines, keys and rows as the compact
  -- panel; only the drawing differs (and the mouse's boxes).
  -- The full screen look's parts, made once (no closures a frame): a pane with its title (and a note on its right),
  -- the picked line lit, a list's first line in view for the picked one (ls: the lines, when a section's heading
  -- should stay in view with its first row; not under the mouse), the thin line under my own entry, between it and
  -- the mods. nav.F: this frame's numbers and text functions, set by menu_draw_full (px, rh, b, top; the panes' bottom
  -- and top, py0 and py1; the lines in view); the colors come in as arguments, made in the frame they're drawn in.
  nav.F = {}
  -- (own: the pane shows my entry, my version after its title in vc. Returns where the title ends, where a status
  -- after it may end (before the note) and the title's y: nav.status_bar)
  function nav.pane(x, wd, title, note, panel, line, gray, own, vc)
    local F = nav.F
    local px, rh, b, top, py0, py1 = F.px, F.rh, F.b, F.top, F.py0, F.py1
    ctx.rect(x, py0, wd, py1 - py0, panel, top + 1)
    ctx.rect(x, py1 - b, wd, b, line, top + 2); ctx.rect(x, py0, wd, b, line, top + 2)
    ctx.rect(x, py0, b, py1 - py0, line, top + 2); ctx.rect(x + wd - b, py0, b, py1 - py0, line, top + 2)
    local nw = note and F.tw(note, px) or 0
    local t = F.fit(F.P(title), px, wd - 12 * px - nw)
    local ty = nav.midy(py1 - rh - 2 * px, rh, px)
    ctx.text(x + 4 * px, ty, t, px, gray, top + 3)
    if note then ctx.text(x + wd - 4 * px - nw, ty, note, px, gray, top + 3) end
    ctx.rect(x + 3 * px, py1 - rh - 3 * px, wd - 6 * px, b, line, top + 2)
    if own then nav.ver_after(x + 4 * px, ty, t, wd - 12 * px - nw, px, vc, top + 3) end
    return x + 4 * px + F.tw(t, px), x + wd - 4 * px - (note and nw + 8 * px or 0), ty
  end
  -- (glow nil: the edge alone, for the open mod in the list while the right pane has the keys; one fill on screen)
  function nav.lit(x, wd, y, glow, yellow)
    local F = nav.F
    if glow then ctx.rect(x + F.b, y, wd - 2 * F.b, F.rh, glow, F.top + 3) end
    ctx.rect(x + F.b, y, 2 * F.px, F.rh, yellow, F.top + 4)
  end
  -- The game's pause screen up (its GAME / SOCIAL / OPTIONS tabs draw over my header): the one time it shows its own
  -- cursor on the ship. mouse_read already asked this frame while the menu has the mouse; else I ask.
  function nav.paused()
    if nav.mouse and nav.axes and nav.axes.move then return nav.game_cursor == true end
    local win = eng('Window.get_main_window')
    return win ~= nil and eng('Window.show_cursor', win) == true
  end
  -- A mod's version after its title in the full screen look's list (mine: nav.ver_after), dim, dropped when it doesn't
  -- fit. The facts are the status's (nav.st, taken at most once a second, the same way nav.status takes them:
  -- nav.facts_now, once a frame, into nav.F.st); a look-alike heading's version is the mod's whose switch it holds
  -- (none for a heading two mods share). Looked up again only when a new list was taken; the text as drawn is kept on
  -- the group (g.vt), made again only when the version or the font changes.
  function nav.facts_now()
    local u = svc.util
    if not (u and u.mod_facts) then return nil end
    local now, st = ctx.now(), nav.st
    if not st or now - st.at >= 1 or now < st.at then
      nav.facts, nav.fpool = nav.facts or {}, nav.fpool or {}
      st = { at = now, by = u.mod_facts(nav.facts, nav.fpool) }
      nav.st = st
    end
    return st
  end
  function nav.ver_mod(g, x, ty, title, room, px, c, layer)
    if g.mod == loader_mod then return nav.ver_after(x, ty, title, room, px, c, layer) end
    local st, P = nav.F.st, nav.F.P
    if not st then return end
    if g.vt_st ~= st or g.vt_p ~= P then
      local s1 = g.rows[1]
      local m = st.by[(s1 and s1.switch) and s1.mod or g.mod]
      local v = m and m.version
      g.vt_st = st
      if g.vt_src ~= v or g.vt_p ~= P then
        g.vt_src, g.vt_p, g.vt, g.vt_tt = v, P, v ~= nil and P(' ' .. tostring(v)) or nil, nil
      end
    end
    if not g.vt then return end
    if ctx.tr_keep then ctx.tr_keep(g.vt) end
    -- (where it goes, or false, kept until the title as drawn, its room or the size changes)
    -- (and where it ends, g.vt_ex, returned for a status after it: nav.status_bar)
    if g.vt_tt ~= title or g.vt_room ~= room or g.vt_px ~= px then
      local w0, vw = ctx.text_width(title, px), ctx.text_width(g.vt, px)
      g.vt_tt, g.vt_room, g.vt_px, g.vt_dx, g.vt_ex = title, room, px, w0 + vw <= room and w0, w0 + vw
    end
    if g.vt_dx then ctx.text(x + g.vt_dx, ty, g.vt, px, c, layer); return x + g.vt_ex end
  end
  function nav.scroll(sel, first, n, ls)
    local visible = nav.F.visible
    if sel < first then first = sel elseif sel >= first + visible then first = sel - visible + 1 end
    if ls and menu.dev ~= 'mouse' and first == sel and sel > 1 and ls[sel - 1] and (ls[sel - 1].head or ls[sel - 1].fold) then
      first = sel - 1
    end
    return max(1, min(first, n - visible + 1))
  end
  function nav.divider(dx, dy, dw)
    local F = nav.F
    ctx.rect(dx, dy, dw, max(1, floor(F.px / 2)), ctx.color(255, 231, 16, 90), F.top + 4)
  end
  local function menu_draw_full(ls)
    local w, h = ctx.screen()
    local s = h / 1080
    local px = max(2, floor(h / 360 + 0.5))
    local tpx = max(px + 1, floor(px * 1.6 + 0.5))
    local top = ctx.TOP + 950
    local col = ctx.color
    local yellow, ink = col(255, 231, 16, 255), col(17, 17, 17, 255)
    local white, green, gray, dim = col(232, 232, 226, 255), nav.st_c(1, col), nav.pc('gray', col), nav.pc('dim', col)
    local rule = nav.pc('rule', col)           -- (the separators and the tracks)
    local panel, line, glow = col(17, 21, 19, 255), col(255, 231, 16, 70), col(255, 231, 16, 42)
    local subc = nav.pc('sub', col)            -- a subheading: a muted gold, well under the headings' yellow
    local orange = nav.st_c(2, col)            -- a reset button asking SURE?
    local P = ctx.text_native and ctx.text_native() and caps or plain
    local fit, tw = ctx.text_fit or fit_cells, ctx.text_width
    local midy = nav.midy
    local m = floor(48 * s)                    -- the outer margin
    -- The game's own bands still draw over mine (the ship's name and the menus' keys along the top, and the
    -- player card and the dispatches along the bottom), so the title and the hints sit just inside those bands:
    -- the header and the hints' strip are taller than what's written in them.
    -- (the pause screen: its tabs and skull fill that band, so the header grows by a band and what's written in it
    -- sits under the tabs; the panes lose two rows while it's up)
    local hh, fh = floor((nav.paused() and 222 or 150) * s), floor(190 * s)  -- the header's and the hints' height
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
    ctx.text(w - m - rw, midy(h - hh, band, px), rtext, px, searching and yellow or gray, top + 2)
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
    local visible = max(3, floor((py1 - py0 - rh - 6 * px) / rh))
    nav.visible = visible                      -- (the wheel keeps the picked line among the lines in view)
    local F = nav.F
    F.px, F.rh, F.b, F.top, F.py0, F.py1, F.visible, F.P, F.fit, F.tw = px, rh, b, top, py0, py1, visible, P, fit, tw
    F.st = nav.facts_now()                     -- (the mods' versions in the list)
    local users, gs = key_users(), nav.listed()
    local listing = not menu.group and menu.search == ''       -- at the list of mods the lines are the mods
    -- the left pane: the mods, each with its version (at the list, the lines themselves; else every mod, the open one
    -- marked by its edge and yellow text, a click opens another)
    nav.pane(lx, lw, 'MODS', tostring(#gs), panel, line, gray)
    local y = py1 - rh - 4 * px - rh
    if listing then
      menu.top = nav.scroll(menu.sel, menu.top, #ls)
      for i = menu.top, min(#ls, menu.top + visible - 1) do
        local l = ls[i]
        if i == menu.sel then nav.lit(lx, lw, y, glow, yellow) end
        local tt = fit(P(text_of(l.text)), px, lw - 12 * px)
        ctx.text(lx + 6 * px, midy(y, rh, px), tt, px, i == menu.sel and yellow or white, top + 4)
        local verc = i == menu.sel and nav.pc('hint', col) or dim   -- (the lit row's: the lighter hint gray)
        nav.ver_mod(l.pick, lx + 6 * px, midy(y, rh, px), tt, lw - 12 * px, px, verc, top + 4)
        nav.hit(lx, y, lw, rh, 'line', i)
        if l.pick.mod == loader_mod and ls[i + 1] then nav.divider(lx + 4 * px, y, lw - 8 * px) end
        y = y - rh
      end
    else
      local open = 1
      for i, g in ipairs(gs) do if g == menu.group then open = i end end
      nav.ltop = nav.scroll(open, nav.ltop, #gs)
      for i = nav.ltop, min(#gs, nav.ltop + visible - 1) do
        local g = gs[i]
        local on = g == menu.group
        if on then nav.lit(lx, lw, y, nil, yellow) end
        local tt = fit(P(text_of(g.title)), px, lw - 12 * px)
        ctx.text(lx + 6 * px, midy(y, rh, px), tt, px, on and yellow or gray, top + 4)
        nav.ver_mod(g, lx + 6 * px, midy(y, rh, px), tt, lw - 12 * px, px, dim, top + 4)
        nav.hit(lx, y, lw, rh, 'group', i)
        if g.mod == loader_mod and gs[i + 1] then nav.divider(lx + 4 * px, y, lw - 8 * px) end
        y = y - rh
      end
    end
    -- (more mods than room: a scroll track on the pane's right edge)
    local ln, lf = listing and #ls or #gs, listing and menu.top or nav.ltop
    if ln > visible or lf > 1 then
      nav.sbar(lx + lw - b - px, py1 - rh - 4 * px, py1 - rh - 4 * px - visible * rh, lf, visible, ln, px, top + 5, rule, col(255, 231, 16, 150))
    end
    -- the right pane: the open mod's rows (or the search's), or at the list a preview of the picked mod's, dimmed
    local rows, title
    if listing then
      local l = ls[menu.sel]
      rows = {}
      if l and l.pick then
        -- (the entry as it would open: its folds as they are)
        if nav.pv_g ~= l.pick or nav.pv_ver ~= ver.layout or nav.pv_fv ~= ver.fold then
          nav.pv_g, nav.pv_ver, nav.pv_fv = l.pick, ver.layout, ver.fold
          nav.pv = nav.fold_lines(l.pick, group_lines(l.pick, {}), {})
        end
        rows = nav.pv
      end
      title = l and l.pick and text_of(l.pick.title) or ''
    else
      rows, title = ls, menu.group and text_of(menu.group.title) or 'SEARCH'
      menu.top = nav.scroll(menu.sel, menu.top, #ls, ls)
    end
    -- (the entry shown is mine, open or in the preview: my version after its title)
    local own = listing and ls[menu.sel] and ls[menu.sel].pick or (not listing and menu.group)
    local te, se, sty = nav.pane(rx, rwid, title, listing and #rows > 0 and P('RIGHT ARROW OPENS') or nil, panel, line,
      gray, own and own.mod == loader_mod, dim)
    -- (the entry's status on its title's right, before the note, in its colors; dimmer in the preview)
    if own then nav.status_bar(own.rows[1], te, se, sty, px, P, listing and dim or gray, col, listing, top + 3) end
    local inner = rwid - 12 * px
    -- The rows' width is capped (1140 px at 1080p, the same share of the screen's height at any size), so on a wide
    -- screen the values don't sit a whole screen away from their labels: the labels on the left, the values in a
    -- column at 55% of that width, left-aligned (a choice's '<' hangs left of it, so every value's text starts at the
    -- same x), cut to the room left to the capped edge (x1). A label too long for the column pushes its row's value to
    -- the pane's right edge (xr), as far as it can, so it's cut only where it was before. Every other row of options
    -- gets a faint tint, from the pane's edge to that capped edge, to follow a row across.
    local cw = min(inner, floor(1140 * s))
    local x1, xr = rx + 6 * px + cw, rx + rwid - 6 * px   -- the values' right edge; the pane's
    local aw = tw('>', px)
    local vc = rx + 6 * px + floor(cw * 0.55)  -- the value column: a choice's '<'
    local vt = vc + aw + 4 * px                -- every value's text
    local vmax = x1 - vt - 4 * px - aw         -- (room for the '>' after it)
    local tint, track = col(232, 232, 226, 8), col(44, 50, 46, 255)
    local tint_w = min(x1 + 6 * px, rx + rwid - b - floor(10 * s)) - rx - b   -- (the pane's right edge left free)
    local first = listing and 1 or menu.top
    local sh = 5 * px                          -- a separator's line: under half a row
    -- (the tint counts option rows alone, from the list's first line: it alternates across a heading, a rule or a
    -- part line, and a row keeps its tint as the list scrolls. nav.tk: the option rows above line nav.tk_f, moved
    -- along with the first line in view as the list scrolls; counted from the top again for a new list)
    if nav.tk_l ~= rows or nav.tk_n ~= #rows then nav.tk_l, nav.tk_n, nav.tk_f, nav.tk = rows, #rows, 1, 0 end
    local tf, tk = nav.tk_f, nav.tk
    while tf < first do if rows[tf] and rows[tf].row then tk = tk + 1 end; tf = tf + 1 end
    while tf > first do tf = tf - 1; if rows[tf] and rows[tf].row then tk = tk - 1 end end
    nav.tk_f, nav.tk = tf, tk
    y = py1 - rh - 4 * px - rh
    for i = first, min(#rows, first + visible - 1) do
      local l = rows[i]
      if l.sep then y = y + rh - sh end        -- (a separator's short line: the top of a row's room)
      local sel = not listing and i == menu.sel and not l.head
      if sel then nav.lit(rx, rwid, y, glow, yellow) end
      if l.row then
        tk = tk + 1
        if tk % 2 == 0 then ctx.rect(rx + b, y, tint_w, rh, tint, top + 2) end
      end
      local ty, x = midy(y, rh, px), rx + (l.indent and 18 or 6) * px   -- (a subheading's rows indented with it)
      if l.pt then
        -- (a package's INCLUDED line: its state in the value column; dimmer in the preview)
        nav.part(l.pt, x, ty, x1, vt, px, listing and dim or gray, dim, col, listing, top + 4)
      elseif l.sep then
        -- (a separator: a thin faint rule (rule) from where a row's label starts to where its value ends, mid line)
        local th = max(1, floor(px / 2))
        ctx.rect(x, y + floor((sh - th) / 2), x1 - x, th, rule, top + 4)
      elseif l.head and l.sub then
        -- (a subheading two letters in from a heading, its rows two letters in from the others)
        ctx.text(rx + 16 * px, ty, fit(P(text_of(l.text)), px, x1 - rx - 16 * px), px, subc, top + 4)
      elseif l.mt then
        -- (a mod's title in a search's results: white with its version dim after it, as in the list of mods, and a
        -- thin line under it, so it stands apart from its own headings' yellow under it; the mod's status at its right,
        -- as on its entry's title)
        local tt = fit(P(text_of(l.text)), px, x1 - rx - 4 * px)
        ctx.text(rx + 4 * px, ty, tt, px, white, top + 4)
        local ve = nav.ver_mod(l.mt, rx + 4 * px, ty, tt, x1 - rx - 4 * px, px, dim, top + 4)
        nav.status_bar(l.mt.rows[1], ve or rx + 4 * px + tw(tt, px), x1, ty, px, P, gray, col, false, top + 4)
        nav.divider(rx + 4 * px, y, x1 - rx - 4 * px)
      elseif l.head then
        ctx.text(rx + 4 * px, ty, fit(P(text_of(l.text)), px, x1 - rx - 4 * px), px, yellow, top + 4)
      elseif l.fold then
        -- (a fold: a heading, its count of rows dim after it while it's closed, + (closed) or - (open) in the value
        -- column, or after a long heading)
        local mk, hx = l.open and '-' or '+', rx + 4 * px
        local mw = tw(mk, px)
        local cw = l.open and 0 or tw(l.ct, px) + 4 * px
        local ht = fit(P(text_of(l.text)), px, x1 - hx - mw - 8 * px - cw)
        local hw = tw(ht, px)
        ctx.text(hx, ty, ht, px, yellow, top + 4)
        if not l.open then
          if ctx.tr_keep then ctx.tr_keep(l.ct) end
          ctx.text(hx + hw + 4 * px, ty, l.ct, px, listing and dim or gray, top + 4)
        end
        ctx.text(max(vc, hx + hw + cw + 8 * px), ty, mk, px, yellow, top + 4)
        if not listing then nav.hit(rx, y, rwid, rh, 'line', i) end
      elseif l.back then
        ctx.text(x, ty, fit(P(l.text), px, x1 - x), px, yellow, top + 4)
        nav.hit(rx, y, rwid, rh, 'line', i)
      else
        local r = l.row
        local sp = r.spec
        local v = fit(P(value_text(r, users)), px, vmax)
        local vw = tw(v, px)
        local live = not listing
        local lcol = live and white or dim
        local vcol = not live and dim or ((sp.type == 'toggle' and not r.value) and gray or (menu.capture == r and yellow or green))
        if live then nav.hit(rx, y, rwid, rh, 'line', i) end
        local lab = P(text_of(sp.label or r.id))
        local long = x + tw(lab, px) + 8 * px      -- (where a whole label would let its value start)
        if sp.type == 'choice' or sp.type == 'slider' or sp.type == 'color' then
          -- < value >, each arrow a box of its own for the mouse; a slider's short bar left of them takes a click or a
          -- drag; a color's swatch left of them
          local sw = floor(120 * s)
          local left = vc - (sp.type == 'slider' and 6 * px + sw or (sp.type == 'color' and rh or 0))
          local dx = long > left and max(0, xr - (vt + vw + 4 * px + aw)) or 0
          local bx = vc + dx
          local ax = vt + dx + vw + 4 * px
          ctx.text(bx, ty, '<', px, sel and yellow or gray, top + 4)
          ctx.text(vt + dx, ty, v, px, vcol, top + 4)
          ctx.text(ax, ty, '>', px, sel and yellow or gray, top + 4)
          if live then
            nav.hit(bx - 2 * px, y, aw + 4 * px, rh, 'dec', i)
            nav.hit(ax - 2 * px, y, aw + 4 * px, rh, 'inc', i)
          end
          if sp.type == 'color' then
            local sz = rh - 4 * px
            bx = bx - sz - 4 * px                    -- (the label ends before the swatch)
            swatch(r, bx + 2 * px, y + 2 * px, sz, top + 5, live and 255 or 90)
          end
          if sp.type == 'slider' then
            -- (a track 120 px long at 1080p, mid row, filled to the value, a square knob on the value; the mouse's box
            -- is the track's x and width exactly, the row's height)
            local th = max(2, floor(2.5 * s + 0.5))
            local sx, ty2 = bx - 6 * px - sw, y + floor((rh - th) / 2)
            local f = max(0, min(1, (r.value - sp.min) / (sp.max - sp.min)))
            local fw = floor(sw * f + 0.5)
            local fc = not live and gray or (sel and yellow or green)
            local kw = max(th + 4, floor(8 * s))
            ctx.rect(sx, ty2, sw, th, live and rule or track, top + 4)
            if fw > 0 then ctx.rect(sx, ty2, fw, th, fc, top + 5) end
            ctx.rect(sx + fw - floor(kw / 2), y + floor((rh - kw) / 2), kw, kw, fc, top + 6)
            if live then nav.hit(sx, y, sw, rh, 'bar', i) end
            bx = sx                                  -- (the label ends before the bar)
          end
          ctx.text(x, ty, fit(lab, px, bx - 8 * px - x), px, lcol, top + 4)
        else
          -- (a reset button asking: SURE? in orange with its seconds left after it, an orange edge on its row)
          local arm = live and r.armed and ctx.now() < r.armed
          local cd = arm and nav.sure(r)
          local cdw = cd and tw(cd, px) + 4 * px or 0
          local vx = long > vc and max(vt, xr - vw - cdw) or vt
          ctx.text(x, ty, fit(lab, px, vx - 8 * px - x), px, lcol, top + 4)
          -- (a mod's switch: its version after its name, dimmer, as mine is in the list of mods; on the lit row in the
          -- lighter hint gray, where the dim would sink into the glow)
          if r.switch then
            nav.ver_row(r, x, ty, lab, vx - 8 * px - x, px, sel and nav.pc('hint', col) or dim, top + 4)
          end
          if sp.type == 'key' and menu.capture ~= r then
            -- a key: a light chip with the key's name in ink
            ctx.rect(vx - 2 * px, y + 2 * px, vw + 4 * px, rh - 4 * px, live and white or dim, top + 4)
            ctx.text(vx, ty, v, px, ink, top + 5)
          else
            ctx.text(vx, ty, v, px, arm and orange or vcol, top + 4)
          end
          if arm then
            ctx.text(vx + vw + 4 * px, ty, cd, px, orange, top + 4)
            ctx.rect(rx + b, y, 2 * px, rh, orange, top + 5)
          end
        end
      end
      y = y - rh
    end
    -- (more lines than room: a scroll track on the pane's right edge)
    if #rows > visible or first > 1 then
      nav.sbar(rx + rwid - b - px, py1 - rh - 4 * px, py1 - rh - 4 * px - visible * rh, first, visible, #rows, px, top + 5, rule, col(255, 231, 16, 150))
    end
    -- the hints: for what was used last, the keyboard, the mouse or the controller (its buttons as pictures)
    ctx.rect(0, fh, w, b, line, top + 1)
    local dev = menu.dev
    if dev == 'pad' and (not nav.pad or menu.capture or menu.typing) then dev = 'keys' end
    if dev == 'mouse' and not nav.mouse then dev = 'keys' end
    local close_key = svc.util and svc.util.key_label(menu_key.value) or menu_key.value
    -- (a key bound more than once: the hint line says what else uses it, whatever was used last)
    local clash = not menu.typing and clash_hint(ls[menu.sel], key_users())
    -- (it, or the selected row's hint, on a line of its own just over the key hints, a size smaller and dim: the
    -- strip has that room under its rule; the key hints stay)
    local note = clash and clash_drawn(clash, P) or (not menu.capture and not menu.typing and row_hint(ls[menu.sel]))
    if note then
      -- (as drawn, kept on nav.nf: made again only when the note, its size, its room, the font or the language change)
      local npx, nf, lv = max(2, px - 1), nav.nf, ctx.lang_v and ctx.lang_v() or 0
      if nf.s ~= note or nf.px ~= npx or nf.w ~= w - 2 * m or nf.P ~= P or nf.lv ~= lv then
        nf.s, nf.px, nf.w, nf.P, nf.lv, nf.t = note, npx, w - 2 * m, P, lv, fit(P(note), npx, w - 2 * m)
      end
      ctx.text(m, hy + rh, nf.t, npx, clash and yellow or nav.pc('hint', col), top + 2)
    end
    if dev == 'pad' then nav.pad_hints(m, w - m, hy, rh, px, P, col, white, top + 2)
    else
      local segs = menu.capture and (menu.capture.spec.menu and HINTS.capture_default or HINTS.capture_none)
        or (menu.typing and HINTS.typing) or (dev == 'mouse' and HINTS.mouse)
        or ((menu.group or menu.search ~= '') and nav.entry_hints(ls[menu.sel])) or HINTS.list
      hint_line(ctx, m, hy, rh, px, w - m, segs, close_key, white, white, ink, top + 2, P)
    end
    nav.draw_cursor(top, h)
  end
  -- where the menu's cursor is (menu pixels, y up; nil before the mouse was read)
  function svc.menu_cursor() return nav.mx, nav.my end
  -- open now? (mods' key and mouse-button reads answer nothing while it is: sandbox.lua, runtime.lua, chef.typed,
  -- chef.bind, svc.pad_bind and the ModBindingsMenu look-alike)
  function svc.menu_open() return menu.open == true end
  -- How my menu opens, for my log: at start-up (with how to change the key without the menu) and on the status lines
  -- until it has opened once. A key the PC keeps for itself (a laptop's F row without Fn) or another app takes never
  -- reaches the game: the menu just doesn't open, and nothing else in my log would say which key I wait for.
  function svc.menu_how()
    local k = menu_key.value
    local s = svc.util and svc.util.key_label(k) or k
    if pad_row.value == 1 then s = s .. ', or the controller\'s touchpad / View held 2 s on the ship' end
    return s
  end
  function svc.menu_ever() return menu.ever == true end
  function svc.menu_key_note()
    log(fmt('options menu: %s (to change the key without the menu: close the game, then put the line "%s<Tab>%s<Tab>s<Tab><key>" in %s_settings.txt, see the README)',
      svc.menu_how(), loader_mod, menu_key.key, ctx.FILES))
  end
  -- the menu's cursor and left button, for the performance monitor to be dragged with: only on the ship, while the
  -- menu is open and has the mouse (nil otherwise)
  function svc.menu_mouse()
    if menu.open and nav.mouse and nav.mx and nav.on_ship() then return nav.mx, nav.my, nav.lmb == true end
  end
  -- the layer my full screen menu covers from, while it's open (nil while it isn't)
  function svc.covering()
    if menu.open and look_row.value == 1 and nav.on_ship() then return ctx.TOP + 950 end
  end
  local function menu_frame(fno)
    local mk = menu_key.value
    -- the controller: read only while the menu is open, or while closed when the touchpad / View held 2 s opens it
    for k in pairs(nav.act) do nav.act[k] = nil end
    local pv = pad_row.value
    local in_mission = not nav.on_ship()
    -- (a new world: nothing held from the last one carries over)
    local wk = (ctx.world.instance or 0) * 65536 + (ctx.world.id or 0)
    if wk ~= nav.wk then nav.wk = wk; if next(nav.held) then nav.held, nav.seed = {}, true end end
    -- (closed, the hold is read ten times a second: a 2 s hold needs no frame of its own, and the held time is the
    -- clock's, so it still opens within a tenth of a second of the 2 s)
    if pv ~= 3 and (menu.open or (pv == 1 and not in_mission)) then
      if menu.open then nav.pad_read(false, fno)
      elseif ctx.now() >= nav.pr_at or ctx.now() < nav.pr_at - 1 then nav.pr_at = ctx.now() + 0.1; nav.pad_read(true, fno) end
    elseif next(nav.held) then nav.held = {} end   -- (no reads: no hold kept from before, it would open the menu by itself)
    local combo = pv == 1 and not in_mission and nav.held.touch
    if not menu.open and combo and not nav.combo and ctx.now() - combo >= 2 then
      nav.combo = true
      menu.open, menu.group, menu.search, menu.sel, menu.top, menu.typing = true, nil, '', 1, 1, false
      nav.drag = nil
      nav.lmb, nav.rmb, menu.dev, nav.nhits, nav.seed = true, true, 'pad', 0, true
      menu.ever = true
      log('options menu opened (controller)')
    end
    if not combo then nav.combo = false end
    -- the mouse (only while open): the cursor, the wheel and the clicks of this frame
    nav.mouse = menu.open and nav.mouse_on()
    if nav.mouse then local w, h = ctx.screen(); nav.mouse_read(w, h) else
      nav.click, nav.rclick, nav.wheel = false, false, 0
      local H = nav.hold
      -- (a mod's hold carries on: hold_mods keeps it)
      if nav.holds.n == 0 then
        H.paused, H.other = false, nil
        if H.on then nav.hold_give() elseif H.had then nav.hold_heal() end
      end
    end
    -- the controller's back (circle/B) or a right click: one level back, at the list of mods it closes (Start isn't
    -- used: the game would open its own pause menu with it too)
    -- (a step back is still drawn this frame, so the menu never leaves a frame with nothing drawn: no flash)
    local stepped = false
    if menu.open and menu.capture == nil and not menu.typing and (nav.act.back or nav.rclick) then
      if menu.group or menu.search ~= '' then go_back(); stepped = true
      else
        menu.open = false
        if menu.ask then reset_ask(menu.ask, false) end
        return
      end
    end
    if not stepped and menu.open and menu.capture == nil and not menu.typing and pressed('backspace')
       and (menu.group or menu.search ~= '') then
      -- Backspace steps back too: from a mod's options (or a kept search) to the list of mods, where the cursor was
      go_back(); stepped = true
    end
    -- (while a search is typed, a menu key that types what the search takes, a letter, a digit or a space, is part of
    -- the search, not a close; F9 and the like still close it)
    if not stepped and menu.open and menu.capture == nil and ((pressed('escape') and not menu.typing)
       or (mk ~= 'off' and pressed(mk)
           and not (menu.typing and (mk:find('^%w$') or mk == 'space' or mk:find('^numpad %d$'))))) then
      menu.open, menu.typing, nav.drag = false, false, nil
      if menu.ask then reset_ask(menu.ask, false) end
      return
    end
    if not menu.open then
      if mk ~= 'off' and pressed(mk) then
        -- it always opens on the list of mods
        menu.open, menu.group, menu.search, menu.sel, menu.top = true, nil, '', 1, 1
        nav.drag = nil
        -- (a mouse button or pad button already down when it opens is no press; no old boxes)
        nav.lmb, nav.rmb, nav.nhits, nav.seed = true, true, 0, true
        menu.ever = true
        if not menu.said then menu.said = true; log('options menu opened') end
      else
        return
      end
    end
    -- the open mod stopped and its options went: back to the list
    if menu.group and #menu.group.rows == 0 then menu.group, menu.sel, menu.top = nil, 1, 1 end
    -- (a reset button that asked and wasn't pressed again in time shows as it was)
    if menu.ask and ctx.now() >= menu.ask.armed then reset_ask(menu.ask, false) end
    local typing = not stepped and menu.capture == nil and search_input()
    local ls = lines()
    if #ls == 0 and menu.search == '' then return end
    local g0, s0, f0 = menu.group, menu.search, ver.fold
    if not typing and not stepped then menu_input(ls) end
    nav.nhits = 0
    -- (the lines again when what was picked this frame opened a mod, went back or opened or closed a fold: both looks
    -- draw the new screen in this same frame, so the compact panel's size and hint line never trail it by a frame)
    if menu.group ~= g0 or menu.search ~= s0 or ver.fold ~= f0 then ls = lines() end
    -- (a color scope of its own, just before it draws: no Color a mod's callback asked for this frame, a button's or an
    -- on_change's above included; and the glyphs' colors made again, nav.glyph)
    if ctx.color_scope then ctx.color_scope() end
    nav.gcol.col = nil
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
  -- crashed an earlier launch). The box carries the inner pcall's answer out of the timed call. Each one gets a color
  -- scope of its own (util.timed's, or here for an owner that isn't a mod: the game-wide look-alike's).
  local box = {}
  local function boxed(owner, key, fn, ...) box[1], box[2] = guarded(owner, key, pcall, fn, ...) end
  local function run_as(owner, key, fn, ...)
    box[1], box[2] = nil, nil
    local a, u = recs[owner], svc.util
    if a and u then u.timed(a, boxed, owner, key, fn, ...)
    else
      if ctx.color_scope then ctx.color_scope() end
      boxed(owner, key, fn, ...)
    end
    local ok, err = box[1], box[2]
    if ok == nil then return false, err or 'skipped' end
    if not ok and a and u then u.note_error(a, err) end      -- (inside the box: timed never saw it fail)
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
                step = st, description = spec.description,
                -- (its description is the row's hint in my menu, when it's text of a size I show)
                hint = type(spec.description) == 'string' and #spec.description <= 200 and spec.description or nil }
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
  -- (once: a binding registered again after its mod was started again keeps the place its row has). A mod's first
  -- row in a heading can take that mod's switch there, or send the switches back to their own entries when the
  -- heading now holds two mods' rows (settle).
  local function place(r, home, key, title)
    if r.placed then return group_of[r.placed] end
    local g = group(key, title)
    local h = group_of[home]
    if h and h ~= g then
      for i = #h.rows, 1, -1 do if h.rows[i] == r then table.remove(h.rows, i) end end
      g.rows[#g.rows + 1] = r
      ver.layout = ver.layout + 1
      if g.reset then reset_tail(g.reset.mod) end
      local own = g.own or {}
      g.own = own
      if not own[r.owner] then
        own[r.owner], g.owners = true, (g.owners or 0) + 1
        for m in pairs(own) do settle(m) end
      end
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
  -- mouse one counts (mouse middle / extra_1 / extra_2 are "mouse 3/4/5"); press by default. Its modifiers make it a
  -- combo ({ button = 'f6', modifiers = { 'ctrl' } } is 'ctrl+f6'); one with a modifier I don't know is passed over.
  local MOUSE_NAMES = { middle = 'mouse 3', extra_1 = 'mouse 4', extra_2 = 'mouse 5' }
  local MOUSE_BUTTONS = { ['mouse 3'] = { 'middle', 'middle button' }, ['mouse 4'] = { 'extra_1', 'x button 1' },
                          ['mouse 5'] = { 'extra_2', 'x button 2' } }
  local function mbm_default(spec)
    if spec == nil then return '', 'press' end
    local list = (type(spec) == 'table' and spec.button == nil) and spec or { spec }
    for _, x in ipairs(list) do
      local button, device, trigger, front = x, 'keyboard', 'press', ''
      if type(x) == 'table' then
        if type(x.modifiers) == 'table' and x.modifiers[1] ~= nil then
          local has = {}
          for _, m in ipairs(x.modifiers) do
            local o = type(m) == 'string' and MOD_OF[m:lower()]
            if o then has[o] = true else button = nil end
          end
          for _, m in ipairs(MODS) do if has[m] then front = front .. m .. '+' end end
        end
        button, device, trigger = button and x.button, x.device or 'keyboard', x.trigger or 'press'
      end
      if type(button) == 'string' and (trigger == 'press' or trigger == 'release' or trigger == 'hold') then
        button = button:lower()
        if device == 'mouse' then button = MOUSE_NAMES[button] elseif device ~= 'keyboard' then button = nil end
        if button then return front .. button, trigger end
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
  -- (a combo: its key went down / is held, and each modifier is held on either side; b.pv, b.pp: the value last read
  -- and its parts)
  local function key_state(owner, b, how)
    local name = b.row.value
    if name == 'off' then return false end
    if b.pv ~= name then b.pv, b.pp = name, key_parts(name) end
    local p = b.pp
    if p then
      if p.pad then return false end
      name = p.key
    end
    local k = key_ref(owner, name)
    if not k then return false end
    local v = guarded(owner, k[how], fn_of(k[how]), k[1])
    if not (v == true or (type(v) == 'number' and v > 0.5)) then return false end
    if p then
      for i = 1, #p.mods do
        local held = false
        for _, side in ipairs(MOD_KEYS[p.mods[i]]) do
          local m = key_ref(owner, side)
          local s = m and guarded(owner, m[3], fn_of(m[3]), m[1])
          if s == true or (type(s) == 'number' and s > 0.5) then held = true; break end
        end
        if not held then return false end
      end
    end
    return true
  end
  -- Controller bindings (chef.bind's 'pad:cross'): the button by the name the pad found gives it, or the same button
  -- under the other family's name ('pad:a' is cross on a DualSense, by my menu's PAD_NAMES). Each one's button is
  -- read once a frame, and only while a mod has asked about it in the last 30 frames (nav.binds): the mod's first ask
  -- in a frame reads it, and svc.frame reads the ones not asked that frame, so p.prev / p.now always give the frame it
  -- went down. Never while my menu is open (the controller is the menu's then): false, nothing read. No pad found
  -- yet: looked for every 5 s (my menu is closed then), as my menu does (nav.pad_find).
  function nav.pad_ix(name)
    local by = nav.by
    if by[name] then return by[name] end
    for _, a in ipairs(PAD_ORDER) do
      local list = PAD_NAMES[a]
      for _, c in ipairs(list) do
        if c == name then for _, o in ipairs(list) do if by[o] then return by[o] end end end
      end
    end
    return false
  end
  function nav.pad_sample(p, fno)
    -- (the pad still there: asked once a frame for every binding and my menu's read together, nav.pf the frame asked)
    if nav.pad and nav.pf ~= fno then nav.pf = fno; nav.pad_live() end
    if not nav.pad then nav.pad_find() end
    local d = false
    if nav.pad then
      if p.by ~= nav.by then p.by, p.ix = nav.by, nav.pad_ix(p.pad) end
      if p.ix then
        local v = eng(nav.calls.button, p.ix)
        d = v == true or (type(v) == 'number' and v > 0.5)
      end
    end
    -- (sampling that starts again begins from what the button is now: no press out of a stale sample)
    if p.at == fno - 1 then p.prev = p.now else p.prev = d end
    p.now, p.at = d, fno
  end
  function svc.pad_bind(p, edge)
    if menu.open then return false end
    local fno = shim.frame
    if p.asked == nil then nav.binds[#nav.binds + 1] = p end
    p.asked = fno
    if p.at ~= fno then nav.pad_sample(p, fno) end
    if edge then return p.now and not p.prev end
    return p.now
  end
  local function mbm_is_down(owner, id)
    local b = shim.keys[id]
    if b == nil then return nil end
    if b.row.value == 'off' then return false end
    if menu.open then return false end                       -- my menu has the keys while it's open
    if b.trigger == 'press' then return key_state(owner, b, 2) end
    if b.trigger == 'hold' then return key_state(owner, b, 3) end
    -- release: down last frame, up this one (sampled in svc.frame while some mod keeps asking; a sample older than my
    -- last frame, kept from before my menu opened or before the mod stopped asking, gives no release)
    b.asked = shim.frame
    return b.at == shim.frame and b.prev == true and not b.now
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
      local r, err = add_row(owner, 'ModBindingsMenu', 'KEYS', id, { type = 'key', default = name ~= '' and name or 'off', label = text,
        combos = true })
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
      local p = key_parts(name)
      if p and p.pad then return {} end
      if p then name = p.key end
      local button = name
      for m, n in pairs(MOUSE_NAMES) do if n == name then button = m end end
      local mods = {}
      if p then for i = 1, #p.mods do mods[i] = p.mods[i] end end
      return { { MOUSE_BUTTONS[name] and 'mouse' or 'keyboard', button, modifiers = mods, trigger = b.trigger } }
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

  -- ---------------------------------------------------------------- the mouse for mods
  -- chef.hold_mouse(true): the mouse held from the game's camera (the delta axis dead-zoned, as my menu does) until the
  -- mod lets go, stops (svc.forget) or the game closes; what the axis had is put back once no mod and not my menu holds
  -- it. A dead zone another mod set itself (far up, not mine) is left alone, and asked again once a second. It needs
  -- only the delta axis: with no cursor axis it holds all the same, and svc.mouse_delta reads 0, 0 while it's held.
  -- False and a reason when the mouse has no delta axis yet (find_axes asks again every 2 s, so the mod can ask again
  -- later) or the game gave no dead zone for it this session.
  function svc.hold_mouse(owner, on)
    local S = nav.holds
    if on then
      if nav.hold.off then return false, 'the mouse can\'t be held: the game gave no dead zone for it' end
      if not nav.find_axes().move then return false, 'the mouse can\'t be held: the game gave no mouse axis' end
      if not S.by[owner] then S.by[owner], S.n = true, S.n + 1 end
      nav.hold_mods()
      -- (this first take found no dead zone: never held, so the mod is told at once)
      if nav.hold.off then
        S.by[owner], S.n = nil, S.n - 1
        return false, 'the mouse can\'t be held: the game gave no dead zone for it'
      end
      return true
    end
    if S.by[owner] then
      S.by[owner], S.n = nil, S.n - 1
      if S.n == 0 and not nav.mouse then nav.hold_give() end
    end
    return true
  end
  -- each frame while a mod holds the mouse and my menu doesn't have it: held again if it isn't (my menu's pause, a
  -- lost cursor, ends with the menu)
  function nav.hold_mods()
    if nav.holds.n == 0 or nav.mouse then return end
    nav.hold.paused = false
    nav.find_axes()
    nav.hold_take()
  end
  function svc.mouse_held() local H = nav.hold; return H.on or H.other ~= nil end
  -- This frame's mouse movement for a mod, x right and y down like the engine's delta axis: that axis itself while
  -- nothing holds the mouse. While it's held the axis reads nothing, so it's the cursor axis's movement then, scaled to
  -- about the same size (my menu takes a delta of 1 as h / 1080 px) and through my menu's filter (a frame that lands
  -- in the window's middle, where the game puts its hidden cursor back, or jumps a third of it moves nothing). 0, 0
  -- while my menu has the mouse, and while it's held on a mouse with no cursor axis. Read once a frame, whichever mod
  -- asks first: by the loader's frame number (ctx.frame), which goes up before the mods' update hooks run, so a mod's
  -- update reads this frame's movement (shim.frame goes up after them, in svc.frame; it's what a host without one has)
  nav.delta = { frame = -1, x = 0, y = 0 }
  function svc.mouse_delta()
    local D, f = nav.delta, ctx.frame and ctx.frame() or shim.frame
    if D.frame == f then return D.x, D.y end
    local gap = f - D.frame
    D.frame, D.x, D.y = f, 0, 0
    if nav.mouse then D.px = nil; return 0, 0 end
    local A = nav.find_axes()
    if not A.move then return 0, 0 end
    local H = nav.hold
    if not (H.on or H.other) then
      D.px = nil
      local v = eng('Mouse.axis', A.move)
      if v == nil then return 0, 0 end
      local x, y = eng('Vector3.to_elements', v)
      D.x, D.y = tonumber(x) or 0, tonumber(y) or 0
      return D.x, D.y
    end
    if not A.cursor then return 0, 0 end
    local w, h = ctx.screen()
    local cx, cy = nav.cursor_at(w, h)
    if not cx then D.px = nil; return 0, 0 end
    local px, py = D.px, D.py
    D.px, D.py = cx, cy
    -- (no sample from the frame before: this one starts the count)
    if not px or gap > 1 then return 0, 0 end
    local dx, dy = cx - px, cy - py
    local mid = cx - w / 2 <= 3 and w / 2 - cx <= 3 and cy - h / 2 <= 3 and h / 2 - cy <= 3
    local jump = dx > w / 3 or -dx > w / 3 or dy > h / 3 or -dy > h / 3
    if mid or jump then return 0, 0 end
    local k = 1080 / h
    D.x, D.y = dx * k, -dy * k                         -- (the cursor counts y up; the delta counts it down)
    return D.x, D.y
  end

  -- A mod that stopped (switched off after errors, failed to start, or about to be started again in dev mode): its menu
  -- rows keep their values but drop its change callbacks, its event subscriptions and waiting after_startup callbacks
  -- end, the utilities drop its timers, jobs and what it spawned, the HD2Runtime look-alike undoes what it made, and
  -- its look-alike hooks (on_update, on_shutdown, guards) end.
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
    svc.hold_mouse(owner, false)               -- (its hold of the mouse ends: the camera never stays frozen)
  end

  -- ---------------------------------------------------------------- the loader's hooks
  local last_world, last_mission = nil, false
  local seen = { at = 0 }                   -- the players event's last look: n players, j joining, the next look at
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
    -- (the controller bindings first, for the frame the mods just had: the ones asked lately but not this frame are
    -- read now; the rest leave the list, so with none asked about nothing runs here)
    if nav.binds[1] then
      local l, f, keep = nav.binds, shim.frame, 0
      for i = 1, #l do
        local p = l[i]
        if f - p.asked <= 30 then
          keep = keep + 1; l[keep] = p
          if p.at ~= f and not menu.open then nav.pad_sample(p, f) end
        else p.asked = nil end
      end
      for i = #l, keep + 1, -1 do l[i] = nil end
    end
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
    -- players: the session's player count and how many are still joining, looked at once a second, only while a mod
    -- listens (the first look only notes them: a change since then is the event)
    if subs.players and svc.util then
      if ctx.now() >= seen.at then
        seen.at = ctx.now() + 1
        local s = svc.util.session_now()
        local n, j = s.on and max(1, s.peers) or 1, s.on and s.joining or 0
        local was = seen.n
        if was and (n ~= was or j ~= seen.j) then seen.n, seen.j = n, j; emit('players', n, j, was)
        else seen.n, seen.j = n, j end
      end
    elseif seen.n then seen.n, seen.j, seen.at = nil, nil, 0 end
    if nav.holds.n > 0 then nav.hold_mods() end
    if dirty and ctx.now() >= save_at then save_at = ctx.now() + 3; save_now() end
    if dev.on and reload_key and pressed(reload_key) then
      log('dev mode: reloading')
      ctx.dev_reload(svc.dev_files())
    end
    -- (the look-alike hooks, guards and events above each ran in a color scope of their own; my menu gets one too,
    -- only in a frame it draws: menu_frame)
    menu_frame(fno)
    -- the 'menu' event (true: it opened, false: it closed), so a mod can hide its HUD while my menu is up
    if menu.open ~= (menu.told == true) then menu.told = menu.open; emit('menu', menu.open == true) end
  end
  function svc.shutdown()
    nav.holds.by, nav.holds.n = {}, 0      -- (the mouse back to the game first, mods' holds too: nothing below may keep it)
    pcall(nav.hold_give)
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