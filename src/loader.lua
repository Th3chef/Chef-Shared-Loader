-- Chef Shared Loader - its core (mods/chef_shared_loader/core_1), or the game's `boot` script replaced
-- Runs Lua mods on the game's plain Lua 5.1 (no LuaJIT, no ffi).
-- What it's built on:
--   * the game runs `boot` at start-up and calls its init/update/render/shutdown; its own boot does nothing
--   * the game runs only the `boot` in the highest-numbered patch. My patch's `boot` is a small frozen stub
--     (src/stub.lua) that does what the game's boot does and then loads this file with
--     require('mods/chef_shared_loader/core_1'); any mod may ship that stub as its own `boot`, so whichever copy the
--     game runs, every loader mod runs. A mod with me built in runs this file as its `boot`.
--   * Lua can read the deployed patch files (io), so I find addons myself: Lua resources whose text starts with
--     "-- HD2-Addon: mods/<author>/<name>", option resources starting with "-- HD2-Options: mods/<author>/<name>",
--     and boot-style scripts starting with "-- HD2-Boot: mods/<author>/<name>" (open to every mod author; see
--     docs/MODDING.md)
--   * loadstring runs them; every addon gets its own environment and a `chef` table of helpers
--   * some engine calls crash the whole game (a null read, not a Lua error) when given the wrong kind of unit or
--     a stale handle; a Lua pcall can't catch that. So every engine call the helpers make is guarded: the first
--     time a call is made I write a breadcrumb, and if the game dies in it two launches running (once could be the
--     game closed from outside) the next launch skips that call, and turns off the addon that made it once it keeps
--     ending the game, saying so in the log and on screen.
--   * engine handles (units, GUIs, cameras) belong to one world: when the world changes I drop them all, and nothing
--     made in one world is used in the next.
--   * on a menu quit the game calls shutdown() and then often crashes by itself (a known game bug), so a run that
--     reached shutdown() is never blamed.
--   * the game's Lua is plain 5.1, not LuaJIT: I put back the pure-Lua parts addons lean on (bit,
--     table.new/clear, xpcall passing arguments, load taking a string; only what's missing) and log once a launch
--     what the game's Lua really has. ffi, the JIT and LuaJIT bytecode can't come back from a script.
-- Idle: nothing runs outside what an addon asked for. The unit scan only runs while an addon watches unit kinds, in a
-- settled world, spread over frames (1,500 units a frame). Drawing objects are made only when something draws.
-- Files (in %APPDATA%\Arrowhead\Helldivers2), named after FILES below (chef_loader): .log (what happened),
-- _state.txt (calls that crashed the game, addons turned off), _trace.txt (this launch's breadcrumbs).

-- Once per Lua state: a second copy of me, or another loader handing off to me after I started (see "For other
-- loaders" in docs/MODDING.md), finds me already running and does nothing.
if rawget(_G, 'ChefSharedLoader') ~= nil then return end
-- How I was started, kept before I set anything: require hands this chunk the name it asked for (as the game's `boot`
-- I get nothing); the callbacks the boot that loaded me set (they run after mine, as that boot's); and the other
-- loaders' tables, their lists of the mods they started, before my look-alikes take those names.
local chef_before = { via = ..., cb = {}, loaders = {} }
for _, k in ipairs({ 'init', 'update', 'render', 'shutdown' }) do
  local f = rawget(_G, k)
  if type(f) == 'function' then chef_before.cb[k] = f end
end
for _, k in ipairs({ '__boot_mod_loader', 'HD2ModLoader', 'CowboyBingusModLoader' }) do
  local L = rawget(_G, k)
  if type(L) == 'table' then chef_before.loaders[k] = L end
end
function init() end
function shutdown() end
function update(dt) end
function render() end

local loader_log                         -- my log, once it's open (so a failed start-up still reaches the file)
local loader_ok, loader_err = pcall(function()

-- A mod can carry this loader built in: its build swaps these three lines, so the name, the files and the addons it
-- runs are that mod's own.
local LOADER = 'Chef Shared Loader'      --@@LOADER@@
local FILES = 'chef_loader'              --@@FILES@@
local ALLOW = '^mods/[%w_%-]+/[%w_%-/]*[%w_%-]$' --@@ALLOW@@ any author's mods/<author>/<name>[/...] (mine first)
local VERSION = '1.4.1'
local TEST = nil --@@TEST@@               a test build's number (tools/build.py --test N); release: nil
local STABLE_FOR = 3                     -- seconds a main world must last before addons may draw in it
local MISSION_UNITS = 5000               -- without a level count: a main world bigger than this is a mission
local PROBE_MIN = 1000                   -- a smaller world (title, loading) is never probed for mission loot
local MISSION_LOOT = 3                   -- mission loot units that make a world a mission
local PROBE_DROP = 0.15                  -- a mission whose units fall this far below its peak is probed (the ship?)
local SUDDEN_DROP = 0.05                 -- or this far between two looks 2 s apart
local PROBE_EVERY = { 5, 10, 15 }        -- seconds between the first probes of a world that isn't a mission
local PROBE_LATER = 60                   -- and after those
local PROBE_IN_MISSION = 20              -- seconds between quiet probes of a mission no bigger than MISSION_UNITS
local SCAN_PER_FRAME = 1500
local RECENT = 60                        -- a per-frame job is only blamed for a crash within this many seconds of starting
local MAX_ERRORS = 20                    -- Lua errors before an addon is switched off for the session
local STATUS_EVERY = 60
local LOG_CAP = 4 * 1024 * 1024         -- bytes one launch may write to the log (a runaway addon can't fill the disk)
local CAMERA_RETRY = 1                   -- seconds between searches for the camera when it can't be found
-- Mods I trust with more than the locked-down space gives, by their HD2-Addon name. A name isn't proof of who made the
-- mod, so no grant adds a file a mod may write (data\ least of all): its files are the locked-down space's.
--   network, lobby_key: the Steam lobby through the HD2Runtime look-alike (the lobby the game reports, that key only)
--   capture: chef.capture, a picture of the screen saved by the loader itself (utilities.lua): the file's folder,
--   name and render target are mine, never the mod's, and its own Application still has no save_render_target
local TRUSTED = {
  ['mods/goose/war_journalist'] = { title = 'War Journalist', capture = true },
  ['mods/libra/match_your_colors'] = { title = 'Helmet Color-Match', network = true, lobby_key = 'hd2myc' },
}

local G = _G
-- my public mark, read-only: other loaders find me by it (and hand off to me through it; docs/MODDING.md)
-- (a userdata where the game has newproxy: rawset can't change its fields; a locked table where it hasn't)
do
  local fields = { name = LOADER, version = VERSION, api = 1, revision = 'chef-shared-loader-' .. VERSION,
                   core = 'mods/chef_shared_loader/core_1' }
  local mark = newproxy and newproxy(true)
  if mark then
    local mt = getmetatable(mark)
    mt.__index, mt.__metatable = fields, false
    mt.__newindex = function() error('read-only', 2) end
  else
    mark = setmetatable({}, { __metatable = false, __newindex = function() error('read-only', 2) end, __index = fields })
  end
  rawset(G, 'ChefSharedLoader', mark)
end
local S = rawget(G, 'stingray') or {}
local io_, os_ = rawget(G, 'io'), rawget(G, 'os')
local pairs, ipairs, pcall, type, tostring, tonumber = pairs, ipairs, pcall, type, tostring, tonumber
local fmt, concat, sort, min, max, floor, atan2 = string.format, table.concat, table.sort, math.min, math.max, math.floor, math.atan2
local byte, sub = string.byte, string.sub
local clock = type(os_) == 'table' and os_.clock or function() return 0 end

local elapsed = 0
local frame_no = 0

-- @@BEGIN compat.lua@@ (copied from src/chef_loader/compat.lua by tools/splice.py; edit that file, not this)
local compat = (function()
-- Chef Shared Loader: compat layer
-- I add back the pure-Lua parts of LuaJIT that mods lean on, for the game's plain Lua 5.1.
-- I only fill in what's missing: if the game still has LuaJIT's own bit library, I leave it alone.
-- What a script can't bring back: ffi, the JIT compiler and LuaJIT bytecode. Those need native code.
-- This file sticks to Lua 5.1 syntax on purpose (no goto, no \x escapes, no LL literals, no bit ops).

local floor, select, type, error = math.floor, select, type, error
local concat, rep = table.concat, string.rep
local rawget, rawset, next, pcall = rawget, rawset, next, pcall
local unpack = unpack or table.unpack

local M = { version = '0.1.0' }

---------------------------------------------------------------------------------------------------
-- bit: same API and same results as LuaJIT's bit library (signed 32-bit results)
---------------------------------------------------------------------------------------------------

local TWO32, TWO31 = 4294967296, 2147483648
-- Adding and subtracting 2^52 + 2^51 rounds to the nearest integer with ties to even. That's the
-- same trick LuaJIT uses inside bit.tobit, so 2.5 -> 2 and 3.5 -> 4 match it exactly.
-- It holds for |x| < 2^51; nothing a mod passes to bit should get anywhere near that.
local ROUND = 6755399441055744

-- I work in unsigned 0 .. 2^32-1 internally and only convert to signed on the way out.
local function tou(x)
  x = ((x + ROUND) - ROUND) % TWO32
  if x ~= x then return 0 end -- NaN and +-inf come out as 0, like LuaJIT
  return x
end

local function tos(u)
  if u >= TWO31 then return u - TWO32 end
  return u
end

-- Powers of two for the shifts: POW[n + 1] = 2^n for n = 0 .. 32
local POW = {}
for n = 0, 32 do POW[n + 1] = 2 ^ n end

-- Low masks (0x1, 0x3, ... 0xFFFFFFFF) map to their modulus, so band(x, 0xFF) is one % instead of a loop.
-- Masks like that are most of what mods pass to band.
local LOWMASK = {}
for k = 1, 32 do LOWMASK[2 ^ k - 1] = 2 ^ k end

-- 4-bit lookup tables, index a * 16 + b + 1. I build them with plain arithmetic.
local AND, OR, XOR = {}, {}, {}
for a = 0, 15 do
  for b = 0, 15 do
    local ra, ro, rx, p, x, y = 0, 0, 0, 1, a, b
    for _ = 1, 4 do
      local xb, yb = x % 2, y % 2
      if xb == 1 and yb == 1 then ra = ra + p end
      if xb == 1 or yb == 1 then ro = ro + p end
      if xb ~= yb then rx = rx + p end
      x, y, p = (x - xb) / 2, (y - yb) / 2, p * 2
    end
    local i = a * 16 + b + 1
    AND[i], OR[i], XOR[i] = ra, ro, rx
  end
end

-- Two-operand versions on unsigned values. Each loop stops as soon as one side runs out of bits.
local function band2(a, b)
  local m = LOWMASK[b]
  if m then return a % m end
  m = LOWMASK[a]
  if m then return b % m end
  local r, p = 0, 1
  while a > 0 and b > 0 do
    local x, y = a % 16, b % 16
    r = r + AND[x * 16 + y + 1] * p
    a, b, p = (a - x) / 16, (b - y) / 16, p * 16
  end
  return r
end

local function bor2(a, b)
  local r, p = 0, 1
  while a > 0 and b > 0 do
    local x, y = a % 16, b % 16
    r = r + OR[x * 16 + y + 1] * p
    a, b, p = (a - x) / 16, (b - y) / 16, p * 16
  end
  return r + (a + b) * p -- one side is 0 here, so the other side's leftover bits carry straight over
end

local function bxor2(a, b)
  local r, p = 0, 1
  while a > 0 and b > 0 do
    local x, y = a % 16, b % 16
    r = r + XOR[x * 16 + y + 1] * p
    a, b, p = (a - x) / 16, (b - y) / 16, p * 16
  end
  return r + (a + b) * p
end

-- band/bor/bxor take any number of operands, like LuaJIT's.
local function fold(op2)
  return function(x, y, ...)
    local r = tou(x)
    if y == nil then return tos(r) end
    r = op2(r, tou(y))
    local n = select('#', ...)
    if n > 0 then
      -- PERF: the extra operands through select, not { ... } (a table per call is garbage on every call)
      for i = 1, n do r = op2(r, tou((select(i, ...)))) end
    end
    return tos(r)
  end
end

local HEXL = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' }
local HEXU = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' }

local bit = {}

function bit.tobit(x) return tos(tou(x)) end

bit.band = fold(band2)
bit.bor = fold(bor2)
bit.bxor = fold(bxor2)

function bit.bnot(x) return tos(TWO32 - 1 - tou(x)) end

-- LuaJIT only uses the low 5 bits of a shift count, so shifting by 32 is a shift by 0.
function bit.lshift(x, n)
  return tos((tou(x) * POW[tou(n) % 32 + 1]) % TWO32)
end

function bit.rshift(x, n)
  return tos(floor(tou(x) / POW[tou(n) % 32 + 1]))
end

function bit.arshift(x, n)
  return floor(tos(tou(x)) / POW[tou(n) % 32 + 1]) -- floor on the signed value keeps the sign bit
end

function bit.rol(x, n)
  n = tou(n) % 32
  local u = tou(x)
  return tos((u * POW[n + 1]) % TWO32 + floor(u / POW[32 - n + 1]))
end

function bit.ror(x, n)
  return bit.rol(x, 32 - tou(n) % 32)
end

function bit.bswap(x)
  local u = tou(x)
  local b0 = u % 256; u = (u - b0) / 256
  local b1 = u % 256; u = (u - b1) / 256
  local b2 = u % 256
  local b3 = (u - b2) / 256
  return tos(((b0 * 256 + b1) * 256 + b2) * 256 + b3)
end

-- I build the hex string by hand: string.format('%x') goes through a C long, which is only
-- 32 bits on Windows, so anything at or above 2^31 would come out wrong there.
function bit.tohex(x, n)
  local digits, H = 8, HEXL
  if n ~= nil then
    digits = tos(tou(n))
    if digits < 0 then digits, H = -digits, HEXU end
    if digits > 254 then digits = 254 end -- LuaJIT stops at 254 characters too
  end
  local u = tou(x)
  local take = digits > 8 and 8 or digits
  local out = {}
  for i = take, 1, -1 do
    local d = u % 16
    out[i] = H[d + 1]
    u = (u - d) / 16
  end
  local s = concat(out, '', 1, take)
  if digits > 8 then s = rep('0', digits - 8) .. s end
  return s
end

M.bit = bit

---------------------------------------------------------------------------------------------------
-- Small LuaJIT extras
---------------------------------------------------------------------------------------------------

-- table.new only pre-sizes a table in LuaJIT; plain Lua 5.1 can't, so it returns an empty table.
local function table_new(narr, nrec) return {} end

-- Setting existing fields to nil while walking a table with next is allowed in Lua 5.1.
local function table_clear(t)
  local k = next(t)
  while k ~= nil do
    t[k] = nil
    k = next(t, k)
  end
end

-- LuaJIT's xpcall passes extra arguments on to the function; Lua 5.1's drops them, so a mod written for LuaJIT
-- would call its function with none. This one passes them on.
local function xpcall_args(f, handler, ...)
  local n = select('#', ...)
  if n == 0 then return xpcall(f, handler) end
  local args = { ... }
  return xpcall(function() return f(unpack(args, 1, n)) end, handler)
end

-- LuaJIT's load takes a string or a reader function (plus a mode and an environment, 5.2 style).
-- The game has no load at all, so I build it on loadstring alone: a reader's
-- pieces get joined first, then it's the same as a string.
local loadstring, setfenv = loadstring, setfenv
local function load_compat(chunk, name, mode, env)
  if type(chunk) == 'function' then
    local parts = {}
    while true do
      local piece = chunk()
      if piece == nil or piece == '' then break end
      if type(piece) ~= 'string' then return nil, 'reader function must return a string' end
      parts[#parts + 1] = piece
    end
    chunk = concat(parts)
  end
  if type(chunk) ~= 'string' then return nil, 'bad argument #1 to \'load\' (string or function expected)' end
  if mode == 'b' then return nil, 'attempt to load a text chunk (mode is \'b\')' end
  if chunk:byte(1) == 27 then return nil, 'binary chunks are not supported by this loader' end
  local f, err = loadstring(chunk, name)
  if f and env ~= nil and setfenv then setfenv(f, env) end
  return f, err
end

M.table_new, M.table_clear = table_new, table_clear
M.xpcall, M.load = xpcall_args, load_compat

---------------------------------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------------------------------

-- Is this already LuaJIT? Then its own bit, xpcall and load are the real thing and I stay out of the way. A jit table
-- alone isn't enough (another loader's stand-in can leave one): LuaJIT also compiles goto, which Lua 5.1 never does.
local function is_luajit(G)
  local ls = rawget(G, 'loadstring')
  if type(rawget(G, 'jit')) ~= 'table' or type(ls) ~= 'function' then return false end
  local ok, f = pcall(ls, 'do goto s end ::s::')
  return ok and f ~= nil
end

-- Fills in only what's missing in the shared globals. The game's own scripts never see a changed
-- function: I add names that don't exist and never replace ones that do.
-- Returns the list of names it added, for the loader's log.
function M.install(G)
  G = G or _G
  local added = {}
  local function add(tbl, key, value, label)
    if rawget(tbl, key) == nil then
      rawset(tbl, key, value)
      added[#added + 1] = label
    end
  end
  add(G, 'bit', bit, 'bit')
  local tbl = rawget(G, 'table')
  if type(tbl) == 'table' then
    add(tbl, 'new', table_new, 'table.new')
    add(tbl, 'clear', table_clear, 'table.clear')
    if unpack then add(tbl, 'unpack', unpack, 'table.unpack') end
  end
  -- So require('bit') / require('table.new') / require('table.clear') work too, when the game has require.
  local pkg = rawget(G, 'package')
  if type(pkg) == 'table' and type(pkg.preload) == 'table' and type(pkg.loaded) == 'table' then
    local function preload(name, value)
      if pkg.loaded[name] == nil and pkg.preload[name] == nil then
        pkg.preload[name] = function() return value end
        added[#added + 1] = 'require("' .. name .. '")'
      end
    end
    preload('bit', rawget(G, 'bit'))
    if type(tbl) == 'table' then
      preload('table.new', rawget(tbl, 'new'))
      preload('table.clear', rawget(tbl, 'clear'))
    end
  end
  return added
end

-- The globals that differ for a mod: the loader puts these into each mod's own environment rather than
-- swapping out the game's xpcall and load. On LuaJIT there's nothing to override.
function M.mod_overrides(G)
  G = G or _G
  if is_luajit(G) then return {} end
  return { xpcall = xpcall_args, load = load_compat }
end

M.is_luajit = is_luajit
return M
end)()
-- @@END compat.lua@@
-- @@BEGIN probe.lua@@ (copied from src/chef_loader/probe.lua by tools/splice.py; edit that file, not this)
local probe = (function()
-- Chef Shared Loader: startup probe
-- One look at what the game's Lua actually is, written to the loader log once per launch.
-- _VERSION says "Lua 5.1" on LuaJIT too, so I test the features themselves instead of trusting it.
-- It only reads and tries to compile tiny snippets. It never calls into game code and never writes anything.
-- Sanitized on purpose: I log yes/no flags and numbers only, never a value like a path or a user name.

local type, pcall, rawget, tostring, pairs, ipairs = type, pcall, rawget, tostring, pairs, ipairs
local concat, sort = table.concat, table.sort

local M = {}

local function has(G, path)
  local v = G
  for part in path:gmatch('[^%.]+') do
    if type(v) ~= 'table' then return false end
    v = rawget(v, part)
  end
  return v ~= nil
end

-- Does this snippet compile? (Compile only; nothing in it runs unless I say so below.)
local function compiles(G, src)
  local ls = rawget(G, 'loadstring') or rawget(G, 'load')
  if type(ls) ~= 'function' then return 'no-compiler' end
  local ok, f = pcall(ls, src, '=probe')
  return (ok and type(f) == 'function') and 'yes' or 'no'
end

local function compile_and_run(G, src)
  local ls = rawget(G, 'loadstring') or rawget(G, 'load')
  if type(ls) ~= 'function' then return nil end
  local ok, f = pcall(ls, src, '=probe')
  if not ok or type(f) ~= 'function' then return nil end
  local ok2, v = pcall(f)
  if ok2 then return v end
  return nil
end

-- First bytes of a dumped empty function: "\27Lua" + 0x51 is Lua 5.1, "\27LJ" is LuaJIT.
local function bytecode_header(G)
  local sd = has(G, 'string.dump') and G.string.dump
  if type(sd) ~= 'function' then return 'no-string.dump' end
  local ok, s = pcall(sd, function() end)
  if not ok or type(s) ~= 'string' then return 'dump-failed' end
  local out = {}
  for i = 1, 5 do
    local b = s:byte(i)
    if not b then break end
    out[#out + 1] = (b >= 32 and b < 127) and string.char(b) or ('<' .. b .. '>')
  end
  return concat(out)
end

-- A rough interpreter-vs-JIT hint: time 200k additions. Plain 5.1 is several times slower than LuaJIT here.
-- It costs a couple of milliseconds, so I only run it in test builds (run(G, { timing = true })).
local function loop_ms(G)
  local clock = has(G, 'os.clock') and G.os.clock
  if type(clock) ~= 'function' then return 'no-os.clock' end
  local t0 = clock()
  local x = 0
  for i = 1, 200000 do x = x + i % 7 end
  return string.format('%.2f', (clock() - t0) * 1000)
end

local NAMES = {
  'jit', 'bit', 'bit32', 'ffi', 'setfenv', 'getfenv', 'loadstring', 'load', 'dofile', 'loadfile',
  'require', 'package', 'package.preload', 'package.loaded', 'module', 'newproxy', 'collectgarbage',
  'coroutine', 'debug', 'debug.getinfo', 'debug.sethook', 'debug.traceback', 'io', 'io.open', 'os',
  'os.clock', 'os.time', 'os.getenv', 'string.dump', 'table.unpack', 'table.pack', 'table.new',
  'table.clear', 'unpack', 'print', 'math.huge',
}

function M.run(G, opts)
  G = G or _G
  local r = {}
  r['_VERSION'] = tostring(rawget(G, '_VERSION'))
  for _, name in ipairs(NAMES) do r['has.' .. name] = has(G, name) and 'yes' or 'no' end

  -- ffi sometimes only shows up through require (package.loaded), not as a global.
  local loaded = has(G, 'package.loaded') and G.package.loaded or nil
  r['loaded.ffi'] = (loaded and loaded.ffi ~= nil) and 'yes' or 'no'
  r['loaded.jit'] = (loaded and loaded.jit ~= nil) and 'yes' or 'no'
  r['loaded.bit'] = (loaded and loaded.bit ~= nil) and 'yes' or 'no'
  -- An ffi written in Lua is another loader's stand-in (it can't reach memory), not the real one. string.dump takes
  -- only a Lua function (debug, the other way to tell, is only there on the game's non-release builds).
  local f, dbg = rawget(G, 'ffi') or (loaded and loaded.ffi), rawget(G, 'debug')
  local str = rawget(G, 'string')
  local dump = type(str) == 'table' and rawget(str, 'dump') or nil
  if type(f) == 'table' and type(rawget(f, 'cdef')) == 'function' then
    local lua = nil
    if type(dump) == 'function' then lua = pcall(dump, f.cdef)
    elseif type(dbg) == 'table' and type(dbg.getinfo) == 'function' then
      local ok, i = pcall(dbg.getinfo, f.cdef, 'S')
      lua = ok and type(i) == 'table' and i.what == 'Lua'
    end
    if lua ~= nil then r['ffi.kind'] = lua and 'lua-stub' or 'native' end
  end

  -- Syntax LuaJIT accepts and plain 5.1 doesn't.
  r['syntax.goto'] = compiles(G, 'do goto skip end ::skip::')
  r['syntax.LL'] = compiles(G, 'return 1LL')
  r['syntax.ULL'] = compiles(G, 'return 1ULL')
  r['syntax.imaginary'] = compiles(G, 'return 1i')
  -- 5.1 reads "\x41" as "x41" instead of failing, so I check the result, not just the compile.
  local hex = compile_and_run(G, 'return "\\x41"')
  r['escape.x'] = (hex == 'A') and 'yes' or ('no(' .. tostring(hex and #hex) .. ' chars)')
  local uesc = compile_and_run(G, 'return "\\u{41}"')
  r['escape.u'] = (uesc == 'A') and 'yes' or 'no'

  -- Does load take a string (LuaJIT / 5.2 style)?
  local ld = rawget(G, 'load')
  if type(ld) == 'function' then
    local ok, f = pcall(ld, 'return 7')
    r['load.string'] = (ok and type(f) == 'function') and 'yes' or 'no'
  else
    r['load.string'] = 'no-load'
  end

  -- Does xpcall pass extra arguments (LuaJIT does, 5.1 doesn't)?
  local xp = rawget(G, 'xpcall')
  if type(xp) == 'function' then
    local ok2, ran, got = pcall(xp, function(a) return a end, function(e) return e end, 42)
    r['xpcall.args'] = (ok2 and ran and got == 42) and 'yes' or 'no'
  end

  r['bytecode.header'] = bytecode_header(G)
  if type(opts) == 'table' and opts.timing then r['loop.200k_ms'] = loop_ms(G) end
  local cg = rawget(G, 'collectgarbage')
  if type(cg) == 'function' then
    local ok, kb = pcall(cg, 'count')
    r['lua.memory_kb'] = ok and string.format('%.0f', kb) or 'n/a'
  end

  -- My summary line: which flavor this is.
  local luajit = r['has.jit'] == 'yes' or r['bytecode.header']:sub(1, 6) == '<27>LJ'
  r['flavor'] = luajit and 'luajit' or (r['syntax.goto'] == 'yes' and 'luajit-like' or 'lua51')
  return r
end

-- Stable, sorted "key=value" lines for the log.
function M.lines(r)
  local keys = {}
  for k in pairs(r) do keys[#keys + 1] = k end
  sort(keys)
  local out = {}
  for i, k in ipairs(keys) do out[i] = k .. '=' .. tostring(r[k]) end
  return out
end
return M
end)()
-- @@END probe.lua@@
-- @@BEGIN services.lua@@ (copied from src/chef_loader/services.lua by tools/splice.py; edit that file, not this)
local services = (function()
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
-- (a hint text's width, asked of the loader: it keeps a text's width in the game's font by the text as translated and
-- for the font it measured it with, never a guessed glyph's; a key's chip; a pair, the gap after it not counted; the
-- whole line. Plain functions, so a line laid out makes no closures)
-- The line as laid out is kept in c (one per hint line, nav.hint): each chip's and word's x from the line's start,
-- a chip's width and each text as drawn, laid out again only when its size, room, the menu's key, the font's capitals
-- or fk change (nav.fit_key: the language, the font measuring a text anew, my menu opened, and once a second, so a
-- glyph the font measured late is never kept longer than that). A line the language's budget cut (ctx.tr_cut) is
-- laid out again in the next frame.
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
local function hint_line(ctx, x, y, rh, px, x_end, pairs_, key, word_c, chip_c, ink, layer, P, c, fk)
  local room = x_end - x
  if c.k ~= fk or c.px ~= px or c.room ~= room or c.key ~= key or c.P ~= P then
    local cut = ctx.tr_cut
    if cut then cut(true) end
    c.k, c.px, c.room, c.key, c.P = fk, px, room, key, P
    local wgap = 6 * px                              -- (between a pair's keys and its word)
    local with_opt, gap = true, 12 * px
    if hint_line_w(ctx, pairs_, true, gap, key, px, P, wgap) > room then
      with_opt = false
      if hint_line_w(ctx, pairs_, false, gap, key, px, P, wgap) > room then gap, wgap = 8 * px, 4 * px end
    end
    -- (at: x from the line's start; a chip's kw is its width, a word's false)
    local first, n, at = true, 0, 0
    local kx, kw, tx, ts = c.kx, c.kw, c.tx, c.t
    for _, pr in ipairs(pairs_) do
      if with_opt or not pr.opt then
        local pw = hint_pair_w(ctx, pr, key, px, P, wgap)
        if (first and 0 or gap) + pw > room - at then break end
        if not first then at = at + gap end
        first = false
        for k = 1, #pr do
          local t = P(pr[k] or key or '')
          local w = hint_tw(ctx, t, px)
          local cw = math.max(w, 5 * px)
          if k > 1 then at = at + 3 * px end
          n = n + 1
          kx[n], kw[n], tx[n], ts[n] = at, cw + 4 * px, at + 2 * px + math.floor((cw - w) / 2), t
          at = at + cw + 4 * px
        end
        if pr.word then
          if #pr > 0 then at = at + wgap end
          local t = P(pr.word)
          n = n + 1
          kx[n], kw[n], tx[n], ts[n] = at, false, at, t
          at = at + hint_tw(ctx, t, px)
        end
      end
    end
    c.n, c.w = n, at
    if cut and cut() then c.k = nil end
  end
  local ty = y + math.floor((rh - 7 * px) / 2)
  local kx, kw, tx, ts = c.kx, c.kw, c.tx, c.t
  for i = 1, c.n do
    local w = kw[i]
    if w then
      ctx.rect(x + kx[i], y + 2 * px, w, rh - 4 * px, chip_c, layer)
      ctx.text(x + tx[i], ty, ts[i], px, ink, layer + 1)
    else
      ctx.text(x + tx[i], ty, ts[i], px, word_c, layer)
    end
  end
  return x + c.w
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
      -- captured there never fires a binding; svc.menu_up, as the mod's own chef can't change it: a field I keep
      -- equal to svc.menu_open() wherever my menu opens or closes, so a mod reading 80 binds a frame makes no call for it)
      function b.pressed()
        local v = r.value
        if v == 'off' or svc.menu_up then return false end
        local q = parts()
        if not q then return chef.key_pressed(v) end
        return combo(q, true)
      end
      function b.down()
        local v = r.value
        if v == 'off' or svc.menu_up then return false end
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
  -- down: the game is closing (svc.shutdown gave it back): never taken again
  local HOLD = 917351
  -- (clean: the looks in a row since the hold was let go that found the dead zone not mine: hold_heal)
  nav.hold = { on = false, had = nil, off = false, paused = false, other = nil, ever = false, heal_at = 0, bad = 0, clean = 0 }
  function nav.hold_take()
    local H, A = nav.hold, nav.axes
    if H.on or H.off or H.paused or H.down or not (A and A.move) then return end
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
    -- (one line each time I let it go, so a log shows the hold ending as well as starting; the values are what I put
    -- back, not read again: no engine call more than the one put back, at shutdown least of all)
    -- (quiet: a give-back was logged and my menu hasn't had the mouse since, so a mod that toggles chef.hold_mouse every
    -- frame writes one line, not one a frame; mouse_read clears it while my menu has the mouse. Shutdown always says it.)
    local at = H.down and 'shutdown' or 'options menu'
    local say = H.down or not H.quiet
    H.quiet = true
    if size == HOLD then
      eng('Mouse.set_dead_zone', A.move, H.had[1], H.had[2])
      if say then
        log(fmt('%s: the mouse given back to the game (its dead zone put back to %s, %s)', at, tostring(H.had[1]),
          tostring(H.had[2])))
      end
    elseif say then
      log(fmt('%s: the mouse let go (its dead zone was %s, not mine: left as it is)', at, tostring(size)))
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
    H.quiet = nil                                       -- (my menu has the mouse: its next give-back is logged)
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
  -- (a slider's and a key's text kept on the row, r.vs, made again only when what it's made from changes: the value
  -- and, r.vs_k, the slider's step or whether the key clashes; as swatch keeps its color)
  local function value_text(r, users)
    local s, v = r.spec, r.value
    if s.type == 'toggle' then return v and 'ON' or 'OFF' end
    if s.type == 'choice' then return text_of(s.choices[v]) end
    if s.type == 'slider' then
      -- (a whole number only when the value is one; else as many decimals as its step and min have, 3 at most, 2
      -- for a slider without a step. Worked out once a row and step: r.dp)
      local st = s.step or 0
      if r.vs_v == v and r.vs_k == st then return r.vs end
      local t
      if floor(v) == v and v > -1e9 and v < 1e9 then t = fmt('%d', v)
      else
        if r.dp_st ~= st then
          r.dp_st, r.dp = st, st > 0 and max(nav.places(st), nav.places(s.min), nav.places(s.max)) or 2
        end
        t = fmt(r.dp == 1 and '%.1f' or (r.dp == 2 and '%.2f' or (r.dp == 3 and '%.3f' or '%.0f')), v)
        -- (a value a hair off a whole one, 0.1 * 30, reads as the whole one)
        if r.dp > 0 and t:find('%.0+$') then t = t:gsub('%.0+$', '') end
        if t == '-0' then t = '0' end
      end
      r.vs, r.vs_v, r.vs_k = t, v, st
      return t
    end
    if s.type == 'key' then
      if menu.capture == r then return 'PRESS A KEY' end
      local clash = v ~= 'off' and (users[v] or 0) > 1
      if r.vs_v == v and r.vs_k == clash then return r.vs end
      -- (a controller button as 'PAD CROSS': the menu's font has no '_'; a combo shows as it's kept, 'CTRL+F6')
      local shown = v == 'off' and 'NONE' or (v:find('^pad:') and 'pad ' .. (v:sub(5):gsub('_', ' '))) or v
      local t = shown .. (clash and ' !' or '')
      r.vs, r.vs_v, r.vs_k = t, v, clash
      return t
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
  nav.hw, nav.nf, nav.hl = {}, {}, {}          -- (nav.nf: the full screen look's note line, as drawn; nav.hl: nav.hint)
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
  -- What my looks keep of their texts from frame to frame is good while nav.fk stays: worked out once a frame by each
  -- look before it draws, a new one when the font's capitals (P), the size, the language or the second changes, when
  -- my menu opens (nav.opened), or when the font measures a text anew (a text of mine never drawn, its width asked
  -- every frame, nav.fk_w, changes with the font: a font changed under the menu is laid out anew in the next frame;
  -- kept as it is, tr_keep, so the language never looks it up). The second is the backstop for anything the font
  -- changes that this one width doesn't show.
  function nav.fit_key(P, px)
    if nav.fk_p ~= P then nav.fk_pt = P('ABCDEFGHIJKLMNOPQRSTUVWXY0123456789') end
    local lv, sec = ctx.lang_v and ctx.lang_v() or 0, floor(ctx.now())
    if ctx.tr_keep then ctx.tr_keep(nav.fk_pt) end
    local pw = ctx.text_width(nav.fk_pt, px)
    if P ~= nav.fk_p or px ~= nav.fk_px or lv ~= nav.fk_lv or sec ~= nav.fk_s or pw ~= nav.fk_w then
      nav.fk_p, nav.fk_px, nav.fk_lv, nav.fk_s, nav.fk_w, nav.fk = P, px, lv, sec, pw, (nav.fk or 0) + 1
    end
  end
  -- A row's label and value as drawn, kept on the row in one small table (nav.fc: r.fc, by place, so a row seen once
  -- costs it a few hundred bytes for good). i: 0 for the label, 6 for the value; c[i + 1] the text as the row gives it
  -- this frame (raw), c[i + 2] it in the font's capitals, c[i + 3] the nav.fk it was made under (false: made again in
  -- the next frame), c[i + 4] the width asked for (the whole text's, nav.fwhole, or the cut one's, nav.fcut),
  -- c[i + 5] the room it was cut to and c[i + 6] the text cut to it. Made again only when raw or nav.fk changes, and
  -- cut again only when the room changes too, so an open menu measures and cuts each row's texts about once a second,
  -- not every frame. A text the language's budget cut (ctx.tr_cut) is made again in the next frame.
  function nav.fc(r)
    local c = r.fc
    if not c then c = { false, false, false, false, false, false, false, false, false, false, false, false }; r.fc = c end
    return c
  end
  function nav.fwhole(c, i, raw, px, P, whole)
    if c[i + 1] ~= raw or c[i + 3] ~= nav.fk then
      local cut = ctx.tr_cut
      if cut then cut(true) end
      local t = P(raw)
      c[i + 1], c[i + 2], c[i + 3], c[i + 5] = raw, t, nav.fk, false
      if whole then c[i + 4] = ctx.text_width(t, px) end
      if cut and cut() then c[i + 3] = false end
    end
    return c[i + 2], c[i + 4]
  end
  function nav.fcut(c, i, room, px, fit, wide)
    if c[i + 5] ~= room then
      local cut = ctx.tr_cut
      if cut then cut(true) end
      local o = fit(c[i + 2], px, room)
      c[i + 5], c[i + 6] = room, o
      if wide then c[i + 4] = ctx.text_width(o, px) end
      if cut and cut() then c[i + 3] = false end
    end
    return c[i + 6], c[i + 4]
  end
  -- a hint line (HINTS, nav.entry_hints) drawn from x to x_end, laid out once and kept per line: hint_line
  function nav.hint(segs, x, y, rh, px, x_end, key, word_c, chip_c, ink, layer, P)
    local c = nav.hl[segs]
    if not c then c = { kx = {}, kw = {}, tx = {}, t = {}, n = 0, w = 0 }; nav.hl[segs] = c end
    return hint_line(ctx, x, y, rh, px, x_end, segs, key, word_c, chip_c, ink, layer, P, c, nav.fk)
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
    nav.fit_key(P, px)
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
        -- (the label and the value as drawn, kept on the row: nav.fc)
        local fc = nav.fc(r)
        local lt, ltw = nav.fwhole(fc, 0, text_of(r.spec.label or r.id), px, P, true)
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
        nav.fwhole(fc, 6, value_text(r, users), px, P)
        local v, vw = nav.fcut(fc, 6, max(floor(inner * 0.4) - 2 * aw, xe - aw - 6 * px - lx - ltw), px, fit, true)
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
        ctx.text(lx, ty, (nav.fcut(fc, 0, lr, px, fit)), px, white, top + 2)
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
      nav.hint(segs, x0 + tx, hy, rh, px, x0 + tx + inner,
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
  nav.F, nav.no_rows = {}, {}
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
  -- cursor on the ship. mouse_read already asked this frame while the menu has the mouse; else I ask, every 0.25 s
  -- (nav.pz the answer, nav.pz_at when it's asked again; nav.opened forgets it, so the menu's first frame asks)
  function nav.paused()
    if nav.mouse and nav.axes and nav.axes.move then return nav.game_cursor == true end
    local t = ctx.now()
    if nav.pz == nil or t >= nav.pz_at or t < nav.pz_at - 0.25 then
      local win = eng('Window.get_main_window')
      nav.pz, nav.pz_at = win ~= nil and eng('Window.show_cursor', win) == true, t + 0.25
    end
    return nav.pz
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
    nav.fit_key(P, px)
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
    -- (my name and version, made once per font's capitals: nav.lv_t)
    if nav.lv_p ~= P then nav.lv_p, nav.lv_t = P, P(ctx.LOADER .. ' ' .. tostring(ctx.VERSION)) end
    local rtext = searching and P('SEARCH /' .. menu.search .. (menu.typing and '_' or '')) or nav.lv_t
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
    if nav.gs_n ~= #gs then nav.gs_n, nav.gs_s = #gs, tostring(#gs) end   -- (the count as text: made when it changes)
    nav.pane(lx, lw, 'MODS', nav.gs_s, panel, line, gray)
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
      rows = nav.no_rows                       -- (nothing to preview: one empty list for every frame, never written to)
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
    if nav.ro_p ~= P then nav.ro_p, nav.ro_t = P, P('RIGHT ARROW OPENS') end
    local te, se, sty = nav.pane(rx, rwid, title, listing and #rows > 0 and nav.ro_t or nil, panel, line,
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
        -- (the label and the value as drawn, kept on the row: nav.fc)
        local fc = nav.fc(r)
        nav.fwhole(fc, 6, value_text(r, users), px, P)
        local v, vw = nav.fcut(fc, 6, vmax, px, fit, true)
        local live = not listing
        local lcol = live and white or dim
        local vcol = not live and dim or ((sp.type == 'toggle' and not r.value) and gray or (menu.capture == r and yellow or green))
        if live then nav.hit(rx, y, rwid, rh, 'line', i) end
        local lab, labw = nav.fwhole(fc, 0, text_of(sp.label or r.id), px, P, true)
        local long = x + labw + 8 * px             -- (where a whole label would let its value start)
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
          ctx.text(x, ty, (nav.fcut(fc, 0, bx - 8 * px - x, px, fit)), px, lcol, top + 4)
        else
          -- (a reset button asking: SURE? in orange with its seconds left after it, an orange edge on its row)
          local arm = live and r.armed and ctx.now() < r.armed
          local cd = arm and nav.sure(r)
          local cdw = cd and tw(cd, px) + 4 * px or 0
          local vx = long > vc and max(vt, xr - vw - cdw) or vt
          ctx.text(x, ty, (nav.fcut(fc, 0, vx - 8 * px - x, px, fit)), px, lcol, top + 4)
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
      nav.hint(segs, m, hy, rh, px, w - m, close_key, white, white, ink, top + 2, P)
    end
    nav.draw_cursor(top, h)
  end
  -- where the menu's cursor is (menu pixels, y up; nil before the mouse was read)
  function svc.menu_cursor() return nav.mx, nav.my end
  -- open now? (mods' key and mouse-button reads answer nothing while it is: sandbox.lua, runtime.lua, chef.typed,
  -- chef.bind, svc.pad_bind and the ModBindingsMenu look-alike)
  function svc.menu_open() return menu.open == true end
  -- (the same as a field, for the binds: set with menu.open, in menu_frame, the one place my menu opens or closes)
  svc.menu_up = false
  -- (my menu opened: what its look keeps from frame to frame laid out anew, nav.fit_key, and the pause screen asked
  -- again, nav.paused)
  function nav.opened()
    svc.menu_up, nav.fk_s, nav.pz = true, nil, nil
  end
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
      nav.opened()
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
        menu.open, svc.menu_up = false, false
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
      menu.open, menu.typing, nav.drag, svc.menu_up = false, false, nil, false
      if menu.ask then reset_ask(menu.ask, false) end
      return
    end
    if not menu.open then
      if mk ~= 'off' and pressed(mk) then
        -- it always opens on the list of mods
        menu.open, menu.group, menu.search, menu.sel, menu.top = true, nil, '', 1, 1
        nav.opened()
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
                 rt = { hashes = {}, statuses = {}, versions = { [1] = true }, hash_reads = 0 },
                 poll_f = { 'down', 'pressed', 'released', 'last' } }   -- (ModBindingsMenu's poll fills these, k.poll)
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
    if st == 'started elsewhere' or st == 'left to its loader' then return 'loaded' end
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
      local fs = shim.poll_f                    -- (the four names made once: a poll a frame makes no table)
      for i = 1, 4 do
        local f = fs[i]
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
      -- (asked from a shutdown hook, after I gave the mouse back: nothing after that would let it go again)
      if nav.hold.down then return false, 'the mouse can\'t be held: the game is closing' end
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
    -- (the mouse back to the game first, mods' holds too, and never taken again: a shutdown hook below asking for it is
    -- refused, so nothing below may keep it)
    nav.hold.down = true
    nav.holds.by, nav.holds.n = {}, 0
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
end)()
-- @@END services.lua@@
-- @@BEGIN utilities.lua@@ (copied from src/chef_loader/utilities.lua by tools/splice.py; edit that file, not this)
services.utilities = (function()
-- Chef Shared Loader: utilities (api 3)
-- More helpers every mod gets, on top of services.lua's:
--   1 safe unit access: unit_kind / unit_alive / unit_position / unit_rotation / unit_node, calls known to crash the
--     game refused centrally (in chef.call too), units_near over the shared unit scan, ray_box (a ray against a box)
--   2 spawn / despawn / link / unlink, particles and unit lights, all cleaned up at a world change or when the mod
--     stops
--   3 timers (after, every), spread (a list worked through over frames) and a frame budget per mod (warned in the log)
--   4 setting (the game's settings file), in_session / is_host / players
--   5 triangle / circle / ring / arc, sprite sheets (bitmap_uv) and notify (a message on screen)
--   6 typed (the text typed this frame) and key_label (a key's name on the player's keyboard)
--   7 save_table / load_table, and capture (a picture of the screen, for a mod granted it)
--   8 mods (every mod the loader found, with its version and state)
--   9 index (which mod's copy of each resource the game loads, and what overrides what)
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

-- ------------------------------------------------------------------ the index: which mod's file wins
-- Every resource (type + id) in the patch files the loader reads at start-up (the boot archive's, 9ba626afa44a3aa3),
-- which patch gives the copy loaded (the highest number) and which it shadows. Built from the tables of contents
-- (bodies are read only to tell two copies of one resource apart: the first 64 KB of each part), the first time a mod
-- asks (chef.index) or right after start-up when a mod says which of its files must win (-- HD2-Exclusive:). It's
-- built a little each frame (M.index runs as a coroutine and yields when its slice is used up), and the comparisons
-- read at most READ_CAP bytes in all: past that, same-size copies count as different (the log says how many).
-- ctx: open, log, FILES; P: patches() -> {{file, n}} ascending, owners() -> {[file] = {mod names}},
-- policies() -> {[mod] = {exclusive = {sel}, fallback = {sel}}}, clock, notify, slice() (true: yield now), optional
-- title(mod) (a mod's name as my options menu shows it, for a notice).
M.TYPES = { unit = 'e0a48d0be9a7453f', material = 'eac0b497876adedf', texture = 'cd4238c6a0c69e32',
  package = 'ad9c6d9ed1e5e77a', lua = 'a14e8dfa2cd117e2', bones = '18dead01056b72e9', animation = '931e336d7646cc26',
  state_machine = 'a486d4045106165c', particles = 'a8193123526fad64', wwise_bank = '535a7bd3e650d799',
  wwise_stream = '504b55235d21440e', wwise_dep = 'af32095c82f2b070', font = '9efe0a916aae7880',
  shader_library = 'e5ee32a477239a93', strings = '0d972bab10b40fd3', geometry_group = 'c4f0f4be7fb0c8d6',
  physics = '5f7203c8f280dab8', prefab = 'ab2f78e885f513c6', level = '2a690fd348fe9ac5', entity = '9831ca893b0d087d',
  render_config = '27862fe24795319c', speedtree = 'e985c5f61c169997' }
M.NAME_OF = {}
for k, v in pairs(M.TYPES) do M.NAME_OF[v] = k end
M.READ_CAP = 64 * 1024 * 1024
local co_lib = coroutine                         -- (taken when the loader starts: nothing a mod does later replaces it)
local s_byte, s_sub = string.byte, string.sub
local function u32(s, i) local a, b, c, d = s_byte(s, i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
local function u64(s, i) return u32(s, i) + u32(s, i + 4) * 4294967296 end
local function hex_of(s, i)                      -- 8 little-endian bytes at i -> 16 hex digits
  local a, b, c, d, e, f, g, h = s_byte(s, i, i + 7)
  return fmt('%02x%02x%02x%02x%02x%02x%02x%02x', h, g, f, e, d, c, b, a)
end
-- a type name ('unit') or 16 hex digits -> 16 hex digits, or nil
function M.type_hex(t)
  if type(t) ~= 'string' then return nil end
  t = t:lower()
  if M.TYPES[t] then return M.TYPES[t] end
  if #t == 16 and t:match('^%x+$') then return t end
  return nil
end
-- "-- HD2-Exclusive: unit material:<16 hex>" and "-- HD2-Fallback: texture *" among a mod's first lines
function M.policies(src)
  local out = { exclusive = {}, fallback = {} }
  for kind, words in s_sub(src, 1, 1200):gmatch('\n%-%- HD2%-(%a+):[ \t]*([^\r\n]*)') do
    local list = kind == 'Exclusive' and out.exclusive or (kind == 'Fallback' and out.fallback or nil)
    if list then
      for w in words:gmatch('%S+') do
        if w == '*' then list[#list + 1] = { any = true }
        else
          local t, id = w:match('^([%w_]+):(%x+)$')
          local th = M.type_hex(t or w)
          if th and (not id or #id == 16) then list[#list + 1] = { type = th, id = id and id:lower() } end
        end
      end
    end
  end
  return out
end
local function matches(list, th, id)
  for _, s in ipairs(list) do
    if s.any or (s.type == th and (not s.id or s.id == id)) then return true end
  end
  return false
end
-- (yields only between patches and between comparisons: never inside a pcall, which a Lua 5.1 coroutine can't yield
-- across)
function M.index(ctx, P)
  local t0, busy = P.clock(), 0
  local I = { rows = 0, same = 0, fallback = 0, shared = 0, files = 0, bad = 0, conflicts = {}, more = 0, unread = 0,
              compared = 0, read = 0, excl = 0 }
  -- A resource (id, type) -> its winning row, and the rows it shadows (highest first). A row is its code: patch index *
  -- 2^21 + entry (a patch of up to 262,144 rows is indexed; the code has room past that). The key is a number, not the
  -- row's 16 bytes as a string: a string per row would grow Lua's string table by hundreds of thousands, and each
  -- doubling of it is one step of tens of ms no pause can split. The number is the id's low 45 bits * 256 + the type's
  -- index (types are a few strings, seen again and again); the id's top 19 bits go with the code in the value
  -- (top * 2^34 + code: up to 8191 patches, below 2^53, so a double holds it exactly), so two ids that share the low
  -- bits are told apart. The rare second one is kept by its 16 bytes (wins_s / shads_s). The tables are split by the
  -- id's low byte into 256, so no single table grows to hundreds of thousands of keys (one rehash of that is tens of
  -- ms too).
  local wins, shads, wins_s, shads_s, tix, ntypes = {}, {}, {}, {}, {}, 0
  for b = 0, 255 do wins[b], shads[b] = {}, {} end
  local list = P.patches()
  if #list > 8191 then error('more than 8191 patch files') end   -- (the loader reads up to 4096)
  local tocs = {}                -- patch index -> its table of contents' rows, in blocks of 512
  local function pause()
    if P.slice() then
      local t1 = P.clock(); busy = busy + (t1 - t0)
      co_lib.yield()
      t0 = P.clock()
    end
  end
  for pi, p in ipairs(list) do
    local f = ctx.open('data/' .. p.file, 'rb')
    if f then
      -- The table of contents is read in blocks of 512 rows, with a pause between them (one read of a big patch's
      -- whole table takes tens of ms); each read is under pcall, the walk isn't (it can't raise, and it has to yield).
      -- A patch whose header or rows can't be read is left out and counted as bad.
      local nt, ne
      local ok = pcall(function()
        local head = f:read(72) or ''
        if #head ~= 72 or u32(head, 1) ~= 0xF0000011 then return end
        local t_, e_ = u32(head, 5), u32(head, 9)
        if t_ > 4096 or e_ > 262144 then return end
        if t_ > 0 and #(f:read(t_ * 32) or '') < t_ * 32 then return end
        nt, ne = t_, e_
      end)
      local blocks, good = {}, ok and nt ~= nil
      local e0 = 0
      while good and e0 < ne do
        local n = min(512, ne - e0)
        local s
        good = pcall(function() s = f:read(n * 80) end) and s ~= nil and #s == n * 80
        if good then
          blocks[#blocks + 1] = s
          for e = e0, e0 + n - 1 do
            local at = (e - e0) * 80 + 1
            local ts = s_sub(s, at + 8, at + 15)
            local ti = tix[ts]
            if not ti then ntypes = ntypes + 1; ti = ntypes; tix[ts] = ti end
            local lo, hi = u32(s, at), u32(s, at + 4)
            local b, top = lo % 256, floor(hi / 8192)
            local code = pi * 2097152 + e
            local wt, st, k = wins[b], shads[b], ((hi % 8192) * 4294967296 + lo) * 256 + ti
            local v = ti < 256 and wt[k] or nil
            local was = v and floor(v / 17179869184) == top and v % 17179869184 or nil
            if ti >= 256 or (v and not was) then                 -- (by its 16 bytes)
              wt, st, k = wins_s, shads_s, s_sub(s, at, at + 15)
              was = wt[k]
            end
            if was and floor(was / 2097152) ~= pi then         -- (a resource listed twice in one patch: once)
              local sh = st[k]
              if not sh then sh = {}; st[k] = sh end
              table.insert(sh, 1, was)
            end
            wt[k] = wt == wins_s and code or top * 17179869184 + code
          end
          e0 = e0 + n
          pause()
        end
      end
      pcall(f.close, f)
      tocs[pi] = blocks              -- (rows taken from a patch whose later block then failed stay, with their block)
      if good then I.files, I.rows = I.files + 1, I.rows + ne else I.bad, I.rows = I.bad + 1, I.rows + e0 end
    end
    pause()
  end
  local function row(code)
    local pi, e = floor(code / 2097152), code % 2097152
    local blocks = tocs[pi]
    local b = floor(e / 512)
    return list[pi], blocks and blocks[b + 1] or '', (e - b * 512) * 80 + 1
  end
  -- the first 64 KB of each of a resource's three parts: the main file, .stream and .gpu_resources (a texture's main
  -- part is only its header; its pixels are in .gpu_resources)
  local function part(path, off, size)
    if size == 0 then return '' end
    local f = ctx.open(path, 'rb')
    if not f then return nil end
    local got
    pcall(function()
      if f:seek('set', off) then got = f:read(min(size, 65536)) end
      -- and the last 4 KB of a bigger part (a retexture can differ only past the first 64 KB)
      if got and size > 65536 and f:seek('set', off + size - 4096) then
        local tail = f:read(4096)
        got = tail and (got .. tail) or nil
      end
    end)
    pcall(f.close, f)
    if got then I.read = I.read + #got end
    return got
  end
  local function first_bytes(p, toc, at)
    local main = part('data/' .. p.file, u64(toc, at + 16), u32(toc, at + 56))
    local stream = part('data/' .. p.file .. '.stream', u64(toc, at + 24), u32(toc, at + 60))
    local gpu = part('data/' .. p.file .. '.gpu_resources', u64(toc, at + 32), u32(toc, at + 64))
    if not (main and stream and gpu) then return nil end
    return main .. '\0' .. stream .. '\0' .. gpu
  end
  local owners, policies = P.owners(), P.policies()
  local function mods_of(p) return owners[p.file] or {} end
  local function label(p) local m = mods_of(p); return #m > 0 and concat(m, ',') or ('patch ' .. p.n) end
  local pairs_said = {}
  local steps = 0
  local th_of = {}                                 -- a row's type -> its 16 hex digits (a few types, read once each)
  local function type_hex(toc, at)
    local ts = s_sub(toc, at + 8, at + 15)
    local h = th_of[ts]
    if not h then h = hex_of(toc, at + 8); th_of[ts] = h end
    return h
  end
  -- two patches of different mods (or two unannounced ones) give one resource: a conflict unless the copies match
  for b = 0, 256 do
    local st, wt = shads[b] or shads_s, wins[b] or wins_s
    for key, list_of in pairs(st) do            -- (nothing is added while this walks it: yielding is fine)
      steps = steps + 1
      if steps % 256 == 0 then pause() end
      local wp, wtoc, wat = row(wt[key] % 17179869184)
      for _, code in ipairs(list_of) do
        local lp, ltoc, lat = row(code)
        if label(wp) ~= label(lp) then
          -- same sizes, then the same bytes of each part, while the reading cap lasts; past it, a same-size pair is
          -- listed as unchecked (it may be the same: no notice for it)
          -- (compared as numbers: a string per pair would grow Lua's string table, as the keys would)
          local same = u32(wtoc, wat + 56) == u32(ltoc, lat + 56) and u32(wtoc, wat + 60) == u32(ltoc, lat + 60)
            and u32(wtoc, wat + 64) == u32(ltoc, lat + 64)
          local unchecked = false
          if same and I.read < M.READ_CAP then
            I.compared = I.compared + 1
            local a, b = first_bytes(wp, wtoc, wat), first_bytes(lp, ltoc, lat)
            same = a ~= nil and a == b
            pause()
          elseif same then same, unchecked, I.unread = false, true, I.unread + 1 end
          if same then I.same = I.same + 1
          elseif unchecked then
            if #I.conflicts < 1000 then
              local th = type_hex(wtoc, wat)
              I.conflicts[#I.conflicts + 1] = { type = M.NAME_OF[th] or th, id = hex_of(wtoc, wat),
                policy = 'unchecked', winner = { patch = wp.n, mods = mods_of(wp) }, loser = { patch = lp.n, mods = mods_of(lp) } }
            else I.more = I.more + 1 end
          else
            local th, id = type_hex(wtoc, wat), nil      -- (the id's 16 hex digits only when something needs them)
            local policy = 'shared'
            for _, m in ipairs(mods_of(lp)) do
              local pol = policies[m]
              if pol then
                id = id or hex_of(wtoc, wat)
                if matches(pol.fallback, th, id) then policy = 'fallback' end
                if policy ~= 'fallback' and matches(pol.exclusive, th, id) then policy = 'exclusive' end
              end
            end
            if policy == 'fallback' then I.fallback = I.fallback + 1
            else
              if policy == 'shared' then I.shared = I.shared + 1 end
              if #I.conflicts < 1000 or (policy == 'exclusive' and I.excl < 4000) then   -- (HD2-Exclusive: up to 4,000 more)
                if policy == 'exclusive' and #I.conflicts >= 1000 then I.excl = I.excl + 1 end
                I.conflicts[#I.conflicts + 1] = { type = M.NAME_OF[th] or th, id = id or hex_of(wtoc, wat), policy = policy,
                  winner = { patch = wp.n, mods = mods_of(wp) }, loser = { patch = lp.n, mods = mods_of(lp) } }
              else I.more = I.more + 1 end
              local pk = wp.n .. ' ' .. lp.n .. ' ' .. policy
              pairs_said[pk] = (pairs_said[pk] or 0) + 1
            end
          end
        end
      end
    end
  end
  -- the index itself: key -> the winning patch, and the shadowed ones (numbers only; the tables of contents go)
  local function bin(h)                          -- 16 hex digits -> the 8 little-endian bytes the tables hold
    local t = {}
    for i = 15, 1, -2 do t[#t + 1] = string.char(tonumber(s_sub(h, i, i + 1), 16)) end
    return concat(t)
  end
  I.lookup = function(th, id)
    local key = bin(id) .. bin(th)
    local lo, hi, ti = u32(key, 1), u32(key, 5), tix[s_sub(key, 9, 16)]
    local b = lo % 256
    local k = ti and ti < 256 and ((hi % 8192) * 4294967296 + lo) * 256 + ti
    local v = k and wins[b][k]
    local w, sh
    if v and floor(v / 17179869184) == floor(hi / 8192) then w, sh = v % 17179869184, shads[b][k]
    else w, sh = wins_s[key], shads_s[key] end
    if not w then return nil end
    local out = {}
    local pi = floor(w / 2097152)
    out[1] = { patch = list[pi].n, file = list[pi].file, mods = mods_of(list[pi]) }
    for _, code in ipairs(sh or {}) do
      local p = list[floor(code / 2097152)]
      out[#out + 1] = { patch = p.n, file = p.file, mods = mods_of(p) }
    end
    return out
  end
  I.patches = {}
  for _, p in ipairs(list) do I.patches[#I.patches + 1] = { number = p.n, file = p.file, mods = mods_of(p) } end
  tocs = nil
  I.ms = (busy + P.clock() - t0) * 1000
  -- the report (under pcall: a broken log or notice mustn't lose the index that's built)
  local rep_ok, rep_err = pcall(function()
  ctx.log(fmt('index: %d rows in %d patch files; between mods %d overridden (%d expected by a fallback), %d identical%s '
    .. '(%.2f ms of work, %.1f MB compared)', I.rows, I.files, #I.conflicts + I.more + I.fallback - I.unread, I.fallback,
    I.same, I.unread > 0 and fmt(', %d of the same size not compared (reading cap; listed as unchecked)', I.unread) or '',
    I.ms, I.read / 1048576))
  local keys, notified = {}, {}       -- notified: one notice a mod, however many patches override it
  for k in pairs(pairs_said) do keys[#keys + 1] = k end
  local function num_order(x, y)
    local a1, a2 = x:match('^(%d+) (%d+)'); local b1, b2 = y:match('^(%d+) (%d+)')
    a1, a2, b1, b2 = tonumber(a1), tonumber(a2), tonumber(b1), tonumber(b2)
    if a1 ~= b1 then return a1 < b1 end
    if a2 ~= b2 then return a2 < b2 end
    return x < y
  end
  sort(keys, num_order)
  for _, k in ipairs(keys) do
    local w, l, policy = k:match('^(%d+) (%d+) (%a+)$')
    local wp, lp
    for _, p in ipairs(list) do if p.n == tonumber(w) then wp = p elseif p.n == tonumber(l) then lp = p end end
    ctx.log(fmt('index: %s (patch %s) overrides %d resource(s) of %s (patch %s)%s', label(wp), w, pairs_said[k], label(lp), l,
      policy == 'exclusive' and ': that mod says they must win (HD2-Exclusive); deploy it after the other or drop one' or ''))
    if policy == 'exclusive' and P.notify then
      for _, m in ipairs(mods_of(lp)) do
        if not notified[m] then
          notified[m] = true
          -- (named as my options menu names the mod, P.title; its file's last part without it)
          local short = (P.title and P.title(m) or m:match('([^/]+)$') or m):upper():gsub('_', ' ')
          local tail = ' IS OVERRIDDEN BY ANOTHER MOD (SEE ' .. ctx.FILES:upper() .. '.LOG)'
          if #short + #tail > 80 then short = s_sub(short, 1, max(8, 77 - #tail)) .. '...' end
          P.notify({ text = short .. tail, dur = 20 })
        end
      end
    end
  end
  end)
  if not rep_ok then pcall(ctx.log, 'index: the report failed: ' .. tostring(rep_err)) end
  return I
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
-- An owner's name flattened for a file name: mods/a/b -> a_b. A nested name (more than two
-- parts) gets "_" and 8 hex digits of a hash of the whole name on top, so mods/a/b/c and mods/a/b_c never share a
-- file (two-part names keep their old files). The hash: two 16-bit halves of a 32-bit one, since string.format's %x
-- only goes to 2^31 on Windows.
function M.flat_owner(owner)
  local flat = owner:gsub('^mods/', ''):gsub('[^%w_%-]', '_')
  local _, slashes = owner:gsub('/', '')
  if slashes <= 2 then return flat end
  local h = 2166136261
  for i = 1, #owner do h = (h * 31 + owner:byte(i)) % 4294967296 end
  return flat .. '_' .. fmt('%04x%04x', floor(h / 65536), h % 65536)
end
-- the old flat file name (not one to one: two pairs could share one), read once to move a table over
function M.old_data_name(owner, name)
  return 'chef_data_' .. M.flat_owner(owner) .. '_' .. name .. '.lua'
end
-- chef.capture (util.capture): the render target I save and the file kind are the engine's usual ones (back_buffer,
-- a .dds), both unconfirmed on HD2 7.2 until my engine probe tries them; a mod's newest keep pictures are kept, and it
-- gets one every `every` seconds at most.
-- The engine's DDS writer is said to label the format wrong in the DX10 header (dxgiFormat, byte 128): an SDR back
-- buffer's B8G8R8A8 bytes as 28 (R8G8B8A8, red and blue swapped in a viewer) and an HDR one's R10G10B10A2 bytes as 0
-- (unknown: most viewers won't open it). Both are 4 bytes a pixel, so the format the header says is what tells them
-- apart; the pitch and the file's size only have to fit. fix: the wrong value -> the right one; right: the values I
-- leave alone (a build whose writer got it right). I look at a picture right after the save and then every look
-- seconds until it's whole, for wait seconds at most. name: the only files I ever open for this (mine, in my folder).
M.CAPTURE = { target = 'back_buffer', ext = '.dds', keep = 50, every = 1,
              fix = { [28] = 87, [0] = 24 }, right = { [87] = true, [24] = true }, look = 0.25, wait = 5,
              name = '^[%w_%-]+_capture_%d%d%.dds$' }

-- ------------------------------------------------------------------ install
-- ctx: services' table (log, guarded, fn_of, open, DIR, world, now ...). L: the loader's own parts: api, xyz, rect,
-- color, tri (an engine triangle or false), bitmap (with uv), key_index, notify, addons, boots(), frame_no(),
-- clock (seconds, for timing), os, new_world_hooks, bad_kinds, settings_text, TOP, granted(owner, what) (a grant's
-- flag, sandbox.lua), saved_get / saved_put (my saved values).
function M.install(ctx, L)
  local util = {}
  local log, guarded, fn_of, api, xyz = ctx.log, ctx.guarded, ctx.fn_of, L.api, L.xyz
  local world = ctx.world

  -- the calls known to end the game, refused before they reach the engine:
  -- runtime-built units (not a unit file; e.g. #ID[46cab355bd8d4d37], about 1,400 a mission): asking their position,
  -- rotation or meshes, or setting them, ends the game. Their box (Unit.box) is untried there, so I refuse it with the
  -- rest, as chef.ray_box never asks it. The set is the loader's, so its unit scan skips them too.
  local BAD_KINDS = L.bad_kinds
  local UNIT_ASKS = { ['Unit.world_position'] = true, ['Unit.world_rotation'] = true, ['Unit.world_pose'] = true,
                      ['Unit.num_meshes'] = true, ['Unit.mesh'] = true, ['Unit.local_position'] = true,
                      ['Unit.local_rotation'] = true, ['Unit.local_pose'] = true, ['Unit.set_local_position'] = true,
                      ['Unit.set_local_rotation'] = true, ['Unit.set_local_scale'] = true,
                      ['Unit.set_local_pose'] = true, ['Unit.set_mesh_visibility'] = true, ['Unit.box'] = true }
  -- (and every Unit.teleport_..., below)
  -- whole engine tables that aren't for mods: the Localizer (Localizer.lookup ends the game, and the game doesn't use
  -- the engine's Localizer, so there's nothing to look up), native code and the network
  local NEVER_TABLES = { Localizer = 'it ends the game', PluginManager = 'native code', Http = 'the network',
                         WebSocket = 'the network' }
  -- (the lobby, GameSession's writes, the console and save files, Application's file and settings writes, Steam's
  -- overlay and Steam id, Friends and Steam's voice chat too:
  -- sandbox.lua's engine_off and CALLS_OFF, handed in as L.engine_off and L.calls_off, the same rules a mod's own view
  -- of the engine follows)
  local engine_off, calls_off = L.engine_off or function() return false end, L.calls_off or {}
  -- and single calls: writing other players' game
  local NEVER = { ['GameSession.set_game_object_field'] = "other players' game",
                  ['GameSession.create_game_object'] = "other players' game",
                  ['GameSession.destroy_game_object'] = "other players' game",
                  ['GameSession.migrate_game_object'] = "other players' game",
                  ['GameSession.migrate_game_session_host'] = "other players' game",
                  ['Network.write_dump_tag'] = 'the network' }
  -- What a call name is, worked out once per name (chef.call is hot): false (fine), 'unit' (refused on some units),
  -- 'camera' (Unit.has_camera) or { why = the refusal }. class_of[0]: how many names it holds; past CLASS_CAP it starts
  -- over, so a mod passing ever new names can't grow it for good (names are strings: 0 is never one).
  local CLASS_CAP = 4096
  local class_of = { [0] = 0 }
  local function class(name)
    if type(name) ~= 'string' then return false end
    local c = class_of[name]
    if c ~= nil then return c end
    c = false
    do
      local t = name:match('^([%w_]+)%.')
      local f = t and name:sub(#t + 2)
      -- (a rule that says why is taken at its word: Application's writes, the console's tables ...)
      local off = t and engine_off(t)
      if off and type(off) ~= 'string' then off = 'the lobby' end
      local call_off = not off and t and calls_off[t] and calls_off[t](f)
      if call_off and type(call_off) ~= 'string' then call_off = 'the lobby or other players\' game' end
      local why = NEVER[name] or (t and NEVER_TABLES[t]) or off or call_off
      -- (a metamethod is no engine call: Application.__index would hand out the calls left out. And the function the
      -- name resolves to, by identity: one left out, held by another table under another name, is still left out)
      if not why and f and f:sub(1, 2) == '__' then why = 'not an engine call' end
      if not why then
        local fn = fn_of(name)                       -- (a function only: an engine constant isn't a call)
        local fo = type(fn) == 'function' and engine_off(fn)
        if fo then why = type(fo) == 'string' and fo or 'the lobby' end
      end
      if why then c = { why = name .. ' is not available to mods (' .. why .. ')' }
      elseif UNIT_ASKS[name] or name:match('^Unit%.teleport_') then c = 'unit'
      elseif name == 'Unit.has_camera' then c = 'camera' end
      if class_of[0] >= CLASS_CAP then class_of = { [0] = 0 } end
      class_of[name], class_of[0] = c, class_of[0] + 1
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
  -- worlds are kept, so the stamps can't pile up. A mod can keep a handle longer than that, though: refused in the
  -- second world, it would be unknown in the third and pass as new. So a unit refused as gone (by current() or
  -- util.gone()) goes in this world's carry set, and the next world's before is this world's stamps plus the carry
  -- set, which then starts empty. The limit: a gone unit stays refused in every later world as long as something asks
  -- about it at least once in each engine world; one nobody asks about for a whole world drops off after it, like any
  -- other stamp. The carry set holds only units asked about in this world, so it can't pile up either.
  local seen = { inst = -1, now = setmetatable({}, { __mode = 'k' }), before = setmetatable({}, { __mode = 'k' }),
    carry = setmetatable({}, { __mode = 'k' }) }
  local function roll()
    if seen.inst ~= world.instance then
      for u in pairs(seen.carry) do seen.now[u] = true end
      seen.inst, seen.before, seen.now = world.instance, seen.now, setmetatable({}, { __mode = 'k' })
      seen.carry = setmetatable({}, { __mode = 'k' })
    end
  end
  local function current(u)
    if u == nil or not world.stable then return false end
    roll()
    if seen.now[u] then return true end
    if seen.before[u] then seen.carry[u] = true; return false end
    seen.now[u] = true
    return true
  end
  -- a unit I know is new in this world (one a mod just spawned)
  local function fresh(u)
    roll()
    seen.now[u], seen.before[u], seen.carry[u] = true, nil, nil
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
  util.current, util.fresh, util.unit_kind = current, fresh, unit_kind
  -- a unit stamped in an engine world before this one (calling anything on it ends the game); a unit not stamped yet,
  -- in a world that hasn't settled, isn't known gone
  function util.gone(u)
    if u == nil then return true end
    roll()
    if seen.before[u] ~= nil and not seen.now[u] then seen.carry[u] = true; return true end
    return false
  end
  -- refused() without the settled-world rule, for a mod that asks about units before the world settles (the HD2Runtime
  -- look-alike): only a unit known gone or a runtime-built one, for the calls known to end the game on those.
  -- stamped: the caller already found u not gone and stamped it in this frame (the look-alike's alive check), so only
  -- the call is checked
  function util.unit_refused(owner, name, u, stamped)
    if not stamped then
      if util.gone(u) then return GONE end
      seen.now[u] = true                  -- stamped even before the world settles (the instance is already this one)
    end
    if class(name) ~= 'unit' then return nil end
    local k = unit_kind(u, owner)
    if k and BAD_KINDS[k] then
      local why = bad_why[k]
      if not why then why = 'a runtime-built unit (' .. k .. '): asking it that ends the game'; bad_why[k] = why end
      return why
    end
    return nil
  end

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
  -- The timers are only walked when one is due (or one was canceled), each list compacted in place.
  local timers, jobs, incoming, incoming_jobs = {}, {}, {}, {}
  local tsched = { next_at = math.huge, dirty = false }
  local function account(a, ms)
    a.ms = (a.ms or 0) + ms
    if ms > (a.max_ms or 0) then a.max_ms = ms end
    a.pm_ms = (a.pm_ms or 0) + ms
    if ms > (a.pm_max or 0) then a.pm_max = ms end
  end
  -- a mod's last error, kept on its record for its status line in my options menu: its first line, spaces squeezed,
  -- 120 characters at most (a traceback or a huge message isn't kept whole), and when (the line dims it once it's old)
  function util.note_error(a, err)
    a.last_error = (err_text(err):match('^[^\n]*'):gsub('%s+', ' ')):sub(1, 120)
    a.error_at = ctx.now()
  end
  local function failed(a, what, err)
    a.timer_errors = (a.timer_errors or 0) + 1
    util.note_error(a, err)
    if a.timer_errors <= 3 then log(fmt('[%s] %s error: %s', tostring(a.short or a.name), what, err_text(err))) end
  end
  -- (ctx.dog: the loader's hang watchdog, told which mod's call runs; see loader.lua. ctx.color_scope: the frame's
  -- color cache emptied first, so no mod's callback gets a Color asked for in an earlier one)
  local function run(a, what, fn, ...)
    if ctx.color_scope then ctx.color_scope() end
    local t0 = L.clock()
    local D = ctx.dog
    local po, ps, pl, pn
    if D then po, ps, pl, pn = D.enter(a, t0) end
    local ok, err = pcall(fn, ...)
    if D then D.leave(po, ps, pl, pn) end
    account(a, (L.clock() - t0) * 1000)
    if not ok then failed(a, what, err) end
    return ok
  end
  -- for services: a mod's callback (an event, on_change, after_startup) timed as that mod's own; and a mod's own
  -- call that ran other mods' callbacks, whose time already went to them
  function util.timed(a, fn, ...)
    if ctx.color_scope then ctx.color_scope() end
    local t0 = L.clock()
    local D = ctx.dog
    local po, ps, pl, pn
    if D then po, ps, pl, pn = D.enter(a, t0) end
    local ok, err = pcall(fn, ...)
    if D then D.leave(po, ps, pl, pn) end
    account(a, (L.clock() - t0) * 1000)
    if not ok then util.note_error(a, err) end
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
  -- is this a key name the keyboard knows (the loader's key_index answers false for one it doesn't); while the game
  -- has no index for F9 either (my own menu key: no keyboard yet) no name is called unknown
  function util.known_key(name)
    if type(name) ~= 'string' or L.key_index == nil then return false end
    if L.key_index(name) then return true end
    return not L.key_index('f9')
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
        if ctx.color_scope then ctx.color_scope() end
        local t0, list, fn = L.clock(), j.list, j.fn
        local D = ctx.dog
        local po, ps, pl, pn
        if D then po, ps, pl, pn = D.enter(j.a, t0) end
        for x = j.i + 1, last do
          local ok, err = pcall(fn, list[x], x)
          if not ok then j.errors = j.errors + 1; failed(j.a, 'spread', err) end
          if j.errors >= 20 then j.on = false; break end
        end
        if D then D.leave(po, ps, pl, pn) end
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
  -- the index (M.index): built once, a little each frame (util.index_step), the first time a mod asks or right after
  -- start-up when a mod declared HD2-Exclusive; nil and why while it's building or when it failed (logged once)
  local index = { built = nil, failed = false, co = nil, slice_end = 0 }
  local function owners_and_policies()
    local owners, policies, seen = {}, {}, {}
    for _, r in ipairs(L.found_rows and L.found_rows() or {}) do
      local o = owners[r.file]
      if not o then o = {}; owners[r.file] = o end
      if not seen[r.file .. '|' .. r.name] then seen[r.file .. '|' .. r.name] = true; o[#o + 1] = r.name end
      local pol = M.policies(r.src)
      local p = policies[r.name]
      if not p then p = { exclusive = {}, fallback = {} }; policies[r.name] = p end
      for _, x in ipairs(pol.exclusive) do p.exclusive[#p.exclusive + 1] = x end
      for _, x in ipairs(pol.fallback) do p.fallback[#p.fallback + 1] = x end
    end
    for _, o in pairs(owners) do sort(o) end
    return owners, policies
  end
  function util.index()
    if index.built then return index.built end
    if index.failed then return nil, 'the index could not be built (see the log)' end
    if not index.co then
      local owners, policies = owners_and_policies()
      local P = { patches = L.patches, owners = function() return owners end, policies = function() return policies end,
                  clock = L.clock, notify = L.notify, slice = function() return L.clock() >= index.slice_end end,
                  -- (asked when a notice is made: the loader may set util.mod_title after the build starts)
                  title = function(m) return util.mod_title and util.mod_title(m) end }
      if not co_lib then index.failed = true; return nil, 'unavailable' end
      index.co = co_lib.create(function() return M.index(ctx, P) end)
    end
    return nil, 'building'
  end
  -- a slice of the build each frame (2 ms at most)
  local function index_step()
    local co = index.co
    if not co or index.built or index.failed then return end
    index.slice_end = L.clock() + 0.002
    local ok, I = co_lib.resume(co)
    if not ok then
      index.failed, index.co = true, nil
      log('the index failed: ' .. err_text(I))
    elseif co_lib.status(co) == 'dead' then
      index.built, index.co = I, nil
    end
  end
  -- right after start-up: only when some mod wants to hear that its files lost (HD2-Exclusive), else on first use
  function util.index_at_startup()
    local _, policies = owners_and_policies()
    for _, p in pairs(policies) do if #p.exclusive > 0 then util.index(); return true end end
    return false
  end
  function util.frame()
    local now = ctx.now()
    if index.co then index_step() end
    timers_frame(now)
    jobs_frame()
    if util.dds_due then util.dds_frame(now) end          -- (only while a picture's header waits to be put right)
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
  local labels = {}                       -- ([0]: how many controller labels it keeps; names are strings)
  local function key_label(name)
    if type(name) ~= 'string' then return '' end
    local l = labels[name]
    if l == nil then
      -- a binding's combo ('ctrl+f6': 'Ctrl+' and the key's own name, kept once the key's is) or controller button
      -- ('pad:left_shoulder': 'Pad left shoulder', kept too: the menu asks it every frame it shows that binding, the
      -- first 256 names a session); only the key itself is asked of the keyboard
      local pad = name:match('^pad:(.+)$')
      if pad then
        l = 'Pad ' .. (pad:gsub('_', ' '))
        local n = labels[0] or 0
        if n < 256 then labels[name], labels[0] = l, n + 1 end
        return l
      end
      local w, rest = name:match('^(%a+)%+(.+)$')
      local m = (w == 'ctrl' and 'Ctrl') or (w == 'shift' and 'Shift') or (w == 'alt' and 'Alt') or nil
      if m then
        l = m .. '+' .. key_label(rest)
        if labels[rest] then labels[name] = l end
        return l
      end
      local ix = L.key_index(name)
      local s = ix and api('Keyboard.button_locale_name', ix)
      if type(s) ~= 'string' or s == '' then s = ix and api('Keyboard.button_name', ix) end
      l = (type(s) == 'string' and s ~= '') and s or name
      -- (kept only once the key resolved: before the keyboard answers, the raw name is shown and asked again later;
      -- key_index itself asks the engine at most every 2 s)
      if ix then labels[name] = l end
    end
    return l
  end
  util.key_label = key_label

  -- (a peer list can be keyed by peer id, or have holes: I count its pairs, not its length)
  local function count_pairs(t)
    local n = 0
    if type(t) == 'table' then for _ in pairs(t) do n = n + 1 end end
    return n
  end
  local function session_now()
    local now = ctx.now()
    if now < session.at + 1 then return session end
    session.at = now
    local s = api('Network.game_session')
    local me = api('Network.peer_id')
    session.me = me
    session.on, session.host, session.peers, session.joining = false, nil, 0, 0
    if s then
      session.on = api('GameSession.in_session', s) == true
      if session.on then
        session.host = api('GameSession.game_session_host', s)
        session.peers = count_pairs(api('GameSession.peers', s))
        -- (the players still joining: only once a mod asked for them, chef.joining or the players event; session.joins.
        -- An engine read untried in game, so nobody pays for it who doesn't use it)
        if session.joins then session.joining = count_pairs(api('GameSession.synchronizing_peers', s)) end
      end
    end
    return session
  end
  util.session_now = session_now

  -- The game's settings file comes from the loader's one cache of it (read again on a world change or a new screen
  -- size, else at most every 90 s); I only parse it again when its text changed.
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
  -- x on the edge from (xa, ya) to (xb, yb) at height y
  local function at(ya, xa, yb, xb, y) if yb == ya then return xa end return xa + (xb - xa) * (y - ya) / (yb - ya) end
  local function tri_spans(x1, y1, x2, y2, x3, y3, c, layer, step)
    -- sort by y, then fill one row of `step` pixels at a time, only the rows on the screen
    if y1 > y2 then x1, y1, x2, y2 = x2, y2, x1, y1 end
    if y1 > y3 then x1, y1, x3, y3 = x3, y3, x1, y1 end
    if y2 > y3 then x2, y2, x3, y3 = x3, y3, x2, y2 end
    if y3 - y1 < 0.5 then return end
    local sw, sh = ctx.screen()
    if not (finite(sw) and finite(sh)) then return end
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

  -- ---------------------------------------------------------------- a ray against a box (chef.ray_box)
  -- The game gives Lua no physics world, so there's no raycast against the world: only Math.ray_box_intersection, a
  -- ray against one box (its pose, a Matrix4x4, and its half sizes, a Vector3) -> the distance along the ray to where
  -- it goes in, or a negative number for a miss. I check every argument before the engine sees any of it and build
  -- the vectors it gets myself from the numbers I checked, so all it's ever handed is those and a Matrix4x4 the engine
  -- made. A value that names itself a Vector3 or a Matrix4x4 counts as one only with the metatable of one the engine
  -- made (engine_made): a mod's own table dressed up as one never reaches the engine, and a Vector3 it hands me is read
  -- under its own key, never mine. The ray goes through the mod's own chef.call too: one that ends the game is skipped
  -- for that mod from the next launch on.
  -- an engine value's kind from its own text ('Vector3(1, 2, 3)' -> 'Vector3', '[Unit ...]' -> 'Unit'); nil for a
  -- plain value
  local function value_kind(v)
    local t = type(v)
    if t ~= 'userdata' and t ~= 'table' then return nil end
    local ok, s = pcall(tostring, v)
    if not ok or type(s) ~= 'string' then return nil end
    return s:match('^%[(%a[%w_]*)') or s:match('^(%a[%w_]*)%(')
  end
  -- (a million meters: past that a double is still finite, but the engine's floats aren't what the mod meant)
  local function near(n) return finite(n) and n > -1e6 and n < 1e6 end
  -- is v (of that kind by its text) the engine's own: its metatable the one of a value the engine made, taken once
  -- (util.made: kind -> that metatable, false for none; also taken from the engine's values I make for a ray anyway.
  -- util.made.own: the engine's Vector3 and Matrix4x4 came with metatables of their own, two different ones, so the
  -- one a value carries names its kind; when they share one, only the text tells them apart)
  util.made = {}
  local function learn(e, kind)
    if util.made[kind] == nil then
      util.made[kind] = getmetatable(e) or false
      local a, b = util.made.Vector3, util.made.Matrix4x4
      util.made.own = (a and b and a ~= b) or nil
    end
  end
  local function engine_made(v, kind)
    if util.made[kind] == nil then
      local e = kind == 'Vector3' and api('Vector3', 0, 0, 0) or api('Matrix4x4.identity')
      if e == nil then return false end
      learn(e, kind)
    end
    return getmetatable(v) == (util.made[kind] or nil)
  end
  -- The text (a new string each time) is read only when the metatable can't tell me.
  -- v's kind ('Vector3', 'Matrix4x4', else what value_kind says)
  local function made_kind(v)
    if util.made.own then
      local mt = getmetatable(v)
      if mt == util.made.Vector3 then return 'Vector3' end
      if mt == util.made.Matrix4x4 then return 'Matrix4x4' end
    end
    return value_kind(v)
  end
  -- value_kind(v) == kind and engine_made(v, kind), the text left unread where the metatable already answers: not the
  -- engine's (one I've learned) is a no outright
  local function made_as(v, kind)
    local mt = util.made[kind]
    if mt ~= nil then
      if getmetatable(v) ~= (mt or nil) then return false end
      if util.made.own then return true end
    end
    return value_kind(v) == kind and engine_made(v, kind)
  end
  -- x, y, z of a Vector3 or a plain { x, y, z } / { x = , y = , z = }; nil unless all three are numbers within reach.
  -- call: the mod's chef.call, for a value the mod handed me (read under its own crash key, never mine)
  local function three(v, call)
    local x, y, z
    if type(v) == 'table' and (v.x ~= nil or v[1] ~= nil) then
      if v.x ~= nil then x, y, z = v.x, v.y, v.z else x, y, z = v[1], v[2], v[3] end
    elseif made_as(v, 'Vector3') then
      if call then x, y, z = call('Vector3.to_elements', v) else x, y, z = xyz(v) end
    end
    if near(x) and near(y) and near(z) then return x, y, z end
  end
  -- half sizes: one number (a cube) or three, each above 0
  local function halves(v, call)
    if type(v) == 'number' then
      if near(v) and v > 0 then return v, v, v end
      return nil
    end
    local x, y, z = three(v, call)
    if x and x > 0 and y > 0 and z > 0 then return x, y, z end
  end
  -- call: the mod's chef.call (before its refusals: nothing here is refused); asked: its unit asks (a unit of this
  -- world, alive, not a runtime-built one; crash keys per kind)
  local function ray_box(call, asked, from, dir, box, ext)
    local fx, fy, fz = three(from, call)
    if not fx then return nil, 'from: a Vector3 or { x, y, z } of finite numbers' end
    local dx, dy, dz = three(dir, call)
    if not dx then return nil, 'dir: a Vector3 or { x, y, z } of finite numbers' end
    -- (scaled to its biggest part first, so squaring it can't overflow), then to length 1: the answer is in meters
    local m = max(math.abs(dx), math.abs(dy), math.abs(dz))
    if m == 0 then return nil, 'dir: zero length' end
    dx, dy, dz = dx / m, dy / m, dz / m
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / len, dy / len, dz / len
    local pose, ex, ey, ez
    local plain = type(box) == 'table' and (type(box.x) == 'number' or type(box[1]) == 'number')
    local bk = not plain and made_kind(box) or nil      -- (the box's kind, worked out once)
    if plain or bk == 'Vector3' then
      -- the mod's own box: its middle (a Vector3 or a plain table) and, in a plain table, its yaw (radians about the up
      -- axis, 0 = facing +y, as chef.unit_rotation gives it). The ray goes into the box's own frame (its right
      -- (cos, -sin, 0), forward (sin, cos, 0), up) and the engine gets the box at the origin: an identity pose is the
      -- only engine value it needs.
      local cx, cy, cz = three(box, call)
      if not cx then return nil, 'box: its middle as a Vector3 or { x, y, z } of finite numbers' end
      local yaw = plain and box.yaw or 0
      if not near(yaw) then return nil, 'box: yaw is a number (radians)' end
      ex, ey, ez = halves(ext, call)
      if not ex then return nil, 'extents: half sizes above 0 (a number or { x, y, z })' end
      local s, c = sin(yaw), cos(yaw)
      local px, py = fx - cx, fy - cy
      fx, fy, fz = px * c - py * s, px * s + py * c, fz - cz
      dx, dy = dx * c - dy * s, dx * s + dy * c
      pose = api('Matrix4x4.identity')
      if pose == nil then return nil, 'no Matrix4x4.identity' end
      learn(pose, 'Matrix4x4')
    elseif ext == nil then
      -- a unit: its own box (Unit.box: its pose and half sizes)
      local k = bk
      if not (k == 'Unit' or (k == nil and type(box) == 'table')) then
        return nil, 'box: a unit, a Matrix4x4 with extents, or { x, y, z } with extents'
      end
      local p, h = asked('Unit.box', box)
      if p == nil then return nil, type(h) == 'string' and h or 'no box for that unit' end
      ex, ey, ez = three(h)
      if not (ex and ex >= 0 and ey >= 0 and ez >= 0) then return nil, 'no box for that unit' end
      pose = p
    else
      -- a pose the engine made (this frame: its values don't outlive it)
      if bk ~= 'Matrix4x4' or not engine_made(box, 'Matrix4x4') then
        return nil, 'box: a unit, a Matrix4x4 with extents, or { x, y, z } with extents'
      end
      ex, ey, ez = halves(ext, call)
      if not ex then return nil, 'extents: half sizes above 0 (a number or { x, y, z })' end
      pose = box
    end
    local vf, vd, ve = api('Vector3', fx, fy, fz), api('Vector3', dx, dy, dz), api('Vector3', ex, ey, ez)
    if not (vf and vd and ve) then return nil, 'no Vector3' end
    learn(vf, 'Vector3')
    local d, why = call('Math.ray_box_intersection', vf, vd, pose, ve)
    if d == nil and why ~= nil then return nil, why end
    if finite(d) and d >= 0 then return d end
    return nil
  end

  -- chef.capture's picture, for a mod whose grant carries capture (util.extend checks that). I make the engine call
  -- myself, with the real Application (the mod's own copy has no save_render_target, sandbox.lua), and everything
  -- it gets is mine: the render target (M.CAPTURE.target), the folder (mine, where chef.save_table writes) and the
  -- name, <mod>_capture_<nn><ext>, nn cycling 01 to M.CAPTURE.keep, so the oldest is written over and the folder
  -- never holds more than keep of a mod's pictures (a mod can't list or delete files, so a cap that refused once full
  -- would stop it for good). One a second at most (M.CAPTURE.every). The number goes on across launches (my saved
  -- values). -> the file's name (not its path), or nil and why.
  -- owner -> { at = when it last reached the engine, n = its number, flat = its name in file names, saved = its
  -- number's key in my saved values }
  util.shots = {}
  function util.capture(owner)
    local C, s = M.CAPTURE, util.shots[owner]
    if not s then
      local flat = M.flat_owner(owner)
      local key = ('capture.' .. flat):sub(1, 64)
      local n = L.saved_get and tonumber(L.saved_get(key)) or 0
      s = { n = (n >= 0 and n <= C.keep) and floor(n) or 0, flat = flat, saved = key }
      util.shots[owner] = s
    end
    local flat, key = s.flat, s.saved
    -- (not while a world loads or goes: the back buffer may be half torn down then, and a picture of a loading screen
    -- isn't what a mod asked for)
    if not world.stable then return nil, 'no world yet' end
    local now = ctx.now and ctx.now() or 0
    if s.at and now - s.at < C.every and now >= s.at then return nil, 'one capture a second at most' end
    -- (patch-proofing: a game build without the call, or one where it errors, answers nil and why, logged once)
    local fn = fn_of('Application.save_render_target')
    if fn == nil then
      once('capture_missing', 'chef.capture: this game build has no Application.save_render_target, so no pictures')
      return nil, 'this game build has no Application.save_render_target'
    end
    if not ctx.DIR then return nil, 'no folder for pictures' end
    local n = s.n % C.keep + 1
    local file = fmt('%s_capture_%02d%s', flat, n, C.ext)
    s.at = now
    -- (the picture 50 shots ago, often from an earlier launch, goes first: it's about to be written over anyway,
    -- and a whole old file sitting there would pass for the new one if the engine finishes writing a moment later.
    -- A save that fails doesn't use the number up, so the next one takes this name again.)
    -- If it's still there (held open by a picture viewer, or no os.remove), a header already right proves nothing.
    if L.os and L.os.remove then pcall(L.os.remove, ctx.DIR .. file) end
    local old = ctx.open and ctx.open(ctx.DIR .. file, 'rb')
    if old then pcall(old.close, old) end
    -- Every call breadcrumbed, not only a launch's first (guarded's): a save that ends the game later in a session (a
    -- world going, a bigger back buffer) is learned from too, and skipped for this mod from the next launch on.
    -- (L.crumb: the loader's trace; s.key built once)
    local crumb = L.crumb
    if crumb then
      if not s.key then s.key = owner .. '|Application.save_render_target' end
      crumb('> ' .. s.key)
    end
    local r, why = guarded(owner, 'Application.save_render_target', fn, C.target, ctx.DIR .. file)
    if crumb then crumb('< ' .. s.key) end
    if r == false or (r == nil and why ~= nil) then
      why = why ~= nil and tostring(why) or 'the engine said no'
      once('capture_failed:' .. owner, fmt('[%s] chef.capture: Application.save_render_target(%q, %s) failed: %s', owner,
        C.target, file, why))
      return nil, why
    end
    s.n = n
    if L.saved_put then L.saved_put(key, n) end
    -- (its name only: the folder's path carries the player's user name, and a log goes with bug reports)
    once('capture_first:' .. owner, fmt('[%s] chef.capture: the first picture this launch is %s, in my folder', owner, file))
    -- its header's format put right: now if the engine wrote it whole already, else on a later frame (util.dds_frame)
    if ctx.open and C.fix then
      local e = { owner = owner, file = file, path = ctx.DIR .. file, til = now + C.wait, next = now + C.look,
                  stale = old and true or nil }
      if not util.dds_look(e) then
        local due = util.dds_due or {}
        due[#due + 1] = e
        util.dds_due = due
      end
    end
    return file
  end

  -- One look at a picture's DDS header (e: owner, file, path). -> true when I'm done with it (put right, right
  -- already, or not a layout I know: left alone), false when it isn't whole yet (not there, held open by the engine,
  -- shorter than its header says, or a header not written yet). Only my own capture names in my own folder are opened.
  function util.dds_look(e)
    local C = M.CAPTURE
    if e.path ~= (ctx.DIR or '') .. e.file or not e.file:match(C.name) then return true end
    local f = ctx.open(e.path, 'rb')
    if not f then return false end
    local okh, h = pcall(f.read, f, 148)
    local oks, size = pcall(f.seek, f, 'end')
    pcall(f.close, f)
    if not (okh and type(h) == 'string' and #h == 148 and oks and type(size) == 'number') then return false end
    if h:sub(1, 4) == '\0\0\0\0' then return false end              -- (a writer that fills the header in last)
    local hi, wide, pitch, form = u32(h, 13), u32(h, 17), u32(h, 21), u32(h, 129)
    local whole = 148 + wide * hi * 4
    local known = h:sub(1, 4) == 'DDS ' and u32(h, 5) == 124 and h:sub(85, 88) == 'DX10' and wide >= 1 and hi >= 1
      and wide <= 16384 and hi <= 16384 and pitch == wide * 4 and size <= whole
      and (C.fix[form] ~= nil or C.right[form] ~= nil)
    if known and size < whole then return false end
    local where = fmt('[%s] chef.capture: %s', e.owner, e.file)
    if not known then
      once('capture_dds_odd:' .. e.owner, fmt('%s isn\'t a DDS layout I know (format %d, %dx%d, pitch %d, %d bytes); '
        .. 'I left it as the engine wrote it', where, form, wide, hi, pitch, size))
      return true
    end
    if C.right[form] then
      if e.stale then return false end      -- (maybe the old picture, the new one not written yet: I keep looking)
      once('capture_dds_right:' .. e.owner, fmt('%s: the engine wrote format %d, already right; I left it alone', where, form))
      return true
    end
    local to = C.fix[form]
    local g = ctx.open(e.path, 'r+b')
    if not g then return false end
    local oks2 = io_ok(pcall(g.seek, g, 'set', 128))
    local okw = oks2 and io_ok(pcall(g.write, g, string.char(to % 256, floor(to / 256) % 256, 0, 0)))
    local okc = io_ok(pcall(g.close, g))
    if okw and okc then
      once('capture_dds_fixed:' .. e.owner, fmt('%s: the engine wrote format %d; I set it to %d', where, form, to))
    else
      once('capture_dds_failed:' .. e.owner, fmt('%s: I couldn\'t set its format %d to %d', where, form, to))
    end
    return true
  end
  -- the pictures still being written: one look each every M.CAPTURE.look seconds, given up after M.CAPTURE.wait
  -- (one log line). util.frame calls this only while util.dds_due holds one.
  function util.dds_frame(now)
    local C, due = M.CAPTURE, util.dds_due
    for i = #due, 1, -1 do
      local e = due[i]
      if now >= e.next then
        e.next = now + C.look
        if util.dds_look(e) then table.remove(due, i)
        elseif now >= e.til then
          table.remove(due, i)
          once('capture_dds_wait:' .. e.owner, fmt('[%s] chef.capture: %s wasn\'t whole%s after %g seconds; I left '
            .. 'its header as the engine wrote it', e.owner, e.file, e.stale and ' (or was still the old picture)' or '',
            C.wait))
        end
      end
    end
    if #due == 0 then util.dds_due = nil end
  end

  -- ---------------------------------------------------------------- the helpers each mod gets
  function util.nearest_first(p, q) return p.d < q.d end      -- (chef.units_near's order)
  function util.extend(chef, a)
    local owner = a.name
    local base_call, base_call_kind = chef.call, chef.call_kind
    -- chef.call and chef.call_kind refuse the known game-ending calls and the ones mods shouldn't make (each refusal
    -- logged once per mod; no strings built for one already logged). said_refused[0]: how many names; past CLASS_CAP
    -- a new one is refused without a log line, so it can't grow for good either.
    local said_refused = { [0] = 0 }
    local function refuse(name, why)
      local s = said_refused[name]
      if not s then
        if said_refused[0] >= CLASS_CAP then return nil, why end
        s = {}; said_refused[name], said_refused[0] = s, said_refused[0] + 1
      end
      if not s[why] then s[why] = true; log(fmt('[%s] refused %s: %s', owner, name, why)) end
      return nil, why
    end
    -- PERF: chef.call is hot (hundreds a frame for a HUD mod). Each name's record (class_of: its class, worked out once)
    -- is read straight here, and the common Unit ask, a unit already seen in this engine world and of a kind known to
    -- be fine, is passed without a call to refused(); the instance compare stands in for roll()'s, so a unit from an
    -- engine world before this one never takes the shortcut. Anything else goes through refused() as before, the same
    -- answers. Then the engine call itself as the loader's chef.call makes it (guarded under the mod's crash key, the
    -- engine function looked up by its name each call), without going through that one too.
    function chef.call(name, ...)
      local c = class_of[name]
      if c == nil then c = class(name) end
      if c then
        local fine = false
        if c == 'unit' and world.stable and seen.inst == world.instance then
          local u = ...
          if u ~= nil and seen.now[u] then
            local k = kind_of[u]
            fine = k == false or (k ~= nil and not BAD_KINDS[k])
          end
        end
        if not fine then
          local why = refused(owner, name, ...)
          if why then return refuse(name, why) end
        end
      end
      return guarded(owner, name, fn_of(name), ...)
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
    -- (the answer and its entries are new tables, the mod's to keep; nothing else is made: the one watch asked for is
    -- looked at in place, and the order is util.nearest_first, one function for every call)
    function chef.units_near(x, y, z, r, w)
      local out = {}
      if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' or type(r) ~= 'number' then return out end
      local r2 = r * r
      for i = 1, w and 1 or #mine do
        local items = (w or mine[i]).items
        if items then
          for _, it in ipairs(items) do
            local dx, dy, dz = it.x - x, it.y - y, it.z - z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= r2 then out[#out + 1] = { unit = it.unit, kind = it.kind, x = it.x, y = it.y, z = it.z, d = sqrt(d2) } end
          end
        end
      end
      if #out > 1 then sort(out, util.nearest_first) end
      return out
    end
    -- a ray against one box (not the world: the game has no raycast for Lua): the distance in meters, nil for a miss,
    -- nil and why for a bad argument or a call the engine doesn't have or refused (ray_box above)
    function chef.ray_box(from, dir, box, extents) return ray_box(base_call, asked, from, dir, box, extents) end

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
    -- the players in the session (me too); and, on its own (a second result here would reach mods that pass
    -- chef.players() straight into a call), how many of them are still joining
    function chef.players()
      local s = session_now()
      if not s.on then return 1 end
      return max(1, s.peers)
    end
    function chef.joining()
      if not session.joins then session.joins, session.at = true, -100 end   -- (asked fresh the first time)
      local s = session_now()
      return s.on and s.joining or 0
    end
    -- (the players event says how many are joining too: listening to it asks for them as chef.joining does)
    local base_on = chef.on
    if type(base_on) == 'function' then
      function chef.on(event, fn)
        if event == 'players' and not session.joins then session.joins, session.at = true, -100 end
        return base_on(event, fn)
      end
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
    -- (three at a time per mod; the color three numbers, each kept within 0..255, else my usual light gray: a notice
    -- with anything else in it would stop every notice from drawing; 80 bytes at most, cut where a character starts)
    function chef.notify(text, seconds, r, g, b)
      if type(text) ~= 'string' or text == '' then return false end
      if L.notes_of(owner) >= 3 then return false end
      r, g, b = tonumber(r), tonumber(g), tonumber(b)
      if finite(r) and finite(g) and finite(b) then
        r, g, b = min(255, max(0, r)), min(255, max(0, g)), min(255, max(0, b))
      else
        r, g, b = 235, 235, 235
      end
      text = text:upper()
      local n = 80
      while n > 0 and n < #text and text:byte(n + 1) >= 128 and text:byte(n + 1) <= 191 do n = n - 1 end
      L.notify({ text = text:sub(1, n), dur = min(30, max(1, tonumber(seconds) or 4)), owner = owner, rgb = { r, g, b } })
      return true
    end

    -- 6 input
    -- (nothing while the loader's options menu is open: its search has the typing)
    function chef.typed()
      if util.menu_open and util.menu_open() then return '', NO_KEYS end
      return typed_now()
    end
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
          local p = M.flat_owner(o) .. '_'
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
    -- a picture of the screen, only for a mod its TRUSTED entry grants capture (util.capture): it hands in nothing,
    -- so nothing it passes (a path, a name, a render target) reaches the engine
    function chef.capture()
      if not (L.granted and L.granted(owner, 'capture')) then return refuse('chef.capture', 'not available to this mod') end
      return util.capture(owner)                     -- (it logs its own failures, once)
    end

    -- 8 the mods the loader found
    function chef.mods() return util.mod_list() end

    -- 9 which mod's copy of a resource the game loads (M.index: nil, 'building' until it's built, a little each frame)
    local index_view                    -- (made once, when the index is there)
    function chef.index()
      if index_view then return index_view end
      local I, why = util.index()
      if not I then return nil, why end
      local function copy(list)
        local out = {}
        for i, p in ipairs(list or {}) do
          local mods = {}
          for j, m in ipairs(p.mods or {}) do mods[j] = m end
          out[i] = { patch = p.patch or p.number, number = p.number, file = p.file, mods = mods }
        end
        return out
      end
      local X = {}
      function X.providers(t, id)
        local th = M.type_hex(t)
        if not th or type(id) ~= 'string' or not id:match('^%x+$') or #id ~= 16 then return {} end
        return copy(I.lookup(th, id:lower()))
      end
      function X.winner(t, id) return X.providers(t, id)[1] end
      function X.patches() return copy(I.patches) end
      local conflicts_copy                  -- (this mod's copy, made once: up to 5,000 entries)
      function X.conflicts()
        if conflicts_copy then return conflicts_copy, I.more end
        local out = {}
        for i, c in ipairs(I.conflicts) do
          out[i] = { type = c.type, id = c.id, policy = c.policy, winner = copy({ c.winner })[1], loser = copy({ c.loser })[1] }
        end
        conflicts_copy = out
        return out, I.more
      end
      index_view = X
      return X
    end
  end

  -- the frame budget behind chef.budget: the loader's own "Budget (ms)" row (util.budget_row, set by the loader;
  -- a mod over it is named in the log and marked in the monitor), 1 ms until it's there
  util.default_budget = function() return util.budget_row and util.budget_row.value or 1.0 end

  -- ---------------------------------------------------------------- the performance monitor
  -- The loader's "Performance monitor" row (util.perf_row, off by default): a panel (where "Monitor position" puts it)
  -- with each mod's cost ("Hide mods under N ms" folds the ones under their budget into one line). Every mod's time
  -- (its hooks, timers and spread work) goes into a.pm_ms / a.pm_max as it runs, a boot script's into b.pm_ms (and an
  -- HD2-Boot mod's timers, spread work and callbacks into its own record, b.a, shown on the same line), and the
  -- loader's own share of its update into pm.loader (all from the loader). Once a second I turn the last second into
  -- averages a frame: each mod's milliseconds and its share of the frame (from the game's own frame time), the worst
  -- single call, and the total. Off, it costs one check a frame; nothing is drawn or added up. Its own drawing (the
  -- loader's pixel font is rects, a few hundred a frame) is timed apart and shown on its own line, so it never counts
  -- against the loader or a mod.
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
  local function plain(t) return (tostring(t):upper():gsub('[^A-Z0-9%.,:%-%+/%%%(%)!%? \128-\255]', ' ')) end
  -- a boot script's name: an HD2-Boot mod's name, else its first comment line up to a bracket, else its patch file
  local function boot_name(b)
    if b.a and type(b.a.short) == 'string' then return b.a.short end      -- an HD2-Boot mod: its own name
    local t = b.title and b.title:match('^([^%(%[]+)')
    t = t and t:gsub('%s+$', '') or ''
    return t ~= '' and t ~= 'no title' and t or ('BOOT ' .. tostring(b.file or '?'))
  end
  -- a mod's name as my options menu shows it (util.mod_title, set by the loader: its title, else its short name with
  -- spaces), else its short name; the log's status line keeps the raw names
  local function pm_name(a) return util.mod_title and a.name and util.mod_title(a.name) or a.short or a.name end
  -- The lines are made again once a second into the same tables (pm.rows, the mods' rows; pm.out, the lines, each with
  -- its own cells table, l.own), so only the numbers that changed make new strings. The helpers, made once:
  -- the rows' order, costliest first, then by name
  function pm.by_cost(x, y) if x.avg ~= y.avg then return x.avg > y.avg end return x.name < y.name end
  -- line i of out: its text, its cells (a, b, c; or a, a table of fixed cells I never change) and its color
  function pm.put(out, i, left, color, a, b, c)
    local l = out[i]
    if not l then l = { own = {} }; out[i] = l end
    local cells = a
    if type(a) ~= 'table' then
      cells = l.own
      cells[1], cells[2], cells[3] = a, b, c
    end
    l[1], l[2], l[3] = left, cells, color
  end
  -- (the cells of the header line and of a mod that's off)
  pm.HEAD, pm.OFF = { 'MS', 'SHARE', 'WORST' }, { '', '', 'OFF' }
  local function pm_lines(now)
    local n = max(1, pm.frames)
    local frame_ms = (now - pm.t0) * 1000 / n
    local rows, nr, total = pm.rows or {}, 0, 0
    pm.rows = rows
    local budget = util.default_budget()               -- (the Budget row; a row's budget: its mod's chef.budget, else this)
    for _, a in ipairs(L.addons) do
      local avg = ((a.pm_ms or 0) - (a.pm_base or 0)) / n
      total = total + avg
      nr = nr + 1
      local r = rows[nr]
      if not r then r = {}; rows[nr] = r end
      r.name, r.avg, r.worst, r.on, r.budget = pm_name(a), avg, a.pm_max or 0, a.on, a.budget or budget
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
        -- (an HD2-Boot mod by its name in the menu; a plain boot script by its own title)
        if b.a and type(b.a.short) == 'string' then name = pm_name(b.a) end
        nr = nr + 1
        local r = rows[nr]
        if not r then r = {}; rows[nr] = r end
        r.name, r.avg, r.worst, r.on, r.budget = name, avg, worst, b.on ~= false,
          type(b.a) == 'table' and b.a.budget or budget
      end
    end
    for i = #rows, nr + 1, -1 do rows[i] = nil end
    sort(rows, pm.by_cost)
    local self = pm.self / n
    local loader = max(0, pm.loader / n - self)
    -- { left, { the MS, SHARE and WORST cells }, color }: 1 header, 2 frame line, 3 total, 4 a mod, 5 a heavy mod
    -- (at or over its budget), 6 off or dim. Each cell is right-aligned in its own column (the game's font isn't
    -- monospaced, so one string padded with spaces wouldn't line up); an empty cell is left out, so a mod that's off
    -- has its OFF at the line's right end, in the last column, never under MS. (MS: '%.2f'; SHARE: '%.1f%%' of the
    -- frame)
    local out, put = pm.out or {}, pm.put
    pm.out = out
    put(out, 1, fmt('FRAME %.1f MS  %d FPS', frame_ms, frame_ms > 0 and floor(1000 / frame_ms + 0.5) or 0), 2, pm.HEAD)
    put(out, 2, 'ALL MODS', 3, fmt('%.2f', total + loader), fmt('%.1f%%', frame_ms > 0 and (total + loader) / frame_ms * 100 or 0))
    local k = 2
    -- "Hide mods under N ms" (util.perf_hide): the mods running under their budget (the Budget row, or their own
    -- chef.budget) share one line, their sum and the worst call among them (a mod that's off keeps its line: OFF
    -- says something)
    local hide = util.perf_hide ~= nil and util.perf_hide.value == true
    local shown, low, low_worst, low_n = 0, 0, 0, 0
    for _, r in ipairs(rows) do
      if hide and r.on and r.avg < r.budget then
        low, low_n = low + r.avg, low_n + 1
        if r.worst > low_worst then low_worst = r.worst end
      elseif shown < 12 then
        shown, k = shown + 1, k + 1
        local left = (ctx.text_native and ctx.text_native()) and tostring(r.name):upper() or plain(r.name)
        if r.on then
          put(out, k, left, r.avg >= r.budget and 5 or 4, fmt('%.2f', r.avg),
            fmt('%.1f%%', frame_ms > 0 and r.avg / frame_ms * 100 or 0), fmt('%.1f', r.worst))
        else
          put(out, k, left, 6, pm.OFF)
        end
      end
    end
    if low_n > 0 then
      k = k + 1
      put(out, k, fmt('MODS UNDER %g MS', budget), 6, fmt('%.2f', low), fmt('%.1f%%', frame_ms > 0 and low / frame_ms * 100 or 0),
        fmt('%.1f', low_worst))
    end
    put(out, k + 1, 'LOADER', 4, fmt('%.2f', loader), fmt('%.1f%%', frame_ms > 0 and loader / frame_ms * 100 or 0))
    put(out, k + 2, 'THIS MONITOR', 6, fmt('%.2f', self), fmt('%.1f%%', frame_ms > 0 and self / frame_ms * 100 or 0))
    for i = #out, k + 3, -1 do out[i] = nil end
    return out
  end
  -- The panel, laid out once a second (when its numbers change) into a list of rects with a color index each; every
  -- frame only makes the few colors and draws the rects. The look matches the options menu: a dark panel in a thin
  -- yellow frame with a yellow bar on top, the title in yellow.
  local PM_COLORS = { { 255, 231, 16, 255 }, { 150, 255, 180, 255 }, { 255, 255, 255, 255 }, { 220, 222, 216, 255 },
                      { 255, 150, 90, 255 }, { 146, 154, 147, 255 }, { 9, 11, 10, 235 }, { 255, 231, 16, 150 } }
  -- (the green, light gray, orange and gray as I want them on screen, toned once here for the top world's curve:
  -- the menu's nav.tone, handed over as ctx.tone; the yellow, the white and the panel go in as they are. Installed
  -- without services.lua, as a test does: the colors as they are)
  do
    local tone = ctx.tone or function(r, g, b) return r, g, b end
    for _, i in ipairs({ 2, 4, 5, 6 }) do
      local c = PM_COLORS[i]
      c[1], c[2], c[3] = tone(c[1], c[2], c[3])
    end
  end
  -- The layout is the panel's 5 rects and one text per column of a line ({ x, y, text, color index }); each frame I
  -- draw them through ctx.text, whose fast path takes a whole text through one pcall.
  -- place (the "Monitor position" row's choice through PM_PLACE): 1 top right, 2 top left, 3 middle right, 4 middle
  -- left, 5 bottom right, 6 bottom left, 7 the middle of the screen, 8 Adjustable, where the player dragged it (fx, fy:
  -- its left edge and top edge as shares of the screen, so a new resolution keeps the spot); the game draws its HUD
  -- over anything of mine, so the player picks a spot it leaves free
  -- the row's choices (Adjustable first) as my place numbers
  local PM_PLACE = { 8, 1, 2, 3, 4, 5, 6, 7 }
  -- the layout's helpers, made once: a text put in the layout's next slot, a text's width at px, and the widest
  -- number each column takes
  function pm.txt(out, x, y, s, ci)
    local n = out.n + 1
    out.n = n
    local e = out.texts[n]
    if not e then e = {}; out.texts[n] = e end
    e[1], e[2], e[3], e[4] = x, y, s, ci
  end
  function pm.width(t, px) return ctx.text_width and ctx.text_width(t, px) or #t * 6 * px - px end
  pm.SAMPLES = { '00.00', '100.0%', '0000.0' }
  local function pm_layout(ls, w, h, place, fx, fy)
    local px = max(2, floor(h / 540 + 0.5))
    local rh, cols = 10 * px, 38
    local pw, ph = (cols * 6 + 10) * px, (#ls + 1) * rh + 5 * px
    local x0, y1
    if place == 7 then
      x0, y1 = floor((w - pw) / 2), floor((h + ph) / 2)
    elseif place == 8 then
      -- (kept on the screen whole: a spot saved on a bigger screen, or a panel grown by more mods)
      -- (never dragged yet: the middle)
      x0 = max(0, min(w - pw, fx and floor(fx * w + 0.5) or floor((w - pw) / 2)))
      y1 = max(min(ph, h), min(h, fy and floor(fy * h + 0.5) or floor((h + ph) / 2)))
    else
      local right = place % 2 == 1
      x0 = right and (w - pw - floor(w * 0.02)) or floor(w * 0.02)
      y1 = (place <= 2 and floor(h * 0.96)) or (place <= 4 and floor((h + ph) / 2)) or (ph + floor(h * 0.04))
    end
    local b = max(1, floor(px * 0.75))
    -- (one layout table, pm.lay, laid out again in place: its 5 rects and its texts, { x, y, text, color index },
    -- each kept for the next layout; the texts past this layout's last are dropped)
    local out = pm.lay
    if not out then
      out = { rects = { {}, {}, {}, {}, {} }, texts = {} }
      pm.lay = out
    end
    out.px, out.x0, out.y1, out.pw, out.ph, out.bar, out.n = px, x0, y1, pw, ph, rh + 2 * px, 0
    local R = out.rects
    R[1][1], R[1][2], R[1][3], R[1][4], R[1][5] = x0, y1 - ph, pw, ph, 7                -- panel
    R[2][1], R[2][2], R[2][3], R[2][4], R[2][5] = x0, y1 - ph, pw, b, 8                 -- frame
    R[3][1], R[3][2], R[3][3], R[3][4], R[3][5] = x0, y1 - ph, b, ph, 8
    R[4][1], R[4][2], R[4][3], R[4][4], R[4][5] = x0 + pw - b, y1 - ph, b, ph, 8
    R[5][1], R[5][2], R[5][3], R[5][4], R[5][5] = x0, y1 - 2 * px, pw, 2 * px, 1        -- the yellow bar on top
    local txt, width = pm.txt, pm.width
    local tx = 5 * px
    txt(out, x0 + tx, y1 - rh - px, 'PERFORMANCE MONITOR', 1)
    local y = y1 - 2 * rh - px
    -- three columns from the right edge, each as wide as its header or its widest number (measured), with a gap
    local gap = 5 * px
    local right, cw = pm.right or {}, pm.cw or {}
    pm.right, pm.cw = right, cw
    for c = 1, 3 do cw[c] = max(width(ls[1][2][c], px), width(pm.SAMPLES[c], px)) end
    right[3] = x0 + pw - tx
    right[2] = right[3] - cw[3] - gap
    right[1] = right[2] - cw[2] - gap
    local name_room = right[1] - cw[1] - gap - (x0 + tx)
    for _, l in ipairs(ls) do
      local cells = l[2]
      -- the name cut (measured) to the room left of the first column; the frame line may run over it (header row)
      local room = l[3] == 2 and (right[1] - cw[1] - (x0 + tx)) or name_room
      txt(out, x0 + tx, y + px, ctx.text_fit and ctx.text_fit(l[1], px, room) or l[1]:sub(1, max(0, floor((room + px) / (6 * px)))), l[3])
      for c, t in ipairs(cells) do
        if t ~= '' then txt(out, right[c] - width(t, px), y + px, t, l[3] == 2 and 6 or l[3]) end
      end
      y = y - rh
    end
    local T = out.texts
    for i = #T, out.n + 1, -1 do T[i] = nil end
    return out
  end
  -- The pause screen is the one time the game shows its own mouse cursor (Window.show_cursor: its map, the chat and
  -- the HUD never do; on the ship its menus that take the mouse do too). nil: no answer (no main window, an odd one).
  local function game_cursor()
    local win = api('Window.get_main_window')
    if win == nil then return nil end
    local v = api('Window.show_cursor', win)
    if type(v) ~= 'boolean' then return nil end
    return v
  end
  -- the game's cursor in screen pixels (from the bottom left, y up like the drawing) and whether the left button is
  -- down, read only while that cursor shows: the axis and button indexes asked once (again every 2 s while missing),
  -- the window's size once a second (the cursor counts the window's pixels, the drawing the screen GUI's)
  local function pm_mouse(now, w, h)
    local M = pm.mouse
    if not M then M = { at = -100, res_at = -100 }; pm.mouse = M end
    if M.cur == nil and now >= M.at then
      M.at = now + 2
      M.cur, M.left = api('Mouse.axis_index', 'cursor'), api('Mouse.button_index', 'left')
      if M.cur == nil or M.left == nil then M.cur, M.left = nil, nil end
    end
    if M.cur == nil then return nil end
    if now >= M.res_at then
      local a, b = api('Application.resolution')
      M.rw, M.rh, M.res_at = tonumber(a), tonumber(b), now + 1
    end
    local v = api('Mouse.axis', M.cur)
    if v == nil then return nil end
    local x, y = api('Vector3.to_elements', v)
    x, y = tonumber(x), tonumber(y)
    local rw, rh = M.rw, M.rh
    if not (x and y and rw and rh and rw > 0 and rh > 0) then M.res_at = 0; return nil end
    local b = api('Mouse.button', M.left)
    return x * w / rw, y * h / rh, type(b) == 'number' and b > 0.5
  end
  -- the dragged spot kept in the loader's saved values (shares of the screen, 4 places)
  local function pm_keep(lay, w, h)
    pm.fx, pm.fy = lay.x0 / w, lay.y1 / h
    if util.perf_put then
      util.perf_put('perf_x', floor(pm.fx * 10000 + 0.5) / 10000)
      util.perf_put('perf_y', floor(pm.fy * 10000 + 0.5) / 10000)
    end
  end
  -- the options menu asks whether a point is the monitor's while it's drawn over the menu (or being dragged there):
  -- the menu takes no hover or click there
  function util.pm_over(x, y)
    if not (pm.on and pm.over_menu and pm.rects and x) then return false end
    if pm.drag then return true end
    local l = pm.rects
    return x >= l.x0 and x < l.x0 + l.pw and y <= l.y1 and y >= l.y1 - l.ph
  end
  -- the layout, made again only when something it depends on changed
  local function pm_lay(w, h, native, place)
    if not pm.rects or pm.w ~= w or pm.h ~= h or pm.native ~= native or pm.place ~= place
       or (place == 8 and (pm.lfx ~= pm.fx or pm.lfy ~= pm.fy)) then
      pm.rects = pm_layout(pm.lines, w, h, place, pm.fx or nil, pm.fy or nil)
      pm.w, pm.h, pm.native, pm.place = w, h, native, place
      pm.lfx, pm.lfy = pm.fx, pm.fy
    end
  end
  function util.monitor_frame(now)
    local on = util.perf_row ~= nil and util.perf_row.value == true
    -- (pm.shown: the layout drawn this frame, nil while nothing is; my options menu reads it the next frame to keep its
    -- compact panel clear of the monitor)
    pm.shown = nil
    if on ~= pm.on then
      pm.on, pm.lines, pm.rects, pm.drag = on, nil, nil, nil
      if on then pm_reset(now) end
      log(on and 'performance monitor: on (each mod\'s average a frame, its share of the frame and its worst call; once a second)'
        or 'performance monitor: off')
    end
    if not on then return end
    if ctx.color_scope then ctx.color_scope() end     -- (the frame's colors, fresh: only while I'm on)
    pm.frames = pm.frames + 1
    if now >= pm.at and pm.frames > 0 then pm.lines, pm.rects = pm_lines(now), nil; pm_reset(now) end
    if not pm.lines then return end
    local t0 = L.clock()
    -- My full screen menu open (util.covering, set by the loader): not drawn. It covers the screen and the player is
    -- in it, not reading me; drawn over it I'd run into its header. The numbers are still added up, and I'm back the
    -- frame it closes or turns compact.
    if util.covering and util.covering() then
      pm.drag, pm.was_down, pm.over_menu = nil, true, false
      pm.self = pm.self + (L.clock() - t0) * 1000
      return
    end
    -- "Monitor on pause screen only" (util.perf_pause: 1 Off, 2 Missions, 3 Always): drawn only while the game shows
    -- its cursor (the numbers are still added up, so they're there the moment it opens), in a mission or everywhere;
    -- Missions leaves the ship as always. No answer from the game: drawn all the time, said once. The game is asked
    -- only when its answer is used (that row on, or the Adjustable position): every frame while its cursor shows or a
    -- drag is on (I'm gone the frame its cursor goes, and a drag follows it), else every 0.25 s, hidden waiting for the
    -- pause screen or drawn Adjustable without it (pm.cur_at: when to ask again, nil to ask the next frame).
    local place = PM_PLACE[util.perf_place and tonumber(util.perf_place.value) or 2] or 1
    local pp = util.perf_pause and tonumber(util.perf_pause.value) or 1
    local pause_only = pp == 3 or (pp == 2 and world.mission == true)
    local cursor
    if pause_only or place == 8 then
      if pm.cur_at and now < pm.cur_at then cursor = pm.cur
      else cursor, pm.cur_at = game_cursor(), nil; pm.cur = cursor end
    end
    if pause_only and cursor ~= true then
      if cursor == nil then
        if not pm.said_pause then
          pm.said_pause = true
          log('performance monitor: the game does not say when its pause screen is up; the monitor shows all the time')
        end
      else
        if not pm.cur_at then pm.cur_at = now + 0.25 end
        pm.drag, pm.was_down, pm.over_menu = nil, true, false
        pm.self = pm.self + (L.clock() - t0) * 1000
        return
      end
    end
    if (pause_only or place == 8) and cursor ~= true and not pm.drag then
      if not pm.cur_at then pm.cur_at = now + 0.25 end
    else
      pm.cur_at = nil
    end
    local w, h = ctx.screen()
    if pm.fx == nil and util.perf_get then          -- (the dragged spot, read once)
      pm.fx, pm.fy = tonumber(util.perf_get('perf_x')), tonumber(util.perf_get('perf_y'))
      if not (pm.fx and pm.fy) then pm.fx, pm.fy = false, false end
    end
    -- (laid out again when the screen size, the font, the spot or the dragged place changes: the game's font measures
    -- differently)
    local native = ctx.text_native and ctx.text_native() or false
    pm_lay(w, h, native, place)
    -- Position Adjustable (8): dragged by its title bar, with the game's cursor while that shows (the pause screen),
    -- or on the ship with my options menu's cursor while the menu has the mouse, in its compact look (the panel is then
    -- drawn over the menu, and the menu takes no hover or click on it: util.pm_over; the full screen look hides me).
    -- Never in a mission without the pause screen (the game shows no cursor there). A left press on the bar takes it,
    -- it follows the cursor while the button stays down, and where it's let go is kept. A button already down as a
    -- cursor appears is no press.
    local D = pm.drag
    local mx, my, down, over_menu
    if place == 8 then
      if util.menu_mouse then
        mx, my, down = util.menu_mouse()
        over_menu = mx ~= nil
      end
      if not over_menu and cursor == true then mx, my, down = pm_mouse(now, w, h) end
    end
    pm.over_menu = over_menu == true
    if mx then
      local lay = pm.rects
      if down and not pm.was_down and not D and mx >= lay.x0 and mx < lay.x0 + lay.pw
         and my <= lay.y1 and my >= lay.y1 - lay.bar then
        D = { dx = mx - lay.x0, dy = my - lay.y1 }
        pm.drag = D
      end
      if D and down then
        pm.fx, pm.fy = (mx - D.dx) / w, (my - D.dy) / h
        pm_lay(w, h, native, place)
      elseif D then
        pm.drag = nil
        pm_keep(pm.rects, w, h)
      end
      pm.was_down = down
    else
      if D then pm.drag = nil; pm_keep(pm.rects, w, h) end
      pm.was_down = true
    end
    local cs = pm.cs or {}
    pm.cs = cs
    -- ("Monitor opacity (%)": every color's alpha scaled by it, the panel and its text alike)
    local op = (util.perf_alpha and tonumber(util.perf_alpha.value) or 100) / 100
    for i, c in ipairs(PM_COLORS) do cs[i] = ctx.color(c[1], c[2], c[3], floor(c[4] * op + 0.5)) end
    -- (over the options menu's compact panel while it can be dragged there: the menu draws from 950, its cursor at 958)
    local top = ctx.TOP + (pm.over_menu and 955 or 940)
    local lay = pm.rects
    pm.shown = lay
    for _, r in ipairs(lay.rects) do ctx.rect(r[1], r[2], r[3], r[4], cs[r[5]], r[5] == 7 and top or top + 2) end
    for _, t in ipairs(lay.texts) do ctx.text(t[1], t[2], t[3], lay.px, cs[t[4]], top + 2) end
    pm.self = pm.self + (L.clock() - t0) * 1000
  end

  -- ---------------------------------------------------------------- the mod list and the health file
  -- Every mod I found, with what it's doing and why: chef.mods() hands out a fresh copy, and chef_loader_health.txt
  -- holds the same, one tab-separated line a mod, so a mod (a report, a menu) or a player can see why one isn't
  -- running. state: running, off, kept off (it crashed the game), not started (a requirement, a compile error ...) or
  -- stopped (too many errors). ms_avg / ms_max: its time a frame over the last status minute (nil before the first).
  -- start_ms / start_kb: its start (compile and first run) in ms, and the Lua heap's change over it in KB (nil for one
  -- that never ran).
  local function state_of(m)
    if m.state == 'running' and not m.on then return 'off' end
    return m.state or (m.on and 'running' or 'off')
  end
  function util.mod_list()
    local out = {}
    for _, m in ipairs(L.addons) do
      -- (its version is its record's, a.version, read when it started, as util.mod_facts and my menu have it: this call
      -- never reads the mod's table, so nothing in it can raise here)
      local v = type(m.version) == 'string' and m.version ~= '' and m.version or nil
      local req, lacks = {}, {}
      for i, q in ipairs(m.requires or {}) do req[i] = q end
      for i, q in ipairs(m.missing or {}) do lacks[i] = q end
      out[#out + 1] = { name = m.name, kind = 'addon', on = m.on == true, dev = m.dev == true, file = m.file,
                        version = v,
                        state = state_of(m), why = m.why, errors = m.errors or 0, ms_avg = m.last_avg, ms_max = m.last_max,
                        requires = req, missing = lacks, start_ms = m.start_ms, start_kb = m.start_kb }
    end
    for _, b in ipairs(L.boots()) do
      local r = b.a or b
      out[#out + 1] = { name = b.owner or b.file, kind = 'boot', on = b.on ~= false, file = b.file,
                        state = b.on == false and (r.state == 'stopped' and 'stopped' or 'off') or 'running',
                        why = r.why, errors = b.errors or 0, title = b.title, start_ms = r.start_ms, start_kb = r.start_kb }
    end
    local listed = {}                    -- (one that started later, after a reload, is listed once: as it is now)
    for _, m in ipairs(out) do listed[m.name] = true end
    for _, u in ipairs(L.unstarted and L.unstarted() or {}) do
      if not listed[u.name] then
        listed[u.name] = true
        out[#out + 1] = { name = u.name, kind = u.kind, on = false, file = u.file, state = u.state, why = u.why, errors = 0 }
      end
    end
    return out
  end
  -- PERF: the facts my options menu's status lines tell (state and why, version, errors, the start's cost), by name, as
  -- util.mod_list has them (a later entry of a name over an earlier one), each mod's in a table of its own from pool,
  -- filled again at every call: taken once a second while the menu is open, they make no garbage (the full list is a
  -- table of 17 fields a mod). by is emptied first; returned. A mod's version is its record's (a.version, read when it
  -- started), the one its switch row shows (nav.ver_row), so the two never disagree.
  function util.mod_facts(by, pool)
    for k in pairs(by) do by[k] = nil end
    for _, m in ipairs(L.addons) do
      local t = pool[m.name] or {}
      t.state, t.why, t.errors, t.start_ms, t.start_kb = state_of(m), m.why, m.errors or 0, m.start_ms, m.start_kb
      t.version = type(m.version) == 'string' and m.version ~= '' and m.version or nil
      pool[m.name], by[m.name] = t, t
    end
    for _, b in ipairs(L.boots()) do
      local r, name = b.a or b, b.owner or b.file
      local t = pool[name] or {}
      t.state = b.on == false and (r.state == 'stopped' and 'stopped' or 'off') or 'running'
      t.why, t.errors, t.start_ms, t.start_kb, t.version = r.why, b.errors or 0, r.start_ms, r.start_kb, nil
      pool[name], by[name] = t, t
    end
    -- (one that started later, after a reload, is listed once: as it is now)
    for _, u in ipairs(L.unstarted and L.unstarted() or {}) do
      if not by[u.name] then
        local t = pool[u.name] or {}
        t.state, t.why, t.errors, t.start_ms, t.start_kb, t.version = u.state, u.why, 0, nil, nil, nil
        pool[u.name], by[u.name] = t, t
      end
    end
    return by
  end
  local function field(v) return (tostring(v == nil and '' or v):gsub('[\t\r\n]', ' ')) end
  function util.health_text()
    -- (start_ms and start_kb at the end: readers of the older columns keep working)
    local out = { 'name\tstate\twhy\tkind\tversion\terrors\tms_avg\tms_max\tfile\tmissing\tstart_ms\tstart_kb' }
    for _, m in ipairs(util.mod_list()) do
      out[#out + 1] = concat({ field(m.name), field(m.state), field(m.why), field(m.kind), field(m.version), field(m.errors),
        m.ms_avg and fmt('%.3f', m.ms_avg) or '', m.ms_max and fmt('%.2f', m.ms_max) or '', field(m.file),
        field(m.missing and concat(m.missing, ' ') or ''), m.start_ms and fmt('%.1f', m.start_ms) or '',
        m.start_kb and fmt('%.0f', m.start_kb) or '' }, '\t')
    end
    return concat(out, '\n') .. '\n'
  end
  -- a file of mine written whole to a .tmp and put in place, like the settings (the health file)
  function util.write_file(path, text)
    local tmp = L.os and path .. '.tmp' or path
    local f = ctx.open(tmp, 'w')
    if not f then return false end
    local okw = io_ok(pcall(f.write, f, text))
    local okc = io_ok(pcall(f.close, f))
    if not (okw and okc) then
      if tmp ~= path and L.os and L.os.remove then pcall(L.os.remove, tmp) end   -- (a cut-off .tmp isn't left behind)
      return false
    end
    if tmp == path then return true end
    return util.replace(tmp, path)
  end
  function util.write_health() return util.write_file(ctx.DIR .. ctx.FILES .. '_health.txt', util.health_text()) end

  util.caps = { units = true, spawn = true, timers = true, budget = true, session = true, settings_file = true,
                shapes = true, sprite_sheets = true, notify = true, typed = true, key_labels = true, save_table = true,
                mods = true, health = true, index = true, joining = true,
                -- (only when the game has the engine call chef.ray_box makes, as it starts)
                ray_box = type(fn_of) == 'function' and fn_of('Math.ray_box_intersection') ~= nil }
  return util
end
return M
end)()
-- @@END utilities.lua@@
-- @@BEGIN sandbox.lua@@ (copied from src/chef_loader/sandbox.lua by tools/splice.py; edit that file, not this)
services.sandbox = (function()
-- Chef Shared Loader: the locked-down space every loader mod runs in
-- Every "-- HD2-Addon:" and "-- HD2-Boot:" mod gets an environment of its own built here. What it can't do from it:
--   * start programs, delete or rename files, quit the game through Lua (os.execute, io.popen, os.remove/rename/exit)
--   * load native code (package.loadlib, C modules through require) or compiled Lua (bytecode can be made to read and
--     write any memory, so loadstring and load take text only)
--   * reach past its own space: no debug library beyond traceback and getinfo, getfenv/setfenv only on its own
--     functions, _G is its own environment, no require of the game's modules (require('_G') would hand out everything),
--     no module() (package.seeall), and the metatables of its environment are locked
--   * open files outside a short list: it reads the game's settings folder, the game's data folder and its own files,
--     and writes only .log .txt .json .csv .dat .ini .marker .fatal files in the loader's folder, never the loader's
--     own files or another mod's saved tables
-- It still can use: everything the engine's script API offers (stingray, Unit, World ...), the chef helpers,
-- os.clock/time/date/getenv, reading and writing its own files.
-- Each mod gets its own copies of string, table, math, coroutine, bit, os and debug, and of every engine table
-- (stingray, Unit, World ...), so one mod changing a library or engine function changes it only for itself. The checks
-- below use functions taken before any mod runs, so no mod can bend them.
-- Engine tables that aren't for mods are out of its view too (stingray and the globals alike): native code
-- (PluginManager), other network routes (Http, WebSocket), the Localizer (it ends the game), the lobby (joining one and
-- writing what other players read: every *Lobby* table, SteamClient's lobby browser and Network's lobby calls),
-- GameSession's writes, the engine's console and save files (Console, CommandWindow, ConsoleHelp, SaveSystem, Cloud,
-- CloudToken), Application's calls that write files, change the player's saved settings or open a browser
-- (save_render_target, set_user_setting, open_url_in_browser ...), Steam's overlay and the player's Steam id
-- (Steam.open_url, Steam.user_id ...), the friend list and its invites (Friends), and Steam's voice chat (SteamVoip,
-- SteamVoipClient, SteamVoipRoom). A function left out stays out by identity too: reached through another table, a
-- metatable or a function __index, a mod finds nothing there (and chef.call refuses it by any name).
-- A mod the loader trusts by name (loader.lua, TRUSTED) is marked through sb.grant: chef.capture's pictures (which the
-- loader saves itself), never a file of its own the others can't write. The lobby, for those mods, goes through the
-- HD2Runtime look-alike (runtime.lua), whose Steam.user_id and Friends.playing_game are the loader's own calls (the
-- game's functions by name), never the mod's view of the engine.
-- A mod that replaces the game's boot script itself isn't a loader mod: the game hands it everything, with or without
-- me. Those run unrestricted (see loader.lua, "other mods' boot scripts").
-- Plain Lua 5.1 (no goto, no bit ops), like the rest of the loader.

local M = { version = '1.4.1' }

local type, pairs, ipairs, error, tostring, select, rawget, pcall = type, pairs, ipairs, error, tostring, select, rawget, pcall
local rawset = rawset
local collectgarbage = collectgarbage
local setmetatable, getmetatable = setmetatable, getmetatable
local s_find, s_match, s_gsub, s_sub, s_lower, s_byte, s_gmatch, s_rep = string.find, string.match, string.gsub,
  string.sub, string.lower, string.byte, string.gmatch, string.rep
local s_format = string.format
local t_concat = table.concat
local real_loadstring, real_setfenv, real_getfenv = loadstring, setfenv, getfenv

-- the file kinds a mod may write, and the Windows device names no file may be called
local MOD_EXT = { log = true, txt = true, json = true, csv = true, dat = true, ini = true,
                  marker = true, fatal = true }   -- (.marker and .fatal: a mod's own crash notes)
local DEVICES = { con = true, prn = true, aux = true, nul = true, ['conin$'] = true, ['conout$'] = true, ['clock$'] = true }
-- (0 to 9, and the superscripts 1 2 3 Windows also counts as their digits, in the ANSI code page)
for _, n in ipairs({ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '\185', '\178', '\179' }) do
  DEVICES['com' .. n] = true; DEVICES['lpt' .. n] = true
end
local LIBS = { 'string', 'table', 'math', 'coroutine', 'bit' }
local OS_KEEP = { 'clock', 'time', 'date', 'difftime', 'getenv' }
local REQUIRE_OK = { bit = 'bit', string = 'string', table = 'table', math = 'math', coroutine = 'coroutine' }
-- engine tables that aren't for mods (M.engine_off), and calls left out of engine tables mods otherwise keep
-- (M.CALLS_OFF): Network, GameSession and UnitSynchronizer keep only their reads (no lobby, connection or writes to
-- what other players see); Application loses what reaches the disk or past the game; Steam keeps only what it says
-- about this game and this client.
-- (utilities.lua refuses the same through chef.call.) engine_off answers why (a text) or false; a CALLS_OFF rule
-- answers true, or a text saying why, for a call that's left out.
-- Whole tables: Console, CommandWindow and ConsoleHelp run the engine's own commands (and CommandWindow opens a window
-- of its own, which can crash the game); SaveSystem, Cloud and CloudToken keep save files that outlast the game. No mod
-- I know of uses any of them. Friends is the friend list (other people's Steam ids, names, what they play) and the
-- invites sent from it; SteamClient has only lobby_browser, the way into other lobbies (SteamLobbyBrowser is off by
-- the Lobby rule already). SteamVoip, SteamVoipClient and SteamVoipRoom are Steam's voice chat: their calls create,
-- join and leave rooms, select the client's voice in and out, and add or remove other players in a room.
M.TABLES_OFF = { PluginManager = 'native code', Http = 'the network', WebSocket = 'the network',
  Localizer = 'it ends the game', Console = "the engine's commands", CommandWindow = "the engine's commands",
  ConsoleHelp = "the engine's commands", SaveSystem = 'files on disk', Cloud = 'files on disk', CloudToken = 'files on disk',
  Friends = "other players' Steam data", SteamClient = 'the lobby', SteamVoip = 'voice chat with other players',
  SteamVoipClient = 'voice chat with other players', SteamVoipRoom = 'voice chat with other players' }
-- The real functions left out (below and in CALLS_OFF), by identity: function -> why. Filled as I install (the tables
-- are the game's), so chef.call refuses one whatever table it's reached through (utilities.lua asks engine_off with
-- the function a name resolves to). Weak keys: a function the game drops isn't kept alive here.
M.OFF_FNS = setmetatable({}, { __mode = 'k' })
function M.engine_off(k)
  if type(k) ~= 'string' then return M.OFF_FNS[k] or false end
  local why = M.TABLES_OFF[k]
  if why then return why end
  if s_find(k, 'Lobby', 1, true) or s_find(k, 'GameServer', 1, true) then return 'the lobby' end
  return false
end
-- Application keeps everything but what leaves the game: files the engine writes (a render target saved as a picture,
-- a mesh exported, its own log restarted), the player's settings changed, applied or saved (user_settings.config), a
-- browser opened, and the performance HUD's command line. The names are the 7.2 game's (my engine probe 0.2.0 listed
-- all 70); the pattern (M.writes) catches one a game update adds that saves, writes, dumps, exports or captures. A deny
-- list, not an allow list like Network's: Application is mostly reads and in-memory calls mods use (worlds,
-- resolution, can_get, main_world, user_setting ...), and a read a game update renames mustn't vanish from mods.
-- (chef.capture, utilities.lua, is how a mod with the grant saves a picture: the loader picks the file.)
M.APP_OFF = { save_render_target = true, save_user_settings = true, save_win32_user_settings = true,
  set_user_setting = true, set_win32_user_setting = true, apply_user_settings = true, apply_win32_user_settings = true,
  open_url_in_browser = true, export_mesh_geometry = true, restart_file_log = true, performance_hud_command = true }
M.WRITES = "files on disk, the game's saved settings or programs outside the game"
function M.writes(f)
  f = s_lower(f)
  return (s_find(f, 'save', 1, true) or s_find(f, 'write', 1, true) or s_find(f, 'dump', 1, true)
    or s_find(f, 'export', 1, true) or s_find(f, 'capture', 1, true) or s_find(f, 'screenshot', 1, true)
    or s_find(f, 'url', 1, true) or s_find(f, 'browser', 1, true) or s_match(f, '^set_.*user_setting')
    or s_match(f, '^apply_.*user_setting')) ~= nil
end
-- Steam keeps what it says about this game and this client: the app id, whether Steam runs and is online, whether a
-- game is installed or owned, Steam's language, whether the overlay is up, and the player's own name (the game shows
-- it anyway). Left out: open_url (a page in the Steam overlay, as Application's browser call), install_event, user_id
-- (an id that names the person outside the game) and any call a game update adds, until it's known to be a read: an
-- allow list, like Network's.
M.STEAM_KEEP = { app_id = true, client_running = true, connected = true, is_installed = true, language = true,
  overlay_active = true, owns_app = true, user_name = true }
M.STEAM_WHY = 'the Steam overlay or the player\'s Steam id'
M.CALLS_OFF = {
  Application = function(f) return (M.APP_OFF[s_lower(f)] or M.writes(f)) and M.WRITES or false end,
  Steam = function(f) return not M.STEAM_KEEP[s_lower(f)] and M.STEAM_WHY or false end,
  -- Network keeps only what reads like a read (peer_id, game_session, is_ / has_ / get_ / num_ ...), and never a name
  -- that mentions the lobby or a connection: a new call in a game update is left out until it's known to be a read
  Network = function(f)
    f = s_lower(f)
    local read = f == 'peer_id' or f == 'game_session' or f == 'object_info' or s_match(f, '^is_') or s_match(f, '^has_')
      or s_match(f, '^get_') or s_match(f, '^num_')
    if not read then return true end
    return (s_find(f, 'lobby', 1, true) or s_find(f, 'server', 1, true) or s_find(f, 'join', 1, true)
      or s_find(f, 'connect', 1, true) or s_find(f, 'create', 1, true) or s_find(f, 'leave', 1, true)
      or s_find(f, 'send', 1, true) or s_find(f, 'dump', 1, true)) ~= nil
  end,
  -- GameSession the same way: its reads stay (in_session, peers, game_session_host, game_object_field / _exists /
  -- _owner / _is_type, objects_owned_by, other_peers, synchronizing_peers (the players still joining),
  -- unit_synchronizer, is_ / has_ / get_ / num_), every write to what
  -- other players see is left out, and so is a call a game update adds. (Network.object_info, a game object type's
  -- field list, is a read too.) unit_synchronizer hands out the session's unit <-> game object map (UnitSynchronizer
  -- below keeps only its lookups). game_object_field_batched (every field of an object at once) is a read too; it has
  -- crashed the game on other players' objects, so each mod's copy is wrapped (sb.guard_engine): the object must
  -- exist, and the loader learns from a crash in it (ctx.guard_read), so it can end the game once, not every launch.
  GameSession = function(f)
    f = s_lower(f)
    local read = f == 'in_session' or f == 'peers' or f == 'other_peers' or f == 'synchronizing_peers'
      or f == 'unit_synchronizer'
      or f == 'game_session_host' or f == 'game_object_field' or f == 'game_object_field_batched'
      or f == 'game_object_exists' or f == 'game_object_owner' or f == 'game_object_is_type' or f == 'objects_owned_by'
      or s_match(f, '^is_') or s_match(f, '^has_') or s_match(f, '^get_') or s_match(f, '^num_')
    if not read then return true end
    return (s_find(f, 'send', 1, true) or s_find(f, 'set', 1, true) or s_find(f, 'create', 1, true)
      or s_find(f, 'destroy', 1, true) or s_find(f, 'migrate', 1, true)) ~= nil
  end,
  -- UnitSynchronizer keeps its lookups (unit <-> game object id, is_ / has_ / get_ / num_); its spawns and destroys
  -- make game objects every player sees
  UnitSynchronizer = function(f)
    f = s_lower(f)
    local read = f == 'game_object_id_to_unit' or f == 'unit_to_game_object_id' or s_match(f, '^is_')
      or s_match(f, '^has_') or s_match(f, '^get_') or s_match(f, '^num_')
    if not read then return true end
    return (s_find(f, 'spawn', 1, true) or s_find(f, 'destroy', 1, true) or s_find(f, 'set', 1, true)
      or s_find(f, 'create', 1, true) or s_find(f, 'send', 1, true)) ~= nil
  end,
}

-- what a mod's key and mouse-button reads answer while the loader's options menu is open (sb.guard_engine)
local QUIET_READS = { pressed = false, released = false, any_pressed = false, any_released = false, button = 0,
                      keystrokes = true }

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
      -- (the part before the first dot, spaces after it dropped: Windows still opens "nul .txt" as the device)
      if DEVICES[s_lower((s_gsub(s_match(name, '^([^%.]*)'), ' +$', '')))] then return nil, 'device names are off limits' end
      names[#names + 1] = name
    end
  end
  if #names == 0 then return nil, 'not a file' end
  return names
end

-- ctx: G, io, os, debug, log, DIR (the loader's folder, with a trailing \), GAME_DIR (the game's settings folder,
-- %APPDATA%\Arrowhead\Helldivers2\, or nil), OLD_DIR (%LOCALAPPDATA%\, my files' old folder, or nil),
-- FILES ('chef_loader'), overrides (compat's xpcall and load)
function M.install(ctx)
  local G, io_, os_, dbg = ctx.G, ctx.io, ctx.os, ctx.debug
  local real_open = type(io_) == 'table' and io_.open or nil
  local io_type = type(io_) == 'table' and io_.type or function() return nil end
  local overrides = ctx.overrides or {}
  -- (the loader sets sb.module_of and sb.on_global once I'm installed; sb.claims: '<owner>|<file>' for each .log a mod
  -- opened to write in my folder this launch, the logs it may read back)
  local sb = { denied = 0, claims = {} }
  -- sb.chunk: my own chunk name. Spliced into loader.lua it's the loader's, the name its hang watchdog never stops code
  -- in (starter.dog.me), so a mod's loadstring and load can't give its code that name.
  if type(dbg) == 'table' and type(dbg.getinfo) == 'function' then
    local ok, info = pcall(dbg.getinfo, M.install, 'S')
    if ok and type(info) == 'table' and type(info.source) == 'string' then sb.chunk = info.source end
  end
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
  if ODIR == WDIR then ODIR = nil end
  -- the roots a mod's path may start with, in the order sb.check tries them: the loader's folder, the game's settings
  -- folder, my old folder, the game's data folder (false for one I don't have)
  sb.roots = { WDIR or false, GDIR or false, ODIR or false, 'data\\' }
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

  -- May a mod (owner: its name; nil reads as no mod's) open this path in this mode? Returns true, or nil and why.
  function sb.check(path, mode, owner)
    if mode == nil then mode = 'r' end
    if type(path) ~= 'string' or path == '' or #path > 400 or s_find(path, '%z') then return nil, 'not a file path' end
    if type(mode) ~= 'string' or not (s_match(mode, '^[rwa]%+?b?$') or s_match(mode, '^[rwa]b%+$')) then
      return nil, 'not a file mode'
    end
    local p = low(path)
    if s_sub(p, 1, 2) == '\\\\' then return nil, 'network and device paths are off limits' end
    local writes = s_find(mode, '[wa%+]') ~= nil
    -- which root (sb.roots)
    local root, rest
    for _, r in ipairs(sb.roots) do
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
      return nil, 'from the old %LOCALAPPDATA% folder mods read only their own .log .txt .json .csv .dat .ini .marker '
        .. '.fatal files'
    end
    if not writes then
      -- My folder is the game's settings folder, shared by every mod: a read there (or in my old folder) never gets the
      -- loader's own files (the settings, the crash state, the trace), another mod's saved tables or another mod's
      -- log. A mod's own saved tables start chef_data_<its name, as M.data_name writes it>__ (no other mod's can: "__"
      -- only ever stands after the name), and its own logs are the ones it opened to write this launch. Below the
      -- game's folder (crash reports, dumps) a mod reads only the game's own settings, saves\<id>_user_settings.config.
      if root ~= 'data\\' then
        if #names == 1 then
          if s_sub(file, 1, #OWN) == OWN or s_sub(file, 1, 11) == 'chef_loader' then
            return nil, 'the loader\'s own files are off limits'
          end
          if s_sub(file, 1, 10) == 'chef_data_' then
            local mine = type(owner) == 'string' and s_sub(owner, 1, 5) == 'mods/' and #owner > 5 and 'chef_data_'
              .. s_gsub(s_sub(owner, 6), '[^a-z0-9%-]', function(ch) return s_format('_%02x', s_byte(ch)) end) .. '__'
            if not (mine and s_sub(file, 1, #mine) == mine) then
              return nil, 'another mod\'s saved tables are off limits (chef.load_table reads a mod\'s own)'
            end
          end
          if ext == 'log' and not (type(owner) == 'string' and sb.claims[owner .. '|' .. file]) then
            return nil, 'mods read only the logs they write themselves'
          end
        elseif GDIR and s_sub(p, 1, #GDIR) == GDIR
          and not (#names == 2 and names[1] == 'saves' and s_find(file, '_user_settings%.config$')) then
          return nil, 'below the game\'s settings folder mods read only saves\\<id>_user_settings.config'
        end
      end
      return true, root, names, ext
    end
    if root ~= WDIR then return nil, 'mods write only in the loader\'s folder' end
    if #names ~= 1 then return nil, 'mods write only straight into the loader\'s folder, not below it' end
    if not (ext and MOD_EXT[ext]) then
      return nil, 'mods write only .log .txt .json .csv .dat .ini .marker .fatal files'
    end
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
    -- ffi and jit read as false, never as the game's: the game has neither since 7.2.0, so one in its globals is
    -- another loader's stand-in, which makes memory reads look like they work while they return nothing
    ffi = false, jit = false,
    -- the loaders' own tables in the game's globals (another loader's, or mine) read as false: each mod gets my
    -- look-alikes as its own (services.bind_lookalikes) and the chef table, and another loader's tables hand out
    -- what this space takes away (its open_log writes any path)
    __boot_mod_loader = false, CowboyBingusModLoader = false, HD2ModLoader = false, ModOptionsMenu = false,
    ModBindingsMenu = false, BingusRuntime = false, ChefSharedLoaderHandoff = false,   -- (ChefSharedLoader: read-only, kept)
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
    -- (an __index that's another table, not the table itself, would hand the calls left out straight back: the copy's
    -- own __index is the copy. One that's the table itself reaches the copy anyway: as_seen, below)
    if type(c.__index) == 'table' and c.__index ~= t then c.__index = c end
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
  local base_mt = { __index = G, __metatable = 'locked' }     -- (its __index narrowed below, once base is filled)
  setmetatable(base, base_mt)
  -- an engine object's metatable whose __index is one of those tables: a mod gets the table as it sees it
  -- (trimmed, or nothing), so the calls left out aren't a method call away
  -- (and so is a table of the real one's own __index that isn't the table itself: an object whose methods are there)
  local as_seen = {}
  for k, v in pairs(G) do
    if type(k) == 'string' and type(v) == 'table' and s_match(k, '^%u') and (engine_off(k) or M.CALLS_OFF[k]) then
      as_seen[v] = base[k]
      local i = rawget(v, '__index')
      if type(i) == 'table' and i ~= v and i ~= G and as_seen[i] == nil then as_seen[i] = base[k] end
    end
  end
  if type(S) == 'table' then
    for k, v in pairs(S) do
      if type(k) == 'string' and type(v) == 'table' and (engine_off(k) or M.CALLS_OFF[k]) then
        as_seen[v] = base.stingray[k] or false
        local i = rawget(v, '__index')
        if type(i) == 'table' and i ~= v and i ~= G and as_seen[i] == nil then as_seen[i] = base.stingray[k] or false end
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
  -- Every engine table (stingray's tables, a capitalized global holding the engine's own functions, and the trimmed
  -- ones above): each mod gets its own copy of each (sb.env), with a copy of its metatable (Vector3 and the like are
  -- called), so what a mod writes into one (a replaced engine function, a field of its own) stays in its copy, never
  -- reaching the game, the loader or another mod. Other capitalized globals (a boot script's tables) aren't copied.
  local is_engine = {}
  local s_dump = string.dump
  local function native_fns(t)                    -- (a table with a C function in it: string.dump refuses those)
    for _, f in pairs(t) do if type(f) == 'function' and not pcall(s_dump, f) then return true end end
    return false
  end
  if type(S) == 'table' then for _, v in pairs(S) do if type(v) == 'table' then is_engine[v] = true end end end
  for _, v in pairs(engine_names) do if type(v) == 'table' and not is_engine[v] and native_fns(v) then is_engine[v] = true end end
  -- (the real stingray reached from an engine table: the mod's own stingray)
  if type(S) == 'table' and base.stingray then as_seen[S] = base.stingray end
  for real, seen in pairs(as_seen) do is_engine[real] = true; if seen then is_engine[seen] = true end end
  if engine_names.stingray then is_engine[engine_names.stingray] = true end
  local raw_mt = type(dbg) == 'table' and type(dbg.getmetatable) == 'function' and dbg.getmetatable or getmetatable
  -- (and every table inside them and their metatables, however deep: a mod's copy holds its own copies of those too.
  -- The game's globals, its libraries and package are never copied (is_engine false): reached from an engine table,
  -- a mod finds its own (its environment, its library copies), or nothing)
  do
    is_engine[G], is_engine[base], is_engine[string_mt or G] = false, false, false
    for _, n in ipairs({ 'string', 'table', 'math', 'coroutine', 'bit', 'os', 'io', 'debug', 'package' }) do
      local lib = rawget(G, n)
      if type(lib) == 'table' then is_engine[lib] = false end
      if n == 'package' and type(lib) == 'table' and type(rawget(lib, 'loaded')) == 'table' then is_engine[lib.loaded] = false end
    end
    local level = {}
    for t, e in pairs(is_engine) do if e then level[#level + 1] = t end end
    while level[1] do
      local nextl = {}
      for _, t in ipairs(level) do
        for _, v in pairs(t) do
          if type(v) == 'table' and is_engine[v] == nil then is_engine[v] = true; nextl[#nextl + 1] = v end
        end
        local mt = raw_mt(t)
        if type(mt) == 'table' and is_engine[mt] == nil then is_engine[mt] = true; nextl[#nextl + 1] = mt end
      end
      level = nextl
    end
  end
  -- The real functions left out, by identity (a call off in a table mods keep, or any call of a table that's off):
  -- as_seen[fn] = false, so a mod's copy of anything that holds one (another engine table, a metatable, what a function
  -- __index answers: own, in sb.env) has nothing there, and M.OFF_FNS for chef.call. Never one mods also have under a
  -- name that's theirs (a function two tables share stays where it's allowed), and never a metamethod (engine tables
  -- may share one).
  do
    local off, kept = {}, {}
    for _, src in ipairs({ G, S }) do                -- (S may be nil: ipairs stops there)
      if type(src) == 'table' then
        for k, t in pairs(src) do
          -- (a table that's off or trimmed under another name too, an alias, counts by its real name only)
          if type(k) == 'string' and type(t) == 'table' and (src == S or s_match(k, '^%u'))
            and (as_seen[t] == nil or engine_off(k) or M.CALLS_OFF[k]) then
            local whole, rule = engine_off(k), M.CALLS_OFF[k]
            -- (and the methods behind a table __index of its own, as as_seen takes them above)
            local i = rawget(t, '__index')
            for _, part in ipairs({ t, type(i) == 'table' and i ~= t and i ~= G and i or nil }) do
              for f, fn in pairs(part) do
                if type(fn) == 'function' and type(f) == 'string' and s_sub(f, 1, 2) ~= '__' then
                  local why = whole or (rule and rule(f))
                  if why then off[fn] = type(why) == 'string' and why or "the lobby or other players' game"
                  else kept[fn] = true end
                end
              end
            end
          end
        end
      end
    end
    for fn, why in pairs(off) do
      if not kept[fn] then M.OFF_FNS[fn] = why; as_seen[fn] = false end
    end
  end
  -- (the engine's names in base read as false from now on: a mod that sets its stingray or Unit to nil finds nothing
  -- behind it, not the shared tables; each environment holds its own copies as its own keys)
  for k, v in pairs(engine_names) do if is_engine[v] then base[k] = false end end
  -- Lua's own base functions as each mod's own keys too: mods written for the old loaders check
  -- rawget(_G, 'unpack') and the like before hooking anything. Never the game's update, render and shutdown, so a mod
  -- chaining rawget(_G, 'update') never finds (and calls) the game's own.
  local plain = {}
  for _, k in ipairs({ 'assert', 'collectgarbage', 'dofile', 'error', 'gcinfo', 'ipairs', 'loadfile', 'module', 'next',
    'pairs', 'pcall', 'print', 'rawequal', 'rawget', 'rawset', 'select', 'setmetatable', 'tonumber', 'tostring',
    'type', 'unpack', 'xpcall', '_VERSION' }) do
    local v = base[k]                                -- (base's own, else the game's)
    if type(v) == 'function' or type(v) == 'string' then plain[k] = v end
  end
  -- what sb.env makes each mod's own reads as false behind it: a mod that sets one of them to nil finds nothing there,
  -- never the game's own (its io, os, debug, require, loadstring, getfenv / setfenv, _G, or the shared libraries)
  for _, k in ipairs(LIBS) do if rawget(base, k) == nil then rawset(base, k, false) end end
  for _, k in ipairs({ 'os', 'io', 'debug', 'package', 'require', 'load', 'loadstring', 'getfenv', 'setfenv',
    'getmetatable', 'newproxy', 'xpcall', '_G' }) do
    if rawget(base, k) == nil then rawset(base, k, false) end
  end
  -- The game's other lower case globals (whatever its engine adds next to Lua's own), taken once, here: each mod gets
  -- a value as it is and a table as its own copy (sb.env), so nothing a mod writes into one reaches the game or another
  -- mod. From here on a lower case name behind base is nothing: the game's callbacks (init, update, render, shutdown:
  -- mine) and whatever is set later (a boot script's) aren't reached. Capitalized names still read the game's.
  local CALLBACKS = { init = true, update = true, render = true, shutdown = true }
  local extra = {}
  for k, v in pairs(G) do
    if type(k) == 'string' and not s_match(k, '^%u') and not CALLBACKS[k] and rawget(base, k) == nil and plain[k] == nil then
      plain[k] = v
      local n = 0
      if type(v) == 'table' then
        -- (what a mod's copy holds: the entries of every table reached from it and their metatables, counted up to
        -- 10,000; the game's globals, the libraries and the engine's tables aren't copied with it, so not counted)
        local seen, todo = { [v] = true }, { v }
        local function reach(x)
          if type(x) == 'table' and not seen[x] and is_engine[x] == nil and as_seen[x] == nil and x ~= string_mt then
            seen[x] = true; todo[#todo + 1] = x
          end
        end
        while todo[1] and n < 10000 do
          local t = table.remove(todo)
          reach(raw_mt(t))
          for _, x in pairs(t) do
            n = n + 1
            if n >= 10000 then break end
            reach(x)
          end
        end
      end
      extra[#extra + 1] = k .. (type(v) == 'table' and (' (table, ' .. (n >= 10000 and '10,000+' or n) .. ' entries)') or '')
    end
  end
  if extra[1] and ctx.log then
    table.sort(extra)
    ctx.log('the game\'s other lower case globals, each mod its own: ' .. t_concat(extra, ', '))
  end
  base_mt.__index = function(_, k)
    if type(k) == 'string' then
      local b = s_byte(k, 1)                         -- (a byte test: this runs on every miss past base)
      if not (b and b >= 65 and b <= 90) then return nil end
    end
    return G[k]
  end
  -- sb.on_global(env, key, value): told of each new global a mod sets (the runtime look-alike shares some between its
  -- mods); the assignment itself always happens first
  local env_mt = { __index = base, __metatable = 'locked', __newindex = function(t, k, v)
    rawset(t, k, v)
    local f = sb.on_global
    if f then pcall(f, t, k, v) end
  end }

  -- ---------------------------------------------------------------- what a trusted mod gets beyond that
  -- grants[owner] = { capture = true (chef.capture's pictures, which the loader saves itself: the mod's own
  -- Application still has no save_render_target) }. Set before the mod's environment is made. A grant opens no file:
  -- a trusted mod's io and os are every mod's (no os.remove or os.rename, no write in data\).
  local grants = {}
  function sb.grant(owner, g) if type(owner) == 'string' and type(g) == 'table' then grants[owner] = g end end
  -- is this mod one the loader trusts (granted more)?
  function sb.trusted(owner) return grants[owner] ~= nil end
  -- does its grant carry this flag (capture: chef.capture's pictures)? Being trusted for something else isn't enough.
  function sb.granted(owner, what) local g = grants[owner]; return g ~= nil and g[what] == true end
  -- One mod's environment. owner: its name, for the log.
  -- The engine reads mods may make that have ended the game in some cases, in this mod's own copy of their table:
  -- GameSession.game_object_field_batched answers only for an object that exists (a whole number id), and goes
  -- through the loader's guard (ctx.guard_read: skipped once it crashed a launch for this mod, learned from
  -- otherwise). Without the guard it stays out.
  -- (the game has GameSession only inside stingray, s3d being the same table; a capitalized global of that name, where
  -- there is one, is the same copy)
  function sb.guard_engine(owner, env)
    local st = rawget(env, 'stingray')
    local gs = (type(st) == 'table' and rawget(st, 'GameSession')) or rawget(env, 'GameSession')
    local real = type(gs) == 'table' and rawget(gs, 'game_object_field_batched')
    if type(real) == 'function' then
      local guard = ctx.guard_read
      if type(guard) ~= 'function' then rawset(gs, 'game_object_field_batched', nil)
      else
        local exists = rawget(gs, 'game_object_exists')
        rawset(gs, 'game_object_field_batched', function(session, id, ...)
          if type(id) ~= 'number' or id ~= id or id < 0 or id % 1 ~= 0 then return nil end
          if type(exists) ~= 'function' then return nil end
          local ok, e = pcall(exists, session, id)
          if not ok or e ~= true then return nil end
          return guard(owner, 'GameSession.game_object_field_batched', id, real, session, id, ...)
        end)
      end
    end
    -- While my options menu is open (ctx.menu_open), the keys and mouse buttons are the menu's: this mod's Keyboard
    -- and Mouse reads of them answer nothing pressed (and no keystrokes), so typing a search or picking a row doesn't
    -- fire a mod's hotkey. The axes (the cursor, the mouse's movement) answer as always.
    local quiet = ctx.menu_open
    if type(quiet) ~= 'function' or type(st) ~= 'table' then return end
    for _, dev in ipairs({ 'Keyboard', 'Mouse' }) do
      local t = rawget(st, dev)
      if type(t) == 'table' then
        for name, none in pairs(QUIET_READS) do
          local f = rawget(t, name)
          if type(f) == 'function' and (name ~= 'keystrokes' or dev == 'Keyboard') then
            if name == 'keystrokes' then
              rawset(t, name, function(...) if quiet() then return {} end return f(...) end)
            else
              rawset(t, name, function(...) if quiet() then return none end return f(...) end)
            end
          end
        end
      end
    end
  end
  function sb.env(owner)
    local env = setmetatable({}, env_mt)
    envs[env] = owner
    env._G = env
    for _, n in ipairs(LIBS) do
      local lib = rawget(G, n)
      if type(lib) == 'table' then env[n] = copy(lib) end
    end
    -- (string.dump only makes bytecode, which load and loadstring refuse anyway)
    if env.string then env.string.dump = nil end
    local string_view = { __index = env.string }     -- getmetatable('') gives this, not the game's
    -- this mod's copies of the engine tables (one per table: its Unit and its stingray.Unit are the same copy), and
    -- what the game's own globals and libraries are for it (its environment, its copies)
    local mine, real_by_copy, fwd, later = { [G] = env }, setmetatable({}, { __mode = 'k' }), {}, {}
    for _, n in ipairs(LIBS) do local lib = rawget(G, n); if type(lib) == 'table' then mine[lib] = env[n] end end
    if string_mt then mine[string_mt] = string_view end
    -- own(t): this mod's copy of an engine table; any = true: of any table (a metatable, its __index / __newindex,
    -- an engine object's methods). Every table reached through a copy is copied too (one copy per table, cycles
    -- included: mine is filled before the fields), so nothing reached through a copy is the real one; a real table
    -- trimmed for mods gives its trimmed view (or nothing); the game's globals and libraries give the mod's own (or
    -- nothing). d: how deep; past 200 tables down a chain, a copy is made empty and filled after the outermost call,
    -- so a long chain never runs out of stack.
    local own
    -- (c gets a copy of t's metatable: called as the real one, the real table of the copy called gets its __call, or
    -- the metatable's own __call when the real table's metatable has changed since; one forwarder per metatable, shared
    -- by the tables that share it; a locked metatable gets one too)
    local function own_mt(t, c, d)
      local mt = raw_mt(t)
      if mt == nil then return end
      local m = type(mt) == 'table' and own(mt, true, d + 1) or {}
      if type(mt) ~= 'table' then
        -- (a locked metatable: read as the real one, what it reads copied)
        m.__index = function(_, k) return own(t[k], true) end
      end
      if type(m) == 'table' and not fwd[m] and (type(mt) ~= 'table' or rawget(mt, '__call') ~= nil) then
        local orig = type(mt) == 'table' and rawget(mt, '__call') or nil
        fwd[m] = true
        rawset(m, '__call', function(self, ...)
          local r = real_by_copy[self]
          if r and raw_mt(r) == mt then return r(...) end
          if orig then return orig(self, ...) end
          error('attempt to call a table value', 2)
        end)
      end
      if type(m) == 'table' then setmetatable(c, m) end
    end
    -- (a function __index in a table I copy: called with the real table of a copy, and what it answers goes through own,
    -- so a call left out, or a table that's off, isn't one __index(nil, name) away)
    local function screened(fn)
      return function(s, k) return own((fn(real_by_copy[s] or s, k))) end
    end
    function own(t, any, d)
      if type(t) ~= 'table' then
        if as_seen[t] == false then return nil end   -- (a real function left out, by identity)
        return t
      end
      local c = mine[t]
      if c ~= nil then return c end
      if is_engine[t] == false then return nil end
      if as_seen[t] ~= nil then
        if not as_seen[t] then return nil end
        return own(as_seen[t], true, d)
      end
      if not (any or is_engine[t]) then return t end
      c = {}
      mine[t], real_by_copy[c] = c, t
      if d and d > 200 then later[#later + 1] = t; return c end
      for k, v in pairs(t) do
        if k == '__index' and type(v) == 'function' then c[k] = screened(v) else c[k] = own(v, true, (d or 0) + 1) end
      end
      own_mt(t, c, d or 0)
      if not d then
        -- (the copies left empty down a long chain, filled now, each from the top again)
        while later[1] do
          local q = table.remove(later)
          local cq = mine[q]
          for k, v in pairs(q) do
            if k == '__index' and type(v) == 'function' then cq[k] = screened(v)
            elseif not (k == '__call' and fwd[cq]) then cq[k] = own(v, true, 1) end
          end
          own_mt(q, cq, 0)
        end
      end
      return c
    end
    for k, v in pairs(engine_names) do rawset(env, k, own(v)) end
    sb.guard_engine(owner, env)
    -- the metatables of this mod's own newproxy(true) userdata: its own, handed back as they are
    local made, np = setmetatable({}, { __mode = 'k' }), G.newproxy
    if type(np) == 'function' then
      env.newproxy = function(x)
        local u = np(x)
        if x == true then made[getmetatable(u)] = true end
        return u
      end
    end
    local seen_mt = setmetatable({}, { __mode = 'k' }) -- an engine metatable -> this mod's copy of it
    local asked_native = false                       -- this mod's first require('ffi'/'jit') is logged
    env.getmetatable = function(o)
      local mt = getmetatable(o)
      if mt ~= nil and mt == string_mt then return string_view end
      if type(o) == 'userdata' and io_type(o) then return nil end   -- file handles: their methods are shared
      -- an engine object's metatable (any userdata's, or one whose __index is an engine table): a copy, its __index
      -- this mod's copy of the engine table (trimmed, or nothing), so the calls left out aren't a method call away and
      -- nothing written there reaches the real one
      local idx = type(mt) == 'table' and rawget(mt, '__index')
      if type(mt) == 'table' and not made[mt] and (type(o) == 'userdata' or (idx and (as_seen[idx] ~= nil or is_engine[idx]))) then
        local c = seen_mt[mt]                        -- one copy per metatable (objects of a kind share it)
        if not c then
          if idx and as_seen[idx] ~= nil then
            c = {}
            seen_mt[mt] = c
            for k, v in pairs(mt) do if k ~= '__index' then c[k] = own(v, true) end end
            c.__index = own(as_seen[idx]) or nil
          else
            c = own(mt, true)                        -- (its __index / __newindex, and mt.__index = mt, copied with it)
            seen_mt[mt] = c
          end
        end
        return c
      end
      return mt
    end
    local os_c = {}
    if type(os_) == 'table' then for _, k in ipairs(OS_KEEP) do os_c[k] = os_[k] end end
    env.os = os_c
    -- package.loaded: the mod's own entries, and behind them (read only) the other addons' modules, from the loader
    -- (sb.module_of: a module, true while it starts or when it returned nothing, nil when it isn't running), so an
    -- "is that mod installed?" check and require('mods/<author>/<name>') find a running mod
    local loaded = setmetatable({}, { __metatable = 'locked', __index = function(_, name)
      local f = sb.module_of
      if type(f) ~= 'function' or type(name) ~= 'string' then return nil end
      local ok, v = pcall(f, name)
      if ok then return v end
    end })
    env.package = { loaded = loaded, preload = {}, path = '', cpath = '' }

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
    -- A mod's own file straight in %LOCALAPPDATA% (where mods for other loaders keep their logs and settings): kept in
    -- my folder instead, under the same name, said once per mod. A read finds it there, else in %LOCALAPPDATA% (the
    -- fallback below), so settings saved before carry over.
    local moved = false
    -- (the path to open, and the file's name when it's one moved to my folder)
    local function redirect(path)
      if not (ODIR and ctx.DIR and type(path) == 'string') then return path end
      local p = low(path)
      if s_sub(p, 1, #ODIR) ~= ODIR then return path end
      local name = s_sub(path, #ODIR + 1)
      local ext = s_match(s_lower(name), '%.(%w+)$')
      if name == '' or s_find(name, '[\\/]') or not (ext and MOD_EXT[ext]) then return path end
      return ctx.DIR .. name, name
    end
    -- (said once per mod, when the first such file passes my check)
    local function said_moved(name)
      if name and not moved and ctx.log then
        moved = true
        ctx.log(s_format('[%s] its files in %%LOCALAPPDATA%% are kept in my folder instead (%s first)', owner, name))
      end
    end
    local io_c = {
      open = function(path, mode)
        local asked, moved_name = path, nil
        path, moved_name = redirect(path)
        local ok, root, names, ext = sb.check(path, mode, owner)
        if ok then
          said_moved(moved_name)
          -- (a log it writes is one it may read back: sb.check)
          if ext == 'log' and mode and s_find(mode, '[wa%+]') and type(owner) == 'string' then
            sb.claims[owner .. '|' .. names[1]] = true
          end
        end
        if not ok then return deny('open', asked, mode, root) end
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
        local asked, moved_name = path, nil
        path, moved_name = redirect(path)
        if moved_name then
          -- (not in my folder yet: read where it was; only a path my check passes is ever opened)
          local f = sb.check(path, 'r', owner) and real_open and real_open(path, 'r')
          if f then f:close(); said_moved(moved_name) else path = asked end
        end
        local ok, why = sb.check(path, 'r', owner)
        if not ok then deny('read', path, 'r', why); error(why, 2) end
        return io_.lines(path)
      end,
      type = io_type,
      close = function(f) if f ~= nil then return f:close() end end,
      write = function(...) return io_.write(...) end,
      popen = blocked('io.popen'), tmpfile = blocked('io.tmpfile'), input = blocked('io.input'),
      output = blocked('io.output'),
    }
    env.io = io_c
    -- code it loads: text only, and it lands in this environment (or one the mod hands load); never under my own chunk
    -- name (sb.chunk: the loader's, whose code the hang watchdog leaves running)
    local NAMED = 'that chunk name is the loader\'s own (off limits to Chef Shared Loader mods)'
    -- Nor under another mod's: my menu finds the mod a label function belongs to by its chunk name minus the first
    -- character (text_of in services.lua: '@mods/<author>/<name>', and '=' or any other first character reads the
    -- same), runs it under the watchdog as that mod and skips it once that mod is off. So a name whose rest starts
    -- with mods/ or boot: (my owner keys) is this mod's only when the rest is its own name, or its name followed by
    -- a character no mod name goes on with ('/' for a piece of its own, ' (part)', ':part'); anything else (plain
    -- names, '=piece') stays open. Mod names nest (mods/<author>/<name>/<more> is one too), so a piece under its own
    -- name can only stand for a mod under that name in its own author's folder, never someone else's.
    local function named(n)
      if type(n) ~= 'string' then return nil end
      if sb.chunk and n == sb.chunk then return NAMED end
      local tail = s_sub(n, 2)
      if not (s_find(tail, '^mods/') or s_find(tail, '^boot:')) then return nil end
      if type(owner) == 'string' and s_sub(tail, 1, #owner) == owner and not s_find(tail, '^[%w_%-]', #owner + 1) then
        return nil
      end
      return 'that chunk name is another mod\'s (a mod names its code after itself only)'
    end
    env.loadstring = function(s, name)
      if type(s) == 'string' and s_byte(s, 1) == 27 then return nil, 'compiled Lua (bytecode) is off limits' end
      local bad = named(name == nil and s or name)
      if bad then return nil, bad end
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
      local bad = named(name == nil and chunk or name)
      if bad then return nil, bad end
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
      local own_lib = lib and rawget(env, lib)                -- (its own copy: one it cleared isn't looked for behind it)
      if type(own_lib) == 'table' then return own_lib end
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
    -- (the game's os, io, debug and package reached from an engine table: this mod's own)
    for _, n in ipairs({ 'os', 'io', 'debug', 'package' }) do
      local lib = rawget(G, n)
      if type(lib) == 'table' and type(rawget(env, n)) == 'table' then mine[lib] = rawget(env, n) end
    end
    -- (the base functions this environment doesn't replace above, and the game's other lower case globals: a table as
    -- this mod's own copy)
    for k, v in pairs(plain) do
      if rawget(env, k) == nil then rawset(env, k, type(v) == 'table' and own(v, true) or v) end
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
end)()
-- @@END sandbox.lua@@
-- @@BEGIN runtime.lua@@ (copied from src/chef_loader/runtime.lua by tools/splice.py; edit that file, not this)
services.runtime = (function()
-- Chef Shared Loader: the HD2Runtime look-alike
-- Mods written for the HD2Runtime API (another loader's boot script, version 0.1.0) find what it gives them:
--   * the HD2Runtime global and require('hd2rt'): version, api (1), mod(spec), status(), frame()
--   * mod(spec) -> a handle { id, engine, raw, on, log, state, switch_off, missing, request }; spec: id (letters,
--     digits, _ . -), api (1 or nil), name, lobby_key (letters, digits, _; 32 at most), bones (16-hex unit resources),
--     needs (engine calls and grants it can't do without: what of them I lack is logged, shown and in handle.missing())
--   * handle.request('lobby', why): mine; asks for the lobby before the work that needs it ('granted', or nil, why:
--     not on my list)
--   * handle.on('update' | 'render' | 'shutdown', fn): called by the loader with the mod's own hooks, each in its own
--     pcall; and handle.on('stop', fn), mine, not that API's: called once when the loader stops the mod (errors, a
--     failed start, a dev reload), before anything of it is undone, so it can put back what only it knows (textures
--     it set on the game's materials: the engine can't tell what a material had before)
--   * handle.engine: the API's engine calls, in its call shapes (Gui.rect takes numbers, Gui.text a font name,
--     World.spawn_unit a resource name ...), built here on the engine as the mod's own calls: the first call of each is
--     breadcrumbed for the mod, a unit is checked before it's asked anything (the loader's unit rules too: a unit from
--     a world that's gone, or a runtime-built one, is refused), and a refused call returns nil and why
--   * what a mod made is undone when it stops: its units destroyed, its GUIs destroyed, units it hid shown, materials
--     it swapped on units it didn't make put back, mouse dead zones it changed put back
-- The Steam lobby (Steam.user_id, Friends.playing_game, Network.join_steam_lobby, SteamLobby.*) only for a mod the
-- loader trusts with it (loader.lua, TRUSTED): the lobby the game reports this player in, and the mod's own member key.
-- Capitalized globals one of these mods sets reach the other ones' environments, as with that API, where they share one
-- _G; never a name the game already has. A trusted mod's globals stay its own, and it takes none of the others'.
-- Plain Lua 5.1.

local M = { version = '1.1.0', runtime_version = '0.1.0' }

local type, pairs, ipairs, next, tostring, select, rawget, rawset, pcall, error = type, pairs, ipairs, next, tostring, select, rawget,
  rawset, pcall, error
local fmt, concat, floor, abs, min = string.format, table.concat, math.floor, math.abs, math.min

-- a value's engine kind from its own tostring: '[Unit ...]' -> 'Unit', 'Vector3(1, 2, 3)' -> 'Vector3'; plain values
-- give type()
local function kind(v)
  local t = type(v)
  if t ~= 'userdata' then return t end
  local ok, s = pcall(tostring, v)
  if not ok or type(s) ~= 'string' then return 'userdata' end
  return s:match('^%[(%a[%w_]*)') or s:match('^(%a[%w_]*)%(') or 'userdata'
end
local unpack = unpack or table.unpack
-- a call's answers, every one of them (a first call goes through guarded, whose answers are cut to four)
local function pack(...) return { n = select('#', ...), ... } end
local function packed(fn, ...) return pack(fn(...)) end
-- a text's measures from the engine's three vectors (read inside a pcall: an answer that isn't vectors raises)
local function extents(lo, hi, caret) return lo.x, lo.y, hi.x, hi.y, caret.x end
local function int(v, lo, hi) return type(v) == 'number' and v == floor(v) and v >= lo and v <= hi end
local function finite(v, limit) return type(v) == 'number' and v == v and abs(v) <= limit end
local function hex16(s) return type(s) == 'string' and #s == 16 and s:match('^%x+$') ~= nil end
local EVENTS = { update = true, render = true, shutdown = true, stop = true }
-- what a mod may ask for (spec.needs, handle.request), as the log names it. Only the lobby is ever given: files and
-- patches (that runtime's own files and game patch files) are names a mod may still list, so it hears they're missing
-- and starts, but no mod gets them
local GRANTS = { lobby = 'the Steam lobby', files = 'its own files', patches = 'game patch files' }
-- the fonts a GUI's text may use: the ones the game makes a material for itself (another name ends the game), each
-- with that material; a locale's own UI font by its 16-hex id
local TEXT_FONTS = { ['content/fonts/fallback'] = 'content/fonts/runtime_font',
                     ['content/fonts/fs_sinclair_medium_runtime'] = 'content/fonts/runtime_font',
                     ['9ad413a8fea59728'] = 'content/fonts/runtime_font' }
local GUIS_PER_MOD, PRIMITIVES, SETS_PER_SECOND = 6, 12000, 10
-- the resource types Application.can_get answers for (another string goes to the engine as a type name)
local CAN_GET = { unit = true, material = true, texture = true, font = true, runtime_font = true, package = true }

-- ctx: log(line), mod_log(owner, text), guarded(owner, key, fn, ...), fn_of(name), G (the game's globals),
-- frame() -> number, instance() -> the engine world's instance, DIR, util (gone, unit_refused, fresh),
-- trusted(owner) -> its TRUSTED entry or nil, attach(owner, hooks) (the hooks the loader calls with the mod's own),
-- now() -> seconds; optional: notify(notice), missing(owner, list) (what a mod needs and I lack, for the mod list)
function M.install(ctx)
  local rt = {}
  local log, guarded, fn_of, util = ctx.log, ctx.guarded, ctx.fn_of, ctx.util
  local owners = {}                                   -- owner -> { name, env, mods = { id -> rec }, order, attached }
  local envs = {}                                     -- a runtime mod's environment -> its owner record (until forget)
  local orphan = {}                                   -- name -> { by, v }: a stopped mod's shared value, until set again
  local shared, shared_by = {}, {}                    -- capitalized globals runtime mods set, shared between them; who
  local G = ctx.G or {}

  -- ---------------------------------------------------------------- calls
  -- a binding's first call for this mod goes through guarded (breadcrumbed, keyed by the mod); later ones straight to
  -- the engine (an error raises into the mod's callback, as that API does). A binding the engine lacks: nil, why.
  local function once(rec, name, ...)
    local fn = fn_of(name)
    if fn == nil then return nil, name .. ' is not in this game build' end
    if rec.seen[name] then return fn(...) end
    local t, why = guarded(rec.owner, name, packed, fn, ...)
    if not (t == nil and why == 'skipped') then rec.seen[name] = true end
    if type(t) ~= 'table' then return nil, why end
    return unpack(t, 1, t.n)
  end
  -- a refusal: nil, why; the first of each kind (binding and why, 30 a mod at most) goes to the log
  local function refuse(rec, binding, why)
    if rec.said_n < 30 then
      local t = rec.said[binding]
      if not t then t = {}; rec.said[binding] = t end
      if not t[why] then
        t[why], rec.said_n = true, rec.said_n + 1
        log(fmt('[%s] %s refused: %s', rec.owner, binding, why))
      end
    end
    return nil, why
  end
  local worlds = { frame = -1, list = {} }
  local function world_list()
    local f = ctx.frame()
    if worlds.frame ~= f then
      local l = guarded('loader', 'Application.worlds', fn_of('Application.worlds'))
      worlds.list, worlds.frame = type(l) == 'table' and l or {}, f
    end
    return worlds.list
  end
  -- once-a-frame answers (a world listed, a userdata a Unit): one table each, reused and emptied when the frame
  -- changes, so they hold only what this frame asked about
  local memo = { frame = -1, listed = {}, unit = {} }
  local function memo_frame()
    local f = ctx.frame()
    if memo.frame ~= f then
      memo.frame = f
      if next(memo.listed) then for k in pairs(memo.listed) do memo.listed[k] = nil end end
      if next(memo.unit) then for k in pairs(memo.unit) do memo.unit[k] = nil end end
    end
  end
  -- a world the engine lists this frame
  local function listed(w)
    if type(w) ~= 'userdata' then return false end
    memo_frame()
    local v = memo.listed[w]
    if v ~= nil then return v end
    v = false
    if kind(w) == 'World' then
      for _, x in ipairs(world_list()) do if x == w then v = true; break end end
    end
    memo.listed[w] = v
    return v
  end
  -- a unit this mod may query: a Unit not known gone (the loader's stamps: one from an engine world before this one
  -- is never touched), alive. A unit isn't refused only because the world hasn't settled yet: those mods ask from
  -- their first frame, as their own runtime lets them.
  -- (Unit.alive itself is asked every time: a unit can be destroyed mid-frame. memo.unit[u]: true for a Unit stamped
  -- this frame (its kind costs a tostring, and what a userdata is never changes), false for anything else; the stamp
  -- is made on the frame's first look only, as the engine world can't change before the next frame. gone is still
  -- checked on every call, ahead of the memo.)
  local function alive(rec, u)
    if type(u) ~= 'userdata' or util.gone(u) then return false end   -- (before kind(): its tostring asks the engine)
    memo_frame()
    local k = memo.unit[u]
    if k == nil then
      k = kind(u) == 'Unit' and not util.unit_refused(rec.owner, 'Unit.alive', u)
      memo.unit[u] = k
    end
    if not k then return false end
    return once(rec, 'Unit.alive', u) == true
  end
  -- (a unit alive() just passed is stamped and not gone: unit_refused is told so, and only checks the call itself)
  local function unit_ask(rec, name, u)
    if not alive(rec, u) then return 'not a live unit' end
    return util.unit_refused(rec.owner, name, u, true)
  end
  -- the engine's value tables (IdString64, Vector3, Quaternion, Matrix4x4) as the mod gets them: each call goes through
  -- once(), and one with a nil among its arguments (the answer to a refused call, say) is refused instead of reaching
  -- the engine, where a nil can end the game. No arguments at all is fine (Vector3.zero, Quaternion.identity).
  local function holed(...)
    local n = select('#', ...)
    if n <= 4 then                                   -- (the usual calls: no loop)
      local a, b, c, d = ...
      return (n >= 1 and a == nil) or (n >= 2 and b == nil) or (n >= 3 and c == nil) or (n >= 4 and d == nil)
    end
    for i = 1, n do if (select(i, ...)) == nil then return true end end
    return false
  end
  local function values(rec, name)
    local t = fn_of(name)
    if t == nil then return nil end
    local w = {}
    return setmetatable(w, {
      __index = function(_, k)
        local f = type(t) == 'table' and t[k] or nil
        if type(f) == 'table' then
          -- (a table in it: the mod's own shallow copy, so what it writes there stays its own)
          local c = {}
          for k2, v2 in pairs(f) do c[k2] = v2 end
          rawset(w, k, c)
          return c
        end
        if type(f) ~= 'function' then return f end
        local b = name .. '.' .. tostring(k)
        local g = function(...)
          if rec.state ~= 'active' then return refuse(rec, b, 'the mod is off') end
          if holed(...) then return refuse(rec, b, 'nothing to work on (nil)') end
          return once(rec, b, ...)
        end
        rawset(w, k, g)
        return g
      end,
      __call = function(_, ...)
        if rec.state ~= 'active' then return refuse(rec, name, 'the mod is off') end
        if holed(...) then return refuse(rec, name, 'nothing to work on (nil)') end
        return once(rec, name, ...)
      end,
    })
  end
  local function nodes(rec, u) return once(rec, 'Unit.num_scene_graph_items', u) or 0 end
  local function resource(rec, what, id)
    local value
    if kind(id) == 'IdString64' then value = id
    elseif type(id) == 'string' and id ~= '' then
      value = hex16(id) and once(rec, 'IdString64.from_hex', id) or once(rec, 'IdString64', id)
    end
    if value == nil then return nil end
    if once(rec, 'Application.can_get', what, value) == true then return value end
    return nil
  end
  -- mesh and material handles: trusted only in the frame they were asked, while their unit lives
  local meshes = setmetatable({}, { __mode = 'k' })
  local materials = setmetatable({}, { __mode = 'k' })
  local versions = setmetatable({}, { __mode = 'k' })   -- unit -> how many times its materials were swapped
  local function mesh_ok(rec, m)
    local e = meshes[m]
    return e ~= nil and e.frame == ctx.frame() and alive(rec, e.unit)
  end
  local function material_ok(rec, mat)
    local e = materials[mat]
    return e ~= nil and e.frame == ctx.frame() and alive(rec, e.unit) and e.version == (versions[e.unit] or 0)
  end

  -- ---------------------------------------------------------------- the engine table one mod gets
  local function engine_for(rec)
    local N = { Unit = {}, Mesh = {}, Material = {}, World = {}, Application = {}, Keyboard = {}, Mouse = {}, Gui = {},
                Steam = {}, Friends = {}, Network = {}, SteamLobby = {}, Window = {},
                IdString64 = values(rec, 'IdString64'), Vector3 = values(rec, 'Vector3'),
                Quaternion = values(rec, 'Quaternion'), Matrix4x4 = values(rec, 'Matrix4x4') }
    local owned, hidden = rec.owned, rec.hidden

    -- Unit: reads
    for _, name in ipairs({ 'num_scene_graph_items', 'num_meshes', 'resource_name', 'world', 'id',
                            'has_animation_state_machine' }) do
      local b = 'Unit.' .. name
      N.Unit[name] = function(u)
        local why = unit_ask(rec, b, u)
        if why then return refuse(rec, b, why) end
        return once(rec, b, u)
      end
    end
    for _, name in ipairs({ 'world_position', 'world_rotation', 'world_pose', 'local_position', 'local_rotation',
                            'local_scale', 'local_pose' }) do
      local b = 'Unit.' .. name
      N.Unit[name] = function(u, i)
        local why = unit_ask(rec, b, u)
        if why then return refuse(rec, b, why) end
        if i == nil then i = 1 end
        -- (node 1, the root, is every unit's: only another index needs the count)
        if i ~= 1 and not int(i, 1, nodes(rec, u)) then return refuse(rec, b, 'no such node') end
        return once(rec, b, u, i)
      end
    end
    function N.Unit.alive(u) return alive(rec, u) end
    function N.Unit.has_node(u, name)
      if not alive(rec, u) then return refuse(rec, 'Unit.has_node', 'not a live unit') end
      if type(name) ~= 'string' then return refuse(rec, 'Unit.has_node', 'node name is not a string') end
      return once(rec, 'Unit.has_node', u, name)
    end
    function N.Unit.node(u, name)
      if not alive(rec, u) then return refuse(rec, 'Unit.node', 'not a live unit') end
      if type(name) ~= 'string' then return refuse(rec, 'Unit.node', 'node name is not a string') end
      if once(rec, 'Unit.has_node', u, name) ~= true then return refuse(rec, 'Unit.node', 'no such node') end
      return once(rec, 'Unit.node', u, name)
    end
    function N.Unit.mesh(u, i)
      local why = unit_ask(rec, 'Unit.mesh', u)
      if why then return refuse(rec, 'Unit.mesh', why) end
      if not int(i, 1, once(rec, 'Unit.num_meshes', u) or 0) then return refuse(rec, 'Unit.mesh', 'no such mesh') end
      local m = once(rec, 'Unit.mesh', u, i)
      if m ~= nil then
        local e = meshes[m]
        if e then e.unit, e.frame = u, ctx.frame() else meshes[m] = { unit = u, frame = ctx.frame() } end
      end
      return m
    end
    -- Unit: changes
    function N.Unit.set_unit_visibility(u, visible)
      if not alive(rec, u) then return refuse(rec, 'Unit.set_unit_visibility', 'not a live unit') end
      if type(visible) ~= 'boolean' then return refuse(rec, 'Unit.set_unit_visibility', 'visibility is not a boolean') end
      once(rec, 'Unit.set_unit_visibility', u, visible)
      if owned[u] == nil then hidden[u] = (not visible) or nil end
      return true
    end
    function N.Unit.set_mesh_visibility(u, i, visible)
      local why = unit_ask(rec, 'Unit.set_mesh_visibility', u)
      if why then return refuse(rec, 'Unit.set_mesh_visibility', why) end
      if not owned[u] then return refuse(rec, 'Unit.set_mesh_visibility', 'unit is not this mod\'s') end
      if not int(i, 1, once(rec, 'Unit.num_meshes', u) or 0) then return refuse(rec, 'Unit.set_mesh_visibility', 'no such mesh') end
      if type(visible) ~= 'boolean' then return refuse(rec, 'Unit.set_mesh_visibility', 'visibility is not a boolean') end
      once(rec, 'Unit.set_mesh_visibility', u, i, visible)
      return true
    end
    -- (a rotation is a Quaternion or the Vector4 the engine hands out for one)
    for _, spec in ipairs({ { 'set_local_position', 'Vector3' }, { 'set_local_rotation', 'Quaternion', 'Vector4' },
                            { 'set_local_scale', 'Vector3' } }) do
      local name, want, alias = spec[1], spec[2], spec[3]
      local b = 'Unit.' .. name
      N.Unit[name] = function(u, i, value)
        local why = unit_ask(rec, b, u)
        if why then return refuse(rec, b, why) end
        if not owned[u] then return refuse(rec, b, 'unit is not this mod\'s') end
        if not int(i, 1, nodes(rec, u)) then return refuse(rec, b, 'no such node') end
        local k = kind(value)
        if k ~= want and k ~= alias then return refuse(rec, b, 'value is not a ' .. want) end
        once(rec, b, u, i, value)
        return true
      end
    end
    -- mesh i, material j of a unit gets another material resource; on a unit the mod didn't make, the one it had
    -- first is put back when the mod stops
    function N.Unit.set_material_at(u, i, j, material)
      local b = 'Unit.set_material_at'
      local why = unit_ask(rec, 'Unit.mesh', u)
      if why then return refuse(rec, b, why) end
      if not int(i, 1, once(rec, 'Unit.num_meshes', u) or 0) then return refuse(rec, b, 'no such mesh') end
      local m = once(rec, 'Unit.mesh', u, i)
      if m == nil or not int(j, 1, once(rec, 'Mesh.num_materials', m) or 0) then return refuse(rec, b, 'no such material position') end
      local res = resource(rec, 'material', material)
      if not res then return refuse(rec, b, 'material is not loaded') end
      local slot = once(rec, 'Mesh.material_slot_id', m, j)
      if slot == nil then return refuse(rec, b, 'no material slot') end
      versions[u] = (versions[u] or 0) + 1
      local previous = once(rec, 'Unit.set_material', u, slot, res)
      if not owned[u] and previous ~= nil then
        rec.rebound = rec.rebound or {}
        local list = rec.rebound[u] or {}
        rec.rebound[u] = list
        local key = i .. ':' .. j
        if list[key] == nil then list[key] = previous end
      end
      return true
    end

    -- Mesh and Material
    function N.Mesh.visibility(m)
      if not mesh_ok(rec, m) then return refuse(rec, 'Mesh.visibility', 'mesh handle is stale or unknown') end
      local v = once(rec, 'Mesh.visibility', m)
      if type(v) ~= 'boolean' then return refuse(rec, 'Mesh.visibility', 'unexpected answer') end
      return v
    end
    function N.Mesh.num_materials(m)
      if not mesh_ok(rec, m) then return refuse(rec, 'Mesh.num_materials', 'mesh handle is stale or unknown') end
      return once(rec, 'Mesh.num_materials', m)
    end
    function N.Mesh.material(m, j)
      if not mesh_ok(rec, m) then return refuse(rec, 'Mesh.material', 'mesh handle is stale or unknown') end
      if not int(j, 1, once(rec, 'Mesh.num_materials', m) or 0) then return refuse(rec, 'Mesh.material', 'no such material') end
      local mat = once(rec, 'Mesh.material', m, j)
      local u = meshes[m].unit
      if mat ~= nil then
        local e = materials[mat]
        if e then e.unit, e.frame, e.version = u, ctx.frame(), versions[u] or 0
        else materials[mat] = { unit = u, frame = ctx.frame(), version = versions[u] or 0 } end
      end
      return mat
    end
    function N.Mesh.name(m)
      if not mesh_ok(rec, m) then return refuse(rec, 'Mesh.name', 'mesh handle is stale or unknown') end
      return once(rec, 'Mesh.name', m)
    end
    function N.Material.id64(mat)
      if not material_ok(rec, mat) then return refuse(rec, 'Material.id64', 'material handle is stale or unknown') end
      return once(rec, 'Material.id64', mat)
    end
    for _, spec in ipairs({ { 'set_scalar', 'number' }, { 'set_vector2', 'Vector2' }, { 'set_vector3', 'Vector3' },
                            { 'set_vector4', 'Vector4' } }) do
      local name, want = spec[1], spec[2]
      local b = 'Material.' .. name
      N.Material[name] = function(mat, variable, value)
        if not material_ok(rec, mat) then return refuse(rec, b, 'material handle is stale or unknown') end
        if type(variable) ~= 'string' then return refuse(rec, b, 'variable name is not a string') end
        if kind(value) ~= want then return refuse(rec, b, 'value is not a ' .. want) end
        once(rec, b, mat, variable, value)
        return true
      end
    end
    function N.Material.set_uint_vector(mat, variable, value)
      local b = 'Material.set_uint_vector'
      if not material_ok(rec, mat) then return refuse(rec, b, 'material handle is stale or unknown') end
      if type(variable) ~= 'string' then return refuse(rec, b, 'variable name is not a string') end
      if type(value) ~= 'table' or #value < 1 or #value > 4 then return refuse(rec, b, 'value is not 1 to 4 integers') end
      local c = {}
      for i = 1, #value do
        if not int(value[i], 0, 4294967295) then return refuse(rec, b, 'value is not 1 to 4 integers') end
        c[i] = value[i]
      end
      once(rec, b, mat, variable, c)
      return true
    end
    function N.Material.set_texture(mat, variable, texture)
      local b = 'Material.set_texture'
      if not material_ok(rec, mat) then return refuse(rec, b, 'material handle is stale or unknown') end
      if type(variable) ~= 'string' then return refuse(rec, b, 'variable name is not a string') end
      local res = resource(rec, 'texture', texture)
      if not res then return refuse(rec, b, 'texture is not loaded') end
      once(rec, b, mat, variable, res)
      return true
    end

    -- World
    for _, name in ipairs({ 'units', 'num_units' }) do
      local b = 'World.' .. name
      N.World[name] = function(w)
        if not listed(w) then return refuse(rec, b, 'not a live world') end
        return once(rec, b, w)
      end
    end
    function N.World.units_by_resource(w, id)
      local b = 'World.units_by_resource'
      if not listed(w) then return refuse(rec, b, 'not a live world') end
      local res = (kind(id) == 'IdString64' and id) or (hex16(id) and once(rec, 'IdString64.from_hex', id))
        or (type(id) == 'string' and id ~= '' and once(rec, 'IdString64', id))
      if not res then return refuse(rec, b, 'not a resource id') end
      return once(rec, b, w, res)
    end
    function N.World.spawn_unit(w, unit_resource, position, rotation)
      local b = 'World.spawn_unit'
      if not listed(w) then return refuse(rec, b, 'not a live world') end
      local res = resource(rec, 'unit', unit_resource)
      if not res then return refuse(rec, b, 'unit resource is not loaded') end
      if position ~= nil and kind(position) ~= 'Vector3' then return refuse(rec, b, 'position is not a Vector3') end
      if rotation ~= nil and kind(rotation) ~= 'Quaternion' then return refuse(rec, b, 'rotation is not a Quaternion') end
      if rotation ~= nil and position == nil then return refuse(rec, b, 'rotation without a position') end
      local u
      if rotation ~= nil then u = once(rec, b, w, res, position, rotation)
      elseif position ~= nil then u = once(rec, b, w, res, position)
      else u = once(rec, b, w, res) end
      if kind(u) == 'Unit' then owned[u] = w; util.fresh(u) end
      return u
    end
    local function own_in(w, u)
      if not listed(w) then return 'not a live world' end
      if not alive(rec, u) then return 'not a live unit' end
      if not owned[u] then return 'unit is not this mod\'s' end
      if once(rec, 'Unit.world', u) ~= w then return 'unit is in another world' end
    end
    function N.World.destroy_unit(w, u)
      local why = own_in(w, u)
      if why then return refuse(rec, 'World.destroy_unit', why) end
      once(rec, 'World.destroy_unit', w, u)
      owned[u] = nil
      return true
    end
    function N.World.link_unit(w, child, child_node, parent, parent_node)
      local b = 'World.link_unit'
      local why = own_in(w, child)
      if why then return refuse(rec, b, why) end
      local pwhy = unit_ask(rec, b, parent)                    -- the parent under the unit rules too
      if pwhy then return refuse(rec, b, pwhy) end
      if child == parent then return refuse(rec, b, 'a unit linked to itself') end
      if once(rec, 'Unit.world', parent) ~= w then return refuse(rec, b, 'units are not in this world') end
      if not int(child_node, 1, nodes(rec, child)) or not int(parent_node, 1, nodes(rec, parent)) then
        return refuse(rec, b, 'no such node')
      end
      once(rec, b, w, child, child_node, parent, parent_node)
      return true
    end
    function N.World.unlink_unit(w, child)
      local why = own_in(w, child)
      if why then return refuse(rec, 'World.unlink_unit', why) end
      once(rec, 'World.unlink_unit', w, child)
      return true
    end

    -- GUIs: the mod's own, in a live world; rectangles and texts given as plain numbers (x, y, z, width, height and a
    -- color 0-255 r, g, b, a), so no foreign handle gets in
    local guis = rec.guis
    local function gui_ok(g)
      local d = guis[g]
      return d ~= nil and (not ctx.instance or d.instance == ctx.instance()) and listed(d.world)
    end
    local function rect_problem(x, y, z, w, h, r, gr, b, a)
      if not finite(x, 32768) or not finite(y, 32768) or not finite(z, 10000) or not finite(w, 32768) or not finite(h, 32768)
        or w <= 0 or h <= 0 then return 'invalid rectangle' end
      if r == nil or gr == nil or b == nil or a == nil then return 'missing color' end
      if not finite(r, 255) or r < 0 or not finite(gr, 255) or gr < 0 or not finite(b, 255) or b < 0 or not finite(a, 255)
        or a < 0 then return 'invalid color' end
    end
    -- the engine values a rectangle needs, or nil when one couldn't be made (it never reaches the engine as a nil)
    local function rect_values(x, y, z, w, h, r, gr, b, a)
      local p, sz, c = once(rec, 'Vector3', x, y, z), once(rec, 'Vector2', w, h), once(rec, 'Color', a, r, gr, b)
      if p == nil or sz == nil or c == nil then return nil end
      return p, sz, c
    end
    local function draw_rect(g, x, y, z, w, h, r, gr, b, a)
      local p, sz, c = rect_values(x, y, z, w, h, r, gr, b, a)
      if p == nil then return refuse(rec, 'Gui.rect', 'no position, size or color') end
      return once(rec, 'Gui.rect', g, p, sz, c)
    end
    function N.World.create_screen_gui(w)
      local b = 'World.create_screen_gui'
      if not listed(w) then return refuse(rec, b, 'not a live world') end
      local n = 0
      for _ in pairs(guis) do n = n + 1 end
      if n >= GUIS_PER_MOD then return refuse(rec, b, 'GUI limit reached') end
      local g = once(rec, b, w, 'scale', 1, 1)
      if g ~= nil then guis[g] = { world = w, count = 0, instance = ctx.instance and ctx.instance() } end
      return g
    end
    function N.World.destroy_gui(w, g)
      if not gui_ok(g) or guis[g].world ~= w then return refuse(rec, 'World.destroy_gui', 'not this mod\'s GUI in a live world') end
      once(rec, 'World.destroy_gui', w, g)
      guis[g] = nil
      return true
    end
    function N.Gui.rect(g, x, y, z, w, h, r, gr, b, a)
      if not gui_ok(g) then return refuse(rec, 'Gui.rect', 'not this mod\'s GUI in a live world') end
      local problem = rect_problem(x, y, z, w, h, r, gr, b, a)
      if problem then return refuse(rec, 'Gui.rect', problem) end
      local d = guis[g]
      if d.count >= PRIMITIVES then return refuse(rec, 'Gui.rect', 'primitive limit reached') end
      local id = draw_rect(g, x, y, z, w, h, r, gr, b, a)
      d.count = d.count + 1
      if type(id) == 'number' then d.ids = d.ids or {}; d.ids[id] = true end
      return id
    end
    -- n rectangles at once: buf holds 9 numbers each; ids (optional) gets each one's id. A bad one stops the batch.
    function N.Gui.rects(g, buf, n, ids)
      if not gui_ok(g) then return refuse(rec, 'Gui.rects', 'not this mod\'s GUI in a live world') end
      if type(buf) ~= 'table' or not int(n, 0, 4096) or #buf < n * 9 or (ids ~= nil and type(ids) ~= 'table') then
        return refuse(rec, 'Gui.rects', 'invalid batch')
      end
      local d = guis[g]
      if d.count + n > PRIMITIVES then return refuse(rec, 'Gui.rects', 'primitive limit reached') end
      if ids then d.ids = d.ids or {} end
      for i = 0, n - 1 do
        local o = i * 9
        local x, y, z, w, h, r, gr, b, a = buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7],
          buf[o + 8], buf[o + 9]
        local problem = rect_problem(x, y, z, w, h, r, gr, b, a)
        if problem then d.count = d.count + i; return refuse(rec, 'Gui.rects', problem) end
        local id = draw_rect(g, x, y, z, w, h, r, gr, b, a)
        if ids then ids[i + 1] = id; if type(id) == 'number' then d.ids[id] = true end end
      end
      d.count = d.count + n
      return n
    end
    local function move_rect(g, id, x, y, z, w, h, r, gr, b, a)
      local p, sz, c = rect_values(x, y, z, w, h, r, gr, b, a)
      if p == nil then return refuse(rec, 'Gui.update_rect', 'no position, size or color') end
      once(rec, 'Gui.update_rect', g, id, p, sz, c)
      return true
    end
    function N.Gui.update_rect(g, id, x, y, z, w, h, r, gr, b, a)
      if not gui_ok(g) then return refuse(rec, 'Gui.update_rect', 'not this mod\'s GUI in a live world') end
      if not (guis[g].ids and guis[g].ids[id]) then return refuse(rec, 'Gui.update_rect', 'not a rectangle of this GUI') end
      local problem = rect_problem(x, y, z, w, h, r, gr, b, a)
      if problem then return refuse(rec, 'Gui.update_rect', problem) end
      return move_rect(g, id, x, y, z, w, h, r, gr, b, a)
    end
    function N.Gui.update_rects(g, ids, buf, n)
      if not gui_ok(g) then return refuse(rec, 'Gui.update_rects', 'not this mod\'s GUI in a live world') end
      if type(ids) ~= 'table' or type(buf) ~= 'table' or not int(n, 0, PRIMITIVES) or #buf < n * 9 or #ids < n then
        return refuse(rec, 'Gui.update_rects', 'invalid batch')
      end
      local known = guis[g].ids
      if not known then return refuse(rec, 'Gui.update_rects', 'not a rectangle of this GUI') end
      for i = 0, n - 1 do
        local id, o = ids[i + 1], i * 9
        if not known[id] then return refuse(rec, 'Gui.update_rects', 'not a rectangle of this GUI') end
        local x, y, z, w, h, r, gr, b, a = buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7],
          buf[o + 8], buf[o + 9]
        local problem = rect_problem(x, y, z, w, h, r, gr, b, a)
        if problem then return refuse(rec, 'Gui.update_rects', problem) end
        if not move_rect(g, id, x, y, z, w, h, r, gr, b, a) then return nil, 'no position, size or color' end
      end
      return n
    end
    function N.Gui.set_visible(g, on)
      if not gui_ok(g) then return refuse(rec, 'Gui.set_visible', 'not this mod\'s GUI in a live world') end
      if type(on) ~= 'boolean' then return refuse(rec, 'Gui.set_visible', 'visibility is not a boolean') end
      once(rec, 'Gui.set_visible', g, on)
      return true
    end
    -- text: a font from TEXT_FONTS (made fresh as an id each call: an id kept from an earlier frame ends the game)
    local resident = {}
    local function font_of(font)
      if font:match('^%x+$') then return once(rec, 'IdString64.from_hex', font) end
      return font
    end
    local function text_problem(s, font, size)
      if type(s) ~= 'string' or #s > 1024 or s:find('%z') then return 'invalid text' end
      if type(font) ~= 'string' or not TEXT_FONTS[font] then return 'font not allowed' end
      if not finite(size, 512) or size <= 0 then return 'invalid size' end
      if not resident[font] then
        local fid = font_of(font)
        if fid == nil or once(rec, 'Application.can_get', 'runtime_font', fid) ~= true
          or once(rec, 'Application.can_get', 'material', TEXT_FONTS[font]) ~= true then return 'font not loaded' end
        resident[font] = true
      end
    end
    local function texts(d) d.texts = d.texts or {}; return d.texts end
    function N.Gui.text(g, s, font, size, x, y, z, r, gr, b, a)
      if not gui_ok(g) then return refuse(rec, 'Gui.text', 'not this mod\'s GUI in a live world') end
      local problem = text_problem(s, font, size) or rect_problem(x, y, z, 1, 1, r, gr, b, a)
      if problem then return refuse(rec, 'Gui.text', problem) end
      local d = guis[g]
      if d.count >= PRIMITIVES then return refuse(rec, 'Gui.text', 'primitive limit reached') end
      local fid, p, c = font_of(font), once(rec, 'Vector3', x, y, z), once(rec, 'Color', a, r, gr, b)
      if fid == nil or p == nil or c == nil then return refuse(rec, 'Gui.text', 'no font, position or color') end
      local id = once(rec, 'Gui.text', g, s, fid, size, TEXT_FONTS[font], p, c)
      d.count = d.count + 1
      if type(id) == 'number' then texts(d)[id] = true end
      return id
    end
    function N.Gui.update_text(g, id, s, font, size, x, y, z, r, gr, b, a)
      if not gui_ok(g) then return refuse(rec, 'Gui.update_text', 'not this mod\'s GUI in a live world') end
      if not texts(guis[g])[id] then return refuse(rec, 'Gui.update_text', 'not a text of this GUI') end
      local problem = text_problem(s, font, size) or rect_problem(x, y, z, 1, 1, r, gr, b, a)
      if problem then return refuse(rec, 'Gui.update_text', problem) end
      local fid, p, c = font_of(font), once(rec, 'Vector3', x, y, z), once(rec, 'Color', a, r, gr, b)
      if fid == nil or p == nil or c == nil then return refuse(rec, 'Gui.update_text', 'no font, position or color') end
      once(rec, 'Gui.update_text', g, id, s, fid, size, TEXT_FONTS[font], p, c)
      return true
    end
    function N.Gui.destroy_text(g, id)
      if not gui_ok(g) then return refuse(rec, 'Gui.destroy_text', 'not this mod\'s GUI in a live world') end
      local t = texts(guis[g])
      if not t[id] then return refuse(rec, 'Gui.destroy_text', 'not a text of this GUI') end
      once(rec, 'Gui.destroy_text', g, id)
      t[id] = nil
      return true
    end
    -- a text's measures without drawing it: left, bottom, right, top (from the pen at the baseline) and the advance
    function N.Gui.text_extents(g, s, font, size)
      if not gui_ok(g) then return refuse(rec, 'Gui.text_extents', 'not this mod\'s GUI in a live world') end
      local problem = text_problem(s, font, size)
      if problem then return refuse(rec, 'Gui.text_extents', problem) end
      local fid = font_of(font)
      if fid == nil then return refuse(rec, 'Gui.text_extents', 'no font id') end
      local lo, hi, caret = once(rec, 'Gui.text_extents', g, s, fid, size)
      local ok, x0, y0, x1, y1, adv = pcall(extents, lo, hi, caret)
      if not ok or not finite(x0, 1e6) or not finite(y0, 1e6) or not finite(x1, 1e6) or not finite(y1, 1e6)
        or not finite(adv, 1e6) then return refuse(rec, 'Gui.text_extents', 'unexpected answer') end
      return x0, y0, x1, y1, adv
    end

    -- the game window: read only (its handle is never handed out); its answers' names and calls listed once per mod
    do
      local names, calls = { 'has_focus', 'show_cursor', 'mouse_focus' }, {}
      for i, name in ipairs(names) do calls[i] = 'Window.' .. name end
      function N.Window.ui_state()
        local w = once(rec, 'Window.get_main_window')
        if kind(w) ~= 'Window' then return refuse(rec, 'Window.ui_state', 'no main window') end
        local out = {}
        for i = 1, 3 do
          local v = once(rec, calls[i], w)
          if type(v) ~= 'boolean' then return refuse(rec, 'Window.ui_state', 'unexpected answer') end
          out[names[i]] = v
        end
        return out
      end
    end
    -- the mouse: device counts checked before an index is used; a vector copied out (the engine's lives for a frame)
    for _, e in ipairs({ { 'num_axes', 64 }, { 'num_buttons', 512 } }) do
      local name, most = e[1], e[2]
      local b = 'Mouse.' .. name
      N.Mouse[name] = function()
        local c = once(rec, b)
        if not int(c, 0, most) then return refuse(rec, b, 'unexpected answer') end
        return c
      end
    end
    local function axis_ok(i) local c = N.Mouse.num_axes(); return c ~= nil and int(i, 0, c - 1) end
    function N.Mouse.axis(i)
      if not axis_ok(i) then return refuse(rec, 'Mouse.axis', 'invalid axis') end
      local v = once(rec, 'Mouse.axis', i)
      if kind(v) ~= 'Vector3' then return refuse(rec, 'Mouse.axis', 'unexpected answer') end
      local x, y, z = once(rec, 'Vector3.to_elements', v)
      if not (finite(x, 1e12) and finite(y, 1e12) and finite(z, 1e12)) then return refuse(rec, 'Mouse.axis', 'unexpected answer') end
      return { x = x, y = y, z = z }
    end
    -- (while the loader's options menu is open the keys and mouse buttons are its own: nothing pressed, no keystrokes)
    local function quiet() return util ~= nil and util.menu_open ~= nil and util.menu_open() == true end
    function N.Mouse.button(i)
      if quiet() then return 0 end
      local c = N.Mouse.num_buttons()
      if not c or not int(i, 0, c - 1) then return refuse(rec, 'Mouse.button', 'invalid button') end
      local v = once(rec, 'Mouse.button', i)
      if v ~= 0 and v ~= 1 then return refuse(rec, 'Mouse.button', 'unexpected answer') end
      return v
    end
    -- dead zones: mode 0, 1 or 2 and a size; sizes from 0.5 to 10 are refused (near 1 the camera's deltas turn
    -- infinite for the session), and the first value the mod changes per axis is put back when it stops
    local function zone_ok(mode, size) return (mode == 0 or mode == 1 or mode == 2) and finite(size, 1e9) and size >= 0 end
    function N.Mouse.dead_zone(i)
      if not axis_ok(i) then return refuse(rec, 'Mouse.dead_zone', 'invalid axis') end
      local mode, size = once(rec, 'Mouse.dead_zone', i)
      if not zone_ok(mode, size) then return refuse(rec, 'Mouse.dead_zone', 'unexpected answer') end
      return mode, size
    end
    function N.Mouse.set_dead_zone(i, mode, size)
      local b = 'Mouse.set_dead_zone'
      if not axis_ok(i) then return refuse(rec, b, 'invalid axis') end
      if not zone_ok(mode, size) then return refuse(rec, b, 'invalid dead zone') end
      if size >= 0.5 and size <= 10 then return refuse(rec, b, 'a size near 1 breaks the camera') end
      rec.dead_zones = rec.dead_zones or {}
      if not rec.dead_zones[i] then
        local m, s = once(rec, 'Mouse.dead_zone', i)
        if not zone_ok(m, s) then return refuse(rec, b, 'unexpected answer') end
        rec.dead_zones[i] = { m, s }
      end
      once(rec, b, i, mode, size)
      return true
    end
    -- the keyboard: names only (the engine's key constants don't match its live indices)
    function N.Keyboard.keystrokes()
      if quiet() then return {} end
      local b = 'Keyboard.keystrokes'
      local events = once(rec, b)
      if type(events) ~= 'table' or #events > 128 then return refuse(rec, b, 'unexpected answer') end
      local out, n, bytes = {}, 0, 0
      for i, v in pairs(events) do
        if not int(i, 1, #events) then return refuse(rec, b, 'unexpected answer') end
        if type(v) == 'string' then
          bytes = bytes + #v
          if #v > 1024 or bytes > 4096 then return refuse(rec, b, 'too much text') end
        elseif not int(v, 0, 255) then return refuse(rec, b, 'unexpected answer') end
        n = n + 1
        out[i] = v
      end
      if n ~= #events then return refuse(rec, b, 'unexpected answer') end
      return out
    end
    function N.Keyboard.pressed(name)
      local b = 'Keyboard.pressed'
      if type(name) ~= 'string' or name == '' or #name > 40 then return refuse(rec, b, 'invalid button name') end
      if quiet() then return false end
      local i = once(rec, 'Keyboard.button_index', name)
      if not int(i, 0, (once(rec, 'Keyboard.num_buttons') or 0) - 1) then return refuse(rec, b, 'unknown button') end
      return once(rec, b, i)
    end
    -- bone names, only of the unit resources the mod declared (spec.bones): on other units the call can end the game
    function N.Unit.bones(u)
      if not alive(rec, u) then return refuse(rec, 'Unit.bones', 'not a live unit') end
      local id = once(rec, 'Unit.resource_name', u)
      local h = kind(id) == 'IdString64' and once(rec, 'IdString64.to_hex', id) or nil
      if type(h) ~= 'string' or not rec.bones[h:lower()] then return refuse(rec, 'Unit.bones', 'unit resource not declared for bone names') end
      local names = once(rec, 'Unit.bones', u)
      if type(names) ~= 'table' then return refuse(rec, 'Unit.bones', 'unexpected answer') end
      return names
    end

    -- the Steam lobby: a trusted mod's own key in the lobby the game reports this player in
    -- the handle of the lobby this player is in now, as join_steam_lobby handed it out (by identity: a left lobby's
    -- handle, or anything else, is refused without asking the engine about it)
    local function lobby_handle(h)
      local L = rt.lobby
      return h ~= nil and L.current ~= nil and L.handles[L.current] == h
    end
    local function net(b)
      local t = ctx.trusted(rec.owner)
      if not (t and t.network) then return 'the lobby is only for mods the loader trusts with it' end
      if rec.lobby_key == nil or rec.lobby_key ~= t.lobby_key then return 'not the lobby key the loader trusts this mod with' end
    end
    function N.Steam.user_id()
      local no = net('Steam.user_id')
      if no then return refuse(rec, 'Steam.user_id', no) end
      local id = once(rec, 'Steam.user_id')
      if not hex16(id) then return refuse(rec, 'Steam.user_id', 'unexpected answer') end
      return id
    end
    function N.Friends.playing_game(id)
      local no = net('Friends.playing_game')
      if no then return refuse(rec, 'Friends.playing_game', no) end
      if not hex16(id) then return refuse(rec, 'Friends.playing_game', 'invalid Steam id') end
      -- only this player's own id: the lobby a mod may join is the one this player is in, never a friend's
      if id ~= once(rec, 'Steam.user_id') then return refuse(rec, 'Friends.playing_game', 'not this player\'s Steam id') end
      local t = once(rec, 'Friends.playing_game', id)
      if type(t) ~= 'table' then return nil, 'no lobby' end              -- (no answer this time: nothing changes)
      -- a definite answer that this player is in no lobby (any more): the left one's handles are never used again
      if t.app_id == 553850 and (not hex16(t.lobby) or t.lobby:match('^0+$')) then
        rt.lobby.current, rt.lobby.reported, rt.lobby.handles = nil, nil, {}
        return nil, 'no lobby'
      end
      if t.app_id ~= 553850 or not hex16(t.lobby) then return nil, 'no lobby' end
      if rt.lobby.current ~= t.lobby then rt.lobby.handles, rt.lobby.current = {}, t.lobby end
      rt.lobby.reported = t.lobby
      return { app_id = t.app_id, lobby = t.lobby }
    end
    function N.Network.join_steam_lobby(lobby)
      local b = 'Network.join_steam_lobby'
      local no = net(b)
      if no then return refuse(rec, b, no) end
      local L = rt.lobby
      if not hex16(lobby) or lobby ~= L.reported or lobby ~= L.current then return refuse(rec, b, 'not the lobby the game reports') end
      if L.handles[lobby] then return L.handles[lobby] end
      local h = once(rec, b, lobby)
      if not (type(h) == 'userdata' and kind(h) == 'SteamLobby') then return refuse(rec, b, 'unexpected answer') end
      L.handles[lobby] = h
      return h
    end
    function N.SteamLobby.state(h)
      local no = net('SteamLobby.state')
      if no then return refuse(rec, 'SteamLobby.state', no) end
      if not lobby_handle(h) then return refuse(rec, 'SteamLobby.state', 'invalid lobby handle') end
      local v = once(rec, 'SteamLobby.state', h)
      if type(v) ~= 'number' then return refuse(rec, 'SteamLobby.state', 'unexpected answer') end
      return v
    end
    function N.SteamLobby.members(h)
      local no = net('SteamLobby.members')
      if no then return refuse(rec, 'SteamLobby.members', no) end
      if not lobby_handle(h) then return refuse(rec, 'SteamLobby.members', 'invalid lobby handle') end
      local list = once(rec, 'SteamLobby.members', h)
      if type(list) ~= 'table' then return refuse(rec, 'SteamLobby.members', 'unexpected answer') end
      local out = {}
      for i = 1, min(#list, 64) do if hex16(list[i]) then out[#out + 1] = list[i] end end
      return out
    end
    local function key_ok(key) return rec.lobby_key ~= nil and key == rec.lobby_key end
    function N.SteamLobby.member_data(h, id, key)
      local b = 'SteamLobby.member_data'
      local no = net(b)
      if no then return refuse(rec, b, no) end
      if not lobby_handle(h) then return refuse(rec, b, 'invalid lobby handle') end
      if not hex16(id) then return refuse(rec, b, 'invalid member id') end
      if not key_ok(key) then return refuse(rec, b, 'not this mod\'s lobby key') end
      local v = once(rec, b, h, id, key)
      if type(v) ~= 'string' then return refuse(rec, b, 'unexpected answer') end
      return v
    end
    function N.SteamLobby.set_member_data(h, key, value)
      local b = 'SteamLobby.set_member_data'
      local no = net(b)
      if no then return refuse(rec, b, no) end
      if not lobby_handle(h) then return refuse(rec, b, 'invalid lobby handle') end
      if not key_ok(key) then return refuse(rec, b, 'not this mod\'s lobby key') end
      if type(value) ~= 'string' or #value > 1024 or value:find('%z') then return refuse(rec, b, 'value is not a short string') end
      local now = ctx.now()
      if now - rec.set_at >= 1 then rec.set_at, rec.sets = now, 0 end
      if rec.sets >= SETS_PER_SECOND then return refuse(rec, b, SETS_PER_SECOND .. ' writes a second at most') end
      rec.sets = rec.sets + 1
      once(rec, b, h, key, value)
      return true
    end

    -- Application
    function N.Application.worlds()
      local c = {}
      for i, w in ipairs(world_list()) do c[i] = w end
      return c
    end
    function N.Application.can_get(what, id)
      -- (a refusal answers false, as a resource that isn't there does)
      if type(what) ~= 'string' then refuse(rec, 'Application.can_get', 'type is not a string'); return false end
      if not CAN_GET[what] then refuse(rec, 'Application.can_get', 'not a resource type mods ask about'); return false end
      return resource(rec, what, id) ~= nil
    end
    for _, name in ipairs({ 'main_world', 'build', 'build_identifier', 'platform', 'time_since_launch', 'resolution', 'argv' }) do
      local b = 'Application.' .. name
      N.Application[name] = function() return once(rec, b) end
    end
    -- the game closed as its own Quit does: for a player's own choice
    function N.Application.quit() once(rec, 'Application.quit'); return true end

    -- a mod that's off gets refusals from every binding it kept
    for _, ns in ipairs({ 'Unit', 'Mesh', 'Material', 'World', 'Application', 'Keyboard', 'Mouse', 'Window', 'Gui', 'Steam',
                          'Friends', 'Network', 'SteamLobby' }) do
      for name, fn in pairs(N[ns]) do
        local b = ns .. '.' .. name
        N[ns][name] = function(...)
          if rec.state ~= 'active' then return refuse(rec, b, 'the mod is off') end
          return fn(...)
        end
      end
    end
    return N
  end
  rt.lobby = { handles = {}, current = nil, reported = nil }

  -- ---------------------------------------------------------------- undoing what a mod made
  local function release(rec)
    local o = rec.owner
    local function g(name, ...) return guarded(o, name, fn_of(name), ...) end
    for i, v in pairs(rec.dead_zones or {}) do g('Mouse.set_dead_zone', i, v[1], v[2]) end
    rec.dead_zones = nil
    for u, list in pairs(rec.rebound or {}) do
      if type(u) == 'userdata' and not util.gone(u) and kind(u) == 'Unit' and g('Unit.alive', u) == true then
        for key, previous in pairs(list) do
          local i, j = key:match('^(%d+):(%d+)$')
          i, j = tonumber(i), tonumber(j)
          if i <= (g('Unit.num_meshes', u) or 0) then
            local m = g('Unit.mesh', u, i)
            if m ~= nil and j <= (g('Mesh.num_materials', m) or 0) then
              local slot = g('Mesh.material_slot_id', m, j)
              if slot ~= nil then g('Unit.set_material', u, slot, previous) end
            end
          end
        end
      end
    end
    rec.rebound = nil
    for gui, e in pairs(rec.guis) do
      if (not ctx.instance or e.instance == ctx.instance()) and listed(e.world) then g('World.destroy_gui', e.world, gui) end
      rec.guis[gui] = nil
    end
    local destroyed, shown = 0, 0
    for u, w in pairs(rec.owned) do
      if listed(w) and not util.gone(u) and g('Unit.alive', u) == true and g('Unit.world', u) == w then
        g('World.destroy_unit', w, u)
        destroyed = destroyed + 1
      end
      rec.owned[u] = nil
    end
    for u in pairs(rec.hidden) do
      if not util.gone(u) and g('Unit.alive', u) == true then g('Unit.set_unit_visibility', u, true); shown = shown + 1 end
      rec.hidden[u] = nil
    end
    return destroyed, shown
  end
  local function switch_off(rec, why)
    if rec.state ~= 'active' then return true end
    rec.state = 'off: ' .. why
    for ev in pairs(EVENTS) do rec.callbacks[ev] = {} end
    local ok, d, s = pcall(release, rec)
    log(fmt('[%s] %s switched off: %s (%s)', rec.owner, rec.id, why,
      ok and fmt('destroyed %d, shown %d', d or 0, s or 0) or ('undoing failed: ' .. tostring(d))))
    return ok
  end
  -- the loader stopped this mod (errors, a failed start, dev reload): everything it made is undone
  function rt.forget(owner)
    local o = owners[owner]
    if not o then return end
    for _, rec in ipairs(o.order) do switch_off(rec, 'stopped by the loader') end
    if o.env then envs[o.env] = nil end
    owners[owner] = nil
    -- what it shared isn't handed to mods that start later; mods that have it keep their copy (one may have made the
    -- name its own, X = X or {})
    for k, by in pairs(shared_by) do
      if by == owner then orphan[k], shared[k], shared_by[k] = { by = owner, v = shared[k] }, nil, nil end
    end
  end
  -- a new world: what belonged to a world that's gone is let go without being touched (any call on it ends the game)
  function rt.new_world()
    worlds.frame, memo.frame = -1, -1
    for k in pairs(memo.listed) do memo.listed[k] = nil end   -- (the gone world's objects aren't held)
    for k in pairs(memo.unit) do memo.unit[k] = nil end
    -- mesh and material handles belong to units of the world that's gone (light handles wouldn't leave weak tables)
    for m in pairs(meshes) do meshes[m] = nil end
    for m in pairs(materials) do materials[m] = nil end
    for u in pairs(versions) do versions[u] = nil end
    for _, o in pairs(owners) do
      for _, rec in ipairs(o.order) do
        for u, w in pairs(rec.owned) do if not listed(w) then rec.owned[u] = nil end end
        for u in pairs(rec.hidden) do if util.gone(u) then rec.hidden[u] = nil end end
        for u in pairs(rec.rebound or {}) do if util.gone(u) then rec.rebound[u] = nil end end
        for gui, e in pairs(rec.guis) do
          if (ctx.instance and e.instance ~= ctx.instance()) or not listed(e.world) then rec.guis[gui] = nil end
        end
      end
    end
  end

  -- ---------------------------------------------------------------- the callbacks, through the mod's own hooks
  local function dispatch(o, event, ...)
    local first
    for _, rec in ipairs(o.order) do
      if rec.state == 'active' then
        local list = rec.callbacks[event]
        for i = 1, #list do
          local ok, err = pcall(list[i], ...)
          if not ok and first == nil then first = err end
          if rec.state ~= 'active' then break end
        end
      end
    end
    if first ~= nil then error(first, 0) end
  end

  -- ---------------------------------------------------------------- HD2Runtime.mod and the public table
  local function owner_rec(owner, env)
    local o = owners[owner]
    if not o then
      o = { name = owner, short = owner:match('([^/]+)$') or owner, env = env, mods = {}, order = {} }
      owners[owner] = o
    end
    return o
  end
  -- what a mod has of a grant: 'granted' (its list entry gives it), or nil (its entry doesn't give it, or it has none)
  local function grant_state(owner, what)
    local t = ctx.trusted(owner)
    if not t then return nil end
    if what == 'lobby' then return t.network and 'granted' or nil end
    return nil
  end
  local function new_mod(o, spec)
    if type(spec) ~= 'table' or type(spec.id) ~= 'string' or not spec.id:match('^[%w_%.%-]+$') or #spec.id > 64 then
      return nil, 'a mod needs an id of letters, digits, _ . -'
    end
    if spec.api ~= nil and spec.api ~= 1 then return nil, 'unsupported api ' .. tostring(spec.api) end
    local old = o.mods[spec.id]
    if old then return old.handle end
    if spec.lobby_key ~= nil and (type(spec.lobby_key) ~= 'string' or not spec.lobby_key:match('^[%w_]+$')
      or #spec.lobby_key > 32) then return nil, 'a lobby key is letters, digits and _ (32 at most)' end
    local bones = {}
    for _, h in ipairs(type(spec.bones) == 'table' and spec.bones or {}) do
      if not hex16(h) then return nil, 'bones lists 16-hex unit resources' end
      bones[h:lower()] = true
    end
    -- what the mod says it needs (spec.needs): engine calls by name ('Material.set_texture') and what my list may give
    -- a trusted mod ('lobby'; 'files' and 'patches' are never given). I check them here, once, so a mod made for a
    -- newer runtime or one that isn't on my list hears what's missing (handle.missing) and the player sees it, instead
    -- of a mod that starts and half works
    local needs = {}
    if spec.needs ~= nil then
      if type(spec.needs) ~= 'table' or #spec.needs > 64 then return nil, 'needs lists at most 64 names' end
      for _, n in ipairs(spec.needs) do
        if type(n) ~= 'string' or #n > 64 or not (n:match('^%a[%w_]*%.%a[%w_]*$') or GRANTS[n]) then
          return nil, 'needs lists engine calls (Namespace.call) and lobby, files or patches'
        end
        needs[#needs + 1] = n
      end
    end
    if #o.order >= 8 then return nil, 'eight mods per file at most' end
    local rec = { owner = o.name, short = o.short, id = spec.id, name = type(spec.name) == 'string' and spec.name or spec.id,
                  state = 'active', errors = 0, callbacks = { update = {}, render = {}, shutdown = {}, stop = {} }, owned = {},
                  hidden = {}, guis = {}, bones = bones, lobby_key = spec.lobby_key, seen = {}, said = {}, said_n = 0,
                  set_at = -1, sets = 0 }
    rec.engine = engine_for(rec)
    -- raw: the mod's own view of the engine (its stingray, without what the locked-down space leaves out), never the
    -- loader's
    local handle = { id = rec.id, engine = rec.engine, raw = o.env and o.env.stingray or nil }
    function handle.on(event, fn)
      if not EVENTS[event] then return nil, 'unknown event ' .. tostring(event) end
      if type(fn) ~= 'function' then return nil, 'the callback is not a function' end
      if rec.state ~= 'active' then return nil, rec.state end
      local list = rec.callbacks[event]
      if #list >= 64 then return nil, '64 callbacks an event at most' end
      list[#list + 1] = fn
      return true
    end
    function handle.log(...)
      local parts = {}
      for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
      ctx.mod_log(o.name, concat(parts, '\t'))
    end
    function handle.state() return rec.state end
    function handle.switch_off(why) return switch_off(rec, 'by itself: ' .. tostring(why)) end
    -- what of spec.needs I can't give, as a new list (empty when everything is there)
    rec.missing = {}
    for _, n in ipairs(needs) do
      local ns, call = n:match('^(%a[%w_]*)%.(%a[%w_]*)$')
      local have
      if ns then have = type(rec.engine[ns]) == 'table' and type(rec.engine[ns][call]) == 'function'
      else have = grant_state(o.name, n) ~= nil end
      if not have then rec.missing[#rec.missing + 1] = n end
    end
    function handle.missing()
      local out = {}
      for i, n in ipairs(rec.missing) do out[i] = n end
      return out
    end
    -- handle.request(what, why): ask for 'lobby' before doing the work that needs it ('files' and 'patches' are
    -- never given).
    -- -> 'granted' | nil, why (I don't give it to this mod; the log and a notice say so once, so the player knows what
    -- to report)
    function handle.request(what, why)
      if not GRANTS[what] then return nil, 'unknown request ' .. tostring(what) end
      if rec.state ~= 'active' then return nil, rec.state end
      local state = grant_state(o.name, what)
      if state then return state end
      if not rec.said['request ' .. what] then
        rec.said['request ' .. what] = true
        log(fmt('[%s] %s asks for %s%s: %s', o.name, rec.name, GRANTS[what],
          type(why) == 'string' and ' (' .. why:sub(1, 200) .. ')' or '', what == 'lobby'
          and 'I give that only to the mods on my list (TRUSTED); to ask for a place, open an issue on GitHub'
          or 'I give that to no mod (its own runtime\'s loader may)'))
        if ctx.notify then ctx.notify({ text = rec.name:upper():sub(1, 32) .. ' NEEDS ACCESS THIS LOADER DOESN\'T GIVE (SEE LOG)', dur = 20 }) end
      end
      return nil, 'not given to this mod'
    end
    rec.handle = handle
    o.mods[rec.id] = rec
    o.order[#o.order + 1] = rec
    -- (the file's first mod with a name of its own, not just its id: that name titles the file's entry in my menu)
    if #o.order == 1 and ctx.named and type(spec.name) == 'string' and spec.name ~= spec.id then ctx.named(o.name, spec.name) end
    if not o.attached then
      o.attached = true
      ctx.attach(o.name, {
        update = function(dt) return dispatch(o, 'update', dt) end,
        render = function() return dispatch(o, 'render') end,
        shutdown = function() return dispatch(o, 'shutdown') end,
        stop = function() return dispatch(o, 'stop') end,
      })
    end
    -- its environment shares the runtime mods' globals from now on
    if o.env and not envs[o.env] then
      envs[o.env] = o
      -- (a trusted mod gets none of the shared globals, and what it sets stays its own: its environment holds only
      -- what it set itself)
      if not ctx.trusted(o.name) then
        for k, v in pairs(shared) do if rawget(o.env, k) == nil then rawset(o.env, k, v) end end
        -- and what it set before registering is shared now (a library mod defines its global, then calls mod())
        local own = {}
        for k, v in pairs(o.env) do own[k] = v end
        for k, v in pairs(own) do if shared_by[k] == nil then rt.on_global(o.env, k, v) end end
      end
    end
    log(fmt('[%s] HD2 Lua Runtime look-alike: mod %s%s', o.name, rec.id, rec.lobby_key and ' (lobby key ' .. rec.lobby_key .. ')' or ''))
    if #rec.missing > 0 then
      log(fmt('[%s] %s needs what this loader (%s) doesn\'t have: %s', o.name, rec.name, tostring(ctx.VERSION),
        concat(rec.missing, ', ')))
      if ctx.notify then ctx.notify({ text = rec.name:upper():sub(1, 32) .. ' NEEDS MORE THAN THIS LOADER HAS (SEE LOG)', dur = 20 }) end
    end
    -- (the mod list's line is the file's: what any of its mods lacks, each name once)
    if ctx.missing then
      local all, seen = {}, {}
      for _, x in ipairs(o.order) do
        for _, n in ipairs(x.missing or {}) do if not seen[n] then seen[n] = true; all[#all + 1] = n end end
      end
      ctx.missing(o.name, all)
    end
    return handle
  end
  local function public_for(owner, env)
    local o = owner_rec(owner, env)
    local pub = { version = M.runtime_version, api = 1, runtime = 'Chef Shared Loader ' .. tostring(ctx.VERSION) }
    function pub.mod(spec)
      if owners[o.name] ~= o then return nil, 'this mod was stopped by the loader' end
      return new_mod(o, spec)
    end
    function pub.status()
      local mods = {}
      for _, x in pairs(owners) do
        for _, rec in ipairs(x.order) do mods[#mods + 1] = { id = rec.id, state = rec.state, errors = rec.errors } end
      end
      return { mods = mods, modules = {}, previous = { exists = false }, log_dir = (ctx.DIR or ''):gsub('\\$', '') }
    end
    function pub.frame() return ctx.frame() end
    return setmetatable({}, { __index = pub, __metatable = 'locked',
      __newindex = function() error('HD2Runtime is read-only', 2) end })
  end
  -- a mod's environment gets its own HD2Runtime (and require('hd2rt') gives the same)
  function rt.bind(env, owner)
    if type(env) ~= 'table' or type(owner) ~= 'string' then return false end
    local pub = public_for(owner, env)
    rawset(env, 'HD2Runtime', pub)
    local pkg = rawget(env, 'package')
    if type(pkg) == 'table' and type(pkg.loaded) == 'table' then pkg.loaded.hd2rt = pub end
    return true
  end
  -- a capitalized global a runtime mod sets: shared with every runtime mod that doesn't have that name yet.
  -- A trusted mod's globals stay its own (what it sets could let another mod use what only it was given: its lobby
  -- key, say), and it gets none of the others'.
  function rt.on_global(env, k, v)
    local o = envs[env]
    if not o or type(k) ~= 'string' or not k:match('^%u[%w_]*$') or rawget(G, k) ~= nil or k == 'HD2Runtime' then return end
    if v == nil then return end
    if ctx.trusted(o.name) then return end
    if shared_by[k] ~= nil and shared_by[k] ~= o.name then return end   -- another mod's name: this one's copy is its own
    local prev = shared[k]
    -- after its mod stopped: only that mod setting it again (a reload) replaces the old copies
    if prev == nil and orphan[k] and orphan[k].by == o.name then prev = orphan[k].v end
    orphan[k] = nil
    shared[k], shared_by[k] = v, o.name
    -- the others get it where they have nothing, or still the value it had before (set to nil and back); never a
    -- trusted mod
    for e, r in pairs(envs) do
      if e ~= env and not ctx.trusted(r.name) then
        local cur = rawget(e, k)
        if cur == nil or (prev ~= nil and cur == prev) then rawset(e, k, v) end
      end
    end
  end
  function rt.count()
    local n = 0
    for _, o in pairs(owners) do n = n + #o.order end
    return n
  end
  return rt
end
return M
end)()
-- @@END runtime.lua@@
-- @@BEGIN lang.lua@@ (copied from src/chef_loader/lang.lua by tools/splice.py; edit that file, not this)
services.lang = (function()
-- Chef Shared Loader: language files
-- A language file is a Lua resource whose first line is "-- HD2-Lang: mods/<author>/<name>" and that returns only
-- data:
--   return {
--     name = 'Deutsch',                 -- shown in my options menu (Chef Shared Loader > Language); 40 bytes at most
--     code = 'de',                      -- optional, for mods (chef.lang())
--     text = { ['ALL MODS'] = 'ALLE MODS', ... },        -- exact texts: English as drawn, any case -> the translation
--     patterns = { { '^(%d+) MODS$', '%1 MODS' }, ... }, -- optional, tried in order when no exact text matches
--   }
-- Data only: before it runs I read its code (strings and comments taken out) and take only names, numbers, '{ } [ ] = ,
-- ; .', spaces and the keywords local, return, nil, true and false: no loops, conditions, calls or operators, so it
-- runs straight through (4 MB a file at most, the 64 highest files, about 2 s of reading in all; a file that takes over
-- 5 s is skipped from the next launch on). It runs once at start-up with nothing to reach (an empty environment),
-- breadcrumbed from reading through taking in: a file that ends the game is skipped from the next launch on. Files with
-- the same name are one language: a later file (a higher patch) wins, for texts, patterns (its own tried first) and
-- code. One vocabulary serves my own menu, the monitor, the notices and every mod, because every text drawn goes
-- through my text functions: they ask tr() first. A pattern must start with '^', have at most 2 of '*', '+' and '-'
-- (not 2 with a '?', and at most 24 classes after the first of 2) and 3 of '?', use only captures it has closed, and be
-- quick on a few long texts, two made from its own letters (timed at start-up, about 100 ms of timing a file); it is
-- tried on texts of up to 160 bytes, once each (kept), with about 1 ms of pattern work a frame (a text past that is
-- drawn as it is and tried on in the next frame).
-- While a language is on, texts with two letters in a row, no digits and no entry are noted (once each, 3000 at most)
-- and written to chef_loader_lang_missing.txt in my folder, as lines ready to copy into the file's text table.
-- The language picked is saved by its name, so adding or removing a language file never changes it.
-- Plain Lua 5.1.

local M = { version = '1.2.0' }

local type, pairs, ipairs, tostring, tonumber, pcall, setfenv, loadstring = type, pairs, ipairs, tostring, tonumber,
  pcall, setfenv, loadstring
local s_upper, s_find, s_gsub, s_format, s_sub, s_match, s_byte = string.upper, string.find, string.gsub, string.format,
  string.sub, string.match, string.byte
local s_gmatch, s_rep, floor = string.gmatch, string.rep, math.floor
local sort, concat = table.sort, table.concat

local MAX_TEXTS, MAX_PATTERNS, MAX_LEN, MAX_NAME, MAX_SRC, MAX_LANGS = 20000, 200, 300, 40, 4 * 1024 * 1024, 31
local MAX_FILES, LOAD_BUDGET, TIME_BUDGET, AFTER_WILD, FILE_SLOW = 64, 2, 0.1, 24, 5
local CACHE, MISSING, DONE, PAT_KEY, WILD, OPT, BUDGET, PAT_COST = 4096, 3000, 4096, 160, 2, 3, 0.001, 0.00025
-- my own texts I renamed: a language's entry for the old text translates the new one too, until it has its own (the
-- old texts as released, in capitals as a language's keys are taken: the compact look's rows are under its own
-- heading now)
local RENAMED = { ['MENU OPACITY % (COMPACT LOOK)'] = 'MENU OPACITY (%)', ['MENU POSITION (COMPACT LOOK)'] = 'MENU POSITION' }

-- a language file's code with its strings and comments taken out (each string as one '"', each comment as a space)
-- -> code, or nil, why
local function code_of(src)
  local out, i, n = {}, 1, #src
  while i <= n do
    local j = s_find(src, '[%-%[\'"]', i) or n + 1
    if j > i then out[#out + 1] = s_sub(src, i, j - 1); i = j end
    if i > n then break end
    local c = s_sub(src, i, i)
    local lvl = c == '-' and s_sub(src, i + 1, i + 1) == '-' and s_match(src, '^%[(=*)%[', i + 2)
    if c == '-' and s_sub(src, i + 1, i + 1) == '-' then
      if lvl then
        local close = ']' .. lvl .. ']'
        local _, e = s_find(src, close, i + 4 + #lvl, true)
        if not e then return nil, 'a long comment that never ends' end
        i = e + 1
      else
        local e = s_find(src, '[\r\n]', i + 2)       -- (a short comment ends at a CR too)
        i = e and e + 1 or n + 1
      end
      out[#out + 1] = ' '
    elseif c == '[' and s_match(src, '^%[=*%[', i) then
      local l2 = s_match(src, '^%[(=*)%[', i)
      local close = ']' .. l2 .. ']'
      local _, e = s_find(src, close, i + 2 + #l2, true)
      if not e then return nil, 'a long string that never ends' end
      out[#out + 1] = '"'
      i = e + 1
    elseif c == '"' or c == "'" then
      local j2 = i + 1
      while true do
        local k = s_find(src, c == '"' and '[\\\r\n"]' or "[\\\r\n']", j2)
        local ch = k and s_sub(src, k, k)
        if not k or ch == '\n' or ch == '\r' then return nil, 'a string that never ends' end
        if ch == '\\' then
          j2 = k + 2
          if s_sub(src, k + 1, k + 2) == '\r\n' or s_sub(src, k + 1, k + 2) == '\n\r' then j2 = k + 3 end   -- (an escaped line end)
        else j2 = k; break end
      end
      out[#out + 1] = '"'
      i = j2 + 1
    else
      out[#out + 1] = c                 -- (a lone '-' or '[')
      i = i + 1
    end
  end
  return concat(out)
end
-- Lua 5.1's keywords; a language file may use only local, return, nil, true and false (and/or/elseif chains are slow
-- for Lua's own parser, and a data file needs none of the others)
local KEYWORDS = { ['and'] = true, ['break'] = true, ['do'] = true, ['else'] = true, ['elseif'] = true, ['end'] = true,
  ['for'] = true, ['function'] = true, ['goto'] = true, ['if'] = true, ['in'] = true, ['not'] = true, ['or'] = true,
  ['repeat'] = true, ['then'] = true, ['until'] = true, ['while'] = true }
-- -> true, or nil, why
local function data_only(src)
  local code, why = code_of(src)
  if not code then return nil, why end
  for w in s_gmatch(code, '[%a_][%w_]*') do
    if KEYWORDS[w] then return nil, '"' .. w .. '" (a language file is data only: no loops, functions or conditions)' end
  end
  if s_find(code, '..', 1, true) then return nil, '".." (a language file is data only: write each text whole)' end
  local bad = s_match(code, '[^%w_%s{}%[%]=,;%."]')
  if bad then return nil, s_format('%q (a language file is data only: no calls or operators)', bad) end
  -- (a call written without parentheses: a name, ] or } followed by a string or a table; return is the one word that
  -- may be followed by them. Each name is read whole, from its first character: linear in the code's length)
  for w in s_gmatch(code, '%f[%w_]([%w_]+)%s*["{]') do
    if w ~= 'return' then return nil, 'a call (a language file is data only)' end
  end
  if s_find(code, '[%]}]%s*["{]') then return nil, 'a call (a language file is data only)' end
  return true
end

-- the end of the set that starts at p[i] ('['), as Lua reads it -> its ']' index, or nil
local function set_end(p, i)
  local n = #p
  local j = i + 1
  if s_sub(p, j, j) == '^' then j = j + 1 end
  repeat
    if j > n then return nil end
    local ch = s_sub(p, j, j)
    j = j + 1
    if ch == '%' then
      if j > n then return nil end
      j = j + 1
    end
  until s_sub(p, j, j) == ']'
  return j
end
-- a pattern as I take it -> its number of captures, or nil, why
local function pattern_ok(p)
  if s_sub(p, 1, 1) ~= '^' then return nil, 'it must start with ^' end
  if s_find(p, '%z') then return nil, 'a zero byte' end
  local i, n, caps, wild, opt, after = 2, #p, 0, 0, 0, 0
  local stack, closed, lits = {}, {}, {}  -- (the captures open now, innermost last; the ones closed)
  while i <= n do
    local c = s_sub(p, i, i)
    local item, lit = true, nil          -- (a single character class: a quantifier may follow)
    if c == '(' then
      caps, item, i = caps + 1, false, i + 1
      if s_sub(p, i, i) == ')' then closed[caps], i = true, i + 1      -- (a position capture)
      else stack[#stack + 1] = caps end
    elseif c == ')' then
      if #stack == 0 then return nil, 'a ) with no (' end
      closed[stack[#stack]] = true
      stack[#stack] = nil
      item, i = false, i + 1
    elseif c == '$' and i == n then
      item, i = false, i + 1
    elseif c == '%' then
      local d = s_sub(p, i + 1, i + 1)
      if d == '' then return nil, 'it ends with %' end
      if d == 'b' then
        if i + 3 > n then return nil, '%b needs two characters' end
        item, i = false, i + 4
      elseif d == 'f' then
        if s_sub(p, i + 2, i + 2) ~= '[' then return nil, '%f needs a set' end
        local e = set_end(p, i + 2)
        if not e then return nil, 'a [ with no ]' end
        item, i = false, e + 1
      elseif d == 'z' then
        return nil, '%z (a zero byte)'
      elseif s_find(d, '%d') then
        local k = tonumber(d)
        if not closed[k] then return nil, 'a back reference to a capture not closed yet' end
        item, i = false, i + 2
      else
        if not s_find(d, '%w') then lit = d end
        i = i + 2
      end
    elseif c == '[' then
      local e = set_end(p, i)
      if not e then return nil, 'a [ with no ]' end
      i = e + 1
    else
      if c ~= '.' then lit = c end
      i = i + 1
    end
    if item then
      if wild > 0 then
        if lit then lits[#lits + 1] = lit else after = after + 1 end
      end
      local q = s_sub(p, i, i)
      if q == '*' or q == '+' or q == '-' then wild, i = wild + 1, i + 1
      elseif q == '?' then opt, i = opt + 1, i + 1 end
    end
  end
  if #stack ~= 0 then return nil, 'a ( with no )' end
  if wild > WILD then return nil, 'more than ' .. WILD .. ' of * + - (it could take too long)' end
  if opt > OPT then return nil, 'more than ' .. OPT .. ' of ? (it could take too long)' end
  if wild >= WILD and opt > 0 then return nil, WILD .. ' of * + - with a ? (it could take too long)' end
  if wild >= WILD and after > AFTER_WILD then return nil, 'more than ' .. AFTER_WILD .. ' items after the first of 2 * + - (it could take too long)' end
  if caps > 32 then return nil, 'more than 32 captures' end
  return caps, concat(lits)
end
-- a replacement as I take it: % followed by %, or by a capture the pattern has (%0 the whole match; %1 too when it
-- has none) -> true, or nil, why
local function replacement_ok(to, caps)
  local most = caps > 0 and caps or 1
  local i = 1
  while true do
    local k = s_find(to, '%', i, true)
    if not k then return true end
    local d = s_sub(to, k + 1, k + 1)
    if d ~= '%' then
      local v = tonumber(d)
      if not v or s_find(d, '%D') then return nil, 'a % not followed by % or a capture\'s number' end
      if v > most then return nil, 'a capture the pattern doesn\'t have (%' .. d .. ')' end
    end
    i = k + 2
  end
end
-- s cut to at most n bytes, between UTF-8 characters
local function utf8_cut(s, n)
  if #s <= n then return s end
  local e = n
  while e > 0 do
    local b = s_byte(s, e + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end       -- (the next byte starts a character: cut before it)
    e = e - 1
  end
  return s_sub(s, 1, e)
end

function M.install(ctx)
  local log = ctx.log
  local L = { langs = {}, by = {}, names = {}, on = nil, cur = {}, old = {}, n = 0, done = {}, ndone = 0, missing = {}, nmissing = 0,
              olddone = {}, piece = {}, oldpiece = {}, npiece = 0, dirty = false, at = 0, v = nil, frame = -1, spent = 0,
              resume = {}, nresume = 0,
              skipped = false }

  -- a language file's table: data only (above), run with nothing to reach
  local function run(rec)
    local ok, why = data_only(rec.src)
    if not ok then return nil, why end
    local chunk, err = loadstring(rec.src, '@' .. rec.name .. ' (language in ' .. rec.file .. ')')
    if not chunk then return nil, tostring(err) end
    setfenv(chunk, {})
    local t
    ok, t = pcall(chunk)
    if not ok then return nil, tostring(t) end
    if type(t) ~= 'table' then return nil, 'it must return a table' end
    return t
  end

  -- a pattern timed on texts that are hard for it (as long as it's ever tried on): over PAT_COST on one is too slow
  local PROBES = { ('A'):rep(PAT_KEY), ('A '):rep(PAT_KEY / 2), ('AB'):rep(PAT_KEY / 2), ('A1 '):rep(PAT_KEY / 3) }
  -- (timed in batches, at least 2 ms or 16 calls, as one call can be far under the clock's step; a first call far over
  -- the limit isn't tried again. timing.left: what's left of the file's budget for this, spent as it's used)
  local timing = { left = TIME_BUDGET }
  local function slow(from, to, lits)
    local clock = ctx.clock
    if not clock then return false end
    local probes = PROBES
    if lits and #lits > 1 then lits = s_sub(lits, 1, -2) end
    if lits and lits ~= '' then
      local most, best, cnt = nil, 0, {}
      for ch in s_gmatch(lits, '.') do cnt[ch] = (cnt[ch] or 0) + 1; if cnt[ch] > best then most, best = ch, cnt[ch] end end
      -- (and two made from the pattern's own literal characters after its first wildcard: hard texts for it)
      probes = { PROBES[1], PROBES[2], PROBES[3], PROBES[4], s_sub(s_rep(lits, floor(PAT_KEY / #lits) + 1), 1, PAT_KEY),
                 s_rep(most, PAT_KEY) }
    end
    for _, t in ipairs(probes) do
      local t0 = clock()
      pcall(s_gsub, t, from, to, 1)
      local one = clock() - t0
      timing.left = timing.left - one
      if one >= 0.0015 then return true end
      local n, t1 = 1, clock()
      while n < 16 and clock() - t1 < 0.002 do pcall(s_gsub, t, from, to, 1); n = n + 1 end
      local spent = clock() - t1
      timing.left = timing.left - spent
      if n > 1 and spent / (n - 1) > PAT_COST then
        -- (once more before refusing: on a clock with 1 ms steps one batch can read up to twice what it took)
        n, t1 = 1, clock()
        while n < 16 and clock() - t1 < 0.002 do pcall(s_gsub, t, from, to, 1); n = n + 1 end
        spent = clock() - t1
        timing.left = timing.left - spent
        if n > 1 and spent / (n - 1) > PAT_COST then return true end
      end
    end
    return false
  end
  -- a language's entries checked and taken in: only strings of a sane size; a pattern only if I take it (above)
  local function take(lang, t, rec)
    local said = 0
    local function bad(why)
      said = said + 1
      if said <= 5 then log(s_format('language %s (%s): %s', lang.name, rec.file, why))
      elseif said == 6 then log(s_format('language %s (%s): more left out (only the first 5 are named)', lang.name, rec.file)) end
    end
    if type(t.code) == 'string' and #t.code <= 16 then lang.code = (s_gsub(t.code, '%c', '')) end   -- (the later file's)
    if type(t.text) == 'table' then
      for k, v in pairs(t.text) do
        if type(k) ~= 'string' or type(v) ~= 'string' or #k == 0 or #k > MAX_LEN or #v > MAX_LEN then
          bad('an entry that is not a text of 1 to ' .. MAX_LEN .. ' bytes was left out')
        elseif lang.ntext >= MAX_TEXTS and not lang.text[s_upper(k)] then
          bad('more than ' .. MAX_TEXTS .. ' texts: the rest were left out'); break
        else
          local key = s_upper(k)
          if not lang.text[key] then lang.ntext = lang.ntext + 1 end
          lang.text[key], lang.alias[key] = v, nil
          local new = RENAMED[key]
          if new and (not lang.text[new] or lang.alias[new]) then
            if not lang.text[new] then lang.ntext = lang.ntext + 1 end
            lang.text[new], lang.alias[new] = v, true
          end
        end
      end
    end
    if type(t.patterns) == 'table' then
      -- this file's patterns first (a later file wins), then the ones before it, 200 at most
      local mine = {}
      for _, p in ipairs(t.patterns) do
        local from, to = type(p) == 'table' and p[1], type(p) == 'table' and p[2]
        if #mine >= MAX_PATTERNS then bad('more than ' .. MAX_PATTERNS .. ' patterns: the rest were left out'); break end
        local caps, why = nil, 'a pattern and its replacement must be texts of 1 to ' .. MAX_LEN .. ' bytes'
        if type(from) == 'string' and type(to) == 'string' and #from > 0 and #from <= MAX_LEN and #to <= MAX_LEN then
          local lits
          caps, why = pattern_ok(from)
          if caps then lits = why; why = nil end
          if caps then
            local rok, rwhy = replacement_ok(to, caps)
            if not rok then caps, why = nil, rwhy
            elseif timing.left <= 0 then caps, why = nil, 'past the time for checking this file\'s patterns'
            elseif not pcall(s_find, '', from) or not pcall(s_gsub, 'X', from, to, 1) then caps, why = nil, 'Lua doesn\'t take it'
            elseif slow(from, to, lits) then caps, why = nil, 'too slow on a long text (over 0.25 ms)' end
          end
        end
        if caps then mine[#mine + 1] = { from, to }
        else bad(s_format('pattern %s left out: %s', type(from) == 'string' and s_format('%q', s_sub(from, 1, 60)) or '?', why)) end
      end
      for _, p in ipairs(lang.patterns) do
        if #mine >= MAX_PATTERNS then break end
        mine[#mine + 1] = p
      end
      lang.patterns = mine
    end
  end

  -- a file's table taken into its language (by name)
  function L.taken(t, rec)
    local name = type(t.name) == 'string' and utf8_cut((s_gsub(t.name, '%c', ' ')), MAX_NAME) or ''
    if name == '' or name == 'English' then name = rec.name end
    local lang = L.by[name]
    if not lang then
      lang = { name = name, text = {}, ntext = 0, patterns = {}, files = {}, alias = {} }
      L.by[name] = lang
      L.langs[#L.langs + 1] = lang
    end
    lang.files[#lang.files + 1] = rec.name
    take(lang, t, rec)
  end
  -- the language files found, in patch order (the higher patch last, so its entries win)
  function L.load(found)
    sort(found, function(a, b) if a.patch ~= b.patch then return a.patch < b.patch end return a.seq < b.seq end)
    local clock = ctx.clock
    local t_start = clock and clock() or 0
    local first = #found - MAX_FILES                 -- (past 64 files, the lowest patches are the ones left out)
    for i, rec in ipairs(found) do
      -- (breadcrumbed, reading through taking in, under its name and its source's fingerprint: a file that ends the
      -- game is skipped from the next launch on; a changed file is tried again. 64 files and 2 s at most in all)
      local t, err = nil, nil
      if #rec.src > MAX_SRC then err = 'more than ' .. MAX_SRC .. ' bytes'
      elseif i <= first then err = 'more than ' .. MAX_FILES .. ' language files (the higher patches are read)'
      elseif clock and clock() - t_start > LOAD_BUDGET then err = 'language files took more than ' .. LOAD_BUDGET .. ' s to read'
      else
        local key = rec.name .. '|lang:' .. (ctx.fp and ctx.fp(rec.src) or #rec.src)
        if ctx.skipped and ctx.skipped(key) then err = 'it ended the game before (this file stays off; a changed one is tried)'
        else
          if ctx.crumb then ctx.crumb('> ' .. key) end
          timing.left = TIME_BUDGET
          local t0 = clock and clock() or 0
          local ok
          ok, t, err = pcall(run, rec)
          if not ok then t, err = nil, tostring(t) end
          if t then
            local tok, terr = pcall(L.taken, t, rec)
            if not tok then t, err = nil, tostring(terr) end
          end
          if ctx.crumb then ctx.crumb('< ' .. key) end
          -- (a file that took this long once (Lua's own reading of it can be slow for some files) is skipped from the
          -- next launch on, as one that ended the game; a changed file is tried again)
          local took = clock and clock() - t0 or 0
          if took > FILE_SLOW and ctx.skip_now then
            ctx.skip_now(key)
            log(s_format('language file %s (%s) took %.1f s to read: skipped from the next launch on', rec.name, rec.file, took))
          end
        end
      end
      if not t then
        log(s_format('language file %s (%s) not used: %s', rec.name, rec.file, err))
      end
    end
    sort(L.langs, function(a, b) return a.name < b.name end)
    -- (the languages' own names, shown in my menu as they are: never noted missing)
    L.names = { ENGLISH = true }

    -- (my menu's choice row takes 32 at most: English and 31 languages)
    for i = #L.langs, MAX_LANGS + 1, -1 do
      log(s_format('language %s left out: more than %d languages', L.langs[i].name, MAX_LANGS))
      L.by[L.langs[i].name] = nil
      L.langs[i] = nil
    end
    for _, lang in ipairs(L.langs) do
      L.names[s_upper(lang.name)] = true
      log(s_format('language: %s (%d texts, %d patterns; %s)', lang.name, lang.ntext, #lang.patterns, concat(lang.files, ', ')))
    end
  end

  -- a text as a Lua string on one line (escapes for line ends and control characters)
  local function quoted(k)
    return '"' .. s_gsub(k, '[%c"\\]', function(ch)
      if ch == '\n' then return '\\n' elseif ch == '\r' then return '\\r' elseif ch == '"' then return '\\"'
      elseif ch == '\\' then return '\\\\' end
      return s_format('\\%03d', s_byte(ch))
    end) .. '"'
  end
  -- the texts with no entry, as lines for the text table; written when there are new ones, at most every 2 minutes,
  -- at shutdown, and before another language is picked
  function L.flush(now, final)
    if not L.dirty or not L.on then return end
    if not final and now < L.at then return end
    L.at = now + 120
    local keys = {}
    for k in pairs(L.missing) do keys[#keys + 1] = k end
    sort(keys)
    local f = ctx.open(ctx.DIR .. ctx.FILES .. '_lang_missing.txt', 'w')
    if not f then return end
    L.dirty = false
    f:write(s_format('-- texts drawn with no entry in %s (%d), ready for its text table:\n', L.on.name, #keys))
    for _, k in ipairs(keys) do local q = quoted(k); f:write('  [', q, '] = ', q, ',\n') end
    f:close()
  end

  -- the language picked in my menu (by its row's number), saved by name when save is true
  local function pick(v, save)
    if L.dirty and L.on then pcall(L.flush, 0, true) end
    L.v = v
    L.on = (type(v) == 'number' and v > 1) and L.langs[v - 1] or nil
    L.cur, L.old, L.n, L.done, L.olddone, L.ndone, L.resume, L.nresume = {}, {}, 0, {}, {}, 0, {}, 0
    L.piece, L.oldpiece, L.npiece = {}, {}, 0
    L.missing, L.nmissing, L.dirty = {}, 0, false
    if save and L.put then L.put('lang_name', L.on and L.on.name or 'English') end
    log('language: ' .. (L.on and L.on.name or 'English'))
  end
  local function sync()
    local r = L.rowref
    if r and r.value ~= L.v then pick(r.value, true) end     -- (the row changed in my menu)
  end

  -- the row in my menu (only when there is a language to pick): English, then the languages by name. With one
  -- language installed and none picked before, it's on (installing it is the player's choice; saved then, so a second
  -- language added later doesn't turn it off); with more, English until one is picked. A saved language that isn't
  -- installed this launch gives English without forgetting it. get / put / set: the loader's own saved values, and
  -- setting the row.
  function L.row(loader_option, get, put, set)
    if #L.langs == 0 then return end
    local choices = { 'English' }
    for _, lang in ipairs(L.langs) do choices[#choices + 1] = lang.name end
    local row = loader_option('lang', { type = 'choice', label = 'Language', choices = choices,
                                        default = #L.langs == 1 and 2 or 1, section = 'menu' })
    if not row then return end
    L.rowref, L.put = row, put
    local saved = get and get('lang_name')
    if type(saved) == 'string' then
      local at = nil
      for i, c in ipairs(choices) do if c == saved then at = i; break end end
      if not at then log('language ' .. saved .. ' (picked before) is not installed: English'); at = 1 end
      if at ~= row.value and set then set(row, at) end
    end
    pick(row.value, type(saved) ~= 'string')
    return row
  end

  -- a text drawn as it is from now on (a translation, or a text made from one: fitted with '...', a wrapped line),
  -- unless it is itself a text the language has an entry for
  -- (two generations, as the cache: a text drawn again stays)
  local function done(s)
    if L.done[s] or L.on.text[s_upper(s)] then return end
    if L.ndone >= DONE then L.olddone, L.done, L.ndone = L.done, {}, 0 end
    L.done[s], L.ndone = true, L.ndone + 1
  end
  local function was_done(s)
    if L.done[s] then return true end
    if L.olddone[s] then done(s); return true end
    return false
  end

  -- the text to draw: the language's text for it, else its first pattern that matches, else the text itself. Kept per
  -- text drawn (two generations: a text drawn again stays), so a menu drawn every frame asks the tables once per text.
  function L.tr(s)
    sync()
    local lang = L.on
    if not lang or type(s) ~= 'string' or s == '' or not s_find(s, '%a') or was_done(s) then return s end
    local c = L.cur[s]
    if c == nil then
      c = L.old[s]
      if c ~= nil then
        if L.n >= CACHE then L.old, L.cur, L.n = L.cur, {}, 0 end
        L.cur[s], L.n = c, L.n + 1
      end
    end
    if c ~= nil then return c end
    local key = s_upper(s)
    local out = lang.text[key]
    if not out and #key <= PAT_KEY and lang.patterns[1] then
      -- (pattern work has a budget a frame, looked at after each pattern: a text past it is drawn as it is, not kept,
      -- and tried on from the next pattern in a later frame; L.skipped tells a caller that keeps what it made)
      local f = ctx.frame and ctx.frame() or 0
      if f ~= L.frame then L.frame, L.spent = f, 0 end
      if L.spent >= BUDGET then L.skipped = true; return s end
      local clock = ctx.clock
      local t0 = clock and clock() or 0
      local ps = lang.patterns
      local i = L.resume[s] or 1
      while ps[i] do
        local p = ps[i]
        local ok, r, m = pcall(s_gsub, key, p[1], p[2], 1)
        if not ok then
          log(s_format('language %s: pattern %q dropped: %s', lang.name, p[1], tostring(r)))
          table.remove(ps, i)
          L.resume, L.nresume = {}, 0            -- (the patterns after it moved up one)
        else
          if m > 0 then
            if #r <= 2 * MAX_LEN then out = r end
            break
          end
          i = i + 1
        end
        if clock and L.spent + (clock() - t0) >= BUDGET and ps[i] then
          L.spent = BUDGET
          if not L.resume[s] then
            if L.nresume >= 1000 then L.resume, L.nresume = {}, 0 end
            L.nresume = L.nresume + 1
          end
          L.resume[s], L.skipped = i, true
          return s
        end
      end
      if clock then L.spent = L.spent + (clock() - t0) end
      if L.resume[s] then L.resume[s], L.nresume = nil, L.nresume - 1 end
    end
    if not out then
      out = s
      if L.nmissing < MISSING and not L.missing[key] and #key <= MAX_LEN and not L.names[key] and s_find(key, '%a%a')
         and not s_find(key, '%d')
         and not L.piece[s] and not L.oldpiece[s] and s_sub(s, -3) ~= '...' then
        L.missing[key] = true
        L.nmissing = L.nmissing + 1
        L.dirty = true
      end
    else
      done(out)
    end
    if L.n >= CACHE then L.old, L.cur, L.n = L.cur, {}, 0 end
    L.cur[s], L.n = out, L.n + 1
    return out
  end

  -- (the pieces of untranslated texts: lines, cut texts; two generations, as the cache. Never noted missing: the whole
  -- text is the one to translate)
  local function piece(s)
    if L.piece[s] then return end
    if L.npiece >= DONE then L.oldpiece, L.piece, L.npiece = L.piece, {}, 0 end
    L.piece[s], L.npiece = true, L.npiece + 1
  end
  -- src: the text it was made from. Only a translated source (or a translation) makes its pieces kept, drawn as they
  -- are from then on; an untranslated source's pieces are looked up again (they may be texts of their own), never
  -- noted missing; a source whose patterns are still being tried makes nothing kept
  function L.keep(s, src)
    if not L.on or type(s) ~= 'string' or s == '' then return s end
    if src ~= nil then
      local c = L.cur[src]
      if c == nil then c = L.old[src] end
      -- (only the lines of a text that was translated, or is a translation: an untranslated one's lines may be texts
      -- of their own)
      if c == nil then
        if not was_done(src) then return s end
      elseif c == src then piece(s); return s end
    end
    done(s)
    return s
  end

  function L.active() sync(); return L.on and L.on.name or nil, L.on and L.on.code or nil end
  -- this frame's pattern budget already spent (a caller with texts that can wait tries again next frame)
  function L.budget_spent()
    local f = ctx.frame and ctx.frame() or 0
    return f == L.frame and L.spent >= BUDGET
  end
  return L
end

M.code_of, M.data_only, M.pattern_ok, M.replacement_ok, M.utf8_cut = code_of, data_only, pattern_ok, replacement_ok, utf8_cut
return M
end)()
-- @@END lang.lua@@
local overrides = {}                     -- what each addon's environment gets on top of G (filled at start-up)

-- ------------------------------------------------------------------ files
-- In the game's own folder, %APPDATA%\Arrowhead\Helldivers2: every player has it (the game keeps its settings there),
-- and the game's Lua can't make a folder of its own (only a command window could, and I won't start one under Easy
-- Anti-Cheat). Any of my files still at the root of %LOCALAPPDATA% (their old place) are brought over once, below.
-- If the game's folder can't be written, they stay in %LOCALAPPDATA%.
-- (services.OLD_DIR / GAME_DIR: fields, not locals, to spare the loader's main function locals.)
local DIR = ''
if type(os_) == 'table' and type(os_.getenv) == 'function' then
  local okl, ldir = pcall(os_.getenv, 'LOCALAPPDATA')
  if okl and type(ldir) == 'string' and ldir ~= '' then services.OLD_DIR = ldir .. '\\' end
  local ok, dir = pcall(os_.getenv, 'APPDATA')
  if ok and type(dir) == 'string' and dir ~= '' then services.GAME_DIR = dir .. '\\Arrowhead\\Helldivers2\\' end
  local f = services.GAME_DIR and type(io_) == 'table' and io_.open(services.GAME_DIR .. FILES .. '.log', 'a')
  if f then f:close(); DIR = services.GAME_DIR else DIR = services.OLD_DIR or '' end
end
local LOG_FILE, STATE_FILE, TRACE_FILE = DIR .. FILES .. '.log', DIR .. FILES .. '_state.txt', DIR .. FILES .. '_trace.txt'

local function now()
  if type(os_) == 'table' then local ok, d = pcall(os_.date, '%H:%M:%S'); if ok then return d end end
  return '?'
end

local function open(path, mode)
  if type(io_) ~= 'table' then return nil end
  local ok, f = pcall(io_.open, path, mode)
  if ok then return f end
end

-- Before the log starts fresh (it passed 1 MB), I move what's in it to the end of chef_loader.old.log, so the last few
-- launches are still there when I need them. The old log keeps its newest whole launches within 4 MB: I cut it only at a
-- "==== ... starting" line, and a newest launch alone over 4 MB stays whole (one launch writes LOG_CAP at most). Both
-- files are read once and the result goes in through a .tmp file and a swap with a .bak, so a step that fails (a locked
-- file, a full disk) leaves the old log as it was. It returns the line the fresh log gets about it. A .bak found with no
-- old log is a swap a crash cut short: I take it as the old log.
-- (a field, not a local: the loader's main function is near its locals limit)
services.log_keep = function()
  local OLD = LOG_FILE:sub(1, -5) .. '.old.log'
  local TMP, BAK, KEEP, START = OLD .. '.tmp', OLD .. '.bak', 4 * 1024 * 1024, '\n[^\n|]* s | ==== '
  local function no(why) return fmt("couldn't keep the last log's launches in %s.old.log (%s); this log starts fresh as before", FILES, why) end
  if type(os_) ~= 'table' or type(os_.rename) ~= 'function' or type(os_.remove) ~= 'function' then return no('no os.rename') end
  local f = open(LOG_FILE, 'rb')
  local s = f and f:read('*a')
  if f then f:close() end
  if type(s) ~= 'string' then return no("the log can't be read") end
  local g = open(OLD, 'rb')
  local had = g ~= nil
  g = g or open(BAK, 'rb')
  local old = g and g:read('*a') or ''
  if g then g:close() end
  if old ~= '' and old:sub(-1) ~= '\n' then old = old .. '\n' end
  s = old .. s
  old = nil
  if #s > KEEP then
    local p = s:find(START, #s - KEEP)
    if not p then
      -- the newest launch alone is over 4 MB: from its start line (or, with no start lines at all, from a line start)
      p = s:find('^[^\n|]* s | ==== ') and 0
      local q = s:find(START, 1)
      while q do p = q; q = s:find(START, q + 1) end
      p = p or s:find('\n', #s - KEEP, true)
    end
    if p and p > 0 then s = s:sub(p + 1) end
  end
  local w = open(TMP, 'wb')
  if not w then return no("can't write " .. FILES .. '.old.log.tmp') end
  local okw, r = pcall(w.write, w, s)
  local okc, c = pcall(w.close, w)
  local v = open(TMP, 'rb')
  local size = v and v:seek('end')
  if v then v:close() end
  if not (okw and r and okc and c and size == #s) then
    pcall(os_.remove, TMP)
    return no(FILES .. '.old.log.tmp came out short: is the disk full?')
  end
  -- (Windows renames onto no existing file, so the old log steps aside as .bak until the new one is in place)
  if had then
    pcall(os_.remove, BAK)
    local ok1, r1 = pcall(os_.rename, OLD, BAK)
    if not (ok1 and r1) then pcall(os_.remove, TMP); return no("it's in use") end
  end
  local ok2, r2 = pcall(os_.rename, TMP, OLD)
  if not (ok2 and r2) then
    if had then pcall(os_.rename, BAK, OLD) end
    pcall(os_.remove, TMP)
    return no("it can't be replaced")
  end
  pcall(os_.remove, BAK)
  return fmt('the last log passed 1 MB, so this one starts fresh; its launches are now at the end of %s.old.log (%d KB: the newest whole launches within 4 MB)',
    FILES, floor(#s / 1024))
end

local log_file, log_written = nil, 0
local function log(text)
  if log_written > LOG_CAP then return end
  local note
  if not log_file then
    -- a fresh log each launch once it passes 1 MB, its launches kept in the old log first (once a launch)
    local f = open(LOG_FILE, 'r')
    local big = false
    if f then local size = f:seek('end'); big = size and size > 1024 * 1024; f:close() end
    if big and not services.log_kept then
      services.log_kept = true
      local ok, n = pcall(services.log_keep)
      note = ok and n or fmt("couldn't keep the last log's launches in %s.old.log (%s); this log starts fresh as before", FILES, tostring(n))
    end
    log_file = open(LOG_FILE, big and 'w' or 'a')
  end
  local line = fmt('%s %6.1f s | %s', now(), elapsed, text)
  log_written = log_written + #line + 1
  if log_written > LOG_CAP then line = line .. '\n(the log is full for this launch)' end
  if log_file then pcall(log_file.write, log_file, line .. '\n'); pcall(log_file.flush, log_file)
  elseif type(print) == 'function' then pcall(print, '[' .. LOADER .. '] ' .. line) end
  if note then log(note) end
end
loader_log = log

-- The one-time move from %LOCALAPPDATA%: the crash state, the saved settings, dev mode's list and the last
-- launch's breadcrumbs (before I read them below). Each is copied, checked and then removed from the old place; a file
-- already in the new place wins. The old log stays where it is, with a last line saying where the log went. Saved
-- tables (chef_data_*.lua) are picked up from the old place by chef.load_table the first time a mod asks.
do
  local old = services.OLD_DIR
  if old and DIR ~= '' and old ~= DIR then
    local moved = {}
    for _, suffix in ipairs({ '_state.txt', '_settings.txt', '_dev.txt', '_trace.txt' }) do
      local from, to = old .. FILES .. suffix, DIR .. FILES .. suffix
      local f = open(from, 'rb')
      if f then
        local text = f:read('*a') or ''
        f:close()
        local g = open(to, 'rb')
        local done = false
        if g then g:close(); done = true
        else
          local w = open(to, 'wb')
          if w then
            local okw = pcall(w.write, w, text)
            w:close()
            local r = open(to, 'rb')
            if r then done = okw and r:read('*a') == text; r:close() end
          end
        end
        if done then
          if type(os_) == 'table' then pcall(os_.remove, from) end
          moved[#moved + 1] = FILES .. suffix
        end
      end
    end
    if #moved > 0 then
      services.MOVED = moved
      local l = open(old .. FILES .. '.log', 'a')
      if l then
        pcall(l.write, l, fmt('%s %s moved its files to %%APPDATA%%\\Arrowhead\\Helldivers2 (%s); this log is no longer written\n',
          now(), LOADER, concat(moved, ', ')))
        l:close()
      end
    end
  end
end

-- ------------------------------------------------------------------ crash learning
-- State kept between launches: "skip: <key>" (a call that crashed the game) and "off: <addon> <fingerprint>
-- <reason>" (an addon I turned off; it comes back on its own when its file changes, i.e. an update, and its skips go).
-- "rule: 3": a first call that never returned, or a per-frame job (drawing, a scan) running when the game died, is only
-- suspected the first time ("suspect: <key>") and skipped if the next launch dies in it again: the game closed from
-- outside mid-call, or ending for its own reasons mid-frame, mustn't switch a call or a feature off for good. Skips from
-- the older rules are dropped once (except rule 2's certain ones). "version: <v>": the loader that wrote it. My own
-- skips (loader|...) are dropped when the loader changes: an update may well have fixed what crashed, and a skip of
-- mine can take away the drawing for every mod.
-- "skip: shared|Unit.<call>:<kind>": a call on one kind of unit that ended the game for one mod, refused for every
-- mod (the engine's answer for that kind, whoever asks). Dropped when the loader or the game's build ("build: <id>")
-- changes: either may well have changed what crashed.
-- "strikes: <addon> <n> <fingerprint>": launches in a row it ended the game (counted two at a time, as a suspicion is
-- confirmed); at tr.CRASH_STRIKES or more it's turned off. A
-- launch it didn't end (a clean one, or another's crash) starts the count over; the line stays (at 0) while it has
-- skipped calls other than a language file's, so a change of its file tries them again, as for a mod I turned off.
-- I record the fingerprint of the file that crashed when the trace names it (its "f" line); without one (a trace
-- without them, or a boot script, whose key carries its fingerprint) it's 'pending' until a file is found. One
-- still 'pending' at 0 has no file to compare: a mod's I mark 'gone', a boot script's goes (starter.unfound).
local RULE = '3'
local skip, off, dropped, suspect = {}, {}, {}, {}
-- The crash trace's state (below) and the crash learning's: tr.shared (the refusals shared with every mod), tr.strikes
-- (name -> { n, fp }) and tr.CRASH_STRIKES, the launches in a row a mod ends the game before it's turned off (its call
-- is skipped once two launches in a row ended in it). (Fields, not locals: the loader is near Lua 5.1's 200 locals.)
local tr = { bytes = 0, firsts = {}, singles = {}, last_tick = -1, cap = 200 * 1024, said = false,
  shared = { n = 0, of = {}, said = {} }, strikes = {}, CRASH_STRIKES = 3, fps = {}, crash_fps = {}, hseq = {}, hn = 0,
  -- the mods (and other mods' boot scripts, boot:<fingerprint>) the player asked to try again from my options menu
  -- (CRASH RECOVERY): their off, strikes, skip and suspect lines are left out of the state saved from then on, so the
  -- next launch starts them (and their skipped and suspected calls) afresh; this launch keeps them as they are
  retry = {} }
-- v1.fp: 1.0.0's fingerprint (every 7th byte). An entry 1.0.0 wrote for a mod or boot script is matched by it and
-- saved under the new fingerprint, whichever launch that source is next seen in.
local v1 = {}
do
  -- (a .tmp left by a save that wrote the new state but couldn't put it in place is the newest whole copy)
  local f = open(STATE_FILE, 'r') or open(STATE_FILE .. '.tmp', 'r')
  if f then
    local rule, old, ver = nil, {}, nil
    for line in f:lines() do
      rule = line:match('^rule: (%S+)$') or rule
      ver = line:match('^version: (%S+)$') or ver
      tr.shared.build = line:match('^build: (.+)$') or tr.shared.build
      local k = line:match('^skip: (.+)$')
      if k then old[#old + 1] = k end
      local sp = line:match('^suspect: (.+)$')
      if sp then suspect[sp] = true end
      local name, fp, why = line:match('^off: (%S+) (%S+) (.*)$')
      if name then off[name] = { fp = fp, why = why } end
      local sn, sc, sf = line:match('^strikes: (%S+) (%d+) (%S+)$')
      if sn then tr.strikes[sn] = { n = tonumber(sc), fp = sf } end
    end
    f:close()
    for _, k in ipairs(old) do
      -- rule 2's skips stay, except a job's (loader|draw:...): those were blamed on one exit, which rule 3 doesn't do
      local keep = rule == RULE or (rule == '2' and not k:match('|draw:'))
      if keep and ver ~= VERSION and (k:match('^loader|') or k:match('^shared|')) then keep = false end
      if keep then skip[k] = true else dropped[#dropped + 1] = k end
      if keep and k:match('^shared|') then tr.shared.n = tr.shared.n + 1 end
    end
    -- (the loader changed since the last launch: a crash from it isn't shared, it may be one I've fixed)
    tr.shared.moved = ver ~= VERSION
  end
end
-- The shared key for a mod's call on a kind of unit: only Unit calls, the kind (a string) as the hex of its resource id:
-- the last run of 8 to 16 hex digits in it, leading zeros left out, so a mod's own label around it ("r<hex>",
-- "0x<hex>", "cape_<hex>_lod") meets every other spelling of that kind; else nil (nothing shared).
function tr.shared.key_of(name, kind)
  if sub(name, 1, 5) ~= 'Unit.' or type(kind) ~= 'string' then return nil end
  local hex
  for run in kind:lower():gmatch('%x+') do
    run = run:gsub('^0+', '')
    if #run >= 8 and #run <= 16 then hex = run end
  end
  if not hex then return nil end
  return 'shared|' .. name .. ':' .. hex
end
-- Written to a .tmp first and put in place only when the whole of it was written and closed, so a full or locked disk
-- never leaves me with half a state (every skip and every mod turned off would be forgotten). Returns true when saved.
local save_state
do
  local said = false
  local function failed(why)
    if not said then said = true; log('could not save the crash state (' .. why .. '); the last one saved is kept') end
    return false
  end
  save_state = function()
    tr.state_dirty = false               -- (the whole state goes out: nothing marked is left to save)
    local out = { 'rule: ' .. RULE, 'version: ' .. VERSION }
    if tr.shared.now or tr.shared.build then out[#out + 1] = 'build: ' .. (tr.shared.now or tr.shared.build) end
    for k in pairs(suspect) do if not tr.retry[k:match('^(.-)|') or ''] then out[#out + 1] = 'suspect: ' .. k end end
    local keys = {}
    for k in pairs(skip) do if not tr.retry[k:match('^(.-)|') or ''] then keys[#keys + 1] = k end end
    sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = 'skip: ' .. k end
    local names = {}
    for n in pairs(off) do if not tr.retry[n] then names[#names + 1] = n end end
    sort(names)
    for _, n in ipairs(names) do out[#out + 1] = 'off: ' .. n .. ' ' .. off[n].fp .. ' ' .. off[n].why end
    names = {}
    for n in pairs(tr.strikes) do if not tr.retry[n] then names[#names + 1] = n end end
    sort(names)
    for _, n in ipairs(names) do
      local s = tr.strikes[n]
      out[#out + 1] = 'strikes: ' .. n .. ' ' .. s.n .. ' ' .. s.fp
    end
    local text = concat(out, '\n') .. '\n'
    local tmp = STATE_FILE .. '.tmp'
    local f = open(tmp, 'w')
    if not f then return failed('it can\'t be opened') end
    local okw, w = pcall(f.write, f, text)
    local okc, c = pcall(f.close, f)
    local rm = type(os_) == 'table' and os_.remove
    if not (okw and w and okc and c) then
      if rm then pcall(rm, tmp) end
      return failed('the disk refused the write')
    end
    local mv = type(os_) == 'table' and os_.rename
    if type(mv) ~= 'function' or type(rm) ~= 'function' then
      -- no rename here: the .tmp proved there's room, so the state itself is written the same way
      f = open(STATE_FILE, 'w')
      if not f then return failed('it can\'t be opened') end
      okw, w = pcall(f.write, f, text)
      okc, c = pcall(f.close, f)
      if not (okw and w and okc and c) then return failed('the disk refused the write') end
      return true
    end
    pcall(rm, STATE_FILE)                -- (Windows won't rename onto a file that's there)
    local okr, r = pcall(mv, tmp, STATE_FILE)
    if not (okr and r) then return failed('it couldn\'t be put in place; it\'s read from the .tmp next launch') end
    return true
  end
end

-- What killed the last launch, read from its trace before I start a new one.
-- "> owner|call" / "< owner|call" = making that call for the first time / it returned (suspected if it never returned);
-- ">> owner|job @<s>" / "<< owner|job" = a per-frame job (suspected if still open and started within RECENT s);
-- "#### clean shutdown" = the game called shutdown(): nothing to blame.
-- "o <mod>|<option> @<s>" = an option changed in my menu then (blames nothing: it's said with a launch that ended).
-- "= owner|call" = that first call (a chef.call_kind one) took only the unit: a crash in it is the engine's answer for
-- that kind of unit, so it's shared with every mod (tr.shared.single); a call with arguments of the mod's own isn't.
-- "f <mod> <fingerprint>" = the file of that mod the launch that wrote it ran (tr.crash_fps): I count the crash
-- against that file, not against whatever is installed by now (an update put in before relaunching is a change).
local blamed, blamed_job = nil, false
do
  local f = open(TRACE_FILE, 'r')
  if f then
    local firsts, opened, order, last_t, clean, singles = {}, {}, {}, 0, false, {}
    -- (only whole lines: a last line with no newline is one the game died writing, half a key that would be blamed and
    -- skipped as if it were a call)
    local okr, all = pcall(f.read, f, '*a')
    for line in (okr and type(all) == 'string' and all or ''):gmatch('([^\n]*)\n') do
      if line:match('^#### clean shutdown') then clean = true end
      local one = line:match('^= (.+)$')
      if one then singles[one] = true end
      local fo, fp = line:match('^f (%S+) (%x+)$')
      if fo then tr.crash_fps[fo] = fp end
      local t = line:match('^t (%d+)$')
      if t then last_t = tonumber(t) end
      local o, at = line:match('^>> (.-) @(%d+)$')
      if o then opened[o] = tonumber(at); order[#order + 1] = o; last_t = max(last_t, tonumber(at))
      else
        -- "o <row> @<s>" = an option changed in my menu (the last one is said if the launch didn't shut down)
        o, at = line:match('^o (.-) @(%d+)$')
        if o then tr.crash_o, tr.crash_o_at = o, tonumber(at) end
      end
      local c = line:match('^<< (.+)$')
      if c then opened[c] = nil end
      -- first calls can nest (an addon's first update makes first calls of its own), so they're a stack
      local b = line:match('^> (.+)$')
      if b then firsts[#firsts + 1] = b end
      local r = line:match('^< (.+)$')
      if r then for i = #firsts, 1, -1 do if firsts[i] == r then table.remove(firsts, i); break end end end
    end
    f:close()
    -- (an option changed is a time it was still running, as a job's opening is)
    if tr.crash_o_at then last_t = max(last_t, tr.crash_o_at) end
    if clean then tr.crash_o, tr.crash_o_at = nil, nil else tr.crash_t = last_t end
    if not clean then
      blamed = firsts[#firsts]
      tr.shared.single = blamed ~= nil and singles[blamed] == true
      -- (the text GUI removal first: holds opened after it in the same frame are only drawing that followed it)
      local rk = 'loader|text:reclaim'
      if not blamed and opened[rk] and last_t - opened[rk] <= RECENT then blamed, blamed_job = rk, true end
      if not blamed then
        for i = #order, 1, -1 do
          local k = order[i]
          if opened[k] and last_t - opened[k] <= RECENT then blamed, blamed_job = k, true; break end
        end
      end
    end
  end
end

local trace = open(TRACE_FILE, 'w')
if not trace then log('the crash trace can\'t be opened: a call that crashes the game this launch won\'t be learned from') end
-- An error as text for the log, whatever it is: an error object whose __tostring fails mustn't raise again in here.
function tr.why(e)
  if type(e) == 'string' then return e end
  local ok, s = pcall(tostring, e)
  if ok and type(s) == 'string' then return s end
  return 'an error (' .. type(e) .. ') that can\'t be shown as text'
end
-- one write that the disk refused is said once: from then on the crash guard is blind for this launch
function tr.failed()
  if not tr.said then tr.said = true; log('the crash trace can\'t be written: a call that crashes the game this launch may not be learned from') end
end
local held = {}                          -- the per-frame jobs open now: key -> the second it opened
-- The trace only has to tell the next launch what was open when the game died. When it passes 200 KB I write it
-- again with only that: the last time stamp, the jobs held (">> key @s"), the last option changed ("o"), the first
-- calls that haven't returned,
-- each with its "=" line when it took only the unit (tr.singles: key -> true from its "=" until it returns), after
-- the mods' "f" lines (tr.fps).
local function crumb(line)
  -- one breadcrumb is one line: a mod's text in a key (chef.call_kind's kind) can't add lines of its own and make the
  -- next launch blame another mod or a loader job
  if line:find('%c') then line = line:gsub('%c', '?') end
  if not trace then return end
  local c2 = sub(line, 1, 2)
  if c2 == '> ' then tr.firsts[#tr.firsts + 1] = sub(line, 3)
  elseif c2 == '< ' then
    local k = sub(line, 3)
    tr.singles[k] = nil
    for i = #tr.firsts, 1, -1 do if tr.firsts[i] == k then table.remove(tr.firsts, i); break end end
  elseif c2 == '= ' then tr.singles[sub(line, 3)] = true
  elseif c2 == 'f ' then
    local o, p = line:match('^f (%S+) (%x+)$')
    if o then tr.fps[o] = p end
  end
  tr.bytes = tr.bytes + #line + 1
  if tr.bytes > tr.cap then
    pcall(trace.close, trace)
    trace = open(TRACE_FILE, 'w')
    if not trace then tr.failed(); return end
    local out = {}
    for o, p in pairs(tr.fps) do out[#out + 1] = 'f ' .. o .. ' ' .. p end
    if tr.last_tick >= 0 then out[#out + 1] = 't ' .. tr.last_tick end
    -- (the jobs held in the order they opened, as the trace had them: the next launch blames the last one open, so in
    -- pairs order my own drawing, held since start-up, could come last and take the blame from a mod's job)
    local hs, sq = {}, tr.hseq or {}
    for k in pairs(held) do hs[#hs + 1] = k end
    table.sort(hs, function(x, y)
      if held[x] ~= held[y] then return held[x] < held[y] end
      if (sq[x] or 0) ~= (sq[y] or 0) then return (sq[x] or 0) < (sq[y] or 0) end
      return x < y
    end)
    for _, k in ipairs(hs) do out[#out + 1] = fmt('>> %s @%d', k, held[k]) end
    if tr.opt and tr.opt.k then out[#out + 1] = fmt('o %s @%d', tr.opt.k, tr.opt.at) end
    for _, k in ipairs(tr.firsts) do
      if tr.singles[k] then out[#out + 1] = '= ' .. k end
      out[#out + 1] = '> ' .. k
    end
    local text = concat(out, '\n') .. (#out > 0 and '\n' or '')
    tr.bytes = #text
    local okw, w = pcall(trace.write, trace, text)
    if not (okw and w) then tr.failed() end
    -- a first call or an "f" line is already in what I just wrote (a first call twice would leave it open for the
    -- next launch)
    if c2 == '> ' or c2 == 'f ' then pcall(trace.flush, trace); return end
    tr.bytes = tr.bytes + #line + 1
  end
  local okw, w = pcall(trace.write, trace, line .. '\n')
  local okf, fl = pcall(trace.flush, trace)
  if not (okw and w and okf and fl) then tr.failed() end
end
local function tick()   -- a time stamp in the trace every 10 s while a job is held, so "started within RECENT s" can be judged
  local t = floor(elapsed)
  if t < tr.last_tick + 10 then return end
  -- while my options menu is open (tr.menu) always: a launch that dies then shows how long after its last option change
  if tr.menu then tr.last_tick = t; crumb('t ' .. t); return end
  -- PERF: only while a held job isn't yet shown older than RECENT by a stamp already written (after that, more stamps
  -- change nothing the next launch can blame, so a GUI held all mission long writes none)
  for _, at in pairs(held) do
    if tr.last_tick - at <= RECENT then tr.last_tick = t; crumb('t ' .. t); return end
  end
end

-- ------------------------------------------------------------------ guarded engine calls
-- "Table.function" split once per name (the engine's tables are looked up each time, so a replaced one is seen)
local split = {}
local starter_no_global = { CowboyBingusModLoader = true, HD2ModLoader = true, ModOptionsMenu = true, ModBindingsMenu = true,
  BingusRuntime = true, __boot_mod_loader = true }
local function fn_of(name)
  local sp = split[name]
  if sp == nil then
    -- a name not split yet: past 4096 of them I start the cache over, so a mod passing chef.call new names without end
    -- can't grow it. The count is kept under the table itself, a key no name can be; sp is this call's own, so
    -- clearing can't take it away.
    local n = (split[split] or 0) + 1
    if n > 4096 then for k in pairs(split) do split[k] = nil end; n = 1 end
    split[split] = n
    local t, f = name:match('^([%w_]+)%.([%w_]+)$')
    sp = t and { t, f } or false
    split[name] = sp
  end
  -- the engine's tables and functions in stingray, else a capitalized name among the globals (Unit.alive, Vector3), so
  -- a build that has them only there still works. Never a lower-case global or library (os, io, debug, loadstring ...):
  -- chef.call reaches this, and those are exactly what the locked-down space takes away. Mods already read capitalized globals
  -- through their environment; the look-alikes are left out (each mod has its own).
  if sp then
    local t = S[sp[1]]
    if t == nil and sp[1]:match('^%u') and not starter_no_global[sp[1]] then t = rawget(G, sp[1]) end
    return type(t) == 'table' and t[sp[2]] or nil
  end
  local f = S[name]
  if f == nil and name:match('^%u') and not starter_no_global[name] then f = rawget(G, name) end
  return f
end
local proven = {}
-- The keys "owner|call" built once each and kept, so the hot paths (thousands of calls a frame) build no strings.
local keycache = {}
local function key_of(owner, key)
  local t = keycache[owner]
  local k = t and t[key]
  if k then return k end
  -- a key not built yet: past 4096 of them (every owner's together) I start the cache over, as for fn_of's names (the
  -- count under the table itself, which no owner is). The key is built after the clearing, so it's never lost.
  local n = (keycache[keycache] or 0) + 1
  if n > 4096 then for o in pairs(keycache) do keycache[o] = nil end; n = 1; t = nil end
  keycache[keycache] = n
  if not t then t = {}; keycache[owner] = t end
  k = owner .. '|' .. key; t[key] = k
  return k
end
-- No table per call: the drawing makes thousands of these a frame while a panel is up.
local function pass(ok, a, b, c, d)
  if not ok then return nil, tr.why(a) end
  return a, b, c, d
end
-- call(owner, key, fn, ...): skipped if `owner|key` crashed a launch; breadcrumbed the first time it runs.
local function guarded(owner, key, fn, ...)
  local t = keycache[owner]                 -- PERF: key_of inlined for a key already built, pass only on the first call
  local k = t and t[key] or key_of(owner, key)
  if skip[k] then return nil, 'skipped' end
  local tf = type(fn)
  if tf ~= 'function' then
    if tf ~= 'table' then return nil, 'missing' end
    local mt = getmetatable(fn)
    if not (type(mt) == 'table' and mt.__call) then return nil, 'not callable' end
  end
  if not proven[k] then
    proven[k] = true; crumb('> ' .. k)
    local a, b, c, d = pass(pcall(fn, ...))
    crumb('< ' .. k)
    return a, b, c, d
  end
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then return a, b, c, d end
  return nil, tr.why(a)
end
-- my helpers' own engine calls (GUIs, the camera, colors, vectors ...), shared by every mod: keyed by me, so a call
-- that crashes the game is skipped once for everyone instead of blaming each mod that reaches it in turn. The calls a
-- mod aims at its own units go through chef.call, keyed by that mod.
local function api(name, ...) return guarded('loader', name, fn_of(name), ...) end
-- (tr.hseq: key -> its place in the order the held jobs opened, for the trace's rewrite; tr.hn counts them)
local function hold(key, on)
  if on and not held[key] then
    tr.hn = tr.hn + 1; tr.hseq[key] = tr.hn
    held[key] = floor(elapsed); crumb(fmt('>> %s @%d', key, held[key]))
  elseif not on and held[key] then held[key] = nil; tr.hseq[key] = nil; crumb('<< ' .. key) end
end
-- An engine read mods may make that has ended the game in some cases (GameSession.game_object_field_batched, on other
-- players' objects): skipped for a mod once it crashed a launch (the crash counted against the mod, as for any crash
-- of its own); its first call on each object breadcrumbed like any first call (a game that ends in it blames it for
-- sure), and each run of calls held as a job while it goes on (blamed if a second launch ends in it). The sandbox
-- checks the object exists first (sandbox.lua, sb.guard_engine). tr.reads: key -> { at = the last call (s), ids = the
-- objects already read in this world, n = how many (at most 4096 kept; emptied as a new world loads) }
tr.reads = {}
function tr.guard_read(owner, key, id, fn, ...)
  local k = key_of(owner, key)
  if skip[k] then return nil, 'skipped' end
  local r = tr.reads[k]
  if not r then r = { at = 0, ids = {}, n = 0 }; tr.reads[k] = r end
  r.at = elapsed
  hold(k, true)
  tr.reads_held[k] = r
  if not r.ids[id] then
    if r.n < 4096 then r.ids[id], r.n = true, r.n + 1 end
    crumb('> ' .. k)
    local a, b, c, d = pass(pcall(fn, ...))
    crumb('< ' .. k)
    return a, b, c, d
  end
  return pass(pcall(fn, ...))
end
-- (a run of calls ends 2 s after its last call: its hold is let go. tr.reads_held: the runs going on now, the only
-- ones the frame looks at, so once every run ended nothing is walked; tr.reads keeps the objects already read)
tr.reads_held = {}
function tr.guard_release()
  for k, r in pairs(tr.reads_held) do
    if elapsed - r.at > 2 then hold(k, false); tr.reads_held[k] = nil end
  end
end
-- An option changed in my menu, or set by a mod: "o <mod>|<option> @<s>" in the trace, so a launch that dies soon
-- after says what was changed last and when. A slider dragged fast changes every frame and a mod may set many at once:
-- one line a second at most, the latest change written as the next second starts (frame, tr.opt.due).
-- tr.opt: k, at = the latest change; w = the second a line was last written
tr.opt = { k = nil, at = 0, w = -1, due = false }
function tr.opt_write()
  tr.opt.due, tr.opt.w = false, floor(elapsed)
  crumb(fmt('o %s @%d', tr.opt.k, tr.opt.at))
end
function tr.opt_changed(id)
  local o = tr.opt
  o.k, o.at = tostring(id), floor(elapsed)
  if o.at > o.w then tr.opt_write() else o.due = true end
end

-- ------------------------------------------------------------------ discovery
-- Patch archive layout (as my build tools write it and Arsenal deploys it): 72-byte header (0xF0000011, type
-- count, entry count, ...), 32-byte type rows, 80-byte entries (id, type, offset, stream offset, gpu offset,
-- 2 unused: u64; then size: u32 ...). A Lua resource: u32 length, u32 envelope (1 or 2: source text), then the text.
-- scan.big: Lua resources over MAX_LUA I didn't read; scan.huge: patch files over MAX_ENTRIES rows I didn't read for
-- mods (a mod's own patch is a few rows; one that big is built data); scan.said: the skipped headers already in the log
local found_addons, found_options, found_boots, scan = {}, {}, {}, { files = 0, ms = 0, bad = 0, seq = 0, big = 0, huge = 0, said = {},
  langs = {},                          -- langs: "-- HD2-Lang:" language files (services.lang)
  list = {},                           -- list: every patch file read, {file, n}, lowest number first (the index)
  mine = {}, cores = {} }              -- mine: boot scripts carrying my marker; cores: rows of my core, {file, n, version}
local found_named = {}                 -- "-- HD2-Boot: mods/<author>/<name>" scripts (boot-style, run alongside)
local discover
-- My start-up stub's fingerprint (fingerprint() below, of src/stub.lua; tools/build.py checks it) and my core's name.
-- scan.via: started by require as my core (the name require passed, or require's own placeholder in package.loaded
-- while it loads me); scan.prev: the game's callbacks as the boot that loaded me left them.
scan.STUB, scan.CORE, scan.prev = '17775935', 'mods/chef_shared_loader/core_1', chef_before.cb
do
  local P = rawget(G, 'package')
  local held = type(P) == 'table' and type(P.loaded) == 'table' and rawget(P.loaded, scan.CORE)
  -- (also when callbacks were already set before me, or a hand-off note is there: the game sets none before its boot,
  -- so another boot ran first and loaded me, whatever its require passed)
  scan.via = chef_before.via == scan.CORE or type(held) == 'userdata' or next(chef_before.cb) ~= nil
    or rawget(G, 'ChefSharedLoaderHandoff') ~= nil
end
do   -- (the reading parts in a block: the loader is near Lua 5.1's 200 locals)
local LUA_TYPE = { 0xe2, 0x17, 0xd1, 0x2c, 0xfa, 0x8d, 0x4e, 0xa1 }
-- my core's resource id (murmur64 of mods/chef_shared_loader/core_1), as its 8 bytes in a table of contents
local CORE_ID = '\154\087\100\126\056\137\119\194'
local function u32(s, i) local a, b, c, d = byte(s, i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
local function u64(s, i) return u32(s, i) + u32(s, i + 4) * 4294967296 end
local function is_lua(s, i) for k = 1, 8 do if byte(s, i + k - 1) ~= LUA_TYPE[k] then return false end end return true end

-- the resource id of `boot` (murmur64 of "boot"), as its 8 bytes in a patch's table of contents
local BOOT_ID = string.char(0xfa, 0x95, 0x18, 0x69, 0x93, 0xdf, 0x76, 0xf4)
local MAX_ENTRIES, MAX_LUA = 200000, 4 * 1024 * 1024    -- sanity limits: a patch file claiming more is skipped
local MAX_PATCH = 4095                   -- the last patch number I look at (big mod lists pass 512)
-- One patch file: its table of contents, then the first bytes of each Lua resource. Anything that doesn't add up (a
-- different format, a cut-off file) makes me skip that file, never read past it.
local function read_patch(f, name)
  local head = f:read(72) or ''
  if #head ~= 72 or u32(head, 1) ~= 0xF0000011 then return end
  local nt, ne = u32(head, 5), u32(head, 9)
  if nt > 4096 then scan.bad = scan.bad + 1; return end
  if ne > MAX_ENTRIES then scan.huge = scan.huge + 1; return end
  local toc = f:read(nt * 32 + ne * 80) or ''
  if #toc < nt * 32 + ne * 80 then scan.bad = scan.bad + 1; return end
  for e = 0, ne - 1 do
    local at = nt * 32 + e * 80 + 1
    if is_lua(toc, at + 8) then
      local off, size = u64(toc, at + 16), u32(toc, at + 56)
      if size > MAX_LUA then scan.big = scan.big + 1 end
      if size >= 8 and size <= MAX_LUA and sub(toc, at, at + 7) == BOOT_ID and f:seek('set', off) then
        -- another mod's boot script (the game runs only the last one deployed): kept to run alongside mine, unless
        -- it's one of mine (my start-up stub, or a copy of this loader built into another mod): those are only noted
        local src = f:read(size) or ''
        local v = #src == size and u32(src, 5)
        if v == 1 or v == 2 then
          local list = src:find('--@@LOADER@@', 1, true) and scan.mine or found_boots
          list[#list + 1] = { file = name:match('[^/]+$'), src = sub(src, 9), n = tonumber(name:match('(%d+)$')) or 0 }
        end
      elseif size >= 8 and size <= MAX_LUA and sub(toc, at, at + 7) == CORE_ID and f:seek('set', off) then
        -- a copy of my core (the game's require loads the one in the highest patch): noted with its version, never a mod
        local head = f:read(min(size, 8192)) or ''
        scan.cores[#scan.cores + 1] = { file = name:match('[^/]+$'), n = tonumber(name:match('(%d+)$')) or 0,
                                        version = (head:match("\nlocal VERSION = '([^'\n]+)'") or 'of an unknown version'):sub(1, 40):gsub('%c', ' ') }
      elseif size >= 8 and size <= MAX_LUA and f:seek('set', off) then
        local first = f:read(min(size, 120)) or ''
        local v = #first >= 8 and u32(first, 5)
        if v == 1 or v == 2 then
          -- a text editor's UTF-8 mark in front of the header is dropped (Lua 5.1 can't read past it either)
          local bom = sub(first, 9, 11) == '\239\187\191' and 3 or 0
          local kind, mod = first:sub(9 + bom):match('^%-%- HD2%-(%a+): ([%w_/%.%-]+)')
          local known = kind == 'Addon' or kind == 'Options' or kind == 'Boot' or kind == 'Lang'
          if known and mod and mod:find('//', 1, true) then known = nil end   -- (no empty part in a name)
          if mod and not (known and mod:match(ALLOW)) and not scan.said[kind .. ' ' .. mod] then
            scan.said[kind .. ' ' .. mod] = true
            log(fmt('skipped "-- HD2-%s: %s" in %s: %s', kind, mod, name:match('[^/]+$'), known
              and 'the name must be mods/<author>/<name>, more parts allowed (letters, digits, _ and -)' or known == false
              and 'HD2-Addon, HD2-Boot, HD2-Options or HD2-Lang was expected' or 'the name must be mods/<author>/<name> (no empty part)'))
          end
          if mod and known and mod:match(ALLOW) and f:seek('set', off + 8 + bom) then
            local src = f:read(size - 8 - bom) or ''
            if #src ~= size - 8 - bom then scan.bad = scan.bad + 1
            else
              local list = kind == 'Addon' and found_addons or (kind == 'Boot' and found_named or (kind == 'Lang' and scan.langs
                or found_options))
              -- the patch number (when two patches carry the same mod, the higher one wins, below) and the order
              -- found (a tie-break, so two copies always resolve the same way)
              scan.seq = scan.seq + 1
              list[#list + 1] = { name = mod, file = name:match('[^/]+$'), src = src, seq = scan.seq,
                                  patch = tonumber(name:match('(%d+)$')) or 0 }
            end
          end
        end
      end
    end
  end
end
discover = function()
  local t0 = clock()
  local misses = 0
  for n = 0, MAX_PATCH do
    local name = 'data/9ba626afa44a3aa3.patch_' .. n
    local f = open(name, 'rb')
    if not f then
      misses = misses + 1
      if misses > 64 then break end
    else
      misses = 0
      scan.files = scan.files + 1
      scan.list[#scan.list + 1] = { file = name:match('[^/]+$'), n = n }
      local ok, err = pcall(read_patch, f, name)
      if not ok then scan.bad = scan.bad + 1; log('skipped ' .. name .. ': ' .. tr.why(err)) end
      pcall(f.close, f)
    end
  end
  scan.ms = (clock() - t0) * 1000
  -- my own mods start first, then everyone else's by name. Two copies of one mod (an old version left installed next
  -- to the new one): the higher patch number comes first and is the one that runs, the same rule the game uses for its
  -- own files (the last one deployed wins); the same patch twice falls back to the order found.
  local function before(a, b)
    local ma, mb = a.name:match('^mods/chef/') ~= nil, b.name:match('^mods/chef/') ~= nil
    if ma ~= mb then return ma end
    if a.name ~= b.name then return a.name < b.name end
    if (a.patch or 0) ~= (b.patch or 0) then return (a.patch or 0) > (b.patch or 0) end
    return (a.seq or 0) < (b.seq or 0)
  end
  sort(found_addons, before)
  sort(found_named, before)
end
end

-- Every byte counts (a one-character hotfix is a new version, and two different boot scripts of one length are two),
-- 16 at a time; four steps between the modulos stay well inside a double's exact range.
local function fingerprint(src)
  local n = #src
  local h = n
  local i = 1
  while i + 15 <= n do
    local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16 = byte(src, i, i + 15)
    h = ((((h * 31 + b1) * 31 + b2) * 31 + b3) * 31 + b4) % 2147483647
    h = ((((h * 31 + b5) * 31 + b6) * 31 + b7) * 31 + b8) % 2147483647
    h = ((((h * 31 + b9) * 31 + b10) * 31 + b11) * 31 + b12) % 2147483647
    h = ((((h * 31 + b13) * 31 + b14) * 31 + b15) * 31 + b16) % 2147483647
    i = i + 16
  end
  for j = i, n do h = (h * 31 + byte(src, j)) % 2147483647 end
  return fmt('%x', h)
end
function v1.fp(src)
  local h = #src
  for i = 1, #src, 7 do h = (h * 31 + byte(src, i)) % 2147483647 end
  return fmt('%x', h)
end
-- a 1.0.0 "off:" entry for this source gets the new fingerprint (the mod is unchanged, so it stays off)
function v1.off(name, src, fp)
  local was = off[name]
  if was and was.fp ~= 'pending' and was.fp ~= fp and was.fp == v1.fp(src) then
    was.fp = fp; save_state()
  end
end
-- a 1.0.0 boot script's skips and its "off:" entry, from boot:<old fingerprint> to boot:<new>
function v1.boot(src, owner)
  local any = false
  for k in pairs(off) do if k:sub(1, 5) == 'boot:' then any = true; break end end
  if not any then for k in pairs(skip) do if k:sub(1, 5) == 'boot:' then any = true; break end end end
  if not any then return end
  local old = 'boot:' .. v1.fp(src)
  if old == owner then return end
  local p, moved = old .. '|', false
  for _, t in ipairs({ skip, suspect }) do
    local ks = {}
    for k in pairs(t) do if k:sub(1, #p) == p then ks[#ks + 1] = k end end
    for _, k in ipairs(ks) do t[owner .. k:sub(#old + 1)] = t[k]; t[k] = nil; moved = true end
  end
  if off[old] then off[owner] = off[old]; off[old] = nil; moved = true end
  if moved then save_state() end
end

-- ------------------------------------------------------------------ world, camera, input
-- world.id: a new one for every settled world, and when the same world's contents turn into another (the game loads
-- the ship into the world the mission ran in). world.instance: a new one only for a new engine world; handles made in
-- one instance (GUIs) can be kept across an id change, never across an instance change.
-- Is it a mission? Its level count tells: hundreds of levels is a mission, one or two (the ship) or none (the title
-- screen, loading) isn't, looked at again every 2 s. Only when the engine can't count levels do the units decide: a world
-- over MISSION_UNITS always is a mission, a smaller one when the loot probe finds mission loot in it (kinds addons
-- name with chef.mission_kinds: samples, medals and the like, which the ship never has). Leaving, by the units: when a
-- mission's unit count drops PROBE_DROP below its peak I stop calling it a mission at once (no drawing on what may be
-- the ship) and probe: loot still there means it was only the mission thinning out, and it carries on as the same
-- mission.
local world = { main = nil, since = 0, time = -1, time_at = 0, id = 0, instance = 0, stable = false, mission = false, units = 0,
                busy = function() return true end }      -- busy: replaced further down (anything holding handles?)
local mission_kinds, kinds_from = {}, {}     -- kinds_from: the addons that named them (probing stops when they're off)
local new_world_hooks = {}
local function world_changed()
  for _, fn in ipairs(new_world_hooks) do fn() end
end
local function can_probe()
  if world.levels or skip['loader|scan'] then return false end       -- (the level count already tells)
  for _, a in ipairs(kinds_from) do if a.on then return true end end
  return false
end
-- the probe's verdict (from probe_step below)
local function probe_done(found, n)
  world.probing, world.probe_at, world.probe_last = false, nil, n
  world.probe_k, world.probe_done_t = (world.probe_k or 0) + 1, elapsed
  if world.mission then
    local was_checking = world.checking
    world.checking = false
    -- (a world over MISSION_UNITS stays a mission even with all its loot picked up)
    if found >= MISSION_LOOT or n > MISSION_UNITS then
      world.peak = n
      if was_checking then log(fmt('world %d: still a mission (%d units, %d mission loot)', world.id, n, found)) end
    else
      -- the schedule starts over for what's there now (most likely the ship)
      world.id, world.mission, world.units, world.probe_k, world.probe_said = world.id + 1, false, n, 1, false
      log(fmt('world %d: not a mission (%d units; the mission is over)', world.id, n))
      world_changed()
    end
  elseif found >= MISSION_LOOT then
    world.id, world.mission, world.units, world.peak = world.id + 1, true, n, n
    log(fmt('world %d: mission (%d units, %d mission loot)', world.id, n, found))
    world_changed()
  elseif not world.probe_said then
    world.probe_said = true
    log(fmt('world %d: no mission loot in %d units', world.id, n))
  end
end
-- the ship arriving (or the world emptying on the way out) is a sudden drop between two looks; a mission thinning out
-- is slow
local function shrank(n, before)
  return n < (world.peak or n) * (1 - PROBE_DROP) or n < (before or n) * (1 - SUDDEN_DROP)
end
-- maybe the mission is over: no drawing until the probe has looked (without the probe, only the size decides)
local function left_maybe(n)
  if can_probe() then
    world.checking, world.probe_at = true, elapsed
  elseif n <= MISSION_UNITS then
    world.id, world.mission, world.units = world.id + 1, false, n
    log(fmt('world %d: not a mission (%d units; the same world, its contents changed)', world.id, n))
    world_changed()
  end
end
-- The main world's level count: one or two on the ship (a second one comes and goes for a few seconds), none on the
-- title screen or while loading, 600 to 1,100 in a mission, whatever their sizes (a mission of 4,400 units and a ship
-- of 4,000 were seen); more than world.LEVELS is a mission. nil: the engine can't tell me (the call missing, failing
-- or skipped after a crash in it), and the unit count and the loot probe decide instead.
world.LEVELS = 10
-- world.shown: the game has shown a real scene (the ship or a mission) this session. The first world the game makes is
-- black loading screens and then the title screen, and nothing I can read tells those two apart (1 unit, no levels
-- throughout), so a notice's clock waits for a world that's a real scene: at least one level, or PROBE_MIN units, or a
-- mission. The notice is drawn all the while, on the title screen too. world.HOLD: if no such world comes (a game
-- update that starts some other way), a notice's clock starts anyway this many seconds after it could first be drawn.
world.shown, world.HOLD = false, 60
function world.levels_of(main)
  local n, why = api('World.num_levels', main)
  if type(n) == 'number' then return n end
  if not world.no_levels then
    world.no_levels = true
    log('World.num_levels: ' .. tostring(why or ('answered ' .. type(n))) .. ' (missions told by their size and loot instead)')
  end
end
local function update_world()
  local main, why = api('Application.main_world')
  if not main then
    -- said once: the engine function gone (or skipped) leaves every mod waiting for a world forever
    if why and not world.no_main then world.no_main = true; log('Application.main_world: ' .. why .. ' (no world, so no mod draws)') end
    if world.main ~= nil then
      world.main, world.stable, world.mission, world.checking, world.probing = nil, false, false, false, false
      world.instance = world.instance + 1; world_changed()
    end
    return
  end
  -- World.time (a world restarted in place goes back in time): every frame while anything may hold handles from this
  -- world (a mod running, my GUIs, lines or a scan), else 4 times a second
  local ask = main ~= world.main or elapsed >= world.time_at or world.busy()
  local t = nil
  if ask then
    world.time_at = elapsed + 0.25
    t = api('World.time', main)
    if type(t) ~= 'number' and not world.no_time then world.no_time = true; log('World.time is not available: only a new main world counts as a world change') end
  end
  if main ~= world.main or (type(t) == 'number' and t < world.time) then
    -- a different world (or the same one restarted): everything from the last one is dropped right now, before it can
    -- be used again, and nothing new is made until it has settled
    local was_stable = world.stable or world.main ~= nil
    world.main, world.since, world.stable = main, elapsed, false
    world.checking, world.probing = false, false
    world.instance = world.instance + 1
    -- (a new world, a new game session: its object ids start over, so a read's first call on each is breadcrumbed
    -- again)
    for _, r in pairs(tr.reads) do r.ids, r.n = {}, 0 end
    if was_stable then world_changed() end
  end
  if ask then world.time = type(t) == 'number' and t or -1 end
  if not world.stable and elapsed - world.since >= STABLE_FOR then
    world.stable = true
    world.id = world.id + 1
    world_changed()
    local n = api('World.num_units', main)
    world.units = type(n) == 'number' and n or 0
    world.levels = world.levels_of(main)
    if world.levels then world.mission = world.levels > world.LEVELS else world.mission = world.units > MISSION_UNITS end
    world.peak, world.probe_k, world.probe_last, world.probe_said, world.probe_done_t = world.units, 0, nil, false, nil
    world.last_n = world.units
    if world.mission or world.units >= PROBE_MIN or (world.levels or 0) > 0 then world.shown = true end
    world.probe_at = (not world.mission and can_probe() and world.units >= PROBE_MIN) and elapsed or nil
    world.recheck, world.flip = elapsed + 2, 0
    log(fmt('world %d: %s (%d units%s)', world.id, world.mission and 'mission' or
      ((can_probe() and world.units >= PROBE_MIN) and 'not a mission yet' or 'not a mission'), world.units,
      world.levels and fmt(', %d level%s', world.levels, world.levels == 1 and '' or 's') or ''))
  elseif world.stable and elapsed >= (world.recheck or 0) then
    -- The game keeps the same main world after a mission (the ship is loaded into it), so I look at it again every
    -- 2 s; a change of verdict makes it a new world as far as addons are concerned (new id; the same instance).
    world.recheck = elapsed + 2
    local n = api('World.num_units', main)
    if type(n) ~= 'number' or world.probing then return end
    local before = world.last_n or n
    world.last_n = n
    local lv = world.levels_of(main)
    world.levels = lv
    if not world.shown and (n >= PROBE_MIN or (lv or 0) > 0) then world.shown = true end
    if lv then
      -- the level count decides, the moment it changes (the ship loaded into the mission's world: one level again)
      local m = lv > world.LEVELS
      if m ~= (world.mission == true) then
        world.id, world.units, world.mission, world.peak, world.checking, world.flip = world.id + 1, n, m, n, false, 0
        log(fmt('world %d: %s (%d units, %d level%s; the same world, its contents changed)', world.id,
          world.mission and 'mission' or 'not a mission', n, lv, lv == 1 and '' or 's'))
        world_changed()
      end
      return
    end
    if world.mission then
      if n > (world.peak or 0) then world.peak = n end
      if not world.checking and shrank(n, before) then
        left_maybe(n)
      elseif n <= MISSION_UNITS and can_probe() and not world.probe_at
          and elapsed >= (world.probe_done_t or world.since) + PROBE_IN_MISSION then
        -- a small mission is looked at again now and then: the ship can be loaded into it without its size dropping
        -- far, and loot gone means the mission is over
        world.probe_at = elapsed
      end
    elseif n > MISSION_UNITS then
      -- a world that turns into a mission by its size needs two looks in a row
      world.flip = (world.flip or 0) + 1
      if world.flip >= 2 then
        world.flip, world.id, world.units, world.mission, world.peak = 0, world.id + 1, n, true, n
        log(fmt('world %d: mission (%d units; the same world, its contents changed)', world.id, n))
        world_changed()
      end
    else
      world.flip = 0
      -- the probe again: on a schedule after the world settled, then every PROBE_LATER s, and at once when the world
      -- grew by PROBE_DROP since the last probe
      if can_probe() and n >= PROBE_MIN and not world.probe_at then
        local k = world.probe_k or 0
        local grew = world.probe_last and n > world.probe_last * (1 + PROBE_DROP)
        local due = (world.probe_done_t or world.since) + (k == 0 and 0 or (PROBE_EVERY[k] or PROBE_LATER))
        if grew or elapsed >= due then world.probe_at = elapsed end
      end
    end
  end
end

-- The camera: I remember the camera unit and only look for it again when it's gone. The search walks the world's units
-- 500 a frame; a walk that finds nothing waits CAMERA_RETRY s before the next, twice as long each time (8 s at most).
-- A new world forgets it.
local cam = { unit = nil, c = nil, frame = -1, data = nil, retry = 0, wait = CAMERA_RETRY, list = nil, i = 0 }
new_world_hooks[#new_world_hooks + 1] = function()
  cam.unit, cam.c, cam.data, cam.frame, cam.retry, cam.wait, cam.list, cam.i = nil, nil, nil, -1, 0, CAMERA_RETRY, nil, 0
end
local function xyz(v)
  if v == nil then return nil end
  local x, y, z = api('Vector3.to_elements', v)
  if type(x) == 'number' then return x, y, z end
end
local function cam_from(u)
  local c = api('Unit.camera', u, 1)
  if not c then return nil end
  local x, y, z = xyz((api('Camera.world_position', c)))
  if not x then return nil end
  local d = { x = x, y = y, z = z, fx = 0, fy = 1, fz = 0, yaw = 0 }
  cam.c = c
  local fov = api('Camera.vertical_fov', c)
  if type(fov) == 'number' then d.fov = fov end
  local rot = api('Camera.world_rotation', c)
  local fx, fy, fz = xyz(rot and api('Quaternion.forward', rot))
  if fx then d.fx, d.fy, d.fz, d.yaw = fx, fy, fz, atan2(fx, fy) end
  -- all of it made it through guarded() (breadcrumbed the first time), Unit.alive before it too: cam.from_fast from now
  if fx and d.fov then
    cam.ffns = { fn_of('Unit.alive'), fn_of('Unit.camera'), fn_of('Camera.world_position'), fn_of('Vector3.to_elements'),
                 fn_of('Camera.vertical_fov'), fn_of('Camera.world_rotation'), fn_of('Quaternion.forward') }
    cam.fast = true
  end
  return d
end
-- PERF: the camera's eight engine calls a frame through one pcall, once they all went through guarded() fine (cam.ffns:
-- the functions, looked up then). The same calls with the same arguments, each only when the guarded path would make it.
-- -> the camera's table only when every call answered (the guarded path's table, with the same fields); false when the
-- camera unit is gone (the search's business); nil for anything else, which takes the guarded path again.
function cam.from_fast(u)
  local f = cam.ffns
  if f[1](u) ~= true then return false end
  local c = f[2](u, 1)
  if not c then return nil end
  local p = f[3](c)
  if p == nil then return nil end
  local x, y, z = f[4](p)
  if type(x) ~= 'number' then return nil end
  local fov = f[5](c)
  if type(fov) ~= 'number' then return nil end
  local rot = f[6](c)
  if not rot then return nil end
  local q = f[7](rot)
  if q == nil then return nil end
  local fx, fy, fz = f[4](q)
  if type(fx) ~= 'number' then return nil end
  cam.c = c
  return { x = x, y = y, z = z, fx = fx, fy = fy, fz = fz, yaw = atan2(fx, fy), fov = fov }
end
-- PERF: chef.world_to_screen's three engine calls through one pcall, once they went through guarded() fine
-- cam.fns: the three functions, looked up when the guarded path last worked (a failure here takes it again)
function cam.project(c, x, y, z)
  local f = cam.fns
  return f[1](f[2](c, f[3](x, y, z)))
end
local function camera()
  if cam.frame == frame_no then return cam.data end
  cam.frame, cam.data = frame_no, nil
  if not world.stable then return nil end
  local gone = false
  if cam.unit and cam.fast then
    local ok, d = pcall(cam.from_fast, cam.unit)
    if ok and d then cam.data = d; return d end
    if ok and d == false then gone = true
    else cam.fast = false end            -- the guarded path below again (it turns this back on once it all works)
  end
  if cam.unit and not gone and api('Unit.alive', cam.unit) == true then cam.data = cam_from(cam.unit) end
  if cam.data then return cam.data end
  if not cam.list then
    if elapsed < cam.retry then return nil end
    cam.unit, cam.c = nil, nil
    local units = api('World.units', world.main)
    if type(units) ~= 'table' then cam.retry = elapsed + cam.wait; return nil end
    cam.list, cam.i = units, 0
  end
  -- (the list is a few frames old: a unit is checked alive before it's asked anything)
  local units = cam.list
  local last = min(#units, cam.i + 500)
  for i = cam.i + 1, last do
    local u = units[i]
    if api('Unit.alive', u) == true then
      local nc = api('Unit.num_cameras', u)
      if type(nc) == 'number' and nc > 0 then
        cam.unit, cam.list = u, nil
        cam.data = cam_from(u)
        if cam.data then cam.wait = CAMERA_RETRY else cam.retry = elapsed + cam.wait end
        return cam.data
      end
    end
  end
  cam.i = last
  if last >= #units then
    cam.list = nil
    cam.retry = elapsed + cam.wait
    cam.wait = min(cam.wait * 2, 8)
  end
  return nil
end

-- A key's index, asked of the engine once. No answer (the keyboard isn't ready yet in the first frames on some
-- setups, or a key name it doesn't know) is asked again, never kept for good: a key asked about at start-up (the
-- options menu's) would otherwise stay dead for the whole session. The wait doubles from 2 s up to 32 s, so a name the
-- game never knows (a mod trying every spelling of a key) isn't asked all session long every 2 s.
-- keys[name .. '|at']: when to ask again; keys[name .. '|wait']: the wait after the next miss.
local keys = {}
local function key_index(name)
  local k = keys[name]
  if k == nil or (k == false and elapsed >= keys[name .. '|at']) then
    k = api('Keyboard.button_index', name) or false
    keys[name] = k
    if not k then
      local wait = keys[name .. '|wait'] or 2
      keys[name .. '|at'], keys[name .. '|wait'] = elapsed + wait, min(wait * 2, 32)
      if not keys[name .. '|said'] then keys[name .. '|said'] = true; log(fmt('key "%s": the game has no index for it yet; asking again, less often each time (from every 2 s to every 32 s)', name)) end
    elseif keys[name .. '|said'] then log(fmt('key "%s": found now', name)) end
  end
  return k
end

-- ------------------------------------------------------------------ unit watching (spread over frames)
-- Addons say which unit kinds they want (resource id -> anything) and how often; one shared scan serves them
-- all, and it only runs while somebody is watching, in a stable world.
local watchers = { next_at = 0 }         -- next_at: no watcher is due before then (0: look again)
local job = nil
local scan_off_noted = false
local pos_keys = {}               -- kind -> "Unit.world_position:<kind>", built once
local function pos_keys_of(k)
  local pk = pos_keys[k]
  if not pk then pk = 'Unit.world_position:' .. k; pos_keys[k] = pk end
  return pk
end

-- The lookup by resource: World.units_by_resource asked for each kind, with the kind's id as an IdString64 (the id
-- as text, '#ID[hash]', finds nothing), instead of walking every unit in the world and asking its name. I only
-- trust it once it has matched a full scan in a mission: the first scans of a launch do both and compare what each
-- found of every kind. Until then, and if it ever fails, the full scan runs instead. Its first call is
-- breadcrumbed like any other, so a game that dies in it skips it from the next launch on.
-- res.bad: kinds no watch ever gets (runtime-built units: asking where one is ends the game; the utilities refuse the
-- same set)
local res = { state = nil, tries = 0, n = 0, ms = 0, full_n = 0, full_ms = 0, err = nil, bad = { ['46cab355bd8d4d37'] = true } }
-- PERF: a debug name -> its kind ('#ID[hash]' -> 'hash', or false), kept (names are the same for every unit of a kind),
-- emptied when it passes 8,192 names; and the scan's Unit.debug_name called straight through one pcall once the
-- breadcrumbed call proved it (like rect_fast)
res.names, res.names_n = {}, 0
function res.dn_fast()
  if proven['loader|Unit.debug_name'] and not skip['loader|Unit.debug_name'] then return fn_of('Unit.debug_name') end
end
function res.kind(n)
  local k = res.names[n]
  if k == nil then
    k = n:match('#ID%[(%x+)%]') or false
    if res.names_n >= 8192 then res.names, res.names_n = {}, 0 end
    res.names[n], res.names_n = k, res.names_n + 1
  end
  return k
end
local RES_TRIES = 2                       -- comparisons that may disagree before I give it up for the launch
-- -> { { unit, kind }, ... } of the living units of these kinds, and the ms it took; nil and why when any ask failed
local function res_lookup(kinds)
  local t0 = clock()
  local out, asked, failed = {}, 0, 0
  for k in pairs(kinds) do
    if type(k) == 'string' and #k == 16 and k:match('^%x+$') then
      asked = asked + 1
      local id = api('IdString64.from_hex', k)
      local us, err = nil, 'no id'
      if id then us, err = api('World.units_by_resource', world.main, id) end
      if type(us) == 'table' then
        for i = 1, #us do
          local u = us[i]
          if api('Unit.alive', u) == true then out[#out + 1] = { unit = u, kind = k } end
        end
      else
        failed, res.err = failed + 1, tostring(err or ('answered ' .. type(us)))
      end
    end
  end
  -- any kind refused: its units would silently be missing, so the answer isn't used at all
  if failed > 0 then return nil, fmt('%d of %d kinds refused: %s', failed, asked, res.err) end
  return out, (clock() - t0) * 1000
end
local function res_off(why)
  res.state = 'off'
  world.scan_n = nil            -- the full scan's own size comparison starts over (its last count may be old)
  log(fmt('unit lookup by resource: off (%s); the full scan carries on', why))
end
-- the kinds any of these watchers want (never a refused one)
local function kinds_of(due)
  local u = {}
  for _, w in ipairs(due) do
    for k in pairs(w.kinds) do if type(k) == 'string' and not res.bad[k:lower()] then u[k] = true end end
  end
  return u
end
-- the lookup's answer for the watchers due, with each unit's position asked by its watcher (as the scan does)
local function res_fill(due, list)
  for _, w in ipairs(due) do
    local b = {}
    for _, it in ipairs(list) do
      if w.kinds[it.kind] then
        local k = it.kind
        local pk = pos_keys_of(k)
        local x, y, z = xyz((guarded(w.owner, pk, fn_of('Unit.world_position'), it.unit, 1)))
        if x then b[#b + 1] = { unit = it.unit, kind = k, x = x, y = y, z = z } end
      end
    end
    w.items, w.building, w.generation = b, nil, w.generation + 1
  end
end
-- after a full scan that was compared: the same units of every kind (one apart per kind and two in all are pickups
-- picked up while the scan ran over its frames)?
local function res_verdict(j)
  local a, b = j.counts, j.check.counts
  local ta, tb, worst, diff = 0, 0, 0, {}
  for k in pairs(j.kinds) do
    local x, y = a[k] or 0, b[k] or 0
    ta, tb = ta + x, tb + y
    if x ~= y then diff[#diff + 1] = fmt('%s %d/%d', k, x, y); worst = max(worst, math.abs(x - y)) end
  end
  if ta == 0 and tb == 0 then return end            -- nothing to compare yet: the next scan compares again
  res.tries = res.tries + 1
  local frames = j.frames or 1
  if j.check.badname then
    res_off('a unit it gave was of another kind: ' .. j.check.badname)
  elseif worst <= 1 and math.abs(ta - tb) <= 2 then
    res.state = 'on'
    log(fmt('unit lookup by resource: on (it found %d units of %d kinds, the full scan %d; %.2f ms in one frame against the full scan\'s %.2f ms over %d frames)',
      tb, j.nkinds, ta, j.check.ms, j.cost, frames))
  elseif res.tries < RES_TRIES then
    log(fmt('unit lookup by resource: differs from the full scan (full/lookup: %s); comparing again', concat(diff, ', ')))
  else
    res_off('it differs from the full scan: ' .. concat(diff, ', '))
  end
end

local function scan_start()
  if skip['loader|scan'] then
    if not scan_off_noted then scan_off_noted = true; log('the unit scan is off: the game ended twice while it ran (delete the state file to try again)') end
    return
  end
  -- nothing is built until a watcher is due: until then one number is compared each frame
  if elapsed < watchers.next_at then return end
  local nd, soonest = 0, math.huge
  for _, w in ipairs(watchers) do
    if w.active and w.owner_on() then
      if w.want_now or elapsed >= w.next then nd = nd + 1 elseif w.next < soonest then soonest = w.next end
    end
  end
  if nd == 0 then watchers.next_at = soonest; return end
  watchers.next_at = 0
  local due = {}
  for _, w in ipairs(watchers) do
    if w.active and w.owner_on() and (w.want_now or elapsed >= w.next) then due[#due + 1] = w end
  end
  if res.state == 'on' then
    -- the world's size from the engine's count (compared with the last such count), not a list of every unit
    local n = api('World.num_units', world.main)
    if type(n) == 'number' then
      local prev = world.res_n
      world.res_n = n
      if world.mission and not world.checking and prev and n < prev * (1 - PROBE_DROP) then
        left_maybe(n)
        if world.checking or not world.mission then return end
      end
    end
    local t0 = clock()
    local list, why = res_lookup(kinds_of(due))
    if list then
      for _, w in ipairs(due) do w.want_now, w.next = false, elapsed + w.every end
      res_fill(due, list)
      local ms = (clock() - t0) * 1000
      for _, w in ipairs(due) do w.scan_ms = ms end
      res.n, res.ms = res.n + 1, res.ms + ms
      return
    end
    res_off(why)
  end
  local units = api('World.units', world.main)
  if type(units) ~= 'table' then return end
  -- a mission world that just emptied (the way out) or turned into the ship isn't scanned: an empty list would show
  -- as everything picked up until the next look at its size. (Against the last scan's list, not World.num_units: the
  -- two needn't count the same units.)
  local n, prev = #units, world.scan_n
  world.scan_n = n
  if world.mission and not world.checking and prev and n < prev * (1 - PROBE_DROP) then
    left_maybe(n)
    if world.checking or not world.mission then return end
  end
  for _, w in ipairs(due) do w.want_now, w.next, w.building = false, elapsed + w.every, {} end
  local kinds = kinds_of(due)
  job = { units = units, i = 0, due = due, kinds = kinds, world = world.id, instance = world.instance, t0 = clock(), cost = 0, frames = 0 }
  -- not trusted yet: the lookup's answer now, to compare with what this scan finds
  if res.state == nil and world.mission and not world.checking then
    local list, ms = res_lookup(kinds)
    if not list then
      res_off(ms)
    else
      local c, nk, named = {}, 0, {}
      for _, it in ipairs(list) do
        if not c[it.kind] then nk = nk + 1 end
        c[it.kind] = (c[it.kind] or 0) + 1
        -- the first unit of each kind must have that kind's name
        if not named[it.kind] then
          named[it.kind] = true
          local nm = api('Unit.debug_name', it.unit)
          local got = type(nm) == 'string' and nm:match('#ID%[(%x+)%]')
          if got and got:lower() ~= it.kind and not job.badname then job.badname = it.kind .. ' gave ' .. got end
        end
      end
      job.check = { counts = c, ms = ms, badname = job.badname }
      job.counts, job.nkinds = {}, 0
      for _ in pairs(kinds) do job.nkinds = job.nkinds + 1 end
    end
  end
  hold('loader|scan', true)   -- a game that dies mid-scan twice in a row stops the scan (my crash rule for jobs)
end
-- A new world: the scan under way stops (its units belong to the old one), and every watcher's list empties at once,
-- with a new generation, so no addon keeps using units from the world that's gone.
new_world_hooks[#new_world_hooks + 1] = function()
  if job then job = nil; hold('loader|scan', false) end
  world.probing, world.scan_n, world.res_n = false, nil, nil
  for _, w in ipairs(watchers) do
    w.items, w.building, w.generation, w.want_now = {}, nil, w.generation + 1, true
  end
  watchers.next_at = 0
end
local function scan_step()
  if not world.stable or job.world ~= world.id or job.instance ~= world.instance then job = nil; hold('loader|scan', false); return end
  local t0 = clock()
  local units = job.units
  local last = min(#units, job.i + SCAN_PER_FRAME)
  local dn, names = res.dn_fast(), res.names
  for i = job.i + 1, last do
    local u = units[i]
    local n
    if dn then local ok, v = pcall(dn, u); n = ok and v or nil else n = api('Unit.debug_name', u) end
    local k = false
    if type(n) == 'string' then k = names[n]; if k == nil then k = res.kind(n); names = res.names end end
    -- the list was taken a few frames ago: a unit picked up since is checked before I ask where it is
    if k and job.kinds[k] and api('Unit.alive', u) == true then
      if job.counts then job.counts[k] = (job.counts[k] or 0) + 1 end
      local pk = pos_keys_of(k)
      for _, w in ipairs(job.due) do
        if w.kinds[k] then
          local x, y, z = xyz((guarded(w.owner, pk, fn_of('Unit.world_position'), u, 1)))
          if x then w.building[#w.building + 1] = { unit = u, kind = k, x = x, y = y, z = z } end
        end
      end
    end
  end
  job.i, job.frames = last, job.frames + 1
  job.cost = job.cost + (clock() - t0) * 1000
  if last >= #units then
    for _, w in ipairs(job.due) do
      w.items, w.building, w.generation = w.building, nil, w.generation + 1
      w.scan_ms = job.cost
    end
    res.full_n, res.full_ms = res.full_n + 1, res.full_ms + job.cost
    local j = job
    job = nil
    hold('loader|scan', false)
    if j.check and res.state == nil then res_verdict(j) end
  end
end

-- The loot probe: the same walk over the world's units (the same engine calls, so the same crash key), counting
-- mission loot only, and done as soon as there's enough of it. A few frames for a ship.
local function probe_start()
  if res.state == 'on' then
    local list = res_lookup(mission_kinds)
    local n = api('World.num_units', world.main)
    if list and type(n) == 'number' then probe_done(#list, n); return end
  end
  local units = api('World.units', world.main)
  if type(units) ~= 'table' then probe_done(0, world.units); return end
  world.probing = true
  job = { probe = true, units = units, i = 0, found = 0, world = world.id, instance = world.instance }
  hold('loader|scan', true)
end
local function probe_step()
  if not world.stable or job.world ~= world.id or job.instance ~= world.instance then
    job = nil; hold('loader|scan', false); world.probing = false; return
  end
  local units = job.units
  local last = min(#units, job.i + SCAN_PER_FRAME)
  local found = job.found
  local dn, names = res.dn_fast(), res.names
  for i = job.i + 1, last do
    local n
    if dn then local ok, v = pcall(dn, units[i]); n = ok and v or nil else n = api('Unit.debug_name', units[i]) end
    local k = false
    if type(n) == 'string' then k = names[n]; if k == nil then k = res.kind(n); names = res.names end end
    if k and mission_kinds[k] then
      found = found + 1
      if found >= MISSION_LOOT then last = #units; break end
    end
  end
  job.i, job.found = last, found
  if last >= #units then
    job = nil
    hold('loader|scan', false)
    probe_done(found, #units)
  end
end

-- ------------------------------------------------------------------ drawing
-- Screen: one immediate GUI per stable world, with the performance-HUD font and GUI materials (rects
-- draw; text glyphs come out as solid blocks, so text is my own pixel font made of rects). Origin bottom-left.
-- World: one line object per stable world, reset every frame something draws, dispatched after the addons ran.
local draw = { world = 0, instance = -1, frame = -1, keys = {}, ui_colors = {}, gui = nil, lines = nil, lines_used = false, colors = {}, w = 1920, h = 1080, icons = {}, icon_ok = nil }
local GUI_FONT, GUI_MAT = 'core/performance_hud/debug', 'core/performance_hud/gui'

-- The engine's Color (like Vector3) is a temporary that only lives for the frame it was made in (kept longer, every
-- rect comes out white), so the cache starts empty every frame. Within a frame a temporary's slot can be handed out
-- again once enough others were made (another mod's markers, say: a bitmap's material id kept that long draws a white
-- square), so the cache is also emptied (draw.color_scope) before every mod callback (its hooks, its look-alike
-- on_update hooks and guards, its timers, each frame's batch of its spread jobs, its events) and before each part of
-- my own drawing (the options menu, the monitor, my notices): a mod never gets a Color an earlier mod asked for. The
-- numbers of the frame's colors (draw.keys) stay for the whole frame (a color made in a mod's update and drawn in its
-- render still converts for the UI world): they only ever give the numbers, and the converted Color is made in the
-- callback that asks for it, so no temporary outlives its callback through them.
-- A fresh Color in every call would cost five times as much per call, and some mods ask for one per rect.
-- draw.cdirty: a color was cached since the last emptying, so a scope with nothing new in it empties nothing (a table
-- that grew big costs its whole size to walk even when it's empty).
-- The key is one number only for whole channels 0-255; any other channel (a mod's fraction, or one out of range) would
-- give another color's number ((0.5, 0, 0) is (0, 128, 0)), so that color is cached under a text of its own
-- (draw.color_odd) and still reaches the engine exactly as I was handed it. The check is one lookup a channel: each
-- channel's share of the key, in a table that has only the whole numbers 0-255 (cheaper than multiplying it out).
local color_frame = -1
draw.odd_keys = {}
local color = (function()
  local R, G, B, A, colors = {}, {}, {}, {}, draw.colors
  for i = 0, 255 do R[i], G[i], B[i], A[i] = i * 16777216, i * 65536, i * 256, true end
  return function(r, g, b, a)
    if color_frame ~= frame_no then   -- emptied in place: no new tables every frame
      color_frame = frame_no
      compat.table_clear(colors); compat.table_clear(draw.keys); compat.table_clear(draw.ui_colors)
      compat.table_clear(draw.odd_keys); draw.cdirty = false
    end
    a = a or 255
    local x, y, z = R[r], G[g], B[b]
    if not (x and y and z and A[a]) then return draw.color_odd(r, g, b, a) end
    local key = x + y + z + a
    local c = colors[key]
    if c == nil then
      c = api('Color', a, r, g, b) or false; colors[key], draw.cdirty = c, true
      if c then draw.keys[c] = key end
    end
    return c or nil
  end
end)()
-- A color that isn't four whole channels 0-255. It has no number in draw.keys (a text in it always counts as changed);
-- draw.odd_keys gives the number of its nearest whole color, which is what it's converted as below native.
function draw.color_odd(r, g, b, a)
  local key = r * 16777216 + g * 65536 + b * 256 + a   -- (what isn't a number fails here, as it always did)
  key = fmt('%.17g %.17g %.17g %.17g', r, g, b, a)
  local c = draw.colors[key]
  if c == nil then
    c = api('Color', a, r, g, b) or false; draw.colors[key], draw.cdirty = c, true
    if c then
      local n = draw.near
      draw.odd_keys[c] = n(r) * 16777216 + n(g) * 65536 + n(b) * 256 + n(a)
    end
  end
  return c or nil
end
-- a channel as the nearest whole number 0-255 (a NaN as 0)
function draw.near(v)
  v = tonumber(v) or 0
  if not (v > 0) then return 0 end
  if v >= 255 then return 255 end
  return floor(v + 0.5)
end
-- whether c is a Color color() made this frame (a mod's own value isn't)
function draw.ours(c) return color_frame == frame_no and (draw.keys[c] or draw.odd_keys[c]) ~= nil end
function draw.color_scope()
  if draw.cdirty then draw.cdirty = false; compat.table_clear(draw.colors); compat.table_clear(draw.ui_colors) end
end
-- Below native the colors go to the UI world, which shows them differently from the game's world (native): measured
-- with swatches of 16 steps per channel drawn both ways (3440x1440, HDR on), the game's
-- world puts them through its tone mapping (N: a steep curve, 136 already comes out 204-255) and the UI world through
-- a near-straight one (U: 17 -> 35, 255 -> 255); both blend before their curve. So a color I'm handed (as it should
-- look, the native look) is stored below native as U^-1(N(c)) per channel, and a see-through one gets the alpha and
-- color that fit best over three backgrounds (a dark panel, dark ground, mid ground). A tint on a texture that has a UI
-- copy (the copy already carries the conversion) is only scaled so white stays white. A mod's build can make UI
-- copies of its textures with the same tables and rule. These are one screen's curves: another screen or HDR setting
-- may differ a little.
local ui_conv = {}                -- color key (negated for a tint) -> { a, r, g, b } below native, kept
local ui_convert
do
  local UI_N = { { 0, 7, 27, 51, 78, 110, 148, 196, 255, 255, 255, 255, 255, 255, 255, 255 },
                 { 0, 7, 25, 44, 65, 89, 120, 165, 221, 255, 255, 255, 255, 255, 255, 255 },
                 { 0, 5, 20, 41, 64, 91, 124, 165, 220, 255, 255, 255, 255, 255, 255, 255 } }
  local UI_U = { { 0, 35, 58, 79, 98, 117, 136, 155, 175, 195, 217, 238, 255, 255, 255, 255 },
                 { 0, 38, 57, 74, 91, 110, 130, 151, 173, 193, 215, 235, 255, 255, 255, 255 },
                 { 0, 33, 54, 74, 93, 111, 129, 148, 167, 187, 207, 228, 248, 255, 255, 255 } }
  local UI_BACKS = { 6, 40, 110 }
  local function curve(ys, v)                       -- ys at 0, 17, ... 255
    if v <= 0 then return ys[1] end
    if v >= 255 then return ys[16] end
    local i = floor(v / 17)
    local f = v / 17 - i
    return ys[i + 1] + (ys[i + 2] - ys[i + 1]) * f
  end
  local function curve_inv(ys, t)                   -- over the curve's rising part
    if t <= ys[1] then return 0 end
    for i = 2, 16 do
      if ys[i] >= t then
        if ys[i] == ys[i - 1] then return (i - 1) * 17 end
        return (i - 2) * 17 + 17 * (t - ys[i - 1]) / (ys[i] - ys[i - 1])
      end
      if ys[i] >= 255 then return (i - 1) * 17 end
    end
    return 255
  end
  local function ui_m(ch, v) return curve_inv(UI_U[ch], curve(UI_N[ch], v)) end
  ui_convert = function(key, tint)
    local a = key % 256
    local c = { floor(key / 16777216) % 256, floor(key / 65536) % 256, floor(key / 256) % 256 }
    local s = { ui_m(1, c[1]), ui_m(2, c[2]), ui_m(3, c[3]) }
    if tint then
      for ch = 1, 3 do s[ch] = s[ch] * 255 / ui_m(ch, 255) end
    elseif a > 0 and a < 255 then
      local af = a / 255
      local want, mb = {}, {}
      for j, back in ipairs(UI_BACKS) do
        want[j], mb[j] = {}, {}
        for ch = 1, 3 do
          local b = curve_inv(UI_N[ch], back)
          want[j][ch] = ui_m(ch, af * c[ch] + (1 - af) * b)
          mb[j][ch] = ui_m(ch, b)
        end
      end
      local best, best_a, best_s = math.huge, af, s
      for step = 1, 64 do
        local a2 = step / 64
        local s2, err = {}, 0
        for ch = 1, 3 do
          local sum = 0
          for j = 1, #UI_BACKS do sum = sum + (want[j][ch] - (1 - a2) * mb[j][ch]) / a2 end
          s2[ch] = max(0, min(255, sum / #UI_BACKS))
          for j = 1, #UI_BACKS do
            local d = a2 * s2[ch] + (1 - a2) * mb[j][ch] - want[j][ch]
            err = err + d * d
          end
        end
        if err < best then best, best_a, best_s = err, a2, s2 end
      end
      s, a = best_s, best_a * 255
    end
    return { floor(a + 0.5), floor(min(255, s[1]) + 0.5), floor(min(255, s[2]) + 0.5), floor(min(255, s[3]) + 0.5) }
  end
end
-- the numbers of a color made by color() this frame (an engine Color is a temporary whose slot is used again in later
-- frames, so a key kept from an earlier frame would be another color's)
function draw.key_of(c) return color_frame == frame_no and draw.keys[c] or nil end
local function ui_color(c, tint)
  local key = draw.key_of(c)
  if not key then
    -- (a color with a fraction or a channel out of range: converted as its nearest whole color, the same Color)
    key = color_frame == frame_no and draw.odd_keys[c]
    if not key then return c end
  end
  local ck = tint and -key or key
  local u = draw.ui_colors[ck]
  if u == nil then
    local v = ui_conv[ck]
    if not v then v = ui_convert(key, tint); ui_conv[ck] = v end
    u = api('Color', v[1], v[2], v[3], v[4]) or c
    draw.ui_colors[ck], draw.cdirty = u, true
  end
  return u
end

-- Render Scale. Below native (Ultra Quality and lower) the game renders its world at a smaller size and upscales it.
-- A screen GUI in the game's world is still placed in screen pixels, but only the render size's worth of the screen
-- (its top-left part) reaches the picture: at Ultra Quality a panel at the bottom right is cut in half, at Quality
-- and below it's gone. A screen GUI in the UI world (the top world, where the game draws effects like the spore
-- cloud) is placed in screen pixels too and covers the whole screen at any Render Scale. So below native I draw the
-- screen there instead; at native I keep the game's world. The UI world is drawn after the game's own HUD and map
-- (their own UI system, not GUI layers), so below native the open map can't cover what I draw: no layer and no
-- other world puts it under. A GUI placed in the game's world in front of the camera (World.create_world_gui) is
-- clipped to the same render-size rectangle as a screen GUI there (and lags the camera when it turns), so the UI world
-- is the only way to the bottom right below native. The render scale comes from the game's settings file.
-- The settings file (about 8 KB): one cache for the Render Scale here and chef.setting, read again on a world change
-- or a new screen size, else at most every cfg.every s (a file that can't be read waits as long). The Render Scale only
-- changes in the game's options screen, so 90 s is plenty. cfg.n counts the texts read, so a reader only parses a new
-- one. A file that doesn't parse (the game may be writing it) keeps the last answer.
-- cfg.again: one more read 3 s after this one (a new screen size: the game may write its new file only after the
-- window changed).
local cfg = { text = nil, n = 0, at = -100, scale = nil, scale_n = 0, every = 90 }
local function cfg_text()
  if elapsed < cfg.at + cfg.every then return cfg.text, cfg.n end
  cfg.at = elapsed
  if cfg.again then cfg.again, cfg.at = nil, elapsed - cfg.every + 3 end
  if type(os_) ~= 'table' then return cfg.text, cfg.n end
  local ok, appdata = pcall(os_.getenv, 'APPDATA')
  if not (ok and type(appdata) == 'string' and appdata ~= '') then return cfg.text, cfg.n end
  local f = open(appdata .. '\\Arrowhead\\Helldivers2\\user_settings.config', 'r')
  if not f then return cfg.text, cfg.n end
  local okr, text = pcall(f.read, f, '*a')
  pcall(f.close, f)
  if okr and type(text) == 'string' and text ~= cfg.text then cfg.text, cfg.n = text, cfg.n + 1 end
  return cfg.text, cfg.n
end
new_world_hooks[#new_world_hooks + 1] = function() cfg.at = -100 end
-- I compare the render size with the window's (w, h: the back buffer), not with the settings' screen_resolution: in
-- Borderless with a Resolution below the monitor's, both say 1920x1080 while the window is the monitor's 2560x1440,
-- and the game's world shows only its top-left 1920x1080 of it, the same as a Render Scale below native. Smaller in
-- either direction (another aspect too) is below native. -> the scale (nil at native), and the render size it came
-- from. An answer is kept for that text and window size only once the text parsed. A text that doesn't parse (a
-- half-written file) keeps the last answer, isn't parsed again, and has the file read again in 3 s, not 90.
local function file_scale(w, h)
  local text, n = cfg_text()
  if n == cfg.scale_n and w == cfg.scale_w and h == cfg.scale_h then return cfg.scale, cfg.rw, cfg.rh end
  if not (text and w and h and w > 0 and h > 0) or n == cfg.bad_n then return cfg.scale, cfg.rw, cfg.rh end
  local rw, rh = text:match('[%s{]render_resolution%s*=%s*%[%s*(%d+)%s+(%d+)%s*%]')
  rw, rh = tonumber(rw), tonumber(rh)
  if not (rw and rh and rw > 0 and rh > 0) then
    cfg.bad_n, cfg.at = n, elapsed - cfg.every + 3
    return cfg.scale, cfg.rw, cfg.rh
  end
  cfg.scale_n, cfg.scale_w, cfg.scale_h, cfg.rw, cfg.rh = n, w, h, rw, rh
  local s = rw / w < rh / h and rw / w or rh / h
  cfg.scale = (s > 0.2 and s < 0.98) and s or nil
  return cfg.scale, rw, rh
end
-- In the UI world my layer L is drawn at UI_BASE + L - 900 (880-960 at -120 to -40: under whatever the
-- game itself draws there with GUI layers)
local UI_BASE = -100
draw.ui, draw.ui_base = false, UI_BASE
-- A NaN or an infinity handed to the engine's drawing can end the game (a mod's layout bug: a divide by zero), so none
-- reaches it. draw.finite: none of these is one (anything that isn't a number passes: the engine refuses that itself,
-- as a Lua error). The hot paths do the same with x - x, which is 0 only for a finite number, inside their pcall.
do
  local HUGE = math.huge
  function draw.finite(a, b, c, d, e)
    if a ~= a or b ~= b or c ~= c or d ~= d or e ~= e then return false end
    if a == HUGE or b == HUGE or c == HUGE or d == HUGE or e == HUGE then return false end
    if a == -HUGE or b == -HUGE or c == -HUGE or d == -HUGE or e == -HUGE then return false end
    return true
  end
end

-- My GUIs live in the world they were made in: within the same instance they're kept (the ship loaded into the
-- mission's world is the same engine world), in a new one they're dropped without being touched (a GUI used after its
-- world went away crashes the game, and so may destroying it).
local function draw_world_reset()
  if draw.frame == frame_no then return end
  draw.frame = frame_no
  if draw.world ~= world.id then
    if draw.instance ~= world.instance then
      hold('loader|draw:gui', false); hold('loader|draw:lines', false)
      hold('loader|draw:bitmaps', false)
      draw.gui, draw.lines, draw.icons, draw.icon_ok = nil, nil, {}, nil
      if draw.nt.main then draw.nt_drop(draw.nt.main) end
      draw.instance = world.instance
    end
    draw.world, draw.lines_used = world.id, false
    draw.size_at = -1
  end
  -- the screen size again every 2 s (it can change mid-mission); a new size reads the settings file again
  if elapsed >= (draw.size_at or -1) + 2 then
    draw.size_at = elapsed
    local w, h = api('Application.back_buffer_size')
    if type(w) == 'number' and type(h) == 'number' and w > 0 and h > 0 then
      if w ~= draw.w or h ~= draw.h then cfg.at, cfg.again = -100, true end
      local s, rw, rh = file_scale(w, h)
      local ui = s ~= nil
      -- (said again when the render size alone changed too: Ultra Quality to Quality stays in the UI world)
      if w ~= draw.w or h ~= draw.h or ui ~= draw.ui or s ~= draw.s or not draw.said then
        draw.w, draw.h, draw.ui, draw.s, draw.said = w, h, ui, s, true
        log(fmt('screen %dx%d, rendering at %s: drawing in %s', w, h, s and fmt('%dx%d (%.3f)', rw, rh, s) or 'native',
          ui and fmt('the UI world (layers from %d)', draw.ui_base - 20) or "the game's world"))
      end
    end
  end
end

local function gui()
  if not world.stable then return nil end
  draw_world_reset()
  if skip['loader|draw:gui'] then return nil end
  if draw.gui == nil then
    draw.gui = api('World.create_screen_gui', world.main, 'immediate', 'material', GUI_FONT, 'material', GUI_MAT) or false
    if draw.gui then hold('loader|draw:gui', true) end
  end
  return draw.gui or nil
end

-- The top: the first world that isn't the main one. The game draws its own HUD, map and menus in that world too,
-- sorted in with my layers there: its layers 0 to 1000 show over all of them but the menus' top bar and button
-- prompts (0 only partly: some menu panels are at it), higher ones only over the HUD and the map, below 0 only over
-- the HUD. Anything drawn at layer 2000 or up goes there, at its layer - 2000 (so 2000-2999: over the menus too). I check every frame that
-- something is drawn there that it's still the same world (and the world count hasn't changed); if not, I drop my
-- GUIs without touching them, because a GUI used after its world went away crashes the game.
local TOP_FROM = 2000
local top = { world = nil, n = 0, wid = -1, gui = nil, icons = {}, frame = -1 }
-- (the game's world list, read once a frame)
function draw.worlds()
  if draw.ws_frame ~= frame_no then draw.ws_frame, draw.ws = frame_no, api('Application.worlds') end
  return draw.ws
end
local function top_drop()
  hold('loader|draw:top', false)
  top.world, top.gui, top.icons = nil, nil, {}
  if draw.nt and draw.nt.top then draw.nt_let_top() end   -- (its text GUI goes the same way: draw.nt_let_top)
end
local function top_world()
  if skip['loader|draw:top'] or not world.stable then return nil end
  if top.frame == frame_no then return top.world end
  top.frame = frame_no
  local ws = draw.worlds()
  local found, n = nil, 0
  if type(ws) == 'table' then
    n = #ws
    for i = 1, n do if ws[i] ~= world.main then found = ws[i]; break end end
  end
  if top.world ~= nil and (found == nil or n ~= top.n or top.wid ~= world.id or not (found == top.world)) then top_drop() end
  if top.world == nil and found ~= nil then top.world, top.n, top.wid = found, n, world.id end
  return top.world
end
local function top_gui()
  local w = top_world()
  if not w then return nil end
  if top.gui == nil then
    top.gui = api('World.create_screen_gui', w, 'immediate', 'material', GUI_FONT, 'material', GUI_MAT) or false
    if top.gui then hold('loader|draw:top', true) end
  end
  return top.gui or nil
end

-- The hot path of every panel: a few thousand of these a frame. After the first (breadcrumbed) calls proved
-- Vector3, Vector2 and Gui.rect, I call them straight through one pcall, with no key strings built per call.
local fast_rect = nil
local function rect_fast(g, x, y, w, h, c, layer)
  if (x - x) + (y - y) + (w - w) + (h - h) + (layer - layer) ~= 0 then return end
  local V3, V2, R = S.Vector3, S.Vector2, S.Gui.rect
  return R(g, V3(x, y, layer), V2(w, h), c)
end
local function rect(x, y, w, h, c, layer)
  if not c or not world.stable then return end
  layer = layer or 900
  if draw.frame ~= frame_no then draw_world_reset() end
  local g
  if layer >= TOP_FROM then g = top_gui(); layer = layer - TOP_FROM
  elseif draw.ui then g = top_gui(); layer = min(draw.ui_base + layer - 900, -1); if not draw.raw then c = ui_color(c) end
  else
    -- PERF: the game world's GUI straight from draw once it's made (gui() again only while there's none)
    g = draw.gui
    if not g then g = gui() end
  end
  if not g then return end
  -- a fast call that fails takes the guarded path: when that one works, the fast path itself is what failed and it
  -- goes off; when it fails too, the arguments were bad (a mod's odd color, say) and the fast path stays on for the rest
  local tried = fast_rect
  if tried and pcall(rect_fast, g, x, y, w, h, c, layer) then return end
  if not draw.finite(x, y, w, h, layer) then return end
  local p, s = api('Vector3', x, y, layer), api('Vector2', w, h)
  if p and s then
    -- (no error: the three calls were made, breadcrumbed the first time)
    local _, err = api('Gui.rect', g, p, s, c)
    if not err then
      if tried then fast_rect = false elseif fast_rect == nil then fast_rect = true end
    end
  end
end

-- A filled triangle through the engine (Gui.triangle, the same GUI and layers as rect): points given as Vector3(x, 0, y)
-- plus the layer. If the engine refuses it with a color color() made, draw.tri_ok goes false
-- and the shapes (utilities.lua) use rects. A field of draw, not a local: the loader is near Lua 5.1's 200 locals.
draw.tri_ok = nil
function draw.tri_fast(g, x1, y1, x2, y2, x3, y3, c, layer)
  if (x1 - x1) + (y1 - y1) + (x2 - x2) + (y2 - y2) + (x3 - x3) + (y3 - y3) + (layer - layer) ~= 0 then return false end
  local V3 = S.Vector3
  S.Gui.triangle(g, V3(x1, 0, y1), V3(x2, 0, y2), V3(x3, 0, y3), layer, c)
  return true
end
function draw.tri(x1, y1, x2, y2, x3, y3, c, layer)
  if not c or not world.stable or draw.tri_ok == false then return false end
  layer = layer or 900
  if draw.frame ~= frame_no then draw_world_reset() end
  local g, c0 = nil, c
  if layer >= TOP_FROM then g = top_gui(); layer = layer - TOP_FROM
  elseif draw.ui then g = top_gui(); layer = min(draw.ui_base + layer - 900, -1); c = ui_color(c)
  else g = draw.gui or gui() end      -- (as in rect: the game world's GUI straight from draw once it's made)
  if not g then return false end
  if draw.tri_ok then
    local ok, r = pcall(draw.tri_fast, g, x1, y1, x2, y2, x3, y3, c, layer)
    if ok then return r end
  end
  if not (draw.finite(x1, y1, x2, y2, x3) and draw.finite(y3, layer)) then return false end
  local a, b, d = api('Vector3', x1, 0, y1), api('Vector3', x2, 0, y2), api('Vector3', x3, 0, y3)
  local err = 'no point'
  if a and b and d then
    local _
    _, err = api('Gui.triangle', g, a, b, d, layer, c)
  end
  if err then
    -- (a mod's own odd color: that call only; Gui.triangle is blamed only when the color was one of mine)
    if not draw.ours(c0) then return false end
    draw.tri_ok = false
    log('shapes: the engine refused Gui.triangle (' .. tostring(err) .. '); shapes are drawn with rects')
    return false
  end
  if draw.tri_ok == nil then log('shapes: engine triangles work') end
  draw.tri_ok = true
  return true
end

-- 5x7 pixel font. Each glyph: 7 rows of 5 bits, top row first.
local GLYPHS = {
  ['A'] = '01110100011000111111100011000110001', ['B'] = '11110100011000111110100011000111110',
  ['C'] = '01110100011000010000100001000101110', ['D'] = '11100100101000110001100011001011100',
  ['E'] = '11111100001000011110100001000011111', ['F'] = '11111100001000011110100001000010000',
  ['G'] = '01110100011000010111100011000101111', ['H'] = '10001100011000111111100011000110001',
  ['I'] = '01110001000010000100001000010001110', ['J'] = '00111000100001000010000101001001100',
  ['K'] = '10001100101010011000101001001010001', ['L'] = '10000100001000010000100001000011111',
  ['M'] = '10001110111010110101100011000110001', ['N'] = '10001100011100110101100111000110001',
  ['O'] = '01110100011000110001100011000101110', ['P'] = '11110100011000111110100001000010000',
  ['Q'] = '01110100011000110001101011001001101', ['R'] = '11110100011000111110101001001010001',
  ['S'] = '01111100001000001110000010000111110', ['T'] = '11111001000010000100001000010000100',
  ['U'] = '10001100011000110001100011000101110', ['V'] = '10001100011000110001100010101000100',
  ['W'] = '10001100011000110101101011010101010', ['X'] = '10001100010101000100010101000110001',
  ['Y'] = '10001100010101000100001000010000100', ['Z'] = '11111000010001000100010001000011111',
  ['0'] = '01110100011001110101110011000101110', ['1'] = '00100011000010000100001000010001110',
  ['2'] = '01110100010000100010001000100011111', ['3'] = '11111000100010000010000011000101110',
  ['4'] = '00010001100101010010111110001000010', ['5'] = '11111100001111000001000011000101110',
  ['6'] = '00110010001000011110100011000101110', ['7'] = '11111000010001000100010000100001000',
  ['8'] = '01110100011000101110100011000101110', ['9'] = '01110100011000101111000010001001100',
  [' '] = '00000000000000000000000000000000000', ['.'] = '00000000000000000000000000110001100',
  [':'] = '00000011000110000000011000110000000', ['-'] = '00000000000000011111000000000000000',
  ['/'] = '00001000010001000100010001000010000', ['%'] = '11001110010001000100010001001110011',
  ['+'] = '00000001000010011111001000010000000', ['('] = '00010001000100001000010000010000010',
  [')'] = '01000001000001000010000100010001000', ["'"] = '00100001000100000000000000000000000',
  ['!'] = '00100001000010000100001000000000100', ['?'] = '01110100010000100010001000000000100',
  [','] = '00000000000000000000001100010001000', ['x'] = '00000000001000101010001000101010001',
  ['>'] = '10000010000010000010001000100010000', ['<'] = '00001000100010001000001000001000001',
}
-- Each glyph as a few rects: runs along a row, merged down over identical rows (about 6-12 rects a letter).
local glyph_rects = {}
local function rects_of(ch)
  local r = glyph_rects[ch]
  if r then return r end
  local bits = GLYPHS[ch] or GLYPHS[ch:upper()] or GLYPHS['?']
  local runs = {}
  for row = 0, 6 do
    local col = 0
    while col < 5 do
      if sub(bits, row * 5 + col + 1, row * 5 + col + 1) == '1' then
        local start = col
        while col < 5 and sub(bits, row * 5 + col + 1, row * 5 + col + 1) == '1' do col = col + 1 end
        runs[#runs + 1] = { x = start, w = col - start, row = row }
      else
        col = col + 1
      end
    end
  end
  r = {}
  local used = {}
  for i, a in ipairs(runs) do
    if not used[i] then
      local h = 1
      for j = i + 1, #runs do
        local b = runs[j]
        if not used[j] and b.x == a.x and b.w == a.w and b.row == a.row + h then used[j] = true; h = h + 1 end
      end
      r[#r + 1] = { x = a.x, y = 7 - a.row - h, w = a.w, h = h }   -- y measured up from the glyph's bottom
    end
  end
  glyph_rects[ch] = r
  return r
end

-- Sprites: small pictures given as rows of characters (top row first); each character maps to a color, '.' is
-- empty. Drawn as rects, runs along a row merged down over identical rows, cached per sprite.
local sprite_rects = setmetatable({}, { __mode = 'k' })
local function sprite_runs(rows)
  local r = sprite_rects[rows]
  if r then return r end
  local h = #rows
  local runs = {}
  for row = 1, h do
    local line, col = rows[row], 1
    while col <= #line do
      local ch = sub(line, col, col)
      if ch ~= '.' then
        local start = col
        while col <= #line and sub(line, col, col) == ch do col = col + 1 end
        runs[#runs + 1] = { x = start - 1, w = col - start, row = row - 1, ch = ch }
      else
        col = col + 1
      end
    end
  end
  r = {}
  local used = {}
  for i, a in ipairs(runs) do
    if not used[i] then
      local n = 1
      for j = i + 1, #runs do
        local b = runs[j]
        if not used[j] and b.x == a.x and b.w == a.w and b.ch == a.ch and b.row == a.row + n then used[j] = true; n = n + 1 end
      end
      r[#r + 1] = { x = a.x, y = h - a.row - n, w = a.w, h = n, ch = a.ch }
    end
  end
  sprite_rects[rows] = r
  return r
end
-- x, y = bottom-left corner; cell = size of one sprite pixel; colors = { [char] = color }
local function sprite(x, y, rows, cell, colors, layer)
  for _, r in ipairs(sprite_runs(rows)) do
    local c = colors[r.ch]
    if c then rect(x + r.x * cell, y + r.y * cell, r.w * cell, r.h * cell, c, (layer or 900) + (r.ch == 'o' and 0 or 1)) end
  end
end

-- Text in the game's own font: FSSinclair Medium (the HUD's), else the next one the game has loaded (FSSinclair Regular,
-- a locale's UI font by its id), always through the game's runtime-font material. A GUI can only use a font whose
-- material the game makes itself: its development fonts end the game. It's retained: a screen GUI that gets text has a
-- retained text GUI beside it (made right after it, so it draws over it, and dropped with it), each text call of a frame
-- takes the next slot of it in order, and a slot's text is made once, then changed (Gui.update_text) only when its
-- words, size, place or color change. Slots a frame didn't use are removed at the start of the next. Sizes and widths
-- come from Gui.text_extents: the cap height of 'H' sets the size (the pixel font's 7 cells), each letter's advance is
-- measured once. All caps, as the pixel font and the game's HUD. The pixel font stays for when none of these fonts is
-- loaded, text calls fail, or a text call ended the game (skipped from the next launch on).
do
  -- UTF-8: one character (ASCII, or a lead byte and its continuation bytes) and a multibyte one; utf8_clean keeps the
  -- well-formed characters and makes every other byte a '?'; utf8_floor: the last character boundary at or before a
  -- byte count; utf8_len: characters
  draw.UTF8_CHAR, draw.UTF8_MB = '[%z\1-\127\194-\244][\128-\191]*', '[\194-\244][\128-\191]+'
  function draw.utf8_clean(str)
    local out, i, n = {}, 1, #str
    while i <= n do
      local b = byte(str, i)
      local len = b < 128 and 1 or (b >= 194 and b <= 223 and 2) or (b >= 224 and b <= 239 and 3) or (b >= 240 and b <= 244 and 4) or 0
      local ok = len > 0 and i + len - 1 <= n
      for k = i + 1, ok and i + len - 1 or i do
        local c = byte(str, k)
        if c < 128 or c > 191 then ok = false; break end
      end
      -- (and no overlong form, UTF-16 surrogate or code point past U+10FFFF: the second byte's narrower range)
      if ok and len > 2 then
        local c = byte(str, i + 1)
        if (b == 224 and c < 160) or (b == 237 and c > 159) or (b == 240 and c < 144) or (b == 244 and c > 143) then ok = false end
      end
      if ok then out[#out + 1] = sub(str, i, i + len - 1); i = i + len else out[#out + 1] = '?'; i = i + 1 end
    end
    return concat(out)
  end
  function draw.utf8_floor(str, n)
    while n > 0 and n < #str do
      local c = byte(str, n + 1)
      if c < 128 or c > 191 then break end
      n = n - 1
    end
    return n
  end
  function draw.utf8_len(str) local _, n = str:gsub('[^\128-\191]', ''); return n end
  local nt = { fonts = { 'content/fonts/fs_sinclair_medium_runtime', 'content/fonts/fallback', '9ad413a8fea59728' },
               MAT = 'content/fonts/runtime_font', font = nil, gen = 0, check_at = -100, fails = 0, adv = {}, cap = nil, base = 0,
               frame = -1, on = false, main = nil, top = nil, dead = false, row = nil, refused = {},
               WHICH = { 'main', 'top' } }
  draw.nt = nt
  -- the engine's font argument: a name as it is, a locale font's id made fresh for each call (an id kept from an earlier
  -- frame ends the game)
  local function font_arg(f)
    if f == nt.plain then return f end                      -- (a name I already know isn't an id: no match per call)
    if f:match('^%x+$') then return api('IdString64.from_hex', f) end
    nt.plain = f
    return f
  end
  local function fail(why, uncounted)
    if uncounted then return end                     -- (a mod's own odd color: that call only, the font stays on)
    nt.fails = nt.fails + 1
    log('text: ' .. why .. (nt.fails >= 3 and '; the pixel font for the rest of this session' or ''))
    if nt.fails >= 3 then nt.dead = true end
  end
  -- the first of the fonts the game has loaded, with its material (asked again every 2 s until one is)
  local function pick_font()
    if elapsed < nt.check_at + 2 then return nil end
    nt.check_at = elapsed
    if api('Application.can_get', 'material', nt.MAT) ~= true then return nil end
    for _, f in ipairs(nt.fonts) do
      local a = font_arg(f)
      if a ~= nil and api('Application.can_get', 'runtime_font', a) == true then return f end
    end
    return nil
  end
  -- Held from a call that makes something new (a text GUI, a text, a first measure) until a frame later in which none
  -- was made (the engine has drawn them by then): a game that ends in that window blames it, and a second time it's
  -- skipped (the pixel font from then on). Changing or removing a text that's already drawn holds nothing, so steady
  -- changes (a counter) don't keep it open for a whole mission.
  local function calls(t)
    if t and t.proven then return end                     -- (a text GUI whose first texts were drawn: none needed)
    nt.made_frame = frame_no
    if not nt.holding then nt.holding = true; hold('loader|draw:text', true) end
  end
  function draw.nt_forget(which) nt[which] = nil end
  -- the text calls the font needs: any of them skipped (it ended the game once) is the pixel font
  local NEEDS = { 'loader|Gui.text', 'loader|Gui.update_text', 'loader|Gui.destroy_text', 'loader|Gui.text_extents',
                  'loader|draw:text' }
  local function skipped()
    for i = 1, #NEEDS do if skip[NEEDS[i]] then return true end end
    return false
  end
  -- A retained GUI shows its texts until they're removed, so one is never just left in a world that's still there (an
  -- immediate GUI left there draws nothing). The main one goes with its engine world (a new instance). The top one is
  -- touched while its world is in the game's world list this frame (the rule the HD2Runtime look-alike keeps for mods'
  -- GUIs), and let go once it isn't.
  -- (nil: the list couldn't be read this frame, so not known: neither touched nor let go)
  local function listed_now(w)
    local ws = draw.worlds()
    if type(ws) ~= 'table' then return nil end
    for i = 1, #ws do if ws[i] == w then return true end end
    return false
  end
  -- the top text GUI may be touched: its screen GUI wasn't dropped, and the top world passes the screen GUI's test
  -- (listed, the same world count, the same main world); false: let go untouched; nil: not known this frame
  local function top_ok(t)
    if t.paired ~= top.gui or top.wid ~= world.id then return false end
    local l = listed_now(t.world)
    if l and #draw.ws ~= top.n then return false end
    return l
  end
  -- The top text GUI when the top world changed (the world count changed, or another world came first): one whose world
  -- is still in the game's world list this frame is removed with its texts (a retained GUI left in a world that's
  -- still there keeps showing them: entering a mission changes the count while the world the panels were on stays);
  -- one whose world isn't listed is let go untouched, and when the list can't be read it's let go too (said once).
  function draw.nt_let_top()
    local t = nt.top
    if not t then return end
    nt.top = nil
    local l = listed_now(t.world)
    if l == true then
      api('World.destroy_gui', t.world, t.g)
    elseif l == nil and t.max > 0 and not nt.said_top then
      nt.said_top = true
      log('text: the top world changed while texts were up and the world list could not be read; its text GUI was let go')
    end
  end
  -- the retained text GUI beside the main or the top screen GUI, made after it (so it draws over it): when that screen
  -- GUI is made again (a new main world, or after the top one idled), the text GUI is made again after it
  local function text_gui(which)
    local t = nt[which]
    local w, paired
    if which == 'main' then
      paired = gui()                                         -- (the screen GUI first)
      if not paired then return nil end
      if t and t.instance ~= draw.instance then draw.nt_drop(t); t = nil end   -- (gone with its world: draw.nt_drop)
      w = world.main
      if not t then draw.nt_said_dropped(w) end
    else
      paired = top_gui()                                     -- (a changed top world drops its text GUI: top_drop)
      if not paired then return nil end
      t = nt.top
      if t and t.paired ~= paired then draw.nt_let_top(); t = nil end   -- (its screen GUI was let go: so is it)
      w = top.world
    end
    if t and t.paired == paired then return t end
    if skipped() then return nil end
    calls()
    if t then api('World.destroy_gui', t.world, t.g); nt[which] = nil end
    local g = api('World.create_screen_gui', w, 'scale', 1, 1)
    if not g then fail('no text GUI could be made'); return nil end
    t = { g = g, world = w, paired = paired, instance = draw.instance, slots = {}, max = 0, n = 0, frame = -1 }
    nt[which] = t
    return t
  end
  -- a text's measures at size 100: left, bottom, right, top (from the pen at the baseline) and its advance
  local function extents(g, str)
    calls()
    local lo, hi, caret = api('Gui.text_extents', g, str, font_arg(nt.font), 100)
    if lo == nil then return nil end
    local ok, x0, y0, x1, y1, adv = pcall(function() return lo.x, lo.y, hi.x, hi.y, caret.x end)
    if not ok or type(x0) ~= 'number' or type(y0) ~= 'number' or type(x1) ~= 'number' or type(y1) ~= 'number'
      or type(adv) ~= 'number' or not draw.finite(x0, y0, x1, y1, adv) then return nil end
    return x0, y0, x1, y1, adv
  end
  -- on this frame? (worked out once a frame: the font found and measured, nothing turned it off)
  function draw.nt_on()
    if nt.frame == frame_no then return nt.on end
    nt.frame, nt.on = frame_no, false
    if nt.dead or not world.stable or skipped() then return false end
    -- the font in use is asked about again every 2 s (and in every frame that makes or changes a text, draw.nt_loaded):
    -- one the game let go of (a package unloaded) is never drawn with
    if nt.font and elapsed >= nt.check_at + 2 then
      nt.check_at = elapsed
      if not draw.nt_loaded() then return false end
      -- a later font in the list, picked while the first wasn't loaded yet (an early title screen): the first one as
      -- soon as it is, measured again, with every text up changed to it
      local f1 = nt.fonts[1]
      if nt.font ~= f1 then
        local a = font_arg(f1)
        if a ~= nil and api('Application.can_get', 'runtime_font', a) == true then
          nt.font, nt.cap, nt.adv, nt.refused, nt.loaded_frame, nt.gen = f1, nil, {}, {}, nil, nt.gen + 1
          for i = 1, 2 do
            local t = nt[nt.WHICH[i]]
            if t then t.proven, t.drew = nil, nil; for _, s in pairs(t.slots) do s.str, s.refont = nil, true end end
          end
        end
      end
    end
    if not nt.font then
      nt.font = pick_font()
      if not nt.font then return false end
      nt.gen = nt.gen + 1
      for i = 1, 2 do local t = nt[nt.WHICH[i]]; if t then t.proven, t.drew = nil, nil end end   -- (a new font: held again)
    end
    if not nt.cap then
      if not draw.nt_loaded() then return false end
      local t = text_gui('main')
      if not t then return false end
      local _, y0, _, y1 = extents(t.g, 'H')
      if not y0 or y1 - y0 < 10 or y1 - y0 > 200 then fail('the font measured wrong'); return false end
      nt.cap, nt.base = y1 - y0, y0
      -- (and whether it has CJK glyphs: one measure of a common one, for translators; 0 wide means none). Its own
      -- hold: after two launches that end in it, it's skipped. Measured once per font, kept as its advance.
      local cjk, CH = nil, '\228\184\173'
      if not skip['loader|font:cjk'] and nt.adv[CH] == nil then
        hold('loader|font:cjk', true)
        cjk = select(5, extents(t.g, CH))
        hold('loader|font:cjk', false)
        if cjk and cjk >= 0 and cjk < 400 then nt.adv[CH] = cjk end
      end
      cjk = cjk or nt.adv[CH]
      log(fmt('text: the game font %s (cap height %.1f at size 100; CJK glyphs: %s)', nt.font, nt.cap,
        cjk == nil and 'not measured' or (cjk > 0 and fmt('yes (%.1f wide)', cjk) or 'no')))
    end
    nt.on = true
    return true
  end
  -- the font and its material still loaded (asked once a frame); if not, it's let go of and the pixel font is used
  function draw.nt_loaded()
    if nt.loaded_frame == frame_no then return nt.loaded end
    nt.loaded_frame, nt.loaded = frame_no, false
    if not nt.font then return false end
    local a = font_arg(nt.font)
    if api('Application.can_get', 'material', nt.MAT) ~= true or a == nil or api('Application.can_get', 'runtime_font', a) ~= true then
      log('text: the game font ' .. nt.font .. ' is no longer loaded; the pixel font until one is')
      nt.font, nt.cap, nt.adv, nt.refused, nt.check_at, nt.on = nil, nil, {}, {}, -100, false
      return false
    end
    nt.loaded = true
    return true
  end
  local function size_of(px) return 7 * px * 100 / nt.cap end
  -- a letter's advance at size 100, measured once (an estimate if it can't be: no GUI this frame, or a refusal)
  local function advance(ch)
    local a = nt.adv[ch]
    if a then return a end
    if not draw.nt_loaded() then nt.guessed = true; return 60 end      -- (the font let go: nothing is measured)
    local t = (nt.main and nt.main.instance == world.instance and nt.main)
      or (nt.top and top_ok(nt.top) == true and nt.top) or (world.stable and text_gui('main')) or nil
    if not t then nt.guessed = true; return 60 end           -- (no text GUI to ask: a guess, asked again later)
    local r = nt.refused[ch]
    if r and r.frame == frame_no then nt.guessed = true; return 60 end   -- (refused this frame: asked in a later one)
    local adv = select(5, extents(t.g, ch))
    if adv and adv >= 0 and adv < 400 then nt.adv[ch] = adv; return adv end
    -- (refused: a guess; refused in 3 frames, the guess stays)
    if not r then r = { n = 0 }; nt.refused[ch] = r end
    r.frame, r.n = frame_no, r.n + 1
    if r.n >= 3 then nt.adv[ch] = 60 else nt.guessed = true end
    return 60
  end
  -- the text as drawn: capitals (A-Z only), no control characters, UTF-8 kept whole (any byte that isn't part of a
  -- well-formed character is a '?', and so is a character the font has no glyph for: it measures 0 wide), at most 1024
  -- bytes (the engine's limit for one text), cut between characters. Plain ASCII skips all of that.
  local function shown(str)
    -- (already as drawn: no lowercase letter, control character or byte above 127, and short enough; most texts)
    if #str <= 1024 and not str:find('[%l%c\128-\255]') then return str end
    str = str:upper():gsub('%c', ' ')
    if str:find('[\128-\255]') then
      str = draw.utf8_clean(str):gsub(draw.UTF8_MB, function(ch) if advance(ch) <= 0 then return '?' end end)
    end
    if #str > 1024 then str = sub(str, 1, draw.utf8_floor(str, 1024)) end
    return str
  end
  -- PERF: what measuring a text works out, kept for the font it was worked out with (nt.adv: a new font makes it anew,
  -- and this starts over): a text's advances summed (sums) and the text as shown (shown, for nt_text), by the text as
  -- given, so a menu drawn every frame works out each of its texts once. Two generations of 1024 each, as the
  -- language's cache: a text drawn again stays. Nothing worked out with a guessed glyph is kept (it's worked out again
  -- next time). A shown text's sum is kept by it too: shown leaves a text already shown as it is.
  -- PERF: a text is kept only from the second time it's met (seen: the texts met once, by the text as given), so a
  -- counter's new text every frame never fills them. The generations are emptied in place and used again (a new
  -- 1024-entry table every few frames was most of a new text's garbage). ab: an ASCII letter's advance by its byte.
  nt.memo = { adv = nil, sums = { cur = {}, old = {}, n = 0 }, shown = { cur = {}, old = {}, n = 0 },
              seen = { cur = {}, old = {}, n = 0 }, ab = {} }
  nt.NONE = {}                                         -- (never written: an empty ab while nt.adv isn't the memo's)
  function nt.memo_clear(c) compat.table_clear(c.cur); compat.table_clear(c.old); c.n = 0 end
  function nt.memo_of(which)
    local m = nt.memo
    if m.adv ~= nt.adv then
      m.adv = nt.adv
      nt.memo_clear(m.sums); nt.memo_clear(m.shown); nt.memo_clear(m.seen); compat.table_clear(m.ab)
    end
    return m[which]
  end
  function nt.memo_put(c, key, v)
    if c.n >= 1024 then
      local o = c.old
      compat.table_clear(o)
      c.old, c.cur, c.n = c.cur, o, 0
    end
    c.cur[key], c.n = v, c.n + 1
  end
  function nt.memo_get(c, key)
    local v = c.cur[key]
    if v == nil then
      v = c.old[key]
      if v ~= nil then nt.memo_put(c, key, v) end
    end
    return v
  end
  -- a text met before (true), else noted as met now (false)
  function nt.again(key)
    local Sn = nt.memo_of('seen')
    if nt.memo_get(Sn, key) then return true end
    nt.memo_put(Sn, key, true)
    return false
  end
  -- a shown text's advances summed, character by character as UTF-8. PERF: plain ASCII (most texts) byte by byte,
  -- each byte's advance from ab once nt.adv has it (the same numbers summed in the same order, without a new string
  -- or a closure per text)
  function nt.total(str)
    local total, M = 0, nt.memo
    if str:find('[\128-\255]') then
      for ch in str:gmatch(draw.UTF8_CHAR) do total = total + advance(ch) end
      return total
    end
    local A = M.adv == nt.adv and M.ab or nt.NONE
    for i = 1, #str do
      local b = byte(str, i)
      local a = A[b]
      if a == nil then
        local ch = sub(str, i, i)
        a = advance(ch)
        -- (kept only as nt.adv has it: a guess isn't; a font let go while measuring leaves ab alone)
        if M.adv == nt.adv then A[b] = nt.adv[ch] else A = nt.NONE end
      end
      total = total + a
    end
    return total
  end
  -- a shown text's width, and whether a glyph in it was a guess (nt.guessed kept as it was for my other callers);
  -- again: false for a text met for the first time (not kept)
  function draw.nt_measured(str, px, again)
    local S = nt.memo_of('sums')
    local total = nt.memo_get(S, str)
    if total ~= nil then
      nt.guessed = nt.guessed or false
      return floor(total * size_of(px) / 100 + 0.5), false
    end
    local was = nt.guessed
    nt.guessed = false
    total = nt.total(str)
    local w = floor(total * size_of(px) / 100 + 0.5)
    local g = nt.guessed
    nt.guessed = was or g
    if not g and again ~= false and nt.memo.adv == nt.adv then nt.memo_put(S, str, total) end
    return w, g
  end
  function draw.nt_width(str, px)
    local S = nt.memo_of('sums')
    local total = nt.memo_get(S, str)
    if total ~= nil and nt.cap then return floor(total * size_of(px) / 100 + 0.5) end
    local was = nt.guessed
    nt.guessed = false
    local s = shown(str)
    total = nt.total(s)
    local g = nt.guessed
    nt.guessed = was or g
    if not nt.cap then return draw.utf8_len(s) * 6 * px - px end   -- (the font went while measuring: the pixel font's width)
    if not g and nt.memo.adv == nt.adv and nt.again(str) then nt.memo_put(S, str, total) end
    return floor(total * size_of(px) / 100 + 0.5)
  end
  function draw.nt_text(x, y, str, px, c, layer)
    -- (x - x is 0 only for a finite number: all of these are numbers here, see text)
    if (x - x) + (y - y) + (px - px) ~= 0 or px <= 0 then return nil end
    local l, cc, which = layer or 900, c, 'main'
    if l >= TOP_FROM then which = 'top'; l = l - TOP_FROM
    elseif draw.ui then which = 'top'; l = min(draw.ui_base + l - 900, -1); if not draw.raw then cc = ui_color(cc) end end
    if not cc then return nil end
    local size = 7 * px * 100 / nt.cap                   -- (size_of)
    local b = nt.base * size / 100
    if type(l) ~= 'number' or (l - l) + (size - size) + (b - b) ~= 0 then return nil end   -- (the pixel font)
    -- PERF: a text GUI already used this frame is the one text_gui gives for the rest of it (the world, its instance,
    -- the top world and the screen GUIs are settled once a frame, before its first text), so only the frame's first
    -- text in each asks
    local t = nt[which]
    if not t or t.frame ~= frame_no then
      t = text_gui(which)
      if not t then return nil end
      if t.frame ~= frame_no then t.frame, t.n = frame_no, 0 end
    end
    -- (the same text as this slot's last one, in the same font: as shown then, without working it out again)
    local raw, s0, again = str, t.slots[t.n + 1], nil
    if s0 and s0.raw == raw and s0.gen == nt.gen then str = s0.str
    else
      -- (a glyph not measured yet was guessed: worked out again next time, not kept)
      local H = nt.memo_of('shown')
      local sh = nt.memo_get(H, raw)
      if sh ~= nil then str, nt.guessed = sh, nt.guessed or false
      else
        local was = nt.guessed
        nt.guessed = false
        str = shown(str)
        if nt.guessed then raw, again = nil, false
        else
          again = nt.again(raw)
          if again and nt.memo.adv == nt.adv then nt.memo_put(H, raw, str) end
        end
        nt.guessed = was or nt.guessed
      end
    end
    -- the change key: the color's numbers (and whether it was converted); a color I didn't make has none, so a slot
    -- with it is always changed (an engine value from an earlier frame is never compared or kept)
    local key = draw.key_of(c)
    local ck = key and (draw.ui and not draw.raw and which == 'top' and -key - 1 or key) or false
    t.n = t.n + 1
    local k = t.n
    if k > t.max then t.max = k end
    local s = t.slots[k]
    if s and ck and s.str == str and s.x == x and s.y == y and s.l == l and s.size == size and s.ck == ck then
      -- (kept while a glyph was guessed: measured again, and kept as shown once nothing is a guess)
      if s.raw == nil then
        local w2, g = draw.nt_measured(str, px)
        s.w, s.gen = w2, nt.gen
        if not g then s.raw = raw end
      end
      return s.w
    end
    if not draw.nt_loaded() then t.n = t.n - 1; return nil end
    local p = api('Vector3', x, y - nt.base * size / 100, l)
    if not p then t.n = t.n - 1; return nil end
    -- (a text that only moved: its width as the slot has it, worked out from the same text and size in this font with
    -- nothing guessed)
    local w, g
    if s and s.raw ~= nil and s.str == str and s.size == size and s.gen == nt.gen then
      w, g, nt.guessed = s.w, false, nt.guessed or false
    else
      w, g = draw.nt_measured(str, px, again)
    end
    if g then raw = nil end                              -- (a guessed width: measured again next time)
    if s then
      if s.refont then s.refont = nil; calls(t); t.drew = true end   -- (its first frame in a new font: held as a new one)
      local _, err = api('Gui.update_text', t.g, s.id, str, font_arg(nt.font), size, nt.MAT, p, cc)
      if err then
        api('Gui.destroy_text', t.g, s.id)
        t.slots[k], s = nil, nil
        t.n = t.n - 1
        fail('a text could not be changed (' .. err .. ')', not key)
        return nil
      end
      s.str, s.x, s.y, s.l, s.size, s.ck, s.w, s.raw, s.gen, s.px = str, x, y, l, size, ck, w, raw, nt.gen, px
    else
      calls(t)
      local id = api('Gui.text', t.g, str, font_arg(nt.font), size, nt.MAT, p, cc)
      if type(id) ~= 'number' then t.n = t.n - 1; fail('a text could not be made', not key); return nil end
      t.slots[k] = { id = id, str = str, x = x, y = y, l = l, size = size, ck = ck, w = w, raw = raw, gen = nt.gen, px = px }
      t.drew = true
    end
    return w
  end
  -- A new engine world instance for the main one: its text GUI is let go untouched, as every GUI of mine is then (one
  -- used after its world went away ends the game, and nothing tells a world that's gone from a new one in its place).
  -- Unless the old world stays in the game's world list in every frame from the change until the new main world has
  -- settled: then it's still drawn with the old GUI's texts on it (the title screen's world kept beside the ship's, or
  -- restarted in place), and that GUI is removed. A world that leaves the list even for a frame (or a frame the list
  -- can't be read) may be gone, with another in its place later: that GUI is let go untouched. The call has its own
  -- key, and its hold has the first claim on a launch that ends while it's open: a launch that ends in it (or, twice,
  -- in the frames after) leaves such texts untouched from then on.
  function draw.nt_drop(t)
    if nt.main == t then nt.main = nil end
    if t.max > 0 then nt.dropped, nt.dropped_g = t.world, t.g end
  end
  -- (called every frame while a dropped GUI is pending: forgotten the first frame its world isn't listed, removed in
  -- the first frame the main world is settled)
  function draw.nt_said_dropped(w)
    local d, g = nt.dropped, nt.dropped_g
    if d == nil then return end
    if listed_now(d) ~= true then
      nt.dropped, nt.dropped_g = nil, nil
      if not nt.said_left then
        nt.said_left = true
        log('text: the last main world left the world list; the texts of its old GUI were let go untouched')
      end
      return
    end
    if not world.stable then return end
    nt.dropped, nt.dropped_g = nil, nil
    local how = d == w and 'the main world restarted in place' or 'the last main world is still in the world list'
    local err = 'skipped'
    if not skip['loader|text:reclaim'] then
      nt.reclaim_frame = frame_no
      hold('loader|text:reclaim', true)
      proven['loader|text:reclaim'] = nil            -- (breadcrumbed every time: each one may be the one that ends it)
      err = select(2, guarded('loader', 'text:reclaim', fn_of('World.destroy_gui'), d, g))
    end
    if err == nil then
      if not nt.said_reclaim then
        nt.said_reclaim = true
        log('text: ' .. how .. '; the texts of its old GUI were removed')
      end
    elseif not nt.said_restart then
      nt.said_restart = true
      log('text: ' .. how .. '; the texts of its old GUI were left untouched (' .. tostring(err) .. ')')
    end
  end
  -- The slots a frame didn't use go (all of them while the font is off), in a text GUI whose world is still there.
  -- At the end of render (when=0: this frame's) and, in case render didn't run, at the start of the next frame (1).
  function draw.nt_sweep(when)
    -- (the text and reclaim holds: released once a frame with none made has passed, and a render since the last one
    -- made, or none seen this launch: the game draws in render)
    if when == 0 then nt.rendered = frame_no end
    if when == 1 and nt.reclaim_frame and nt.reclaim_frame < frame_no - 1
       and (not nt.rendered or nt.rendered > nt.reclaim_frame) then
      nt.reclaim_frame = nil; hold('loader|text:reclaim', false)
    end
    if when == 1 and nt.dropped ~= nil then draw.nt_said_dropped(world.main) end
    if when == 1 and nt.holding and (nt.made_frame or -1) < frame_no - 1
       and (not nt.rendered or nt.rendered > nt.made_frame) then
      nt.holding = false; hold('loader|draw:text', false)
      for i = 1, 2 do local t = nt[nt.WHICH[i]]; if t and t.drew then t.proven = true end end
    end
    -- while texts are up, the engine draws them with the font every frame: it's checked every frame they're there
    if when == 1 and nt.font and ((nt.main and nt.main.max > 0) or (nt.top and nt.top.max > 0)) then draw.nt_loaded() end
    local off = nt.dead or skipped() or not nt.font
    for _, which in ipairs(nt.WHICH) do
      local t = nt[which]
      if t then
        local alive
        if which == 'main' then
          alive = world.stable and t.instance == world.instance
          if not alive and t.instance ~= world.instance then draw.nt_drop(t) end
        else alive = top_ok(t) end
        if alive == false and which == 'top' then
          draw.nt_let_top()
        elseif alive then
          local keep = t.frame == frame_no - when and t.n or 0
          if off then keep = 0 end
          for i = t.max, keep + 1, -1 do
            local s = t.slots[i]
            if s then api('Gui.destroy_text', t.g, s.id); t.slots[i] = nil end
          end
          if t.max > keep then t.max = keep end
        end
      end
    end
  end
end
-- (the pixel font: every UTF-8 character, or stray byte above 127, is one '?')
function draw.pixel_text(str)
  if not str:find('[\128-\255]') then return str end
  return (str:gsub('[\192-\255][\128-\191]*', '?'):gsub('[\128-\191]', '?'))
end
-- (a text as the language picked in my menu has it: services.lang, once language files are found; else itself)
function draw.tr(s) return s end
draw.tr_id = draw.tr                       -- (no language: text skips the call)
function draw.tr_keep(s) return s end      -- (a text made from a translated one: kept as it is)
-- a text's width as drawn, as it is (draw.measure) or translated first (text_width)
function draw.measure(str, px)
  if type(str) == 'string' and type(px) == 'number' and draw.nt_on() then return draw.nt_width(str, px) end
  return #draw.pixel_text(str) * 6 * px - px
end
local function text_width(str, px) return draw.measure(draw.tr(str), px) end
-- PERF: once rect's fast path is proven, a whole text goes through one pcall, its GUI, layer and color worked out once
-- (rect does that per rect: twice draw_world_reset, the GUI and the layer for every one of a letter's 5-6 rects)
function draw.text_fast(g, x, y, str, px, c, layer)
  if (x - x) + (y - y) + (px - px) + (layer - layer) ~= 0 then return end
  local V3, V2, R = S.Vector3, S.Vector2, S.Gui.rect
  local cx = x
  for i = 1, #str do
    local ch = sub(str, i, i)
    if ch ~= ' ' then
      local rs = rects_of(ch)
      for j = 1, #rs do
        local r = rs[j]
        R(g, V3(cx + r.x * px, y + r.y * px, layer), V2(r.w * px, r.h * px), c)
      end
    end
    cx = cx + 6 * px
  end
end
local function text(x, y, str, px, c, layer)
  if not c then return 0 end
  -- Under my full screen menu (draw.cover: its lowest layer in the top world, while it's open) a text of the top world
  -- isn't drawn: the game's font draws over every rect of its world, so it would show through the menu. Measured all
  -- the same, for the caller's layout.
  local lv = layer or 900
  if draw.cover and type(px) == 'number' and type(lv) == 'number'
     and ((lv >= TOP_FROM and lv - TOP_FROM < draw.cover) or (lv < TOP_FROM and draw.ui)) then
    return text_width(type(str) == 'string' and str or tostring(str), px)
  end
  if draw.tr ~= draw.tr_id then str = draw.tr(str) end
  -- PERF: an unchanged text in the game's font is its retained slot as it was, found before anything else is worked
  -- out. Once the frame's first text in a text GUI went through nt_text (t.frame), the font, the GUI and the world are
  -- settled for the frame, so a slot with the same text, place, layer, size and color only gives back its width. (Its
  -- x, y and px passed nt_text's checks when it was drawn: equal to them, these are finite numbers too.)
  local nt = draw.nt
  if nt.on and nt.frame == frame_no and (layer == nil or type(layer) == 'number') then
    local t, l, ck = nt.main, lv, draw.key_of(c)
    if lv >= TOP_FROM then t, l = nt.top, lv - TOP_FROM
    elseif draw.ui then t, l = nt.top, min(draw.ui_base + lv - 900, -1) end
    if ck and draw.ui and not draw.raw then ck = -ck - 1 end
    if ck and t and t.frame == frame_no then
      local s = t.slots[t.n + 1]
      if s and s.raw == str and s.gen == nt.gen and s.x == x and s.y == y and s.px == px and s.l == l and s.ck == ck
         and s.size == 7 * px * 100 / nt.cap then
        -- (in the UI world the converted Color is still made in this call, as nt_text does)
        if draw.ui and lv < TOP_FROM and not draw.raw then ui_color(c) end
        local k = t.n + 1
        t.n = k
        if k > t.max then t.max = k end
        return s.w
      end
    end
  end
  if type(str) == 'string' and type(x) == 'number' and type(y) == 'number' and type(px) == 'number'
     and (layer == nil or type(layer) == 'number') and draw.nt_on() then
    local w = draw.nt_text(x, y, str, px, c, layer)
    if w then return w end
    -- (a text the game font couldn't take draws in the pixel font, this call only)
  end
  if type(str) == 'string' then str = draw.pixel_text(str) end
  if fast_rect and world.stable and type(str) == 'string' and type(x) == 'number' and type(y) == 'number'
     and type(px) == 'number' and (layer == nil or type(layer) == 'number') then
    local l, cc = layer or 900, c
    draw_world_reset()
    local g
    if l >= TOP_FROM then g = top_gui(); l = l - TOP_FROM
    elseif draw.ui then g = top_gui(); l = min(draw.ui_base + l - 900, -1); if not draw.raw then cc = ui_color(cc) end
    else g = gui() end
    if not g or pcall(draw.text_fast, g, x, y, str, px, cc, l) then return #str * 6 * px - px end
    -- a call that fails (a mod's odd color, say) takes the guarded path below, for this call only
  end
  local cx = x
  for i = 1, #str do
    local ch = sub(str, i, i)
    if ch ~= ' ' then
      for _, r in ipairs(rects_of(ch)) do rect(cx + r.x * px, y + r.y * px, r.w * px, r.h * px, c, layer) end
    end
    cx = cx + 6 * px
  end
  return cx - x - px
end

-- the longest start of a text that fits a width (measured), for cutting it with '...' or wrapping it
function draw.text_cut(str, px, maxw, dots)
  local lo, hi = 0, #str
  while lo < hi do
    local mid = floor((lo + hi + 1) / 2)
    if draw.measure(sub(str, 1, mid) .. dots, px) <= maxw then lo = mid else hi = mid - 1 end
  end
  return draw.utf8_floor(str, lo)          -- (never inside a UTF-8 character)
end
-- a text cut to a width, ending in '...' when it was cut
function draw.text_fit(str, px, maxw)
  local src = tostring(str or '')
  str = draw.tr(src)
  if type(px) ~= 'number' or type(maxw) ~= 'number' or draw.measure(str, px) <= maxw then return str end
  local n = draw.text_cut(str, px, maxw, '...')
  if n > 0 then return draw.tr_keep((sub(str, 1, n):gsub('%s+$', '')) .. '...', src) end
  return draw.measure('...', px) <= maxw and '...' or ''
end
-- a text broken into lines that fit a width, at spaces (a word longer than a line is broken where it has to be); at
-- most `most` lines (64 if not given), the rest left out
function draw.text_wrap(str, px, maxw, most)
  local lines, cur = {}, ''
  most = type(most) == 'number' and most >= 1 and floor(most) or 64
  if type(px) ~= 'number' or type(maxw) ~= 'number' or maxw <= 0 then return { tostring(str or '') } end
  local src = tostring(str or '')
  for word in draw.tr(src):gmatch('%S+') do
    local try = cur == '' and word or (cur .. ' ' .. word)
    if draw.measure(try, px) <= maxw then
      cur = try
    else
      if cur ~= '' then lines[#lines + 1] = cur end
      cur = word
      while #cur > 1 and #lines < most and draw.measure(cur, px) > maxw do
        local n = draw.text_cut(cur, px, maxw, '')
        if n < 1 then n = #(cur:match('^' .. draw.UTF8_CHAR) or sub(cur, 1, 1)) end   -- (at least one whole character)
        lines[#lines + 1] = sub(cur, 1, n)
        cur = sub(cur, n + 1)
      end
    end
    if #lines >= most then break end
  end
  if cur ~= '' and #lines < most then lines[#lines + 1] = cur end
  for i = 1, #lines do draw.tr_keep(lines[i], src) end
  return lines
end

-- Like rects: once the breadcrumbed calls proved Vector3 and LineObject.add_line, a line drawn after the frame's first
-- (its line object made and reset) goes straight through one pcall. draw.fast_line: nil until proven, false for good
-- once the fast call failed where the guarded one then worked.
function draw.line_fast(lo, c, x1, y1, z1, x2, y2, z2)
  if (x1 - x1) + (y1 - y1) + (z1 - z1) + (x2 - x2) + (y2 - y2) + (z2 - z2) ~= 0 then return end
  local V3 = S.Vector3
  return S.LineObject.add_line(lo, c, V3(x1, y1, z1), V3(x2, y2, z2))
end
local function line(x1, y1, z1, x2, y2, z2, c)
  if not world.stable or not c then return end
  local tried = draw.fast_line and draw.lines_used and draw.frame == frame_no
  if tried and pcall(draw.line_fast, draw.lines, c, x1, y1, z1, x2, y2, z2) then return end
  if not (draw.finite(x1, y1, z1, x2, y2) and draw.finite(z2)) then return end
  draw_world_reset()
  if skip['loader|draw:lines'] then return end
  if draw.lines == nil then
    draw.lines = api('World.create_line_object', world.main) or false
    if draw.lines then hold('loader|draw:lines', true) end
  end
  if not draw.lines then return end
  if not draw.lines_used then api('LineObject.reset', draw.lines); draw.lines_used = true end
  local a, b = api('Vector3', x1, y1, z1), api('Vector3', x2, y2, z2)
  if a and b then
    local _, err = api('LineObject.add_line', draw.lines, c, a, b)
    if not err then
      if tried then draw.fast_line = false elseif draw.fast_line == nil then draw.fast_line = true end
    end
  end
end

-- Bitmaps (icons), all engine functions. The game's UI material
-- content/ui/shared/misc/yellow_logo has one texture slot; every texture gets its own screen GUI whose
-- copy of that material has the texture bound (Gui.material + Material.set_texture), and Gui.bitmap draws it.
-- Textures shipped in a mod's patch are loaded with the game's boot archive. If the material or a
-- texture isn't loaded, or a call is refused, bitmap() returns false and the caller draws something else.
local UI_MATERIAL, UI_SLOT = 'e2d6ed90906c1e8b', '3aa8b87e00000000'
local ui_textures = {}            -- texture -> its copy for the UI world (an addon's chef.ui_textures)
-- The UI material has no mipmaps, so a texture drawn at half its size or less skips texels and its edges come out as
-- stair steps (48 px icons drawn at 25 px look pixely). An addon can ship each
-- texture pre-shrunk to a ladder of sizes (chef.texture_sizes): texture -> { width, id, width, id, ... } from the
-- smallest up, and bitmap() draws the smallest one at least as wide as it's drawn (only ever shrunk a little, never
-- stretched), else the biggest.
local tex_sizes = {}
local function sized(tex, w)
  local l = tex_sizes[tex]
  if not l then return tex end
  local n = #l
  for i = 1, n - 2, 2 do
    if l[i] >= w then return l[i + 1] end
  end
  return l[n]
end
local function id64(hex) return api('IdString64.from_hex', hex) end
local icon_notes = {}
local fast_bitmap = nil
-- The material id is made fresh in every call, like the vectors: an id kept from an earlier call (even one made earlier
-- in the same frame) can have had its slot used again by the other temporaries made since (another mod's markers,
-- say), and then the bitmap draws with whatever id is there now: a white square somewhere else for that frame.
local function bitmap_fast(g, x, y, w, h, c, layer)
  local V3, V2 = S.Vector3, S.Vector2
  return S.Gui.bitmap(g, S.IdString64.from_hex(UI_MATERIAL), V3(x, y, layer), V2(w, h), c)
end
function draw.uv_fast(g, x, y, w, h, c, layer, u0, v0, u1, v1)
  local V3, V2 = S.Vector3, S.Vector2
  return S.Gui.bitmap_uv(g, S.IdString64.from_hex(UI_MATERIAL), V2(u0, v0), V2(u1, v1), V3(x, y, layer), V2(w, h), c)
end
-- u0, v0, u1, v1: only that part of the texture (a sprite sheet), through Gui.bitmap_uv; no size ladder
local function bitmap(tex, x, y, w, h, c, layer, u0, v0, u1, v1)
  if not world.stable or not c or skip['loader|draw:bitmaps'] then return false end
  layer = layer or 900
  if not draw.finite(x, y, w, h, layer) or (u0 and not draw.finite(u0, v0, u1, v1)) then return false end
  draw_world_reset()
  if not u0 then tex = sized(tex, w) end
  if draw.ui and layer < TOP_FROM then
    local t2 = ui_textures[tex]
    if t2 then tex, c = t2, ui_color(c, true) else c = ui_color(c) end
  end
  local icons, target = draw.icons, world.main
  if layer >= TOP_FROM or draw.ui then
    target = top_world()
    if not target then return false end
    icons = top.icons
    if layer >= TOP_FROM then layer = layer - TOP_FROM else layer = min(draw.ui_base + layer - 900, -1) end
  end
  local e = icons[tex]
  if e == nil then
    e = false
    if draw.icon_ok == nil then draw.icon_ok = api('Application.can_get', 'material', id64(UI_MATERIAL)) == true end
    local why = nil
    if not draw.icon_ok then why = 'the UI material is not loaded'
    elseif api('Application.can_get', 'texture', id64(tex)) ~= true then why = 'texture ' .. tex .. ' is not loaded'
    else
      local g = api('World.create_screen_gui', target, 'immediate')
      if g then e = { gui = g, frame = -1 } else why = 'no screen GUI' end
    end
    icons[tex] = e
    if e then hold(icons == top.icons and 'loader|draw:top' or 'loader|draw:bitmaps', true)
    elseif not icon_notes[why] then icon_notes[why] = true; log('icons: ' .. why .. '; the addon draws its own fallback') end
  end
  if not e then return false end
  if e.frame ~= frame_no then
    -- the texture is bound once a frame
    e.frame = frame_no
    local mh = api('Gui.material', e.gui, id64(UI_MATERIAL))
    local _, err = nil, 'no material'
    if mh then _, err = api('Material.set_texture', mh, id64(UI_SLOT), id64(tex)) end
    if err then
      icons[tex] = false
      if not icon_notes[err] then icon_notes[err] = true; log('icons: texture ' .. tex .. ' refused (' .. tostring(err) .. ')') end
      return false
    end
  end
  if u0 then
    -- (a sprite sheet's part: its own proof and fast path, draw.fast_uv, the same rules as Gui.bitmap's below)
    local tried = draw.fast_uv
    if tried and pcall(draw.uv_fast, e.gui, x, y, w, h, c, layer, u0, v0, u1, v1) then return true end
    local p, sz = api('Vector3', x, y, layer), api('Vector2', w, h)
    local a0, a1 = api('Vector2', u0, v0), api('Vector2', u1, v1)
    if not (p and sz and a0 and a1) then return false end
    local _, err = api('Gui.bitmap_uv', e.gui, id64(UI_MATERIAL), a0, a1, p, sz, c)
    if err and not icon_notes['uv'] then icon_notes['uv'] = true; log('sprite sheets: Gui.bitmap_uv refused (' .. tostring(err) .. ')') end
    if not err then
      if tried then draw.fast_uv = false elseif draw.fast_uv == nil then draw.fast_uv = true end
    end
    return not err
  end
  -- like rects: once the breadcrumbed calls proved the id, Vector3, Vector2 and Gui.bitmap, one pcall straight through
  -- (an addon's numbers can be a few hundred bitmaps a frame). A fast call that fails takes the guarded path: when that
  -- one works, the fast path itself is what failed and it goes off; when it fails too, the arguments were bad (a mod's
  -- odd color, say) and the fast path stays on for every other call.
  local tried = fast_bitmap
  if tried and pcall(bitmap_fast, e.gui, x, y, w, h, c, layer) then return true end
  local p, sz = api('Vector3', x, y, layer), api('Vector2', w, h)
  if not (p and sz) then return false end
  local _, err = api('Gui.bitmap', e.gui, id64(UI_MATERIAL), p, sz, c)
  if not err then
    if tried then fast_bitmap = false elseif fast_bitmap == nil then fast_bitmap = true end
  end
  return not err
end

local function draw_flush()
  -- nothing drawn on top for half a second (the map closed): I give the top world's GUIs back, so they don't pile up
  -- over a session and a crash long after isn't put on them
  if top.world and frame_no - top.frame > 30 then
    local ws, alive = draw.worlds(), false
    if type(ws) == 'table' and #ws == top.n and top.wid == world.id then
      for i = 1, #ws do if ws[i] == top.world then alive = true; break end end
    end
    if alive then
      if top.gui then api('World.destroy_gui', top.world, top.gui) end
      if draw.nt.top and draw.nt.top.world == top.world then api('World.destroy_gui', top.world, draw.nt.top.g); draw.nt_forget('top') end
      for _, e in pairs(top.icons) do if e then api('World.destroy_gui', top.world, e.gui) end end
    end
    top_drop(); top.frame = -1
  end
  if draw.lines and draw.lines_used and world.stable and draw.world == world.id then
    api('LineObject.dispatch', world.main, draw.lines)
    draw.lines_shown = true
  elseif draw.lines_shown then
    -- The engine keeps drawing the set I last dispatched until I dispatch another, so on the first frame no line is
    -- drawn after some were (a mod stopped drawing them, or was switched off) I dispatch an empty set, once, and nothing
    -- more until lines come back. Not on a line object of a world that's gone (a new instance: unsettled, or settled
    -- but nothing drew in it yet): its lines went with that world. A world whose contents turned into another (a new
    -- world id, the same instance) keeps its line object, so its lines are emptied too. The set only counts as gone
    -- once the empty one went out: on a frame the world isn't settled but is still the instance its line object was
    -- made in, I wait for the next settled frame of it instead of forgetting the lines.
    if not draw.lines or draw.instance ~= world.instance then
      draw.lines_shown = false
    elseif world.stable then
      draw.lines_shown = false
      api('LineObject.reset', draw.lines)
      api('LineObject.dispatch', world.main, draw.lines)
    end
  end
  draw.lines_used = false
end

-- ------------------------------------------------------------------ addons
local addons, notices = {}, {}
-- the shared services every mod gets (src/chef_loader/services.lua): after_startup, capabilities, saved settings, shared
-- values and events, require, key bindings, the options menu, the look-alikes, dev mode (test builds)
local svc = services.install({ log = log, guarded = guarded, fn_of = fn_of, open = open, DIR = DIR, FILES = FILES, LOADER = LOADER,
  OLD_DIR = services.OLD_DIR ~= DIR and services.OLD_DIR or nil,
  VERSION = VERSION, TEST = TEST, ALLOW = ALLOW, TOP = TOP_FROM, world = world, color = color, rect = rect, text = text, text_width = text_width,
  color_scope = draw.color_scope,                -- (before every mod callback that services and the utilities run)
  bitmap = bitmap, cover = function(l) draw.cover, draw.cover_set = type(l) == 'number' and l - TOP_FROM or nil, true end,
  text_fit = draw.text_fit, text_wrap = draw.text_wrap, text_native = function() return draw.nt_on() end,
  tr = function(s) return draw.tr(s) end, tr_keep = function(s) return draw.tr_keep(s) end,
  lang_v = function() return draw.lang and draw.lang.v end,
  tr_cut = function(reset)                       -- (a text the frame's pattern budget cut: drawn as it is this frame)
    local L = draw.lang
    if not L then return false end
    if reset then L.skipped = false end
    return L.skipped == true
  end,
  screen = function() draw_world_reset(); return draw.w, draw.h end,
  key_pressed = function(name)
    local k = key_index(name)
    return k and guarded('loader', 'Keyboard.pressed', fn_of('Keyboard.pressed'), k) == true or false
  end,
  now = function() return elapsed end, clock = now, LOG_CAP = LOG_CAP, opt_changed = tr.opt_changed,
  frame = function() return frame_no end,          -- (my frame count: what this frame's mouse movement is keyed on)
  addon = function(name) for _, a in ipairs(addons) do if a.name == name then return a end end end,
  dev_reload = function() end })
-- the utilities (src/chef_loader/utilities.lua): safe unit access, spawning with clean-up, timers, session and
-- settings, shapes, sprite sheets, notify, typed text, saved tables, the mod list
svc.util = services.utilities.install(svc.ctx, { api = api, xyz = xyz, rect = rect, bitmap = bitmap, key_index = key_index,
  crumb = crumb,                                   -- (chef.capture breadcrumbs every save through it, not only the first)
  raw = function(on) draw.raw = on == true end, ui = function() return draw.ui end,
  tri = draw.tri, tri_ok = function() return draw.tri_ok end,
  notify = function(n) notices[#notices + 1] = n end,
  notes_of = function(o) local k = 0; for _, n in ipairs(notices) do if n.owner == o then k = k + 1 end end return k end,
  addons = addons, boots = function() return svc.ctx.boots or {} end, frame_no = function() return frame_no end,
  patches = function() return scan.list end,
  unstarted = function() return svc.starter and svc.starter.unstarted end,     -- (starter is made further down)
  found_rows = function()
    local t = {}
    for _, list in ipairs({ found_addons, found_named, found_options }) do
      for _, r in ipairs(list) do t[#t + 1] = r end
    end
    return t
  end,
  clock = clock, os = os_, new_world_hooks = new_world_hooks, bad_kinds = res.bad, settings_text = cfg_text,
  engine_off = services.sandbox.engine_off, calls_off = services.sandbox.CALLS_OFF,
  -- (a grant's flag, chef.capture's: the locked-down space is made after this, so it's looked up when asked)
  granted = function(owner, what)
    local sb = svc.sandbox
    return type(sb) == 'table' and type(sb.granted) == 'function' and sb.granted(owner, what) == true
  end,
  -- (the loader's saved values, where chef.capture keeps each mod's last picture number across launches)
  saved_get = function(k) return svc.loader_get(k) end, saved_put = function(k, v) return svc.loader_put(k, v) end,
  found = function()
    local t = {}
    for _, r in ipairs(found_addons) do t[#t + 1] = r.name end
    for _, r in ipairs(found_named) do t[#t + 1] = r.name end
    return t
  end })
-- my own row in the options menu: the frame budget behind chef.budget
svc.util.budget_row = svc.loader_option('budget', { type = 'slider', label = 'Budget (ms)', min = 0.5, max = 10,
  step = 0.5, default = 1, section = 'monitor' })
-- and the performance monitor (utilities: each mod's cost, drawn once a second's numbers are in)
svc.util.perf_row = svc.loader_option('perf', { type = 'toggle', label = 'Performance monitor', default = false,
  section = 'monitor' })
-- (where the monitor sits: the player keeps it clear of what they want to see; Adjustable is where they last let go
-- of it, dragged on the pause screen or with the options menu's cursor on the ship, kept in my saved values as
-- perf_x / perf_y)
-- (Adjustable is the first choice: a position saved from the six-choice list (1 top right ... 6 bottom left) moves
-- down one place once, and a saved 8 is Adjustable; perf_place_v marks it done. The default, Top right, is 2.)
if svc.loader_get('perf_place_v') ~= 2 then
  local old = tonumber(svc.loader_get('opt.perf_place'))
  if old then svc.loader_put('opt.perf_place', old == 8 and 1 or old + 1) end
  svc.loader_put('perf_place_v', 2)
end
svc.util.perf_place = svc.loader_option('perf_place', { type = 'choice', label = 'Monitor position', default = 2,
  choices = { 'Adjustable', 'Top right', 'Top left', 'Middle right', 'Middle left', 'Bottom right', 'Bottom left',
    'Center' },
  section = 'monitor_look' })
-- (how see-through the whole panel is, text included: 100 is as it always was)
svc.util.perf_alpha = svc.loader_option('perf_alpha', { type = 'slider', label = 'Monitor opacity (%)', min = 10,
  max = 100, step = 10, default = 100, section = 'monitor_look' })
-- (shown only while the game's pause screen is up: nothing over the HUD while playing. Off; in missions (on the ship
-- as always); or always, the ship too. It was an on/off row for missions: a saved on is Missions, a saved off is Off)
do
  local old = svc.loader_get('opt.perf_pause')
  if type(old) == 'boolean' then svc.loader_put('opt.perf_pause', old and 2 or nil) end
  -- (the Game font row is gone, the game's font always used when it can be: what it saved is cleared)
  if svc.loader_get('opt.font') ~= nil then svc.loader_put('opt.font', nil) end
end
svc.util.perf_pause = svc.loader_option('perf_pause', { type = 'choice', label = 'Monitor on pause screen only',
  choices = { 'Off', 'Missions', 'Always' }, default = 1, section = 'monitor_look' })
svc.util.perf_get, svc.util.perf_put, svc.util.menu_mouse = svc.loader_get, svc.loader_put, svc.menu_mouse
svc.util.menu_open = svc.menu_open
-- (the monitor names each mod as my menu does, and hides while my full screen menu covers the screen)
svc.util.mod_title, svc.util.covering = svc.mod_title, svc.covering
-- (the mods under their budget on one line, so the heavy ones stand out; the label names the Budget row's value)
svc.util.perf_hide = svc.loader_option('perf_hide', { type = 'toggle', default = false, section = 'monitor',
  label = function() return fmt('Hide mods under %g ms', svc.util.budget_row and svc.util.budget_row.value or 1) end })
-- the HD2Runtime look-alike (src/chef_loader/runtime.lua): its callbacks run through the mod's own hooks (a.rt)
svc.runtime = services.runtime.install({ log = log, guarded = guarded, fn_of = fn_of, G = G, DIR = DIR,
  VERSION = VERSION, util = svc.util, frame = function() return frame_no end, now = function() return elapsed end,
  instance = function() return world.instance end,
  trusted = function(owner) return TRUSTED[owner] end,
  -- (a mod's spec.needs and handle.request: what it lacks goes on the mod list)
  notify = function(n) notices[#notices + 1] = n end,
  missing = function(owner, list) local a = svc.ctx.addon(owner); if a then a.missing = list end end,
  mod_log = function(owner, text) log('[' .. owner .. '] ' .. text) end,
  -- (a mod's own name, HD2Runtime.mod{ name = ... }: its entry in my options menu goes by it, svc.mod_named)
  named = svc.mod_named,
  attach = function(owner, hooks) local a = svc.ctx.addon(owner); if a then a.rt = hooks end end })
new_world_hooks[#new_world_hooks + 1] = function() svc.runtime.new_world() end
-- language files (src/chef_loader/lang.lua): read once discovery has found them, at start-up
svc.lang = services.lang.install({ log = log, open = open, DIR = DIR, FILES = FILES, clock = clock,
  frame = function() return frame_no end, crumb = crumb, skipped = function(k) return skip[k] == true end, fp = function(s) return fingerprint(s) end,
  skip_now = function(k) skip[k] = true; save_state() end })
-- the options menu's texts through the language, from where the last frame's pattern budget stopped (the list made
-- once per rows-and-language version; draw.tr_list false once every text was looked up)
function draw.tr_pass()
  local list = draw.tr_list or svc.option_texts()
  draw.tr_list = list
  local i = draw.tr_at
  while list[i] do
    svc.lang.skipped = false
    draw.tr(list[i])
    if svc.lang.skipped then break end
    i = i + 1
  end
  draw.tr_at = i
  if not list[i] then draw.tr_list = false end
end
local function options_for(name)
  local o = {}
  for _, r in ipairs(found_options) do
    if r.name == name then
      local chunk = loadstring(r.src, '@' .. r.name .. ' (options in ' .. r.file .. ')')
      local ok, t = false, nil
      -- an options file is just a table: it runs with nothing to reach (breadcrumbed like a hook: one that ends the
      -- game is skipped from the next launch on, until its mod's own file changes; the mod still starts, with nothing
      -- from it in chef.options, and its crash count starts over after a launch it doesn't end)
      local k = name .. '|options'
      if chunk and not skip[k] then
        setfenv(chunk, {})
        crumb('> ' .. k)
        ok, t = pcall(chunk)
        crumb('< ' .. k)
      end
      if ok and type(t) == 'table' then
        for k, v in pairs(t) do
          if type(v) == 'table' and type(o[k]) == 'table' then for k2, v2 in pairs(v) do o[k][k2] = v2 end
          else o[k] = v end
        end
      else
        log('options for ' .. name .. ' in ' .. r.file .. ' could not be read')
      end
    end
  end
  return o
end

local function make_api(a)
  local owner = a.name                   -- crash keys carry the full addon name, e.g. mods/me/my_mod|Unit.alive
  -- api: the documented helper set's level (docs/MODDING.md); it only goes up when something is added
  local chef = { loader = LOADER, loader_version = VERSION, api = 1, name = a.name }
  chef.options = a.options
  function chef.log(...) local ok, s = pcall(fmt, ...); log('[' .. owner .. '] ' .. (ok and s or tr.why((...)))) end
  function chef.call(name, ...) return guarded(owner, name, fn_of(name), ...) end
  local kind_keys = {}                   -- name -> kind -> "name:kind", built once
  local marked = {}                      -- "name:kind" -> true once its first call was looked at (unit only or not)
  local shared = tr.shared               -- (one look-up a call)
  function chef.call_kind(name, kind, ...)
    local t = kind_keys[name]
    if not t then t = {}; kind_keys[name] = t end
    local key = t[kind]
    if not key then key = name .. ':' .. kind; t[kind] = key end
    -- (refused for every mod: it ended the game for one asking the same of that kind, with only the unit; a call with
    -- more arguments isn't the call that was learned)
    if shared.n > 0 and select('#', ...) == 1 then
      local sk = shared.of[key]
      if sk == nil then sk = shared.key_of(name, kind) or false; shared.of[key] = sk end
      if sk and skip[sk] then
        local said = shared.said[owner]
        if not said then said = {}; shared.said[owner] = said end
        if not said[sk] then
          said[sk] = true
          log(fmt('[%s] %s skipped: it ended the game for a mod in an earlier launch', owner, sk:sub(8)))
        end
        return nil, 'skipped'
      end
    end
    -- (its first call, when it took only the unit, is marked so in the trace: a crash in that is the engine's answer for
    -- that kind, and the next launch shares it with every mod)
    if not marked[key] then
      marked[key] = true
      local k = key_of(owner, key)
      if select('#', ...) == 1 and not proven[k] then crumb('= ' .. k) end
    end
    return guarded(owner, key, fn_of(name), ...)
  end
  function chef.time() return elapsed end
  function chef.world() if world.stable then return world.main end end
  function chef.world_id() return world.stable and world.id or 0 end
  function chef.in_mission() return world.stable and world.mission and not world.checking end
  -- unit kinds (resource id hex -> true) that only exist in missions: the loader's loot probe looks for them to tell
  -- a small mission from the ship
  function chef.mission_kinds(kinds)
    local any = false
    for k in pairs(kinds) do
      if type(k) == 'string' and k:match('^%x+$') then mission_kinds[k:lower()] = true; any = true end
    end
    if any then kinds_from[#kinds_from + 1] = a end
    if world.stable and not world.mission and not world.probe_at and world.units >= PROBE_MIN and can_probe() then
      world.probe_at = elapsed
    end
  end
  chef.camera = camera
  -- a world point on screen through my view camera: x, y in screen pixels (bottom-left origin, like the
  -- GUIs), or nil when it's behind me or there's no camera. The engine's answer is 2D, so "behind" is my own check.
  local w2s_fast = false
  function chef.world_to_screen(x, y, z)
    local d = camera()
    if not d or not cam.c then return nil end
    local ax, ay, az = x - d.x, y - d.y, z - d.z
    if ax * d.fx + ay * d.fy + az * d.fz <= 0.5 then return nil end
    if w2s_fast then
      local ok, sx, sy = pcall(cam.project, cam.c, x, y, z)
      if ok and type(sx) == 'number' then return sx, sy end
      w2s_fast = false                   -- the guarded path below again (it turns this back on once it works)
    end
    local v = api('Vector3', x, y, z)
    if not v then return nil end
    local r = guarded(owner, 'Camera.world_to_screen', fn_of('Camera.world_to_screen'), cam.c, v)
    if r == nil then return nil end
    local sx, sy = xyz(r)
    if not sx then return nil end
    -- all three calls made it through guarded() (breadcrumbed the first time)
    cam.fns = { fn_of('Vector3.to_elements'), fn_of('Camera.world_to_screen'), fn_of('Vector3') }
    w2s_fast = true
    return sx, sy
  end
  function chef.watch(kinds, every)
    if type(kinds) ~= 'table' then return nil end
    -- PERF: at most a list every 0.5 s (every = 0, or w.refresh() each frame, would keep the full scan running all the
    -- time: 1,500 units a frame and two trace writes a scan, every frame in a small world)
    local w = { owner = owner, a = a, kinds = kinds, every = max(0.5, tonumber(every) or 5), next = 0, items = {}, generation = 0,
                active = true, want_now = true, owner_on = function() return a.on end, scan_ms = 0 }
    watchers[#watchers + 1] = w
    watchers.next_at = 0
    function w.pause() w.active = false end
    function w.resume() if not w.active then w.active, w.want_now, watchers.next_at = true, true, 0 end end
    function w.refresh() w.next, watchers.next_at = min(w.next, max(elapsed, w.next - w.every + 0.5)), 0 end
    -- for good: it leaves the scan's list
    function w.stop()
      w.active, w.items = false, {}
      for i = #watchers, 1, -1 do if watchers[i] == w then table.remove(watchers, i) end end
    end
    return w
  end
  -- While my options menu is open its keys and mouse buttons are its own: key_down, key_pressed and mouse_down answer
  -- false and wheel 0 (the menu scrolls with it), as the mod's own Keyboard and Mouse reads do (sandbox.lua), so a
  -- search typed there never fires a mod's hotkey. key_known and the cursor answer as always.
  function chef.key_down(name)
    if svc.menu_open() then return false end
    local k = key_index(name)
    if not k then return false end
    local v = guarded(owner, 'Keyboard.button', fn_of('Keyboard.button'), k)
    return type(v) == 'number' and v > 0.5
  end
  -- is this a key name the game knows? (Keyboard.button_index gives nothing for an unknown name)
  function chef.key_known(name) return key_index(name) and true or false end
  function chef.key_pressed(name)
    if svc.menu_open() then return false end
    local k = key_index(name)
    return k and guarded(owner, 'Keyboard.pressed', fn_of('Keyboard.pressed'), k) == true or false
  end
  function chef.screen() draw_world_reset(); return draw.w, draw.h end
  function chef.ui_textures(map)
    if type(map) == 'table' then for k, v in pairs(map) do if type(k) == 'string' and type(v) == 'string' then ui_textures[k] = v end end end
  end
  function chef.texture_sizes(map)
    if type(map) ~= 'table' then return end
    for k, l in pairs(map) do
      local ok = type(k) == 'string' and type(l) == 'table' and #l >= 2 and #l % 2 == 0
      if ok then
        for i = 1, #l, 2 do
          if type(l[i]) ~= 'number' or type(l[i + 1]) ~= 'string' or (i > 1 and l[i] <= l[i - 2]) then ok = false; break end
        end
      end
      if ok then tex_sizes[k] = l end
    end
  end
  -- A mouse axis's or button's index, asked of the engine once. No answer (the mouse isn't ready yet in the first
  -- frames on some setups, or a name it doesn't know) is asked again, as key_index does: after 2 s, the wait doubling
  -- up to 32 s. mouse_ix[call][name]: the index, or false until mouse_at[call][name]; mouse_wait: the wait after the
  -- next miss.
  local mouse_ix = { ['Mouse.axis_index'] = {}, ['Mouse.button_index'] = {} }
  local mouse_at = { ['Mouse.axis_index'] = {}, ['Mouse.button_index'] = {} }
  local mouse_wait = { ['Mouse.axis_index'] = {}, ['Mouse.button_index'] = {} }
  local function mouse_index(call, name)
    if name == nil then return false end
    local t = mouse_ix[call]
    local k = t[name]
    if k == nil or (k == false and elapsed >= mouse_at[call][name]) then
      k = guarded(owner, call, fn_of(call), name) or false
      t[name] = k
      if not k then
        local wait = mouse_wait[call][name] or 2
        mouse_at[call][name], mouse_wait[call][name] = elapsed + wait, min(wait * 2, 32)
      end
    end
    return k
  end
  -- the mouse wheel this frame (0 when it didn't move); the game's map zooms with it
  function chef.wheel()
    if svc.menu_open() then return 0 end
    local wheel_ix = mouse_index('Mouse.axis_index', 'wheel')
    if not wheel_ix then return 0 end
    local v = guarded(owner, 'Mouse.axis', fn_of('Mouse.axis'), wheel_ix)
    if v == nil then return 0 end
    local _, y = guarded(owner, 'Vector3.to_elements', fn_of('Vector3.to_elements'), v)
    return type(y) == 'number' and y or 0
  end
  -- the mouse cursor (window pixels, as the engine gives them) and a mouse button held ('left', 'right', ...)
  function chef.cursor()
    local cursor_ix = mouse_index('Mouse.axis_index', 'cursor')
    if not cursor_ix then return nil end
    local v = guarded(owner, 'Mouse.axis', fn_of('Mouse.axis'), cursor_ix)
    if v == nil then return nil end
    local x, y = guarded(owner, 'Vector3.to_elements', fn_of('Vector3.to_elements'), v)
    if type(x) == 'number' and type(y) == 'number' then return x, y end
  end
  function chef.mouse_down(name)
    if svc.menu_open() then return false end
    local k = mouse_index('Mouse.button_index', name)
    if not k then return false end
    local v = guarded(owner, 'Mouse.button', fn_of('Mouse.button'), k)
    return type(v) == 'number' and v > 0.5
  end
  chef.TOP = TOP_FROM
  chef.color, chef.text_width = color, text_width
  -- the language picked in my menu (its name and code, nil for English), and a text as it has it
  function chef.lang() return svc.lang.active() end
  function chef.tr(s) return draw.tr(s) end
  function chef.rect(x, y, w, h, c, layer) rect(x, y, w, h, c, layer) end
  function chef.text(x, y, s, px, c, layer) return text(x, y, s, px, c, layer) end
  function chef.text_fit(s, px, maxw) return draw.text_fit(s, px, maxw) end
  function chef.text_wrap(s, px, maxw, most) return draw.text_wrap(s, px, maxw, most) end
  function chef.sprite(x, y, rows, cell, colors, layer) sprite(x, y, rows, cell, colors, layer) end
  function chef.bitmap(tex, x, y, w, h, c, layer) return bitmap(tex, x, y, w, h, c, layer) end
  function chef.line(x1, y1, z1, x2, y2, z2, c) line(x1, y1, z1, x2, y2, z2, c) end
  svc.extend(chef, a)
  svc.util.extend(chef, a)
  return chef
end

-- the start-up steps for one mod and switching one off (a table: the loader is near Lua 5.1's 200 locals)
local starter = {}
svc.starter = starter
-- A mod that stops (switched off after errors, or a start that failed half-way): it's off for the session, its watches
-- and loot kinds go, and the services forget it (no more events or change callbacks to it; its timers, jobs and what it
-- spawned go too).
function starter.off(a)
  if not a.forgotten then starter.undo(a) end
  a.on = false
  a.game_env = nil                                   -- (its environment isn't kept for the session)
  if a.forgotten then return end
  a.forgotten = true
  for i = #watchers, 1, -1 do if watchers[i].a == a then table.remove(watchers, i) end end
  for i = #kinds_from, 1, -1 do if kinds_from[i] == a then table.remove(kinds_from, i) end end
  local ok, err = pcall(svc.forget, a.name)
  if not ok then log('forgetting ' .. a.name .. ' failed: ' .. tr.why(err)) end
end

-- A mod I stop gets one call first to put back what only it knows: its module's on_stop() and, for an HD2Runtime mod,
-- its handle.on('stop') callbacks (both when it has both). The engine can't tell me what texture a material had
-- before a mod's set_texture, so I can't undo those myself. Each is breadcrumbed ("<mod>|on_stop", "<mod>|stop"; one
-- that ended the game is skipped from then on); the mod's engine calls still work here, since nothing of it is
-- forgotten yet.
function starter.undo(a)
  local list = {}
  if type(a.module) == 'table' then
    local fn = rawget(a.module, 'on_stop')
    if fn == nil and a.hooks_mt then
      local ok, v = pcall(starter.get, a.module, 'on_stop')
      if ok then fn = v end
    end
    if type(fn) == 'function' then list[#list + 1] = { 'on_stop', fn } end
  end
  if type(a.rt) == 'table' and type(a.rt.stop) == 'function' then list[#list + 1] = { 'stop', a.rt.stop } end
  for _, e in ipairs(list) do
    local k = a.name .. '|' .. e[1]
    if skip[k] then log('skipped ' .. k .. ' (it crashed the game)')
    else
      crumb('> ' .. k)
      local D = starter.dog                          -- (watched like its other calls: a fresh dog.limit)
      local po, ps, pl, pn = D.enter(a, clock())
      local ok, err = pcall(e[2])
      D.leave(po, ps, pl, pn)
      crumb('< ' .. k)
      if ok then log(e[1] .. ': ' .. a.name .. ' put back what it changed')
      else
        if svc.util then svc.util.note_error(a, err) end
        log('[' .. a.short .. '] ' .. e[1] .. ' error: ' .. tr.why(err))
      end
    end
  end
end

-- A mod's time is summed here (its hooks; its timers and spread jobs in the utilities) and divided by the loader's own
-- frame count in the status line.
-- A mod's update/render/shutdown are looked up in its module at every call (rawget: it can't raise, and a mod may set
-- replace or remove one after it started); a.hooks, read once at start, only serves a module with a metatable (its
-- hooks may come through __index). The first call of each is breadcrumbed like an engine call ("<mod>|update"): a mod whose own code ends
-- the game is blamed and stays off from the next launch on. a.ran: hook -> its crash key once called, false when it's
-- skipped. a.rt: an HD2Runtime mod's callbacks (its handle.on), called when its module has no hook of that name.
-- The hang watchdog. A mod's call (its start, hooks, timers, spread jobs, event listeners, look-alike hooks, its
-- on_stop, a label function of its rows) that runs on past dog.limit seconds (an endless loop, say) is stopped with an
-- error where it is, and at the next update I switch the mod off for the session, as for too many errors, so a stuck
-- mod costs the game a few seconds, not the session. A count hook (every million instructions: nothing next to a
-- frame's cost) asks my clock, and only does anything while a mod's call runs. Each place that calls a mod names it and
-- when its call began (enter), and puts back the one before when it returns (leave), so a mod's call that runs
-- another's (an event) blames the one running.
-- - The error is only raised in the mod's own code, never in mine (a helper of mine it called, my code between its
--   calls): me is my file's chunk name, which no mod's code has (sandbox.lua's loadstring and load refuse to compile
--   anything under it).
-- - The first count past the limit only marks the call: a long engine call (a package load, a big spawn) can take the
--   time without a loop. The error comes on a later count of the same call, after a million more of the mod's own
--   instructions ran past the limit (a few ms).
-- - From the error until the call ends the hook runs every instruction, so a loop around the mod's own pcall gets the
--   error again at once; a mod that hung gets no fresh time on any other call before I switch it off.
-- - Armed, the hook stays set for the whole session while any mod is on, not only during a mod's call: my own code
--   between the mods' calls runs under it too, the VM counting its count down on every instruction. That costs under one
--   percent of the Lua's time on that thread (0.84%; a few microseconds a frame), about what setting and clearing it
--   around each of the dozens of mod calls a frame would cost, so I keep the simpler one. The game's own boot callbacks
--   are empty: the Lua on these threads is mine and the mods'. With no mod on, it's off. Coroutines a mod makes get it
--   too (its coroutine.create / wrap, in starter.env_for). A debug hook someone else set is left alone: then there's no
--   watchdog this session. The one exception is the hook of a loader that handed off to me (dog.take / dog.give).
-- - It can't stop a stuck engine call: no Lua runs while one does. A start gets dog.start seconds.
starter.dog = { limit = 3, start = 10, lim = 3, owner = false, since = 0, n = 0, hung = {}, armed = false, at = 0, clock = clock,
                sethook = type(debug) == 'table' and debug.sethook or nil,
                gethook = type(debug) == 'table' and debug.gethook or nil,
                getinfo = type(debug) == 'table' and debug.getinfo or nil }
starter.dog.me = starter.dog.getinfo and starter.dog.getinfo(1, 'S').source
if not starter.dog.me then starter.dog.sethook = nil end      -- (no way to tell my code from a mod's: no watchdog)
svc.ctx.dog = starter.dog                        -- (the utilities' timers, jobs and callbacks enter and leave it too)
-- (dog.armed is the watchdog's real state for the services: true while it watches the mods' calls, false with no
-- debug hooks, another script's hook set or no mod on; chef.has('hang_watchdog') reads it there)
-- (the hook set again on the running thread, only when it's still mine: never over a hook another script set)
function starter.dog.reset(count)
  local D = starter.dog
  if D.gethook() == D.hook then D.sethook(D.hook, '', count) end
end
function starter.dog.hook()
  local D = starter.dog
  local a = D.owner
  if not (a and clock() - D.since > D.lim) then
    -- (a thread left counting every instruction after its call ended: back to every million)
    local _, _, c = D.gethook()
    if c == 1 then D.sethook(D.hook, '', 1000000) end
    return
  end
  local info = D.getinfo(2, 'S')
  if not info or info.source == D.me then return end
  if not D.hung[a] then
    if D.over ~= D.since then D.over = D.since; return end
    D.hung[a] = D.lim; D.hung[#D.hung + 1] = a
  end
  D.n = D.n + 1
  if not D.fast then D.fast = true; D.reset(1) end
  error(fmt('stopped by the hang watchdog: it ran over %d s (an endless loop?)', D.lim), 0)
end
-- (not armed: nothing to note. A mod that hung already gets no time: its next count past my check raises.)
function starter.dog.enter(a, t0, lim)
  local D = starter.dog
  if not D.armed then return end
  local po, ps, pl, pn = D.owner, D.since, D.lim, D.n
  D.owner, D.since, D.lim = a, D.hung[a] and -1e9 or t0, lim or D.limit
  return po, ps, pl, pn
end
-- (a hang during the call: the caller's own count starts again now, so it isn't blamed for the time that hang took,
-- unless the caller is the one that hung; the hook stays on every instruction while that caller runs)
function starter.dog.leave(po, ps, pl, pn)
  local D = starter.dog
  if pn == nil then return end
  D.owner, D.lim = po, pl
  D.since = (D.n ~= pn and not (po and D.hung[po])) and clock() or ps
  if D.fast and not (po and D.hung[po]) then D.fast = false; D.reset(1000000) end
end
-- On at start-up when there are mods to start (force), then looked at once a second (each thread that runs mods):
-- off while no mod is on, on again when one is; another hook set (a profiler) is left alone for the session.
-- (the boot scripts through svc.ctx.boots: my boots local is declared further down, so a bare boots here is the global)
function starter.dog.running()
  for _, a in ipairs(addons) do if a.on then return true end end
  for _, b in ipairs(svc.ctx.boots or {}) do if b.on then return true end end
  return false
end
function starter.dog.arm(force)
  local D = starter.dog
  if not (D.sethook and D.gethook) or D.off then return end
  local h = D.gethook()
  local want = force or starter.dog.running()
  if h == D.hook then
    if not want then D.sethook(); D.armed = false end
    return
  end
  if h ~= nil then
    D.off, D.armed = true, false
    log('hang watchdog: off (another debug hook is set)')
    return
  end
  if not want then D.armed = false; return end
  D.sethook(D.hook, '', 1000000)
  D.armed = true
  if not D.said then D.said = true; log(fmt('hang watchdog: on (a mod\'s call over %d s, or its start over %d s, is stopped and the mod switched off)', D.limit, D.start)) end
end
-- Started by another loader that handed off to me, I run as its guest: it sets its own debug hook around each of its
-- calls into me (its own watchdog) and puts back what it found once I return. That hook isn't one to leave alone for
-- the session as a profiler's: for my start-up and each of my game callbacks mine goes in its place (or none, while
-- mine is off), and its goes back as it was when I return.
function starter.dog.take()
  local D = starter.dog
  if not (starter.handoff and D.sethook and D.gethook) or D.off or D.hf then return end
  local h, m, c = D.gethook()
  if h == nil or h == D.hook then return end
  D.hf, D.hm, D.hc = h, m, c
  if D.armed then D.sethook(D.hook, '', D.fast and 1 or 1000000) else D.sethook() end
end
function starter.dog.give()
  local D = starter.dog
  if not D.hf then return end
  D.sethook(D.hf, D.hm or '', D.hc or 0)
  D.hf, D.hm, D.hc = nil, nil, nil
end
-- render's thread: armed there too, once a second, only when the game renders on another thread than it updates on
function starter.dog.render()
  local D = starter.dog
  if D.rthread == nil and D.useen then D.rthread = coroutine.running() ~= D.uthread end
  if D.rthread and clock() >= (D.rat or 0) then D.rat = clock() + 1; D.arm() end
end
-- at the start of each update: a watchdog left half set (an error between an enter and its leave) put right, the
-- mods that hung since the last one switched off, and once a second whether it should be on
function starter.dog.frame()
  local D = starter.dog
  if D.owner or D.fast then
    if not D.said_left then D.said_left = true; log('hang watchdog: it was left set after a call; put right') end
    D.owner, D.lim, D.fast = false, D.limit, false
    if D.armed then D.reset(1000000) end
  end
  if clock() >= D.at then D.at = clock() + 1; D.uthread, D.useen = coroutine.running(), true; D.arm() end
  if not D.hung[1] then return end
  local list = D.hung
  D.hung = {}
  for _, a in ipairs(list) do
    if a.on ~= false then
      local why = fmt('it hung (a call ran over %d s)', list[a])
      local name = a.name or a.owner or '?'
      if a.requires then                         -- an addon
        starter.off(a)
        starter.state(a, 'stopped', why)
      else                                       -- a boot script's callbacks, or a boot-style mod (then a.a is itself)
        a.on = false
        a.state, a.why, svc.ctx.health_dirty = 'stopped', why, true
        if a.a then starter.off(a.a) end
        starter.stopped(name, why)
      end
      log(fmt('switched off %s for this session: %s', name, why))
      -- (on screen a mod is named as my menu names it, another mod's boot script by the patch file it's in, as CRASH
      -- RECOVERY names them)
      local shown = starter.retry_what(name):upper()
      notices[#notices + 1] = { text = shown .. ' STOPPED: IT HUNG (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
    end
  end
end
local function run_hook(a, hook, ...)
  local ran = a.on and a.ran
  if not ran then return end
  local fn = rawget(a.module, hook)
  if fn == nil and a.hooks_mt then fn = a.hooks[hook] end
  if fn == nil and a.rt then fn = a.rt[hook] end
  -- (only a mod whose module has no hooks: a global helper named update never becomes one)
  if fn == nil and a.game_env then                   -- the game callback it put in place of the one it was given
    local g = rawget(a.game_env, hook)
    if g ~= starter.game_hooks[hook] then fn = g end
  end
  if type(fn) ~= 'function' then return end
  local k = ran[hook]
  if k == false then return end
  local first = not k
  if first then
    k = a.name .. '|' .. hook
    if skip[k] then ran[hook] = false; log('skipped ' .. k .. ' (it crashed the game)'); return end
    ran[hook] = k
    crumb('> ' .. k)
  end
  draw.color_scope()                     -- (no Color an earlier mod asked for: its slot may be another's by now)
  local t0 = clock()
  local D = starter.dog
  local po, ps, pl, pn = D.enter(a, t0)
  local ok, err = pcall(fn, ...)
  D.leave(po, ps, pl, pn)
  local ms = (clock() - t0) * 1000
  if first then crumb('< ' .. k) end
  a.ms = a.ms + ms
  if ms > a.max_ms then a.max_ms = ms end
  a.pm_ms = (a.pm_ms or 0) + ms
  if ms > (a.pm_max or 0) then a.pm_max = ms end
  if not ok then
    a.errors = a.errors + 1
    -- (its status line in my options menu shows the last one)
    if svc.util then svc.util.note_error(a, err) end
    if a.errors <= 3 then log('[' .. a.short .. '] ' .. hook .. ' error: ' .. tr.why(err)) end
    if a.errors >= MAX_ERRORS then
      starter.off(a)
      starter.state(a, 'stopped', 'after ' .. a.errors .. ' errors')
      log('switched off ' .. a.name .. ' for this session after ' .. a.errors .. ' errors')
      notices[#notices + 1] = { text = svc.mod_title(a.name):upper() .. ' STOPPED AFTER ERRORS', dur = 20 }
    end
  end
end
-- A mod's module read once, each field on its own pcall (a "strict" module raises on a field it doesn't have, and one
-- missing hook mustn't lose the others): its hooks and its version (a.version, text or nil).
function starter.get(t, k) return t[k] end
-- A mod's start measured (its compile and its file's first run): the time on my clock in ms, and how the Lua heap
-- changed in KB (collectgarbage('count'); the heap is the game's too, so a collection in between makes it smaller,
-- even below 0). Only at start: nothing a frame. For the started line, chef.mods() and the health file.
function starter.heap_kb()
  local ok, k = pcall(collectgarbage, 'count')
  return ok and type(k) == 'number' and k or nil
end
function starter.took(a, t0, k0)
  a.start_ms = (clock() - t0) * 1000
  local k1 = k0 and starter.heap_kb()
  a.start_kb = k1 and k1 - k0 or nil
  return a.start_kb and fmt('%.1f ms, %+.0f KB', a.start_ms, a.start_kb) or fmt('%.1f ms', a.start_ms)
end
function starter.read_module(a, m)
  local h = {}
  for _, k in ipairs({ 'update', 'render', 'shutdown' }) do
    local ok, v = pcall(starter.get, m, k)
    if ok and type(v) == 'function' then h[k] = v end
  end
  local ok, v = pcall(starter.get, m, 'version')
  a.version = ok and (type(v) == 'string' or type(v) == 'number') and tostring(v) or nil
  a.hooks, a.ran, a.module, a.hooks_mt = h, {}, m, getmetatable(m) ~= nil
end
-- The game's callbacks as an addon finds them in its globals (empty: mine run the game's own); one it replaced is its hook
starter.game_hooks = { update = function() end, render = function() end, shutdown = function() end }
-- A returned table of data only (no functions): what the old loaders' mods return ({ installed = true }), not a
-- library's API, whose global helper named update must never become a hook
function starter.data_only(m)
  for _, v in pairs(m) do if type(v) == 'function' then return false end end
  return true
end
function starter.set_game_hooks(a)
  if not a.game_env then return false end
  for k, f in pairs(starter.game_hooks) do
    local g = rawget(a.game_env, k)
    if g ~= f and type(g) == 'function' then return true end
  end
  return false
end
-- What a mod is doing and why, for chef.mods() and chef_loader_health.txt (written at most every 5 s after a change).
function starter.state(a, state, why)
  local was = a.state
  a.state, a.why = state, why
  if state == 'running' then starter.publish(a.name) end
  svc.ctx.health_dirty = true
  if was == 'running' and state ~= 'running' then starter.stopped(a.name, why or state) end
end
-- The 'mod_stopped' event (its name, why) once a running mod stops (errors, a hang, switched off ...), so a mod that
-- took its exports with chef.require can let them go. Its own listeners are gone by then (starter.off forgot them).
function starter.stopped(name, why)
  local ok, err = pcall(svc.emit, 'mod_stopped', name, why)
  if not ok then log('the mod_stopped event failed: ' .. tr.why(err)) end
end
-- A boot-style mod or another mod's boot script that never started (it never reaches the boots list): listed too
starter.unstarted = {}
function starter.never(name, file, state, why, kind)
  for i = #starter.unstarted, 1, -1 do                       -- (the same one again, after a reload: the latest why)
    if starter.unstarted[i].name == name then table.remove(starter.unstarted, i) end
  end
  starter.unstarted[#starter.unstarted + 1] = { name = name, kind = kind or 'boot', file = file, state = state, why = why, errors = 0 }
  svc.ctx.health_dirty = true
end
-- The four game callbacks as stand-ins, put in a boot script's or an HD2-Boot mod's environment before its code runs.
-- One that wraps them ("local old = update ... old(dt)") gets a stand-in instead of mine through the game's globals:
-- mine runs every mod and boot script again, so it re-entered itself each frame until the stack ran out. The
-- stand-ins it didn't replace are taken out again once it ran, so they never count as its own. (Addons get
-- starter.game_hooks the same way.)
starter.SEEDS = { init = function() end, update = function() end, render = function() end, shutdown = function() end }
function starter.seed(env) for k, fn in pairs(starter.SEEDS) do rawset(env, k, fn) end end
function starter.unseed(env) for k, fn in pairs(starter.SEEDS) do if rawget(env, k) == fn then rawset(env, k, nil) end end end
-- The game's four callbacks (mine) before a boot script runs, and after it: one it replaced in the game's own globals
-- (code it loads with require gets those, not its environment) is put back, and becomes that script's own unless it
-- has one of its own already.
function starter.callbacks()
  local t = {}
  for k in pairs(starter.SEEDS) do t[k] = rawget(G, k) end
  return t
end
function starter.restore(mine, env, file, failed)
  for k in pairs(starter.SEEDS) do
    local fn, now = mine[k], rawget(G, k)
    if fn ~= nil then rawset(G, k, fn) end
    if type(now) == 'function' and now ~= starter.SEEDS[k] and now ~= fn then
      local own = rawget(env, k)
      if failed then
        log(fmt('%s replaced the game\'s %s (through code it loaded) before it failed: I put mine back', file, k))
      elseif own == nil or own == starter.SEEDS[k] then
        rawset(env, k, now)
        log(fmt('%s replaced the game\'s %s (through code it loaded); I put mine back and run its %s as its own', file, k, k))
      else
        log(fmt('%s replaced the game\'s %s (through code it loaded) and has a %s of its own: I put mine back and run its own',
          file, k, k))
      end
    end
  end
end
-- run(): a boot script's load. Whatever happens in run, the game's four callbacks are mine again afterwards (code it
-- loads with require gets the game's globals and may replace them). Code that keeps one it found then (a library that
-- wraps update later) keeps mine, which is harmless: mine never run inside themselves (update, render, init).
function starter.seeded(env, file, run)
  local mine = starter.callbacks()
  local ok, r1, r2 = pcall(run)
  starter.restore(mine, env, file, not ok or (r1 == nil and r2 ~= nil))
  if not ok then error(r1, 0) end
  return r1, r2
end
-- A mod's locked-down space (src/chef_loader/sandbox.lua), with the look-alikes (CowboyBingusModLoader,
-- ModOptionsMenu, HD2Runtime) as its own copies, not the shared ones
-- coroutine.wrap's results: what the coroutine returned, or its error raised again (as the real wrap does)
function starter.co_pass(ok, ...)
  if ok then return ... end
  error((...), 0)
end
function starter.env_for(name)
  local env = svc.sandbox.env(name)
  -- (the hang watchdog reaches the mod's own coroutines: each one it makes gets my hook, while it's armed; the mod
  -- resuming it is the one blamed)
  local co, D = rawget(env, 'coroutine'), starter.dog
  if type(co) == 'table' and D.sethook and type(co.create) == 'function' and type(co.resume) == 'function' then
    local create, resume = co.create, co.resume
    local function hooked(f)
      local c = create(f)
      if D.armed then pcall(D.sethook, c, D.hook, '', 1000000) end
      return c
    end
    rawset(co, 'create', hooked)
    rawset(co, 'wrap', function(f)
      local c = hooked(f)
      return function(...) return starter.co_pass(resume(c, ...)) end
    end)
  end
  local bind = services.bind_lookalikes or svc.bind_lookalikes
  if type(bind) == 'function' then
    local ok, err = pcall(bind, env, name)
    if not ok then log('the look-alikes for ' .. name .. ' failed: ' .. tr.why(err)) end
  end
  if svc.runtime then
    local ok, err = pcall(svc.runtime.bind, env, name)
    if not ok then log('the HD2 Lua Runtime look-alike for ' .. name .. ' failed: ' .. tr.why(err)) end
  end
  return env
end

-- "-- HD2-Requires:" lines (services.requirements): Chef Shared Loader's own version, and other mods, which start first
-- (services.order) so their version can be checked here
function starter.requires_ok(r)
  if r.cycle then return false, 'its requirements go round in a circle' end
  for _, q in ipairs(services.requirements(r.src)) do
    if q.name == 'chef-shared-loader' or q.name == 'chef-loader' then
      if q.version and not services.version_at_least(VERSION, q.version) then
        return false, fmt('needs Chef Shared Loader %s or newer (this is %s)', q.version, VERSION)
      end
    else
      local d = svc.ctx.addon(q.name)
      if not (d and d.on and type(d.module) == 'table') then
        local by = starter.elsewhere_safe({ name = q.name })
        if by then return false, 'needs ' .. q.name .. ', which ' .. by .. ' started (its module is that loader\'s, not mine)' end
        return false, 'needs ' .. q.name .. ' (not installed or not running)'
      end
      if q.version and d.version == nil then
        return false, fmt('needs %s %s or newer (the one installed has no version)', q.name, q.version)
      elseif q.version and not services.version_at_least(d.version, q.version) then
        return false, fmt('needs %s %s or newer (%s is installed)', q.name, q.version, tostring(d.version))
      end
    end
  end
  return true
end
-- A mod that changed since it was turned off goes back on, and the calls of its that crashed the game are tried again
-- (an update may well have fixed them). A language file's skip stays: its key carries that file's own fingerprint.
function starter.back_on(name)
  off[name] = nil
  local n = starter.retry(name)
  log('turned back on: ' .. name .. ' (the mod changed since it was turned off)' ..
    (n > 0 and fmt('; its %d skipped call(s) are tried again', n) or ''))
end
-- a mod's own skipped calls dropped (it changed: an update may well have fixed them), its crash count with them, and
-- the state saved. -> how many calls
function starter.retry(name)
  local p, ks = name .. '|', {}
  for k in pairs(skip) do if k:sub(1, #p) == p and not k:match('|lang:%x+$') then ks[#ks + 1] = k end end
  for _, k in ipairs(ks) do skip[k] = nil end
  tr.strikes[name] = nil
  save_state()
  return #ks
end
-- a mod still on after crashing the game (fewer than tr.CRASH_STRIKES in a row, or one that asked to stay on) that
-- changed since: its skipped calls are tried again
function starter.changed_since_crash(name, fp)
  local s = tr.strikes[name]
  if not (s and s.fp ~= 'pending' and s.fp ~= fp) then return end
  local n = starter.retry(name)
  log(fmt('%s changed since it crashed the game: %s', name, n > 0 and n .. ' skipped call(s) tried again' or 'its count starts over'))
end
-- A mod that asked to stay on after a crash ("-- HD2-Keep-On-Crash: yes" in its first lines; keep) has its off line
-- taken away: only the call that crashed stays skipped. Its strikes line stays, at 0, so a change of its file tries
-- that call again (now, if it changed already). -> nil, for the caller's `was`
function starter.keep_on(name, was, fp)
  off[name] = nil
  tr.strikes[name] = { n = 0, fp = was.fp }
  save_state()
  log('kept on after a crash (it asked to): ' .. name .. '; the call that crashed stays skipped')
  starter.changed_since_crash(name, fp)
end
-- The count of a mod the last launch ended, said once its file is read (the crash is counted before it is): one that
-- asked to stay on is never turned off for it.
function starter.stays(name, keep)
  local s = tr.strikes[name]
  if not (tr.shared.counted and name == tr.shared.struck and s and s.n > 0) then return end
  if keep then
    log(fmt('%s stays on: it asked to (HD2-Keep-On-Crash), %d crash(es) in a row; the call that crashed stays skipped',
      name, s.n))
  else
    log(fmt('%s stays on: %d of the %d crashes in a row that turn it off', name, s.n, tr.CRASH_STRIKES))
  end
end
-- once the addons have their fingerprints: a strikes line at 0 still 'pending' (a crash from a trace without "f"
-- lines) belongs to a mod not found since it crashed (a boot script's never resolves: its key carries its fingerprint,
-- so its line goes; its skips stay). A mod's line stays, marked 'gone': whatever file of it comes back is a change, and
-- I try its skipped calls again. A line that names the crashed file needs none of this.
function starter.unfound()
  local named, gone = {}, {}
  for _, r in ipairs(found_named) do named[r.name] = true end
  for name, s in pairs(tr.strikes) do
    if s.n == 0 and s.fp == 'pending' and not named[name] then gone[#gone + 1] = name end
  end
  for _, name in ipairs(gone) do
    if name:match('^boot:') then tr.strikes[name] = nil else tr.strikes[name].fp = 'gone' end
  end
  if #gone > 0 then save_state() end
end
function starter.addon(r)
  local a = { name = r.name, short = r.name:match('([^/]+)$'), file = r.file, fp = fingerprint(r.src),
              on = true, errors = 0, ms = 0, max_ms = 0, dev = r.dev, requires = {} }
  addons[#addons + 1] = a
  crumb('f ' .. a.name .. ' ' .. a.fp)
  for _, q in ipairs(services.requirements(r.src)) do a.requires[#a.requires + 1] = q.name end
  v1.off(a.name, r.src, a.fp)
  starter.changed_since_crash(a.name, a.fp)
  -- the player switched it off in my options menu (its own row, first in its options): not started
  if not svc.mod_switch(a.name, a.short, a.file) then
    a.on = false
    starter.state(a, 'off', 'switched off in the options menu')
    log('not started: ' .. a.name .. ' (switched off in the options menu)')
    return a
  end
  local was = off[a.name]
  local keep = r.src:sub(1, 400):match('\n%-%- HD2%-Keep%-On%-Crash: yes') ~= nil
  if was and keep then was = starter.keep_on(a.name, was, a.fp) end
  if was and was.fp == a.fp then
    a.on = false
    starter.state(a, 'kept off', was.why)
    log('kept off: ' .. a.name .. ' (' .. was.why .. '); an update of the mod turns it back on')
    notices[#notices + 1] = { text = svc.mod_title(a.name):upper() .. ' IS OFF AFTER A CRASH (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
  elseif was then
    starter.back_on(a.name)
  end
  if a.on and skip[a.name .. '|start'] then
    -- its own start code ended the game: not run again (a change of its file drops the skip, and it starts). Without a
    -- strikes or off line (a skip from an older state) I add one at 0, so that change is seen.
    if not tr.strikes[a.name] and not off[a.name] then tr.strikes[a.name] = { n = 0, fp = a.fp }; save_state() end
    a.on = false
    starter.state(a, 'not started', 'its start ended the game')
    log('not started: ' .. a.name .. ' (its start ended the game; an update of the mod tries it again)')
    notices[#notices + 1] = { text = svc.mod_title(a.name):upper() .. ' IS OFF AFTER A CRASH (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
    return a
  end
  starter.stays(a.name, keep)
  if a.on then
    local rok, why = starter.requires_ok(r)
    if not rok then
      a.on = false
      starter.state(a, 'not started', why)
      log('not started: ' .. a.name .. ' ' .. why)
      notices[#notices + 1] = { text = svc.mod_title(a.name):upper() .. ' IS OFF (SEE ' .. FILES:upper() .. '.LOG)', dur = 20 }
      return a
    end
    a.options = options_for(a.name)
    local t0, k0 = clock(), starter.heap_kb()
    local chunk, cerr = loadstring(r.src, '@' .. r.name)
    if not chunk then
      a.on = false
      starter.state(a, 'not started', 'could not compile: ' .. tostring(cerr))
      log('could not compile ' .. a.name .. ': ' .. tostring(cerr))
    elseif not svc.sandbox then
      -- no locked-down space, no start: a mod never runs with the game's whole Lua by mistake
      a.on = false
      starter.state(a, 'not started', 'the locked-down space for mods could not be set up')
      log('not started: ' .. a.name .. ' (the locked-down space for mods could not be set up)')
    else
      -- its own locked-down space (src/chef_loader/sandbox.lua)
      local env = starter.env_for(a.name)
      -- the game's callbacks as its globals: mods written for the old loaders chain them (keep the one they find, set
      -- their own that calls it), and what they set is run as their hook
      for k, f in pairs(starter.game_hooks) do rawset(env, k, f) end
      setfenv(chunk, env)
      crumb('> ' .. a.name .. '|start')
      local D = starter.dog
      local po, ps, pl, pn = D.enter(a, clock(), D.start)
      local ok, m = pcall(chunk, make_api(a))
      D.leave(po, ps, pl, pn)
      crumb('< ' .. a.name .. '|start')
      local took = starter.took(a, t0, k0)
      if ok and type(m) == 'table' then
        starter.read_module(a, m)
        if next(a.hooks) == nil and not a.hooks_mt and starter.data_only(m) then a.game_env = env end
        starter.state(a, 'running')
        log(fmt('started %s %s (%s; %s)', a.name, a.version or '', a.file, took))
      elseif ok and (m == nil or type(m) == 'boolean' or type(m) == 'number' or type(m) == 'string') then
        -- a file that does its work when it runs and returns nothing (or true, as HD2Runtime mods do; or a plain
        -- value, as other loaders allow) ran fine: its hooks are its runtime callbacks, if any, else it has none
        if m ~= nil and m ~= true then a.value = m end
        starter.read_module(a, {})
        if not a.rt then a.game_env = env end
        starter.state(a, 'running')
        log(fmt('started %s (%s; %s; %s)', a.name, a.file, a.rt and 'its callbacks through the HD2 Lua Runtime look-alike'
          or starter.set_game_hooks(a) and 'its hooks are the game callbacks it set'
          or 'it returned nothing, so it has no update or shutdown', took))
      else
        starter.off(a)                 -- it may have set up timers, watches or events before it failed
        local why = ok and ('it returned a ' .. type(m) .. ', not a table') or tr.why(m)
        starter.state(a, 'not started', why)
        log('could not start ' .. a.name .. ': ' .. why)
      end
    end
  end
  return a
end
-- A mod's on/off row in my options menu changed (svc.mod_switch): off stops it now, the usual way (its on_stop, then
-- everything it made); on again, it starts at the next launch (a mod is only started at launch). along: a part of a
-- package switched with its main mod (svc.pk_settle), which the main mod's own notice already tells.
function starter.switched(name, on, along)
  if on then
    log(name .. ' switched on in the options menu: it starts at the next launch')
    if not along then
      notices[#notices + 1] = { text = svc.mod_title(tostring(name)):upper() .. ' STARTS AT THE NEXT LAUNCH', dur = 8 }
    end
    return
  end
  for _, a in ipairs(addons) do
    if a.name == name and a.on then
      starter.off(a)
      starter.state(a, 'off', 'switched off in the options menu')
      log('switched off ' .. name .. ' in the options menu (and at the next launches)')
    end
  end
  -- (svc.ctx.boots, not boots: that local is declared further down, so here the bare name is the global, nil)
  for _, b in ipairs(svc.ctx.boots or {}) do
    if b.owner == name and b.on then
      b.on = false
      b.state, b.why, svc.ctx.health_dirty = 'off', 'switched off in the options menu', true
      if b.a then starter.off(b.a) end
      log('switched off ' .. name .. ' in the options menu (and at the next launches)')
      starter.stopped(name, 'switched off in the options menu')
    end
  end
end
svc.ctx.mod_switched = starter.switched
-- What a CRASH RECOVERY button names: a mod as its entry in the list shows it (svc.mod_title); another mod's boot
-- script (boot:<fingerprint>) by the patch file it's in this launch (the boot that started me, or one I found), else
-- by its fingerprint.
function starter.retry_what(name)
  local fp = name:match('^boot:(.+)$')
  if not fp then return svc.mod_title and svc.mod_title(name) or name end
  local ran = scan.ran
  if ran and ran.fp == fp then return 'the boot script in ' .. ran.file end
  for _, b in ipairs(found_boots) do
    if b.fp == fp then return 'the boot script in ' .. b.file end
  end
  return 'the boot script with fingerprint ' .. fp
end
-- CRASH RECOVERY in my options menu: one "Try again next launch" button for each mod or other mod's boot script the
-- crash state holds back (kept off, crashes counted in a row, skipped calls, a job suspected of the last crash), its
-- hint saying what. Pressed, its lines leave the state file (tr.retry), so the next launch starts it and tries its
-- skipped calls again (a suspected job gets a first crash's chance again, not a skip); nothing changes in this launch.
-- This is the menu's way to do what deleting chef_loader_state.txt by hand did, one mod at a time. My own keys
-- (loader|...) and the refusals shared with every mod (shared|...) get no button: their owner is neither. A boot
-- script's strikes line still 'pending' at 0 is gone by now (starter.unfound) and one at 0 gets no button anyway.
function starter.retry_rows()
  local by, names = {}, {}
  local function note(name, what)
    if type(name) ~= 'string' or not (name:match('^mods/') or name:match('^boot:[^|%s]+$')) then return end
    if not by[name] then by[name] = {}; names[#names + 1] = name end
    local e = by[name]
    e[#e + 1] = what
  end
  for n, o in pairs(off) do note(n, 'kept off (' .. tostring(o.why) .. ')') end
  for n, s in pairs(tr.strikes) do if (s.n or 0) > 0 then note(n, s.n .. ' crash(es) in a row') end end
  -- (skipped and suspected calls counted per mod, each key's owner the part before its first |)
  for _, t in ipairs({ { skip, ' skipped call(s)' }, { suspect, ' suspected call(s)' } }) do
    local count = {}
    for k in pairs(t[1]) do
      local o = k:match('^(.-)|')
      if o then count[o] = (count[o] or 0) + 1 end
    end
    for o, n in pairs(count) do note(o, n .. t[2]) end
  end
  sort(names)
  for _, name in ipairs(names) do
    local row
    local what = starter.retry_what(name)
    -- (a row's hint is 200 bytes at most, or the row isn't made: a longer list of reasons is cut there, between UTF-8
    -- characters, with ...)
    local hint = concat(by[name], ', ')
    if #hint > 200 then hint = hint:sub(1, draw.utf8_floor(hint, 197)) .. '...' end
    row = svc.loader_option('retry.' .. name, { type = 'button', label = 'Try again next launch: ' .. what, text = 'RETRY',
      section = 'recovery', hint = hint, run = function()
        if tr.retry[name] then return end
        tr.retry[name] = true
        save_state()
        -- (the log names a mod in full, a boot script by its file)
        log('crash recovery: ' .. (name:match('^boot:') and what or name) .. ' is tried again at the next launch (' .. concat(by[name], ', ') .. ')')
        notices[#notices + 1] = { text = what:upper() .. ' IS TRIED AGAIN AT THE NEXT LAUNCH', dur = 8 }
        if row then svc.relabel(row, 'Tried again next launch: ' .. what, 'DONE') end
      end })
  end
  if #names > 0 then log(fmt('crash recovery: %d mod(s) held back by the crash state (options menu > %s > CRASH RECOVERY)', #names, LOADER)) end
end
-- A mod whose version changed since the last launch: a log line each and one notice (one mod named as its entry in
-- the list names it, after its start, so its chef.title counts; more by their count). I keep each version among my own
-- saved values, "ver.<author>.<name>" (its name after mods/, each / a dot: names have no dots, so no two meet), which
-- the settings file writes with the rest (only when one changed). Only a mod that started has a version to read: one
-- switched off, kept off or not started keeps the one I last saw, so back on at that version it says nothing. A mod
-- seen for the first time is only recorded; one with no version, or a name or version too long (or odd) to keep, is
-- left out. My own version isn't one of them (my start line says it).
function starter.updated_notice()
  local up = {}
  for _, a in ipairs(addons) do
    local key = type(a.version) == 'string' and #a.version <= 64 and not a.version:find('%c') and a.name:match('^mods/(.+)$')
    key = key and 'ver.' .. (key:gsub('/', '.'))
    if key and #key <= 64 then
      local was = svc.loader_get(key)
      if type(was) == 'string' and was ~= a.version then
        log(fmt('updated %s: %s -> %s', a.name, was, a.version))
        up[#up + 1] = { name = a.name, was = was, now = a.version }
      end
      svc.loader_put(key, a.version)
    end
  end
  -- (in white: it's news, not a warning)
  if #up == 1 then
    local u = up[1]
    notices[#notices + 1] = { text = (svc.mod_title(u.name) .. ' UPDATED: ' .. u.was .. ' -> ' .. u.now):upper(), dur = 8, rgb = { 255, 255, 255 } }
  elseif #up > 1 then
    notices[#notices + 1] = { text = #up .. ' MODS UPDATED (SEE ' .. FILES:upper() .. '.LOG)', dur = 8, rgb = { 255, 255, 255 } }
  end
end
local function start_addons()
  local seen = {}
  -- the HD2Runtime API's own core deployed as an addon: the loader that bundles it runs it, and that API's mods with
  -- it, only when that loader runs at all, i.e. it handed off to me from above. Below me its boot isn't run
  -- (boot_one), so the core stays unstarted and my look-alike runs those mods.
  starter.rt_host = nil
  for _, r in ipairs(found_addons) do if starter.handoff and starter.rt_core(r) then starter.rt_host = r.file end end
  for _, r in ipairs(services.order(found_addons)) do
    if seen[r.name] then
      log(fmt('two copies of %s: running the one deployed last (%s), skipped %s', r.name, seen[r.name], r.file))
    else
      seen[r.name] = r.file
      local by, how = starter.elsewhere_safe(r)
      if by then
        starter.never(r.name, r.file, 'started elsewhere', by .. ' (' .. how .. ')', 'addon')
        log(fmt('%s: already started by %s (%s), not started again', r.name, by, how))
      elseif starter.rt_core(r) or (starter.rt_host and starter.rt_mod(r)) then
        -- (not mine to start, and not marked as mine in package.loaded: the loader that bundles the core starts both;
        -- with no such loader running, rt_host is nil and only the core gets here)
        by = true
        if not starter.rt_host then
          starter.never(r.name, r.file, 'not started', 'the HD2 Lua Runtime\'s own core: not needed, its mods run on my look-alike of it', 'addon')
          log(fmt('the HD2 Lua Runtime in %s (%s): not needed, no loader handed off to me, so its mods run on my look-alike '
            .. 'of it', r.file, r.name))
        elseif starter.rt_core(r) then
          starter.never(r.name, r.file, 'left to its loader', 'the HD2 Lua Runtime\'s own core: the loader that bundles it runs it', 'addon')
          log(fmt('the HD2 Lua Runtime in %s (%s): left to the loader that bundles it, which runs that runtime\'s mods', r.file, r.name))
        else
          starter.never(r.name, r.file, 'left to its loader', 'made for the HD2 Lua Runtime, whose own core is installed: '
            .. 'the loader that bundles it runs this mod', 'addon')
          log(fmt('%s (%s): made for the HD2 Lua Runtime, whose own core is in %s: left to the loader that bundles it, not '
            .. 'started on my look-alike', r.name, r.file, starter.rt_host))
        end
      end
      -- one pcall each: a mod that breaks my start-up steps (an error object that can't be shown, say) stops only itself
      local ok, err = true, nil
      if not by then ok, err = pcall(starter.addon, r) end
      if not ok then
        local a = addons[#addons]
        if a and a.name == r.name then pcall(starter.off, a); pcall(starter.state, a, 'not started', tr.why(err)) end
        log('starting ' .. r.name .. ' failed: ' .. tr.why(err))
      end
    end
  end
end

-- ------------------------------------------------------------------ frame
-- the loader's own time per frame and its frame errors (one table: the loader is near Lua 5.1's 200 locals); sig and
-- logged_at: the status line's last numbers and when it was last written
local st = { next_status = STATUS_EVERY, ms = 0, frames = 0, max = 0, errors = 0, errors_at = 0, sig = nil, logged_at = -1e9 }
-- a loader error every frame mustn't flood the log: the first few, then a count once a minute
local function frame_error(err)
  st.errors = st.errors + 1
  if st.errors <= 5 then log('frame error: ' .. tr.why(err))
  elseif elapsed >= st.errors_at then st.errors_at = elapsed + 60; log(fmt('frame errors so far: %d (last: %s)', st.errors, tr.why(err))) end
end

-- (a notice I can draw: a text, a time, and no color or one of three finite numbers. One a mod made with anything else
-- ('red', say) would raise in every frame's drawing, never reach its end and hold up every notice after it.)
function draw.notice_ok(n)
  if type(n) ~= 'table' or type(n.text) ~= 'string' or type(n.dur) ~= 'number' then return false end
  local c = n.rgb
  if c == nil then return true end
  if type(c) ~= 'table' then return false end
  for i = 1, 3 do
    local v = c[i]
    if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return false end
  end
  return true
end
local function draw_notices()
  if #notices == 0 or not world.stable then return end
  draw_world_reset()
  -- PERF: the notices shown on are kept in place (no new list each frame): the ones that ran out, or can't be drawn,
  -- go first, before anything is drawn, so an error in the drawing can't leave the list half moved up
  local nn, kept = #notices, 0
  for i = 1, nn do
    local n = notices[i]
    local on = type(n) == 'table'
    if on then
      if n.valid == nil then n.valid = draw.notice_ok(n) end
      on = n.valid and elapsed < (n.until_t or math.huge)
    end
    if on then kept = kept + 1; notices[kept] = n end
  end
  for i = nn, kept + 1, -1 do notices[i] = nil end
  if kept == 0 then return end
  local w, h = draw.w, draw.h
  local px = max(2, floor(h / 540 + 0.5))
  -- (the first plate's top edge 18% down the screen, y growing upward: under the title screen's logo and the ship's
  -- top bar, in the upper third, clear of the bottom HUD; the next ones stack under it)
  local y = h - floor(h * 0.18)
  -- (in the top world, under the monitor and the menu, so they show over the game's HUD and menus too; in the main
  -- world when there's no top world to draw in, or drawing there was switched off after a crash)
  local base = top_gui() and TOP_FROM + 930 or 950
  -- (the red toned for the top world's curve there: the menu's palette, nav.pal.notice)
  local nr = base >= TOP_FROM and svc.pal and svc.pal.notice
  local red, dark = nr and color(nr[1], nr[2], nr[3], 255) or color(255, 90, 70, 255), color(8, 9, 8, 225)
  local seen = not (draw.cover and base >= TOP_FROM)
  for _, n in ipairs(notices) do
    -- (the clock starts once it can be seen, and once the game has shown the ship or a mission: see world.shown)
    if n.until_t == nil and seen then
      n.drawn_t = n.drawn_t or elapsed
      if world.shown or elapsed - n.drawn_t >= world.HOLD then n.until_t = elapsed + n.dur end
    end
    if elapsed < (n.until_t or math.huge) then
      -- wrapped to 60% of the screen (measured; worked out again only when the screen, font or text changes)
      local native = draw.nt_on()
      if n.wrap_w ~= w or n.wrap_native ~= native or n.wrap_px ~= px or n.wrap_gen ~= draw.nt.gen or n.wrap_lang ~= svc.lang.v then
        draw.nt.guessed, svc.lang.skipped = false, false
        n.lines, n.wrap_w, n.wrap_native, n.wrap_px = draw.text_wrap(n.text, px, floor(w * 0.6), 4), w, native, px
        n.wrap_gen, n.wrap_lang = draw.nt.gen, svc.lang.v
        -- (each line's width and the widest, measured with the wrap and kept with its lines: a frame only draws them)
        n.lws, n.lw = {}, 0
        for i, l in ipairs(n.lines) do n.lws[i] = text_width(l, px); n.lw = max(n.lw, n.lws[i]) end
        -- (a letter not measured yet, or a text not translated yet: worked out again next frame)
        if draw.nt.guessed or svc.lang.skipped then n.wrap_w = nil end
      end
      local c = n.rgb and color(n.rgb[1], n.rgb[2], n.rgb[3], 255) or red
      -- one dark plate behind the whole notice (its widest line, a margin all round) with a thin edge in its color on
      -- the left, so it reads over anything; its lines centered on it
      if n.lines[1] then
        local lw = n.lw
        local ph, x = #n.lines * 11 * px + 4 * px, floor((w - lw) / 2) - 6 * px
        rect(x, y - ph, lw + 12 * px, ph, dark, base)
        rect(x, y - ph, px, ph, c, base + 1)
        y = y - 2 * px
        for i, l in ipairs(n.lines) do
          y = y - 11 * px
          text(floor((w - n.lws[i]) / 2), y + 2 * px, l, px, c, base + 5)
        end
        y = y - 2 * px - 3 * px
      end
    end
  end
end
-- The health file, written only when its text changed: a mod's state, or its times (looked at once a status minute,
-- so a minute that moved nothing writes nothing). st.health_text: the text last written (nil after a failed write, so
-- the next change writes it whatever it is).
function starter.health()
  local text = svc.util.health_text()
  if text == st.health_text then return true end
  st.health_text = nil
  local ok = svc.util.write_health()
  if ok then st.health_text = text end
  return ok
end

local function frame(dt)
  frame_no = frame_no + 1
  tr.menu = svc.menu_open()
  if tr.menu or next(held) then tick() end
  if tr.opt.due and floor(elapsed) > tr.opt.w then tr.opt_write() end
  if next(tr.reads_held) then tr.guard_release() end
  update_world()
  if draw.nt.main or draw.nt.top or draw.nt.holding or draw.nt.dropped ~= nil or draw.nt.reclaim_frame then
    local ok, err = pcall(draw.nt_sweep, 1)
    if not ok then frame_error(err) end
  end
  if job then
    if job.probe then probe_step() else scan_step() end
  elseif world.stable and world.probe_at and elapsed >= world.probe_at then
    if can_probe() then probe_start() else world.probe_at, world.checking = nil, false end
  elseif world.stable and #watchers > 0 then
    scan_start()
  end
  -- (my full screen menu open this frame: decided before any mod draws, confirmed by the menu as it draws)
  local cv = svc.covering and svc.covering()
  draw.cover = cv and cv - TOP_FROM or nil
  for _, a in ipairs(addons) do run_hook(a, 'update', dt) end
  -- one pcall each: an error in one (the menu, say) doesn't hold up the timers or the drawing
  draw.cover_set = false
  draw.color_scope()
  local ok, err = pcall(svc.frame, dt)
  if not ok then frame_error(err) end
  if not draw.cover_set then draw.cover = nil end
  draw.color_scope()
  ok, err = pcall(svc.util.frame)
  if not ok then frame_error(err) end
  draw.color_scope()
  ok, err = pcall(draw_notices)
  if not ok then frame_error(err) end
  ok, err = pcall(draw_flush)
  if not ok then frame_error(err) end
  -- (a language on: every text of the options menu is looked up once, and again when the menu's rows or the language
  -- change, so the texts it has no entry for are listed whether or not the player has scrolled to them)
  if draw.tr == svc.lang.tr then
    if draw.tr_layout ~= svc.layout_ver() or draw.tr_lv ~= svc.lang.v then
      draw.tr_layout, draw.tr_lv, draw.tr_list, draw.tr_at = svc.layout_ver(), svc.lang.v, nil, 1
    end
    if draw.tr_list ~= false and not svc.lang.budget_spent() then
      ok, err = pcall(draw.tr_pass)
      if not ok then frame_error(err); draw.tr_list = false end
    end
  end
  if svc.lang.dirty then
    ok, err = pcall(svc.lang.flush, elapsed)
    if not ok then frame_error(err) end
  end
  if svc.ctx.health_dirty and elapsed >= (svc.ctx.health_at or 0) then
    svc.ctx.health_dirty, svc.ctx.health_at = false, elapsed + 5
    ok, err = pcall(starter.health)
    if not ok then frame_error(err) end
  end
  if elapsed >= st.next_status then
    st.next_status = elapsed + STATUS_EVERY
    -- Each mod's time (hooks, timers, spread jobs) over the loader's frames this minute, checked against its budget
    -- every minute. The line itself is only written when a mod is on and its numbers moved (avg to 0.05 ms, worst to
    -- 0.5 ms, on/off, errors), else once every 10 minutes.
    local parts, sig, any_on, frames = {}, {}, false, st.frames
    for _, a in ipairs(addons) do
      local avg = frames > 0 and a.ms / frames or 0
      parts[#parts + 1] = fmt('%s %s avg %.3f ms max %.2f ms%s', a.short, a.on and 'on' or 'off', avg, a.max_ms,
        a.errors > 0 and (' errors ' .. a.errors) or '')
      sig[#sig + 1] = fmt('%s%s%d:%d:%d', a.short, a.on and '+' or '-', a.errors, floor(avg * 20 + 0.5), floor(a.max_ms * 2 + 0.5))
      if a.on then
        any_on = true
        if frames > 0 then svc.util.budget_check(a, avg, a.max_ms) end
      end
      a.last_avg, a.last_max = frames > 0 and avg or nil, frames > 0 and a.max_ms or nil
      svc.ctx.health_dirty = true                 -- (the health file's times: looked at once a status minute)
      a.ms, a.max_ms = 0, 0
    end
    sig = concat(sig, ' ')
    if (any_on and sig ~= st.sig) or elapsed >= st.logged_at + 600 then
      st.sig, st.logged_at = sig, elapsed
      local scans = ''
      if res.n > 0 or res.full_n > 0 then
        scans = fmt(' | unit lists: %d by resource avg %.2f ms, %d full scans avg %.2f ms', res.n, res.n > 0 and res.ms / res.n or 0,
          res.full_n, res.full_n > 0 and res.full_ms / res.full_n or 0)
        res.n, res.ms, res.full_n, res.full_ms = 0, 0, 0, 0
      end
      -- (my menu not opened yet after the first 3 minutes: which key opens it, so a log sent to me answers that too)
      if elapsed >= 180 and not svc.menu_ever() then scans = scans .. ' | options menu not opened yet: ' .. svc.menu_how() end
      log(fmt('status: loader avg %.3f ms max %.2f ms | %s%s', frames > 0 and st.ms / frames or 0, st.max,
        #parts > 0 and concat(parts, ' | ') or 'no addons', scans))
    end
    st.ms, st.frames, st.max = 0, 0, 0
  end
end

-- ------------------------------------------------------------------ other mods' boot scripts
-- The game runs only one `boot`: whichever deployed patch has it last. Mods that need boot for something of their own
-- (a file-mod installer boot, say, that swaps game files when the game exits) would stop working next to me, and I
-- next to them. So each other boot found in the patches runs too, in its own environment (its init/update/render/
-- shutdown and anything else it defines stay in there; _G is that environment too, so it can't replace mine), with
-- each of its callbacks called after mine. Identical copies (several mods can ship the same one) run
-- once. Each callback's first call is breadcrumbed like an engine call, so one that
-- ends the game is skipped from the next launch on; one that keeps raising Lua errors is turned off for the session.
local boots = {}
svc.ctx.boots = boots
-- A mod can also ship its boot-style script as "-- HD2-Boot: mods/<author>/<name>" (any resource name, not
-- `boot`): then it never replaces mine and runs whatever order the mods deploy in. It runs like the others below
-- (init/update/render/shutdown in its own environment), plus: a `chef` table of helpers (with its options), its log
-- lines under its name, and if it ends the game it stays off (named on screen) until the mod is updated, as an addon.
-- An environment alone doesn't hold a boot script in: on Lua 5.1 a function made by loadstring (or load, or
-- dofile) gets the game's globals, not the environment of the script that made it. A boot script that loads code
-- would write init/update/render/shutdown straight into the game's globals and replace mine, and I'd never run
-- again. So every other mod's boot script gets its own
-- loadstring, load and dofile, and whatever they load lands in that script's environment too (unless it hands load an
-- environment). (HD2-Boot scripts get the same from the locked-down space in sandbox.lua instead.)
function starter.seal(env)
  env.loadstring = function(s, name)
    local f, err = loadstring(s, name)
    if f then setfenv(f, env) end
    return f, err
  end
  local load_ = rawget(env, 'load') or rawget(G, 'load')   -- my compat load (boot-style scripts get it) or the game's
  if type(load_) == 'function' then
    env.load = function(chunk, name, mode, e)
      local f, err = load_(chunk, name, mode, e)
      if f and e == nil then setfenv(f, env) end
      return f, err
    end
  end
  if type(rawget(G, 'dofile')) == 'function' and type(io_) == 'table' then
    env.dofile = function(path)
      local fh = io_.open(path, 'rb')
      if not fh then error('cannot open ' .. tostring(path), 2) end
      local text = fh:read('*a'); fh:close()
      local f, err = loadstring(text or '', '@' .. tostring(path))
      if not f then error(err, 2) end
      setfenv(f, env)
      return f()
    end
  end
end
-- The trusted mods that are installed get their grants (sandbox.lua keeps them; the lobby is runtime.lua's)
function starter.trust(sb)
  local found = {}
  for _, r in ipairs(found_addons) do found[r.name] = true end
  for _, r in ipairs(found_named) do found[r.name] = true end
  for name, t in pairs(TRUSTED) do
    if found[name] then
      local g = { capture = t.capture == true or nil }
      sb.grant(name, g)
      local what = {}
      if t.network then what[#what + 1] = 'the Steam lobby' end
      if g.capture then what[#what + 1] = 'screenshots' end
      log(fmt('trusted: %s (%s)', name, concat(what, ', ')))
    end
  end
end
-- Another loader, named from its own markers (its title line otherwise)
function starter.loader_name(src, title)
  local v = src:match('local MARKER = "boot%-mod%-loader%-([%d%.]+)"')
  if v then return 'Boot Mod Loader ' .. v end
  v = src:find('CowboyBingusModLoader', 1, true) and src:match('revision = "loader%-v(%d+)"')
  if v then return 'Bingus Shared Loader v' .. v end
  return ((title:match('^([^%(%.;]+)') or 'another loader'):gsub('%s+$', ''))
end
-- Who filled another loader's Bingus-API table (k: the global it sits under). The table's name alone says nothing: a
-- loader that hosts me makes one for the mods that look for it (the loader that API comes from no longer runs), so I
-- name the loader that handed off to me, else the revision or loader/runtime the table gives, else just "another
-- loader".
-- (my own look-alikes never get here: elsewhere skips any table with my revision)
function starter.table_owner(L, k, rev)
  local h = starter.handoff
  if h and h ~= 'another loader' then return h end
  if type(rev) == 'string' then return rev:sub(1, 40) end
  local v = rawget(L, 'loader')
  if type(v) ~= 'string' then v = rawget(L, 'runtime') end
  local via = 'through its Bingus-compatible ' .. k .. ' table)'
  if type(v) == 'string' and v:find('%w') then return 'another loader (' .. (v:sub(1, 40):gsub('%c', ' ')) .. ', ' .. via end
  return 'another loader (' .. via
end
-- A mod another loader already started in this Lua state (it handed off to me after starting some): it isn't started
-- a second time. Their marks: a `__boot_mod_loader.mods` list, the `modules` table of a CowboyBingusModLoader or
-- HD2ModLoader that isn't mine, and package.loaded (set for every mod a loader started, or left by a require that
-- failed).
function starter.elsewhere(name)
  local bml = chef_before.loaders.__boot_mod_loader
  local list = type(bml) == 'table' and rawget(bml, 'mods')
  if type(list) == 'table' then
    for i = 1, 4096 do
      local e = rawget(list, i)
      if e == nil then break end
      if type(e) == 'table' and rawget(e, 'name') == name and rawget(e, 'state') == 'loaded' then return 'Boot Mod Loader', 'loaded' end
    end
  end
  for _, k in ipairs({ 'HD2ModLoader', 'CowboyBingusModLoader' }) do
    local L = chef_before.loaders[k]
    local rev = type(L) == 'table' and rawget(L, 'revision')
    local mods = type(L) == 'table' and rawget(L, 'modules')
    if type(mods) == 'table' and not (type(rev) == 'string' and rev:find('^chef%-shared%-loader')) then
      local s = rawget(mods, name)
      if s == 'loaded' or s == 'loading' then return starter.table_owner(L, k, rev), s end
    end
  end
  -- (require's own placeholder, a userdata, is a require that failed or never finished: that mod isn't running)
  local pkg = rawget(G, 'package')
  local loaded = type(pkg) == 'table' and rawget(pkg, 'loaded')
  local v = type(loaded) == 'table' and rawget(loaded, name)
  if v ~= nil and type(v) ~= 'userdata' and not starter.marks[v] then return 'another loader', 'started' end
end
-- (my start-up steps never stop on another loader's odd table: an error there means "not started elsewhere")
function starter.elsewhere_safe(r)
  -- a mod made for me (HD2-Requires: chef-shared-loader) did nothing under another loader: I start it
  local head = r.src and r.src:sub(1, 1200)
  if head and (head:find('\n%-%- HD2%-Requires: chef%-shared%-loader') or head:find('\n%-%- HD2%-Requires: chef%-loader')) then return nil end
  local ok, by, how = pcall(starter.elsewhere, r.name)
  if ok then return by, how end
end
-- The HD2Runtime API's own core, bundled as an addon by a loader that ships it for its mods. When that loader hands
-- off to me from above, it starts the core and the mods that ask for it, which may need more of that API than my
-- look-alike has. So the core is never started here, and a mod announcing `@requires` / `@after mods/hd2rt/core` is
-- left to that loader while the core is deployed and a loader handed off to me. Otherwise (no core, or that loader's
-- boot beneath mine, which I don't run) my look-alike runs the mod.
function starter.rt_core(r)
  if r.name == 'mods/hd2rt/core' then return true end
  local head = r.src and r.src:sub(1, 600)
  return head ~= nil and head:find('\n%-%- @name HD2 Lua Runtime\r?\n') ~= nil
end
function starter.rt_mod(r)
  local head = r.src and r.src:sub(1, 1200)
  if not head or head:find('\n%-%- HD2%-Requires: chef%-shared%-loader') then return false end
  return head:find('\n%-%- @requires%s+mods/hd2rt/core[^%w_/]') ~= nil or head:find('\n%-%- @after%s+mods/hd2rt/core[^%w_/]') ~= nil
end
-- and the other way round: every mod I start is marked in the game's package.loaded, so a loader that starts mods
-- with require, or checks package.loaded first, skips it. The mark is a read-only stand-in that reads the mod's own
-- table (a boot script that requires it as a library still gets its fields), never the table itself.
starter.marks = setmetatable({}, { __mode = 'k' })
function starter.value_of(name)
  for _, a in ipairs(addons) do if a.name == name then return a.module end end
end
function starter.publish(name)
  local pkg = rawget(G, 'package')
  local loaded = type(pkg) == 'table' and rawget(pkg, 'loaded')
  if type(loaded) == 'table' and rawget(loaded, name) == nil then
    local m = newproxy and newproxy(true)
    if m then
      local mt = getmetatable(m)
      mt.__index = function(_, k)
        local v = starter.value_of(name)
        if type(v) == 'table' then return v[k] end
      end
      mt.__metatable = false
    else
      m = setmetatable({}, { __index = function(_, k) local v = starter.value_of(name); if type(v) == 'table' then return v[k] end end,
                             __newindex = function() error('read-only', 2) end, __metatable = false })
    end
    starter.marks[m] = true
    rawset(loaded, name, m)
  end
end
-- Another mod loader's boot script (one with the __boot_mod_loader marker, or one that reads the deployed patches for
-- "-- HD2-Addon:" mods itself) isn't run (boot_one): its init would start every addon a second time, outside my crash
-- guard and without the `chef` helpers my mods need. Copies of this loader are already left out when the patches are
-- read.
function starter.other_loader(src)
  if src:find('__boot_mod_loader', 1, true) then return true end
  -- one that reads the patches for HD2-Addon mods itself
  local reads = (src:find('HD2%-Addon', 1, true) or src:find('HD2-Addon', 1, true)) and src:find('9ba626afa44a3aa3', 1, true)
  if not reads then return false end
  return true
end
function starter.named_one(r)
  local fp = fingerprint(r.src)
  local short = r.name:match('([^/]+)$')
  crumb('f ' .. r.name .. ' ' .. fp)
  v1.off(r.name, r.src, fp)
  local was = off[r.name]
  if was and was.fp == 'pending' then was.fp = fp; save_state() end
  local st = tr.strikes[r.name]
  if st and st.fp == 'pending' then st.fp = fp; save_state() end
  starter.changed_since_crash(r.name, fp)
  if not svc.mod_switch(r.name, short, r.file) then
    starter.never(r.name, r.file, 'off', 'switched off in the options menu')
    log('not started: ' .. r.name .. ' (switched off in the options menu)')
    return
  end
  local keep = r.src:sub(1, 400):match('\n%-%- HD2%-Keep%-On%-Crash: yes') ~= nil
  if was and keep then was = starter.keep_on(r.name, was, fp) end
  starter.stays(r.name, keep)
  if was and was.fp == fp then
    starter.never(r.name, r.file, 'kept off', was.why)
    log('kept off: ' .. r.name .. ' (' .. was.why .. '); an update of the mod turns it back on')
    notices[#notices + 1] = { text = svc.mod_title(r.name):upper() .. ' IS OFF AFTER A CRASH (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
    return
  end
  if was then starter.back_on(r.name) end
  local rok, why = starter.requires_ok(r)
  if not rok then
    starter.never(r.name, r.file, 'not started', why)
    log('not started: ' .. r.name .. ' ' .. why)
    notices[#notices + 1] = { text = svc.mod_title(r.name):upper() .. ' IS OFF (SEE ' .. FILES:upper() .. '.LOG)', dur = 20 }
    return
  end
  local t0, k0 = clock(), starter.heap_kb()
  local chunk, cerr = loadstring(r.src, '@' .. r.name)
  if not chunk then
    starter.never(r.name, r.file, 'not started', 'could not compile: ' .. tostring(cerr))
    log('could not compile ' .. r.name .. ': ' .. tostring(cerr))
    return
  end
  if not svc.sandbox then
    starter.never(r.name, r.file, 'not started', 'the locked-down space for mods could not be set up')
    log('not started: ' .. r.name .. ' (the locked-down space for mods could not be set up)')
    return
  end
  -- the same locked-down space as an addon (its own _G, loadstring, load; src/chef_loader/sandbox.lua)
  local env = starter.env_for(r.name)
  -- One table is both its mod (the chef helpers, its timers and jobs add their time to it) and its row in the boot
  -- scripts (its callbacks' time), so the performance monitor shows all of its time on its own row.
  local a = { name = r.name, short = short, file = r.file, fp = fp, on = true, errors = 0, ms = 0, max_ms = 0,
              owner = r.name, env = env }
  a.a = a
  a.options = options_for(r.name)
  env.chef = make_api(a)
  starter.seed(env)
  setfenv(chunk, env)
  local D = starter.dog
  local po, ps, pl, pn = D.enter(a, clock(), D.start)
  local ok, err = starter.seeded(env, r.name, function() return guarded(r.name, 'load', function() chunk(); return true end) end)
  D.leave(po, ps, pl, pn)
  starter.unseed(env)
  local took = starter.took(a, t0, k0)
  if err ~= nil and ok == nil then
    starter.off(a)                     -- it may have set up timers, watches or events before it failed
    starter.never(r.name, r.file, 'not started', 'failed to run: ' .. tr.why(err))
    log(fmt('%s failed to run: %s', r.name, tr.why(err)))
  else
    boots[#boots + 1] = a
    starter.publish(r.name)
    log(fmt('started %s (boot-style, %s; %s)', r.name, r.file, took))
  end
end
local function start_named()
  local seen = {}
  for _, r in ipairs(services.order(found_named)) do
    if seen[r.name] then
      log(fmt('two copies of %s: running the one deployed last (%s), skipped %s', r.name, seen[r.name], r.file))
    else
      seen[r.name] = r.file
      -- (no other loader starts an HD2-Boot mod: never "started elsewhere")
      local ok, err = pcall(starter.named_one, r)
      if not ok then log('starting ' .. r.name .. ' failed: ' .. tr.why(err)) end
    end
  end
end
-- (dev mode) the files again: options first, then each addon or boot-style script is stopped and started fresh
function starter.dev_reload(list)
  for _, d in ipairs(list) do
    if d.kind == 'Options' then
      for i = #found_options, 1, -1 do if found_options[i].dev and found_options[i].path == d.path then table.remove(found_options, i) end end
      found_options[#found_options + 1] = d
    end
  end
  local n = 0
  for _, d in ipairs(list) do
    if d.kind == 'Addon' then
      for i = #addons, 1, -1 do
        local a = addons[i]
        if a.name == d.name then run_hook(a, 'shutdown'); starter.off(a); table.remove(addons, i) end
      end
      starter.addon(d); n = n + 1
    elseif d.kind == 'Boot' then
      for i = #boots, 1, -1 do
        local b = boots[i]
        if b.owner == d.name then
          local fn = b.on and rawget(b.env, 'shutdown')
          if type(fn) == 'function' then pcall(fn) end
          b.on = false
          if b.a then starter.off(b.a) end
          table.remove(boots, i)
        end
      end
      starter.named_one(d); n = n + 1
    end
  end
  log(fmt('dev mode: reloaded %d mod(s)', n))
  notices[#notices + 1] = { text = 'DEV MODE: RELOADED ' .. n .. ' MOD(S)', dur = 4 }
end
svc.ctx.dev_reload = starter.dev_reload
function starter.boot_one(b, seen)
  local fp = fingerprint(b.src)
  b.fp = fp                            -- (CRASH RECOVERY names a boot:<fingerprint> by the file it's in: retry_what)
  local title = (b.src:match('^%-%-%s*([^\r\n]+)') or 'no title'):sub(1, 90)
  if seen[fp] then
    log(fmt('another copy of a boot script I already run (%s): skipped', b.file))
  elseif starter.other_loader(b.src) and title:match('^HD2 Lua Runtime') then
    -- the HD2Runtime API's own boot, which its mods carry: I run those mods myself (its look-alike), so it isn't needed;
    -- while a loader that handed off to me bundles its core (start_addons, before this), they're left to that loader
    seen[fp] = true
    if starter.rt_host then
      log(fmt('the HD2 Lua Runtime\'s boot script in %s (%s): not needed, its mods are left to the loader that bundles its '
        .. 'core (in %s)', b.file, title, starter.rt_host))
    else
      log(fmt('the HD2 Lua Runtime\'s boot script in %s (%s): not needed, its mods run on my look-alike of it', b.file, title))
    end
  elseif starter.other_loader(b.src) then
    seen[fp] = true
    local who = starter.loader_name(b.src, title)
    if starter.handoff and starter.handoff:find(who, 1, true) == 1 then
      -- the loader that handed off to me: its boot is the one the game ran
      starter.never('boot:' .. fp, b.file, 'handed off', who .. ' started me and left its mods to me')
      log(fmt('%s\'s boot script in %s handed off to me: I run its mods', who, b.file))
    else
      starter.never('boot:' .. fp, b.file, 'not started', who .. ': it would start every mod a second time')
      log(fmt('%s\'s boot script is in %s, below mine: not run, it would start every addon a second time; its mods run '
        .. 'here. If it is ever deployed after me, the game runs it instead of me and no %s mod starts', who, b.file, LOADER))
      notices[#notices + 1] = { text = 'OTHER LOADER NOT RUN: ' .. who:upper():sub(1, 24) .. ' (SEE ' .. FILES:upper() .. '.LOG)', dur = 10 }
    end
  else
    seen[fp] = true
    local chunk, cerr = loadstring(b.src, '@boot (' .. b.file .. ')')
    local owner = 'boot:' .. fp
    v1.boot(b.src, owner)
    if not chunk then
      starter.never(owner, b.file, 'not started', 'could not compile: ' .. tostring(cerr))
      log(fmt('could not compile the boot script in %s: %s', b.file, tostring(cerr)))
    elseif off[owner] then
      starter.never(owner, b.file, 'kept off', off[owner].why)
      log(fmt('kept off: the boot script in %s (%s)', b.file, off[owner].why))
    else
      -- its metatable locked, and known to the locked-down space as someone else's: no loader mod can reach the game's
      -- globals through it (getfenv on one of its functions gives the mod its own environment)
      local env = setmetatable({}, { __index = G, __metatable = 'locked' })
      env._G = env
      starter.seal(env)
      if svc.sandbox and type(svc.sandbox.register_full) == 'function' then svc.sandbox.register_full(env, owner) end
      starter.seed(env)
      setfenv(chunk, env)
      -- its first run (its load) under the hang watchdog with the time a mod's start gets (dog.start), as an HD2-Boot
      -- mod's: an endless loop there is stopped, and it isn't started. Its row is the watchdog's owner; it joins the
      -- boot scripts only once it ran (off before then, so the watchdog's next frame doesn't stop it a second time).
      local row = { owner = owner, file = b.file, env = env, errors = 0, on = true, title = title }
      local D = starter.dog
      local po, ps, pl, pn = D.enter(row, clock(), D.start)
      local okl, ok, err = pcall(starter.seeded, env, 'the boot script in ' .. b.file,
        function() return guarded(owner, 'load', function() chunk(); return true end) end)
      D.leave(po, ps, pl, pn)
      starter.unseed(env)
      if not okl then ok, err = nil, ok end
      if err ~= nil and ok == nil then
        row.on = false
        starter.never(owner, b.file, 'not started', 'failed to run: ' .. tr.why(err))
        log(fmt('the boot script in %s failed to run: %s', b.file, tr.why(err)))
      else
        boots[#boots + 1] = row
        -- full access, as the game would give it if it were deployed after me: locking it down would only
        -- break it (the file-mod installer swaps game files), and a boot that wants everything can take it anyway
        log(fmt('running another mod\'s boot script too, with full access as the game gives any boot script: %s (%s)',
          b.file, title))
        local okm, errm = pcall(starter.merger_note, b, title)
        if not okm then log('the file-mod merger check: ' .. tr.why(errm)) end
      end
    end
  end
end
-- A file-mod installer boot next to a file-mod merger program. The program writes the game's settings files itself,
-- with the game closed (its records and stock backups in a folder of its own in the game folder, where the game runs,
-- next to data\), and the installer swaps those same files for its own mods' copies when the game exits: whichever
-- wrote last wins. Both refuse to write over a file they don't recognize, so nothing breaks, and I still run the
-- installer as before; I only say so: in my log for each such boot, once on screen. Its file mods are the payloads in
-- the archives its own source names (ID_HIGH, ID_FIRST, ID_LAST), each with a name= line; the program's own merged
-- pack (a mod-manager zip it builds, the same installer inside) is only logged: that's the program used the other way.
function starter.merger_note(b, title)
  if not title:lower():find('file%-mod installer') then return end
  if scan.merger == nil then
    local f = open('MedicFileModMerger/log.txt', 'rb') or open('MedicFileModMerger/state.txt', 'rb')
    scan.merger = f and true or false
    if f then pcall(f.close, f) end
  end
  if not scan.merger then return end
  local function u32(s, i) local a, b2, c, d = byte(s, i, i + 3); return a + b2 * 256 + c * 65536 + d * 16777216 end
  -- a payload patch's table of contents (a few rows), then the name in the header of the resource that carries one
  local function payload(f)
    local head = f:read(72) or ''
    if #head ~= 72 or u32(head, 1) ~= 0xF0000011 then return end
    local nt, ne = u32(head, 5), u32(head, 9)
    if nt > 64 or ne > 64 then return end
    local toc = f:read(nt * 32 + ne * 80) or ''
    if #toc < nt * 32 + ne * 80 then return end
    for e = 0, ne - 1 do
      if f:seek('set', u32(toc, nt * 32 + e * 80 + 17) + 8) then
        -- (its magic in two pieces: my own source never carries it whole, so a tool that looks for it in the deployed
        -- boots never takes me for the installer)
        local h = f:read(10) or ''
        local n = #h == 10 and sub(h, 1, 6) == 'HD2' .. 'FM1' and u32(h, 7)
        if n and n <= 4096 then
          return ((('\n' .. (f:read(n) or '')):match('\nname=([^\r\n]+)') or '?'):sub(1, 60):gsub('%c', ' '))
        end
      end
    end
  end
  local high, first, last = b.src:match('ID_HIGH, ID_FIRST, ID_LAST = "(%x+)", (%d+), (%d+)')
  local mods, packs = {}, {}
  first, last = tonumber(first), tonumber(last)
  if high and #high == 14 and first and last then
    for n = first, min(last, first + 31, 255) do
      local misses = 0
      for i = 0, 63 do
        local file = fmt('%s%02x.patch_%d', high, n, i)
        local f = open('data/' .. file, 'rb')
        if not f then
          misses = misses + 1
          if misses > 2 then break end
        else
          misses = 0
          local ok, name = pcall(payload, f)
          pcall(f.close, f)
          if ok and name then
            local list = name:find('^Merged Pack %(') and packs or mods
            list[#list + 1] = name .. ' in ' .. file
          end
        end
      end
    end
  else
    mods[1] = 'its file mods (I couldn\'t read which)'
  end
  if #packs > 0 then
    log(fmt('the boot script in %s (%s) installs Medic File Mod Merger\'s own merged pack (%s), and the merger\'s ' ..
      'folder is in the game folder: use one of the two ways, the merger says not to use both at once', b.file, title,
      concat(packs, ', ')))
  end
  if #mods == 0 then return end
  log(fmt('the boot script in %s (%s) installs file mods from your mod manager, and Medic File Mod Merger manages ' ..
    'the game\'s settings files here (its MedicFileModMerger folder is in the game folder): both write the same files, ' ..
    'so untick these in your mod manager and deploy (the merger says a mod that also has other parts, like Lua, can ' ..
    'stay ticked: its file part just stays inactive): %s', b.file, title, concat(mods, ', ')))
  if not scan.merger_said then
    scan.merger_said = true
    notices[#notices + 1] = { text = 'A FILE-MOD INSTALLER MOD IS STILL DEPLOYED: MEDIC FILE MOD MERGER MANAGES THOSE ' ..
      'FILES (SEE ' .. FILES:upper() .. '.LOG)', dur = 8 }
  end
end
-- How I came to run, said once: the boot the game ran (the one in the highest-numbered patch) and my core's copies.
-- Boots carrying my marker are mine (my stub, a changed copy of it, or this loader built into a mod) and never run.
-- Started by require from a boot that isn't mine, I don't run that boot again (the game already did); the callbacks
-- it set before it loaded me (mine replaced them) run as its own, like any other boot script's.
function starter.started_how()
  local top
  for _, list in ipairs({ scan.mine, found_boots }) do
    for _, b in ipairs(list) do if not top or b.n > top.n then top = b end end
  end
  local others = {}
  for _, b in ipairs(scan.mine) do
    local ver = b.src:match("\nlocal VERSION = '([^'\n]+)'")
    b.stub = fingerprint(b.src) == scan.STUB
    b.kind = b.stub and 'my start-up stub'
      or ver and fmt('a full copy of %s %s', b.src:match("\nlocal LOADER = '([^'\n]+)'") or LOADER, ver)
      or 'a changed copy of my start-up stub'
    b.src = nil
    if b ~= top then others[#others + 1] = b.file .. ': ' .. b.kind end
  end
  local core = ''
  if #scan.cores > 0 then
    local hi = scan.cores[1]
    for _, c in ipairs(scan.cores) do if c.n > hi.n then hi = c end end
    core = fmt('; my core (%s) is in %s', hi.version, hi.file)
    if #scan.cores > 1 then
      local l = {}
      for _, c in ipairs(scan.cores) do l[#l + 1] = c.file .. ' ' .. c.version end
      core = core .. fmt(', the highest of %d copies (%s): the game loads that one', #scan.cores, concat(l, ', '))
    end
  end
  local mine = top and top.kind
  if not scan.via then
    log(fmt('start-up: running as the game\'s boot script%s%s', top and fmt(' (the boot in %s is %s)', top.file,
      mine or 'another mod\'s') or '', core))
  elseif not top then
    log('start-up: started as ' .. scan.CORE .. ', but no patch has a boot script' .. core)
  elseif top.stub then
    log(fmt('start-up: started by my start-up stub, the boot in %s%s', top.file, core))
  elseif mine then
    log(fmt('start-up: started by the boot in %s, %s: it isn\'t the stub I ship, and a changed copy may stop starting ' ..
      'me after an update (the mod that carries it should ship chef_loader_stub.lua unchanged)%s', top.file, mine, core))
  else
    top.title = (top.src:match('^%-%-%s*([^\r\n]+)') or 'no title'):sub(1, 90)
    top.fp = fingerprint(top.src)
    scan.ran = top
    log(fmt('start-up: started by the boot in %s (%s), which %s: the game already ran it, so I don\'t run it again%s',
      top.file, top.title, starter.handoff and 'handed off to me' or 'isn\'t my stub', core))
  end
  if #others > 0 then log('boot scripts of mine, not run: ' .. concat(others, ', ')) end
end
local function start_boots()
  local seen = {}
  local top = scan.ran
  if top then
    -- the boot that loaded me (the game ran it): only the callbacks it set before mine replaced them
    seen[top.fp] = true
    local owner, cb, n = 'boot:' .. top.fp, {}, 0
    for k, fn in pairs(scan.prev) do if type(fn) == 'function' then cb[k] = fn; n = n + 1 end end
    if off[owner] then
      starter.never(owner, top.file, 'kept off', off[owner].why)
      log(fmt('kept off: the boot script in %s (%s)', top.file, off[owner].why))
    elseif n > 0 then
      boots[#boots + 1] = { owner = owner, file = top.file, env = cb, errors = 0, on = true, title = top.title }
      log(fmt('running the callbacks the boot script in %s set before it started me (%d)', top.file, n))
    end
  end
  for _, b in ipairs(found_boots) do
    if b ~= top then
      local ok, err = pcall(starter.boot_one, b, seen)
      if not ok then log('starting the boot script in ' .. tostring(b.file) .. ' failed: ' .. tr.why(err)) end
    end
  end
end
-- one callback of every other boot script, after mine. Another mod's boot script isn't watched for hangs in its
-- shutdown: the file-mod installer swaps game files there, and a slow copy stopped half-way would leave a broken file
-- (the game is closing anyway). A boot-style loader mod (b.a) is watched there as in its other calls.
local function call_boots(hook, ...)
  for _, b in ipairs(boots) do
    local fn = b.on and rawget(b.env, hook)
    if type(fn) == 'function' then
      draw.color_scope()
      local t0 = clock()
      local D = starter.dog
      local po, ps, pl, pn
      if hook ~= 'shutdown' or b.a then po, ps, pl, pn = D.enter(b, t0) end
      local r1, err = guarded(b.owner, hook, fn, ...)
      D.leave(po, ps, pl, pn)
      local ms = (clock() - t0) * 1000
      b.pm_ms = (b.pm_ms or 0) + ms
      if ms > (b.pm_max or 0) then b.pm_max = ms end
      if r1 == nil and type(err) == 'string' and err ~= 'skipped' then
        b.errors = b.errors + 1
        if b.errors <= 3 then log(fmt('the boot script in %s: %s error: %s', b.file, hook, err)) end
        if b.errors >= MAX_ERRORS then
          b.on = false
          b.state, b.why, svc.ctx.health_dirty = 'stopped', 'after ' .. b.errors .. ' errors', true
          if b.a then starter.off(b.a) end   -- a boot-style mod's timers, watches, events and spawns stop with it
          log(fmt('the boot script in %s stopped after %d errors', b.file, b.errors))
          starter.stopped(b.owner, b.why)
        end
      end
    end
  end
end

-- The game's callbacks never run inside one another: a boot script that wraps mine at run time (it reads update after
-- it loaded, past its stand-in) and calls it from its own would run every mod again, nested, until the stack ran out.
-- A call to any of them that comes in while one of mine is running returns at once.
function update(dt)
  if st.down or st.busy then return end        -- (the game called shutdown(): nothing runs after it)
  st.busy = true
  if starter.handoff then pcall(starter.dog.take) end
  local ok, err = pcall(starter.update_body, dt)
  if starter.handoff then pcall(starter.dog.give) end
  st.busy = false
  if not ok then frame_error(err) end
end
function starter.update_body(dt)
  if type(dt) == 'number' and dt > 0 and dt < 10 then elapsed = elapsed + dt end
  local okd, errd = pcall(starter.dog.frame)     -- (mods that hung since the last update: switched off)
  if not okd then log('the hang watchdog: ' .. tr.why(errd)) end
  -- the performance monitor: the mods' time so far, so my own share of this update is what's left
  local pm = svc.util.pm.on and svc.util.pm_sum() or nil
  local t0 = clock()
  local ok, err = pcall(frame, dt)
  local ms = (clock() - t0) * 1000
  if pm then svc.util.pm.loader = svc.util.pm.loader + max(0, ms - (svc.util.pm_sum() - pm)) end
  st.ms, st.frames = st.ms + ms, st.frames + 1
  if ms > st.max then st.max = ms end
  if not ok then frame_error(err) end
  if #boots > 0 then
    ok, err = pcall(call_boots, 'update', dt)
    if not ok then frame_error(err) end
  end
end

function init()
  if st.inited then return end            -- (once: a loader that hands off can make it come twice)
  st.inited = true
  if #boots > 0 and not st.busy then
    st.busy = true
    if starter.handoff then pcall(starter.dog.take) end
    local ok, err = pcall(call_boots, 'init')
    if starter.handoff then pcall(starter.dog.give) end
    st.busy = false
    if not ok then frame_error(err) end
  end
end
function starter.render()
  for _, a in ipairs(addons) do run_hook(a, 'render') end
  if #boots > 0 then call_boots('render') end
end
function render()
  if st.down or st.busy then return end
  if #addons > 0 or #boots > 0 then
    st.busy = true
    if starter.handoff then pcall(starter.dog.take) end
    pcall(starter.dog.render)                  -- (a hook is per thread: the game may render on another than update's)
    local ok, err = pcall(starter.render)
    if starter.handoff then pcall(starter.dog.give) end
    st.busy = false
    if not ok then frame_error(err) end
  end
  -- the texts this frame didn't draw go now, not a frame late (and a render is noted for the text hold)
  if draw.nt.main or draw.nt.top or draw.nt.holding or draw.nt.reclaim_frame then
    local ok, err = pcall(draw.nt_sweep, 0)
    if not ok then frame_error(err) end
  end
end
-- Once only, and every step on its own pcall: one that fails doesn't keep the others from running, and the clean marker
-- is always the last line of the trace.
function shutdown()
  if st.down then return end
  st.down = true
  if starter.handoff then pcall(starter.dog.take) end
  for _, a in ipairs(addons) do pcall(run_hook, a, 'shutdown') end
  -- the other boot scripts' shutdown before the services close the mods' own logs and my trace closes (the file-mod
  -- installer does its work here)
  if #boots > 0 then pcall(call_boots, 'shutdown') end
  pcall(starter.health)
  pcall(svc.lang.flush, elapsed, true)
  pcall(svc.shutdown)
  pcall(svc.util.shutdown)
  pcall(log, 'shutdown (clean)')
  pcall(crumb, '#### clean shutdown')
  if trace then pcall(trace.close, trace); trace = nil end
  if log_file then pcall(log_file.close, log_file); log_file = nil end
  if starter.handoff then pcall(starter.dog.give) end
end

-- ------------------------------------------------------------------ start-up
log(fmt('==== %s %s%s starting', LOADER, VERSION, TEST and (' Test ' .. TEST) or ''))
-- started by another loader that handed off to me: its note says which (the callbacks it set first run after mine, as
-- its boot's: start_boots)
do
  local note = rawget(G, 'ChefSharedLoaderHandoff')
  if note ~= nil then
    rawset(G, 'ChefSharedLoaderHandoff', nil)
    local from = type(note) == 'table' and type(rawget(note, 'from')) == 'string' and (rawget(note, 'from'):sub(1, 60):gsub('%c', ' ')) or 'another loader'
    starter.handoff = from
    log('started by ' .. from .. ', which handed off to me')
    -- handed off from inside its init (phase 'init'): the game has called init already, so I call mine once I'm
    -- loaded, and its own init (the one running now) isn't called again
    if type(note) == 'table' and rawget(note, 'phase') == 'init' then chef_before.init_now = true; chef_before.cb.init = nil end
  end
end
-- What the game's Lua is, before I add anything (so the probe sees the game's own), then the LuaJIT parts it lacks.
do   -- (one ok/v pair: the loader is near Lua 5.1's 200 locals)
  local ok, v = pcall(probe.run, G, { timing = TEST ~= nil })
  if ok then
    v = probe.lines(v)
    for i = 1, #v, 8 do log('lua: ' .. concat(v, ' ', i, min(i + 7, #v))) end
  else
    log('lua probe failed: ' .. tr.why(v))
  end
  ok, v = pcall(compat.install, G)
  if ok and #v > 0 then log('added the LuaJIT parts this game lacks: ' .. concat(v, ', '))
  elseif ok then log('the game already has the LuaJIT parts addons use')
  else log('adding the LuaJIT parts failed: ' .. tr.why(v)) end
  ok, v = pcall(compat.mod_overrides, G)
  if ok and type(v) == 'table' then overrides = v end
  v = {}
  for k in pairs(overrides) do v[#v + 1] = k end
  sort(v)
  if #v > 0 then log('each addon gets LuaJIT\'s ' .. concat(v, ' and ')) end
end
-- the game's build: a refusal shared with every mod goes when it changes (an update may well have changed what crashed)
do
  local v = guarded('loader', 'Application.build_identifier', fn_of('Application.build_identifier'))
  tr.shared.now = (type(v) == 'string' or type(v) == 'number') and tostring(v):gsub('%s', '') or nil
  if tr.shared.now == '' then tr.shared.now = nil end
  if tr.shared.now and tr.shared.build and tr.shared.now ~= tr.shared.build then
    local gone = {}
    for k in pairs(skip) do if k:match('^shared|') then gone[#gone + 1] = k end end
    for _, k in ipairs(gone) do skip[k] = nil; dropped[#dropped + 1] = k end
    tr.shared.n = 0
  end
  -- (marked changed, too, on my first launch over an older version's state, even when nothing else changed: else every
  -- launch reads that version, takes me as moved and never shares a crash. Here tr.shared.moved is still only the
  -- version's; the build's is added below.)
  if tr.shared.now and tr.shared.now ~= tr.shared.build or tr.shared.moved then tr.state_dirty = true end
  -- (the game's build changed since the last launch, or isn't known now as it was: a crash from it isn't shared)
  if tr.shared.now ~= tr.shared.build then tr.shared.moved = true end
end
if #dropped > 0 then
  log('dropped ' .. #dropped .. ' skip(s) recorded by an older crash rule, an older version of me or another game build: ' ..
    concat(dropped, ', '))
  tr.state_dirty = true
end
-- My drawing (loader|draw:gui, :lines, :bitmaps, :top) is held for a world's whole life, so it's open whenever a game
-- dies soon after a mission loads, for whatever reason. It's never skipped for that: without it no mod draws
-- anything, and a draw call that really crashes is caught by its own first call anyway. (loader|draw:text is held only
-- from a frame's text calls to the next frame, and skipping it costs only the game's font, so it's blamed as a job.)
-- A launch that didn't shut down (a crash, or the game closed from outside) is said first, with when its trace last
-- saw it running and the last option changed in my menu: the blame below needs a first call that never returned or a
-- job held under RECENT s, and a crash anywhere else leaves nothing more to go on.
-- A trace can't tell a crash from the game being closed from outside (Task Manager, Steam's Stop): both just stop
-- writing, and a kill that lands while a call or job is open leaves it open exactly as a crash in it would. No crash
-- dump can settle it either: the game names its dumps with a random part, and my Lua can't list a folder. Two kills
-- landing in the same call two launches running is next to impossible (a first call is open for a moment once a
-- launch), while a call that crashes the game mostly does it again, so whatever was open is only suspected the first
-- time ("suspect: <key>": nothing skipped, counted or refused for every mod), and blamed when the next launch ends in
-- it too. Then both launches count against the mod: it's turned off a launch later than if one crash were enough.
if tr.crash_t then
  log('the last launch ended without a clean shutdown (a crash or the game being closed from outside)' ..
    (tr.crash_t > 0 and fmt('; its trace last saw it running at %d s', tr.crash_t) or '') ..
    (tr.crash_o and fmt('; the last option changed in my menu: %s at %d s', tr.crash_o, tr.crash_o_at) or ''))
end
if blamed and blamed_job and blamed:match('^loader|draw:') and blamed ~= 'loader|draw:text' then
  log('it ended within about a minute of a world loading, while my drawing (' .. blamed .. ') was held: that\'s held ' ..
    'for a world\'s whole life, so it doesn\'t point at the drawing, and drawing is never switched off for that')
  blamed = nil
end
if tr.crash_t and not blamed and not blamed_job then
  log('nothing of mine or a mod\'s was open in it to learn from (a call is tracked on its first run, a per-frame ' ..
    'job in its first ' .. RECENT .. ' s), so nothing is skipped or turned off for it')
end
if blamed and not suspect[blamed] then
  if blamed_job then
    log('the last launch ended while ' .. blamed .. ' was running; if the next one ends the same way, I skip it ' ..
      '(nothing is skipped or counted for it yet)')
  else
    log('the last launch ended inside ' .. blamed .. ' (a call that never returned): a crash in it and the game ' ..
      'closed from outside while it ran look the same, so nothing is skipped or counted for it yet; if the next ' ..
      'launch ends in it too, I skip it')
  end
  suspect = { [blamed] = true }
  -- (a launch that may have ended in a mod's own call or job isn't one it didn't end: its count is kept, none added)
  local owner = blamed:match('^([^|]+)|')
  if owner ~= 'loader' then tr.shared.struck = owner end
  blamed = nil
  save_state()
elseif not blamed and next(suspect) then
  suspect = {}
  tr.state_dirty = true
end
-- (here blamed is the one suspected at the launch before: two launches in a row ended in it)
if blamed then
  suspect = {}
  skip[blamed] = true
  local owner = blamed:match('^([^|]+)|')
  log('the last launch crashed in: ' .. blamed .. ' (the launch before it ended in it too; that call is skipped from now on)')
  -- (a language file's key carries its own fingerprint: skipping it is enough, no mod is turned off for it)
  if owner and owner ~= 'loader' and not blamed:match('^[^|]+|lang:%x+$') then
    -- the mod stays on (its call skipped) until it has ended tr.CRASH_STRIKES launches in a row; then it's turned off
    -- (I count it against the file that crashed, from its "f" line; without one, the next file found takes it). Both
    -- launches count: the one it was suspected of kept the count it had, and was its crash too.
    local s, cfp = tr.strikes[owner] or { n = 0 }, tr.crash_fps[owner] or 'pending'
    s.n, s.fp = s.n + 2, cfp
    tr.shared.struck, tr.shared.counted = owner, true
    if s.n >= tr.CRASH_STRIKES then
      tr.strikes[owner] = nil
      off[owner] = { fp = cfp, why = 'crashed the game in ' .. blamed:gsub('^[^|]+|', '') .. ' (' .. s.n .. ' launches in a row)' }
    else
      tr.strikes[owner] = s
      -- (a mod's count is said once its file is read, in starter.stays; a boot script never asks to stay on)
      if owner:match('^boot:') then starter.stays(owner, false) end
    end
    -- a call on one kind of unit (chef.call_kind; of my helpers only chef.lights passes the unit alone) that took only
    -- the unit is refused for every mod too, asked the same way: another mod asking it of that kind would end the game
    -- the same way (only the mod that found it has the crash counted). Not one with arguments of the mod's own (a bad
    -- node index is that mod's), nor a crash from before the loader or the game changed.
    local call, kind = blamed:match('^[^|]+|(Unit%.[%w_]+):(.+)$')
    local sk = call and tr.shared.single and not tr.shared.moved and tr.shared.key_of(call, kind)
    if sk and not skip[sk] then
      skip[sk] = true; tr.shared.n = tr.shared.n + 1
      log('refused for every mod from now on: ' .. sk:sub(8) .. ' (a change of the game\'s build or of me tries it again)')
    end
  end
  save_state()
end
-- every other mod didn't end the last launch: its count starts over (its line stays, at 0, while it has skipped calls
-- a change of its file tries again: not a language file's). Marked changed only when a count or a line really changed.
if next(tr.strikes) then
  for name, s in pairs(tr.strikes) do
    if name ~= tr.shared.struck then
      if s.n ~= 0 then s.n = 0; tr.state_dirty = true end
      local p, any = name .. '|', false
      for k in pairs(skip) do if sub(k, 1, #p) == p and not k:match('|lang:%x+$') then any = true; break end end
      if not any then tr.strikes[name] = nil; tr.state_dirty = true end
    end
  end
end
-- a call of my own that's skipped takes something away from every mod (the drawing, say): said on screen too, for as
-- long as it's skipped (an update of the loader clears it)
do
  local mine = {}
  for k in pairs(skip) do if k:match('^loader|') then mine[#mine + 1] = k end end
  if #mine > 0 then
    sort(mine)
    log('skipping ' .. #mine .. ' call(s) of my own that crashed the game: ' .. concat(mine, ', ') .. ' (an update of ' ..
      LOADER .. ' tries them again)')
    notices[#notices + 1] = { text = 'CHEF SHARED LOADER SKIPS A CALL THAT CRASHED (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
  end
end
-- Is anything holding handles from this world (a mod running, my GUIs, lines, icons or a scan)? Then World.time is
-- asked every frame, else 4 times a second (update_world).
world.busy = function()
  if job or draw.gui or draw.lines or top.gui or next(draw.icons) or #boots > 0 then return true end
  for _, a in ipairs(addons) do if a.on then return true end end
  return false
end

do   -- the start-up steps (in a block, with one ok/err pair: the loader is near Lua 5.1's 200 locals)
local ok, err = pcall(discover)
if not ok then log('addon search failed: ' .. tr.why(err)) end
log(fmt('found %d addon(s), %d boot-style script(s) and %d option file(s) in %d patch files (%.1f ms)', #found_addons,
  #found_named, #found_options, scan.files, scan.ms))
if scan.bad > 0 then log(fmt('%d patch file(s) or mod(s) skipped: not laid out the way I read them, or cut short', scan.bad)) end
if scan.big > 0 then log(fmt('%d Lua resource(s) over 4 MB not read (too big to be a mod)', scan.big)) end
if scan.huge > 0 then log(fmt('%d patch file(s) over 200,000 resources not read for mods (too big to hold a mod)', scan.huge)) end
if #scan.langs > 0 then
  ok, err = pcall(function()
    svc.lang.load(scan.langs)
    if svc.lang.row(svc.loader_option, svc.loader_get, svc.loader_put, svc.set_row) then draw.tr, draw.tr_keep, draw.lang = svc.lang.tr, svc.lang.keep, svc.lang end
  end)
  if not ok then log('language files: ' .. tr.why(err)) end
end
ok, err = pcall(starter.started_how)
if not ok then log('telling how I started failed: ' .. tr.why(err)) end
ok, err = pcall(svc.menu_key_note)
if not ok then log('telling my menu key failed: ' .. tr.why(err)) end
-- the line my start-up stub writes when it found my core but couldn't start it: said once here, then the file goes
if services.GAME_DIR then
  local p = services.GAME_DIR .. 'chef_loader_stub.txt'
  local f = open(p, 'r')
  if f then
    local okr, line = pcall(f.read, f, '*l')
    pcall(f.close, f)
    if okr and type(line) == 'string' and line ~= '' then log('the start-up stub could not start me before: ' .. line:sub(1, 300)) end
    if type(os_) == 'table' then pcall(os_.remove, p) end
  end
end
-- (dev mode, test builds only) loose files listed in chef_loader_dev.txt: each wins over a deployed mod of the same name
if TEST then
  ok, err = pcall(svc.dev_files)
  if ok and #err > 0 then
    for _, d in ipairs(err) do
      local list = d.kind == 'Addon' and found_addons or (d.kind == 'Boot' and found_named or found_options)
      if d.kind ~= 'Options' then for i = #list, 1, -1 do if list[i].name == d.name then table.remove(list, i) end end end
      list[#list + 1] = d
    end
    notices[#notices + 1] = { text = 'CHEF SHARED LOADER DEV MODE: ' .. #err .. ' FILE(S)', dur = 8 }
  elseif not ok then
    log('dev mode failed: ' .. tr.why(err))
  end
end
-- an addon blamed for the last crash is turned off (or has its crash counted) now that I know its fingerprint
for _, r in ipairs(found_addons) do
  local o = off[r.name]
  if o and o.fp == 'pending' then o.fp = fingerprint(r.src); tr.state_dirty = true end
  local st = tr.strikes[r.name]
  if st and st.fp == 'pending' then st.fp = fingerprint(r.src); tr.state_dirty = true end
end
starter.unfound()
-- what start-up changed in the state, saved once here, before any mod's code runs (a crash's blame and count were saved
-- the moment they were learned); nothing changed, nothing written
if tr.state_dirty then save_state() end
ok, err = pcall(svc.install_shims, G)
if not ok then log('the look-alikes failed: ' .. tr.why(err)) end
-- the locked-down space every loader mod runs in (after the compat parts and the look-alikes, which mods reach
-- through it); if it can't be set up, no loader mod starts
do
  local bok, sb = pcall(services.sandbox.install, { G = G, io = io_, os = os_, debug = rawget(G, 'debug'), log = log,
    DIR = DIR, GAME_DIR = services.GAME_DIR, OLD_DIR = services.OLD_DIR, FILES = FILES,
    overrides = overrides, guard_read = tr.guard_read, menu_open = function() return svc.menu_open() end })
  if bok and type(sb) == 'table' then
    svc.sandbox = sb
    log('mods run locked down: no programs, no native code or bytecode, files only in the game\'s folders (sandbox '
      .. services.sandbox.version .. ')')
    if svc.runtime then sb.on_global = svc.runtime.on_global end
    sb.module_of = svc.module_of           -- (package.loaded's fallback: the other addons' modules)
    starter.trust(sb)
  else
    log('the locked-down space for mods failed, so no loader mod starts: ' .. tr.why(sb))
    notices[#notices + 1] = { text = 'NO MODS STARTED (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
  end
  if services.MOVED then log('moved from %LOCALAPPDATA% to %APPDATA%\\Arrowhead\\Helldivers2: ' .. concat(services.MOVED, ', ')) end
end
-- (the hang watchdog, before the first mod's start, when there's any mod to start; in place of the hook of a loader
-- that handed off to me, for my start-up: its hook goes back at the end of it)
if starter.handoff then pcall(starter.dog.take) end
ok, err = pcall(starter.dog.arm, #found_addons + #found_named + #found_boots > 0)
if not ok then log('the hang watchdog failed to start: ' .. tr.why(err)) end
ok, err = pcall(start_addons)
if not ok then log('starting the addons failed: ' .. tr.why(err)) end
ok, err = pcall(start_named)
if not ok then log('starting the boot-style scripts failed: ' .. tr.why(err)) end
ok, err = pcall(start_boots)
if not ok then log('starting the other boot scripts failed: ' .. tr.why(err)) end
ok, err = pcall(starter.retry_rows)
if not ok then log('the crash recovery rows failed: ' .. tr.why(err)) end
ok, err = pcall(starter.updated_notice)
if not ok then log('telling which mods were updated failed: ' .. tr.why(err)) end
ok, err = pcall(svc.startup_done)
if not ok then log('after startup failed: ' .. tr.why(err)) end
svc.ctx.health_dirty = false
ok, err = pcall(starter.health)
if not ok then log('writing the health file failed: ' .. tr.why(err)) end
ok, err = pcall(svc.util.index_at_startup)
if not ok then log('the index at start-up failed: ' .. tr.why(err)) end
if starter.handoff then pcall(starter.dog.give) end

end
end)
if not loader_ok then
  local ok, why = pcall(tostring, loader_err)
  why = 'failed to start: ' .. (ok and type(why) == 'string' and why or 'an error that can\'t be shown as text')
  if not (loader_log and pcall(loader_log, why)) and type(print) == 'function' then pcall(print, '[Chef Shared Loader] ' .. why) end
end
if loader_ok and chef_before.init_now then init() end
