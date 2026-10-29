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
