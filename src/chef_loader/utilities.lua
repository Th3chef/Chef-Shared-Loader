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
  -- unit seen in the engine world before this one is never touched again (any call on one ends the game). Keep stamps
  -- from every earlier world, even if a mod leaves a retained handle unused for an entire intervening world. Both
  -- sets have weak keys: they do not keep unit handles alive, and garbage collection removes their stamps once mods
  -- release them. Memory use follows the handles still referenced, rather than every unit ever seen.
  local seen = { inst = -1, now = setmetatable({}, { __mode = 'k' }), before = setmetatable({}, { __mode = 'k' }) }
  local function roll()
    if seen.inst ~= world.instance then
      for u in pairs(seen.now) do seen.before[u] = true end
      seen.inst, seen.now = world.instance, setmetatable({}, { __mode = 'k' })
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
  util.current, util.fresh, util.unit_kind = current, fresh, unit_kind
  -- a unit stamped in an engine world before this one (calling anything on it ends the game); a unit not stamped yet,
  -- in a world that hasn't settled, isn't known gone
  function util.gone(u)
    if u == nil then return true end
    roll()
    return seen.before[u] ~= nil and not seen.now[u]
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
