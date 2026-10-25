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
