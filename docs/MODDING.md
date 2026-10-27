# Making mods for Chef Shared Loader

Chef Shared Loader replaces the game's empty `boot` script and runs Lua mods on the current game build (Lua 5.1, with Easy
Anti-Cheat), for any mod author. Your mod ships a Lua file with a one-line header, and Chef Shared Loader:

- finds it in the installed mods and runs it;
- keeps it apart from every other mod;
- guards its engine calls, so a call that crashes the game is skipped from then on;
- merges its Arsenal options;
- hands it helpers for units, the camera, keys and drawing.

Players install Chef Shared Loader once, as its own mod, and every Chef Shared Loader mod works.

**Using the loader's code:** the snippets on this page and the mods in `examples/` are free to copy as they are. You
may also copy and adapt parts of the loader's own source into your mod to call its functions, detect it, or make your
mod work with it or the mods it runs; keep the line "Parts adapted from Chef Shared Loader by Th3chef" with what you
took. See [LICENSE](../LICENSE).

**Why not replace `boot` yourself?** The game runs only one `boot`: whichever mod deploys last. Two mods that both
replace it can't work together. With Chef Shared Loader, no mod but the loader touches `boot`, and deploy order doesn't matter.
A mod that must ship a `boot` can ship the loader's start-up stub as it (see [Carrying the stub](#carrying-the-stub)).

## Two ways to write one

| | Addon (`-- HD2-Addon:`) | Boot-style script (`-- HD2-Boot:`) |
|---|---|---|
| Written as | a module: returns a table with `update(dt)` and `shutdown()` | the game's boot style: global `init`, `update(dt)`, `render`, `shutdown` |
| Helpers | `chef` is passed in (`local chef = ...`) | `chef` is a global |
| Best for | new mods | porting a mod that used to replace `boot` |

Both run in their own locked-down environment (see [What your mod can reach](#what-your-mod-can-reach)). Globals you
define stay yours, `_G` is your environment, and the engine's script API (`stingray`, `Unit`, `World` ...) works as
usual. Both are crash-guarded and stay off after a crash until the mod is updated.

### Porting a boot-replacing mod

Two changes are enough:

1. Make the script's first line `-- HD2-Boot: mods/<you>/<your_mod>`.
2. Ship it as a Lua resource with any name except `boot` (use `mods/<you>/<your_mod>`).

Your `init`, `update`, `render` and `shutdown` are called as before, after Chef Shared Loader's own. There's one difference:
`_G` is your environment, not the game's, so assigning to `_G.x` doesn't touch other mods.

## Names and headers

- **The header** is the file's very first line, exactly `-- HD2-Addon: mods/<author>/<name>` (or `-- HD2-Boot:`,
  `-- HD2-Options:` for an options file, or `-- HD2-Lang:` for a language file, from 1.2.0). `<author>` and `<name>`
  use letters, digits, `_` and `-`; a name may have more parts (`mods/<author>/<group>/<name>`, from 1.2.0).
- **The author folder** should be unique to you (your handle). Two mods with the same full name run once: the one
  deployed last (the highest patch number).
- **Load order:** `mods/chef/...` (my own mods) start first, then everyone else's by name. A mod's requirements start
  before it (see Requirements below).
- **`-- HD2-Exclusive:` / `-- HD2-Fallback:`** (optional, among the first lines): which of your resources must win
  and which may be overridden (see "Which mod's copy the game loads").

## Options (Arsenal / HD2 Mod Manager)

- **Each option folder** ships a small Lua resource:

  ```lua
  -- HD2-Options: mods/you/my_mod
  return { fast = true, size = 'large' }
  ```

- **Merging:** Chef Shared Loader merges every ticked folder's table into `chef.options` (nested tables are merged one level
  deep). With nothing ticked, `chef.options` is `{}`.
- **Defaults:** Arsenal ticks every option and picks the first sub-option by default, so list the default first, and
  make a checkbox mean the default when it's ticked.

## Packing

`tools/pack_addon.py` builds an Arsenal-ready zip from a small `mod.json`:

```
python3 tools/pack_addon.py examples/hello_addon/mod.json out
```

- **What it writes:** a `core` folder with your Lua, one folder per option, and `manifest.json`. See the top of the
  script for the format.
- **The patch header:** pass `--header-from <a Lua patch that works on the current game>` if a game update changes
  the patch format.
- **Your mod page:** say "Needs Chef Shared Loader 1.0.0 or newer" in the mod's description and on its page.

**Examples:** `examples/hello_addon` (an addon with an option), `examples/hello_boot` (a boot-style script) and
`examples/utilities_test` (every api 3 utility, each result in its own log, util_test.log).

## The `chef` helpers (api 1)

`chef.api` is 3 in 1.0.0 (api 2 and 3 are the next two sections); everything in this one is api 1. It goes up only
when something is added, never for a change that breaks a mod. `chef.loader_version` is the loader's
version, `chef.name` your mod's name.

### General

| Helper | What it does |
|---|---|
| `chef.log(fmt, ...)` | A line in `chef_loader.log` (in `%APPDATA%\Arrowhead\Helldivers2`), prefixed `[mods/you/my_mod]`. |
| `chef.options` | Your merged options. |
| `chef.time()` | Seconds since the game started (the loader's clock). |

### Engine calls (crash-guarded)

| Helper | What it does |
|---|---|
| `chef.call('Table.function', ...)` | A guarded engine call, e.g. `chef.call('Unit.alive', u)`: an engine table from `stingray` (or an engine table among the game's globals). It returns nil plus a reason when the function is missing, raised an error, or is skipped after a crash. |
| `chef.call_kind('Table.function', kind, ...)` | The same, with its own crash key per `kind` (so a crash on one unit kind only skips that kind). |

### World, camera and units

| Helper | What it does |
|---|---|
| `chef.world()`, `chef.world_id()` | The main world once it has settled (nil before); its id changes with every new world. |
| `chef.in_mission()` | True in a mission (not the ship, not loading). |
| `chef.camera()` | The view camera: `{ x, y, z, fx, fy, fz, yaw, fov }` (position, forward, yaw in radians and the vertical field of view when the engine gives it), or nil while there's none. Read only: the table is shared by every mod. When the camera is lost, the loader looks for it again over a few frames. |
| `chef.world_to_screen(x, y, z)` | Screen pixels (bottom-left origin), or nil when behind the camera. |
| `chef.watch(kinds, every)` | Lists units of the given resource ids (`{ ['a57ae2a703c02899'] = true }`) every `every` seconds (5 by default), spread over frames. Returns `w` with `w.items` (`{ unit, kind, x, y, z }`), `w.generation` (bumps on each new list) and `w.pause()`, `w.resume()`, `w.refresh()`, and `w.stop()` to drop the watch for good. Runtime-built units (`46cab355bd8d4d37`) are never listed (asking where one is ends the game). A mod that stops loses its watches. |
| `chef.mission_kinds(kinds)` | Unit ids that only exist in missions. The loader tells a mission by its level count; these ids are only used if the engine can't count levels (from 1.2.3). |

### Input

| Helper | What it does |
|---|---|
| `chef.key_down(name)`, `chef.key_pressed(name)`, `chef.key_known(name)` | Keyboard, by the engine's key names (`'f7'`, `'tab'`, `'left ctrl'`, ...). |
| `chef.mouse_down(name)`, `chef.cursor()`, `chef.wheel()` | Mouse buttons, the cursor, and the wheel this frame. |

### Drawing

| Helper | What it does |
|---|---|
| `chef.screen()` | The screen's width and height. |
| `chef.color(r, g, b, a)` | A color for this frame. |
| `chef.rect(x, y, w, h, c, layer)` | A filled rectangle; bottom-left origin. Layers 880-960 are the usual range (higher draws on top). |
| `chef.text(x, y, s, px, c, layer)` | Text in capitals (in the player's language when a language file has it), 7 `px` tall, its left end at x and its bottom at y; returns its width. In the game's own font (FSSinclair Medium) once the game has it loaded, else the loader's pixel font (capitals, digits, `. , : - + / % ( ) ! ?`). |
| `chef.text_width(s, px)` | Its width in the font in use (measured: the game's font is proportional). |
| `chef.text_fit(s, px, w)` | The text cut to `w` wide, ending in `...` when it was cut. |
| `chef.text_wrap(s, px, w, most)` | The text broken into lines `w` wide at spaces (at most `most`, 64 if not given). |
| `chef.lang()`, `chef.tr(s)` | The language picked (its name and code; nil for English), and a text as that language has it (see "Language files"). |
| `chef.sprite(x, y, rows, cell, colors, layer)` | A pixel sprite: `rows` are strings, each character a key in `colors`. |
| `chef.bitmap(tex, x, y, w, h, c, layer)` | A texture shipped in your patch (its resource id as hex), tinted `c`. Returns false when it can't be drawn: then draw something else. |
| `chef.ui_textures(map)` | Texture → its copy for below-native drawing. |
| `chef.texture_sizes(map)` | Texture → pre-shrunk sizes `{ width, id, ... }`, smallest first. |
| `chef.line(x1, y1, z1, x2, y2, z2, c)` | A line in the world. |
| `chef.TOP` | Add it to a layer to draw over the game's HUD, map and menus: `chef.TOP + 0` to `chef.TOP + 999` show over all of them but the menus' top bar and button prompts (the loader's own menu is at 950-959, its monitor at 940-949, its notices at 930-939); higher ones only over the HUD and the map. While the loader's full screen menu is open, top-world texts under it aren't drawn (below native render scale, that's every text but the menu's). Without it, a mod draws under the game's HUD and menus. From 1.1.0: `chef.TOP + N` drew under the game's menus there; to keep that placement, add 1000. |

## Shared services (api 2)

Check with `chef.api >= 2` (or `chef.has and chef.has('menu')`) before using these, so your mod still runs on an older
loader. An older loader has no `chef.has`: calling it there is an error, so test that it's there first.

### Start-up and capabilities

| Helper | What it does |
|---|---|
| `chef.capabilities` | Read-only. `api` (the level, 3), and true for each of: `after_startup`, `settings`, `share`, `events`, `require`, `bind`, `menu`, `shims`, `dev`, `logs`, `own_log` (api 2) and `units`, `spawn`, `timers`, `budget`, `session`, `settings_file`, `shapes`, `sprite_sheets`, `notify`, `typed`, `key_labels`, `save_table`, `mods` (api 3). |
| `chef.has(name)` | True when the loader has that capability (`chef.has('api')` is true too). |
| `chef.after_startup(fn)` | Runs `fn` once every mod has started (so other mods' shared values, exports and menu rows exist). Called at once when start-up is already over. |
| `chef.log_directory` | The folder the loader's files are in (`%APPDATA%\Arrowhead\Helldivers2`), without a trailing `\`. Keep your own files there (`.log .txt .json .csv .dat .ini .marker .fatal`). |
| `chef.previous_directory` | Where older builds of the loader kept its folder (`%LOCALAPPDATA%`), or nil. You may read your own `.log .txt .json .csv .dat .ini .marker .fatal` files there; a read of a missing file in `chef.log_directory` already falls back to it. |
| `chef.own_log(name)` | From now on your `chef.log` lines go to `<name>.log` in that folder instead of `chef_loader.log` (no `[mods/...]` prefix there; a fresh file each launch once it passes 1 MB). The loader's own lines about your mod (started, Lua errors, crashes, timings) stay in `chef_loader.log`. Call it first thing; returns false and keeps logging to `chef_loader.log` when the name is taken or the file can't be opened. Names are letters, digits, `_ -`, 48 at most, and can't start with `chef_loader`. Check `chef.has('own_log')`. |
| `chef.log_file` | The full path of the file your `chef.log` lines go to. |

### Saved settings

| Helper | What it does |
|---|---|
| `chef.save(key, value)` | Keeps a boolean, number or string (up to 512 characters) between launches. `nil` removes it. Keys are letters, digits, `_ . -`. Written at most every 3 s and at shutdown. |
| `chef.load(key, default)` | What was saved, or `default`. |

Each mod's keys are its own: two mods can both save `size`.

### Between mods: shared values, events, exports

| Helper | What it does |
|---|---|
| `chef.share(name, value)`, `chef.shared(name)` | A value any mod can read by name. Use your mod's name in it (`'you.my_mod.data'`). |
| `chef.on(event, fn)` | Calls `fn(...)` for every `emit` of `event`. Returns a function that ends the subscription (it's removed). A listener that errors 20 times is switched off, and a mod that stops loses its listeners. |
| `chef.emit(event, ...)` | Calls every listener; returns how many ran. |
| `chef.require(name, want)` | The table another addon returned (its exports), when it runs and its `version` is `want` or newer; else nil and a reason. |

The loader's own events:

| Event | Arguments | When |
|---|---|---|
| `startup` | | Once, after every mod started and the `after_startup` callbacks ran. |
| `world` | world id, in a mission | A new world has settled. |
| `mission_start`, `mission_end` | world id | A mission starts; the mission ends (extraction, quitting, a new world). |
| `shutdown` | | The game closes. |

**Requirements.** `-- HD2-Requires:` lines among the file's first lines name what the mod needs:

```lua
-- HD2-Addon: mods/you/my_mod
-- HD2-Requires: chef-shared-loader >= 1.0.0
-- HD2-Requires: mods/you/my_lib >= 1.2
```

Required mods start first. A mod whose requirement is missing, too old or in a circle isn't started, and the log says
why (for example `not started: mods/you/my_mod needs mods/you/my_lib 1.2 or newer (1.1.0 is installed)`).
`chef-loader` works as the loader's name too.

### The options menu and key bindings

The loader draws one menu for every mod's options, over everything, anywhere in the game. **F9** opens and
closes it (players can change that key in the menu itself). It opens on the list of mods: the loader's own entry
first, under a divider, then the mods in alphabetical order by title (your `chef.title`); **Up/Down** picks a mod and **Enter** (or **Right**) opens its options, in the
order your mod registered them. Every screen under the list starts with a **< Back** row (Enter on it returns to the
list, where the cursor was; **Backspace** does the same from anywhere). In a mod's options, **Up/Down** (Page Up/Down)
picks a row, **Left/Right** changes it, **Enter** toggles or starts a key capture, and **Delete** puts the default
back. **Escape** closes the whole menu. In a key capture, any key binds it, **Delete** sets none and **Escape**
cancels. **/** starts a search across every mod: type part of a mod's or a row's name, **Backspace** (or Delete)
takes a letter off, **Enter** keeps the search, **/** again or **Escape** leaves it. While the menu is open its keys and mouse buttons
are its own: your mod's `Keyboard` / `Mouse` reads of them (`pressed`, `released`, `any_pressed`, `button`,
`keystrokes`), `chef.typed()` and `chef.bind` keys answer nothing pressed, so a search never fires your hotkey (the
mouse's movement and cursor still read as always). The game itself still sees the keys, in the menu and while a search is typed (so
W walks, and Escape and Enter also reach its pause screen and chat; Delete erases and **/** leaves a search without
that). Values are saved between launches. A mod with no options isn't listed.

| Helper | What it does |
|---|---|
| `chef.title(text)` | Your mod's heading in the menu (its name otherwise). |
| `chef.option(id, spec)` | Adds a row and returns its current value. Ids are letters, digits, `_ . -`. `spec`: `{ type = 'toggle' \| 'choice' \| 'slider' \| 'key', label, default, ... }`. A choice has `choices` (2 to 32 strings; the value is the index), a slider `min` < `max` (finite numbers) and optionally `step` (0 or more; values snap within the range). A spec that doesn't fit is refused with the reason. A row at its default isn't stored, so a new default in an update reaches players who never changed it. |
| `chef.get(id)`, `chef.set(id, value)` | Read or change a row. |
| `chef.on_change(id, fn)` | `fn(value)` whenever the row changes (from the menu or `set`). Up to 64 per row; it stops when your mod stops. |
| `chef.bind(id, default_key, label)` | A key row (key names in any case: `'F6'` is `'f6'`). Returns `b` with `b.key()` (`'off'` for none), `b.pressed()` and `b.down()` for this frame. A key two rows use is marked `!` in the menu and noted in the log; with that row selected, the hint line names the other options on the key. |

Arsenal options (`chef.options`) still work and stay the place for what has to be chosen before the game starts (which
textures ship, for example). A good pattern: take the Arsenal value as the menu row's default.

```lua
local chef = ...
if chef.has and chef.has('menu') then
  chef.title('My Mod')
  chef.option('size', { type = 'choice', label = 'Size', choices = { 'Small', 'Large' }, default = 1 })
  local ping = chef.bind('ping', 'f6', 'Ping')
  -- in update: if ping.pressed() then ... end
end
```

### Mods written for Bingus Shared Loader, Boot Mod Loader and Mod Options Menu

The loader gives Lua-only mods written for those loaders the same calls they had there (the parts that needed `ffi` or
the JIT can't come back). Each mod gets its own read-only copy of each, tied to that mod: what it registers stops when
it stops, and no mod can replace another's. When nothing else defines them, they're also in the game's globals.

- `CowboyBingusModLoader` (also as `HD2ModLoader`): `version` 17, `api` 1, `revision`, `capabilities`,
  `after_startup(fn)`, `on_update(id, fn)` (once a frame with `dt`; the same id replaces its function; a function that
  errors is dropped and logged), `on_shutdown(id, fn)` or `on_shutdown(fn)`, `log_directory`, `open_log(name)` (a `.log`
  file in the loader's folder, started fresh at each launch), `game` (`build_identifier`) and `modules` (each mod's
  state in those loaders' words: `loaded`, `loading`, `load failed: ...`). Every callback is timed into the mod's line
  in the performance monitor and crash-guarded like the mod's own hooks.
- `ModOptionsMenu` (version 3): `register_option(id, spec)`, `get`, `set`, `on_change`, `ready`. Its rows appear in this
  menu under the mod's heading (`spec.mod_id`, else `spec.mod`, else the mod's name; 32 options a heading). An option
  with no value saved here yet starts from the value the mod had before: `mom_<mod>_settings.txt` in the game's folder,
  else the old menu's `ModOptionsMenu.values`. Any id saves, spaces and all.
- `ModBindingsMenu`: `register_binding`, `is_down` (press, hold or release), `poll`, `set_binding`, `binding`. Each
  binding is a key row in this menu under the mod's heading. While this menu is open, `is_down` is false.
- `BingusRuntime`: `shared(env)`, `guard(spec)` and `install()`, with the same status fields; its guards are ticked by
  the loader.
- `package.loaded['mods/x/y']` and `require('mods/x/y')` give another running mod's module (or `true` while it starts
  or when it returned nothing).
- **The engine through `rawget`:** `rawget(_G, 'stingray')`, `rawget(_G, 'Unit')` and the like find the engine as the
  mod sees it (a table that's off reads as `false`). Lua's own base functions (`rawget(_G, 'unpack')` ...) are there
  too.
- **The game's lower case globals** (what the engine adds next to Lua's own, taken when the loader starts) are your
  own: a value as it is, a table as your own copy, so nothing you write into one reaches the game or another mod.
  `chef_loader.log` lists them at start-up. A lower case global set later, and the game's `init`, `update`, `render`
  and `shutdown`, aren't reached. Capitalized game globals are read as they are.
- **The game's callbacks:** a mod's globals start with empty `update`, `render` and `shutdown`. A mod that keeps the one
  it finds and sets its own (the old loaders' way of hooking in) has that one run as its hook, guarded and timed like
  any other. This is only for a mod that returns nothing, or a table with no hooks and no functions
  (`{ installed = true }`): a mod returning hooks or an API never has a global named `update` run as one.
- **`require('ffi')` / `require('jit')`:** the game has neither since 7.2.0. A mod that asks gets an error, and the log
  says once that what in it needs them won't work, even when the mod catches the error and carries on. `ffi` and `jit`
  read as `false`, even when another loader left a stand-in for them in the game's globals.

### Mods written for the HD2 Lua Runtime

The HD2 Lua Runtime (0.1.0) is another loader's boot script, shipped inside the mods made for it. Chef Shared Loader
runs those mods on a look-alike of it, so they work without it (its own boot isn't run; the log says it isn't needed):

- **`HD2Runtime` and `require('hd2rt')`:** `version` (`'0.1.0'`), `api` (1), `mod(spec)`, `status()` (with
  `log_dir`, the loader's folder) and `frame()`.
- **`HD2Runtime.mod(spec)`:** `spec.id` (letters, digits, `_ . -`), `api` (1 or nil), `name`, `lobby_key` and `bones`
  (16-hex unit resources). It returns a handle: `id`, `engine`, `raw` (your own `stingray`, as locked down as the rest), `on(event, fn)` (`update`,
  `render`, `shutdown`, and `stop`: see below), `log(...)`, `state()`, `switch_off(why)`.
- **Saying what you need:** `spec.needs` lists the engine calls (`'Material.set_texture'`) and the grants (`'lobby'`,
  `'files'`, `'patches'`; see Trusted mods) your mod can't do without, 64 at most. The loader checks them when you call
  `mod()`: whatever it lacks is in `handle.missing()` (a new list, empty when everything is there), in the log, in a
  notice for the player and in `chef.mods()` / `chef_loader_health.txt` (`missing`). The mod still starts, so it can
  carry on without those parts and say so itself.
- **Asking for access:** `handle.request(what, why)` with `'lobby'`, `'files'` or `'patches'` and a short reason, before
  the work that needs it. It answers `'granted'`; `'asked'` (the player has to turn on its row in the options menu and
  has been told, with your reason in the log; ask again later); or `nil, 'not given to this mod'` (the loader doesn't
  give it to your mod: the log and a notice say so once, so the player knows what to report). Asking first means a
  mod never does a long job only to have its result refused.
- **The callbacks** run with the mod's own hooks, each in its own `pcall`. A file may return `true` (or nothing).
- **`handle.engine`** has that runtime's calls in its own shapes:
  - `Gui.rect` and `Gui.rects` take plain numbers; `Gui.text` takes a font from its list;
  - `World.spawn_unit` takes a resource name or 16-hex id;
  - `Window.ui_state()`, `Mouse.axis(i)`, `Keyboard.pressed(name)` and the rest;
  - `Application.can_get(type, id)` for `unit`, `material`, `texture`, `font`, `runtime_font` and `package`;
  - `IdString64`, `Vector3`, `Quaternion` and `Matrix4x4` (with no arguments too, `Vector3.zero()`); a nil among the
    arguments, a trailing one too (the answer to a refused call, say), is refused, not passed to the engine. `chef.call`
    answers four values padded with nils, so hand these the values you need, not a `chef.call(...)` straight in.

  Each call is the mod's own:
  - its first call is breadcrumbed for it;
  - a unit is checked before it's asked anything (with the loader's unit rules);
  - a refused call returns `nil, why`.
- **Live palette materials** (that runtime's private-material calls, with its rules and refusals, word for word): a
  mod recolours its own copies during play, without a restart.
  - `Material.private_aliases(list)` declares the mod's private materials, `{ { id = '<16 lower-case hex>', slots =
    { 'material_lut', ... } }, ... }` (slot names letters, digits and `_`, 64 at most). It replaces the mod's last
    declaration and writes nothing.
  - `Material.set_private_texture(mat, variable, texture)`, `Material.reinitialize_shader(mat)` and
    `Mesh.refresh_instance_hash(mesh)` work only on a material (or a mesh with one) that is declared, of a unit the mod
    spawned **in this frame**, read in this frame. Anything else is refused before it reaches the engine: the game's
    own materials (shared by every unit that wears them), a copy from an earlier frame, an undeclared slot, a texture
    that isn't loaded. The recipe that works is the order above: every slot's texture, then the shader, then the
    mesh. Each call is protected and its answers checked (`'unobserved return shape'` if the engine answers otherwise).
  - `Unit.paint_private_cape(u, alias, fields)` paints the game's own medium cape (the one cape whose layout is known)
    with a declared private material: `fields` gives all five of `material_lut`, `cape_lut`, `cape_gradient`,
    `decal_sheet` and `cape_scalar_fields` (16-hex loaded textures). The loader binds the material by the cape's slot
    first and reads only the new private instance; `Unit.restore_private_cape(u)` binds the game's material back by
    that slot without reading the painted meshes. A painted cape is one mod's at a time (another's paint or restore is
    refused), and once painted it can't be read or swapped through `Unit.mesh` / `Unit.set_material_at` again
    (`'native cape reads require a fresh private transaction'`): paint it again instead.
  - A call the game build lacks the engine functions for isn't there (`handle.missing()` names it, with
    `spec.needs`).
- **What it made is undone when it stops:** the game's capes it painted (put back by their slot first, before anything
  else), its units, its GUIs, the units it hid, the materials it swapped on the game's units and the mouse dead zones
  it changed. Textures it set with `Material.set_texture` can't be: the engine
  can't tell what a material had before. Put those back yourself in `handle.on('stop', fn)`, which the loader calls
  once when it stops your mod (errors, a failed start, a dev reload), before it undoes anything, while your engine
  calls still work. (`stop` is Chef Shared Loader's own; the HD2 Lua Runtime itself never calls it.) A mod that
  switches itself off (`handle.switch_off`) gets no `stop` afterwards: put things back before you call it.
- **Shared globals:** a capitalized global one runtime mod sets (`NativeNotification`, say) reaches the other runtime
  mods, as in that runtime, where they share one `_G` (one set before `HD2Runtime.mod()` too). A name the game
  already has never does. A trusted mod's globals stay its own, except the one its place on the list names as its
  view (below), and it takes only the shared globals its place on the list names, each from one named mod. When a
  mod stops, what it shared isn't handed to mods that start later; mods that have it keep their copy. A stopped mod's `HD2Runtime.mod()` is refused.
- **The Steam lobby** (`Steam.user_id`, `Friends.playing_game`, `Network.join_steam_lobby`, `SteamLobby.*`) is only
  for mods the loader trusts with it (below): the lobby the game reports this player in (`Friends.playing_game` takes only the player's own id), the mod's own
  `lobby_key` (the one the loader's list gives it), values up to
  1 KB and 10 writes a second.

### Trusted mods

A short list in the loader (`TRUSTED` in `src/loader.lua`) names mods that get more than the locked-down space,
each only what it needs. Today it's HD2 Transmog (`mods/hd2tm/transmog`):
- **The Steam lobby** through the HD2 Lua Runtime look-alike.
- **Its own files in `%LOCALAPPDATA%`** (the 1.0 and 1.1 saves, and the shared-look files).
- **Game patch files**, only once the player turns on "Game patch files: HD2 Transmog" in the options menu (a notice
  says so the first time the mod asks):
  - its scratch file in `data\`, and patches carrying its marker;
  - a file only takes a patch's name by being renamed to it, and it's checked first: its table of contents must be
    the layout the loader knows (the type counts add up to the rows), it must not replace the game's `boot` script,
    and every Lua resource in it must be comment lines only, the size the row gives, with no stream or GPU data;
  - a file still open for writing is never renamed or removed: close it first (a handle you drop is closed for you
    when it's collected).
- **A read-only view for the other runtime mods:** its `TransmogUI` global, with only `version`, `snapshot()` (just
  `api_version`, `revision`, `context`, `applied`, `capabilities` and `health`; not its catalog), `worn(group)` (the
  native pieces it wears in `'armor'`, `'helmet'` or `'cape'`, and its avatar) and `report()` (what its last apply
  spawned, with the materials it swapped). Nothing that applies, saves, builds or opens anything.
  - Each answer is a copy: tables are new tables (functions left out, units as they are, 8 deep and 4,000 values at
    most), so changing one changes nothing in HD2 Transmog.
  - Arguments are plain values only (nil, booleans, numbers, strings up to 256 characters).
  - Each call is guarded under the reading mod's own crash key (`TransmogUI.worn`, say): one that ends the game is
    skipped for that mod from then on.
  - When HD2 Transmog stops, the calls answer `nil, 'not running'`; when it starts again (a dev-mode reload), the same
    view reaches it again, so keeping `TransmogUI` in a local is fine.
  - Each call costs what HD2 Transmog takes to answer plus the copy: call them a few times a second at most, not
    every frame.
  - No other mod's value is ever shared under the name `TransmogUI`. Its module (what it returns) isn't handed to other
    mods through `package.loaded` either.
- **What a trusted mod takes from the others:** only the shared globals its place on the list names, each from one
  named mod, as its own copy (made when that mod sets it, so a change another mod makes to the shared table never
  reaches it). HD2 Transmog takes only `NativeNotification`, from the Native Notification its package carries
  (`mods/native_notification/core`). If another mod sets that name first, HD2 Transmog goes without it and the log
  says so.

A name isn't proof of who made a mod, which is why writing game files also waits for the player. To ask for a place
on the list, open an issue on GitHub with what the mod needs and why.

### Dev mode (test builds of the loader only)

For working on a mod without packing and deploying it each time. Dev mode only exists in a test build of Chef Shared
Loader (its log's first line says `Test N`); the release build ignores `chef_loader_dev.txt`.

1. Make `chef_loader_dev.txt` in the loader's folder (`chef.log_directory`).
2. Put one Lua file's full path on each line (`#` starts a comment). Each file needs its header line, like a deployed
   mod. Add `reload = f11` to pick the reload key (F11 by default).
3. Launch the game: the files load like mods (a dev file wins over a deployed mod with the same name), and the screen
   says DEV MODE.
4. Edit a file and press the reload key: those mods start again. Their menu rows keep their values; their event
   listeners and change callbacks are dropped and set up again by the new copy.

Delete the file (or empty it) to turn dev mode off.

### Text in the game's font

`chef.text` is drawn in the game's own font, FSSinclair Medium (the HUD's), once the game has it and its material loaded
(FSSinclair Regular or a locale's UI font when Medium isn't there, as on a Russian client). The loader keeps each text:
you still call `chef.text` every frame, and a text that didn't change since the last frame costs no engine call; one
that did is changed in place. What you didn't draw this frame is gone in the next. Lay text out with
`chef.text_width` / `chef.text_fit` / `chef.text_wrap`, not a count of characters: letters are of different widths. The
pixel font is used until the font is loaded, or if text calls fail; the same calls work either way.

Two things differ from the pixel font:
- **Text is on top of shapes:** in the game's font, text draws over every rect, sprite and bitmap of the same screen
  (the main one, or the one at `chef.TOP` and above), whatever its layer. Text layers still order text among itself.
  Don't put a rect over text to hide it: stop drawing the text instead.
- **Letters have different widths:** a layout that counts characters (`#s * 6 * px`) is off. Use `chef.text_width`.
- **UTF-8 text** (from 1.2.0): the game's font takes UTF-8 whole, measured and cut a character at a time (a cut or a
  wrapped line never splits one). A character the font has no glyph for, or a byte that isn't UTF-8, shows as `?`. The
  pixel font shows each non-ASCII character as one `?`. Only A-Z are put in capitals.

### Language files (from 1.2.0)

A language file translates the loader's menu, monitor and notices and every mod's text at once: every text drawn
through `chef.text` (and measured with `chef.text_width`, `chef.text_fit`, `chef.text_wrap`) is looked up first. It's
a Lua resource that returns only data:

```lua
-- HD2-Lang: mods/<you>/<language>
return {
  name = 'Deutsch',                      -- shown in F9 > Chef Shared Loader > Language (40 bytes at most)
  code = 'de',                           -- optional: what chef.lang() gives mods
  text = {                               -- English as drawn (any case) = the translation
    ['ALL MODS'] = 'ALLE MODS',
    ['PERFORMANCE MONITOR'] = 'LEISTUNGSANZEIGE',
  },
  patterns = {                           -- optional, tried in order when no exact text matches (Lua patterns on
    { '^FRAME (.*)$', 'BILD %1' },       -- the text in capitals)
  },
}
```

- **Data only:** before it runs, the loader reads its code (strings and comments aside) and takes only names, numbers,
  `{ } [ ] = , ; .` and spaces, and of Lua's keywords only `local`, `return`, `nil`, `true` and `false`: no loops,
  functions, conditions, calls, operators (a minus sign included) or `..`, so write every text whole. 4 MB at most a
  file, 64 files in all (the highest patches), about 2 s of reading at start-up (files past that, the highest patches,
  are left out, every launch while it lasts); a file that takes over 5 s to read is skipped from the next launch on
  until it changes. It runs once at start-up with nothing to reach; a file that ends the game is skipped from the next
  launch on (a changed file is tried again). Texts are checked (1 to 300 bytes, a translation up to 300; 20,000 texts
  at most), and so are patterns (200 at most); the first 5 things left out of each file are named in the log. 31
  languages at most. A translation that is itself another entry's English text is translated again where it's drawn:
  keep them apart.
- **Patterns:** each must start with `^`, have at most 2 of `*`, `+` and `-` (not 2 together with a `?`, and at most
  24 classes such as `.`, `%a` or `[...]` after the first of 2; letters and spaces don't count) and 3 of `?`, use only
  captures it has closed (32 at most; `%0` the whole match, `%%` a percent sign), have no zero byte or `%z`, and be
  quick on a few long test texts, some made from its own letters (it's timed at start-up, with about 100 ms of timing
  a file: patterns past that are left out). Keep patterns simple: one that's slow is left out. It's tried on the text
  in capitals, so its captures come out in capitals; texts longer than 160 bytes only match exactly. Pattern work is
  held to about 1 ms a frame (looked at after each pattern; each new text also costs a little), so a new text can show
  in English for a frame before its pattern is found.
- **Capitals:** texts are drawn in capitals, but only A-Z are made capitals: write accented letters as capitals (`É`,
  not `é`).
- **One language, several files:** files with the same `name` are merged; a higher patch's entries win (its patterns
  are tried first). So a mod can ship its own texts for a language as a file of its own.
- **The choice is kept by name:** adding or removing a language file never changes the language picked (one that's
  missing for a launch gives English and comes back when it's installed again). With one language installed and none
  picked before, it's on.
- **Finding what to translate:** while a language is on, every text with two letters in a row, no digits and no entry
  is written (once, 3,000 at most) to `chef_loader_lang_missing.txt` in the loader's folder, as lines ready to copy
  into `text`: the texts drawn, and every mod's option texts in the menu, scrolled to or not. Texts over 300 bytes and
  the languages' own names aren't listed. Picking another language writes the list first; the next language's list
  starts empty.
- **Lines the menu puts together** (the hint for a key two options use: `F7 ALSO USED BY: SOME MOD (TOGGLE)`) are
  made from texts translated one by one (`ALSO USED BY:`, the mods' titles and labels), so they need no pattern.
- **The menu's hint lines** are drawn as pairs, each key (`ARROWS`, `ENTER`, `/`, `ESC`, `DEL`, `BKSP`, `CLICK`, `<`
  `>`, `RIGHT CLICK`, `WHEEL`, the menu key) a light chip followed by what it does (`MOVE`, `OPEN`, `CHANGE`,
  `SEARCH`, `CLOSE`, `BACK`, `DEFAULT`, `CANCEL`, `NONE`, `ERASE`, `EXIT`, `PICK`, `SCROLL`, and `PRESS A KEY` / `TYPE
  TO SEARCH` on their own), each key and word translated on its own: translate the pieces, not the whole line (since
  1.2.2). A pair that doesn't fit is left out whole (the arrows' first).
- **Texts with a number** (`HIDE MODS UNDER 1 MS`, `MODS UNDER 1 MS`, `FRAME 16.7 MS  60 FPS`) need a pattern, and
  aren't listed as missing.
- **Fonts:** the game's font has CJK glyphs (the log says "CJK glyphs: yes"); in the pixel font, non-ASCII text shows
  as `?`.
- **For mods:** `chef.lang()` gives the language's name and code (nil for English); `chef.tr(s)` gives a text as the
  language has it (for a text you lay out yourself; ask again rather than keeping it forever: it can still be English
  for a frame). A text that changes every frame (a number) is best kept apart from its label, so the label has one
  entry.
- Packing: `tools/pack_addon.py` takes a language file like an addon (`"lua": [{"resource": "mods/you/de", "file":
  "de.lua"}]`).

### Drawing every frame

An addon's table can have `render()` besides `update(dt)`; the loader calls it after the game's render each frame.
The loader looks `update`, `render` and `shutdown` up in the table at every call, so you can set or swap them later.
Boot-style scripts keep their global `render`.

`on_stop()` in the table is called once when the loader stops your mod (20 errors, a start that failed half-way, a
dev-mode reload), before it forgets your timers, watches and events: put back what only you know there, such as
textures you set on the game's materials (the engine can't tell the loader what a material had before). It's
breadcrumbed as `<mod>|on_stop`; one that ends the game is skipped from then on. (An HD2 Lua Runtime mod's
`handle.on('stop')` callbacks run too.)

## Utilities (api 3)

Check with `chef.api >= 3`, or `chef.has('units')`, `chef.has('spawn')` and so on (the names are listed under
`chef.capabilities` above).

### Units, safely

Some engine calls end the whole game instead of raising a Lua error. The loader refuses the known ones before they reach
the engine, in these helpers and in `chef.call` / `chef.call_kind` too (each refusal is logged once per mod):
- everything in `Localizer` (`Localizer.lookup` ends the game; the game doesn't use the engine's Localizer);
- on a runtime-built unit (one that isn't a unit file, like `#ID[46cab355bd8d4d37]`, about 1,400 a mission): its
  position, rotation or pose (`Unit.world_*`, `Unit.local_*`), its meshes (`Unit.num_meshes`, `Unit.mesh`,
  `Unit.set_mesh_visibility`) and moving it (`Unit.set_local_position`, `_rotation`, `_scale`, `_pose`, and every
  `Unit.teleport_...`);
- `Unit.has_camera` without a camera name;
- those same unit calls on a unit from an engine world that's gone. Units are stamped with the engine world they were
  seen in: within one engine world (the ship is loaded into the mission's) a unit stays usable; one from the world
  before is refused.

Also refused, because quality-of-life mods have no business with them: everything in `PluginManager` (native code),
`Http` and `WebSocket` (the network), `Network.write_dump_tag`, and writing other players' game
(`GameSession.set_game_object_field`, `create_game_object`, `destroy_game_object`, `migrate_game_object`,
`migrate_game_session_host`).

These are refused only through `chef`: the game's globals are still there, and calling them directly skips this
safety net.

| Helper | What it does |
|---|---|
| `chef.unit_kind(u)` | The unit's resource id (16 hex digits), cached until the world changes. |
| `chef.unit_alive(u)` | True while it's alive, in this world. |
| `chef.unit_position(u, node)` | x, y, z (node 1, its root, by default); nil for a unit that can't be asked. Crash keys per kind. |
| `chef.unit_rotation(u, node)` | Forward x, y, z and the yaw (radians, 0 = +y). |
| `chef.unit_node(u, name)` | A node's index, or nil when the unit has no such node. |
| `chef.units_near(x, y, z, r, w)` | The units of watch `w` (or of all your watches) within `r` of a point, nearest first: `{ unit, kind, x, y, z, d }`. From the watches' last lists: no extra scan. |

### Spawning, with clean-up

Everything made here is destroyed for you when the world changes (`chef.world_id()` changes) and when your mod stops
(20 Lua errors, a start that failed half-way, a boot-style script stopped after 20 errors, or a dev-mode reload). A new
engine world is never touched: the old world's things are simply forgotten. A particle effect that ended by itself (a
one-shot) is dropped from the list and never destroyed again, and units the game destroyed are dropped too.

| Helper | What it does |
|---|---|
| `chef.spawn(id, x, y, z)` | Spawns a unit (its resource id as hex, or a name); nil and a reason when it isn't loaded. |
| `chef.despawn(u)` | Destroys one you spawned. |
| `chef.link(child, parent, node, child_node)` | Links child (node 1 by default) to parent's node (a name or an index). |
| `chef.unlink(child)` | Unlinks it. |
| `chef.particles(id, x, y, z)` / `chef.stop_particles(h)` | A particle effect, and stopping it (only while it's still playing). |
| `chef.lights(u)` / `chef.light(u, i)` | How many lights a unit has; light `i` with `set_color(r, g, b)` (0-255), `set_intensity(v)`, `set_enabled(on)`, `set_falloff(start, end)`, `set_shadows(on)`. |

Ship the unit or effect in your patch (or use one the game has loaded): `Application.can_get` decides.

### Timers, spreading work, a frame budget

| Helper | What it does |
|---|---|
| `chef.after(s, fn)` | `fn()` once after `s` seconds. Returns `{ cancel(), active() }`. |
| `chef.every(s, fn)` | `fn()` every `s` seconds (a timer that errors 20 times stops). |
| `chef.spread(list, n, fn, done, opts)` | `fn(item, i)` for `n` items a frame; `done(true)` at the end, `done(false)` when a new world stops it (`opts.keep = true` carries on: only for lists without units). Returns `{ cancel(), active(), progress() }`. |
| `chef.budget(ms)` | Your average milliseconds a frame before the log warns and the performance monitor marks you (the loader's Budget row, 1 ms, by default). |

Your time is your hooks plus your timers and spread jobs, divided by the frames the game ran: a mod that only uses
timers is measured too. It's checked against your budget every minute (a warning at most every 10 minutes). Timers and
jobs made inside a timer or job start on the next frame.

### The game and the session

| Helper | What it does |
|---|---|
| `chef.setting(path)` | A value from the game's settings file (`user_settings.config`), e.g. `'render_settings.render_resolution'` (a table), `'screen_resolution'`, `'fullscreen'`. The loader reads the file again on a world change or a new screen size, else at most every 30 s. |
| `chef.in_session()`, `chef.is_host()`, `chef.players()`, `chef.peer_id()` | In an online session; this game is the host (true when not in a session); how many players; my peer id. Checked at most once a second. |

### More drawing

| Helper | What it does |
|---|---|
| `chef.triangle(x1, y1, x2, y2, x3, y3, c, layer)` | A filled triangle. The engine's own when the game draws them, rows of rects otherwise (the log says which). |
| `chef.circle(x, y, r, c, layer)`, `chef.ring(x, y, r_in, r_out, c, layer)` | Filled circle; ring. |
| `chef.arc(x, y, r_in, r_out, a0, a1, c, layer)` | A piece of a ring, angles in degrees, 0 = up, clockwise. |
| `chef.bitmap_uv(tex, u0, v0, u1, v1, x, y, w, h, c, layer)` | Part of a texture. |
| `chef.sprite_sheet(tex, cols, rows)` | A sheet; `sheet.draw(i, x, y, w, h, c, layer)` draws picture `i` (1 = top left, row by row). |
| `chef.notify(text, seconds, r, g, b)` | A message at the top of the screen (three at a time per mod). |

### Input

| Helper | What it does |
|---|---|
| `chef.typed()` | The text typed this frame (from `Keyboard.keystrokes`), and the raw list (read only: it's shared). |
| `chef.key_label(name)` | A key's name on the player's keyboard (`'f9'` → `F9`), for showing it. |

### Saving tables

| Helper | What it does |
|---|---|
| `chef.save_table(name, t)` | Saves plain data (booleans, numbers, strings, tables of them; no functions or cycles, 16 deep, 256 KB) to `chef_data_<author>_<mod>__<name>.lua` in the log folder (characters other than `a-z 0-9 -` become `_` and two hex digits, so every mod and table has its own file; files from 1.0.0 are moved over once). Written to a `.tmp` first; returns true when saved, or false and why. |
| `chef.load_table(name)` | Reads it back (run with nothing to reach), or nil and why. |

### The mod list

`chef.mods()` gives every mod the loader found: `{ name, kind = 'addon' | 'boot', on, dev, file, version, state,
why, errors, ms_avg, ms_max, requires, missing }`. `missing` lists what a HD2 Lua Runtime mod said it needs
(`spec.needs`) and the loader doesn't have. `state` is `running`, `off`, `kept off` (it crashed the game), `not started`
(a requirement, a compile error ...; `why` says which), `stopped` (too many errors), `started elsewhere` (another
loader started it first; `why` names it) or, for a boot entry, `handed off` (the loader that handed the game to this
one). `ms_avg` / `ms_max` are its time
a frame over the last status minute (nil before the first). The same list is written to `chef_loader_health.txt` next
to the log (tab-separated, after start-up, at most every 5 s after a change, and at shutdown), so a player can see why
a mod isn't running. `chef.has('health')`.

### Which mod's copy the game loads (the index)

When two patches ship the same resource (an armor unit, a texture, a material), the game loads the copy in the
highest-numbered patch and the other is never seen. `chef.index()` (`chef.has('index')`) tells which, for the patches
the loader reads at start-up (the boot archive's, `9ba626afa44a3aa3.patch_N`; a mod's own other archives aren't in it):

| Call | Returns |
|---|---|
| `X.winner(type, id)` | `{ patch, file, mods }` of the copy the game loads, or nil |
| `X.providers(type, id)` | every patch that ships it, the winner first |
| `X.patches()` | `{ { number, file, mods }, ... }`, lowest number first |
| `X.conflicts()` | resources two different mods ship in different copies: `{ { type, id, policy, winner, loser }, ... }` (at most 1,000, plus up to 4,000 more `exclusive` ones), and the count of the rest |

- **Built a little each frame:** the first call starts it and returns `nil, 'building'`; ask again on a later frame
  (a few frames for most installs, more for big texture packs). The loader spends at most 2 ms a frame on it.
- `type` is a name (`'unit'`, `'material'`, `'texture'`, `'package'`, `'bones'`, `'animation'` ...) or 16 hex digits,
  `id` 16 hex digits. `mods` are the names declared in that patch's Lua (empty for a patch with no `HD2-` header). A
  mod's textures or units in a patch of their own, without its Lua, show as that patch (`patch N`), not as the mod.
- `policy` is `exclusive`, `shared` (no header line covers it) or `unchecked` (see below).
- **Copies that are the same don't conflict:** two copies count as the same when their sizes, the first 64 KB and the
  last 4 KB of each part (the main file, `.stream`, `.gpu_resources`) match. The comparisons read at most 64 MB in all;
  past that, same-size copies are listed as `unchecked` (never reported on screen), and the log says how many.

Two header lines say what your mod expects:

```lua
-- HD2-Addon: mods/you/my_armor
-- HD2-Exclusive: unit material:1a2b3c4d5e6f7a8b
-- HD2-Fallback: texture
```

- `HD2-Exclusive`: these must be the copies the game loads. When another mod's copy wins, the log names both mods and
  the screen says `<MOD> IS OVERRIDDEN BY ANOTHER MOD`, once the index is built after start-up.
- `HD2-Fallback`: these are fine to be overridden (a default others replace); never reported.
- Neither: an override is listed in the log, one line per pair of patches, once the index is built.

### The loader's own settings (options menu, Chef Shared Loader group)

The rows sit under three headings: Menu (with the subheadings Compact look and Controls), Performance (with the
subheading Monitor look) and Permissions (the game patch files the loader may touch, one row each). A subheading is
drawn indented and in a dimmer yellow, its rows indented with it.

| Row | What it does |
|---|---|
| **Menu** | |
| Open this menu | The menu key (F9). It can't be off or a menu navigation key; such a value falls back to F9. |
| Menu look | Full screen (default; on the ship only, the compact panel in a mission) or Compact. |
| Language | Only when a language file is installed: English or one of the installed languages (on by default when exactly one is installed). See "Language files". |
| **Compact look** | |
| Menu position (Compact look) | Left (default), Center or Right. |
| Menu opacity % (Compact look) | 100 by default, down to 30 in steps of 10: the compact panel, text included, gets that much see-through (the menu's mouse cursor stays solid). The full screen look stays opaque. |
| **Controls** | |
| Mouse in this menu | On the ship (default), Always or Off. While the menu has the mouse, the camera doesn't turn with it: the loader gives the mouse's delta axis a dead zone no movement reaches and puts back the one it found when the menu closes (a dead zone already that far up, another mod's, is left alone). The menu's cursor follows the engine's cursor axis. |
| Controller in this menu | On, and holding the touchpad / View button two seconds opens it on the ship (default); On; or Off. |
| **Performance** | |
| Performance monitor | Off by default. On, a panel shows, once a second: the game's frame time, every mod's average milliseconds a frame (its hooks, timers and spread work), its share of the frame and its worst single call, the loader's own share, and the panel's own cost on a line of its own. Off, it costs nothing. |
| Budget (ms) | 1 ms by default. A mod averaging more a frame (or more than its own `chef.budget`) is named in the log (at most every 10 minutes) and marked orange in the performance monitor. |
| Hide mods under N ms | N is the Budget row's value (the row's name follows it). Off by default. On, the mods running under their budget share one monitor line (MODS UNDER N MS: their sum and the worst call among them), so the heavy ones stand out. A mod that's off keeps its line. |
| **Monitor look** | |
| Monitor position | Where the monitor sits: Adjustable, top right (default), top left, middle right, middle left, bottom right, bottom left, or Center. Adjustable: drag it by its yellow title bar on the pause screen (the game's cursor), or on the ship with this menu's cursor (while the menu has the mouse, the monitor is drawn over it); never in a mission without the pause screen. Where it's let go is kept (as shares of the screen, so another resolution keeps the spot). |
| Monitor opacity (%) | 100 by default, down to 10 in steps of 10: the whole panel, text included, gets that much see-through. |
| Monitor on pause screen only | Off (default), Missions or Always. Missions: in a mission the monitor shows only while the game shows its own cursor (its pause screen); on the ship it shows as always. Always: the same on the ship too (the ship's menus that show the game's cursor show it as well). The numbers are still added up, so they're there the moment the pause screen opens. If the game doesn't say, the monitor shows all the time (said once in the log). Up to 1.2.3 this was an on/off row for missions: a saved On is Missions. |

## Rules that keep the game alive

- **Guard engine calls.** Make engine calls through `chef.call` / `chef.call_kind`. Some engine calls end the whole
  game when given the wrong thing (a destroyed unit, a unit kind without a state machine, a value of the wrong type);
  Lua can't catch that.
  - Chef Shared Loader writes a breadcrumb before each guarded call's first use. After a crash, the next launch skips that
    call and turns your mod off, with a notice on screen and in the log.
  - Updating the mod turns it back on.
  - Testers can add `-- HD2-Keep-On-Crash: yes` in the file's first lines to stay on (only the crashing call is skipped).
- **Engine values live one frame.** `Color`, `Vector3` and the like only last the frame they're made in: make them
  in the frame that uses them.
- **Handles belong to one world.** Units, GUIs and cameras belong to the world they came from. When
  `chef.world_id()` changes, drop what you kept.
- **Keep `update` cheap, and idle when there's nothing to do.** The log's `status:` line shows each mod's average
  and worst milliseconds a frame (written when the numbers move, else every 10 minutes). A mod that raises 20 Lua
  errors is turned off for the session: its timers, watches, listeners and spawned things go with it.
- **Below native Render Scale,** the loader draws your screen drawing where the whole screen is reachable and
  converts your colors, so you don't need to do anything. If you ship textures, `chef.ui_textures` lets you hand it
  pre-converted copies. Layers stay under the game's menus there, so layers 999 and up all draw at one layer: keep
  plain layers at 998 or lower (`chef.TOP` layers aren't affected).

## The Lua you get

- **The game's Lua is plain Lua 5.1:** no LuaJIT, no `ffi`, no `goto`. The game removed `load` and `loadfile`.
- **What Chef Shared Loader puts back:** the pure-Lua parts of LuaJIT that mods often use: `bit` (identical results to
  LuaJIT's), `table.new`, `table.clear` and `table.unpack`.
- **In your own environment:** `xpcall` with arguments, and `load` from a string.

## What your mod can reach

Every `HD2-Addon` and `HD2-Boot` mod runs locked down, so players can install mods from anyone without handing them
their computer. Your mod has:

- **The engine's script API:** `stingray`, `Unit`, `World` and the rest, plus every `chef` helper. Every engine
  table is your mod's own copy (and so is every table inside one, and an engine object's metatable from
  `getmetatable`), taken when your mod starts: a function you replace there is replaced for your mod only, and an
  engine table compared by identity with another mod's copy isn't the same table.
- **Lua itself:** its own copies of `string`, `table`, `math`, `coroutine` and `bit`, so changing one changes it only
  for you. `require` gives your own `package.loaded` / `package.preload` first (a mod bundled as modules), then
  those, plus `table.new` and `table.clear`.
- **`os`:** `clock`, `time`, `date`, `difftime` and `getenv`.
- **`io.open` / `io.lines`:**
  - **Reading:** the loader's folder (`chef.log_directory`, which is also the game's settings folder, `saves\`
    included) and the game's `data\` folder.
  - **Writing:** only `.log .txt .json .csv .dat .ini .marker .fatal` files straight in `chef.log_directory`, with names made of
    letters, digits, `_ - .`. The loader's own files (`chef_loader*`) and saved tables (`chef_data_*`) are off limits;
    use `chef.save_table`.
  - **A file straight in `%LOCALAPPDATA%`** (`os.getenv('LOCALAPPDATA') .. '\\my_mod.ini'`) is opened in
    `chef.log_directory` instead, under the same name; a read of one not there yet falls back to `%LOCALAPPDATA%`. A
    mod written for another loader keeps its log and settings this way with no change.
- **`loadstring` / `load`:** text only. What you load runs in your environment, or in the table you hand `load`.
- **`getfenv` / `setfenv`:** on your own functions.
- **`debug`:** `traceback` and `getinfo`.

Off limits, with an error or a `nil, why` (and the first 10 refusals of each mod are logged as `blocked:`):

- **Programs and files:** `os.execute`, `os.exit`, `os.remove`, `os.rename` and `io.popen`.
- **Native code and compiled Lua:** `package.loadlib`, C modules and bytecode.
- **The game's globals:** `require` of anything but the libraries above, `dofile`, `loadfile` and `module`. A name your
  environment makes its own (`io`, `os`, `debug`, `require`, `loadstring`, `getfenv`, `_G`, the libraries ...) set to
  nil finds nothing behind it.
- **Climbing out:** the rest of `debug`, `setmetatable` on your environment, and `getfenv`/`setfenv` on the game's,
  the loader's or another mod's functions.
- **Engine tables that aren't for mods** (in `stingray` and the globals alike; a table left out reads as `false`):
  - `PluginManager` (native code), `Http` and `WebSocket`, and the `Localizer` (it ends the game);
  - every `*Lobby*` table, and all of Network but its reads (`peer_id`, `game_session`, `object_info`, `is_*`, `has_*`,
    `get_*`, `num_*`, without lobby or connection names);
  - all of GameSession but its reads (`in_session`, `peers`, `other_peers`, `game_session_host`, `game_object_field`,
    `game_object_exists`, `game_object_owner`, `game_object_is_type`, `objects_owned_by`, `unit_synchronizer`, `is_*`,
    `has_*`, `get_*`, `num_*`, and since 1.2.2 `game_object_field_batched`): no writes to what other players see.
    `game_object_field_batched` has crashed the game on other players' objects, so it answers only for an object that
    exists (a whole number id, else nil), and the loader learns from a crash in it: its first call on each object is
    breadcrumbed, so a game that ends there skips that call for your mod and keeps the mod off until it changes (one
    crash, not one every launch);
  - all of UnitSynchronizer but its lookups (`game_object_id_to_unit`, `unit_to_game_object_id`, `is_*`, `has_*`,
    `get_*`, `num_*`): no spawns or destroys every player sees;
  - the same through an engine object's metatable (`getmetatable` gives the trimmed table).

  `chef.call` refuses the same.
- **Files outside the rules above:** `..`, alternate data streams (`:`), short `~` names, device names and network
  paths are refused too.

**Porting tips:**
- **A mod that hooks the frame by replacing `_G.update`** (keeping the one it found) still works: that function runs
  as the mod's hook. Returning `update` from your module's table is the plainer way.
- **Sharing between mods** goes through `chef.share` / `chef.require`, not globals.
- **A mod that truly needs more** (swapping game files, say) has to ship its own `boot`, and then it isn't a loader
  mod (see below).

## Carrying the stub

If your mod has to ship its own `boot` (a file-mod installer, say), ship Chef Shared Loader's **start-up stub** as that
`boot` and put your own code in a `-- HD2-Boot:` mod (see [Porting a boot-replacing mod](#porting-a-boot-replacing-mod)).
Then whichever of the two the game runs, every Chef Shared Loader mod keeps running, whatever the load order.

- **The file:** `src/stub.lua` in the loader's repository (28 lines; the build also writes it next to the zip as
  `chef_loader_stub.lua`).
  Ship it as the Lua resource `boot` (id `0xf476df93691895fa`), as Lua source. With `tools/pack_addon.py`, list it in
  `lua` as `{"resource": "boot", "file": "chef_loader_stub.lua"}` (its note that the file has no header line is
  expected: the loader never runs the stub as a mod).
- **What it does:** what the game's own boot does (four empty callbacks, `debug` on non-release builds), then, if
  Chef Shared Loader is installed (`stingray.Application.can_get('lua', 'mods/chef_shared_loader/core_1')`), it loads
  the loader with `require`. Without the loader it does nothing more than the game's boot. If the loader is there but
  fails to load, the stub writes one line to `%APPDATA%\Arrowhead\Helldivers2\chef_loader_stub.txt` and the game
  carries on.
- **License:** anyone may copy and ship the stub unchanged, byte for byte, as their mod's `boot`, free and with no
  credit needed. A changed copy isn't the stub: it must not carry the stub's name or the `--@@LOADER@@` marker on its
  first line.
- **Unchanged means unchanged:** the loader knows the stub by its fingerprint. A changed copy that keeps the marker is
  named in the log as one (`a changed copy of my start-up stub`), and nothing promises it keeps starting the loader. The
  stub is frozen: a stub that has to change gets a new core name (`core_2`) and ships as a new file, so the copies in
  mods stay as they are.
- **Don't write your own boot that loads the loader.** It works (the loader doesn't run that boot a second time, and
  runs the callbacks it set before the loader replaced them), but code in it runs with the game's whole Lua, before any
  crash guard, and nothing in it is locked down. Ship the stub and a `-- HD2-Boot:` mod instead.
- **Two mods with the stub:** any number of mods may carry it; the game runs the copy in the highest patch, and the
  loader logs the others as not run.

## For other loaders

For authors of other mod loaders. The game runs one `boot`: the one in the highest patch. These are the ways another
loader and Chef Shared Loader can share a game without starting a mod twice. Everything here is free to copy into your
loader as it is. (A mod that only needs a `boot` of its own ships the stub instead: see
[Carrying the stub](#carrying-the-stub).)

### Finding Chef Shared Loader

- **Running:** `rawget(_G, 'ChefSharedLoader')` is set (read-only) once it runs; index it for `name`, `version` (a string such as
  `'1.2.0'`), `api` (a number), `revision` (`'chef-shared-loader-<version>'`) and `core` (the core's resource name).
- **Installed:** `stingray.Application.can_get('lua', 'mods/chef_shared_loader/core_1')` is true when its core is
  deployed. The core has no `-- HD2-` header, so a loader that scans the patches for `-- HD2-Addon:` mods never starts it
  as a mod.

### Handing off to it

A loader whose `boot` the game runs can hand the whole game to Chef Shared Loader when it's installed, and stop. Put this
at the very top of your `boot`, before it sets any global or callback:

```lua
local A = rawget(_G, 'stingray') and stingray.Application
if A and type(A.can_get) == 'function' and A.can_get('lua', 'mods/chef_shared_loader/core_1')
    and rawget(_G, 'ChefSharedLoader') == nil then
  rawset(_G, 'ChefSharedLoaderHandoff', { from = 'My Loader 1.0' })
  require('mods/chef_shared_loader/core_1')
  return
end
```

- `from` is your loader's name and version, 60 characters at most. The log says "started by My Loader 1.0, which handed
  off to me", and your `boot` (the game already ran it) isn't run again or reported as a loader it didn't run.
- If your `boot` must run the game's own boot first, do that, then hand off: `init`, `update`, `render` and `shutdown`
  set before the hand-off are kept and run after the loader's own each frame, crash-guarded.
- Handing off from inside your `init` (the game has called it already): add `phase = 'init'` to the note. The loader then
  calls its own `init` once it's loaded, and doesn't call yours again.
- The loader runs once per Lua state: a second hand-off, or a second copy of it, does nothing.

### Not starting a mod twice

- **Mods it starts:** every mod Chef Shared Loader starts is marked in the game's `package.loaded[name]` (a marker, never
  the mod's own table). A loader that starts mods with `require(name)` therefore skips them by itself; a loader that
  starts them another way can check `package.loaded[name] ~= nil` first.
- **Mods you start:** before it starts a mod, Chef Shared Loader looks for it in `package.loaded`, in Boot Mod Loader's
  `__boot_mod_loader.mods`, and in the `modules` table of a Bingus-style `CowboyBingusModLoader` / `HD2ModLoader`
  (`'loaded'`, `'loading'` or `'load failed: ...'`). A mod found there isn't started again; the log and `chef.mods()`
  say which loader has it.

### Mods made for Chef Shared Loader

- A Chef Shared Loader mod reads its helpers from `...` (`local chef = ...`). Under a loader that passes something else, it
  should stop at once instead of failing at its first `chef.` call:

```lua
local chef = ...
if type(chef) ~= 'table' then return end
```

- A mod that only works on Chef Shared Loader should say so in its header lines, right after the first:
  `-- HD2-Requires: chef-shared-loader` (or `-- HD2-Requires: chef-shared-loader >= 1.2.0` when it needs a version). A loader that finds `\n-- HD2-Requires: chef-shared-loader` in a mod's first lines
  can skip it with a log line ("needs Chef Shared Loader").
- `-- HD2-Boot:` mods are only started by Chef Shared Loader.

## Compatibility with mods that still replace `boot`

- **When Chef Shared Loader deploys after such a mod:** Chef Shared Loader also runs that mod's `boot` script, in its own
  environment and crash-guarded, with full access (as the game gives any boot script; the log says so). Identical
  copies run once.
- **When that mod deploys after Chef Shared Loader:** the game runs only that mod's `boot`, and no Chef Shared Loader mod runs,
  unless its `boot` is the start-up stub (see [Carrying the stub](#carrying-the-stub)).
- So players who keep such a mod should give Chef Shared Loader the highest priority. The fix for good is to port the
  mod to `-- HD2-Boot:`, and, if it must keep a `boot` of its own, to ship the start-up stub as that `boot`.
- Code such a boot loads with `loadstring`, `load` or `dofile` stays in its own environment too.
- **Wrapping the game's callbacks** (`local old = update; function update(dt) old(dt) ... end`) works in such a boot
  and in an `-- HD2-Boot:` mod: the one it finds is a stand-in, not Chef Shared Loader's own. Code it loads with
  `require` gets the game's globals; if that code replaces the game's `update` (or `init`, `render`, `shutdown`), Chef
  Shared Loader puts its own back once the boot has run, and runs the replaced one as that boot's (the log says so).
- Its environment's metatable is locked (from 1.0.1), so no loader mod can reach the game's globals through it. A boot
  script that calls `setmetatable(_G, ...)` (a "strict mode" guard) gets an error there; port it to `-- HD2-Boot:`.
- **Another mod loader's `boot`** (one that reads the patches for mods itself, such as Boot Mod Loader or Bingus Shared
  Loader v21) is not run: it would start every mod a second time. The log and the screen name it. When such a loader is
  deployed after Chef Shared Loader, the game runs it instead, unless it hands off (see
  [For other loaders](#for-other-loaders)).
- **Two copies of the same mod** (`-- HD2-Addon:` or `-- HD2-Boot:` with the same name): the one deployed last runs.
