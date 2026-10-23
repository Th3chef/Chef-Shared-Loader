# Making mods for Chef Shared Loader

Chef Shared Loader replaces the game's empty `boot` script and runs Lua mods on the current game build (Lua 5.1, with Easy
Anti-Cheat), for any mod author. Your mod ships a Lua file with a one-line header, and Chef Shared Loader:

- finds it in the installed mods and runs it;
- keeps it apart from every other mod;
- guards its engine calls, so a call that crashes the game is skipped from then on;
- merges its Arsenal options;
- hands it helpers for units, the camera, keys and drawing.

Players install Chef Shared Loader once, as its own mod, and every Chef Shared Loader mod works.

**Why not replace `boot` yourself?** The game runs only one `boot`: whichever mod deploys last. Two mods that both
replace it can't work together. With Chef Shared Loader, no mod but the loader touches `boot`, and deploy order doesn't matter.

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

- **The header** is the file's very first line, exactly `-- HD2-Addon: mods/<author>/<name>` (or `-- HD2-Boot:`, or
  `-- HD2-Options:` for an options file). `<author>` and `<name>` use letters, digits, `_` and `-`.
- **The author folder** should be unique to you (your handle). Two mods with the same full name run once: the one
  deployed last (the highest patch number).
- **Load order:** `mods/chef/...` (my own mods) start first, then everyone else's by name. A mod's requirements start
  before it (see Requirements below).

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
| `chef.call('Table.function', ...)` | A guarded engine call, e.g. `chef.call('Unit.alive', u)`. It returns nil plus a reason when the function is missing, raised an error, or is skipped after a crash. |
| `chef.call_kind('Table.function', kind, ...)` | The same, with its own crash key per `kind` (so a crash on one unit kind only skips that kind). |

### World, camera and units

| Helper | What it does |
|---|---|
| `chef.world()`, `chef.world_id()` | The main world once it has settled (nil before); its id changes with every new world. |
| `chef.in_mission()` | True in a mission (not the ship, not loading). |
| `chef.camera()` | The view camera: `{ x, y, z, fx, fy, fz, yaw, fov }` (position, forward, yaw in radians and the vertical field of view when the engine gives it), or nil while there's none. Read only: the table is shared by every mod. When the camera is lost, the loader looks for it again over a few frames. |
| `chef.world_to_screen(x, y, z)` | Screen pixels (bottom-left origin), or nil when behind the camera. |
| `chef.watch(kinds, every)` | Lists units of the given resource ids (`{ ['a57ae2a703c02899'] = true }`) every `every` seconds (5 by default), spread over frames. Returns `w` with `w.items` (`{ unit, kind, x, y, z }`), `w.generation` (bumps on each new list) and `w.pause()`, `w.resume()`, `w.refresh()`, and `w.stop()` to drop the watch for good. Runtime-built units (`46cab355bd8d4d37`) are never listed (asking where one is ends the game). A mod that stops loses its watches. |
| `chef.mission_kinds(kinds)` | Unit ids that only exist in missions (helps the loader tell a small mission from the ship). |

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
| `chef.text(x, y, s, px, c, layer)` | The loader's pixel font (capitals, digits, `. , : - + / % ( ) ! ?`). |
| `chef.text_width(s, px)` | That font's width for a string. |
| `chef.sprite(x, y, rows, cell, colors, layer)` | A pixel sprite: `rows` are strings, each character a key in `colors`. |
| `chef.bitmap(tex, x, y, w, h, c, layer)` | A texture shipped in your patch (its resource id as hex), tinted `c`. Returns false when it can't be drawn: then draw something else. |
| `chef.ui_textures(map)` | Texture → its copy for below-native drawing. |
| `chef.texture_sizes(map)` | Texture → pre-shrunk sizes `{ width, id, ... }`, smallest first. |
| `chef.line(x1, y1, z1, x2, y2, z2, c)` | A line in the world. |
| `chef.TOP` | Add it to a layer to draw over the game's own HUD and map. |

## Shared services (api 2)

Check with `chef.api >= 2` (or `chef.has and chef.has('menu')`) before using these, so your mod still runs on an older
loader. An older loader has no `chef.has`: calling it there is an error, so test that it's there first.

### Start-up and capabilities

| Helper | What it does |
|---|---|
| `chef.capabilities` | Read-only. `api` (the level, 3), and true for each of: `after_startup`, `settings`, `share`, `events`, `require`, `bind`, `menu`, `shims`, `dev`, `logs`, `own_log` (api 2) and `units`, `spawn`, `timers`, `budget`, `session`, `settings_file`, `shapes`, `sprite_sheets`, `notify`, `typed`, `key_labels`, `save_table`, `mods` (api 3). |
| `chef.has(name)` | True when the loader has that capability (`chef.has('api')` is true too). |
| `chef.after_startup(fn)` | Runs `fn` once every mod has started (so other mods' shared values, exports and menu rows exist). Called at once when start-up is already over. |
| `chef.log_directory` | The folder the loader's files are in (`%APPDATA%\Arrowhead\Helldivers2`), without a trailing `\`. Keep your own files there (`.log .txt .json .csv .dat`). |
| `chef.previous_directory` | Where older builds of the loader kept its folder (`%LOCALAPPDATA%`), or nil. You may read your own `.log .txt .json .csv .dat` files there; a read of a missing file in `chef.log_directory` already falls back to it. |
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
closes it (players can change that key in the menu itself). It opens on the list of mods, always in alphabetical
order by title (your `chef.title`); **Up/Down** picks a mod and **Enter** (or **Right**) opens its options, in the
order your mod registered them. Every screen under the list starts with a **< Back** row (Enter on it returns to the
list, where the cursor was; **Backspace** does the same from anywhere). In a mod's options, **Up/Down** (Page Up/Down)
picks a row, **Left/Right** changes it, **Enter** toggles or starts a key capture, and **Delete** puts the default
back. **Escape** closes the whole menu. In a key capture, any key binds it, **Delete** sets none and **Escape**
cancels. **/** starts a search across every mod: type part of a mod's or a row's name, **Backspace** takes a letter
off, **Enter** keeps the search, **Escape** clears it. Values are saved between launches. A mod with no options isn't listed.

| Helper | What it does |
|---|---|
| `chef.title(text)` | Your mod's heading in the menu (its name otherwise). |
| `chef.option(id, spec)` | Adds a row and returns its current value. Ids are letters, digits, `_ . -`. `spec`: `{ type = 'toggle' \| 'choice' \| 'slider' \| 'key', label, default, ... }`. A choice has `choices` (2 to 32 strings; the value is the index), a slider `min`, `max` and optionally `step`. A row at its default isn't stored, so a new default in an update reaches players who never changed it. |
| `chef.get(id)`, `chef.set(id, value)` | Read or change a row. |
| `chef.on_change(id, fn)` | `fn(value)` whenever the row changes (from the menu or `set`). |
| `chef.bind(id, default_key, label)` | A key row. Returns `b` with `b.key()` (`'off'` for none), `b.pressed()` and `b.down()` for this frame. A key two rows use is marked `!` in the menu and noted in the log. |

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

### Mods written for Bingus Shared Loader and Mod Options Menu

When nothing else defines them, the loader puts two look-alikes in the game's globals, so Lua-only mods written for
them run (the parts that needed `ffi` or the JIT can't come back):

- `CowboyBingusModLoader`: `after_startup(fn)`, `capabilities`, `log_directory` and `open_log(name)` (a `.log` file in
  the loader's folder).
- `ModOptionsMenu`: `register_option(id, spec)`, `get`, `set`, `on_change`, `ready`. Its rows appear in this menu,
  under each `spec.mod` heading (128 options and 64 headings at most). Any id saves, spaces and all.

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

### Drawing every frame

An addon's table can have `render()` besides `update(dt)`; the loader calls it after the game's render each frame.
Boot-style scripts keep their global `render`.

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
| `chef.budget(ms)` | Your average milliseconds a frame before the log warns (the loader's menu setting, 2 ms, by default). |

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
| `chef.save_table(name, t)` | Saves plain data (booleans, numbers, strings, tables of them; no functions or cycles, 16 deep, 256 KB) to `chef_data_<author>_<mod>_<name>.lua` in the log folder. Written to a `.tmp` first. |
| `chef.load_table(name)` | Reads it back (run with nothing to reach), or nil and why. |

### The mod list

`chef.mods()` gives every mod the loader found: `{ name, kind = 'addon' | 'boot', on, dev, file, version }`.

### The loader's own settings (options menu, Chef Shared Loader group)

| Row | What it does |
|---|---|
| Open this menu | The menu key (F9). |
| Budget warning (ms) | The default frame budget behind `chef.budget`. |
| Performance monitor | Off by default. On, a panel in the top right shows, once a second: the game's frame time, every mod's average milliseconds a frame (its hooks, timers and spread work), its share of the frame and its worst single call, the loader's own share, and the panel's own cost on a line of its own. Off, it costs nothing. |

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
  pre-converted copies.

## The Lua you get

- **The game's Lua is plain Lua 5.1:** no LuaJIT, no `ffi`, no `goto`. The game removed `load` and `loadfile`.
- **What Chef Shared Loader puts back:** the pure-Lua parts of LuaJIT that mods often use: `bit` (identical results to
  LuaJIT's), `table.new`, `table.clear` and `table.unpack`.
- **In your own environment:** `xpcall` with arguments, and `load` from a string.

## What your mod can reach

Every `HD2-Addon` and `HD2-Boot` mod runs locked down, so players can install mods from anyone without handing them
their computer. Your mod has:

- **The engine's script API:** `stingray`, `Unit`, `World` and the rest, plus every `chef` helper.
- **Lua itself:** its own copies of `string`, `table`, `math`, `coroutine` and `bit`, so changing one changes it only
  for you. `require` gives those, plus `table.new` and `table.clear`.
- **`os`:** `clock`, `time`, `date`, `difftime` and `getenv`.
- **`io.open` / `io.lines`:**
  - **Reading:** the loader's folder (`chef.log_directory`, which is also the game's settings folder, `saves\`
    included) and the game's `data\` folder.
  - **Writing:** only `.log .txt .json .csv .dat` files straight in `chef.log_directory`, with names made of letters,
    digits, `_ - .`. The loader's own files (`chef_loader*`) and saved tables (`chef_data_*`) are off limits; use
    `chef.save_table`.
- **`loadstring` / `load`:** text only. What you load runs in your environment, or in the table you hand `load`.
- **`getfenv` / `setfenv`:** on your own functions.
- **`debug`:** `traceback` and `getinfo`.

Off limits, with an error or a `nil, why` (and the first 10 refusals of each mod are logged as `blocked:`):

- **Programs and files:** `os.execute`, `os.exit`, `os.remove`, `os.rename` and `io.popen`.
- **Native code and compiled Lua:** `package.loadlib`, C modules and bytecode.
- **The game's globals:** `require` of anything but the libraries above, `dofile`, `loadfile` and `module`.
- **Climbing out:** the rest of `debug`, `setmetatable` on your environment, and `getfenv`/`setfenv` on the game's,
  the loader's or another mod's functions.
- **Files outside the rules above:** `..`, alternate data streams (`:`), short `~` names, device names and network
  paths are refused too.

**Porting tips:**
- **A mod that hooked the frame by assigning `_G.update`** no longer reaches the engine that way. Return `update`
  from your module's table, or use `-- HD2-Boot:` with a global `update`.
- **Sharing between mods** goes through `chef.share` / `chef.require`, not globals.
- **A mod that truly needs more** (swapping game files, say) has to ship its own `boot`, and then it isn't a loader
  mod (see below).

## Compatibility with mods that still replace `boot`

- **When Chef Shared Loader deploys after such a mod:** Chef Shared Loader also runs that mod's `boot` script, in its own
  environment and crash-guarded, with full access (as the game gives any boot script; the log says so). Identical
  copies run once.
- **When that mod deploys after Chef Shared Loader:** the game runs only that mod's `boot`, and no Chef Shared Loader mod runs.
- So players who keep such a mod should deploy Chef Shared Loader last. The fix for good is to port the mod to `-- HD2-Boot:`.
- Code such a boot loads with `loadstring`, `load` or `dofile` stays in its own environment too.
- **Another mod loader's `boot`** (one that reads the patches for `-- HD2-Addon:` mods itself, such as Boot Mod Loader)
  is not run: it would start every mod a second time. The log and the screen say so. Only one loader can run.
- **Two copies of the same mod** (`-- HD2-Addon:` or `-- HD2-Boot:` with the same name): the one deployed last runs.
