-- Chef Shared Loader - the game's `boot` script, replaced
-- Runs Lua mods on the game's plain Lua 5.1 (no LuaJIT, no ffi).
-- What it's built on:
--   * the game runs `boot` at start-up and calls its init/update/render/shutdown; its own boot does nothing
--   * Lua can read the deployed patch files (io), so I find addons myself: Lua resources whose text starts with
--     "-- HD2-Addon: mods/<author>/<name>", option resources starting with "-- HD2-Options: mods/<author>/<name>",
--     and boot-style scripts starting with "-- HD2-Boot: mods/<author>/<name>" (open to every mod author; see
--     docs/MODDING.md)
--   * loadstring runs them; every addon gets its own environment and a `chef` table of helpers
--   * some engine calls crash the whole game (a null read, not a Lua error) when given the wrong kind of unit or
--     a stale handle; a Lua pcall can't catch that. So every engine call the helpers make is guarded: the first
--     time a call is made I write a breadcrumb, and if the game dies the next launch reads it, skips that call and
--     turns off the addon that made it, saying so in the log and on screen.
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
local ALLOW = '^mods/[%w_%-]+/[%w_%-]+$' --@@ALLOW@@ any author's mods/<author>/<name> (mine still start first)
local VERSION = '1.0.1'
local TEST = nil --@@TEST@@               a test build's number (tools/build.py --test N); release: nil
local STABLE_FOR = 3                     -- seconds a main world must last before addons may draw in it
local MISSION_UNITS = 5000               -- a main world bigger than this is a mission (ship ~3,600-3,800, missions 4,900-16,000)
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

local G = _G
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

-- Is this already LuaJIT? Then its own bit, xpcall and load are the real thing and I stay out of the way.
local function is_luajit(G)
  return type(rawget(G, 'jit')) == 'table'
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
end)()
-- @@END services.lua@@
-- @@BEGIN utilities.lua@@ (copied from src/chef_loader/utilities.lua by tools/splice.py; edit that file, not this)
services.utilities = (function()
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
    function chef.mods()
      local out = {}
      for _, m in ipairs(L.addons) do
        -- (another mod's version read raw: its table can't raise into this call)
        local v = type(m.module) == 'table' and rawget(m.module, 'version') or nil
        out[#out + 1] = { name = m.name, kind = 'addon', on = m.on == true, dev = m.dev == true, file = m.file,
                          version = (type(v) == 'string' or type(v) == 'number') and tostring(v) or nil }
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
                mods = true }
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
--     and writes only .log .txt .json .csv .dat files in the loader's folder, never the loader's own files or another
--     mod's saved tables
-- It still can use: everything the engine's script API offers (stingray, Unit, World ...), the chef helpers,
-- os.clock/time/date/getenv, reading and writing its own files.
-- Each mod gets its own copies of string, table, math, coroutine, bit, os and debug, so one mod changing a library
-- function changes it only for itself. The checks below use functions taken before any mod runs, so no mod can bend
-- them.
-- A mod that replaces the game's boot script itself isn't a loader mod: the game hands it everything, with or without
-- me. Those run unrestricted (see loader.lua, "other mods' boot scripts").
-- Plain Lua 5.1 (no goto, no bit ops), like the rest of the loader.

local M = { version = '1.0.1' }

local type, pairs, ipairs, error, tostring, select, rawget, pcall = type, pairs, ipairs, error, tostring, select, rawget, pcall
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
-- FILES ('chef_loader'), overrides (compat's xpcall and load)
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
  setmetatable(base, { __index = G, __metatable = 'locked' })
  local env_mt = { __index = base, __metatable = 'locked' }

  -- One mod's environment. owner: its name, for the log.
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
    env.getmetatable = function(o)
      local mt = getmetatable(o)
      if mt ~= nil and mt == string_mt then return string_view end
      if type(o) == 'userdata' and io_type(o) then return nil end   -- file handles: their methods are shared
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
      said = said + 1
      if said <= 10 and ctx.log then
        ctx.log(s_format('blocked: %s tried to %s %s (%s): %s', owner, what, show(path), tostring(mode), why))
      end
      return nil, why
    end
    local io_c = {
      open = function(path, mode)
        local ok, root, names, ext = sb.check(path, mode)
        if not ok then return deny('open', path, mode, root) end
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
      type = io_type,
      close = function(f) if f ~= nil then return f:close() end end,
      write = function(...) return io_.write(...) end,
      popen = blocked('io.popen'), tmpfile = blocked('io.tmpfile'), input = blocked('io.input'),
      output = blocked('io.output'),
    }
    env.io = io_c

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

    env.require = function(name)
      local lib = REQUIRE_OK[name]
      if lib and env[lib] ~= nil then return env[lib] end
      if name == 'table.new' or name == 'table.clear' then
        local fn = env.table and env.table[s_sub(name, 7)]
        if fn then return fn end
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
end)()
-- @@END sandbox.lua@@
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

local log_file, log_written = nil, 0
local function log(text)
  if log_written > LOG_CAP then return end
  if not log_file then
    -- a fresh log each launch once it passes 1 MB
    local f = open(LOG_FILE, 'r')
    local big = false
    if f then local size = f:seek('end'); big = size and size > 1024 * 1024; f:close() end
    log_file = open(LOG_FILE, big and 'w' or 'a')
  end
  local line = fmt('%s %6.1f s | %s', now(), elapsed, text)
  log_written = log_written + #line + 1
  if log_written > LOG_CAP then line = line .. '\n(the log is full for this launch)' end
  if log_file then pcall(log_file.write, log_file, line .. '\n'); pcall(log_file.flush, log_file)
  elseif type(print) == 'function' then pcall(print, '[' .. LOADER .. '] ' .. line) end
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
-- <reason>" (an addon I turned off; it comes back on its own when its file changes, i.e. an update).
-- "rule: 3": a first call that never returned is skipped at once (that one is certain). A per-frame job (drawing, a
-- scan) running when the game died is only suspected the first time ("suspect: <key>") and skipped if the next launch
-- dies in it again: a game that ends for its own reasons mid-frame mustn't switch a feature off for good. Skips from
-- the older rules are dropped once (except rule 2's certain ones). "version: <v>": the loader that wrote it. My own
-- skips (loader|...) are dropped when the loader changes: an update may well have fixed what crashed, and a skip of
-- mine can take away the drawing for every mod.
local RULE = '3'
local skip, off, dropped, suspect = {}, {}, {}, {}
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
      local k = line:match('^skip: (.+)$')
      if k then old[#old + 1] = k end
      local sp = line:match('^suspect: (.+)$')
      if sp then suspect[sp] = true end
      local name, fp, why = line:match('^off: (%S+) (%S+) (.*)$')
      if name then off[name] = { fp = fp, why = why } end
    end
    f:close()
    for _, k in ipairs(old) do
      -- rule 2's skips stay, except a job's (loader|draw:...): those were blamed on one exit, which rule 3 doesn't do
      local keep = rule == RULE or (rule == '2' and not k:match('|draw:'))
      if keep and ver ~= VERSION and k:match('^loader|') then keep = false end
      if keep then skip[k] = true else dropped[#dropped + 1] = k end
    end
  end
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
    local out = { 'rule: ' .. RULE, 'version: ' .. VERSION }
    for k in pairs(suspect) do out[#out + 1] = 'suspect: ' .. k end
    local keys = {}
    for k in pairs(skip) do keys[#keys + 1] = k end
    sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = 'skip: ' .. k end
    local names = {}
    for n in pairs(off) do names[#names + 1] = n end
    sort(names)
    for _, n in ipairs(names) do out[#out + 1] = 'off: ' .. n .. ' ' .. off[n].fp .. ' ' .. off[n].why end
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
-- "> owner|call" / "< owner|call" = making that call for the first time / it returned (blamed if it never returned);
-- ">> owner|job @<s>" / "<< owner|job" = a per-frame job (blamed if still open and started within RECENT s);
-- "#### clean shutdown" = the game called shutdown(): nothing to blame.
local blamed, blamed_job = nil, false
do
  local f = open(TRACE_FILE, 'r')
  if f then
    local firsts, opened, order, last_t, clean = {}, {}, {}, 0, false
    for line in f:lines() do
      if line:match('^#### clean shutdown') then clean = true end
      local t = line:match('^t (%d+)$')
      if t then last_t = tonumber(t) end
      local o, at = line:match('^>> (.-) @(%d+)$')
      if o then opened[o] = tonumber(at); order[#order + 1] = o; last_t = max(last_t, tonumber(at)) end
      local c = line:match('^<< (.+)$')
      if c then opened[c] = nil end
      -- first calls can nest (an addon's first update makes first calls of its own), so they're a stack
      local b = line:match('^> (.+)$')
      if b then firsts[#firsts + 1] = b end
      local r = line:match('^< (.+)$')
      if r then for i = #firsts, 1, -1 do if firsts[i] == r then table.remove(firsts, i); break end end end
    end
    f:close()
    if not clean then
      blamed = firsts[#firsts]
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
-- The trace only has to tell the next launch what was open when the game died. When it passes 200 KB I write it
-- again with only that: the last time stamp, the jobs held (">> key @s") and the first calls that haven't returned.
local tr = { bytes = 0, firsts = {}, last_tick = -1, cap = 200 * 1024, said = false }
-- An error as text for the log, whatever it is: an error object whose __tostring fails mustn't raise again in here.
-- (A field, not a local: the loader is near Lua 5.1's 200 locals.)
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
local function crumb(line)
  -- one breadcrumb is one line: a mod's text in a key (chef.call_kind's kind) can't add lines of its own and make the
  -- next launch blame another mod or a loader job
  if line:find('%c') then line = line:gsub('%c', '?') end
  if not trace then return end
  local c2 = sub(line, 1, 2)
  if c2 == '> ' then tr.firsts[#tr.firsts + 1] = sub(line, 3)
  elseif c2 == '< ' then
    local k = sub(line, 3)
    for i = #tr.firsts, 1, -1 do if tr.firsts[i] == k then table.remove(tr.firsts, i); break end end
  end
  tr.bytes = tr.bytes + #line + 1
  if tr.bytes > tr.cap then
    pcall(trace.close, trace)
    trace = open(TRACE_FILE, 'w')
    if not trace then tr.failed(); return end
    local out = {}
    if tr.last_tick >= 0 then out[#out + 1] = 't ' .. tr.last_tick end
    for k, at in pairs(held) do out[#out + 1] = fmt('>> %s @%d', k, at) end
    for _, k in ipairs(tr.firsts) do out[#out + 1] = '> ' .. k end
    local text = concat(out, '\n') .. (#out > 0 and '\n' or '')
    tr.bytes = #text
    local okw, w = pcall(trace.write, trace, text)
    if not (okw and w) then tr.failed() end
    -- a first call is already in the list I just wrote (twice would leave it open for the next launch)
    if c2 == '> ' then pcall(trace.flush, trace); return end
    tr.bytes = tr.bytes + #line + 1
  end
  local okw, w = pcall(trace.write, trace, line .. '\n')
  local okf, fl = pcall(trace.flush, trace)
  if not (okw and w and okf and fl) then tr.failed() end
end
local function tick()   -- a time stamp in the trace every 10 s while a job is held, so "started within RECENT s" can be judged
  local t = floor(elapsed)
  if t < tr.last_tick + 10 then return end
  -- PERF: only while a held job isn't yet shown older than RECENT by a stamp already written (after that, more stamps
  -- change nothing the next launch can blame, so a GUI held all mission long writes none)
  for _, at in pairs(held) do
    if tr.last_tick - at <= RECENT then tr.last_tick = t; crumb('t ' .. t); return end
  end
end

-- ------------------------------------------------------------------ guarded engine calls
-- "Table.function" split once per name (the engine's tables are looked up each time, so a replaced one is seen)
local split = {}
local starter_no_global = { CowboyBingusModLoader = true, ModOptionsMenu = true }
local function fn_of(name)
  local sp = split[name]
  if sp == nil then
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
  if not t then t = {}; keycache[owner] = t end
  local k = t[key]
  if not k then k = owner .. '|' .. key; t[key] = k end
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
local function hold(key, on)
  if on and not held[key] then held[key] = floor(elapsed); crumb(fmt('>> %s @%d', key, held[key]))
  elseif not on and held[key] then held[key] = nil; crumb('<< ' .. key) end
end

-- ------------------------------------------------------------------ discovery
-- Patch archive layout (as my build tools write it and Arsenal deploys it): 72-byte header (0xF0000011, type
-- count, entry count, ...), 32-byte type rows, 80-byte entries (id, type, offset, stream offset, gpu offset,
-- 2 unused: u64; then size: u32 ...). A Lua resource: u32 length, u32 flag (2 = source text), then the text.
-- scan.big: Lua resources over MAX_LUA I didn't read; scan.said: the skipped headers already in the log
local found_addons, found_options, found_boots, scan = {}, {}, {}, { files = 0, ms = 0, bad = 0, seq = 0, big = 0, said = {} }
local found_named = {}                 -- "-- HD2-Boot: mods/<author>/<name>" scripts (boot-style, run alongside)
local discover
do   -- (the reading parts in a block: the loader is near Lua 5.1's 200 locals)
local LUA_TYPE = { 0xe2, 0x17, 0xd1, 0x2c, 0xfa, 0x8d, 0x4e, 0xa1 }
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
  if nt > 4096 or ne > MAX_ENTRIES then scan.bad = scan.bad + 1; return end
  local toc = f:read(nt * 32 + ne * 80) or ''
  if #toc < nt * 32 + ne * 80 then scan.bad = scan.bad + 1; return end
  for e = 0, ne - 1 do
    local at = nt * 32 + e * 80 + 1
    if is_lua(toc, at + 8) then
      local off, size = u64(toc, at + 16), u32(toc, at + 56)
      if size > MAX_LUA then scan.big = scan.big + 1 end
      if size >= 8 and size <= MAX_LUA and sub(toc, at, at + 7) == BOOT_ID and f:seek('set', off) then
        -- another mod's boot script (the game runs only the last one deployed): kept to run alongside mine, unless
        -- it's a copy of this loader (another mod with it built in)
        local src = f:read(size) or ''
        if #src == size and u32(src, 5) == 2 and not src:find('--@@LOADER@@', 1, true) then
          found_boots[#found_boots + 1] = { file = name:match('[^/]+$'), src = sub(src, 9) }
        end
      elseif size >= 8 and size <= MAX_LUA and f:seek('set', off) then
        local first = f:read(min(size, 120)) or ''
        if #first >= 8 and u32(first, 5) == 2 then
          -- a text editor's UTF-8 mark in front of the header is dropped (Lua 5.1 can't read past it either)
          local bom = sub(first, 9, 11) == '\239\187\191' and 3 or 0
          local kind, mod = first:sub(9 + bom):match('^%-%- HD2%-(%a+): ([%w_/%.%-]+)')
          local known = kind == 'Addon' or kind == 'Options' or kind == 'Boot'
          if mod and not (known and mod:match(ALLOW)) and not scan.said[kind .. ' ' .. mod] then
            scan.said[kind .. ' ' .. mod] = true
            log(fmt('skipped "-- HD2-%s: %s" in %s: %s', kind, mod, name:match('[^/]+$'), known
              and 'the name must be mods/<author>/<name> (letters, digits, _ and -)' or 'HD2-Addon, HD2-Boot or HD2-Options was expected'))
          end
          if mod and known and mod:match(ALLOW) and f:seek('set', off + 8 + bom) then
            local src = f:read(size - 8 - bom) or ''
            if #src ~= size - 8 - bom then scan.bad = scan.bad + 1
            else
              local list = kind == 'Addon' and found_addons or (kind == 'Boot' and found_named or found_options)
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
      if misses > 40 then break end
    else
      misses = 0
      scan.files = scan.files + 1
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
-- Is it a mission? A world over MISSION_UNITS always is. A smaller one is a mission when the loot probe finds mission
-- loot in it (kinds addons name with chef.mission_kinds: samples, medals and the like, which the ship never has);
-- missions under MISSION_UNITS exist (about 4,900 units, the ship about 3,600). Leaving: when a mission's unit count drops
-- PROBE_DROP below its peak I stop calling it a mission at once (no drawing on what may be the ship) and probe: loot
-- still there means it was only the mission thinning out, and it carries on as the same mission.
local world = { main = nil, since = 0, time = -1, time_at = 0, id = 0, instance = 0, stable = false, mission = false, units = 0,
                busy = function() return true end }      -- busy: replaced further down (anything holding handles?)
local mission_kinds, kinds_from = {}, {}     -- kinds_from: the addons that named them (probing stops when they're off)
local new_world_hooks = {}
local function world_changed()
  for _, fn in ipairs(new_world_hooks) do fn() end
end
local function can_probe()
  if skip['loader|scan'] then return false end
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
    if was_stable then world_changed() end
  end
  if ask then world.time = type(t) == 'number' and t or -1 end
  if not world.stable and elapsed - world.since >= STABLE_FOR then
    world.stable = true
    world.id = world.id + 1
    world_changed()
    local n = api('World.num_units', main)
    world.units = type(n) == 'number' and n or 0
    world.mission = world.units > MISSION_UNITS
    world.peak, world.probe_k, world.probe_last, world.probe_said, world.probe_done_t = world.units, 0, nil, false, nil
    world.last_n = world.units
    world.probe_at = (not world.mission and can_probe() and world.units >= PROBE_MIN) and elapsed or nil
    world.recheck, world.flip = elapsed + 2, 0
    log(fmt('world %d: %s (%d units)', world.id, world.mission and 'mission' or
      ((can_probe() and world.units >= PROBE_MIN) and 'not a mission yet' or 'not a mission'), world.units))
  elseif world.stable and elapsed >= (world.recheck or 0) then
    -- The game keeps the same main world after a mission (the ship is loaded into it), so I look at its size every
    -- 2 s; a change of verdict makes it a new world as far as addons are concerned (new id; the same instance).
    world.recheck = elapsed + 2
    local n = api('World.num_units', main)
    if type(n) ~= 'number' or world.probing then return end
    local before = world.last_n or n
    world.last_n = n
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
  return d
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
  if cam.unit and api('Unit.alive', cam.unit) == true then cam.data = cam_from(cam.unit) end
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

local keys = {}
local function key_index(name)
  local k = keys[name]
  if k == nil then k = api('Keyboard.button_index', name) or false; keys[name] = k end
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
-- rect comes out white), so the cache starts empty every frame.
local color_frame = -1
local function color(r, g, b, a)
  if color_frame ~= frame_no then   -- emptied in place: no new tables every frame
    color_frame = frame_no
    compat.table_clear(draw.colors); compat.table_clear(draw.keys); compat.table_clear(draw.ui_colors)
  end
  local key = r * 16777216 + g * 65536 + b * 256 + (a or 255)
  local c = draw.colors[key]
  if c == nil then
    c = api('Color', a or 255, r, g, b) or false; draw.colors[key] = c
    if c then draw.keys[c] = key end
  end
  return c or nil
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
local function ui_color(c, tint)
  local key = draw.keys[c]
  if not key then return c end
  local ck = tint and -key or key
  local u = draw.ui_colors[ck]
  if u == nil then
    local v = ui_conv[ck]
    if not v then v = ui_convert(key, tint); ui_conv[ck] = v end
    u = api('Color', v[1], v[2], v[3], v[4]) or c
    draw.ui_colors[ck] = u
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
-- or a new screen size, else at most every 30 s (a file that can't be read waits as long). cfg.n counts the texts
-- read, so a reader only parses a new one. A file that doesn't parse (the game may be writing it) keeps the last answer.
local cfg = { text = nil, n = 0, at = -100, scale = nil, scale_n = 0 }
local function cfg_text()
  if elapsed < cfg.at + 30 then return cfg.text, cfg.n end
  cfg.at = elapsed
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
local function file_scale()
  local text, n = cfg_text()
  if n == cfg.scale_n then return cfg.scale end
  cfg.scale_n = n
  local rw, rh = text:match('[%s{]render_resolution%s*=%s*%[%s*(%d+)%s+(%d+)%s*%]')
  local sw, sh = text:match('\nscreen_resolution%s*=%s*%[%s*(%d+)%s+(%d+)%s*%]')
  rw, rh, sw, sh = tonumber(rw), tonumber(rh), tonumber(sw), tonumber(sh)
  if not (rw and rh and sw and sh and sw > 0 and sh > 0 and rw > 0 and rh > 0) then return cfg.scale end
  local s = rh / sh
  cfg.scale = (s > 0.2 and s < 0.98 and math.abs(rw / rh - sw / sh) < 0.03 * (sw / sh)) and s or nil
  return cfg.scale
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
      if w ~= draw.w or h ~= draw.h then cfg.at = -100 end
      local s = file_scale()
      local ui = s ~= nil
      if w ~= draw.w or h ~= draw.h or ui ~= draw.ui or not draw.said then
        draw.w, draw.h, draw.ui, draw.said = w, h, ui, true
        log(fmt('screen %dx%d, render scale %s: drawing in %s', w, h, s and fmt('%.3f', s) or 'native',
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

-- The top: the first world that isn't the main one, drawn on top
-- of the game's map. Anything drawn at layer 2000 or up goes there (at its layer - 1000). I check every frame that
-- something is drawn there that it's still the same world (and the world count hasn't changed); if not, I drop my
-- GUIs without touching them, because a GUI used after its world went away crashes the game.
local TOP_FROM = 2000
local top = { world = nil, n = 0, wid = -1, gui = nil, icons = {}, frame = -1 }
local function top_drop()
  hold('loader|draw:top', false)
  top.world, top.gui, top.icons = nil, nil, {}
end
local function top_world()
  if skip['loader|draw:top'] or not world.stable then return nil end
  if top.frame == frame_no then return top.world end
  top.frame = frame_no
  local ws = api('Application.worlds')
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
  if layer >= TOP_FROM then g = top_gui(); layer = layer - 1000
  elseif draw.ui then g = top_gui(); layer = draw.ui_base + layer - 900; if not draw.raw then c = ui_color(c) end
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
-- plus the layer. If the engine refuses it, draw.tri_ok goes false
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
  draw_world_reset()
  local g
  if layer >= TOP_FROM then g = top_gui(); layer = layer - 1000
  elseif draw.ui then g = top_gui(); layer = draw.ui_base + layer - 900; c = ui_color(c)
  else g = gui() end
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

local function text_width(text, px) return #text * 6 * px - px end
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
  if fast_rect and world.stable and type(str) == 'string' and type(x) == 'number' and type(y) == 'number'
     and type(px) == 'number' and (layer == nil or type(layer) == 'number') then
    local l, cc = layer or 900, c
    draw_world_reset()
    local g
    if l >= TOP_FROM then g = top_gui(); l = l - 1000
    elseif draw.ui then g = top_gui(); l = draw.ui_base + l - 900; if not draw.raw then cc = ui_color(cc) end
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

local function line(x1, y1, z1, x2, y2, z2, c)
  if not world.stable or not c or not (draw.finite(x1, y1, z1, x2, y2) and draw.finite(z2)) then return end
  draw_world_reset()
  if skip['loader|draw:lines'] then return end
  if draw.lines == nil then
    draw.lines = api('World.create_line_object', world.main) or false
    if draw.lines then hold('loader|draw:lines', true) end
  end
  if not draw.lines then return end
  if not draw.lines_used then api('LineObject.reset', draw.lines); draw.lines_used = true end
  local a, b = api('Vector3', x1, y1, z1), api('Vector3', x2, y2, z2)
  if a and b then api('LineObject.add_line', draw.lines, c, a, b) end
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
local fast_bitmap, ui_mat_id, ui_mat_frame = nil, nil, -1
local function bitmap_fast(g, mat, x, y, w, h, c, layer)
  local V3, V2 = S.Vector3, S.Vector2
  return S.Gui.bitmap(g, mat, V3(x, y, layer), V2(w, h), c)
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
    if layer >= TOP_FROM then layer = layer - 1000 else layer = draw.ui_base + layer - 900 end
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
    local p, sz = api('Vector3', x, y, layer), api('Vector2', w, h)
    local a0, a1 = api('Vector2', u0, v0), api('Vector2', u1, v1)
    if not (p and sz and a0 and a1) then return false end
    local _, err = api('Gui.bitmap_uv', e.gui, id64(UI_MATERIAL), a0, a1, p, sz, c)
    if err and not icon_notes['uv'] then icon_notes['uv'] = true; log('sprite sheets: Gui.bitmap_uv refused (' .. tostring(err) .. ')') end
    return not err
  end
  -- like rects: once the breadcrumbed calls proved Vector3, Vector2 and Gui.bitmap, one pcall straight through (an
  -- addon's numbers can be a few hundred bitmaps a frame)
  if fast_bitmap then
    -- the material id made fresh once a frame (the engine's value types can be one-frame temporaries, like Color)
    if ui_mat_frame ~= frame_no then
      ui_mat_frame = frame_no
      local ok, v = pcall(S.IdString64.from_hex, UI_MATERIAL)
      ui_mat_id = ok and v or nil
    end
    if ui_mat_id and pcall(bitmap_fast, e.gui, ui_mat_id, x, y, w, h, c, layer) then return true end
    fast_bitmap = false
    return false
  end
  local p, sz = api('Vector3', x, y, layer), api('Vector2', w, h)
  if not (p and sz) then return false end
  local _, err = api('Gui.bitmap', e.gui, id64(UI_MATERIAL), p, sz, c)
  if not err and fast_bitmap == nil then
    fast_bitmap = true
  end
  return not err
end

local function draw_flush()
  -- nothing drawn on top for half a second (the map closed): I give the top world's GUIs back, so they don't pile up
  -- over a session and a crash long after isn't put on them
  if top.world and frame_no - top.frame > 30 then
    local ws, alive = api('Application.worlds'), false
    if type(ws) == 'table' and #ws == top.n and top.wid == world.id then
      for i = 1, #ws do if ws[i] == top.world then alive = true; break end end
    end
    if alive then
      if top.gui then api('World.destroy_gui', top.world, top.gui) end
      for _, e in pairs(top.icons) do if e then api('World.destroy_gui', top.world, e.gui) end end
    end
    top_drop(); top.frame = -1
  end
  if draw.lines and draw.lines_used and world.stable and draw.world == world.id then
    api('LineObject.dispatch', world.main, draw.lines)
  end
  draw.lines_used = false
end

-- ------------------------------------------------------------------ addons
local addons, notices = {}, {}
-- the shared services every mod gets (src/chef_loader/services.lua): after_startup, capabilities, saved settings, shared
-- values and events, require, key bindings, the options menu, the look-alikes, dev mode (test builds)
local svc = services.install({ log = log, guarded = guarded, fn_of = fn_of, open = open, DIR = DIR, FILES = FILES, LOADER = LOADER,
  OLD_DIR = services.OLD_DIR ~= DIR and services.OLD_DIR or nil,
  VERSION = VERSION, ALLOW = ALLOW, TOP = TOP_FROM, world = world, color = color, rect = rect, text = text, text_width = text_width,
  screen = function() draw_world_reset(); return draw.w, draw.h end,
  key_pressed = function(name)
    local k = key_index(name)
    return k and guarded('loader', 'Keyboard.pressed', fn_of('Keyboard.pressed'), k) == true or false
  end,
  now = function() return elapsed end, clock = now, LOG_CAP = LOG_CAP,
  addon = function(name) for _, a in ipairs(addons) do if a.name == name then return a end end end,
  dev_reload = function() end })
-- the utilities (src/chef_loader/utilities.lua): safe unit access, spawning with clean-up, timers, session and
-- settings, shapes, sprite sheets, notify, typed text, saved tables, the mod list
svc.util = services.utilities.install(svc.ctx, { api = api, xyz = xyz, rect = rect, bitmap = bitmap, key_index = key_index,
  raw = function(on) draw.raw = on == true end, ui = function() return draw.ui end,
  tri = function(...) return draw.tri(...) end, tri_ok = function() return draw.tri_ok end,
  notify = function(n) notices[#notices + 1] = n end,
  notes_of = function(o) local k = 0; for _, n in ipairs(notices) do if n.owner == o then k = k + 1 end end return k end,
  addons = addons, boots = function() return svc.ctx.boots or {} end, frame_no = function() return frame_no end,
  clock = clock, os = os_, new_world_hooks = new_world_hooks, bad_kinds = res.bad, settings_text = cfg_text,
  found = function()
    local t = {}
    for _, r in ipairs(found_addons) do t[#t + 1] = r.name end
    for _, r in ipairs(found_named) do t[#t + 1] = r.name end
    return t
  end })
-- my own row in the options menu: the frame budget behind chef.budget
svc.util.budget_row = svc.loader_option('budget', { type = 'slider', label = 'Budget warning (ms)', min = 0.5, max = 10,
  step = 0.5, default = 2 })
-- and the performance monitor (utilities: each mod's cost, drawn once a second's numbers are in)
svc.util.perf_row = svc.loader_option('perf', { type = 'toggle', label = 'Performance monitor', default = false })
local function options_for(name)
  local o = {}
  for _, r in ipairs(found_options) do
    if r.name == name then
      local chunk = loadstring(r.src, '@' .. r.name .. ' (options in ' .. r.file .. ')')
      local ok, t = false, nil
      -- an options file is just a table: it runs with nothing to reach (breadcrumbed like a hook: one that ends the
      -- game is skipped from the next launch on, and its mod stays off until it's updated)
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
  function chef.call_kind(name, kind, ...)
    local t = kind_keys[name]
    if not t then t = {}; kind_keys[name] = t end
    local key = t[kind]
    if not key then key = name .. ':' .. kind; t[kind] = key end
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
  function chef.key_down(name)
    local k = key_index(name)
    if not k then return false end
    local v = guarded(owner, 'Keyboard.button', fn_of('Keyboard.button'), k)
    return type(v) == 'number' and v > 0.5
  end
  -- is this a key name the game knows? (Keyboard.button_index gives nothing for an unknown name)
  function chef.key_known(name) return key_index(name) and true or false end
  function chef.key_pressed(name)
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
  -- the mouse wheel this frame (0 when it didn't move); the game's map zooms with it
  local wheel_ix = nil
  function chef.wheel()
    if wheel_ix == nil then wheel_ix = guarded(owner, 'Mouse.axis_index', fn_of('Mouse.axis_index'), 'wheel') or false end
    if not wheel_ix then return 0 end
    local v = guarded(owner, 'Mouse.axis', fn_of('Mouse.axis'), wheel_ix)
    if v == nil then return 0 end
    local _, y = guarded(owner, 'Vector3.to_elements', fn_of('Vector3.to_elements'), v)
    return type(y) == 'number' and y or 0
  end
  -- the mouse cursor (window pixels, as the engine gives them) and a mouse button held ('left', 'right', ...)
  local cursor_ix, mouse_ix = nil, {}
  function chef.cursor()
    if cursor_ix == nil then cursor_ix = guarded(owner, 'Mouse.axis_index', fn_of('Mouse.axis_index'), 'cursor') or false end
    if not cursor_ix then return nil end
    local v = guarded(owner, 'Mouse.axis', fn_of('Mouse.axis'), cursor_ix)
    if v == nil then return nil end
    local x, y = guarded(owner, 'Vector3.to_elements', fn_of('Vector3.to_elements'), v)
    if type(x) == 'number' and type(y) == 'number' then return x, y end
  end
  function chef.mouse_down(name)
    local k = mouse_ix[name]
    if k == nil then k = guarded(owner, 'Mouse.button_index', fn_of('Mouse.button_index'), name) or false; mouse_ix[name] = k end
    if not k then return false end
    local v = guarded(owner, 'Mouse.button', fn_of('Mouse.button'), k)
    return type(v) == 'number' and v > 0.5
  end
  chef.TOP = TOP_FROM
  chef.color, chef.text_width = color, text_width
  function chef.rect(x, y, w, h, c, layer) rect(x, y, w, h, c, layer) end
  function chef.text(x, y, s, px, c, layer) return text(x, y, s, px, c, layer) end
  function chef.sprite(x, y, rows, cell, colors, layer) sprite(x, y, rows, cell, colors, layer) end
  function chef.bitmap(tex, x, y, w, h, c, layer) return bitmap(tex, x, y, w, h, c, layer) end
  function chef.line(x1, y1, z1, x2, y2, z2, c) line(x1, y1, z1, x2, y2, z2, c) end
  svc.extend(chef, a)
  svc.util.extend(chef, a)
  return chef
end

-- the start-up steps for one mod and switching one off (a table: the loader is near Lua 5.1's 200 locals)
local starter = {}
-- A mod that stops (switched off after errors, or a start that failed half-way): it's off for the session, its watches
-- and loot kinds go, and the services forget it (no more events or change callbacks to it; its timers, jobs and what it
-- spawned go too).
function starter.off(a)
  a.on = false
  if a.forgotten then return end
  a.forgotten = true
  for i = #watchers, 1, -1 do if watchers[i].a == a then table.remove(watchers, i) end end
  for i = #kinds_from, 1, -1 do if kinds_from[i] == a then table.remove(kinds_from, i) end end
  local ok, err = pcall(svc.forget, a.name)
  if not ok then log('forgetting ' .. a.name .. ' failed: ' .. tr.why(err)) end
end

-- A mod's time is summed here (its hooks; its timers and spread jobs in the utilities) and divided by the loader's own
-- frame count in the status line.
-- A mod's update/render/shutdown are looked up in its module at every call (rawget: it can't raise, and a mod may set
-- replace or remove one after it started); a.hooks, read once at start, only serves a module with a metatable (its
-- hooks may come through __index). The first call of each is breadcrumbed like an engine call ("<mod>|update"): a mod whose own code ends
-- the game is blamed and stays off from the next launch on. a.ran: hook -> its crash key once called, false when it's
-- skipped.
local function run_hook(a, hook, ...)
  local ran = a.on and a.ran
  if not ran then return end
  local fn = rawget(a.module, hook)
  if fn == nil and a.hooks_mt then fn = a.hooks[hook] end
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
  local t0 = clock()
  local ok, err = pcall(fn, ...)
  local ms = (clock() - t0) * 1000
  if first then crumb('< ' .. k) end
  a.ms = a.ms + ms
  if ms > a.max_ms then a.max_ms = ms end
  a.pm_ms = (a.pm_ms or 0) + ms
  if ms > (a.pm_max or 0) then a.pm_max = ms end
  if not ok then
    a.errors = a.errors + 1
    if a.errors <= 3 then log('[' .. a.short .. '] ' .. hook .. ' error: ' .. tr.why(err)) end
    if a.errors >= MAX_ERRORS then
      starter.off(a)
      log('switched off ' .. a.name .. ' for this session after ' .. a.errors .. ' errors')
      notices[#notices + 1] = { text = a.short:upper():gsub('_', ' ') .. ' STOPPED AFTER ERRORS', dur = 20 }
    end
  end
end
-- A mod's module read once, each field on its own pcall (a "strict" module raises on a field it doesn't have, and one
-- missing hook mustn't lose the others): its hooks and its version (a.version, text or nil).
function starter.get(t, k) return t[k] end
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
-- A mod's locked-down space (src/chef_loader/sandbox.lua), with the look-alikes (CowboyBingusModLoader,
-- ModOptionsMenu) as its own copies, not the shared ones
function starter.env_for(name)
  local env = svc.sandbox.env(name)
  local bind = services.bind_lookalikes or svc.bind_lookalikes
  if type(bind) == 'function' then
    local ok, err = pcall(bind, env, name)
    if not ok then log('the look-alikes for ' .. name .. ' failed: ' .. tr.why(err)) end
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
      if not (d and d.on and type(d.module) == 'table') then return false, 'needs ' .. q.name .. ' (not installed or not running)' end
      if q.version and not services.version_at_least(d.version, q.version) then
        return false, fmt('needs %s %s or newer (%s is installed)', q.name, q.version, tostring(d.version))
      end
    end
  end
  return true
end
function starter.addon(r)
  local a = { name = r.name, short = r.name:match('([^/]+)$'), file = r.file, fp = fingerprint(r.src),
              on = true, errors = 0, ms = 0, max_ms = 0, dev = r.dev }
  addons[#addons + 1] = a
  v1.off(a.name, r.src, a.fp)
  local was = off[a.name]
  -- A mod can ask to stay on after a crash ("-- HD2-Keep-On-Crash: yes" in its first lines): then only
  -- the call that crashed is skipped.
  local keep = r.src:sub(1, 400):match('\n%-%- HD2%-Keep%-On%-Crash: yes') ~= nil
  if was and keep then
    off[a.name] = nil
    save_state()
    log('kept on after a crash (it asked to): ' .. a.name .. '; the call that crashed stays skipped')
    was = nil
  end
  if was and was.fp == a.fp then
    a.on = false
    log('kept off: ' .. a.name .. ' (' .. was.why .. '); an update of the mod turns it back on')
    notices[#notices + 1] = { text = a.short:upper():gsub('_', ' ') .. ' IS OFF AFTER A CRASH (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
  elseif was then
    off[a.name] = nil
    save_state()
    log('turned back on: ' .. a.name .. ' (the mod changed since it was turned off)')
  end
  if a.on then
    local rok, why = starter.requires_ok(r)
    if not rok then
      a.on = false
      log('not started: ' .. a.name .. ' ' .. why)
      notices[#notices + 1] = { text = a.short:upper():gsub('_', ' ') .. ' IS OFF (SEE ' .. FILES:upper() .. '.LOG)', dur = 20 }
      return a
    end
    a.options = options_for(a.name)
    local chunk, cerr = loadstring(r.src, '@' .. r.name)
    if not chunk then
      a.on = false
      log('could not compile ' .. a.name .. ': ' .. tostring(cerr))
    elseif not svc.sandbox then
      -- no locked-down space, no start: a mod never runs with the game's whole Lua by mistake
      a.on = false
      log('not started: ' .. a.name .. ' (the locked-down space for mods could not be set up)')
    else
      -- its own locked-down space (src/chef_loader/sandbox.lua)
      local env = starter.env_for(a.name)
      setfenv(chunk, env)
      crumb('> ' .. a.name .. '|start')
      local ok, m = pcall(chunk, make_api(a))
      crumb('< ' .. a.name .. '|start')
      if ok and type(m) == 'table' then
        starter.read_module(a, m)
        log(fmt('started %s %s (%s)', a.name, a.version or '', a.file))
      elseif ok and m == nil then
        -- a file that does its work when it runs and returns nothing ran fine: it simply has no update or
        -- shutdown of mine to call
        starter.read_module(a, {})
        log(fmt('started %s (%s; it returned nothing, so it has no update or shutdown)', a.name, a.file))
      else
        starter.off(a)                 -- it may have set up timers, watches or events before it failed
        log('could not start ' .. a.name .. ': ' .. (ok and ('it returned a ' .. type(m) .. ', not a table') or tr.why(m)))
      end
    end
  end
  return a
end
local function start_addons()
  local seen = {}
  for _, r in ipairs(services.order(found_addons)) do
    if seen[r.name] then
      log(fmt('two copies of %s: running the one deployed last (%s), skipped %s', r.name, seen[r.name], r.file))
    else
      seen[r.name] = r.file
      -- one pcall each: a mod that breaks my start-up steps (an error object that can't be shown, say) stops only itself
      local ok, err = pcall(starter.addon, r)
      if not ok then
        local a = addons[#addons]
        if a and a.name == r.name then pcall(starter.off, a) end
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

local function draw_notices()
  if #notices == 0 or not world.stable then return end
  draw_world_reset()
  local keep = {}
  local w, h = draw.w, draw.h
  local px = max(2, floor(h / 540 + 0.5))
  local y = h - 60 * px / 2
  local red, dark = color(255, 90, 70, 255), color(10, 10, 10, 180)
  for _, n in ipairs(notices) do
    n.until_t = n.until_t or (elapsed + n.dur)     -- the clock starts when the notice can first be seen
    if elapsed < n.until_t then
      keep[#keep + 1] = n
      local tw = text_width(n.text, px)
      local x = floor((w - tw) / 2)
      rect(x - 3 * px, y - 2 * px, tw + 6 * px, 11 * px, dark, 950)
      text(x, y, n.text, px, n.rgb and color(n.rgb[1], n.rgb[2], n.rgb[3], 255) or red, 960)
      y = y - 14 * px
    end
  end
  notices = keep
end

local function frame(dt)
  frame_no = frame_no + 1
  if next(held) then tick() end
  update_world()
  if job then
    if job.probe then probe_step() else scan_step() end
  elseif world.stable and world.probe_at and elapsed >= world.probe_at then
    if can_probe() then probe_start() else world.probe_at, world.checking = nil, false end
  elseif world.stable and #watchers > 0 then
    scan_start()
  end
  for _, a in ipairs(addons) do run_hook(a, 'update', dt) end
  -- one pcall each: an error in one (the menu, say) doesn't hold up the timers or the drawing
  local ok, err = pcall(svc.frame)
  if not ok then frame_error(err) end
  ok, err = pcall(svc.util.frame)
  if not ok then frame_error(err) end
  ok, err = pcall(draw_notices)
  if not ok then frame_error(err) end
  ok, err = pcall(draw_flush)
  if not ok then frame_error(err) end
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
-- Another mod loader's boot script (one that reads the deployed patches for "-- HD2-Addon:" mods itself)
-- isn't run: its init would start every addon a second time, outside my crash guard and without the
-- `chef` helpers my mods need. Copies of this loader are already left out when the patches are read.
function starter.other_loader(src)
  if src:find('__boot_mod_loader', 1, true) then return true end
  local wants_addons = src:find('HD2%-Addon', 1, true) or src:find('HD2-Addon', 1, true)
  return (wants_addons and src:find('9ba626afa44a3aa3', 1, true)) and true or false
end
function starter.named_one(r)
  local fp = fingerprint(r.src)
  local short = r.name:match('([^/]+)$')
  v1.off(r.name, r.src, fp)
  local was = off[r.name]
  if was and was.fp == 'pending' then was.fp = fp; save_state() end
  if was and r.src:sub(1, 400):match('\n%-%- HD2%-Keep%-On%-Crash: yes') then
    off[r.name] = nil; save_state(); was = nil
    log('kept on after a crash (it asked to): ' .. r.name .. '; the call that crashed stays skipped')
  end
  if was and was.fp == fp then
    log('kept off: ' .. r.name .. ' (' .. was.why .. '); an update of the mod turns it back on')
    notices[#notices + 1] = { text = short:upper():gsub('_', ' ') .. ' IS OFF AFTER A CRASH (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
    return
  end
  if was then off[r.name] = nil; save_state(); log('turned back on: ' .. r.name .. ' (the mod changed since it was turned off)') end
  local rok, why = starter.requires_ok(r)
  if not rok then
    log('not started: ' .. r.name .. ' ' .. why)
    notices[#notices + 1] = { text = short:upper():gsub('_', ' ') .. ' IS OFF (SEE ' .. FILES:upper() .. '.LOG)', dur = 20 }
    return
  end
  local chunk, cerr = loadstring(r.src, '@' .. r.name)
  if not chunk then
    log('could not compile ' .. r.name .. ': ' .. tostring(cerr))
    return
  end
  if not svc.sandbox then
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
  setfenv(chunk, env)
  local ok, err = guarded(r.name, 'load', chunk)
  if err ~= nil and ok == nil then
    starter.off(a)                     -- it may have set up timers, watches or events before it failed
    log(fmt('%s failed to run: %s', r.name, tr.why(err)))
  else
    boots[#boots + 1] = a
    log(fmt('started %s (boot-style, %s)', r.name, r.file))
  end
end
local function start_named()
  local seen = {}
  for _, r in ipairs(services.order(found_named)) do
    if seen[r.name] then
      log(fmt('two copies of %s: running the one deployed last (%s), skipped %s', r.name, seen[r.name], r.file))
    else
      seen[r.name] = r.file
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
  local title = (b.src:match('^%-%-%s*([^\r\n]+)') or 'no title'):sub(1, 90)
  if seen[fp] then
    log(fmt('another copy of a boot script I already run (%s): skipped', b.file))
  elseif starter.other_loader(b.src) then
    seen[fp] = true
    log(fmt('another mod loader\'s boot script in %s (%s): not run, it would start every addon a second time. ' ..
      'Only one loader can run: remove that mod (deployed after me, it would run instead of me)', b.file, title))
    local short = (title:match('^([^%(%.;]+)') or 'another loader'):gsub('%s+$', ''):sub(1, 24)
    notices[#notices + 1] = { text = 'OTHER LOADER NOT RUN: ' .. short:upper() .. ' (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
  else
    seen[fp] = true
    local chunk, cerr = loadstring(b.src, '@boot (' .. b.file .. ')')
    local owner = 'boot:' .. fp
    v1.boot(b.src, owner)
    if not chunk then
      log(fmt('could not compile the boot script in %s: %s', b.file, tostring(cerr)))
    elseif off[owner] then
      log(fmt('kept off: the boot script in %s (%s)', b.file, off[owner].why))
    else
      -- its metatable locked, and known to the locked-down space as someone else's: no loader mod can reach the game's
      -- globals through it (getfenv on one of its functions gives the mod its own environment)
      local env = setmetatable({}, { __index = G, __metatable = 'locked' })
      env._G = env
      starter.seal(env)
      if svc.sandbox and type(svc.sandbox.register_full) == 'function' then svc.sandbox.register_full(env, owner) end
      setfenv(chunk, env)
      local ok, err = guarded(owner, 'load', chunk)
      if err ~= nil and ok == nil then
        log(fmt('the boot script in %s failed to run: %s', b.file, tr.why(err)))
      else
        boots[#boots + 1] = { owner = owner, file = b.file, env = env, errors = 0, on = true, title = title }
        -- full access, as the game would give it if it were deployed after me: locking it down would only
        -- break it (the file-mod installer swaps game files), and a boot that wants everything can take it anyway
        log(fmt('running another mod\'s boot script too, with full access as the game gives any boot script: %s (%s)',
          b.file, title))
      end
    end
  end
end
local function start_boots()
  local seen = {}
  for _, b in ipairs(found_boots) do
    local ok, err = pcall(starter.boot_one, b, seen)
    if not ok then log('starting the boot script in ' .. tostring(b.file) .. ' failed: ' .. tr.why(err)) end
  end
end
-- one callback of every other boot script, after mine
local function call_boots(hook, ...)
  for _, b in ipairs(boots) do
    local fn = b.on and rawget(b.env, hook)
    if type(fn) == 'function' then
      local t0 = clock()
      local r1, err = guarded(b.owner, hook, fn, ...)
      local ms = (clock() - t0) * 1000
      b.pm_ms = (b.pm_ms or 0) + ms
      if ms > (b.pm_max or 0) then b.pm_max = ms end
      if r1 == nil and type(err) == 'string' and err ~= 'skipped' then
        b.errors = b.errors + 1
        if b.errors <= 3 then log(fmt('the boot script in %s: %s error: %s', b.file, hook, err)) end
        if b.errors >= MAX_ERRORS then
          b.on = false
          if b.a then starter.off(b.a) end   -- a boot-style mod's timers, watches, events and spawns stop with it
          log(fmt('the boot script in %s stopped after %d errors', b.file, b.errors))
        end
      end
    end
  end
end

function update(dt)
  if st.down then return end              -- (the game called shutdown(): nothing runs after it)
  if type(dt) == 'number' and dt > 0 and dt < 10 then elapsed = elapsed + dt end
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
  if #boots > 0 then
    local ok, err = pcall(call_boots, 'init')
    if not ok then frame_error(err) end
  end
end
function starter.render()
  for _, a in ipairs(addons) do run_hook(a, 'render') end
  if #boots > 0 then call_boots('render') end
end
function render()
  if st.down or (#addons == 0 and #boots == 0) then return end
  local ok, err = pcall(starter.render)
  if not ok then frame_error(err) end
end
-- Once only, and every step on its own pcall: one that fails doesn't keep the others from running, and the clean marker
-- is always the last line of the trace.
function shutdown()
  if st.down then return end
  st.down = true
  for _, a in ipairs(addons) do pcall(run_hook, a, 'shutdown') end
  -- the other boot scripts' shutdown before the services close the mods' own logs and my trace closes (the file-mod
  -- installer does its work here)
  if #boots > 0 then pcall(call_boots, 'shutdown') end
  pcall(svc.shutdown)
  pcall(svc.util.shutdown)
  pcall(log, 'shutdown (clean)')
  pcall(crumb, '#### clean shutdown')
  if trace then pcall(trace.close, trace); trace = nil end
  if log_file then pcall(log_file.close, log_file); log_file = nil end
end

-- ------------------------------------------------------------------ start-up
log(fmt('==== %s %s%s starting', LOADER, VERSION, TEST and (' Test ' .. TEST) or ''))
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
if #dropped > 0 then
  log('dropped ' .. #dropped .. ' skip(s) recorded by an older crash rule or an older version of me: ' .. concat(dropped, ', '))
  save_state()
end
-- My drawing (loader|draw:gui, :lines, :bitmaps, :top) is held for a world's whole life, so it's open whenever a game
-- dies soon after a mission loads, for whatever reason. It's never skipped for that: without it no mod draws
-- anything, and a draw call that really crashes is caught by its own first call anyway.
if blamed and blamed_job and blamed:match('^loader|draw:') then
  log('the last launch ended while I was drawing (' .. blamed .. '); drawing is never switched off for that')
  blamed = nil
end
if blamed and blamed_job and not suspect[blamed] then
  log('the last launch ended while ' .. blamed .. ' was running; if the next one ends the same way, I skip it')
  suspect = { [blamed] = true }
  blamed = nil
  save_state()
elseif not blamed and next(suspect) then
  suspect = {}
  save_state()
end
if blamed then
  suspect = {}
  skip[blamed] = true
  local owner = blamed:match('^([^|]+)|')
  log('the last launch crashed in: ' .. blamed .. ' (that call is skipped from now on)')
  if owner and owner ~= 'loader' then
    off[owner] = { fp = 'pending', why = 'crashed the game in ' .. blamed:gsub('^[^|]+|', '') }
  end
  save_state()
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
-- an addon blamed for the last crash is turned off now that I know its fingerprint
for _, r in ipairs(found_addons) do
  local o = off[r.name]
  if o and o.fp == 'pending' then o.fp = fingerprint(r.src); save_state() end
end
ok, err = pcall(svc.install_shims, G)
if not ok then log('the look-alikes failed: ' .. tr.why(err)) end
-- the locked-down space every loader mod runs in (after the compat parts and the look-alikes, which mods reach
-- through it); if it can't be set up, no loader mod starts
do
  local bok, sb = pcall(services.sandbox.install, { G = G, io = io_, os = os_, debug = rawget(G, 'debug'), log = log,
    DIR = DIR, GAME_DIR = services.GAME_DIR, OLD_DIR = services.OLD_DIR, FILES = FILES, overrides = overrides })
  if bok and type(sb) == 'table' then
    svc.sandbox = sb
    log('mods run locked down: no programs, no native code or bytecode, files only in the game\'s folders (sandbox '
      .. services.sandbox.version .. ')')
  else
    log('the locked-down space for mods failed, so no loader mod starts: ' .. tr.why(sb))
    notices[#notices + 1] = { text = 'NO MODS STARTED (SEE ' .. FILES:upper() .. '.LOG)', dur = 25 }
  end
  if services.MOVED then log('moved from %LOCALAPPDATA% to %APPDATA%\\Arrowhead\\Helldivers2: ' .. concat(services.MOVED, ', ')) end
end
start_addons()
ok, err = pcall(start_named)
if not ok then log('starting the boot-style scripts failed: ' .. tr.why(err)) end
ok, err = pcall(start_boots)
if not ok then log('starting the other boot scripts failed: ' .. tr.why(err)) end
ok, err = pcall(svc.startup_done)
if not ok then log('after startup failed: ' .. tr.why(err)) end

end
end)
if not loader_ok then
  local ok, why = pcall(tostring, loader_err)
  why = 'failed to start: ' .. (ok and type(why) == 'string' and why or 'an error that can\'t be shown as text')
  if not (loader_log and pcall(loader_log, why)) and type(print) == 'function' then pcall(print, '[Chef Shared Loader] ' .. why) end
end
