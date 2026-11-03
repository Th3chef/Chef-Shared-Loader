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
--     a world that's gone is refused, and a runtime-built one for the calls those rules name), and a refused call
--     returns nil and why
--   * what a mod made is undone when it stops: its units destroyed, its GUIs destroyed, units it hid shown, materials
--     it swapped on units it didn't make put back, mouse dead zones it changed put back
-- The Steam lobby (Steam.user_id, Friends.playing_game, Network.join_steam_lobby, SteamLobby.*) only for a mod the
-- loader trusts with it (loader.lua, TRUSTED): the lobby the game reports this player in, and the mod's own member key.
-- Capitalized globals one of these mods sets reach the other ones' environments, as with that API, where they share one
-- _G; never a name the game already has. Only the first write is seen (a new key in the mod's environment): a later one
-- stays its own, and a mod that starts later gets the value as it is then. A trusted mod's globals stay its own, and it
-- takes none of the others'.
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
-- the IdString64 calls that work on the one value they're handed: called with nothing at all they read as called with a
-- nil (the other value calls may take no arguments: Vector3.zero, Quaternion.identity)
local CONVERTERS = { to_hex = true, from_hex = true }
-- what a binding asks of the engine besides, or instead of, its own name: a mod that needs it needs all of these
-- (hard dependencies only: a binding that manages without one doesn't list it)
local USES = { ['Gui.rects'] = { 'Gui.rect', 'Vector3', 'Vector2', 'Color' },
               ['Gui.update_rects'] = { 'Gui.update_rect', 'Vector3', 'Vector2', 'Color' },
               ['Gui.rect'] = { 'Gui.rect', 'Vector3', 'Vector2', 'Color' },
               ['Gui.update_rect'] = { 'Gui.update_rect', 'Vector3', 'Vector2', 'Color' },
               ['Window.ui_state'] = { 'Window.get_main_window', 'Window.has_focus', 'Window.show_cursor', 'Window.mouse_focus' },
               ['Unit.set_material_at'] = { 'Unit.set_material', 'Unit.num_meshes', 'Unit.mesh', 'Mesh.num_materials',
                                            'Mesh.material_slot_id', 'Application.can_get' },
               ['Keyboard.pressed'] = { 'Keyboard.pressed', 'Keyboard.button_index', 'Keyboard.num_buttons' },
               -- (a resource or a font is asked about with Application.can_get before it's used)
               ['World.spawn_unit'] = { 'World.spawn_unit', 'Application.can_get' },
               ['Material.set_texture'] = { 'Material.set_texture', 'Application.can_get' },
               ['Gui.text'] = { 'Gui.text', 'Application.can_get', 'Vector3', 'Color' },
               ['Gui.update_text'] = { 'Gui.update_text', 'Application.can_get', 'Vector3', 'Color' },
               ['Gui.text_extents'] = { 'Gui.text_extents', 'Application.can_get' },
               -- and what every binding of a namespace asks first, keyed by the namespace alone (no need is a bare
               -- name): a live unit (Unit.alive) for a unit, a mesh or a material, a listed world for a world or a GUI
               Unit = { 'Unit.alive' }, Mesh = { 'Unit.alive' }, Material = { 'Unit.alive' },
               World = { 'Application.worlds' }, Gui = { 'Application.worlds' } }
-- the engine tables only a mod the loader trusts with the lobby gets anything from
local LOBBY = { Steam = true, Friends = true, Network = true, SteamLobby = true }

-- ctx: log(line), mod_log(owner, text), guarded(owner, key, fn, ...), fn_of(name), G (the game's globals),
-- frame() -> number, instance() -> the engine world's instance, DIR, util (gone, unit_refused, fresh, listed),
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
  -- changes, so they hold only what this frame asked about. (An emptied table keeps its size, and each emptying walks
  -- all of it: after a frame that asked about more than 1,024 units the units' table is a new one.)
  local memo = { frame = -1, listed = {}, unit = {} }
  local function memo_frame()
    local f = ctx.frame()
    if memo.frame ~= f then
      memo.frame = f
      if next(memo.listed) then for k in pairs(memo.listed) do memo.listed[k] = nil end end
      if next(memo.unit) then
        local n = 0
        for k in pairs(memo.unit) do memo.unit[k] = nil; n = n + 1 end
        if n > 1024 then memo.unit = {} end
      end
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
        local one = name == 'IdString64' and CONVERTERS[k]
        local g = function(...)
          if rec.state ~= 'active' then return refuse(rec, b, 'the mod is off') end
          if holed(...) or (one and select('#', ...) == 0) then return refuse(rec, b, 'nothing to work on (nil)') end
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
        -- (kept as hex, not the id: release runs minutes later, and an id kept from an earlier frame ends the game. to_hex
        -- only on a real id: on anything else it can fault natively. false: there's nothing to put back here, and a later
        -- swap's answer, the mod's own material, mustn't take this place.)
        if list[key] == nil then
          local hex = kind(previous) == 'IdString64' and once(rec, 'IdString64.to_hex', previous) or nil
          list[key] = type(hex) == 'string' and hex or false
          if not list[key] and not rec.no_put_back then
            rec.no_put_back = true
            log(fmt('[%s] %s: the material it replaced can\'t be put back (no id to keep)', rec.owner, b))
          end
        end
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
    -- (util.listed: a list of the main world's units stamps them, as these mods find their units here and the shared
    -- scan stamps only the kinds a watch asks for; a list of a world that has never been main clears its refused ones)
    for _, name in ipairs({ 'units', 'num_units' }) do
      local b = 'World.' .. name
      N.World[name] = function(w)
        if not listed(w) then return refuse(rec, b, 'not a live world') end
        return util.listed(w, once(rec, b, w))
      end
    end
    function N.World.units_by_resource(w, id)
      local b = 'World.units_by_resource'
      if not listed(w) then return refuse(rec, b, 'not a live world') end
      local res = (kind(id) == 'IdString64' and id) or (hex16(id) and once(rec, 'IdString64.from_hex', id))
        or (type(id) == 'string' and id ~= '' and once(rec, 'IdString64', id))
      if not res then return refuse(rec, b, 'not a resource id') end
      return util.listed(w, once(rec, b, w, res))
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
      -- (the parent must be a live unit of this world too. The link isn't one of the calls refused by name, so a
      -- runtime-built parent gets through, as it does for chef.link)
      local pwhy = unit_ask(rec, b, parent)
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
      if g ~= nil then
        guis[g] = { world = w, count = 0, instance = ctx.instance and ctx.instance() }
        -- (made while paused, by a function it shared: hidden like its others, and shown at the resume as it sets it)
        if rec.paused then guis[g].hid = true; once(rec, 'Gui.set_visible', g, false) end
      end
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
      guis[g].shown = on                       -- (what it last set: a pause hides it until the resume, rt.resume)
      if not rec.paused then once(rec, 'Gui.set_visible', g, on) end
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
      -- (the primitive comes back only if the engine call really ran: a skipped one left the text there)
      local _, no = once(rec, 'Gui.destroy_text', g, id)
      if no == nil then guis[g].count = guis[g].count - 1 end
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
    -- infinite for the session), and what the mod found is put back when it stops. Mods nest (rt.zones, each axis's
    -- entries, oldest first): one under another hands what it found to the entry above when it stops, so the axis ends as
    -- the first of them found it, whichever order they stop in. A mod that sets it again from under another moves up.
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
      if rec.paused then return refuse(rec, b, 'the mod is off') end   -- (a function it shared: the camera stays free)
      return rec.zone_set(i, mode, size)
    end
    -- (its own function on rec, never on N: the mod has that table, and a resume calls this outside the mod's calls)
    function rec.zone_set(i, mode, size)
      local b = 'Mouse.set_dead_zone'
      rec.dead_zones = rec.dead_zones or {}
      local z, e = rt.zones[i], rec.dead_zones[i]
      if not z then z = {}; rt.zones[i] = z end
      if not e or z[#z] ~= e then
        local m, s = once(rec, 'Mouse.dead_zone', i)
        if not zone_ok(m, s) then return refuse(rec, b, 'unexpected answer') end
        -- (my mouse hold's own size isn't what the mod found: what the hold found is, or the mod hands the hold's size back)
        local had = ctx.hold_had and ctx.hold_had(i, s)
        if had then m, s = had[1], had[2] end
        if e then rt.zone_out(z, e) end
        e = { m, s }
        rec.dead_zones[i], z[#z + 1] = e, e
      end
      once(rec, b, i, mode, size)
      e.mode, e.size = mode, size
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
  rt.zones = {}
  function rt.zone_near(a, b) return abs(a - b) <= 1e-6 * math.max(1, abs(b)) end
  -- (an entry leaves its axis's list: what it found goes to the entry above it, which found this one's value)
  function rt.zone_out(z, e)
    for k, q in ipairs(z) do
      if q == e then
        if z[k + 1] then z[k + 1][1], z[k + 1][2] = e[1], e[2] end
        table.remove(z, k)
        return
      end
    end
  end
  -- (the last one on an axis puts back what it found, unless the axis reads neither what the mod set nor what it found:
  -- something that isn't a runtime mod has it now, and it's left to that. Compared near enough: the engine keeps a size
  -- as a float. No answer: put back, as a stop always did. My menu's or a mod's mouse hold sitting on what the mod set
  -- would hand that back when it ends, so the hold is given what the mod found as well: ctx.hold_had. The switch that
  -- stops or pauses a mod is pressed in that menu.)
  function rt.zones_back(rec)
    local o = rec.owner
    local function g(name, ...) return guarded(o, name, fn_of(name), ...) end
    for i, v in pairs(rec.dead_zones or {}) do
      local z, top = rt.zones[i], false
      if z then top = z[#z] == v; rt.zone_out(z, v) end
      if top then
        local _, s = g('Mouse.dead_zone', i)
        local had = ctx.hold_had and ctx.hold_had(i)
        if had and v.size and rt.zone_near(had[2], v.size) then had[1], had[2] = v[1], v[2] end
        if type(s) ~= 'number' or not v.size or rt.zone_near(s, v.size) or rt.zone_near(s, v[2]) then
          g('Mouse.set_dead_zone', i, v[1], v[2])
        end
      end
    end
    if rec.dead_zones and ctx.hold_look then ctx.hold_look() end
    rec.dead_zones = nil
  end
  local function release(rec)
    local o = rec.owner
    local function g(name, ...) return guarded(o, name, fn_of(name), ...) end
    rt.zones_back(rec)
    for u, list in pairs(rec.rebound or {}) do
      if type(u) == 'userdata' and not util.gone(u) and kind(u) == 'Unit' and g('Unit.alive', u) == true then
        for key, previous in pairs(list) do
          local i, j = key:match('^(%d+):(%d+)$')
          i, j = tonumber(i), tonumber(j)
          if previous and i <= (g('Unit.num_meshes', u) or 0) then
            local m = g('Unit.mesh', u, i)
            if m ~= nil and j <= (g('Mesh.num_materials', m) or 0) then
              local slot = g('Mesh.material_slot_id', m, j)
              -- (the id made here, fresh, and a key of its own: the swap already proved Unit.set_material's, so a crash
              -- in this one would leave no crumb)
              local id = slot ~= nil and g('IdString64.from_hex', previous) or nil
              if id ~= nil then guarded(o, 'release:Unit.set_material', fn_of('Unit.set_material'), u, slot, id) end
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
  -- an orphan is only there to find the copies a reload replaces: one no running mod has goes, with what it holds (a
  -- string most of all: a weak table never lets go of one). A running mod writing over its copy tells me nothing, so I
  -- look when a mod is forgotten and at each new world.
  function rt.sweep()
    for k, x in pairs(orphan) do
      local held = false
      if x.v ~= nil then
        for e in pairs(envs) do
          -- (rawequal: a mod's __eq must never run here, in another mod's stop)
          if rawequal(rawget(e, k), x.v) then held = true; break end
        end
      end
      if not held then orphan[k] = nil end
    end
  end
  -- the loader stopped this mod (errors, a failed start, dev reload): everything it made is undone
  function rt.forget(owner)
    local o = owners[owner]
    if not o then return end
    for _, rec in ipairs(o.order) do switch_off(rec, 'stopped by the loader') end
    if o.env then envs[o.env] = nil end
    owners[owner] = nil
    -- what it shared isn't handed to mods that start later; mods that have it keep their copy (one may have made the
    -- name its own, X = X or {}). Held weakly: its functions keep the stopped mod's environment and locals, and what a
    -- running mod still has stays alive through that mod.
    for k, by in pairs(shared_by) do
      if by == owner then
        orphan[k], shared[k], shared_by[k] = setmetatable({ by = owner, v = shared[k] }, { __mode = 'v' }), nil, nil
      end
    end
    rt.sweep()
  end
  -- A paused mod (svc.pause) keeps all it made, but two things of it can't wait with it, as nothing calls it to change
  -- them: its dead zones go back, or the camera stays frozen as long as it's off, and its GUIs hide, or they stay on
  -- screen frozen where it left them (a retained GUI shows until it's removed). rec.zones_held: the entries it had,
  -- with what it set on each axis (mode, size); a GUI's hid: I hid it. Resumed, the zones are set again, on top of what
  -- the axis has by then, and each GUI shows as the mod last set it (shown), unless its world went meanwhile.
  local function gui_here(e) return (not ctx.instance or e.instance == ctx.instance()) and listed(e.world) end
  function rt.pause(owner)
    local o = owners[owner]
    for _, rec in ipairs(o and o.order or {}) do
      rec.paused, rec.zones_held = true, rec.dead_zones
      rt.zones_back(rec)
      for gui, e in pairs(rec.guis) do
        if gui_here(e) then e.hid = true; once(rec, 'Gui.set_visible', gui, false) end
      end
    end
  end
  function rt.resume(owner)
    local o = owners[owner]
    for _, rec in ipairs(o and o.order or {}) do
      local held = rec.state == 'active' and rec.zones_held
      rec.paused, rec.zones_held = nil, nil
      for i, e in pairs(held or {}) do if e.size then rec.zone_set(i, e.mode, e.size) end end
      for gui, e in pairs(rec.guis) do
        if e.hid then
          e.hid = nil
          if gui_here(e) then once(rec, 'Gui.set_visible', gui, e.shown ~= false) end
        end
      end
    end
  end
  -- did a mod of this file stop itself (handle.switch_off)? (the loader's stop forgets it: asked before that) A mod that
  -- did stays stopped until the next launch: its switch brings it back no sooner.
  function rt.stopped_itself(owner)
    local o = owners[owner]
    for _, rec in ipairs(o and o.order or {}) do if rec.state ~= 'active' then return true end end
    return false
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
        -- (a unit of an engine world that's gone goes whatever its world handle says: a world restarted in place stays
        -- listed, and past the stamps' cap nothing would tell release this one is gone)
        for u, w in pairs(rec.owned) do if not listed(w) or util.gone(u) then rec.owned[u] = nil end end
        for u in pairs(rec.hidden) do if util.gone(u) then rec.hidden[u] = nil end end
        for u in pairs(rec.rebound or {}) do if util.gone(u) then rec.rebound[u] = nil end end
        for gui, e in pairs(rec.guis) do
          if (ctx.instance and e.instance ~= ctx.instance()) or not listed(e.world) then rec.guis[gui] = nil end
        end
      end
    end
    rt.sweep()
  end

  -- ---------------------------------------------------------------- the callbacks, through the mod's own hooks
  -- (failed: a callback may raise nil, and that's an error too: it counts toward the loader's stop like any other)
  local function dispatch(o, event, ...)
    local failed, first = false, nil
    for _, rec in ipairs(o.order) do
      if rec.state == 'active' then
        local list = rec.callbacks[event]
        for i = 1, #list do
          local ok, err = pcall(list[i], ...)
          if not ok then
            rec.errors = rec.errors + 1
            if not failed then failed, first = true, err end
          end
          if rec.state ~= 'active' then break end
        end
      end
    end
    if failed then error(first, 0) end
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
  -- what a mod has of a grant: 'granted' (its list entry gives it), or nil (its entry doesn't give it, or it has none).
  -- The lobby only under the key its entry names, as the Steam calls have it (net): another key would be granted here
  -- and then refused there.
  local function grant_state(rec, what)
    local t = ctx.trusted(rec.owner)
    if not t then return nil end
    if what == 'lobby' then
      return (t.network and rec.lobby_key ~= nil and rec.lobby_key == t.lobby_key) and 'granted' or nil
    end
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
      if ns then
        have = type(rec.engine[ns]) == 'table' and type(rec.engine[ns][call]) == 'function'
        -- (my wrapper is always there: what counts is what it asks of this build)
        for _, e in ipairs(have and USES[n] or {}) do if fn_of(e) == nil then have = false end end
        for _, e in ipairs(have and USES[ns] or {}) do if fn_of(e) == nil then have = false end end
        if have and not USES[n] and fn_of(n) == nil then have = false end
        if have and LOBBY[ns] then have = grant_state(rec, 'lobby') ~= nil end
      else have = grant_state(rec, n) ~= nil end
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
      local state = grant_state(rec, what)
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
        -- (is there a stop callback at all? one for the loader's log, never a hook)
        has_stop = function()
          for _, x in ipairs(o.order) do if #x.callbacks.stop > 0 then return true end end
          return false
        end,
      })
    end
    -- its environment shares the runtime mods' globals from now on
    if o.env and not envs[o.env] then
      envs[o.env] = o
      -- (a trusted mod gets none of the shared globals, and what it sets stays its own: its environment holds only
      -- what it set itself)
      if not ctx.trusted(o.name) then
        -- (the value its owner has now, not the one it set first: only that first write told me anything)
        for k, v in pairs(shared) do
          if rawget(o.env, k) == nil then
            local by = owners[shared_by[k]]
            local now = by and by.env and rawget(by.env, k)
            if now == nil then now = v end
            rawset(o.env, k, now)
          end
        end
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
  -- a capitalized global a runtime mod sets: shared with every runtime mod that doesn't have that name yet. (Each mod
  -- has its own copy of the name, so I hear of a write only when the key is new: the first one, or one after X = nil.)
  -- A trusted mod's globals stay its own (what it sets could let another mod use what only it was given: its lobby
  -- key, say), and it gets none of the others'.
  function rt.on_global(env, k, v)
    local o = envs[env]
    -- (each mod's HD2Runtime and BingusRuntime are bound to its own environment: shared, one would keep a stopped mod's
    -- whole environment for the session. fn_of: the game keeps its tables in stingray, so a name it has isn't always in G)
    if not o or type(k) ~= 'string' or not k:match('^%u[%w_]*$') or rawget(G, k) ~= nil or fn_of(k) ~= nil or k == 'HD2Runtime' or k == 'BingusRuntime' then return end
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
        if cur == nil or (prev ~= nil and rawequal(cur, prev)) then rawset(e, k, v) end
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
