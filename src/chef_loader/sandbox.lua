-- Chef Shared Loader: the locked-down space every loader mod runs in
-- Every "-- HD2-Addon:" and "-- HD2-Boot:" mod gets an environment of its own built here. What it can't do from it:
--   * start programs, delete or rename files, quit the game through Lua (os.execute, io.popen, os.remove/rename/exit)
--   * load native code (package.loadlib, C modules through require) or compiled Lua (bytecode can be made to read and
--     write any memory, so loadstring and load take text only)
--   * reach past its own space: no debug library beyond traceback and getinfo, getfenv/setfenv only on its own
--     functions, _G is its own environment, no require of the game's modules (require('_G') would hand out everything),
--     no module() (package.seeall), and the metatables of its environment are locked
--   * open files outside a short list: it reads the game's settings folder, the game's data folder and its own files,
--     and writes only .log .txt .json .csv .dat files in the loader's folder, never the loader's own files or another
--     mod's saved tables
-- It still can use: everything the engine's script API offers (stingray, Unit, World ...), the chef helpers,
-- os.clock/time/date/getenv, reading and writing its own files.
-- Each mod gets its own copies of string, table, math, coroutine, bit, os and debug, so one mod changing a library
-- function changes it only for itself. The checks below use functions taken before any mod runs, so no mod can bend
-- them.
-- Engine tables that aren't for mods are out of its view too (stingray and the globals alike): native code
-- (PluginManager), other network routes (Http, WebSocket), the Localizer (it ends the game), the lobby (joining one and
-- writing what other players read: every *Lobby* table and Network's lobby calls) and GameSession's writes.
-- A mod the loader trusts by name (loader.lua, TRUSTED) can get more through sb.grant: files of its own in
-- %LOCALAPPDATA%, and game patch files in data\ (with the player's yes) that are checked before they take a patch's
-- name, so they never carry code. The lobby, for those mods, goes through the HD2Runtime look-alike (runtime.lua).
-- A mod that replaces the game's boot script itself isn't a loader mod: the game hands it everything, with or without
-- me. Those run unrestricted (see loader.lua, "other mods' boot scripts").
-- Plain Lua 5.1 (no goto, no bit ops), like the rest of the loader.

local M = { version = '1.1.0' }

local type, pairs, ipairs, error, tostring, select, rawget, pcall = type, pairs, ipairs, error, tostring, select, rawget, pcall
local rawset, newproxy = rawset, newproxy
local collectgarbage = collectgarbage
local setmetatable, getmetatable = setmetatable, getmetatable
local s_find, s_match, s_gsub, s_sub, s_lower, s_byte, s_gmatch, s_rep = string.find, string.match, string.gsub,
  string.sub, string.lower, string.byte, string.gmatch, string.rep
local s_format = string.format
local t_concat = table.concat
local real_loadstring, real_setfenv, real_getfenv = loadstring, setfenv, getfenv

-- the file kinds a mod may write, and the Windows device names no file may be called
local MOD_EXT = { log = true, txt = true, json = true, csv = true, dat = true }
local DEVICES = { con = true, prn = true, aux = true, nul = true, ['conin$'] = true, ['conout$'] = true, ['clock$'] = true }
for n = 1, 9 do DEVICES['com' .. n] = true; DEVICES['lpt' .. n] = true end
local LIBS = { 'string', 'table', 'math', 'coroutine', 'bit' }
local OS_KEEP = { 'clock', 'time', 'date', 'difftime', 'getenv' }
local REQUIRE_OK = { bit = 'bit', string = 'string', table = 'table', math = 'math', coroutine = 'coroutine' }
-- engine tables that aren't for mods (M.engine_off), and calls left out of engine tables mods otherwise keep
-- (M.CALLS_OFF): Network and GameSession keep only their reads (no lobby, connection or writes to what other players
-- see). (utilities.lua refuses the same through chef.call.)
function M.engine_off(k)
  return k == 'PluginManager' or k == 'Http' or k == 'WebSocket' or k == 'Localizer' or s_find(k, 'Lobby', 1, true) ~= nil
    or s_find(k, 'GameServer', 1, true) ~= nil
end
M.CALLS_OFF = {
  -- Network keeps only what reads like a read (peer_id, game_session, is_ / has_ / get_ / num_ ...), and never a name
  -- that mentions the lobby or a connection: a new call in a game update is left out until it's known to be a read
  Network = function(f)
    f = s_lower(f)
    local read = f == 'peer_id' or f == 'game_session' or s_match(f, '^is_') or s_match(f, '^has_') or s_match(f, '^get_')
      or s_match(f, '^num_')
    if not read then return true end
    return (s_find(f, 'lobby', 1, true) or s_find(f, 'server', 1, true) or s_find(f, 'join', 1, true)
      or s_find(f, 'connect', 1, true) or s_find(f, 'create', 1, true) or s_find(f, 'leave', 1, true)
      or s_find(f, 'send', 1, true) or s_find(f, 'dump', 1, true)) ~= nil
  end,
  -- GameSession the same way: its reads stay (in_session, peers, game_session_host, game_object_field / _exists /
  -- _owner, is_ / has_ / get_ / num_), every write to what other players see is left out, and so is a call a game update adds
  GameSession = function(f)
    f = s_lower(f)
    local read = f == 'in_session' or f == 'peers' or f == 'game_session_host' or f == 'game_object_field'
      or f == 'game_object_exists' or f == 'game_object_owner'
      or s_match(f, '^is_') or s_match(f, '^has_') or s_match(f, '^get_') or s_match(f, '^num_')
    if not read then return true end
    return (s_find(f, 'send', 1, true) or s_find(f, 'set', 1, true) or s_find(f, 'create', 1, true)
      or s_find(f, 'destroy', 1, true) or s_find(f, 'migrate', 1, true)) ~= nil
  end,
}

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- The part of a path after one of my roots, one name at a time. Refused: "..", empty names, names Windows treats as
-- another file (a trailing dot or space is dropped by Windows, "~" makes 8.3 short names like CHEF_L~1.LOG, ":" opens
-- an alternate data stream), wildcards and control characters, and device names.
local function names_of(rest)
  local names = {}
  if s_find(rest, ':', 1, true) then return nil, 'a ":" in a file name is off limits' end
  for name in s_gmatch(rest, '[^\\]+') do
    if name == '..' then return nil, '".." is off limits' end
    if name ~= '.' then
      if s_find(name, '[<>"|%?%*~%c]') then return nil, 'that file name is off limits' end
      if s_find(name, '[%. ]$') then return nil, 'a name ending in a dot or a space is off limits' end
      if DEVICES[s_match(name, '^([^%.]*)')] then return nil, 'device names are off limits' end
      names[#names + 1] = name
    end
  end
  if #names == 0 then return nil, 'not a file' end
  return names
end

-- ctx: G, io, os, debug, log, DIR (the loader's folder, with a trailing \), GAME_DIR (the game's settings folder,
-- %APPDATA%\Arrowhead\Helldivers2\, or nil), OLD_DIR (%LOCALAPPDATA%\, my files' old folder, or nil),
-- FILES ('chef_loader'), LOADER (its name, for messages), overrides (compat's xpcall and load)
function M.install(ctx)
  local G, io_, os_, dbg = ctx.G, ctx.io, ctx.os, ctx.debug
  local real_open = type(io_) == 'table' and io_.open or nil
  local io_type = type(io_) == 'table' and io_.type or function() return nil end
  local overrides = ctx.overrides or {}
  local sb = { denied = 0 }
  local envs = setmetatable({}, { __mode = 'k' })        -- every mod environment I made -> its mod's name
  local full = setmetatable({}, { __mode = 'k' })        -- environments with the game's whole Lua (other boot scripts)

  -- The file handles' methods are one table every handle shares (f.__index hands it out), so a mod could replace
  -- f.write and have my own writes (the crash state, the trace, the settings) run its function. The handles get a
  -- locked copy instead, taken before any mod runs: f:write, f:lines and io.type work as usual, and f.__index is
  -- nil. Done on the first handle I see (io.stdout, else the first file a mod opens).
  local files_locked = false
  local function lock_files(f)
    if files_locked or f == nil then return end
    local mt = getmetatable(f)
    if type(mt) ~= 'table' or type(rawget(mt, '__index')) ~= 'table' then return end
    -- already locked (a second install in the same Lua state): the methods sit behind the proxy, not in it
    if getmetatable(rawget(mt, '__index')) == 'locked' then files_locked = true; return end
    local methods = {}
    for k, v in pairs(rawget(mt, '__index')) do
      if type(k) ~= 'string' or s_sub(k, 1, 2) ~= '__' then methods[k] = v end
    end
    mt.__index = setmetatable({}, { __index = methods, __metatable = 'locked',
      __newindex = function() error('the file methods are off limits to Chef Shared Loader mods', 2) end })
    files_locked = true
  end
  if type(io_) == 'table' then pcall(lock_files, rawget(io_, 'stdout') or rawget(io_, 'stderr')) end

  local function low(p) return s_lower((s_gsub(p, '/', '\\'))) end
  local WDIR = ctx.DIR and ctx.DIR ~= '' and low(ctx.DIR) or nil
  local GDIR = ctx.GAME_DIR and low(ctx.GAME_DIR) or nil
  local ODIR = ctx.OLD_DIR and low(ctx.OLD_DIR) or nil
  local LDIR = ODIR                     -- %LOCALAPPDATA%\, for a trusted mod's own files (even when it's my folder too)
  if ODIR == WDIR then ODIR = nil end
  local OWN = s_lower(ctx.FILES or 'chef_loader')

  -- for the log: the player's folders as %APPDATA% / %LOCALAPPDATA%, so a log someone attaches to a bug report
  -- doesn't carry their user name
  local shown = {}
  do
    local ok, a = pcall(os_.getenv, 'APPDATA')
    if ok and type(a) == 'string' and a ~= '' then shown[#shown + 1] = { low(a), '%APPDATA%' } end
    local okl, l = pcall(os_.getenv, 'LOCALAPPDATA')
    if okl and type(l) == 'string' and l ~= '' then shown[#shown + 1] = { low(l), '%LOCALAPPDATA%' } end
  end
  local function show(path)
    if type(path) ~= 'string' then return tostring(path) end
    local p = low(path)
    for _, s in ipairs(shown) do
      if s_sub(p, 1, #s[1]) == s[1] then return s[2] .. s_sub(path, #s[1] + 1) end
    end
    if s_match(p, '^%a:\\users\\') then return '<user folder>' .. s_gsub(s_sub(path, 10), '^[^\\/]*', '') end
    return path
  end
  sb.show = show

  -- May a mod open this path in this mode? Returns true, or nil and why.
  function sb.check(path, mode)
    if mode == nil then mode = 'r' end
    if type(path) ~= 'string' or path == '' or #path > 400 or s_find(path, '%z') then return nil, 'not a file path' end
    if type(mode) ~= 'string' or not (s_match(mode, '^[rwa]%+?b?$') or s_match(mode, '^[rwa]b%+$')) then
      return nil, 'not a file mode'
    end
    local p = low(path)
    if s_sub(p, 1, 2) == '\\\\' then return nil, 'network and device paths are off limits' end
    local writes = s_find(mode, '[wa%+]') ~= nil
    -- which root: the loader's folder, the game's settings folder, my old folder, the game's data folder
    local root, rest
    for _, r in ipairs({ WDIR or false, GDIR or false, ODIR or false, 'data\\' }) do
      if r and s_sub(p, 1, #r) == r and #p > #r then root, rest = r, s_sub(p, #r + 1); break end
    end
    if not root then
      return nil, writes and 'mods write only in the loader\'s folder'
        or 'mods read only the game\'s settings and data folders and the loader\'s folder'
    end
    local names, why = names_of(rest)
    if not names then return nil, why end
    local file = names[#names]
    local ext = s_match(file, '%.(%w+)$')
    if root == ODIR and not (#names == 1 and ext and MOD_EXT[ext]) then
      return nil, 'from the old %LOCALAPPDATA% folder mods read only their own .log .txt .json .csv .dat files'
    end
    if not writes then return true, root, names, ext end
    if root ~= WDIR then return nil, 'mods write only in the loader\'s folder' end
    if #names ~= 1 then return nil, 'mods write only straight into the loader\'s folder, not below it' end
    if not (ext and MOD_EXT[ext]) then return nil, 'mods write only .log .txt .json .csv .dat files' end
    if not s_match(file, '^[%w_%-%.]+$') then return nil, 'file names are letters, digits, _ - and .' end
    if s_sub(file, 1, #OWN) == OWN or s_sub(file, 1, 11) == 'chef_loader' or s_sub(file, 1, 10) == 'chef_data_' then
      return nil, 'the loader\'s own files and saved tables are off limits (chef.save_table saves a table)'
    end
    return true, root, names, ext
  end

  local function blocked(name, instead)
    return function() error(name .. ' is off limits to Chef Shared Loader mods' .. (instead or ''), 2) end
  end

  -- what every environment falls back on: the few names I take away or replace, then the game's globals
  local base = {
    dofile = blocked('dofile'), loadfile = blocked('loadfile'), module = blocked('module'),
    collectgarbage = function(opt, arg)
      if opt == nil or opt == 'collect' or opt == 'count' or opt == 'step' then return collectgarbage(opt, arg) end
      return 0
    end,
  }
  local string_mt = getmetatable('')
  -- the engine as mods see it: stingray and the globals without the tables (and calls) that aren't for them. A table
  -- left out reads as false in a mod's globals (nil would fall through to the game's).
  local engine_off = M.engine_off
  local function trimmed(k, t)
    local off = M.CALLS_OFF[k]
    if not off or type(t) ~= 'table' then return t end
    local c = {}
    for f, fn in pairs(t) do if type(f) ~= 'string' or not off(f) then c[f] = fn end end
    return c
  end
  local S = rawget(G, 'stingray')
  if type(S) == 'table' then
    local view = {}
    for k, v in pairs(S) do
      if not (type(k) == 'string' and engine_off(k)) then view[k] = type(k) == 'string' and trimmed(k, v) or v end
    end
    base.stingray = view
  end
  for k, v in pairs(G) do
    if type(k) == 'string' and s_match(k, '^%u') then
      if engine_off(k) then base[k] = false
      elseif M.CALLS_OFF[k] then base[k] = (type(S) == 'table' and S[k] == v and base.stingray[k]) or trimmed(k, v) end
    end
  end
  setmetatable(base, { __index = G, __metatable = 'locked' })
  -- an engine object's metatable whose __index is one of those tables: a mod gets the table as it sees it
  -- (trimmed, or nothing), so the calls left out aren't a method call away
  local as_seen = {}
  for k, v in pairs(G) do
    if type(k) == 'string' and type(v) == 'table' and s_match(k, '^%u') and (engine_off(k) or M.CALLS_OFF[k]) then
      as_seen[v] = base[k]
    end
  end
  if type(S) == 'table' then
    for k, v in pairs(S) do
      if type(k) == 'string' and type(v) == 'table' and (engine_off(k) or M.CALLS_OFF[k]) then
        as_seen[v] = base.stingray[k] or false
      end
    end
  end
  -- the engine's names as each mod's environment holds them as its own keys: stingray and every capitalized global,
  -- as the mod sees it (trimmed, or false when off). Mods written for the old loaders find the engine with
  -- rawget(_G, 'stingray') and the like, which never reaches __index. (Game names are never shared by on_global.)
  -- Taken once, here: a later change to a game global (a full-access boot script's) doesn't reach mods.
  local engine_names = {}
  for k in pairs(G) do
    if type(k) == 'string' and s_match(k, '^%u') then engine_names[k] = base[k] end
  end
  if base.stingray ~= nil then engine_names.stingray = base.stingray end
  -- sb.on_global(env, key, value): told of each new global a mod sets (the runtime look-alike shares some between its
  -- mods); the assignment itself always happens first
  local env_mt = { __index = base, __metatable = 'locked', __newindex = function(t, k, v)
    rawset(t, k, v)
    local f = sb.on_global
    if f then pcall(f, t, k, v) end
  end }

  -- ---------------------------------------------------------------- what a trusted mod gets beyond that
  -- grants[owner] = { files = { { dir, name } ... } (its own files in %LOCALAPPDATA%: below dir, names starting with
  -- name; both lower case), patches = { scratch = file name prefix, marker = text, consent = fn() -> true when the
  -- player said yes, asked = fn(why) } }. Set before the mod's environment is made (its os gets remove and rename).
  local grants = {}
  function sb.grant(owner, g) if type(owner) == 'string' and type(g) == 'table' then grants[owner] = g end end
  local function own_file(g, p)
    if not (LDIR and g.files) or s_sub(p, 1, #LDIR) ~= LDIR then return false end
    local names = names_of(s_sub(p, #LDIR + 1))
    if not names then return false end
    local file = names[#names]
    if not s_match(file, '^[%w_%-%.]+$') then return false end
    local dir = t_concat(names, '\\', 1, #names - 1)
    for _, f in ipairs(g.files) do
      if dir == f.dir and s_sub(file, 1, #f.name) == f.name then return true end
    end
    return false
  end
  -- a file in data\ a trusted mod may write: its scratch file (any suffix), or a patch's main file or sidecar.
  -- -> 'scratch' | 'main' | 'side', and the patch number
  local SIDES = { ['.stream'] = true, ['.gpu_resources'] = true, ['.part'] = true }
  local function data_file(g, p)
    if not g.patches or s_sub(p, 1, 5) ~= 'data\\' then return nil end
    local names = names_of(s_sub(p, 6))
    if not names or #names ~= 1 then return nil end
    local file, scratch = names[1], g.patches.scratch
    if scratch and s_sub(file, 1, #scratch) == scratch and s_match(s_sub(file, #scratch + 1), '^[%w_%-%.]*$') then
      return 'scratch'
    end
    local n, suffix = s_match(file, '^9ba626afa44a3aa3%.patch_(%d+)(.*)$')
    if n and #n <= 5 then
      if suffix == '' then return 'main', n end
      if SIDES[suffix] then return 'side', n end
    end
    return nil
  end
  -- What a patch main file holds: its table of contents read, and every Lua resource in it read too. A patch passes
  -- when it doesn't replace the game's boot script and each Lua resource in it is only comment lines (so nothing in
  -- it can run; a long comment, --[[ ]], can end mid-line before code, so those are refused). -> true, has_marker
  -- (a Lua resource starting with marker) | nil, why
  local BOOT_ID, LUA_TYPE = '\250\149\024\105\147\223\118\244', '\226\023\209\044\250\141\078\161'
  local function u32(s, i) local a, b, c, d = s_byte(s, i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
  local function only_comments(text)
    for line in s_gmatch(text .. '\n', '([^\r\n]*)[\r\n]') do   -- (Lua ends a comment at \r as well as \n)
      if not s_match(line, '^%s*$') and (not s_match(line, '^%s*%-%-') or s_match(line, '^%s*%-%-%[=*%[')) then
        return false
      end
    end
    return true
  end
  local function read_patch(f, marker)
    local h = f:read(72)
    if type(h) ~= 'string' or #h < 72 or u32(h, 1) ~= 0xF0000011 then return nil, 'not a patch file' end
    local types, count = u32(h, 5), u32(h, 9)
    if types > 4096 or count > 262144 then return nil, 'not a patch file' end
    local tt = types > 0 and f:read(32 * types) or ''
    if #tt ~= 32 * types then return nil, 'a cut-off patch file' end
    -- The layout must be the one I read: the type table's counts (u64 at +16) add up to the row count and every row's
    -- type (at +8) is in it. A changed row size or field order fails this, so a patch is refused, never misread.
    local listed, sum = {}, 0
    for k = 0, types - 1 do
      listed[s_sub(tt, 32 * k + 9, 32 * k + 16)] = true
      sum = sum + u32(tt, 32 * k + 17) + u32(tt, 32 * k + 21) * 4294967296
    end
    if sum ~= count then return nil, 'a patch file layout I don\'t know' end
    local marked, base = false, 72 + 32 * types
    -- the rows a chunk at a time (a patch can have tens of thousands; one read of them all would be megabytes)
    for first = 0, count - 1, 4096 do
      local n = count - first
      if n > 4096 then n = 4096 end
      if not f:seek('set', base + 80 * first) then return nil, 'a cut-off patch file' end
      local rows = f:read(80 * n) or ''
      if #rows ~= 80 * n then return nil, 'a cut-off patch file' end
      for i = 0, n - 1 do
        local o = i * 80
        if not listed[s_sub(rows, o + 9, o + 16)] then return nil, 'a patch file layout I don\'t know' end
        if s_sub(rows, o + 1, o + 8) == BOOT_ID then return nil, 'it would replace the game\'s boot script' end
        if s_sub(rows, o + 9, o + 16) == LUA_TYPE then
          local at = u32(rows, o + 17) + u32(rows, o + 21) * 4294967296
          -- (seek takes a 32-bit long on the game's platform: an offset past 2 GB would wrap)
          if at >= 2147483647 then return nil, 'a Lua resource past 2 GB' end
          if not f:seek('set', at) then return nil, 'a cut-off patch file' end
          local env8 = f:read(8)
          if type(env8) ~= 'string' or #env8 < 8 then return nil, 'a cut-off patch file' end
          local len = u32(env8, 1)
          if len > 65536 then return nil, 'a Lua resource too big for a note' end
          -- the row's size is what a loader reads; it must be just this text, or code could sit past the length I check
          if u32(rows, o + 57) ~= len + 8 then return nil, 'a Lua resource whose sizes disagree' end
          -- a Lua resource is all in the main file; stream or GPU data would be bytes I never read
          if u32(rows, o + 61) ~= 0 or u32(rows, o + 65) ~= 0 then return nil, 'a Lua resource with stream or GPU data' end
          local text = len > 0 and f:read(len) or ''
          if type(text) ~= 'string' or #text ~= len then return nil, 'a cut-off patch file' end
          if not only_comments(text) then return nil, 'a Lua resource with code in it' end
          if marker and s_sub(text, 1, #marker) == marker then marked = true end
        end
      end
    end
    return true, marked
  end
  local function patch_check(path, marker)
    if not real_open then return nil, 'no io' end
    local f = real_open(path, 'rb')
    if not f then return nil, 'not there' end
    local ok, a, b = pcall(read_patch, f, marker)
    pcall(f.close, f)
    if not ok then return nil, 'unreadable: ' .. tostring(a) end
    return a, b
  end
  sb.patch_check = patch_check
  -- a patch number is this mod's to write: its main file (main: its path as the mod spelled it) isn't there, or it
  -- carries the mod's marker
  -- (the answer is kept until a mod renames or removes something in data\: each sidecar open would read the whole
  -- main file again otherwise)
  local ours_cache = {}
  local function patch_ours(g, main)
    local key = low(main)
    local known = ours_cache[key]
    if known ~= nil and known.g == g then return known.v end
    local f = real_open and real_open(main, 'rb')
    if not f then return true end                  -- (not there, or not readable now: not kept, asked again)
    pcall(f.close, f)
    local ok, marked = patch_check(main, g.patches.marker)
    local v = ok == true and marked == true
    ours_cache[key] = { g = g, v = v }
    return v
  end
  -- A trusted mod's write handles on files in data\ come wrapped, so I know which are open: a file still open for
  -- writing is never renamed (to a patch's name or any other) or removed, so nothing reaches a patch after its check.
  -- The wrapper is a userdata (newproxy) whose __gc closes a handle the mod dropped; without newproxy it's a table, and
  -- a dropped one simply leaves the weak tables. Open or not is read from them, so a count can't drift.
  -- the key for a path: data\<name> as names_of reads it (data\.\x and data\\x are data\x), else the lower-case path
  local function key_of(p)
    if s_sub(p, 1, 5) == 'data\\' then
      local names = names_of(s_sub(p, 6))
      if names and #names == 1 then return 'data\\' .. names[1] end
    end
    return p
  end
  local real_of, path_of = setmetatable({}, { __mode = 'k' }), setmetatable({}, { __mode = 'k' })
  local function open_for_writing(p)
    for h, q in pairs(path_of) do if q == p and real_of[h] then return true end end
    return false
  end
  local function let_go(h)
    local f = real_of[h]
    real_of[h] = nil
    return f
  end
  -- a method's answers as the mod gets them: its handle where the file answered itself (5.2's write), all the others
  local function answers(h, f, a, ...)
    if a == f then return h, ... end
    return a, ...
  end
  local hmethods = {}
  for _, m in ipairs({ 'read', 'write', 'seek', 'flush', 'setvbuf' }) do
    hmethods[m] = function(h, ...)
      local f = real_of[h]
      if not f then return nil, 'attempt to use a closed file' end
      return answers(h, f, f[m](f, ...))
    end
  end
  -- the iterator holds the handle, so it isn't collected (and its file closed) while a loop runs
  function hmethods.lines(h, ...)
    local f = real_of[h]
    if not f then error('attempt to use a closed file', 2) end
    local it = f:lines(...)
    return function() local _ = h; return it() end
  end
  function hmethods.close(h)
    local f = let_go(h)
    if not f then return nil, 'attempt to use a closed file' end
    return f:close()
  end
  local function wrapped(f, p)
    local h, mt
    if newproxy then h = newproxy(true); mt = getmetatable(h) else h = {}; mt = {}; setmetatable(h, mt) end
    mt.__index, mt.__metatable = hmethods, 'locked'
    mt.__tostring = function() return 'file (' .. (real_of[h] and 'open' or 'closed') .. ')' end
    if newproxy then mt.__gc = function(x) local g = let_go(x); if g then pcall(g.close, g) end end end
    real_of[h], path_of[h] = f, key_of(p)
    return h
  end
  -- io.type for a mod: a wrapped handle is a file too
  local function type_of(o)
    if path_of[o] ~= nil then return real_of[o] and 'file' or 'closed file' end
    return io_type(o)
  end
  -- May this trusted mod do this to path (p: lower case) in data\? -> true | nil, why | false (not a file of this kind)
  local function data_ok(g, p, what, path)
    local kind, n = data_file(g, p)
    if not kind then return false end
    if not g.patches.consent() then
      local why = 'writing game patch files waits for the player\'s yes (options menu, ' .. (ctx.LOADER or 'the loader') .. ')'
      pcall(g.patches.asked, why)
      return nil, why
    end
    if kind == 'scratch' then return true end
    if kind == 'main' and what == 'write' then return nil, 'a patch main file is only made by renaming a checked file to it' end
    if not patch_ours(g, s_sub(path, 1, 5) .. '9ba626afa44a3aa3.patch_' .. n) then return nil, 'that patch number is another mod\'s' end
    return true, kind
  end

  -- One mod's environment. owner: its name, for the log.
  function sb.env(owner)
    local env = setmetatable({}, env_mt)
    envs[env] = owner
    env._G = env
    for k, v in pairs(engine_names) do rawset(env, k, v) end
    for _, n in ipairs(LIBS) do
      local lib = rawget(G, n)
      if type(lib) == 'table' then env[n] = copy(lib) end
    end
    -- (string.dump only makes bytecode, which load and loadstring refuse anyway)
    if env.string then env.string.dump = nil end
    local string_view = { __index = env.string }     -- getmetatable('') gives this, not the game's
    local seen_mt = setmetatable({}, { __mode = 'k' }) -- an engine metatable -> this mod's copy of it
    local asked_native = false                       -- this mod's first require('ffi'/'jit') is logged
    env.getmetatable = function(o)
      local mt = getmetatable(o)
      if mt ~= nil and mt == string_mt then return string_view end
      if type(o) == 'userdata' and io_type(o) then return nil end   -- file handles: their methods are shared
      if type(mt) == 'table' and as_seen[rawget(mt, '__index')] ~= nil then
        local c = seen_mt[mt]                        -- one copy per metatable (objects of a kind share it)
        if not c then
          c = {}
          for k, v in pairs(mt) do c[k] = v end
          c.__index = as_seen[rawget(mt, '__index')] or nil
          seen_mt[mt] = c
        end
        return c
      end
      return mt
    end
    local os_c = {}
    if type(os_) == 'table' then for _, k in ipairs(OS_KEEP) do os_c[k] = os_[k] end end
    env.os = os_c
    env.package = { loaded = {}, preload = {}, path = '', cpath = '' }

    -- files: through my check, and the first denials of each mod go to the log
    local said = 0
    local function deny(what, path, mode, why)
      sb.denied = sb.denied + 1
      -- (a read of ..\something is a mod looking for a folder relative to where the game runs, as it tries the next
      -- spelling: refused, but not worth a log line)
      if what == 'open' and type(path) == 'string' and s_match(low(path), '^%.%.\\')
        and (mode == nil or not s_find(tostring(mode), '[wa%+]')) then return nil, why end
      said = said + 1
      if said <= 10 and ctx.log then
        ctx.log(s_format('blocked: %s tried to %s %s (%s): %s', owner, what, show(path), tostring(mode), why))
      end
      return nil, why
    end
    local io_c = {
      open = function(path, mode)
        local ok, root, names, ext = sb.check(path, mode)
        if not ok then
          local g = grants[owner]
          local mode_ok = mode == nil or (type(mode) == 'string' and (s_match(mode, '^[rwa]%+?b?$') or s_match(mode, '^[rwa]b%+$')))
          if g and mode_ok and real_open and type(path) == 'string' and path ~= '' and #path <= 400 and not s_find(path, '%z')
            and s_sub(path, 1, 2) ~= '\\\\' and s_sub(path, 1, 2) ~= '//' then
            local p = low(path)
            local writes = mode ~= nil and s_find(mode, '[wa%+]') ~= nil
            local yes, why = own_file(g, p), nil
            local in_data = false
            if not yes and writes then yes, why = data_ok(g, p, 'write', path); in_data = yes == true end
            if yes then
              local f, err, code = real_open(path, mode or 'r')
              if f and in_data then return wrapped(f, p) end
              return f, err, code
            end
            if yes == nil then return deny('open', path, mode, why) end
          end
          return deny('open', path, mode, root)
        end
        if not real_open then return nil, 'no io' end
        local f, err, code = real_open(path, mode or 'r')
        if f and not files_locked then lock_files(f) end
        -- a mod's own file read from the loader's folder that isn't there yet comes from the old folder
        -- (%LOCALAPPDATA%) if it's there: a mod's saved settings carry over,
        -- and its next write lands in the new place
        if not f and root == WDIR and ODIR and ctx.OLD_DIR and type(names) == 'table' and #names == 1 and ext
          and MOD_EXT[ext] and (mode == nil or mode == 'r' or mode == 'rb') then
          local g = real_open(ctx.OLD_DIR .. names[1], mode or 'r')
          if g then lock_files(g); return g end
        end
        return f, err, code
      end,
      lines = function(path)
        if path == nil then return io_.lines() end
        local ok, why = sb.check(path, 'r')
        if not ok then deny('read', path, 'r', why); error(why, 2) end
        return io_.lines(path)
      end,
      type = type_of,
      close = function(f) if f ~= nil then return f:close() end end,
      write = function(...) return io_.write(...) end,
      popen = blocked('io.popen'), tmpfile = blocked('io.tmpfile'), input = blocked('io.input'),
      output = blocked('io.output'),
    }
    env.io = io_c
    local g = grants[owner]
    if g and type(os_) == 'table' and os_.remove and os_.rename then
      -- a trusted mod's own files: removed or renamed within the same kind of place; renaming a file to a patch's
      -- main name checks it first (it must pass and carry the mod's marker, so the number stays recognizably its)
      local function place(path, what)
        if type(path) ~= 'string' or path == '' or #path > 400 or s_find(path, '%z') then return nil, 'not a file path' end
        local p = low(path)
        if own_file(g, p) then return 'own' end
        local ok, why = data_ok(g, p, what, path)
        if ok then return 'data', why end
        return nil, why or 'not one of this mod\'s files'
      end
      local function busy(path) return open_for_writing(key_of(low(path))) end
      os_c.remove = function(path)
        local where, why = place(path, 'remove')
        if not where then return deny('remove', path, '-', why) end
        if busy(path) then return deny('remove', path, '-', 'it is still open for writing') end
        for k in pairs(ours_cache) do ours_cache[k] = nil end
        return os_.remove(path)
      end
      os_c.rename = function(from, to)
        local a, why = place(from, 'rename')
        if not a then return deny('rename', from, '-', why) end
        local b, kind = place(to, 'rename')
        if not b then return deny('rename', to, '-', kind) end
        if a ~= b then return deny('rename', to, '-', 'only within the same folder') end
        if busy(from) or busy(to) then return deny('rename', from, '-', 'it is still open for writing') end
        if kind == 'main' then
          local ok, marked = patch_check(from, g.patches.marker)
          if not ok then return deny('rename', from, '-', 'not a patch file it may make: ' .. tostring(marked)) end
          if not marked then return deny('rename', from, '-', 'the patch doesn\'t carry the mod\'s marker') end
          if ctx.log then ctx.log(s_format('%s placed a checked game patch file: %s', owner, show(to))) end
        end
        for k in pairs(ours_cache) do ours_cache[k] = nil end
        return os_.rename(from, to)
      end
    end

    -- code it loads: text only, and it lands in this environment (or one the mod hands load)
    env.loadstring = function(s, name)
      if type(s) == 'string' and s_byte(s, 1) == 27 then return nil, 'compiled Lua (bytecode) is off limits' end
      local f, err = real_loadstring(s, name)
      if f then real_setfenv(f, env) end
      return f, err
    end
    env.load = function(chunk, name, mode, e)
      if type(chunk) == 'function' then
        local parts = {}
        while true do
          local piece = chunk()
          if piece == nil or piece == '' then break end
          if type(piece) ~= 'string' then return nil, 'reader function must return a string' end
          parts[#parts + 1] = piece
        end
        chunk = t_concat(parts)
      end
      if type(chunk) ~= 'string' then return nil, 'bad argument #1 to \'load\' (string or function expected)' end
      if mode == 'b' then return nil, 'attempt to load a text chunk (mode is \'b\')' end
      if s_byte(chunk, 1) == 27 then return nil, 'compiled Lua (bytecode) is off limits' end
      if e ~= nil and type(e) ~= 'table' then return nil, 'bad argument #4 to \'load\' (table expected)' end
      local f, err = real_loadstring(chunk, name)
      if f then real_setfenv(f, e or env) end
      return f, err
    end
    if overrides.xpcall then env.xpcall = overrides.xpcall end

    -- getfenv/setfenv: a function of the game's, the loader's or another mod's reads as this mod's own environment,
    -- and can't be changed. Levels count one more here (this wrapper is a level of its own).
    local function foreign(e) return e == G or full[e] ~= nil or (envs[e] ~= nil and e ~= env) end
    env.getfenv = function(f)
      if f == nil then f = 1 end
      if type(f) == 'number' then
        if f == 0 then return env end
        if f < 0 then error('bad argument #1 to \'getfenv\' (level must be non-negative)', 2) end
        local e = real_getfenv(f + 1)
        if foreign(e) then return env end
        return e
      end
      if type(f) ~= 'function' then error('bad argument #1 to \'getfenv\' (number or function expected)', 2) end
      local e = real_getfenv(f)
      if foreign(e) then return env end
      return e
    end
    env.setfenv = function(f, t)
      if type(t) ~= 'table' then error('bad argument #2 to \'setfenv\' (table expected)', 2) end
      if type(f) == 'number' then
        if f <= 0 then error('setfenv on the whole game is off limits to Chef Shared Loader mods', 2) end
        if foreign(real_getfenv(f + 1)) then error('that function isn\'t this mod\'s (off limits)', 2) end
        return real_setfenv(f + 1, t)
      end
      if type(f) ~= 'function' then error('bad argument #1 to \'setfenv\' (number or function expected)', 2) end
      if foreign(real_getfenv(f)) then error('that function isn\'t this mod\'s (off limits)', 2) end
      return real_setfenv(f, t)
    end

    -- debug: the traceback and getinfo (without the function itself), nothing that reaches locals or upvalues
    local d = {}
    if type(dbg) == 'table' then
      if dbg.traceback then d.traceback = function(...) return dbg.traceback(...) end end
      if dbg.getinfo then
        d.getinfo = function(f, what)
          if type(f) == 'number' then f = f + 1 end
          local info = (what ~= nil) and dbg.getinfo(f, what) or dbg.getinfo(f)
          if type(info) == 'table' then info.func = nil end
          return info
        end
      end
    end
    env.debug = d

    -- require: the mod's own package.loaded and package.preload first (a mod bundled as modules), then the libraries
    local LOADING = {}
    env.require = function(name)
      local pkg = rawget(env, 'package')
      local loaded = type(pkg) == 'table' and rawget(pkg, 'loaded')
      local preload = type(pkg) == 'table' and rawget(pkg, 'preload')
      if type(name) == 'string' and type(loaded) == 'table' then
        local v = loaded[name]
        if v == LOADING then error('require(\'' .. name .. '\'): a loop (it requires itself)', 2) end
        if v ~= nil then return v end
        local f = type(preload) == 'table' and preload[name]
        if f then
          if type(f) ~= 'function' then error('package.preload[\'' .. name .. '\'] is not a function', 2) end
          loaded[name] = LOADING
          local ok, r = pcall(f, name)
          if not ok then loaded[name] = nil; error(r, 0) end
          if r == nil then r = loaded[name] ~= LOADING and loaded[name] or true end
          loaded[name] = r
          return r
        end
      end
      local lib = REQUIRE_OK[name]
      if lib and env[lib] ~= nil then return env[lib] end
      if name == 'table.new' or name == 'table.clear' then
        local fn = env.table and env.table[s_sub(name, 7)]
        if fn then return fn end
      end
      -- ffi and jit aren't the loader's to give: the game runs plain Lua 5.1 since 7.2.0, so a mod that needs them
      -- (memory access) can't run with any loader. The message says so, instead of reading as a lockdown refusal.
      if name == 'ffi' or name == 'jit' then
        -- logged once even when the mod catches the error: a mod that quietly does without would otherwise look
        -- started and fine while what needs it never works
        if not asked_native and ctx.log then
          asked_native = true
          ctx.log(s_format('%s asked for %s, which the game hasn\'t had since its 7.2.0 update: whatever in it needs %s '
            .. '(game memory reads) won\'t work, with this loader or any other', owner, name, name))
        end
        error('require(\'' .. name .. '\'): the game has no ' .. name .. ' since its 7.2.0 update (plain Lua 5.1), so '
          .. 'a mod that needs it (game memory access) can\'t run with any loader', 2)
      end
      error('require(\'' .. tostring(name) .. '\') is off limits to Chef Shared Loader mods (another mod\'s exports: chef.require)', 2)
    end
    return env
  end

  -- is this table a mod environment of mine? (the loader's own checks)
  function sb.owner_of(t) return envs[t] end
  -- an environment with the game's whole Lua (another mod's boot script): to every loader mod it's someone else's, so
  -- getfenv on one of its functions gives the mod its own environment and setfenv refuses
  function sb.register_full(e, owner) if type(e) == 'table' then full[e] = owner or true end end
  return sb
end

return M
