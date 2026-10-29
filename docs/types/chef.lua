---@meta
-- Chef Shared Loader: type stubs for the `chef` helpers, for editor autocomplete and checks with the Lua language
-- server (LuaLS, the "Lua" extension in VS Code). This file is never run and never shipped with a mod: point your
-- editor at docs/types (see docs/TESTING.md). docs/MODDING.md is the full guide; each description here is short.
--
-- In an addon (`-- HD2-Addon:`), the helpers are the file's argument:
--
--   ---@type Chef
--   local chef = ...
--
-- In a boot-style script (`-- HD2-Boot:`), `chef` is a global, typed below.
--
-- Check `chef.has('<capability>')` before using a helper that came after the loader version your mod needs (an older
-- loader has no `chef.has`: test that it's there first).

-- An engine unit. It belongs to one world: drop it when chef.world_id() changes.
---@alias ChefUnit userdata
-- An engine world.
---@alias ChefWorld userdata
-- A point or a direction: an engine Vector3 (from this frame), { x = , y = , z = } or { x, y, z }.
---@alias ChefVec3 userdata | { x: number, y: number, z: number } | number[]
-- A box for chef.ray_box: its middle (a ChefVec3, a plain one with `yaw` in radians about the up axis, 0 = facing +y),
-- or its pose as an engine Matrix4x4 made this frame; with extents. A unit alone, without extents, is its own box.
---@alias ChefBox ChefVec3 | { x: number, y: number, z: number, yaw: number? } | userdata
-- An engine Color from chef.color. It lives for the frame it was made in only.
---@alias ChefColor userdata
-- A particle effect handle from chef.particles.
---@alias ChefParticles any
-- Unit resource ids (16 hex digits) -> true.
---@alias ChefKinds table<string, boolean>

---@alias ChefOptionType
---| 'toggle'  # a checkbox: the value is a boolean
---| 'choice'  # one of `choices`: the value is its index
---| 'slider'  # a number from `min` to `max`, snapped to `step`
---| 'key'     # a key binding: the value is a key name, or 'off'
---| 'button'  # a button: runs `run`, saves nothing (from 1.4.0)
---| 'color'   # a color: the value is 'RRGGBB' (from 1.4.0)

---@alias ChefEvent
---| 'startup'        # once, after every mod started and the after_startup callbacks ran
---| 'world'          # (world_id, in_mission): a new world has settled
---| 'mission_start'  # (world_id): a mission starts
---| 'mission_end'    # (world_id): the mission ends (extraction, quitting, a new world)
---| 'players'        # (players, joining, players_before): the player count or the number still joining changed (from 1.4.0)
---| 'menu'           # (open): the loader's options menu opened (true) or closed (false) (from 1.4.0)
---| 'mod_stopped'    # (name, why): a running mod stopped: errors, the hang watchdog, switched off (from 1.4.0)
---| 'shutdown'       # the game closes
---| string           # any event a mod emits with chef.emit

---@alias ChefCapabilityName
---| 'api'
---| 'after_startup'
---| 'settings'
---| 'share'
---| 'events'
---| 'require'
---| 'bind'
---| 'menu'
---| 'shims'
---| 'dev'
---| 'logs'
---| 'own_log'
---| 'units'
---| 'spawn'
---| 'timers'
---| 'budget'
---| 'session'
---| 'settings_file'
---| 'shapes'
---| 'sprite_sheets'
---| 'notify'
---| 'typed'
---| 'key_labels'
---| 'save_table'
---| 'mods'
---| 'health'
---| 'index'
---| 'joining'
---| 'ray_box'
---| 'mouse_hold'
---| 'players_event'
---| 'hang_watchdog'
---| 'option_buttons'
---| 'option_colors'
---| 'option_headings'
---| 'menu_state'
---| 'mod_stopped_event'
---| 'bind_combos'
---| 'option_folds'

---@alias ChefModState 'running' | 'off' | 'kept off' | 'not started' | 'stopped' | 'started elsewhere' | 'left to its loader' | 'handed off'

---Read-only. `api` is the helper level; every other field is true when the loader has that capability.
---@class ChefCapabilities
---@field api integer
---@field after_startup boolean
---@field settings boolean
---@field share boolean
---@field events boolean
---@field require boolean
---@field bind boolean
---@field menu boolean
---@field shims boolean
---@field dev boolean
---@field logs boolean
---@field own_log boolean
---@field units boolean
---@field spawn boolean
---@field timers boolean
---@field budget boolean
---@field session boolean
---@field settings_file boolean
---@field shapes boolean
---@field sprite_sheets boolean
---@field notify boolean
---@field typed boolean
---@field key_labels boolean
---@field save_table boolean
---@field mods boolean
---@field health boolean
---@field index boolean
---@field joining boolean          chef.joining() says how many are still joining (from 1.4.0)
---@field ray_box boolean          chef.ray_box: the game has Math.ray_box_intersection (from 1.4.0)
---@field mouse_hold boolean       chef.hold_mouse, chef.mouse_held, chef.mouse_delta (from 1.4.0)
---@field players_event boolean    the 'players' event (from 1.4.0)
---@field hang_watchdog boolean    a call into a mod that runs over 3 s is stopped: true while the watchdog watches (from 1.4.0)
---@field option_buttons boolean   chef.button and 'button' rows (from 1.4.0)
---@field option_colors boolean    'color' rows and chef.rgb (from 1.4.0)
---@field option_headings boolean  `heading`, `sub` and `hint` in option specs (from 1.4.0)
---@field menu_state boolean       chef.menu_open() and the 'menu' event (from 1.4.0)
---@field mod_stopped_event boolean the 'mod_stopped' event (from 1.4.0)
---@field bind_combos boolean      chef.bind takes key combos ('ctrl+f6') and controller buttons ('pad:cross') (from 1.4.0)
---@field option_folds boolean     a mod's headings fold in the menu; `fold = false` keeps one open (from 1.4.0)

---The view camera. Read only: the table is shared by every mod.
---@class ChefCamera
---@field x number    position
---@field y number
---@field z number
---@field fx number   forward
---@field fy number
---@field fz number
---@field yaw number  radians, 0 = +y
---@field fov number? the vertical field of view, when the engine gives it

---One unit a watch found.
---@class ChefWatchItem
---@field unit ChefUnit
---@field kind string  its resource id, 16 hex digits
---@field x number
---@field y number
---@field z number

---From chef.watch: the units of the kinds asked for, listed again every `every` seconds.
---@class ChefWatch
---@field items ChefWatchItem[]  the last list
---@field generation integer     bumps with each new list
local ChefWatch = {}
---Stops listing until resume().
function ChefWatch.pause() end
---Lists again (at once, then on its schedule).
function ChefWatch.resume() end
---Asks for a new list soon (at most every 0.5 s).
function ChefWatch.refresh() end
---Drops the watch for good.
function ChefWatch.stop() end

---A unit near a point, from chef.units_near.
---@class ChefNearUnit: ChefWatchItem
---@field d number  its distance from the point

---From chef.bind: a key row in the options menu.
---@class ChefBinding
local ChefBinding = {}
---The key it's bound to ('off' for none).
---@return string
function ChefBinding.key() end
---True in the frame the key went down.
---@return boolean
function ChefBinding.pressed() end
---True while the key is held.
---@return boolean
function ChefBinding.down() end

---A row of the options menu: `chef.option(id, spec)`.
---@class ChefOptionSpec
---@field type ChefOptionType
---@field label string?        the row's name (its id otherwise)
---@field default any?         toggle: boolean; choice: an index (1); slider: a number (min); key: a key name ('off'); color: 'RRGGBB' ('FFFFFF')
---@field choices string[]?    a choice's 2 to 32 choices
---@field min number?          a slider's lowest value (finite, below max)
---@field max number?          a slider's highest value
---@field step number?         a slider's step (0 or more; values snap within the range)
---@field palette string[]?    a color row's 2 to 32 'RRGGBB' colors (the loader's own 14 without one)
---@field run fun()?           a button's function, run as your mod when it's pressed
---@field text string?         what a button row shows on its right ('RUN' by default)
---@field heading string?      a heading line above this row (200 characters at most; from 1.4.0)
---@field sub boolean?         with heading: a small heading, its rows indented under it until the next heading
---@field fold boolean?        with heading (not sub): false keeps this heading always open, never folded (from 1.4.0)
---@field hint string?         shown on its own line above the key hints while the row is selected (200 characters at most)

---From chef.after / chef.every.
---@class ChefTimer
local ChefTimer = {}
---Stops it.
function ChefTimer.cancel() end
---True until it ran (after) or was canceled.
---@return boolean
function ChefTimer.active() end

---From chef.spread.
---@class ChefJob
local ChefJob = {}
---Stops it (its done callback isn't called).
function ChefJob.cancel() end
---True while it runs.
---@return boolean
function ChefJob.active() end
---Items done so far, and how many in all.
---@return integer done
---@return integer total
function ChefJob.progress() end

---@class ChefSpreadOptions
---@field keep boolean?  true: a new world doesn't stop it (only for lists without units)

---From chef.light: one light of a unit, asked fresh at each call. Each returns true when it went through.
---@class ChefLight
local ChefLight = {}
---@param r number 0-255
---@param g number 0-255
---@param b number 0-255
---@return boolean
function ChefLight.set_color(r, g, b) end
---@param v number
---@return boolean
function ChefLight.set_intensity(v) end
---@param on boolean
---@return boolean
function ChefLight.set_enabled(on) end
---@param start_distance number
---@param end_distance number
---@return boolean
function ChefLight.set_falloff(start_distance, end_distance) end
---@param on boolean
---@return boolean
function ChefLight.set_shadows(on) end

---From chef.sprite_sheet: a texture holding cols x rows pictures.
---@class ChefSpriteSheet
---@field tex string
---@field cols integer
---@field rows integer
local ChefSpriteSheet = {}
---Draws picture i (1 = top left, row by row); false when it can't be drawn.
---@param i integer
---@param x number
---@param y number
---@param w number
---@param h number
---@param c ChefColor
---@param layer number?
---@return boolean
function ChefSpriteSheet.draw(i, x, y, w, h, c, layer) end

---One entry of chef.mods(): every mod the loader found.
---@class ChefModEntry
---@field name string            'mods/<author>/<name>'
---@field kind 'addon'|'boot'
---@field on boolean
---@field dev boolean?           loaded from dev mode's file list (test builds)
---@field file string?           the patch it came from
---@field version string?        its module's `version` as read when it started, as text (the one its switch row shows)
---@field state ChefModState
---@field why string?            why it isn't running
---@field errors integer
---@field ms_avg number?         its average ms a frame over the last status minute (nil before the first)
---@field ms_max number?         its worst call over that minute, in ms
---@field requires string[]?     its HD2-Requires lines
---@field missing string[]?      what an HD2 Lua Runtime mod said it needs (spec.needs) and the loader lacks
---@field start_ms number?       its start (compile and first run) in ms; nil for a mod that never ran (from 1.4.0)
---@field start_kb number?       how much the Lua heap grew over its start, in KB (approximate, can be below 0; from 1.4.0)
---@field title string?          a boot entry's title

---A patch as chef.index() reports it.
---@class ChefIndexPatch
---@field patch integer
---@field number integer
---@field file string
---@field mods string[]  the mods declared in that patch's Lua

---@class ChefIndexConflict
---@field type string
---@field id string
---@field policy 'exclusive'|'shared'|'unchecked'
---@field winner ChefIndexPatch
---@field loser ChefIndexPatch

---From chef.index(): which mod's copy of a resource the game loads.
---@class ChefIndex
local ChefIndex = {}
---The copy the game loads, or nil.
---@param type string  a type name ('unit', 'material', 'texture' ...) or 16 hex digits
---@param id string    16 hex digits
---@return ChefIndexPatch?
function ChefIndex.winner(type, id) end
---Every patch that ships it, the winner first.
---@param type string
---@param id string
---@return ChefIndexPatch[]
function ChefIndex.providers(type, id) end
---Every patch the loader read, lowest number first.
---@return ChefIndexPatch[]
function ChefIndex.patches() end
---Resources two different mods ship in different copies, and the count of the rest.
---@return ChefIndexConflict[] conflicts
---@return integer? more
function ChefIndex.conflicts() end

---What an addon's file returns. The loader looks each hook up at every call, so you can set or swap them later.
---@class ChefAddon
---@field version string?        your mod's version (chef.require and chef.mods() read it; F9 shows it on your switch)
---@field update fun(dt: number)?  every frame
---@field render fun()?           every frame, after the game's render
---@field shutdown fun()?         when the game closes
---@field on_stop fun()?          once, when the loader stops your mod (errors, the hang watchdog, switched off in the menu, a failed start, a dev reload): put back what only you know

---The helpers each mod gets.
---@class Chef
---@field loader string                 the loader's name, 'Chef Shared Loader'
---@field loader_version string         the loader's version, e.g. '1.4.1'
---@field api integer                   the helper level (3); it only goes up when something is added
---@field name string                   your mod's name, 'mods/<author>/<name>'
---@field options table                 your merged Arsenal options ({} when none is ticked)
---@field TOP integer                   add it to a layer to draw over the game's HUD, map and menus (chef.TOP + 0 to + 999)
---@field capabilities ChefCapabilities read-only
---@field log_directory string          the loader's folder (%APPDATA%\Arrowhead\Helldivers2), no trailing backslash
---@field log_file string               the file your chef.log lines go to
---@field previous_directory string?    where older builds of the loader kept its folder (%LOCALAPPDATA%), or nil
local Chef = {}

-- ---------------------------------------------------------------- general (api 1)

---A line in chef_loader.log, prefixed [mods/you/my_mod] (or in your own log after chef.own_log).
---@param fmt any  a string.format pattern, or any value
---@param ... any
function Chef.log(fmt, ...) end

---Seconds since the game started (the loader's clock).
---@return number
function Chef.time() end

-- ---------------------------------------------------------------- engine calls (crash-guarded)

---A guarded engine call, e.g. chef.call('Unit.alive', u). Returns the engine's answers, or nil and a reason when the
---function is missing, raised an error, is refused, or is skipped after it crashed the game.
---@param name string  'Table.function'
---@param ... any
---@return any ...
function Chef.call(name, ...) end

---The same as chef.call, with its own crash key per kind (a crash on one unit kind only skips that kind).
---@param name string
---@param kind string
---@param ... any
---@return any ...
function Chef.call_kind(name, kind, ...) end

-- ---------------------------------------------------------------- world, camera and units

---The main world once it has settled, else nil.
---@return ChefWorld?
function Chef.world() end

---The settled world's id (0 before); it changes with every new world.
---@return integer
function Chef.world_id() end

---True in a mission (not the ship, not loading).
---@return boolean
function Chef.in_mission() end

---Unit ids that only exist in missions (used only if the engine can't count levels).
---@param kinds ChefKinds
function Chef.mission_kinds(kinds) end

---The view camera, or nil while there's none.
---@return ChefCamera?
function Chef.camera() end

---Screen pixels (bottom-left origin) of a world point, or nil when it's behind the camera.
---@param x number
---@param y number
---@param z number
---@return number? sx
---@return number? sy
function Chef.world_to_screen(x, y, z) end

---Lists the units of the given kinds every `every` seconds (5 by default, 0.5 at least), spread over frames.
---Runtime-built units (46cab355bd8d4d37) are never listed.
---@param kinds ChefKinds
---@param every number?
---@return ChefWatch?
function Chef.watch(kinds, every) end

-- ---------------------------------------------------------------- input

---True while the key is held (the engine's key names: 'f7', 'tab', 'left ctrl' ...); false while the loader's
---options menu is open.
---@param name string
---@return boolean
function Chef.key_down(name) end

---True in the frame the key went down; false while the loader's options menu is open.
---@param name string
---@return boolean
function Chef.key_pressed(name) end

---True when the keyboard knows that key name.
---@param name string
---@return boolean
function Chef.key_known(name) end

---True while the mouse button is held ('left', 'right', 'middle'); false while the loader's options menu is open.
---@param name string
---@return boolean
function Chef.mouse_down(name) end

---The mouse cursor in window pixels, or nil; it answers while the options menu is open too.
---@return number? x
---@return number? y
function Chef.cursor() end

---The mouse wheel this frame (0 when it didn't move, and while the loader's options menu is open).
---@return number
function Chef.wheel() end

-- ---------------------------------------------------------------- drawing

---The screen's width and height in pixels.
---@return number w
---@return number h
function Chef.screen() end

---A color for this frame (make it in the frame that draws). a is 255 when not given.
---@param r integer 0-255
---@param g integer 0-255
---@param b integer 0-255
---@param a integer? 0-255
---@return ChefColor
function Chef.color(r, g, b, a) end

---A filled rectangle; bottom-left origin. Layers 880-960 are the usual range (higher draws on top).
---@param x number
---@param y number
---@param w number
---@param h number
---@param c ChefColor
---@param layer number?  900 by default
function Chef.rect(x, y, w, h, c, layer) end

---Text in capitals (translated when a language file has it), 7 px tall, its left end at x and its bottom at y.
---@param x number
---@param y number
---@param s string
---@param px number  the scale: the text is 7 * px pixels tall
---@param c ChefColor
---@param layer number?
---@return number width
function Chef.text(x, y, s, px, c, layer) end

---A text's width in the font in use (measured: the game's font is proportional).
---@param s string
---@param px number
---@return number
function Chef.text_width(s, px) end

---The text cut to w wide, ending in '...' when it was cut.
---@param s string
---@param px number
---@param w number
---@return string
function Chef.text_fit(s, px, w) end

---The text broken into lines w wide at spaces (at most `most` lines, 64 if not given).
---@param s string
---@param px number
---@param w number
---@param most integer?
---@return string[]
function Chef.text_wrap(s, px, w, most) end

---The language picked in the options menu: its name and code (nil for English).
---@return string? name
---@return string? code
function Chef.lang() end

---A text as the language picked has it.
---@param s string
---@return string
function Chef.tr(s) end

---A pixel sprite: rows are strings, each character a key in colors.
---@param x number
---@param y number
---@param rows string[]
---@param cell number  one sprite pixel's size in screen pixels
---@param colors table<string, ChefColor>
---@param layer number?
function Chef.sprite(x, y, rows, cell, colors, layer) end

---A texture shipped in your patch (its resource id as hex), tinted c. False when it can't be drawn.
---@param tex string
---@param x number
---@param y number
---@param w number
---@param h number
---@param c ChefColor
---@param layer number?
---@return boolean
function Chef.bitmap(tex, x, y, w, h, c, layer) end

---Texture -> its copy for drawing below native render scale.
---@param map table<string, string>
function Chef.ui_textures(map) end

---Texture -> pre-shrunk sizes { width, id, width, id, ... }, smallest first.
---@param map table<string, (number|string)[]>
function Chef.texture_sizes(map) end

---A line in the world.
---@param x1 number
---@param y1 number
---@param z1 number
---@param x2 number
---@param y2 number
---@param z2 number
---@param c ChefColor
function Chef.line(x1, y1, z1, x2, y2, z2, c) end

-- ---------------------------------------------------------------- start-up and capabilities (api 2)

---True when the loader has that capability (chef.has('api') is true too).
---@param name ChefCapabilityName|string
---@return boolean
function Chef.has(name) end

---Runs fn once every mod has started (at once when start-up is already over).
---@param fn fun()
function Chef.after_startup(fn) end

---From now on your chef.log lines go to <name>.log in the loader's folder (a fresh file each launch once it passes
---1 MB). 8 names a launch at most; all your own logs together write at most 4 MB a launch. Call it first thing.
---@param name string  letters, digits, _ - (48 at most), not starting with chef_loader
---@return boolean ok
---@return string? why
function Chef.own_log(name) end

-- ---------------------------------------------------------------- saved settings

---Keeps a boolean, number or string (up to 512 characters) between launches; nil removes it.
---@param key string  letters, digits, _ . - (64 at most); opt. keys are the options menu's: refused, nil and why
---@param value boolean|number|string|nil
---@return boolean? ok
---@return string? why
function Chef.save(key, value) end

---What was saved, or default.
---@param key string
---@param default any
---@return any
function Chef.load(key, default) end

-- ---------------------------------------------------------------- between mods

---A value any mod can read by name (use your mod's name in it: 'you.my_mod.data').
---@param name string
---@param value any
---@return boolean
function Chef.share(name, value) end

---A shared value, or nil.
---@param name string
---@return any
function Chef.shared(name) end

---Calls fn(...) for every emit of event. Returns a function that ends the subscription.
---The 'players' event (from 1.4.0) passes the player count, how many are still joining, and the count before.
---@param event ChefEvent
---@param fn fun(...: any)
---@return (fun())?
function Chef.on(event, fn) end

---Calls every listener of event; returns how many ran.
---@param event string
---@param ... any
---@return integer?
function Chef.emit(event, ...) end

---Another addon's exports (the table it returned) when it runs and its version is `want` or newer; else nil and why.
---@param name string  'mods/<author>/<name>'
---@param want string?
---@return table? exports
---@return string? why
function Chef.require(name, want) end

-- ---------------------------------------------------------------- the options menu and key bindings

---Your mod's heading in the options menu (its name otherwise).
---@param text string
function Chef.title(text) end

---Adds a row to the options menu and returns its current value, or nil and why when the spec doesn't fit.
---@param id string  letters, digits, _ . -
---@param spec ChefOptionSpec
---@return any value
---@return string? why
function Chef.option(id, spec) end

---A row's current value.
---@param id string
---@return any
function Chef.get(id) end

---Changes a row (as if picked in the menu) and returns its new value.
---@param id string
---@param value any
---@return any
function Chef.set(id, value) end

---fn(value) whenever the row changes (from the menu or set); for a button, fn(true) each time it's pressed.
---@param id string
---@param fn fun(value: any)
---@return boolean
function Chef.on_change(id, fn) end

---A button row (from 1.4.0): Right (or Enter) or a click runs fn() as your mod (nothing once your mod is stopped or
---switched off). The same as
---chef.option(id, { type = 'button', label = label, run = fn, text = text }).
---@param id string
---@param label string
---@param fn fun()
---@param text string?  what the row shows on its right ('RUN' by default)
---@return any value
---@return string? why
function Chef.button(id, label, fn, text) end

---A color row's value ('RRGGBB', a '#' in front is taken) as 0-255 red, green and blue; nil for anything else (from 1.4.0).
---@param value string
---@return integer? r
---@return integer? g
---@return integer? b
function Chef.rgb(value) end

---A key row in the options menu (key names in any case: 'F6' is 'f6'). Returns nil and why for an id that isn't
---letters, digits, _ . -
---@param id string  letters, digits, _ . -
---@param default_key string  'off' for none
---@param label string?
---@return ChefBinding? binding
---@return any value
function Chef.bind(id, default_key, label) end

-- ---------------------------------------------------------------- the mouse (from 1.4.0)

---true holds the mouse from the game's camera; false lets go. Returns true, or false and why when the game gave no
---dead zone for the mouse. Let go when you're done (the loader also lets go when your mod stops).
---@param on boolean
---@return boolean ok
---@return string? why
function Chef.hold_mouse(on) end

---True while the game's camera can't turn with the mouse (held by the loader for a mod or its menu, or by another mod).
---@return boolean
function Chef.mouse_held() end

---This frame's mouse movement, x right and y down (0, 0 while the options menu has the mouse). Ask every frame.
---@return number dx
---@return number dy
function Chef.mouse_delta() end

-- ---------------------------------------------------------------- units, safely (api 3)

---The unit's resource id (16 hex digits), cached until the world changes.
---@param u ChefUnit
---@return string?
function Chef.unit_kind(u) end

---True while it's alive, in this world.
---@param u ChefUnit
---@return boolean
function Chef.unit_alive(u) end

---Its position (node 1, its root, by default); nil for a unit that can't be asked.
---@param u ChefUnit
---@param node integer?
---@return number? x
---@return number? y
---@return number? z
function Chef.unit_position(u, node) end

---Its forward direction and yaw (radians, 0 = +y); nil for a unit that can't be asked.
---@param u ChefUnit
---@param node integer?
---@return number? fx
---@return number? fy
---@return number? fz
---@return number? yaw
function Chef.unit_rotation(u, node) end

---A node's index, or nil when the unit has no such node.
---@param u ChefUnit
---@param name string
---@return integer?
function Chef.unit_node(u, name) end

---The units of watch w (or of all your watches) within r of a point, nearest first (from the watches' last lists).
---@param x number
---@param y number
---@param z number
---@param r number
---@param w ChefWatch?
---@return ChefNearUnit[]
function Chef.units_near(x, y, z, r, w) end

---A ray against one box you name, not the world (the game gives Lua no raycast). `box` is a unit with `extents`
---left out (its own box, from Unit.box), or a box of your own with `extents`, its half sizes (one number for a cube,
---or three, each above 0). Numbers finite and within a million meters. The distance in meters along the ray to where
---it goes into the box; nil for a miss; nil and why for a bad argument (nothing reaches the engine then), or when the
---engine call is missing, raised an error or is skipped after a crash (crash key <your mod>|Math.ray_box_intersection).
---Check chef.has('ray_box') (from 1.4.0).
---@param from ChefVec3
---@param dir ChefVec3  any length but 0
---@param box ChefUnit | ChefBox
---@param extents? number | ChefVec3  half sizes; leave out for a unit
---@return number? distance
---@return string? why
function Chef.ray_box(from, dir, box, extents) end

-- ---------------------------------------------------------------- spawning, with clean-up

---Spawns a unit (its resource id as hex, or a name); nil and why when it isn't loaded. It's destroyed for you when
---the world changes or your mod stops.
---@param id string
---@param x number?
---@param y number?
---@param z number?
---@return ChefUnit? unit
---@return string? why
function Chef.spawn(id, x, y, z) end

---Destroys a unit you spawned; false when it isn't one of yours.
---@param u ChefUnit
---@return boolean
function Chef.despawn(u) end

---Links child (its node 1 by default) to parent's node (a name or an index; 1 by default).
---@param child ChefUnit
---@param parent ChefUnit
---@param parent_node (string|integer)?
---@param child_node integer?
---@return true? ok
---@return string? why
function Chef.link(child, parent, parent_node, child_node) end

---Unlinks it.
---@param child ChefUnit
---@return true? ok
---@return string? why
function Chef.unlink(child) end

---A particle effect at a point; nil and why when it can't be made.
---@param id string
---@param x number?
---@param y number?
---@param z number?
---@return ChefParticles? handle
---@return string? why
function Chef.particles(id, x, y, z) end

---Stops an effect you made (only while it's still playing); false when it isn't one of yours.
---@param h ChefParticles
---@return boolean
function Chef.stop_particles(h) end

---How many lights a unit has.
---@param u ChefUnit
---@return integer
function Chef.lights(u) end

---Light i of a unit (1 by default).
---@param u ChefUnit
---@param i integer?
---@return ChefLight
function Chef.light(u, i) end

-- ---------------------------------------------------------------- timers, spreading work, a frame budget

---fn() once after s seconds.
---@param s number
---@param fn fun()
---@return ChefTimer?
function Chef.after(s, fn) end

---fn() every s seconds (a timer that errors 20 times stops).
---@param s number
---@param fn fun()
---@return ChefTimer?
function Chef.every(s, fn) end

---fn(item, i) for n items a frame; done(true) at the end, done(false) when a new world stops it.
---@generic T
---@param list T[]
---@param n integer?  items a frame (50 by default)
---@param fn fun(item: T, i: integer)
---@param done fun(finished: boolean)?
---@param opts ChefSpreadOptions?
---@return ChefJob?
function Chef.spread(list, n, fn, done, opts) end

---Your average ms a frame before the log warns and the performance monitor marks you; returns the budget in use.
---@param ms number?
---@return number
function Chef.budget(ms) end

-- ---------------------------------------------------------------- the game and the session

---A value from the game's settings file (user_settings.config), e.g. 'render_settings.render_resolution'.
---@param path string
---@return any
function Chef.setting(path) end

---True in an online session.
---@return boolean
function Chef.in_session() end

---True when this game is the host (true when not in a session).
---@return boolean
function Chef.is_host() end

---True while the loader's options menu is open (from 1.4.0; the 'menu' event says when it opens and closes).
---@return boolean
function Chef.menu_open() end

---How many players (you too). Checked at most once a second:
---for a change, listen to the 'players' event.
---@return integer players
function Chef.players() end

---How many of the session's players are still joining (from 1.4.0; 0 when not in a session). Checked at most once a
---second.
---@return integer
function Chef.joining() end

---This game's peer id.
---@return string?
function Chef.peer_id() end

-- ---------------------------------------------------------------- more drawing

---A filled triangle.
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param x3 number
---@param y3 number
---@param c ChefColor
---@param layer number?
---@return boolean? engine  true when the engine drew it, false when it was drawn as rects
function Chef.triangle(x1, y1, x2, y2, x3, y3, c, layer) end

---A filled circle.
---@param x number
---@param y number
---@param r number
---@param c ChefColor
---@param layer number?
function Chef.circle(x, y, r, c, layer) end

---A ring.
---@param x number
---@param y number
---@param r_in number
---@param r_out number
---@param c ChefColor
---@param layer number?
function Chef.ring(x, y, r_in, r_out, c, layer) end

---A piece of a ring, angles in degrees, 0 = up, clockwise.
---@param x number
---@param y number
---@param r_in number
---@param r_out number
---@param a0 number
---@param a1 number
---@param c ChefColor
---@param layer number?
function Chef.arc(x, y, r_in, r_out, a0, a1, c, layer) end

---Part of a texture (u, v from 0 to 1).
---@param tex string
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
---@param x number
---@param y number
---@param w number
---@param h number
---@param c ChefColor
---@param layer number?
---@return boolean
function Chef.bitmap_uv(tex, u0, v0, u1, v1, x, y, w, h, c, layer) end

---A sprite sheet: cols x rows pictures in one texture.
---@param tex string
---@param cols integer
---@param rows integer
---@return ChefSpriteSheet
function Chef.sprite_sheet(tex, cols, rows) end

---A message centered on a dark plate under the game's logo (the first plate's top 18% down the screen), with the
---loader's own notices (three at a time per mod); false when it wasn't shown. Its seconds only start once the game
---shows the ship or a mission (60 s at most after it could first be seen, if neither comes).
---@param text string  up to 80 bytes, cut on a character boundary
---@param seconds number?  4 by default (1 to 30)
---@param r integer?  the color: three numbers 0..255 (otherwise light gray)
---@param g integer?
---@param b integer?
---@return boolean
function Chef.notify(text, seconds, r, g, b) end

-- ---------------------------------------------------------------- more input

---The text typed this frame, and the raw list (read only: it's shared).
---@return string text
---@return string[] raw
function Chef.typed() end

---A key's name on the player's keyboard ('f9' -> 'F9'), for showing it.
---@param name string
---@return string
function Chef.key_label(name) end

-- ---------------------------------------------------------------- saving tables

---Saves plain data (no functions or cycles, 16 deep, 256 KB) to its own file in the loader's folder.
---@param name string  letters, digits, _ - (48 at most)
---@param t table
---@return boolean ok
---@return string? why
function Chef.save_table(name, t) end

---Reads a saved table back, or nil and why.
---@param name string
---@return table? t
---@return string? why
function Chef.load_table(name) end

-- ---------------------------------------------------------------- screenshots (trusted mods with the capture grant)

---Saves a picture of the screen (1.4.0). Only a mod whose TRUSTED entry grants `capture`; every other mod gets
---nil, 'not available to this mod'. It takes no arguments: the loader picks the render target and the file, in its
---own folder, named <author>_<mod>_capture_<nn>.dds with nn 01 to 50, then over again (the oldest written over).
---One a second at most. The engine's render target name and file format aren't confirmed on HD2 7.2 yet.
---@return string? file  the file's name (not its path)
---@return string? why
function Chef.capture() end

-- ---------------------------------------------------------------- the mod list and the index

---Every mod the loader found, with its state (the same list is in chef_loader_health.txt).
---@return ChefModEntry[]
function Chef.mods() end

---Which mod's copy of each resource the game loads. nil, 'building' until it's built (ask again on a later frame).
---@return ChefIndex? index
---@return string? why
function Chef.index() end

---In a boot-style script (`-- HD2-Boot:`), the helpers are this global.
---@type Chef
chef = nil
