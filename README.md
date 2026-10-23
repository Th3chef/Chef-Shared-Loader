# Chef Shared Loader

My Lua mod loader for the Lua 5.1 game build. It replaces the game's `boot` script and runs every Chef Shared Loader mod it finds in the installed mods, from any author.

Its earlier name was Chef Loader (the file names, the `chef` helpers and the `HD2-` headers didn't change, so every mod
written for it still runs). This kit is the loader's only home: loader changes go here, not into a mod's built-in copy.

**Open to every mod author.** Any mod can ship a Lua file starting with `-- HD2-Addon: mods/<author>/<name>`
(a module) or `-- HD2-Boot: mods/<author>/<name>` (a boot-style script, the one-line port for mods that used to
replace `boot`), plus `-- HD2-Options:` files for its Arsenal options. Chef Shared Loader runs them all side by side, each in
its own environment, crash-guarded. The guide for mod makers is **docs/MODDING.md**; `tools/pack_addon.py` packs a mod
and `examples/` has three small ones.

**Shared services (api 2).** What mods leaned on Bingus Shared Loader and its menus for, rebuilt for plain Lua 5.1:
- `after_startup`, a read-only `capabilities` table and `has(name)`;
- saved settings per mod (`chef_loader_settings.txt`), shared values and events between mods, `require` of another
  mod's exports with `-- HD2-Requires:` version checks (a mod whose requirement isn't met isn't started, and the log
  says why);
- an in-game options menu (F9 by default) with every mod's options and key bindings, saved between launches, with
  doubled keys marked, a search (/) and the loader's own Budget warning setting;
- look-alikes of `CowboyBingusModLoader` and `ModOptionsMenu`, so Lua-only mods written for them run;
- a log file of its own for any mod that asks (`chef.own_log`);
- dev mode, in test builds only: loose Lua files listed in `chef_loader_dev.txt`, reloaded with F11.

**Utilities (api 3):** safe unit access (the calls known to end the game refused centrally, `units_near` over the
shared scan), spawning, linking, particles and lights cleaned up at world changes and when a mod stops, timers and
work spread over frames with a frame budget per mod, the game's settings file, host and player count, triangles,
circles, rings, arcs, sprite sheets, on-screen messages, typed text and key labels, saved tables and the mod list.

## Files

| File | What it is |
|---|---|
| `src/loader.lua` | The boot script, with compat.lua, probe.lua, services.lua and utilities.lua copied inline (the game runs boot as one script). |
| `src/chef_loader/compat.lua` | Puts back LuaJIT's pure-Lua parts. Edit here, then run `tools/splice.py`. |
| `src/chef_loader/probe.lua` | Logs what the game's Lua really is, once a launch. Edit here, then run `tools/splice.py`. |
| `src/chef_loader/services.lua` | The shared services, the options menu, the look-alikes and dev mode. Edit here, then run `tools/splice.py`. |
| `src/chef_loader/utilities.lua` | The api 3 utilities. Edit here, then run `tools/splice.py` (spliced in as a field, `services.utilities`: the loader's main chunk is near Lua 5.1's 200 locals). |
| `tools/splice.py` | Copies the four files into loader.lua; `--check` fails if they're out of step. |
| `tools/build.py` | Builds the Arsenal zip: `python3 tools/build.py <out> --header-from <working Lua patch> [--test N]`. It refuses to build if loader.lua is out of step, and writes the boot script it packed next to the zip (`chef_loader_boot.lua`). |
| `docs/MODDING.md` | The guide for mod makers: the two ways to write a mod, names and headers, options, packing, the `chef` helpers, the rules. |
| `tools/pack_addon.py` | Packs a Chef Shared Loader mod (its Lua files and options, from a small `mod.json`) into an Arsenal zip. |
| `examples/` | `hello_addon` (an addon with an option), `hello_boot` (a boot-style script) and `utilities_test` (every api 3 utility, each result in util_test.log). |

## Test builds and release builds

`tools/build.py --test N` sets the loader's `TEST` line to N. Only a test build has dev mode (`chef_loader_dev.txt`)
and the probe's 200k-step Lua timing loop, and its log starts `Chef Shared Loader 0.2.0 Test N starting`. A release
build (no `--test`) leaves `TEST` nil: no dev mode, no timing loop. Everything else is the same code.

## What the compat layer adds (only when the game lacks it; nothing of the game's is ever replaced)

- **For everyone:**
  - `bit`: the full LuaJIT API, with results identical to LuaJIT.
  - `table.new`, `table.clear` and `table.unpack`.
  - `require('bit')`, `require('table.new')` and `require('table.clear')`.
- **In each addon's own environment:** `xpcall` that passes extra arguments on, and `load` that accepts a string (with a mode and an environment). The game's own `xpcall` and `load` stay as they are.
- **Not possible from a script:** ffi, the JIT and LuaJIT bytecode. LuaJIT-only syntax (`goto`, `\x` escapes, `LL`) isn't rewritten either.

## Cost

- **At start-up:** the patch scan and the probe, a millisecond or two (a test build adds the probe's timing loop,
  about 2 ms more).
- **Per frame while idle:** a look at the main world and the menu key; World.time every frame only while something
  could hold handles from the world (a mod running, my GUIs or a scan), else 4 times a second. The unit scan only runs
  while a mod watches unit kinds, the timers only when one is due, and the log's status line is written when a mod's
  numbers move, else every 10 minutes.
- **`bit` on Lua 5.1, per call:**

| Call | Cost |
|---|---|
| `band` with a low mask (0xFF, 0xFFFF, ...) | 0.19 us |
| shifts | 0.15 us |
| `band`, `bor`, `bxor` with any other value | about 0.6 us |
| `tohex` | 0.8 us |

## Colors below native

Below native Render Scale the loader draws in the UI world, which shows colors differently from the game's world.
`ui_color` converts every color an addon hands it with curves I measured in game (swatches drawn at native and at
Ultra Quality): stored = U^-1(N(c)) per channel, and a see-through color gets the alpha and color that fit best over
three backgrounds. A tint on a texture with a UI copy is only scaled so white stays white. Treasure Radar's
`ui_calib.py` holds the same tables for the textures' UI copies.

## Files on the player's computer (%LOCALAPPDATA%)

Everything sits at the root of `%LOCALAPPDATA%`, which every player has. The game's Lua can't make a folder (only a
command window could, and the loader won't start one under Easy Anti-Cheat), so the loader never needs one.

| File | What it holds |
|---|---|
| `chef_loader.log` | What happened (a fresh one each launch once it passes 1 MB). |
| `chef_loader_state.txt` | Calls that crashed the game and mods turned off. |
| `chef_loader_trace.txt` | This launch's breadcrumbs (rewritten with only what's open whenever it passes 200 KB). |
| `chef_loader_settings.txt` | Saved settings and the options menu's values. |
| `chef_loader_dev.txt` | Made by hand: dev mode's file list (test builds only). |
| `chef_data_<author>_<mod>_<name>.lua` | A mod's saved table (`chef.save_table`). |
| `<name>.log` | A mod's own log, when it asks for one (`chef.own_log`; Treasure Radar's is `treasure_radar.log`). |

Mods find the folder in `chef.log_directory`.

## Log

At start-up the log gets:
- `lua:` lines: yes/no flags and numbers only, with one `flavor=lua51 / luajit / luajit-like` summary.
- `added the LuaJIT parts this game lacks: ...`
- `each addon gets LuaJIT's load and xpcall`

## Only one boot runs

The game runs whichever boot is deployed last. Chef Shared Loader and the loader built into Treasure Radar 0.5.1 and
older skip each other, because both are copies of this loader. If chef_loader.log doesn't get a
`Chef Shared Loader 0.2.0 starting` line, an old Treasure Radar's copy won and is running only Treasure Radar.

## Support

If you like my mods, you can support me on [Patreon](https://www.patreon.com/c/Chefboiardee).

## License

All rights reserved, except that your own mods written for it are yours. See [LICENSE](LICENSE).
