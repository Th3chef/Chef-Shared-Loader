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
