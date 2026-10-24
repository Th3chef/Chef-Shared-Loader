# Changelog

## Unreleased

**Compatibility**
- The HD2 Lua Runtime's `boot` (a mod loader that starts its addons through `require`) now runs as a guest instead
  of being refused: the addons in its own patch are its to start, every other addon is marked as loaded first so it
  can't start one a second time, and it runs in the game's globals with its callbacks kept apart. Mods built on it
  (HD2 Transmog 1.0.x, Native Notification) run beside loader mods when the loader is deployed last. Other mod loaders
  (which may start addons without `require`) are still refused, as before.
- An addon whose file returns nothing gets the `update`, `render` and `shutdown` it set as globals called as its hooks
  (mods written before loaders).
- `-- HD2-Requires: full-access` (addons and `HD2-Boot` mods): a mod that needs the game's whole Lua is not started
  while the lockdown is on, and says so, instead of failing half-way. `chef.has('full_access')`.

**Fixes**
- A boot script that wraps the game's callbacks (`local old = update`), in its own file or in code it loads with
  `require`, no longer re-enters the loader's own: every mod ran again inside it, nesting until the stack ran out, each
  frame. While a boot script, an `HD2-Boot` mod or an addon loads, the callbacks it can wrap are no-ops.
- A boot script that replaced the game's callbacks through code it loaded with `require` stopped every loader mod;
  the loader now puts its own back and runs the replacement as that script's own.

**Mod list**
- `chef.mods()` also gives each mod's `state` and `why`, `errors`, `ms_avg` / `ms_max`, `requires` and `full_access`,
  and lists the addons other loaders run. The same goes to `chef_loader_health.txt` (`chef.has('health')`).

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
