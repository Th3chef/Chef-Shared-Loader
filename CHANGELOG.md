# Changelog

## 1.3.1

**Fixes**
- Mods were cut off when the game ran below the monitor's resolution in Borderless (Resolution 1920x1080 on a
  2560x1440 monitor, say): the loader took it for native and drew in the game's world, which shows only the top-left
  1920x1080 of the window. It now compares the render size with the window's and draws in the UI world, as for a
  Render Scale below native.
- A mod's update installed after it crashed the game but before the next launch was blamed for that crash, so a fixed
  build could stay off (or keep its call skipped, or not be started). The crash is now counted against the file that
  was running: the trace names each mod's fingerprint, and an update installed before relaunching counts as a change
  (for crashes from 1.3.1 on).

**Changes**
- The log names the options menu's key at every start, with how to change it without the menu, and the status lines
  repeat it until the menu has opened once that launch. A key the PC keeps for itself (a laptop's F row without Fn) left no trace
  in the log before. The README says how to pick another key in `chef_loader_settings.txt`.

## 1.3.0

**Crash safety**
- A mod that crashes the game is no longer turned off at once: the call that crashed is skipped and the mod stays on.
  Only when it ends 3 launches in a row is it turned off. A launch it doesn't end starts the count over, and an update
  of the mod tries its skipped calls again. `chef_loader_state.txt` has a new line for it, `strikes:`. A mod whose own
  start code ends the game is still not started from the next launch on, until it's updated.
- A mod turned off after a crash still comes back on when it's updated, and now the calls of its that crashed are
  tried again too (they stayed skipped for good). So are those of a mod kept on with `-- HD2-Keep-On-Crash: yes`.
- A call on one kind of unit (`chef.call_kind` or the `chef.unit_*` helpers) that ended the game, made with only the
  unit, is now refused for every mod on that kind: the other mods get `nil, 'skipped'`. A call with arguments of the
  mod's own isn't shared, and neither is a crash from before an update of the loader or of the game. A shared refusal
  is tried again after an update of the loader or of the game.

**Game patch files**
- A trusted mod's built patch over 262,144 rows was refused as "not a patch file", so a big build failed. The cap is
  now 2,097,152 rows; the other checks are the same.
- A patch file over 200,000 rows still isn't read for mods, and the log now says why ("too big to hold a mod")
  instead of counting it among the files "not laid out the way I read them".
- `chef.index()` covers patches up to 2,097,152 rows (it left out those over 200,000).

**Mods made for the HD2 Lua Runtime**
- A mod can list what it needs (`spec.needs`: engine calls, and `lobby`, `files` or `patches`). What the loader lacks
  is in `handle.missing()`, the log, a notice, `chef.mods()` (`missing`) and a new last column of
  `chef_loader_health.txt`, `missing`. The mod still starts.
- A mod can ask for access before the work that needs it: `handle.request(what, why)` answers `'granted'`, `'asked'`
  (the player has to turn on its row in F9; when the mod gives a reason, the player is told so, with the reason in the
  log) or `nil, 'not given to this mod'` (the log and a notice say so once).
- Live palette materials: that runtime's private-material calls (`Material.private_aliases`,
  `Material.set_private_texture`, `Material.reinitialize_shader`, `Mesh.refresh_instance_hash`,
  `Unit.paint_private_cape` and `Unit.restore_private_cape`), so a mod recolors its own copies, and the game's medium
  cape, during play without a restart. Each call is checked before it reaches the engine, and a painted cape is put
  back when the mod stops.
- Inboxes: a trusted mod's place on the list can name a view that takes data. Any mod, a runtime mod or not, hands it
  one table of plain data a call, copied all the way down. With the trusted mod installed, every mod that isn't trusted
  has the inbox from the start: a call made before the trusted mod is up, or before it has filled in that call, is held
  (16 at most per mod and call) and made once it has. Another trusted mod gets the inbox once the trusted mod is up. A
  trusted mod that won't start (kept off after a crash, stopped, or not started) holds nothing: the call answers
  `nil, 'not running'`.

**Trusted mods**
- A trusted mod gets the other trusted mods' read-only views whichever starts first (before, only when it started
  first).
- A trusted mod can have more than one view, each its own global.

**For language file makers**
- Two new notices start with a mod's name, so a pattern translates them: `... NEEDS MORE THAN THIS LOADER HAS (SEE
  LOG)` and `... NEEDS ACCESS THIS LOADER DOESN'T GIVE (SEE LOG)`.

**Credits**
- RatInPlat: what an HD2 Lua Runtime mod needs and asks for (`spec.needs`, `handle.missing()`, `handle.request`),
  the live palette material calls and the trusted mods' inbox views (pull request #8).

## 1.2.4

- New row "Monitor opacity (%)": the performance monitor, text included, from fully solid (100, the default) down to
  10.
- "Monitor on pause screen only" is now Off, Missions or Always. Always keeps the monitor off the screen on the ship
  too, until the pause screen is up. It replaces "Missions: monitor on pause screen only" (a saved On is Missions).
- New row "Menu opacity % (Compact look)": the compact F9 panel, text included, from 100 (the default) down to 30. The
  full screen look stays solid.
- The loader's own options are easier to scan: Menu, with the subheadings Compact look and Controls under it, and
  Performance, with Monitor look under it.
- The "Game font" row is gone: the menu, the monitor and notices always use the game's font once it's loaded. The
  loader's pixel font is still there as the fallback.
- For language file makers: new texts COMPACT LOOK, CONTROLS, MONITOR LOOK, MENU OPACITY % (COMPACT LOOK), MONITOR
  OPACITY (%), MONITOR ON PAUSE SCREEN ONLY and MISSIONS; GAME FONT and MISSIONS: MONITOR ON PAUSE SCREEN ONLY are gone.

## 1.2.3

- Small missions count as missions: the loader now tells a mission from the ship by the world's level count (the ship
  has one or two, a mission hundreds) instead of its size. Some missions (bots on Trivial, for example) are smaller than
  a well-upgraded ship, so mods that only run in missions never started in them, unless a mod that names mission loot
  (Treasure Radar) was installed too.
- The F9 menu tells the ship the same way, so a big ship no longer counts as a mission for its mouse and full-screen
  layout.
- For mod authors: `chef.mission_kinds` is only used if the engine can't count levels.

## 1.2.2

**The options menu**
- The hint line at the bottom shows each key (arrows, Enter, `/`, F9, Esc, Delete, Backspace, and the mouse's click,
  `<` `>`, right click and wheel) as a light key chip, like the option rows' keys, followed by what it does (ARROWS
  MOVE, ENTER OPEN, / SEARCH ...), in white instead of gray. The compact panel's line now ends with ESC CLOSE too;
  when a line is short of room, whole pairs are left out (the arrows' first), never a key without its word. Language
  files translate its keys and words one by one (docs/MODDING.md).
- In the compact panel, opening a mod (or going back) draws the new screen in the same frame: the hint line no longer
  jumps a frame late.
- On the pause screen, the menu's mouse cursor follows the real mouse (it moved only with the mouse's movement
  there, so it drifted off the game's cursor).
- Chef Shared Loader's own entry is always first in the list of mods; the mods follow in alphabetical order.
- Mods' hotkeys no longer fire while the menu is open: typing a search (an L, say) doesn't switch a mod's light on
  and off. Mods read no key presses, mouse clicks or typed text while it's open.
- Search: the hints say ENTER SEARCH, BKSP ERASE and / ESC EXIT; `/` again leaves a search, like Escape. Delete
  erases too.

**Performance monitor**
- "Monitor position" has two more choices: Adjustable (first in the list) and Center. Adjustable: drag the monitor by
  its yellow title bar on the pause screen, or on the ship with the F9 menu's cursor; it stays where you let it go,
  across launches.
- New row "Missions: monitor on pause screen only": in a mission the monitor shows only while the pause screen is up,
  so nothing sits over the HUD while you play; on the ship it shows as always.

**Mods made for other loaders**
- More mods run: `GameSession.game_object_field_batched` (every field of a game object at once) is now allowed, so
  mods like DRIVER HUD find your vehicle. It once crashed the game on other players' objects, so the loader asks
  only about objects that exist and learns from a crash in it: a game that ends there skips that call for that mod
  and keeps the mod off until it updates (with a notice), so it can't crash every launch.

## 1.2.1

**The options menu**
- On the ship, while the full screen menu has the mouse, the camera no longer turns with it: the mouse only moves the
  menu's cursor, and the camera gets the mouse back the moment the menu closes (or the mouse is turned off for it, or
  at shutdown). With Mouse in this menu set to Always, the same goes for the compact panel in a mission. A mod that
  already holds the mouse that way is left alone.
- Going back a step (right click, Backspace, circle/B) no longer flashes the menu for a frame.

**Performance monitor**
- "Budget warning (ms)" is now "Budget (ms)", 1 ms by default (it was 2). A mod over it (or over its own
  `chef.budget`) is still named in the log, and is now marked orange in the monitor.
- New row: Hide mods under N ms, N following the Budget row (off by default). On, the mods running under their
  budget share one line, MODS UNDER N MS (their sum and the worst call among them), so the heavy ones stand out. A
  mod that's off keeps its line.

**Mods made for other loaders**
- Lua's own base functions (`unpack`, `pairs`, `pcall` ...) are a mod's own globals, so mods that check
  `rawget(_G, 'unpack')` before they hook the game start their update. The game's `update`, `render` and `shutdown`
  aren't among them.
- Mods may call `GameSession.other_peers` and `GameSession.unit_synchronizer` (teammates' objects, a unit's game
  object). `UnitSynchronizer` keeps only its lookups (`game_object_id_to_unit`, `unit_to_game_object_id`); its spawns
  and destroys, which every player sees, are left out.
- `.marker` and `.fatal` files are allowed next to `.log .txt .json .csv .dat .ini` (a mod's own crash notes; kept in
  the loader's folder like the others).

**Fixes**
- Lockdown: a mod that set one of its own names (`io`, `os`, `debug`, `require`, `loadstring`, `getfenv`, `_G`, a
  library ...) to nil found the game's own behind it. It now finds nothing there.
- Lockdown: the game's other lower case globals were shared, so a mod could change a table of the game's for the
  game and every other mod. Each mod now gets its own (a table as its own copy), taken when the loader starts and
  listed in the log; lower case globals set later, and the game's `init`, `update`, `render` and `shutdown`, aren't
  reached.

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
