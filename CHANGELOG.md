# Changelog

## 1.2.0

**The load-order stub**
- The loader's `boot` is now a small, frozen start-up stub that starts the loader itself (the Lua resource
  `mods/chef_shared_loader/core_1`) with the game's `require`. Any mod may ship the stub, unchanged, as its own `boot`:
  whichever copy the game runs, every loader mod keeps running, whatever the load order (docs/MODDING.md, "Carrying
  the stub"). The stub's own license lets anyone ship it byte for byte, free and with no credit needed.
- Without the loader installed, the stub does just what the game's own boot does. If the loader is there but can't
  load, the stub writes one line to `chef_loader_stub.txt` and the game carries on; the next launch logs that line.
- The log says which boot the game ran and how the loader started, names the loader's own boots it didn't run (other
  copies of the stub, a changed copy, a copy of the loader built into a mod), and lists the copies of the loader when
  more than one mod carries it.
- Another mod's boot that starts the loader itself isn't run a second time; the callbacks it set run as that boot's.
- A trusted mod's game patch file can't carry a copy of the loader, and its exports aren't handed to other mods. A
  trusted mod may offer the other HD2 Lua Runtime mods a read-only view of one global of its own (the calls its place
  on the list names; every answer a copy, nothing that changes the mod). Of what the other mods share, it gets only the
  globals its place on the list names, each from the one mod named.
- Each mod gets its own copy of every engine table (`stingray`, `Unit`, `World` ...): a mod that replaces an engine
  function or adds a field changes only its own copy, never the game's, the loader's or another mod's.

**Fixes**
- The options menu key (F9) could stay dead for the whole session when the game wasn't ready to report the key in the
  first frames. A key with no answer yet is asked about again every 2 seconds, and the log says so.
- When the game's HUD font wasn't loaded yet at start-up, the loader used its backup font for the whole session. It
  now switches to the HUD font as soon as it's loaded.
- A world that restarted in place (as the title screen can) kept the loader's last texts on screen. They're now
  removed once that world has settled.

**The options menu**
- A full screen look on the ship: the mods on the left, the picked mod's options on the right, a title picture at the
  top. In a mission the menu is the compact panel (the game keeps running under it). F9 > Chef Shared Loader > Menu
  look picks Full screen or Compact.
- A controller works in the menu: the D-pad moves, cross/A picks, circle/B goes back (and closes at the list of mods),
  square/X puts the default back, L1/R1 a page. On the ship, holding the touchpad / View button for two seconds opens
  it. Row: Controller in this menu.
- The mouse works in the menu (on the ship by default, since moving it still turns the camera): hover, click, right
  click to go back, the wheel, and dragging a slider. Row: Mouse in this menu.
- New rows: Menu position (left, center, right; the compact look) and Monitor position (top, middle or bottom, left
  or right).
- A key two options use: with that row selected, the hint line names the other options on the key, in yellow.
- The "OTHER LOADER NOT RUN" notice goes after 10 seconds.
- The loader's own options are grouped under headings: Menu, Performance and Permissions.
- The options menu, the performance monitor and the loader's notices draw over the game's HUD, map, terminals and Esc
  menu (all but the menus' top bar and button prompts). For mods, layers `chef.TOP` to `chef.TOP + 999` do the same
  (docs/MODDING.md). A mod that drew at `chef.TOP + N` under the game's menus in 1.1.0 adds 1000 to keep that.

**Language files**
- A language file translates the loader's menu, monitor and notices and every mod's text at once: a Lua resource
  starting `-- HD2-Lang: mods/<author>/<name>` that returns only data (a name, exact texts, optional patterns). Pick it
  in F9 > Chef Shared Loader > Language (shown once one is installed; kept by name, so adding another never changes it).
  Files with the same name are one language, so a mod can ship its own texts for it (docs/MODDING.md, "Language
  files").
- While a language is on, the texts it has no entry for are listed in `chef_loader_lang_missing.txt`, ready to copy
  into the file: the texts drawn, and every mod's option texts in the menu, scrolled to or not.
- For mods: `chef.lang()` (the language's name and code) and `chef.tr(s)`.
- A language file is read as data before it runs (no loops, calls or operators), with limits on its size and on how
  long its patterns may take; a file that ends the game is skipped from the next launch until it changes.

**Other mod loaders**
- Boot Mod Loader's and Bingus Shared Loader v21's boot scripts in a lower patch are named in the log and on screen
  (they're still not run).
- A mod another loader already started (in `package.loaded`, Boot Mod Loader's list, or the `modules` table of another
  loader's `CowboyBingusModLoader`) isn't started again; the log and `chef.mods()` name that loader. A mod made for
  Chef Shared Loader (`-- HD2-Requires: chef-shared-loader`) is always started. Every mod the loader starts is marked in
  `package.loaded`, so a loader that starts mods with `require` skips it.
- Another loader can hand the game to Chef Shared Loader with a few lines at the top of its `boot`; the callbacks it set
  first keep running after the loader's (docs/MODDING.md, "For other loaders"). A public, read-only
  `ChefSharedLoader` value says it's running, and it runs once per Lua state.
- The start-up log names an `ffi` written in Lua (another loader's stand-in) as one, not as the real `ffi`.

**Mods written for Bingus Shared Loader, Boot Mod Loader and Mod Options Menu**
- `CowboyBingusModLoader` (also `HD2ModLoader`) has those loaders' calls: `on_update(id, fn)`, `on_shutdown` in both
  forms, `modules`, `game`, `version` 17. Every callback is timed in the performance monitor and crash-guarded.
- `ModOptionsMenu` version 3: headings by `mod_id`, and an option with no value saved yet starts from the value it had
  before (`mom_<mod>_settings.txt`, else `ModOptionsMenu.values`).
- New: `ModBindingsMenu` (each binding a key row in the options menu) and `BingusRuntime`.
- `package.loaded` and `require` give another running mod's module.
- `ffi` and `jit` read as `false` for every mod, even when another loader left a stand-in for them.
- A mod that keeps its log or settings straight in `%LOCALAPPDATA%` (as mods for those loaders often do) has those
  files kept in the loader's folder instead, under the same names; settings it saved there before are still read.
  `.ini` files are allowed too.
- `open_log` starts a fresh file the first time each name is opened in a launch (it added to the old one).
- `ModOptionsMenu`: up to 32 options a heading and 112 headings; `set` and `register_option` check what they're given.

**For mod authors**
- A mod the loader stops (too many errors, a start that failed half-way, a dev reload) first gets `on_stop()` (in its
  table) or `handle.on('stop', fn)` (an HD2 Lua Runtime mod), to put back what only it knows, such as textures it set
  on the game's materials. Breadcrumbed: one that ends the game is skipped from then on.
- Mod names may have more parts (`mods/<author>/<group>/<name>`).
- A mod file that returns `false`, a number or a string runs, as one that returns nothing does.
- Patch files are found across up to 64 missing numbers in a row (was 40), as Boot Mod Loader does.
- With the game's render scale below native, a mod's plain layers stay under the game's menus.
- UTF-8 text in the game's font (`chef.text`, the menu, the monitor): each character is kept whole, measured whole and
  never cut in the middle; one the font has no glyph for shows as `?`. The pixel font shows a non-ASCII character as one
  `?` (it showed one per byte). The log says whether the game's font has CJK glyphs.
- File names Windows keeps for devices are refused in more spellings (`COM0`, `LPT0`, any case, spaces before the dot).
- Three more read-only network calls for mods: `GameSession.objects_owned_by`, `GameSession.game_object_is_type` (the
  check before reading a field) and `Network.object_info`.

**Credits**
- MCTimeRL: the report on what kept UTF-8 (Chinese) text out of the game's font, with a working translated build,
  and the idea for language files.
- Rosensterner: the full screen menu look, its title picture, and the controller and mouse support in the options menu.

## 1.1.0

**License**
- A compatibility grant: other mod authors may copy and adapt parts of the loader's code into their own mods to call
  its functions, detect it, or work with it and the mods it runs, with a credit line. The examples and the code in
  docs/MODDING.md are free to use. Reuploading the loader, or releasing it as another loader, still needs asking.

**Mods made for the HD2 Lua Runtime**
- Mods written for the HD2 Lua Runtime run on a look-alike of it:
  `HD2Runtime` and `require('hd2rt')`, `mod(spec)` handles with `on`, `log` and that runtime's engine calls, each one
  crash-guarded for the mod and undone when it stops. Its own boot script, which those mods carry, isn't needed (the
  log says so).
- A mod's own `require` serves its `package.preload` (mods bundled as modules).
- A mod file may return `true`, as those mods do.
- Lua resources in envelope 1 (plain text too) are read as well as envelope 2.

**Boot scripts, the mod list and the resource index**
- Boot scripts and `-- HD2-Boot:` mods that wrap the game's `update` (`local old = update ...`) no longer run the
  loader again from inside it every frame (it ran out of stack); code a boot script loads with `require` can't replace
  the loader's callbacks any more (they're put back, and the replaced one runs as that boot's).
- `chef.mods()` gives each mod's state (running, off, kept off, not started, stopped) and why, its errors and its time a
  frame; the same list is written to `chef_loader_health.txt`.
- `chef.index()`: which mod's copy of each resource the game loads (`winner`, `providers`, `patches`, `conflicts`),
  built a little each frame on first use. `-- HD2-Exclusive:` and `-- HD2-Fallback:` header lines say which resources
  must win (reported in the log and on screen when another mod's copy wins) and which may be overridden.

**Text**
- The options menu, the performance monitor, notices and `chef.text` are drawn in the game's own font (FSSinclair
  Medium, the HUD's; Regular or the locale's font where Medium isn't loaded), in capitals as before. Text is kept
  between frames and only changed when it changes (the monitor costs about a tenth of what it did), laid out by
  measured width, and long notices wrap. The pixel font stays as the fallback, and "Game font" in the loader's
  options switches to it by hand.
- New for mods: `chef.text_fit` and `chef.text_wrap`; `chef.text_width` measures in the font in use.

**Mods written for Bingus Shared Loader**
- Mods that find the engine with `rawget(_G, 'stingray')` and hook in by replacing the game's `update` (keeping the
  one they found) now start and run; before, they looked started but did nothing.
- A mod that asks for `ffi` or `jit` gets a log line saying the game has neither since 7.2.0, so what in it needs them
  won't work with any loader, even when the mod carries on without them.

**Trusted mods**
- A short list in the loader gives a named mod more than the locked-down space, only what it needs: the Steam lobby
  (its own key, the lobby the game reports), its own files in %LOCALAPPDATA%, or game patch files once the player turns
  on that mod's "Game patch files" row in the options menu (F9).
- A game patch file is checked before it takes a patch's name: its table of contents must read as the layout the
  loader knows, it must not replace the game's boot script, and any Lua in it must be comments only. A file still open
  for writing is never renamed or removed.

**Lockdown**
- Engine tables that aren't for mods are out of their reach in `stingray` and the globals too, not only through
  `chef.call`: native code (PluginManager), Http and WebSocket, the Localizer, every lobby table, and GameSession's
  writes to what other players see. Network and GameSession keep only their reads (`peer_id`, `game_session`,
  `in_session`, `peers`, `game_object_field`, `is_*`, `has_*`, `get_*`, `num_*` and the like), without the lobby and connection
  ones, so a call a game update adds stays out until it's known to be a read; an engine object's metatable gives the
  same trimmed table.

## 1.0.1

**Crash safety**
- A mod whose own update, render, shutdown or options file ends the game is now blamed and kept off at the next launch
  (before, only its start was traced, so it could crash the game on every launch).
- One mod's error can no longer stop the other mods: start-up, render, the boot scripts' update, timers, events and
  shutdown each run every mod on its own, and an error that can't be turned into text is still logged.
- Shutdown always writes the clean marker and saves settings, even when a mod's shutdown fails, and runs only once.
- A mod's bad number (NaN or infinity) in a drawing call is refused instead of being able to switch off the loader's own
  menu; a call the loader skipped after a crash gets another try after a loader update, with a notice while it's skipped.
- Shapes (triangles, arcs) are clipped to the screen and capped, so a huge or infinite shape can't freeze the game.
- A mod's fingerprint now covers its whole source, so a same-size hotfix turns a crashed mod back on. What 1.0.0
  learned carries over: mods it kept off stay off until they're updated, and other mods' boot scripts keep their
  skipped calls.
- A crash during a mission can no longer be blamed on the loader's drawing (two such launches switched drawing off for
  good).
- A mod can set or replace its `update`, `render` or `shutdown` after it started, and the new one runs.

**Lockdown**
- File handles, other mods' boot environments, and the `CowboyBingusModLoader` and `ModOptionsMenu` look-alikes are
  sealed: each mod gets its own look-alikes, and a stopped mod's `on_change` and `after_startup` no longer run.
- Saved-table files have one name per mod and table, so two mods can't share one (old files are moved over once).
- Device names (`con.log`, `clock$` ...) are refused, and `string.dump` is gone.
- `chef.call` also finds engine tables the game keeps among its globals, and never anything the locked-down space takes
  away.

**Saved data**
- Settings, the crash state and saved tables are written to a `.tmp` file first and only then replace the old one, so a
  full or locked disk no longer wipes them; a failed settings write is tried again. Saved tables from 1.0.0 move to
  their new names the first time the mod loads them.
- Saved strings with `\n` or `\t` after a backslash (`C:\new\tab`) come back intact.
- `save_table`: reserved-word keys (`end`) and large numbers (3e9) save correctly, and it returns false when the write
  fails.

**Fixes**
- A `-- HD2-Requires:` line without a version no longer swallows the next line.
- No more stray mission end and start in the middle of a mission.
- Sliders snap within their range, and a slider with no default and a bad value no longer stops the mod.
- The menu key can't be set to none or to a navigation key, and the menu hint shows the real key.
- `chef.title` works after `chef.option`; `chef.bind` accepts upper-case key names.
- The performance monitor counts boot-style mods' timers and spread work, events, `on_change` and `after_startup` time
  to the mod, not the loader.
- More log lines when something is skipped (a missing world, a file over 4 MB, a byte-order mark, a bad name).

**Performance**
- Faster drawing, unit scans, guarded calls and `world_to_screen`; the menu costs less than half as much, and the
  performance monitor about a third, with almost no garbage.
- Less idle work: trace time stamps only while they matter, fewer clock calls for spread work, no garbage from `bit`
  calls with three or more values, and a unit watch scans at most twice a second.

## 1.0.0

The first release on its own (Treasure Radar 0.5.x carried an earlier copy built in).

- Open to every mod author: any mod with a
  `-- HD2-Addon: mods/<author>/<name>` or `-- HD2-Boot: mods/<author>/<name>` file runs, side by side and crash-guarded.
- Shared services (api 2): `after_startup`, capabilities, saved settings per mod, shared values and events between
  mods, `require` of another mod's exports with version checks, a log of its own for any mod, and look-alikes of
  `CowboyBingusModLoader` and `ModOptionsMenu`.
- An in-game options menu (F9) with every mod's options and key bindings, saved between launches: the mods in
  alphabetical order, each mod's options under a < Back row, doubled keys marked, a search (/) across every mod, and the
  loader's own settings (Budget warning, Performance monitor).
- A performance monitor: each mod's milliseconds a frame, share of the frame and worst call, once a second.
- Utilities (api 3): safe unit access (calls known to end the game refused centrally), spawning, linking, particles
  and lights cleaned up when a world ends or a mod stops, timers and work spread over frames with a budget per mod,
  the game's settings file, host and player count, shapes, sprite sheets, on-screen messages, typed text, key labels,
  saved tables and the mod list.
- Mods run locked down: no programs, no native code or bytecode, and files only in the game's own folders (reads in
  the game's settings folder and `data\`; writes of `.log .txt .json .csv .dat` in the loader's folder). Other mods'
  own boot scripts keep full access, in their own space.
- Another mod loader's boot script isn't run (it would start every mod twice); the log and the screen say so.
- Two copies of one mod: the one deployed last runs.
- Logs and files sit in %APPDATA%\Arrowhead\Helldivers2, the game's own folder (moved once from %LOCALAPPDATA%).
