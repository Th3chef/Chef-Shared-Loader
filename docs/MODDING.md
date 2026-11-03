# Making mods for Chef Shared Loader

Chef Shared Loader replaces the game's empty `boot` script and runs Lua mods on the current game build (Lua 5.1, with Easy
Anti-Cheat), for any mod author. Your mod ships a Lua file with a one-line header, and Chef Shared Loader:

- finds it in the installed mods and runs it;
- keeps it apart from every other mod;
- guards its engine calls, so a call that crashes the game the first time it's made is skipped once two launches in
  a row have ended in it;
- merges its Arsenal options;
- hands it helpers for units, the camera, keys and drawing.

Players install Chef Shared Loader once, as its own mod, and every Chef Shared Loader mod works.

**Checking your mod without the game:** editor type stubs for every helper and a simulator that runs your mod: see [TESTING.md](TESTING.md).

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
usual. Both are crash-guarded: a call that crashed the game is skipped and the mod stays on, until it ends at least 4 launches
in a row (see [Rules that keep the game alive](#rules-that-keep-the-game-alive)).

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

**Examples:** `examples/hello_addon` (an addon with an option), `examples/hello_boot` (a boot-style script),
`examples/lang_example` (a language file) and `examples/utilities_test` (every api 3 utility, each result in its own
log, util_test.log).

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
| `chef.call('Table.function', ...)` | A guarded engine call, e.g. `chef.call('Unit.alive', u)`: an engine table from `stingray` (or an engine table among the game's globals). It returns nil plus a reason when the function is missing (a name that isn't a string counts as missing: nil, `'missing'`), raised an error, or is skipped after a crash. |
| `chef.call_kind('Table.function', kind, ...)` | The same, with its own crash key per `kind` (so a crash on one unit kind only skips that kind). |

### World, camera and units

| Helper | What it does |
|---|---|
| `chef.world()`, `chef.world_id()` | The main world once it has settled (before that `chef.world()` is nil and `chef.world_id()` is 0); its id changes with every new world. |
| `chef.in_mission()` | True in a mission (not the ship, not loading). |
| `chef.camera()` | The view camera: `{ x, y, z, fx, fy, fz, yaw, fov }` (position, forward, yaw in radians and the vertical field of view when the engine gives it), or nil while there's none. Read only: the table is shared by every mod. When the camera is lost, the loader looks for it again over a few frames. |
| `chef.world_to_screen(x, y, z)` | Screen pixels (bottom-left origin), or nil when behind the camera. |
| `chef.watch(kinds, every)` | Lists units of the given resource ids (`{ ['a57ae2a703c02899'] = true }`, in any case) every `every` seconds (5 by default), spread over frames. Returns `w` with `w.items` (`{ unit, kind, x, y, z }`; `kind` is in lower case), `w.generation` (bumps on each new list), `w.active` (false while paused or stopped) and `w.pause()`, `w.resume()`, `w.refresh()`, and `w.stop()` to drop the watch for good. `kinds` stays your own table: change it in place and call `w.refresh()` to list other kinds. It's read raw, so a metatable on it isn't asked. Runtime-built units (`46cab355bd8d4d37`) are never listed (asking where one is ends the game). A mod that stops loses its watches. |
| `chef.mission_kinds(kinds)` | Unit ids that only exist in missions. The loader tells a mission by its level count; these ids are only used if the engine can't count levels (from 1.2.3). |

### Input

| Helper | What it does |
|---|---|
| `chef.key_down(name)`, `chef.key_pressed(name)`, `chef.key_known(name)` | Keyboard, by the engine's key names (`'f7'`, `'tab'`, `'left ctrl'`, ...). While the loader's options menu is open, `key_down` and `key_pressed` answer false. |
| `chef.mouse_down(name)`, `chef.cursor()`, `chef.wheel()` | Mouse buttons, the cursor, and the wheel this frame. While the options menu is open, `mouse_down` answers false and `wheel` 0 (the menu scrolls with it); the cursor reads as always. A key or mouse name the game has no index for yet (the first frames on some setups) is asked again, after 2 s and then less often (up to every 32 s). |

### Drawing

| Helper | What it does |
|---|---|
| `chef.screen()` | The screen's width and height. Read it in `update` or `render`, not once at load: until the loader's first frame, `after_startup` included, it's 1920x1080. |
| `chef.color(r, g, b, a)` | A color for this frame. |
| `chef.rect(x, y, w, h, c, layer)` | A filled rectangle; bottom-left origin. Layers 880-960 are the usual range (higher draws on top). |
| `chef.text(x, y, s, px, c, layer)` | Text in capitals (in the player's language when a language file has it), 7 `px` tall, its left end at x and its bottom at y; returns its width. In the game's own font (FSSinclair Medium) once the game has it loaded, else the loader's pixel font (capitals, digits, `. , : - + / % ( ) ! ?`). |
| `chef.text_width(s, px)` | Its width in the font in use (measured: the game's font is proportional). |
| `chef.text_fit(s, px, w)` | The text cut to `w` wide, ending in `...` when it was cut. |
| `chef.text_wrap(s, px, w, most)` | The text broken into lines `w` wide at spaces (at most `most`, 64 if not given, 1024 whatever you ask; of the text's first 16 KB). |
| `chef.lang()`, `chef.tr(s)` | The language picked (its name and code; nil for English), and a text as that language has it (see "Language files"). |
| `chef.sprite(x, y, rows, cell, colors, layer)` | A pixel sprite: `rows` are strings, each character a key in `colors`. `.` is an empty cell, and a character with no color draws nothing. `o` draws at `layer` (900 by default), every other character one layer above it, so `o` makes an outline under the rest. |
| `chef.bitmap(tex, x, y, w, h, c, layer)` | A texture shipped in your patch (its resource id as hex), tinted `c`. Returns false when it can't be drawn: then draw something else. |
| `chef.ui_textures(map)` | Texture → its copy for below-native drawing. |
| `chef.texture_sizes(map)` | Texture → pre-shrunk sizes `{ width, id, ... }`, smallest first. The lists are copied when you call it: changing one afterward does nothing. |
| `chef.line(x1, y1, z1, x2, y2, z2, c)` | A line in the world. |
| `chef.TOP` | Add it to a layer to draw over the game's HUD, map and menus: `chef.TOP + 0` to `chef.TOP + 999` show over all of them but the menus' top bar and button prompts (the loader's own menu is at 950-959, its monitor at 940-949, its notices at 930-939); higher ones only over the HUD and the map. While the loader's full screen menu is open, top-world texts under it aren't drawn (below native render scale, that's every text but the menu's). Without it, a mod draws under the game's HUD and menus. From 1.1.0: `chef.TOP + N` drew under the game's menus there; to keep that placement, add 1000. |

## Shared services (api 2)

Check with `chef.api >= 2` (or `chef.has and chef.has('menu')`) before using these, so your mod still runs on an older
loader. An older loader has no `chef.has`: calling it there is an error, so test that it's there first.

### Start-up and capabilities

| Helper | What it does |
|---|---|
| `chef.capabilities` | Read-only. `api` (the level, 3), and true for each of: `after_startup`, `settings`, `share`, `events`, `require`, `bind`, `menu`, `shims`, `logs`, `own_log` (api 2; `dev` too, on a test build only: a release ignores the dev file) and `units`, `spawn`, `timers`, `budget`, `session`, `settings_file`, `shapes`, `sprite_sheets`, `notify`, `typed`, `key_labels`, `save_table`, `mods`, `health`, `index` (api 3). From 1.4.0 also `joining`, `mouse_hold`, `players_event`, `option_buttons`, `option_colors`, `option_headings`, `option_folds`, `menu_state`, `mod_stopped_event`, `bind_combos`, and `ray_box`, true only when the game has the engine call `chef.ray_box` makes (`Math.ray_box_intersection`), as the loader starts, and `hang_watchdog`, true while the hang watchdog watches the mods' calls (as your mod starts; `chef.has('hang_watchdog')` asks it live). |
| `chef.has(name)` | True when the loader has that capability (`chef.has('api')` is true too). |
| `chef.after_startup(fn)` | Runs `fn` once every mod has started (so other mods' shared values, exports and menu rows exist). Called at once when start-up is already over, except in a mod's own late start (see [Starting late](#starting-late)): there it runs right after that start ends. |
| `chef.log_directory` | The folder the loader's files are in (`%APPDATA%\Arrowhead\Helldivers2`), without a trailing `\`. Keep your own files there (`.log .txt .json .csv .dat .ini .marker .fatal`). You read your own files there, never the loader's files, another mod's saved tables or a `.log` you don't hold this launch (see `io.open` under What your mod can reach); below it only `saves\<id>_user_settings.config`. |
| `chef.previous_directory` | Where older builds of the loader kept its folder (`%LOCALAPPDATA%`), or nil. You may read your own `.log .txt .json .csv .dat .ini .marker .fatal` files there (a `.log` only one you hold this launch); a read of a missing file in `chef.log_directory` already falls back to it. |
| `chef.own_log(name)` | From now on your `chef.log` lines go to `<name>.log` in that folder instead of `chef_loader.log` (no `[mods/...]` prefix there; a fresh file each launch once it passes 1 MB, if its first line names your mod). 8 names a launch at most; all your own logs together write at most 4 MB a launch. The loader's own lines about your mod (started, Lua errors, crashes, timings) stay in `chef_loader.log`. Call it first thing; returns false and keeps logging to `chef_loader.log` when the name is taken (names that differ only in case are one name, as on Windows) or the file can't be opened. Names are letters, digits, `_ -`, 48 at most, can't start with `chef_loader` and can't be a device name (`con`, `nul`, `com1` ...). Check `chef.has('own_log')`. |
| `chef.log_file` | The full path of the file your `chef.log` lines go to. After `chef.own_log` you can read it back with `io.open` / `io.lines` if you hold it: a new file, or one whose first line, written by `chef.own_log`, names your mod. A log that lost that line isn't read back and doesn't start fresh at 1 MB; opening it with `'w'` empties it and makes it yours again, unless another mod has written there this launch. `chef_loader.log` itself is never readable. |

### Saved settings

| Helper | What it does |
|---|---|
| `chef.save(key, value)` | Keeps a boolean, number or string (up to 512 characters, any bytes) between launches. `nil` removes it. Keys are letters, digits, `_ . -`; keys starting with `opt.` are the options menu's (your rows are saved under them) and are refused: `nil` and why. A mod saves 256 KB at most: past that, a save that would make its lines bigger gets `false` and why, while removing a value or changing one within its size still works, and nothing already saved is taken away. Written at most every 3 s (a slow save waits longer) and at shutdown. |
| `chef.load(key, default)` | What was saved, or `default`. |

Each mod's keys are its own: two mods can both save `size`.

### Between mods: shared values, events, exports

| Helper | What it does |
|---|---|
| `chef.share(name, value)`, `chef.shared(name)` | A value any mod can read by name. Use your mod's name in it (`'you.my_mod.data'`). It goes when the loader stops your mod, so nil means it isn't running; a mod started again shares it anew. Your own `handle.switch_off` isn't such a stop: `chef.share(name, nil)` first. |
| `chef.on(event, fn)` | Calls `fn(...)` for every `emit` of `event`. Returns a function that ends the subscription (it's removed). A listener that errors 20 times is switched off, and a mod that stops loses its listeners. Once your mod has stopped, code of it that still runs (a function another mod holds) can add no new listener, `chef.on_change`, `chef.share` or `chef.after_startup`, and `chef.save` and `chef.set` give nil and `the mod is off` (a paused mod's still work). |
| `chef.emit(event, ...)` | Calls every listener; returns how many ran. |
| `chef.require(name, want)` | The table another addon returned (its exports), when it runs and its `version` is `want` or newer; else nil and a reason. |

The loader's own events:

| Event | Arguments | When |
|---|---|---|
| `startup` | | Once, after every mod started and the `after_startup` callbacks ran (a mod that starts late gets its own: see [Starting late](#starting-late)). |
| `world` | world id, in a mission | A new world has settled. |
| `mission_start`, `mission_end` | world id | A mission starts; the mission ends (extraction, quitting, a new world). `mission_end` carries the mission's world id and comes before the `world` of the world after it. |
| `menu` | true (it opened) or false (it closed) | The loader's options menu opened or closed (from 1.4.0, `chef.has('menu_state')`): hide your HUD while it's up, say. `chef.menu_open()` says whether it's open now. |
| `mod_stopped` | the mod's name, why | A running mod stopped: too many errors, the hang watchdog, switched off in the menu, stopped to be tried again from CRASH RECOVERY, or a dev-mode reload (from 1.4.0, `chef.has('mod_stopped_event')`). Drop what you took from it with `chef.require`. Never for a mod that never ran (a failed start), and the stopped mod doesn't hear its own. |
| `players` | players, joining, players before | The session's player count or the number still joining changed (someone starts joining, is in, or leaves). Looked at once a second, and only while a mod listens (a paused mod's listener doesn't count); the first look after you start listening only notes the count. Check `chef.has('players_event')` (from 1.4.0). |
| `shutdown` | | The game closes. |

**Requirements.** `-- HD2-Requires:` lines among the file's first lines (its first 1200 bytes, and on to the end of the
line that crosses them, 1456 bytes at most; a line that starts later isn't read, and the log says so) name what the mod needs:

```lua
-- HD2-Addon: mods/you/my_mod
-- HD2-Requires: chef-shared-loader >= 1.0.0
-- HD2-Requires: mods/you/my_lib >= 1.2
```

Required mods start first. A mod whose requirement is missing, too old or in a circle isn't started, and the log says
why (for example `not started: mods/you/my_mod needs mods/you/my_lib 1.2 or newer (1.1.0 is installed)`, or `needs
mods/you/my_lib (not installed)`, or `(deployed, but off)`).
`chef-loader` works as the loader's name too.

A requirement another loader runs (see [Mods written for the HD2 Lua Runtime](#mods-written-for-the-hd2-lua-runtime))
counts as met once that loader really has it: a mod waiting for one that runs below this loader is tried again after
that loader has run, and a chain of such mods starts in order. A version is checked against the `-- @version` line in
that mod's header. Its module stays that loader's: `chef.require` gives `nil` and `<name> is not running`.

A running `HD2-Boot` mod counts as met too. It has no module, so `chef.require` gives `nil` and says so, and a version
is checked against a `-- @version` line in its header.

A mod with no `version` of its own (it returns `true` or nothing, or its table has none) goes by a `-- @version` line in
its header, in its first 4 KB. So a versioned `HD2-Requires` works on a mod on the HD2 Lua Runtime look-alike.

### The options menu and key bindings

The loader draws one menu for every mod's options, over everything, anywhere in the game. **F9** opens and
closes it (players can change that key in the menu itself). It opens on the list of mods: the loader's own entry
first, under a divider, then the mods in alphabetical order by title (your `chef.title`); **Up/Down** picks a mod and **Right** opens its options, in the
order your mod registered them. Every screen under the list starts with a **< Back** row (Left or Right on it
returns to the list, where the cursor was; **Backspace** does the same from anywhere but a search being typed, where
it erases). In a mod's options, **Up/Down** (Page
Up/Down) picks a row, **Left/Right** changes a toggle, a choice, a slider or a color, **Right** starts a key row's
capture or presses a button and **Left** there goes back to the list (the controller's confirm or a click toggles,
starts a capture or presses as well), and **Delete** puts the default back. The menu's key (or Escape) closes the whole menu. In a key capture, any
key binds it, **Delete** sets none and **Escape** cancels. For a `chef.bind` row (and a ModBindingsMenu one), the modifiers held when the key is pressed bind the combo
(**Ctrl+Shift+F6**), and a modifier pressed and let go with no other key binds that modifier on its own; on a
`chef.bind` row, a controller button binds that button (while the menu's controller row isn't Off), except circle/B (cancels), square/X (sets none, as Delete
does) and the touchpad / View (it opens the menu) (from 1.4.0). The menu's own key and a mod's own `'key'` rows still
take one plain key. **Enter** starts a search across every mod, from anywhere in the menu, and the game opens its chat
on the same press: the chat is the search box, and it keeps the letters from the game. Type part of a mod's or a row's
name, the list follows each letter, **Backspace** takes one off (held, it follows the chat box; Delete takes one too).
**Escape** or a click closes the chat unsent and keeps what was found, the cursor on the first row found (nothing
typed: the whole list); a click does that with the menu's mouse off too, and presses no row. The arrows work from
there, and the next Escape closes the menu. **Enter** with letters in the box sends them to the other players, and
nothing in the loader can stop that (it keeps what was found all the same); with nothing typed it just closes the box.
The menu's key does nothing while typing: Enter, Escape or a click end the typing first. Where no chat opens (the title
screen, say) the search works the same, and the letters reach the game too. The hint lines offer only keys the game ignores (the arrows, Delete and the menu's
key), plus the search's keys and **Escape** to cancel a key capture; the game opens its pause screen on Escape (with
no chat open) and at times Backspace. While the menu is open its keys and mouse buttons
are its own: your mod's `Keyboard` / `Mouse` reads of them (`pressed`, `released`, `any_pressed`, `button`,
`keystrokes`, through `chef.call` too), `chef.typed()`, `chef.key_down` / `chef.key_pressed` / `chef.mouse_down` (and `chef.wheel`, 0) and
`chef.bind` keys answer nothing pressed, so a search never fires your hotkey (the
mouse's movement and cursor still read as always). The game itself still sees the keys in the menu, and the chat holds
them back only while it's open. Values are saved between launches. Every mod the loader found is listed (from 1.4.0), with its options under
the loader's own first row, its on/off switch, labeled with your mod's name as its entry shows it (your `chef.title`,
even one set as your mod starts, else the last part of its name with spaces) and your `version` after it, dimmer, as
you wrote it (none until your mod has started; it's left out when the two don't fit the row): off stops the mod at
once through the usual stop (your `on_stop`, then your timers, watches, events and spawns go), or pauses it if it has
no `on_stop`, and it stays off; on, it starts when the menu closes, or a paused mod carries on then
([Starting late](#starting-late)). A search for your mod's name finds it.
Its `chef.mods()` / health state is then `off`, why `switched off in the options menu`. The entry's title bar
shows, at the right of your mod's name, its read-only status: that state and why, your start's cost and your last
error (from a timer, an event, `on_change`, `after_startup`, a look-alike callback or your hooks), live while the menu
is open: red, dim gray once five minutes pass with no new one (a search shows it at the right of your mod's title
line). The switch is your entry's first row, a rule under it, then your options.
Mods deployed in one patch file (a mod and the helpers it ships) are one package: one entry with one switch, the main
mod's (the one with options or a title of its own, else the one whose name isn't a generic one such as `core` or
`main`, else the first by name); its other parts are listed under INCLUDED with their state, their options under
their names, and the switch and Reset cover them all. Any of the file's mods saved off keeps the whole package off,
also when an update adds a mod to the file. Give the main mod the options or the `chef.title`, so it's the
one named.
Your entry's last row is the loader's **Reset every option to its default** (two presses): every row you registered
(`chef.option`, `chef.bind`, the look-alikes') goes back to its default through the usual change, so your `on_change`
handlers run as for a player's change. When your `version` changes between launches, the player is told once
(`updated <name>: <old> -> <new>` in the log and on screen), so give every release a new `version`.

| Helper | What it does |
|---|---|
| `chef.title(text)` | Your mod's heading in the menu. Otherwise an HD2 Lua Runtime mod's own `name`, else the last part of its name with spaces (a generic one, such as `core`, `main` or `src`, gives way to the folder above it, and so on up the path: `mods/my_mod/core` and `mods/my_mod/src/main` are both "my mod"). |
| `chef.option(id, spec)` | Adds a row and returns its current value. Ids are letters, digits, `_ . -`. `spec`: `{ type = 'toggle' \| 'choice' \| 'slider' \| 'key' \| 'button' \| 'color', label, default, ... }`. A choice has `choices` (2 to 32 strings; the value is the index; a saved choice your mod no longer has falls back to the row's default), a slider `min` < `max` (finite numbers) and optionally `step` (0 or more; values snap within the range; a value shows as a whole number when it is one, else with its step's decimals: with a 2.5 step, 7.5). A spec that doesn't fit is refused with the reason. The spec is copied when you register the row: its fields are read once (inherited ones too; `choices` and `palette` item by item), so one table can be reused for the next row, and editing `spec.label` or anything else in it afterward doesn't change the row. For text that changes, give the label or choice as a function: that stays live. A label or choice that's a table or userdata shows `?`. A row at its default isn't stored, so a new default in an update reaches players who never changed it. A label, title or choice given as a function runs as your mod, under the hang watchdog; a function that raises shows `?`. While the hang watchdog is on, a label, title or choice given as a function isn't called once your mod has stopped: the menu shows `?` and a search won't find it. |
| `chef.get(id)`, `chef.set(id, value)` | Read or change a row. |
| `chef.on_change(id, fn)` | `fn(value)` whenever the row changes (from the menu or `set`). Up to 64 per row; it stops when your mod stops. For a button, `fn(true)` each time it's pressed. |
| `chef.button(id, label, fn, text)` | A button row (from 1.4.0, `chef.has('option_buttons')`): **Right** (or the controller's confirm) or a click runs `fn()` as your mod (an error in it is logged, not raised); once your mod is stopped or switched off, its buttons do nothing. `text` is what the row shows on its right (`'RUN'` by default). It saves nothing. The same as `chef.option(id, { type = 'button', label = ..., run = fn, text = ... })`. |
| Color rows | `chef.option(id, { type = 'color', label, default = 'FF8800', palette = { ... } })` (from 1.4.0, `chef.has('option_colors')`): the value is six hex digits, `'RRGGBB'` (a `#` in front is taken), shown with a swatch; **Left/Right** step through `palette` (2 to 32 colors; without one: white, the Helldivers yellow, orange, red, pink, purple, indigo, blue, sky, teal, green, brown, gray, black). A default not in the palette is kept until the player picks another. `chef.rgb(value)` gives its 0-255 red, green and blue. |
| Headings and hints | Any row's spec can carry `heading = 'Look'` (a heading line above it; add `sub = true` for a small one, its rows indented under it until the next heading) and `hint = 'What this does'` (shown on a line of its own above the key hints while the row is selected: two lines at most in the compact panel, one in the full screen look, cut past that). 200 characters at most each (from 1.4.0, `chef.has('option_headings')`). A Mod Options Menu option's `description` is its hint. |
| Folds | Your headings fold (from 1.4.0, `chef.has('option_folds')`; nothing to do on your side): a heading (not a `sub` one) is a line the cursor stops on, `+` and the count of its rows while it's closed, `-` while it's open, its subheadings and their rows folding with it. Right opens it (or steps into it when it's open), Left closes it (back to the list from a closed one), the controller's confirm or a click opens and closes it; Left on a key or button row inside closes it, the cursor on it. An entry with more than 20 option rows opens with every heading closed, a shorter one fully open. Your switch, the rows before your first heading and the reset button always show. What the player opens or closes is kept per heading for the session and saved for the next launch. The search always shows every row. Put `fold = false` on a heading's row (the one with `heading`) to keep that heading always open, drawn as a plain heading. |
| `chef.bind(id, default_key, label)` | A key row (key names in any case: `'F6'` is `'f6'`). Returns nil and why for an id that isn't letters, digits, `_ . -`. Returns `b` with `b.key()` (`'off'` for none), `b.pressed()` and `b.down()` for this frame. A key two rows use is marked `!` in the menu and noted in the log; with that row selected, the hint line names the other options on the key. From 1.4.0 (`chef.has('bind_combos')`) the value can be a combo, `'ctrl+shift+f6'`: the modifiers first, always in the order ctrl, shift, alt, either side's key counting (a default is taken in any case and spacing: `'Shift + Ctrl+F6'` is `'ctrl+shift+f6'`). `b.pressed()` is true in the frame the key goes down while its modifiers are held, `b.down()` while all of them are; a modifier the combo doesn't name doesn't stop it (Shift is the game's sprint), and a plain key reads as it always did, modifiers held or not, so Ctrl+F6 fires both `'ctrl+f6'` and `'f6'`. So a combo and a plain binding of its key are marked `!` as clashing, both ways, and each one's hint names the other; two combos on the same key with different modifiers (`'ctrl+f6'`, `'shift+f6'`) don't clash with each other, and a controller button clashes only with the same button. Or a controller button, `'pad:cross'` (the name the pad gives it; the other pad family's name for the same button works too: `'pad:a'` is cross on a DualSense): read from the first pad found, only while your mod asks about it (a binding not asked about for 30 frames isn't read), and false while the menu is open. The menu shows them as `CTRL+SHIFT+F6` and `PAD CROSS`; `chef.key_label` gives `Ctrl+Shift+` and the key's own name, or `Pad cross`. Read a combo or a pad button with `b.pressed()` / `b.down()`: `chef.key_pressed(b.key())` knows plain keys only. |

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

### Starting late

Your mod may start after the launch's start-up: when the player switches it on in the options menu (it was saved off,
or they just switched it off), or presses **Try again now** in CRASH RECOVERY. It starts when the menu closes, once a
world that's loading has settled, a mod it requires first. It's the same start as at launch: a fresh copy of your file
from the top, a new environment, a new `chef`, the options you registered back with their values. Each row you register
again is your new copy's, its label, button and other functions too; a row you don't register again stays listed with
its functions gone (a function label says `?`, a button runs nothing). If it was running (tried again, or off and on in
one menu session) it was stopped first, the usual way, and other mods got `mod_stopped`; with no stop callback it isn't
started again at all, see below. The hang watchdog gives a late
start a call's 3 s, not the 10 s of a start at launch, and so its `init` and `after_startup` callbacks: a mission may
be under way.

What a launch gives a mod once, a late start gives you too, to your mod alone, in this order. The first three come right
after your start ends, and the last two after your first update and your first timers, as at launch:

1. your `chef.after_startup` callbacks, so they find your locals set and your file finished, as at launch;
2. `startup`;
3. a boot-style mod's global `init()`;
4. `world` for the world the game is in;
5. `mission_start` if a mission is under way.

If the world changes in that one frame, you hear the new world when it settles, the usual way, and not the old one.

`players` isn't replayed (at launch too the first look only notes the count: you get the next change). The `menu` event
isn't either: the menu is closed by then (a dev-mode reload doesn't wait for that: with the menu open, your new copy
hears `menu` with `true` right after `startup`). A mod that's started late isn't told apart from one started at launch, so
keep your start the same either way. Two things are worth a thought:

- **A mod with no stop callback is paused, not stopped.** The loader undoes what it knows of (timers, watches, events,
  spawns, its HD2 Lua Runtime objects), not what only your mod knows, such as a texture set on one of the game's materials
  or a scale you changed. A new copy would read what the old one left as the game's own, and keep it. So a mod with no
  `on_stop` and no `handle.on('stop')` that's switched off stays loaded and just isn't called: no hooks, timers, spread
  jobs, watch updates, event listeners, `on_change` callbacks, look-alike hooks or guards, and its buttons run nothing and
  a function label says `?`. Only its shutdown still comes as the game closes (an addon's `shutdown` hook, the
  `shutdown` event, a look-alike's `on_shutdown` and its guards' stop), so it can save what it has. Everything else stays where it was: your module, environment and locals, what you shared, your
  rows, and what you spawned or changed in the game, which is still in the world while you're off (a new world clears your
  spawns the usual way). Only `chef.hold_mouse` and an HD2 Lua Runtime mod's dead zones let go for the pause, so the camera
  never stays frozen, and its GUIs hide, so they don't stay on screen frozen. While you're off, `chef.hold_mouse(true)` and
  `Mouse.set_dead_zone` are refused, and `Gui.set_visible` only notes what to show on resume, for a function you shared
  that another mod still calls. `chef.mods()` and the health file say `off`, other mods get `mod_stopped`, and
  `chef.require` says you're not running.

  Switched back on, your mod is resumed as the menu closes: the status says `STARTS WHEN THIS MENU CLOSES`, and the same
  copy is called again, with its state as it left it. It isn't a start, so your file doesn't run again and none of the five
  steps above come, except what you'd otherwise have missed: `mission_end` if the mission you were in ended, `world` if
  the world moved meanwhile and `mission_start` if one you haven't heard is under way (in that order, as a running mod
  hears them at a world change), `menu` with `false` if you heard the menu open, an `on_change` with the row's value if
  the player changed it, and `done(false)` for a spread job a new world ended. A timer that came due meanwhile runs once;
  other events are gone. A mouse hold and your dead zones come back, and your GUIs show as you last set them. Other mods
  aren't told: there's no event for it. The next launch goes by the saved switch, as always. CRASH RECOVERY shows **Try again next launch** for a
  mod with no stop callback that ran in this launch, running or paused, as a try again has to start it fresh. To restart in
  the same launch instead, add `on_stop` and put back what you changed. A mod that hasn't run in this launch (saved off, or
  its start held back) has left nothing behind and starts late as usual, and a dev-mode reload starts a new copy all the
  same: that one's your own test.
- **Other mods don't hear about it.** A mod that took your exports with `chef.require` at its own start keeps the old
  ones after `mod_stopped`: ask again, or `chef.require` when you need them. A late start doesn't restart mods that
  require yours. What it shared with `chef.share` goes as it stops, so a reader gets nil until the new copy shares again.

A mod stopped in this launch by its errors, a hang or its own `switch_off` stays stopped until the next launch, whatever
the switch says, and the menu says it starts then. A mod the crash guard holds stays held: the switch says so and points
to CRASH RECOVERY, whose **Try again now** brings it back (an update of the mod does too). A mod left to another loader
is that loader's: the switch says so and starts nothing. A mod left not started by a requirement or a start that failed
can try again: off, then on, and it starts when the menu closes, through every check a start goes through. Nothing does
that by itself: a requirement that comes up later doesn't start the mods that need it. The one exception is a package's
mods left waiting on each other: **Try again now** on one of them brings the others left down by it, the main mod and its
parts. A part of a package doesn't start alone: while the package's main mod is stopped, the part waits. If the game quits while a start is waiting, nothing
starts; the saved switch starts your mod at the next launch.

### Mods written for Bingus Shared Loader, Boot Mod Loader and Mod Options Menu

The loader gives Lua-only mods written for those loaders the same calls they had there (the parts that needed `ffi` or
the JIT can't come back). Each mod gets its own read-only copy of each, tied to that mod: what it registers stops when
it stops, and no mod can replace another's. When nothing else defines them, they're also in the game's globals.

- `CowboyBingusModLoader` (also as `HD2ModLoader`): `version` 17, `api` 1, `revision`, `capabilities`,
  `after_startup(fn)`, `on_update(id, fn)` (once a frame with `dt`; the same id replaces its function; a function that
  errors is dropped and logged), `on_shutdown(id, fn)` or `on_shutdown(fn)`, `log_directory`, `open_log(name)` (a `.log`
  file in the loader's folder, started fresh at each launch), `game` (`build_identifier`) and `modules` (each mod's
  state in those loaders' words: `loaded`, `loading`, `load failed: ...`; a mod left to another loader reads `loaded`
  only once that loader ran it, and `load failed` if it refused it or never came to it). Every callback is timed into the mod's line
  in the performance monitor and crash-guarded like the mod's own hooks.
- `ModOptionsMenu` (version 3): `register_option(id, spec)`, `get`, `set`, `on_change`, `ready`. Its rows appear in this
  menu under the mod's heading (`spec.mod_id`, else `spec.mod`, else the mod's name; 32 options a heading). An option
  with no value saved here yet starts from the value the mod had before: `mom_<mod>_settings.txt` in the game's folder,
  else the old menu's `ModOptionsMenu.values`. Any id saves, spaces and all.
- `ModBindingsMenu`: `register_binding`, `is_down` (press, hold or release), `poll`, `set_binding`, `binding`. Each
  binding is a key row in this menu under the mod's heading. While this menu is open, `is_down` is false. A default
  or `set_binding` spec with `modifiers` (`{ button = 'f6', modifiers = { 'ctrl' } }`) is kept as that combo, and
  `binding` gives its modifiers back (from 1.4.0; before, such a default was passed over).
- `BingusRuntime`: `shared(env)`, `guard(spec)` and `install()`, with the same status fields; its guards are ticked by
  the loader.
- `package.loaded['mods/x/y']` and `require('mods/x/y')` give another running mod's module (or `true` while it starts
  or when it returned nothing, and for a running `HD2-Boot` mod, which has no module).
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
runs those mods on a look-alike of it, so they work without it (its own boot isn't run; the log says it isn't needed).
The one exception: when a loader that bundles the HD2 Lua Runtime runs here (Rat's Shared Loader, with its core
`mods/hd2rt/core` deployed), the mods marked for it with a `-- @loader rat` line are left to it, and it runs them on the
real runtime (see The mod list). That holds in either deploy order: above this loader it starts them and then hands
off (state `started elsewhere`, `why` names it), below it it runs as one of this loader's boot scripts (state `left to
its loader`). Rat's Shared Loader recommends itself on top, and in the other order its loading screen shows READY WITH
WARNINGS. A mod that only says `@requires` or `@after` the core
isn't marked: Rat's Shared Loader leaves it to other loaders, so it runs on the look-alike, in both orders.

Any addon can choose this while Rat's Shared Loader is deployed, by adding the `-- @loader rat` line to its header. It
then runs under that loader, outside this loader's lockdown, its F9 switch and its crash guard, and F9 lists it with one
read-only row, "Run by Rat's Shared Loader" (the host's name when another loader hosts it), with no switch and no reset.
Mods it runs from one patch file share one row, the main mod's: not one with a generic name such as `core`.
The mark is a `-- @loader rat` line among the comment lines the file starts with, in its first 4096 bytes. A second
`@loader` line with another value makes it no mark at all. When that loader runs below this one, a marked mod it never
touched (its core never came up, or it doesn't read the mod as marked: see "The sweep after the boot scripts" in the
README) starts on the look-alike after the boot scripts have run. On the look-alike:

- **`HD2Runtime` and `require('hd2rt')`:** `version` (`'0.1.0'`), `api` (1), `mod(spec)`, `status()` (with
  `log_dir`, the loader's folder) and `frame()`.
- **`HD2Runtime.mod(spec)`:** `spec.id` (letters, digits, `_ . -`), `api` (1 or nil), `name`, `lobby_key` and `bones`
  (16-hex unit resources). It returns a handle: `id`, `engine`, `raw` (your own `stingray`, as locked down as the rest), `on(event, fn)` (`update`,
  `render`, `shutdown`, and `stop`: see below), `log(...)`, `state()`, `switch_off(why)`.
- **Saying what you need:** `spec.needs` lists the engine calls (`'Material.set_texture'`) and the grants (`'lobby'`;
  see Trusted mods) your mod can't do without, 64 at most. `'files'` and `'patches'` (that runtime's own files and game
  patch files) are taken as names but never given: no mod here gets them. The loader checks them when you call
  `mod()`, with what each call asks the engine first (`Unit.alive` for a unit, `Application.worlds` for a world or a
  GUI, `Application.can_get` for a resource or a font): whatever it lacks is in `handle.missing()` (a new list, empty when everything is there), in the log, in a
  notice for the player and in `chef.mods()` / `chef_loader_health.txt` (`missing`). The mod still starts, so it can
  carry on without those parts and say so itself.
- **Asking for access:** `handle.request(what, why)` with `'lobby'` and a short reason, before the work that needs
  it (`'files'` and `'patches'` are always refused). It answers `'granted'` (your mod's entry on the loader's list
  gives it, and for `'lobby'` your `spec.lobby_key` is the key the entry names) or
  `nil, 'not given to this mod'` (the loader doesn't give it to your mod: the log and a notice say so once, so the
  player knows what to report). From 1.4.0 it never answers `'asked'`: no grant waits for the player's yes. Asking
  first means a mod never does a long job only to have its result refused.
- **The callbacks** run with the mod's own hooks, each in its own `pcall`. A file may return `true` (or nothing). In
  an `HD2-Boot` mod they run the same way: a global `update`, `render` or `shutdown` of its own goes first, as a
  module's hook does in an addon, and a callback runs when there's no global of that name.
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
- **No live palette calls:** that runtime's private-material calls (`Material.private_aliases`,
  `Material.set_private_texture`, `Material.reinitialize_shader`, `Mesh.refresh_instance_hash`,
  `Unit.paint_private_cape`, `Unit.restore_private_cape`) aren't in the look-alike; `handle.missing()` names any your
  mod lists in `spec.needs`. A mod built on them (HD2 Transmog and its packs) runs on its own runtime's loader.
- **What it made is undone when it stops:** its units, its GUIs, the units it hid, the materials it swapped on the
  game's units and the mouse dead zones it changed. What it set on a material (`Material.set_texture`, and the values of
  `set_scalar`, `set_vector2`, `set_vector3`, `set_vector4` and `set_uint_vector`) can't be: the engine can't tell what
  a material had before. Put those back yourself in `handle.on('stop', fn)`, which the loader calls
  once when it stops your mod (20 errors, it hung, it was switched off in the menu, a running mod stopped to be tried
  again from CRASH RECOVERY, a failed start, a dev reload), before it undoes anything, while your engine
  calls still work. (`stop` is Chef Shared Loader's own; the HD2 Lua Runtime itself never calls it.) A mod that
  switches itself off (`handle.switch_off`) gets no `stop` afterward: put things back before you call it. That call ends
  only that handle's callbacks and what it made, and the switch won't restart your mod in this launch. The loader still
  counts your mod as running: your timers, listeners, hooks and shares stay, and no `mod_stopped` is sent.
- **Shared globals:** a capitalized global one runtime mod sets (`MyLibrary`, say) reaches the other runtime
  mods, as in that runtime, where they share one `_G` (one set before `HD2Runtime.mod()` too). A name the game
  already has never does. Only the first write is handed over: each mod has its own copy of the name, so a later
  `MyLibrary = other` stays yours. A mod that starts later gets the value as it is then. To keep other mods up to
  date, share a table and change what's in it, or write `MyLibrary = nil; MyLibrary = other`, which reaches the mods
  that still have the value shared before. A trusted mod's globals stay its own, and it takes none of the others'. When a
  mod stops, what it shared isn't handed to mods that start later; mods that have it keep their copy. A stopped mod's `HD2Runtime.mod()` is refused.
- **The Steam lobby** (`Steam.user_id`, `Friends.playing_game`, `Network.join_steam_lobby`, `SteamLobby.*`) is only
  for mods the loader trusts with it (below): the lobby the game reports this player in (`Friends.playing_game` takes only the player's own id), the mod's own
  `lobby_key` (the one the loader's list gives it), values up to
  1 KB and 10 writes a second. These are the loader's own calls: the mod's own `Steam` has no `user_id` and its
  `Friends` is off, as for every mod.

### Trusted mods

A short list in the loader (`TRUSTED` in `src/loader.lua`) names mods that get more than the locked-down space,
each only what its entry gives. No entry opens a file: a trusted mod reads and writes what every mod does (nothing in
the game's `data\` folder, no `os.remove` or `os.rename`). What an entry can give:
- **The Steam lobby** through the HD2 Lua Runtime look-alike, under the one `lobby_key` the entry names.
- **Screenshots** (`capture`, from 1.4.0): `chef.capture()` saves a picture of the screen. The loader makes the
  engine call itself (`Application.save_render_target`, which no mod's own `Application` has); the mod hands in
  nothing but, for a depth picture, the word `'depth'`.
  - The folder is the loader's own (`%APPDATA%\Arrowhead\Helldivers2\`, where `chef.save_table` writes), and the name
    is `<author>_2f<mod>_capture_<nn>.dds` (the mod's name with `mods/` dropped, characters other than `a-z 0-9 -`
    written as `_` and two hex digits, as in `chef.save_table`'s names: `mods/me/my_mod` gives `me_2fmy_5fmod`, so no
    two mods share a name), `nn` going from `01` to `50` and then starting over, so the oldest picture is written over and
    the folder never holds more than 50 of a mod's. The number carries on across launches. Pictures saved under the
    older name (`<author>_<mod>_capture_<nn>.dds`, `me_my_mod_...`, which two mods could share) are renamed to the new
    one once, the first time the mod asks, and the number carries on from them. Not when that older name could be
    another mod's (it has `_2f` in it, so it reads as a new name, or another installed mod had the same one): then
    nothing is renamed, the number starts at `01` and the log says so once. A picture that can't be renamed (held
    open, say) stays under its old name, and the log names it so it can be deleted.
  - One a second at most, in real seconds, so a mod that has stopped the game's time still gets its next picture: a
    call sooner answers `nil, 'one capture a second at most'`.
  - It returns the file's name (not its path), or `nil, why`: `'not available to this mod'` for every mod whose
    entry doesn't grant it (being trusted for something else isn't enough), and the engine's reason when the call
    fails or the game build has no such call (the log says so once).
  - The engine's DDS writer is said to label the pixel format wrong in the file's DX10 header (28, RGBA, for an SDR
    screen's BGRA bytes; 0, unknown, for an HDR screen's RGB10A2 bytes). The loader puts that one field right (87 or
    24) once the file is whole and leaves every other file alone (a format already right, a layout it doesn't know).
    When the engine has the file written by the time `chef.capture()` returns, it's put right then; otherwise the
    loader looks again every quarter of a second for up to 5 seconds, so count a picture as finished 5 seconds after
    the call, not on the same frame. Before the save, the old picture at that name (50 shots ago) is removed.
  - What the engine saves and in which format (the render target `back_buffer`, a `.dds` file) isn't confirmed in
    game yet.
  - **Depth:** `chef.capture('depth')`, under the same grant, saves the scene's depth instead. `'depth'` is the only
    word it takes: the loader picks the render target from its own table, and any other value answers `nil, why` with
    no engine call. It returns the file's name, as `chef.capture()` does.
    - The render target (`linear_depth`) and everything about the file below come from the mod's author and aren't
      confirmed in game yet.
    - It's kept apart from the screen pictures: a depth save that ends the game skips depth and leaves `chef.capture()`
      working, it has its own one a second (a picture of each can be taken on the same frame) and its own number across
      launches, and its names are `<author>_2f<mod>_depth_<nn>.dds`.
    - Only 2 are kept (`nn` is `01` or `02`, the older written over), so read the file the call just named.
    - The file is a 148-byte DDS header (DX10, DXGI format 41, `R32_FLOAT`, Texture2D, 1 mip, width and height the render
      resolution, pitch width * 4), then the pixels: 148 + width * height * 4 bytes in all. The format is right as
      written, so the loader leaves the header alone. As with a screen picture, the file may not be whole on the same
      frame: it's done when it has all those bytes.
    - The pixels are little-endian float32, row-major, top-left origin: linear view depth in meters. The sky reads 0,
      NaN or inf.
    - A mod reads it with its own `io`: `io.open(chef.log_directory .. '\\' .. file, 'rb')`, the height and width are
      the little-endian 32-bit numbers at bytes 12 and 16, and `f:seek('set', 148 + (y * width + x) * 4)` finds a pixel.

#### How a mod gets on the list

A place on the list is for a mod that can't do its job without one of the capabilities above. It's never for
convenience. What earns a place:
- **The mod needs it to work at all:** without the capability, the mod's main feature does nothing. A mod that works
  on its own and only does more with it (syncs when it can, saves a step) is a convenience, not a need.
- **The code that uses it is readable:** plain Lua, not obfuscated, so the code that uses the capability can be read
  and checked.
- **It asks only for what it uses:** the narrowest entry that works (one lobby key, screenshots only if it takes
  them).

What never earns one:
- anything that changes another player's game, character or files, or sends data to a server of its own;
- hiding what it does, or code that uses the capability that can't be read.

**An entry names the mod, not a version.** I check the version that asks, and check again when the mod updates and I
see it. A version that breaks these rules loses its entry.

**The Steam lobby stays a curated entry, never a player's switch.** A mod's name isn't proof of who made it: any
file can call itself any mod. The lobby is also shared with the other players in your game, so one bad lobby key
reaches people who never installed it. Each lobby entry is checked by hand.

**A no isn't final.** A mod that was turned down can ask again after it changes, with a short note on what changed.

**The list is reviewed at every release.** An entry whose mod is gone, no longer needs the capability, or changed
in a way that breaks the rules above is removed. Its author is told in the issue where it was granted.

To ask for a place, open an issue on GitHub with the mod, which capability it needs, why it can't work without it,
and where the code that uses it can be read.

### Dev mode (test builds of the loader only)

For working on a mod without packing and deploying it each time. Dev mode only exists in a test build of Chef Shared
Loader (its log's first line says `Test N`); the release build ignores `chef_loader_dev.txt`.

1. Make `chef_loader_dev.txt` in the loader's folder (`chef.log_directory`).
2. Put one Lua file's full path on each line (`#` starts a comment). Each file needs its header line, like a deployed
   mod. Add `reload = f11` to pick the reload key (F11 by default).
3. Launch the game: the files load like mods (a dev file wins over a deployed mod with the same name), and the screen
   says DEV MODE.
4. Edit a file and press the reload key: those mods start again, each with its `shutdown` call first and then the way
   a late start goes ([Starting late](#starting-late)). Their menu rows keep their values; their event listeners and
   change callbacks are dropped and set up again by the new copy.

Delete the file (or empty it) to turn dev mode off.

### Text in the game's font

`chef.text` is drawn in the game's own font, FSSinclair Medium (the HUD's), once the game has it and its material loaded
(FSSinclair Regular or a locale's UI font when Medium isn't there, as on a Russian client). The loader keeps each text:
you still call `chef.text` every frame, and a text that didn't change since the last frame costs no engine call; one
that did is changed in place. What you didn't draw this frame is gone in the next. Lay text out with
`chef.text_width` / `chef.text_fit` / `chef.text_wrap`, not a count of characters: letters are of different widths. The
pixel font is used until the font is loaded, or if text calls fail; the same calls work either way.

Three things differ from the pixel font:
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
- **The menu's hint lines** are drawn as pairs, each key (`ARROWS`, `ENTER`, `ESC`, `DEL`, `BKSP`, `CLICK`, `<`
  `>` (the Left and Right arrows, and the mouse's arrows on a row), `RIGHT CLICK`, `WHEEL`, the menu key) a light chip
  followed by what it does (`MOVE`, `OPEN`, `CHANGE`, `SEARCH`, `SENDS`, `DONE`, `CLOSE`, `BACK`, `DEFAULT`, `CANCEL`,
  `NONE`, `ERASE`, `PICK`, `SCROLL`, and `PRESS A KEY` / `TYPE TO SEARCH` on their own), each key and word
  translated on its own: translate the pieces, not the whole line (since 1.2.2). A pair that doesn't fit is left out
  whole (the arrows' first). The full screen look's `RIGHT ARROW OPENS` (beside a mod's preview) is one text.
- **Renamed texts:** when the loader renames one of its own texts, a language's entry for the old text still
  translates the new one until the file has its own (`MENU OPACITY % (COMPACT LOOK)` for `MENU OPACITY (%)`,
  `MENU POSITION (COMPACT LOOK)` for `MENU POSITION`).
- **Texts with a number** (`HIDE MODS UNDER 1 MS`, `MODS UNDER 1 MS`, `+3 MORE`, `FRAME 16.7 MS  60 FPS`) need a pattern, and
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
Only your own code counts there: `chef.require` hands other mods this same table, and a function another mod puts in
it isn't run (your old hook stays and the log says so), so one mod can't wrap another's hook this way. Boot-style
scripts keep their global `render`.

`on_stop()` in the table is called once when the loader stops your mod (20 errors, it hung, it was switched off in
the menu, a running mod stopped to be tried again from CRASH RECOVERY, a dev-mode reload), before it forgets your timers, watches and events: put back what only you know there, such as
textures you set on the game's materials (the engine can't tell the loader what a material had before). Without one,
its switch pauses a mod that ran instead of stopping it, and the same copy carries on when it's switched back on
([Starting late](#starting-late)); paused, it still gets its `shutdown` as the game closes. A start that
raises never returns the table, so there's no `on_stop` to call: `pcall` your risky start code, or use
`handle.on('stop')`. It's
breadcrumbed as `<mod>|on_stop`; one that ends the game is skipped from then on. (An HD2 Lua Runtime mod's
`handle.on('stop')` callbacks run too.) After a hang it runs just after the loader looked at the world, so a new world
may not have settled yet (`chef.world()` is nil then).

**The hang watchdog** (from 1.4.0; `chef.has('hang_watchdog')` is true while it watches, false when it's off this
session: another script set a Lua debug hook, or the game has none). Any call into your mod (your start, `update`,
`render`, a timer, a spread job, an event listener, a look-alike hook) that runs on for more than 3 s (10 s for your
start-up work at launch: your start, an `HD2-Boot` mod's `init`, and the `after_startup` callbacks run then; one made
later, or a start in the same launch from the options menu, gets 3 s) is stopped with the error "stopped by the hang
watchdog: it ran over 3 s (an endless loop?)", and the loader
switches the mod off for the session at the next frame, as after 20 errors: the log says `switched off <mod> for this
session: it hung`, with the file and function your code was running then (`...; it was running mods/you/mod, the
function on line 12`), a notice tells the player, and `chef.mods()` / the health file say `stopped`. A start that hangs is
a start that failed instead: the log says `could not start <mod>: stopped by the hang watchdog ...` (an `HD2-Boot` mod:
`<mod> failed to run: stopped by the hang watchdog ...`), no notice shows, and `chef.mods()` / the health file say
`not started`. An endless loop no
longer freezes the game for good. The error comes back on every instruction of your code until the call ends, so a
loop around your own `pcall` stops too, and a mod that hung gets no fresh time on its other calls before it's switched
off. Coroutines you make with `coroutine.create` / `coroutine.wrap` are watched too (the error ends the coroutine). A
function handler you give `xpcall` isn't run for this error (a handler that loops there could never be stopped). The
loader's reads of your module count as your code: its hooks and version as it starts (under the start's limit), its
`on_stop` as it stops, so an `__index` that loops is stopped the same way. An options file that runs on past 3 s is
stopped too: the log says why, your mod starts without that table, and each launch loses those 3 s until the file
changes. Time no Lua ran in isn't counted: the watchdog checks after every million instructions (milliseconds), so a
gap of over 0.5 s between two checks is an engine call, a slow C function or the game stalling, and it comes off the
clock of every call running then (yours, and the call that ran yours). The first such gap comes off whole, however
long (the PC slept), and the rest up to twice the limit in all: 6 s for a call, 20 s for start-up work at launch. That
budget is shared by every call inside one outer call: your listener's gaps come out of the budget of the mod that sent
the event, and your timer's out of its own. A loop around a slow engine call is still stopped, a limit after the
budget ran out. A listener called right after a long engine call of the sender's gets its full 3 s from its own
start, no more. Real Lua that keeps running past the limit is a hang. If that Lua is one of
the loader's helpers the error waits for your own code, and your mod is switched off even if the call then ends clean.
It can't stop a stuck engine call (no Lua runs while one does), and it can't stop a string pattern that backtracks hard
(`('a?'):rep(32) .. ('a'):rep(32)`): patterns run in C, no hook runs there, and the crash guard doesn't help. Keep
patterns short and simple, above all on text you didn't write. Long work belongs in `chef.spread` or a timer, a little
a frame, anyway.

## Utilities (api 3)

Check with `chef.api >= 3`, or `chef.has('units')`, `chef.has('spawn')` and so on (the names are listed under
`chef.capabilities` above).

### Units, safely

Some engine calls end the whole game instead of raising a Lua error. The loader refuses the known ones before they reach
the engine, in these helpers and in `chef.call` / `chef.call_kind` too. Each refusal by `chef.call` or `chef.call_kind` is
logged once per mod, and so is a helper handed a unit from a world that's gone, once for each helper, however often you
ask: `[mods/you/mod] refused chef.unit_position: a unit from a world that is gone`. `chef.unit_alive` stays quiet: asking it
is how you check a unit. The other reasons a helper has no answer (no unit, a runtime-built unit, a world that hasn't
settled) log nothing. What's refused:
- everything in `Localizer` (`Localizer.lookup` ends the game; the game doesn't use the engine's Localizer);
- `AI.find_intersecting_units` (it ended the game; other argument shapes are untried; from 1.5.0 it's gone from your
  mod's own `AI` too);
- on a runtime-built unit (one that isn't a unit file, like `#ID[46cab355bd8d4d37]`, about 1,400 a mission): its
  position, rotation or pose (`Unit.world_*`, `Unit.local_*`), its meshes (`Unit.num_meshes`, `Unit.mesh`,
  `Unit.set_mesh_visibility`), its box (`Unit.box`; `Unit.local_scale` and this one are refused by analogy, not because they were seen to end the game) and moving it (`Unit.set_local_position`, `_rotation`, `_scale`, `_pose`, and every
  `Unit.teleport_...`);
- `Unit.has_camera` without a camera name;
- those same unit calls on a unit from an engine world that's gone, and through `chef.call` and `chef.call_kind` every
  other `Unit` call too (`Unit.alive` among them: it answers `nil` and why, so `chef.unit_alive` is the one to ask), and
  `World.destroy_unit`, `World.link_unit`, `World.unlink_unit` and `World.update_unit`, and `World.dismember_unit` and `World.mend_unit` with such a unit in any argument. A `Unit` call or one of those with no
  unit at all is refused with `no unit`. Until the world has settled, the calls in the runtime-built list above answer
  `no world yet`, on any unit. A unit whose name can't be read is refused for those calls too: it may be a runtime-built one. So is a name with no id, until a name with an id has been read this launch: if none reads, a game update may have changed the names, and the screen says `GAME UPDATE? UNIT CALLS REFUSED`. Units are stamped with the engine world they were
  seen in: within one engine world (the ship is loaded into the mission's) a unit stays usable; one from a world
  before is refused, and stays refused in every later world, even if nothing asked about it in between. A unit from
  `chef.watch`, or from a `World.units` or `World.units_by_resource` list of the main world made through `chef.call`,
  counts as seen when it's listed, so one you keep is refused like this even if you never asked about it in its own
  world. A world that isn't the main one and has never been main lives on when the main world changes, its units too:
  list it again in the new world and the refused units in that list answer, while one you kept that isn't in it stays
  refused. Past 32 main worlds in one launch, lists of these worlds stop doing this. A list of a world that used to be
  main clears nothing, even while the engine still has that world.

Also refused, because quality-of-life mods have no business with them: everything in `PluginManager` (native code),
`Http` and `WebSocket` (the network), `Network.write_dump_tag`, and writing other players' game
(`GameSession.set_game_object_field`, `create_game_object`, `destroy_game_object`, `migrate_game_object`,
`migrate_game_session_host`), and from 1.4.0 the engine's console and save files (`Console`, `CommandWindow`,
`ConsoleHelp`, `SaveSystem`, `Cloud`, `CloudToken`) and the Application calls that reach past the game, and from
1.4.1 the Steam overlay and the player's Steam id (`Steam.open_url`, `Steam.user_id`, `Steam.install_event`), the
friend list and its invites (all of `Friends`), the lobby browser (`SteamClient`) and Steam voice chat (all of
`SteamVoip`, `SteamVoipClient` and `SteamVoipRoom`), and from 1.5.0 the engine's network messages (`RPC`, all of it), the LAN lobby
browser (`LanClient`), and the writes to the player's Steam account and what friends see (all of `Leaderboard`,
`LeaderboardTransactionToken` and `Presence`, and all of `Achievement` and `Stats` but `Achievement.unlocked` and
`Stats.get`) (see "Engine tables that aren't for mods" below).

The unit calls above are refused only through `chef`: your mod's `Unit` still has them, and calling them directly
skips this safety net. (`AI.find_intersecting_units` and the tables and calls in the paragraph above are gone from your mod's own
globals too: see "Engine tables that aren't for mods" below.) The same goes for `Math.ray_box_intersection`: your mod can call it straight, without the checks and the
crash guard `chef.ray_box` puts around it.

| Helper | What it does |
|---|---|
| `chef.unit_kind(u)` | The unit's resource id (16 hex digits), cached until the world changes. |
| `chef.unit_alive(u)` | True while it's alive, in this world. |
| `chef.unit_position(u, node)` | x, y, z (node 1, its root, by default); nil for a unit that can't be asked. Crash keys per kind. |
| `chef.unit_rotation(u, node)` | Forward x, y, z and the yaw (radians, 0 = +y). |
| `chef.unit_node(u, name)` | A node's index, or nil when the unit has no such node. |
| `chef.units_near(x, y, z, r, w)` | The units of watch `w` (or of all your watches) within `r` of a point, nearest first: `{ unit, kind, x, y, z, d }`. From the watches' last lists: no extra scan. |
| `chef.ray_box(from, dir, box, extents)` | A ray against **one box you name**, not a raycast against the world: the game gives Lua no raycast (no `PhysicsWorld`), so nothing here sees terrain, walls or units you didn't pass. `from` and `dir`: a Vector3, `{ x = , y = , z = }` or `{ x, y, z }` (`dir` any finite length but 0). The box: **a unit** with `extents` left out (its own box, from the engine's `Unit.box`; never asked of a runtime-built unit or one from a world that's gone; crash key per kind); or a box of your own with `extents`, its half sizes (one number for a cube, or `{ x, y, z }` / a Vector3, each above 0), where `box` is its middle (`{ x, y, z }` / `{ x = , y = , z = , yaw = }`, `yaw` in radians about the up axis, 0 = facing +y as `chef.unit_rotation` gives it, or a Vector3), or its pose as a Matrix4x4 the engine made this frame (engine values don't outlive their frame). Numbers must be finite and, but for `dir`, within a million meters. Returns the distance in meters along the ray to where it goes into the box; nil for a miss; nil and why for a bad argument (nothing reaches the engine then), or when the engine call is missing (`chef.has('ray_box')` is false), raised an error or is skipped after a crash (crash key `<your mod>\|Math.ray_box_intersection`). A ray that starts inside the box gets the distance to where it leaves the box (the game's own answer, checked in game; the simulators say 0). Cost: one engine call, plus three Vector3s it builds (and an identity Matrix4x4 for a box of your own, `Unit.alive` and `Unit.box` for a unit), and a `Vector3.to_elements` read for each engine Vector3 you pass (plain tables need none). From 1.4.0, `chef.has('ray_box')`. |

### Spawning, with clean-up

Everything made here is destroyed for you when the world changes (`chef.world_id()` changes) and when your mod stops
(20 Lua errors, a start that failed half-way, a boot-style script stopped after 20 errors, or a dev-mode reload). A new
engine world is never touched: the old world's things are simply forgotten. A particle effect that ended by itself (a
one-shot) is dropped from the list and never destroyed again, and units the game destroyed are dropped too.

| Helper | What it does |
|---|---|
| `chef.spawn(id, x, y, z)` | Spawns a unit (its resource id as hex, or a name); nil and a reason when it isn't loaded, or when the position isn't finite numbers (`nil, 'x, y, z: finite numbers'`; a missing one is 0). |
| `chef.despawn(u)` | Destroys one you spawned. |
| `chef.link(child, parent, node, child_node)` | Links child (node 1 by default) to parent's node (a name or an index). |
| `chef.unlink(child)` | Unlinks it. |
| `chef.particles(id, x, y, z)` / `chef.stop_particles(h)` | A particle effect (a position that isn't finite numbers is refused, as for `chef.spawn`), and stopping it (only while it's still playing). |
| `chef.lights(u)` / `chef.light(u, i)` | How many lights a unit has; light `i` with `set_color(r, g, b)` (0-255), `set_intensity(v)`, `set_enabled(on)`, `set_falloff(start, end)`, `set_shadows(on)`. |

Ship the unit or effect in your patch (or use one the game has loaded). `chef.spawn` asks `Application.can_get` first and answers nil and why for one that isn't loaded; `chef.particles` doesn't ask.

### Timers, spreading work, a frame budget

| Helper | What it does |
|---|---|
| `chef.after(s, fn)` | `fn()` once after `s` seconds. Returns `{ cancel(), active() }`. |
| `chef.every(s, fn)` | `fn()` every `s` seconds (a timer that errors 20 times stops, with a line in the log, and so does one the crash guard skips). |
| `chef.spread(list, n, fn, done, opts)` | `fn(item, i)` for `n` items a frame; `done(true)` at the end, `done(false)` when a new world stops it, the crash guard skips it or its items have raised 20 errors (with a line in the log); a `cancel()` stops it at once, with no `done` (`opts.keep = true` carries on across worlds: only for lists without units). Returns `{ cancel(), active(), progress() }`. |
| `chef.budget(ms)` | Your average milliseconds a frame before the log warns and the performance monitor marks you (the loader's Budget row, 1 ms, by default). |

Your time is your hooks plus your timers and spread jobs, divided by the frames the game ran: a mod that only uses
timers is measured too. It's checked against your budget every minute (a warning at most every 10 minutes). Timers and
jobs made inside a timer or job start on the next frame.

### The game and the session

| Helper | What it does |
|---|---|
| `chef.setting(path)` | A value from the game's settings file (`user_settings.config`), e.g. `'render_settings.render_resolution'` (a table), `'screen_resolution'`, `'fullscreen'`. The loader reads the file again on a world change or a new screen size, else at most every 90 s. A table comes back as your mod's own copy: changing it reaches no other mod. |
| `chef.in_session()`, `chef.is_host()`, `chef.players()`, `chef.joining()`, `chef.peer_id()` | In an online session; this game is the host (true when not in a session); how many players (you too); how many of them are still joining (from 1.4.0, `chef.has('joining')`; 0 when not in a session); my peer id. Checked at most once a second. For a change, listen to the `players` event instead of asking every frame. |

### More drawing

| Helper | What it does |
|---|---|
| `chef.triangle(x1, y1, x2, y2, x3, y3, c, layer)` | A filled triangle. The engine's own when the game draws them, rows of rects otherwise (the log says which). |
| `chef.circle(x, y, r, c, layer)`, `chef.ring(x, y, r_in, r_out, c, layer)` | Filled circle; ring. |
| `chef.arc(x, y, r_in, r_out, a0, a1, c, layer)` | A piece of a ring, angles in degrees, 0 = up, clockwise. |
| `chef.bitmap_uv(tex, u0, v0, u1, v1, x, y, w, h, c, layer)` | Part of a texture. |
| `chef.sprite_sheet(tex, cols, rows)` | A sheet; `sheet.draw(i, x, y, w, h, c, layer)` draws picture `i` (1 = top left, row by row). |
| `chef.notify(text, seconds, r, g, b)` | A message in the upper part of the screen, centered on a dark plate under the game's logo (the first plate's top 18% down the screen), with the loader's own notices (three at a time per mod). The color: three numbers 0..255 (otherwise light gray); the text up to 80 bytes, cut on a character boundary. Its `seconds` only start once the game shows the ship or a mission (60 s at most after it could first be seen, if neither comes). |

### Input

| Helper | What it does |
|---|---|
| `chef.typed()` | The text typed this frame (from `Keyboard.keystrokes`), and the raw list (a copy of your mod's own, so changing it reaches nothing else). |
| `chef.key_label(name)` | A key's name on the player's keyboard (`'f9'` → `F9`), for showing it. |
| `chef.hold_mouse(on)` | `true` holds the mouse from the game's camera (a free camera's mouse look, say); `false` lets go. It's the loader's own hold, shared with its options menu: the mouse's delta axis gets a dead zone far above any movement, and what the axis had is put back once no mod (and not the menu) holds it, including when your mod stops (switched off after errors, say) and when the game closes, so the camera never stays frozen. A dead zone another mod set itself is left alone. Returns true, or false and why when the game gave no dead zone for the mouse. Check `chef.has('mouse_hold')` (from 1.4.0). |
| `chef.mouse_held()` | True while the loader holds the mouse for a mod or its menu, or wants to and finds a dead zone another mod set itself already there. It only looks while a mod or the menu asks for the hold: with neither, this answers false even when another mod's own dead zone keeps the camera still. |
| `chef.mouse_delta()` | This frame's mouse movement, x right and y down. While the mouse isn't held it's the engine's delta axis. While it's held that axis reads nothing, so it's the cursor axis's movement instead, scaled to about the same size; a frame where the game puts its hidden cursor back in the window's middle, or the cursor jumps a third of the window, counts as no movement. Ask every frame: an answer only counts the movement since the frame before. 0, 0 while the options menu has the mouse. |

Holding the mouse: when you're done, call `chef.hold_mouse(false)`. The loader also lets go for you when your mod stops, but not when a mod merely stops asking.

### Saving tables

| Helper | What it does |
|---|---|
| `chef.save_table(name, t)` | Saves plain data (booleans, numbers, strings, tables of them; no functions or cycles, 16 deep, 256 KB) to `chef_data_<author>_<mod>__<name>.lua` in the log folder (characters other than `a-z 0-9 -` become `_` and two hex digits, so every mod and table has its own file; a table from 1.0.0 is copied to this name the first time you load it, and the old file stays). Written to a `.tmp` first; returns true when saved, or false and why. |
| `chef.load_table(name)` | Reads it back (run with nothing to reach), or nil and why. |
| `chef.capture()` | (1.4.0) Saves a picture of the screen, for a trusted mod granted screenshots only; every other mod gets `nil, 'not available to this mod'`. `chef.capture('depth')` saves the scene's depth (not confirmed in game). See Trusted mods. |

### The mod list

`chef.mods()` gives every mod the loader found: `{ name, kind = 'addon' | 'boot', on, dev, file, version, state,
why, errors, ms_avg, ms_max, timer_errors, requires, missing, start_ms, start_kb, skipped }`. `errors` counts your hooks' (20 stop you), `timer_errors` your timers' and spread jobs' (they stop only that timer or job). `version` is the mod's `version` as read when it
started, as text (the one its switch row shows; nil for a mod that never started or has none). `missing` lists what a HD2 Lua Runtime mod said it needs
(`spec.needs`) and the loader doesn't have. `state` is `running`, `off`, `kept off` (it crashed the game), `not started`
(a requirement, a compile error ...; `why` says which), `stopped` (too many errors), `started elsewhere` (another
loader started it first; `why` names it, or says plain `another loader` when no loader table says who), `left to its
loader` (when a loader that bundles the HD2 Lua Runtime runs here as a boot script, or handed off from above without
starting it: that runtime's own core, `mods/hd2rt/core`, and every mod with a `-- @loader rat` line, and any mod that
loader refused or that failed under it, when `why` says it didn't start it. That loader runs them on the real runtime,
whatever this loader's options menu says: such a mod has no switch there, only a read-only row that says who runs it
(mods in one patch file share the main mod's row, and each keeps its own entry here),
and the core has no row at all, as it's part of that loader.
With no such loader running, or when it never came up, the core is `not started` and those mods run on this loader's
look-alike) or, for a boot
entry, `handed off`
(the loader that handed the game to this one). `ms_avg` / `ms_max` are its time
a frame over the last status minute (nil before the first). `skipped` is how many of its calls the crash guard skips
(a running mod with some shows CRASH GUARD in the options menu; its `state` stays `running`). `start_ms` / `start_kb` (from 1.4.0) are its start (its
compile and its file's first run) in ms, and how much the Lua heap grew over it in KB, also on its `started` line in
the log; nil for a mod that never ran. The KB figure is approximate: the heap is shared with the game, so a garbage
collection during the start makes it smaller, even below 0. The same list is written to `chef_loader_health.txt` next
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
subheading Monitor look) and Crash recovery (a "Try again now" or "Try again next launch" button for each mod the
crash state holds back). A subheading is drawn indented and in a dimmer yellow, its rows indented with it. These headings don't fold
(the mods' headings do).

| Row | What it does |
|---|---|
| **Menu** | |
| Open this menu | The menu key (F9). It can't be off or a menu navigation key; such a value falls back to F9. |
| Menu look | Full screen (default; on the ship only, the compact panel in a mission) or Compact. |
| Language | Only when a language file is installed: English or one of the installed languages (on by default when exactly one is installed). See "Language files". |
| **Compact look** | |
| Menu position | Left (default), Center or Right. Where the performance monitor would cover the panel, the panel moves under it (or ends above it), keeping its side; fewer rows show and it scrolls sooner. |
| Menu opacity (%) | 100 by default, down to 30 in steps of 10: the compact panel's background (the panel, its frame, the selected row's glow, the thin lines and the scroll track) gets that much see-through. The text stays solid, and so do the yellow title bar, the key chips, the selected row's edge, the color swatches, the scroll thumb and the menu's mouse cursor. The full screen look stays opaque. |
| **Controls** | |
| Mouse in this menu | On the ship (default), Always or Off. While the menu has the mouse, the camera doesn't turn with it: the loader gives the mouse's delta axis a dead zone no movement reaches and puts back the one it found when the menu closes (a dead zone already that far up, another mod's, is left alone). The menu's cursor follows the engine's cursor axis. |
| Controller in this menu | On, and holding the touchpad / View button two seconds opens it on the ship (default); On; or Off. |
| **Performance** | |
| Performance monitor | Off by default. On, a panel shows, once a second: the game's frame time, every mod (by its name in this menu) with its average milliseconds a frame (its hooks, timers and spread work), its share of the frame and its worst single call, the loader's own share, and the panel's own cost on a line of its own. It shows 12 mods at most: past that the cheapest, and any that are off, share a `+N MORE` line (their sum and the worst call among them). Off, it costs nothing. |
| Budget (ms) | 1 ms by default. A mod averaging more a frame (or more than its own `chef.budget`) is named in the log (at most every 10 minutes) and marked orange in the performance monitor. |
| Hide mods under N ms | N is the Budget row's value (the row's name follows it). Off by default. On, the mods running under their budget share one monitor line (MODS UNDER N MS: their sum and the worst call among them), so the heavy ones stand out. A mod that's off keeps its line, within the 12 shown. |
| **Monitor look** | |
| Monitor position | Where the monitor sits: Adjustable, top right (default), top left, middle right, middle left, bottom right, bottom left, or Center. Adjustable: drag it by its yellow title bar on the pause screen (the game's cursor), or on the ship with this menu's cursor in its compact look (while the menu has the mouse, the monitor is drawn over it; the full screen look hides the monitor until it closes); never in a mission without the pause screen. Where it's let go is kept (as shares of the screen, so another resolution keeps the spot). |
| Monitor opacity (%) | 100 by default, down to 10 in steps of 10: the panel's background (the panel, its frame and the yellow bar on top) gets that much see-through. The text stays solid. |
| Monitor on pause screen only | Off (default), Missions or Always. Missions: in a mission the monitor shows only while the game shows its own cursor (its pause screen); on the ship it shows as always. Always: the same on the ship too (the ship's menus that show the game's cursor show it as well). The numbers are still added up, so they're there the moment the pause screen opens. If the game doesn't say, the monitor shows all the time (said once in the log). Up to 1.2.3 this was an on/off row for missions: a saved On is Missions. |

## Rules that keep the game alive

- **Guard engine calls.** Make engine calls through `chef.call` / `chef.call_kind`. Some engine calls end the whole
  game when given the wrong thing (a destroyed unit, a unit kind without a state machine, a value of the wrong type);
  Lua can't catch that.
  - Chef Shared Loader writes a breadcrumb before each guarded call's first use. A launch that ends while that call
    is running only makes it suspected (the game closed from outside, from Task Manager say, leaves the same trace as
    a crash): nothing changes for your mod. If the next launch ends in the same call too, that call is skipped for your
    mod from then on (it gets `nil, 'skipped'`), both launches count as its crashes and your mod stays on. If it ends
    at least 4 launches in a row (they count in those twos, so two calls that each crash twice), it's turned off, with
    a notice on screen and in the log; a launch it doesn't end starts the count over.
  - Your callbacks are learned the same way, by where their code sits (their first line and file): `after_startup`,
    `chef.on` listeners, `on_change`, a button's `run`, `chef.after`, `chef.every`, and `chef.spread`'s `fn` and `done`.
    A skip takes the callbacks written at that place and no others. A skipped `after_startup`, listener, `on_change`
    or `run` just doesn't run (a listener isn't counted by `chef.emit`, and no error is counted against it). A skipped
    timer stops, and a skipped spread ends with `done(false)`. The breadcrumb is on a first run for the first group; a
    timer's stays on until a run from that place has finished, a spread's until a job from there has.
  - A crash in your mod's start code (the file running before it returns) is different: once two launches in a row
    end in it, your mod isn't started from then on, until its file changes.
  - Updating the mod turns it back on, and the calls that crashed are tried again.
  - A call on one kind of unit (`chef.call_kind`) made with only the unit, that crashed, is refused for every mod on
    that kind: yours gets `nil, 'skipped'` and stays on. It is tried again after a loader or game update. (A call with
    arguments of your own, a node index say, is only skipped for your mod.) Only `chef.call_kind` and `chef.lights`
    take part: `chef.call`, your own `stingray` and the HD2 Lua Runtime look-alike's calls don't ask about it, and a
    crash in one of those isn't shared.
  - Testers can add `-- HD2-Keep-On-Crash: yes` in the file's first lines (as far as `HD2-Requires` is read) to stay on (only the crashing call is skipped).
    The skipped calls stay skipped until the mod is updated; then they're tried again.
- **Engine values live one frame.** `Color`, `Vector3` and the like only last the frame they're made in: make them
  in the frame that uses them.
- **Handles belong to one world.** Units, GUIs and cameras belong to the world they came from. When
  `chef.world_id()` changes, drop what you kept. A unit from a world that's gone stays refused in later worlds: the
  `chef` helpers answer as if it's dead, and `chef.call` on a `Unit` call, or on destroying or linking it, answers `nil`
  and why. Your mod's own `Unit` and `World` aren't checked.
- **Keep `update` cheap, and idle when there's nothing to do.** The log's `status:` line shows each mod's average
  and worst milliseconds a frame (written when the numbers move, else every 10 minutes). A mod that raises 20 Lua
  errors is turned off for the session: its timers, watches, listeners and spawned things go with it.
- **Below native (a Render Scale below native, or Borderless at a Resolution below the monitor's),** the loader draws your screen drawing where the whole screen is reachable and
  converts your colors, so you don't need to do anything. If you ship textures, `chef.ui_textures` lets you hand it
  pre-converted copies. Layers stay under the game's menus there, so layers 999 and up all draw at one layer: keep
  plain layers at 998 or lower (`chef.TOP` layers aren't affected).

## The Lua you get

- **The game's Lua is plain Lua 5.1:** no LuaJIT, no `ffi`, no `goto`. The game removed `load` and `loadfile`.
- **What Chef Shared Loader puts back:** the pure-Lua parts of LuaJIT that mods often use: `bit` (identical results to
  LuaJIT's), `table.new`, `table.clear` and `table.unpack`.
- **In your own environment:** `xpcall` with arguments (a function handler isn't run for the hang watchdog's error),
  and `load` from a string.

## What your mod can reach

Every `HD2-Addon` and `HD2-Boot` mod runs locked down, so players can install mods from anyone without handing them
their computer. Your mod has:

- **The engine's script API:** `stingray`, `Unit`, `World` and the rest, plus every `chef` helper. Every engine
  table is your mod's own copy (and so is every table inside one, and an engine object's metatable from
  `getmetatable`), taken when your mod starts: a function you replace there is replaced for your mod only, and an
  engine table compared by identity with another mod's copy isn't the same table.
- **Lua itself:** its own copies of `string`, `table`, `math`, `coroutine` and `bit`, so changing one changes it only
  for you. `s:fn()` always reaches the game's own `string`, not your copy: a function you add to `string` is called as
  `string.fn(s)` (`s:fn()` raises), and one you replace there applies to `string.fn(s)` only. `require` gives your own
  `package.loaded` / `package.preload` first (a mod bundled as modules), then those, plus `table.new` and `table.clear`.
- **`os`:** `clock`, `time`, `date`, `difftime` and `getenv`.
- **`io.open` / `io.lines`:** (`io.lines()` with no file is refused: it would read the game's console input)
  - **Reading:** your own files in the loader's folder (`chef.log_directory`, which is also the game's settings
    folder), never the loader's own files (`chef_loader*`), another mod's saved tables (`chef_data_*`) or a `.log` you
    don't hold this launch; below it only `saves\<id>_user_settings.config`. And the game's `data\` folder.
  - **A `.log` you hold** is one you made new or started with `'w'` this launch, your `open_log` file, or your
    `chef.own_log` file when it's new or its first line, written by `chef.own_log`, names your mod. You can read it
    back; the first mod to hold a name keeps it for the launch, in any case. To read back a log you write with
    `io.open`, start it with `'w'`. Appending to a log from an earlier launch you don't hold works (`'a+'` acts as
    `'a'`: no read on that handle), but it doesn't let you read it; the first to do so keeps the name from the other
    mods' `'w'` and `open_log`, which append, and its own `'w'` still empties the log and holds it, until another mod
    has written there this launch. `'r+'` is refused; `'w'` on a log another mod holds appends instead of emptying it.
  - **Writing:** only `.log .txt .json .csv .dat .ini .marker .fatal` files straight in `chef.log_directory`, with names made of
    letters, digits, `_ - .`. The loader's own files (`chef_loader*`) and saved tables (`chef_data_*`) are off limits;
    use `chef.save_table`.
  - **A file straight in `%LOCALAPPDATA%`** (`os.getenv('LOCALAPPDATA') .. '\\my_mod.ini'`) is opened in
    `chef.log_directory` instead, under the same name; a read of one not there yet falls back to `%LOCALAPPDATA%`. A
    mod written for another loader keeps its log and settings this way with no change.
- **`loadstring` / `load`:** text only. What you load runs in your environment, or in the table you hand `load`.
  A chunk name that names a mod (`@mods/...`, `=mods/...`, `@boot:...`) has to be your own: your mod's name, or
  your name followed by `/part`, ` (part)` or `:part`. Another mod's name, and the loader's own, give `nil, why`.
  Plain names (`'=piece'`, `'piece.lua'`) and no name are fine.
- **`getfenv` / `setfenv`:** on your own functions. A custom environment is yours when you set it yourself
  (`setfenv`, or the table you hand `load`); `getfenv` on a function in anyone else's reads as your own environment.
- **`debug`:** `traceback` and `getinfo` (an option string starting `>` raises `invalid option`).
- **`newproxy`:** your own, and its metatable is yours, but a `__gc` written there is dropped (logged once): a finalizer
  would run outside the hang watchdog and after your mod stopped. Clean up in `on_stop`.

Off limits, with an error or a `nil, why` (the first 10 file refusals of each mod are logged as `blocked:`, all but a
read of `..\something`; the other refusals here, `dofile`, `io.popen` and the rest, write nothing):

- **Programs and files:** `os.execute`, `os.exit`, `os.remove`, `os.rename` and `io.popen`.
- **Native code and compiled Lua:** `package.loadlib`, C modules and bytecode.
- **The game's globals:** `require` of anything but the libraries above, `dofile`, `loadfile` and `module`. A name your
  environment makes its own (`io`, `os`, `debug`, `require`, `loadstring`, `getfenv`, `_G`, the libraries ...) set to
  nil finds nothing behind it.
- **Climbing out:** the rest of `debug`, `setmetatable` on your environment, and `getfenv`/`setfenv` on the game's,
  the loader's or another mod's functions.
- **Very long patterns:** `find`, `match`, `gmatch`, `gsub` and `gfind` raise an error on a pattern over 2048 bytes,
  from `string` or as a method on a string. A `find` with `plain` true has no limit. The check runs these calls in a
  `pcall`, so an error raised in a `gsub` callback reaches your `xpcall` handler after `gsub` has returned: the error
  text keeps its own line, but a `debug.traceback` there shows a frame of the loader's and then your `gsub` call, not
  your callback.
- **Engine tables that aren't for mods** (in `stingray` and the globals alike; a table left out reads as `false` in
  the globals and `nil` in `stingray`):
  - `PluginManager` (native code), `Http` and `WebSocket`, and the `Localizer` (it ends the game);
  - from 1.4.0, `Console`, `CommandWindow` and `ConsoleHelp` (the engine's own commands), and `SaveSystem`, `Cloud`
    and `CloudToken` (save files that outlast the game);
  - from 1.4.0, the Application calls that write files, change the player's settings or open a program:
    `save_render_target`, `save_user_settings`, `save_win32_user_settings`, `set_user_setting`,
    `set_win32_user_setting`, `apply_user_settings`, `apply_win32_user_settings`, `open_url_in_browser`,
    `export_mesh_geometry`, `restart_file_log`, `performance_hud_command`, and any other whose name has `save`,
    `write`, `dump`, `export`, `capture`, `screenshot`, `url` or `browser` in it (a call a game update adds included).
    The rest of Application stays (`worlds`, `main_world`, `resolution`, `can_get`, `user_setting` and the other
    reads, `quit` ...). A trusted mod granted screenshots saves one through `chef.capture` (see Trusted mods);
  - every `*Lobby*` table, and all of Network but its reads (`peer_id`, `game_session`, `object_info`, `is_*`, `has_*`,
    `get_*`, `num_*`, without lobby or connection names);
  - all of GameSession but its reads (`in_session`, `peers`, `other_peers`, `synchronizing_peers`, `game_session_host`, `game_object_field`,
    `game_object_exists`, `game_object_owner`, `game_object_is_type`, `objects_owned_by`, `unit_synchronizer`, `is_*`,
    `has_*`, `get_*`, `num_*`, and since 1.2.2 `game_object_field_batched`): no writes to what other players see.
    `game_object_field_batched` has crashed the game on other players' objects, so it answers only for an object that
    exists (a whole number id, else nil), and the loader learns from a crash in it: its first call on each object is
    breadcrumbed, so a game that ends there two launches in a row skips that call for your mod from then on (two
    crashes, not one every launch; the mod itself stays on, as after any crash of its own, and is turned off only
    after it ends at least 4 launches in a row);
  - all of UnitSynchronizer but its lookups (`game_object_id_to_unit`, `unit_to_game_object_id`, `is_*`, `has_*`,
    `get_*`, `num_*`): no spawns or destroys every player sees;
  - from 1.4.1, all of Steam but what it says about this game and this client (`app_id`, `client_running`,
    `connected`, `is_installed`, `language`, `overlay_active`, `owns_app`, and `user_name`, the player's own name):
    no `open_url` (a page in the Steam overlay), `install_event` or `user_id` (an id that names the player outside the
    game), and a call a game update adds stays out until it's known to be a read;
  - from 1.4.1, `Friends` (the friend list, other people's Steam ids, names and status, and invites), `SteamClient`
    (the lobby browser), and `SteamVoip`, `SteamVoipClient` and `SteamVoipRoom` (Steam voice chat: creating, joining
    and leaving rooms, selecting the voice in and out, adding and removing other players in a room). A trusted lobby mod still gets its own Steam id and lobby through the HD2 Lua Runtime
    look-alike (see Trusted mods);
  - from 1.5.0, `RPC` (the engine's network messages, whatever the name), and `LanClient` (the LAN lobby browser);
  - from 1.5.0, the writes to the player's Steam account and what friends see: all of `Leaderboard`,
    `LeaderboardTransactionToken` and `Presence`, and all of `Achievement` and `Stats` but `Achievement.unlocked` and
    `Stats.get` (no unlocks, stat changes or scores, and a call a game update adds stays out until it's known to be
    a read);
  - from 1.5.0, `AI.find_intersecting_units` (it ended the game; the rest of `AI` stays);
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
- **Don't write your own boot that loads the loader.** It works (the loader doesn't run that boot a second time, runs
  the callbacks it set before the loader replaced them, and runs its own `init` at its first `update` when nothing called
  it before), but code in it runs with the game's whole Lua, before any crash guard, and nothing in it is locked down.
  Ship the stub and a `-- HD2-Boot:` mod instead.
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
  set before the hand-off are kept and run after the loader's own each frame, crash-guarded. One that is the game's own
  global again when the loader would call it (your loader put it back, or runs the loader in an environment of its own)
  is left to the game, which calls it already: the loader never runs one of yours a second time.
- Handing off from inside your `init` (the game has called it already): add `phase = 'init'` to the note. The loader then
  calls its own `init` once it's loaded, and doesn't call yours again.
- The loader's mods start at its first `init` call, not while your `boot` loads it, so a crash in a mod's start doesn't
  land in your load, and until then nothing of theirs is marked in `package.loaded`. If your loader keeps the callbacks
  and runs them itself, call that `init` once; without it the mods start at the first `update`, and the loader leaves
  out the `init` you set before the hand-off (the game's init call went to your loader, not to it). A call to its `init`
  after that does nothing.
- Your loader may load it in an environment of its own, even one where the globals it sets don't read back: it never
  reads its own callbacks back from the globals. With a note or without one, its `init` runs at its first `update` when
  nothing called it before.
- If the loader fails to start (its log says `failed to start:`), nothing of the loader's runs in that launch. Its four
  callbacks become stand-ins for the ones set before it loaded: each calls yours when the game calls it, and does
  nothing while yours is the game's own global again (your loader keeps the loader's callbacks and put its own back, or
  runs it in an environment of its own). So your callbacks keep running, none of them twice, and none calls itself.
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
  can skip it with a log line ("needs Chef Shared Loader"). Put it in every addon that uses `chef`: without it, another
  loader deployed above this one can start the addon itself with a plain `require`, where `...` is the mod's name
  instead of `chef`, and list it as failed on its own screen, even though this loader then starts it as usual. Don't
  put it next to a `-- @loader rat` line: it's one start in either order, but not always where you'd want it. With Chef
  Shared Loader on top it starts the mod, and Rat's Shared Loader finds it started. With Rat's Shared Loader on top that
  loader starts it, as it doesn't read `HD2-Requires`, and Chef Shared Loader leaves it and logs a warning that it has
  both marks (it starts the mod itself only if that loader blocked it or it failed there).
- `-- HD2-Boot:` mods are only started by Chef Shared Loader.

## Compatibility with mods that still replace `boot`

- **When Chef Shared Loader deploys after such a mod:** Chef Shared Loader also runs that mod's `boot` script, in its own
  environment and crash-guarded, with full access (as the game gives any boot script; the log says so). Identical
  copies run once. What it does through the look-alikes counts as that script's: its `on_update` and the like are
  watched by the hang watchdog (one that hangs is dropped, the script runs on; its `on_shutdown` isn't watched, as its
  own `shutdown` isn't), a crash in one is held against that script, and they end when it's stopped.
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
  [For other loaders](#for-other-loaders)). Rat's Shared Loader's `boot` is a stub that reads no patches: below Chef
  Shared Loader it runs as a boot script, and starts Rat's Shared Loader, which starts only its own marked mods.
- **Two copies of the same mod** (`-- HD2-Addon:` or `-- HD2-Boot:` with the same name): the one deployed last runs.
