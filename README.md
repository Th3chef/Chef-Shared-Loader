# Chef Shared Loader

![Chef Shared Loader](media/gallery.png)

**Download:** `Chef-Shared-Loader-1.0.0.zip` from the [latest release](https://github.com/Th3chef/Chef-Shared-Loader/releases/latest) (not the source code). **Mod makers:** [docs/MODDING.md](docs/MODDING.md).

**Install:** add the zip in your mod manager and enable it, **put it last in your load order** so it deploys after every
other mod (in a mod manager that lists the highest priority at the top, that means first), then Purge and Deploy. A mod
deployed after it that replaces the game's `boot` script takes its place, and then no loader mod runs
(see [Other mods' boot scripts](#other-mods-boot-scripts)).

A Lua mod loader for Helldivers 2 on the Lua 5.1 game build (PUC Lua 5.1, no LuaJIT, no `ffi`, Easy Anti-Cheat on).
It replaces the game's `boot` script, finds every loader mod in the deployed patch archives, and runs each one in its
own locked-down environment with crash guarding, shared services and drawing helpers. Any mod author can target it.
The guide for mod makers is [docs/MODDING.md](docs/MODDING.md).

- **Version:** 1.0.0
- **Game:** Steam build 25988413 (2026-10-20) and later, while the game keeps loading `boot` from a patch as source
- **Runtime:** Lua 5.1 only (`goto`, `\x` escapes and `LL` literals are not used anywhere)
- **Files on the player's computer:** `%APPDATA%\Arrowhead\Helldivers2\` (see [Files](#files-on-the-players-computer))

## Contents

1. [How it starts](#how-it-starts)
2. [Discovery](#discovery)
3. [Running mods](#running-mods)
4. [Security model](#security-model)
5. [Crash guard](#crash-guard)
6. [Other mods' boot scripts](#other-mods-boot-scripts)
7. [Services and helpers](#services-and-helpers)
8. [Compat layer](#compat-layer)
9. [Files on the player's computer](#files-on-the-players-computer)
10. [Log reference](#log-reference)
11. [Cost](#cost)
12. [Source layout and build](#source-layout-and-build)
13. [Known limits](#known-limits)

## How it starts

1. **Boot takeover.** The engine runs the Lua resource named `boot` (resource id `murmur64("boot")` =
   `0xf476df93691895fa`) from the highest-numbered patch that carries one, then calls its global `init`, `update(dt)`,
   `render` and `shutdown`. The loader ships as that resource, as Lua source (resource flag 2).
2. **The game's own boot is not run.** On this build it only defines four empty callbacks, loads `debug` on
   non-release builds, and calls `jit.off()` when LuaJIT is present (decoded from build 25988413's bytecode). Skipping
   it changes nothing in a release build.
3. **One `pcall` around everything.** The whole loader runs inside one protected call, so a loader bug logs and
   prints `[Chef Shared Loader] failed to start` instead of taking the game down. The four engine callbacks are
   defined first, as empty functions, so the engine always finds them.
4. **Order at start-up:**
   1. The file folder is picked, and older files are moved once.
   2. The crash state and the last launch's breadcrumbs are read.
   3. The Lua probe runs and the compat parts are added.
   4. The patches are scanned.
   5. Dev-mode files are added (test builds only).
   6. The Bingus look-alikes and the locked-down space are set up.
   7. Addons start, then `HD2-Boot` scripts, then other mods' boot scripts.
   8. `after_startup` callbacks run.

## Discovery

The loader reads the deployed archives itself with `io`, from the game folder (the working directory):
`data/9ba626afa44a3aa3.patch_0` upward to `patch_4095`, stopping after 40 missing numbers in a row.

**Archive layout:**
- A 72-byte header: magic `0xF0000011`, type count, entry count, then engine metadata.
- 32-byte type rows.
- 80-byte entry rows: id, type, offset, stream offset, GPU offset and 2 unused fields (all u64); then size and the
  remaining fields (u32).

**What it looks for:** Lua resources only (type `0xa14e8dfa2cd117e2`). Each one's data is `u32 length`, `u32 flag`
(2 = source text), then the text. Only source text is accepted. A resource is a loader mod when its first line is
exactly one of these:

| Header | Kind |
|---|---|
| `-- HD2-Addon: mods/<author>/<name>` | A module that returns a table of hooks |
| `-- HD2-Boot: mods/<author>/<name>` | A boot-style script with global `init`/`update`/`render`/`shutdown` |
| `-- HD2-Options: mods/<author>/<name>` | An options table for that mod (one per ticked Arsenal option folder) |

- **Names:** `<author>` and `<name>` match `[%w_%-]+`.
- **Sanity limits:** at most 200,000 entries and 4,096 types per archive, and 4 MB per Lua resource. An archive that
  is cut short or doesn't fit is skipped, never read past.
- **Order:** `mods/chef/...` first, then by name. `HD2-Requires:` dependencies are started before the mods that
  need them.
- **Duplicates:** two copies of the same name (an old version left installed): the one in the highest patch number
  runs, the same rule the game uses for its own files.
- **Scan cost:** about 1 ms for a typical mod list in the simulator, once per launch.

## Running mods

- **Addon:** the chunk is compiled with `loadstring(src, '@mods/<author>/<name>')`, given its own environment, and
  called with `chef` (the helper table) as its argument. A returned table's `update(dt)`, `render()` and
  `shutdown()` are called each frame and at exit. Returning nothing is allowed (the Bingus style): that mod simply has
  no hooks.
- **HD2-Boot script:** compiled the same way. `chef` is a global in its environment, and its global
  `init`/`update`/`render`/`shutdown` are called after the loader's own.
- **Errors:** every hook runs in `pcall`. The first 3 errors of a mod are logged. At 20 errors the mod is switched
  off for the session and named on screen.
- **Timing:** each mod's time per frame (average and worst, its timers and spread work included, over all of the
  loader's frames) goes into a status line when the numbers move, at most every 60 s, else every 10 minutes. A mod
  over its budget is named in the log (at most every 10 minutes).
- **Performance monitor** (the loader's own options, off by default): a panel with the game's frame time and every
  mod's average milliseconds a frame, share of the frame and worst call, once a second, plus the loader's own share
  and the panel's own cost (its text is drawn as rects, a few hundred a frame, so it shows that apart).
- **Options menu (F9):** the list of mods in alphabetical order; Enter opens one mod's options, under a < Back row
  (Backspace goes back too); Delete puts an option's default back; Escape or F9 closes the menu.
- **Worlds:** engine handles (units, GUIs, cameras) are dropped whenever the main world changes, and nothing made in
  one world is used in the next.
  - **Settled:** a world counts as settled after 3 s.
  - **Mission:** it counts as a mission above 5,000 units, or when mods' mission loot kinds are found in it. The ship
    is about 3,600 to 3,800 units.
  - **Unit scan:** spread over frames at 1,500 units a frame. It runs only while a mod watches unit kinds.

## Security model

**Scope:** what a loader mod (`HD2-Addon` or `HD2-Boot`) can reach on the player's computer and inside the game's Lua.
Source: `src/chef_loader/sandbox.lua`.

**Environment chain:**
- **Lookups:** `mod env` → `base` (replaced and refused names) → the game's globals. Both metatables carry
  `__metatable = 'locked'`, so `getmetatable` can't climb the chain and `setmetatable` on them fails.
- **`_G`:** the mod's own environment, so assignments never reach the game's globals.
- **Own copies:** each mod gets its own copies of `string`, `table`, `math`, `coroutine`, `bit`, `os` and `debug`.
  A mod that replaces a library function changes it only for itself.
- **The string metatable:** `getmetatable('')` returns a view whose `__index` is the mod's own `string` copy, never
  the shared string metatable.
- **File handles:** `getmetatable(file)` returns `nil` (file methods are shared).
- **Checks can't be bent:** the policy checks use functions captured before any mod runs.

**Refused or replaced:**

| Name | What a mod gets |
|---|---|
| `os` | Only `clock`, `time`, `date`, `difftime`, `getenv`. No `execute`, `exit`, `remove`, `rename`, `tmpname`, `setlocale`. |
| `io` | `open` and `lines` through the file policy below; `type`, `write` (stdout), `close`. `popen`, `tmpfile`, `input`, `output` raise errors. |
| `loadstring`, `load` | Text only (a chunk starting with byte 27 is refused). Loaded code gets the mod's environment, or the table passed to `load`. |
| `dofile`, `loadfile`, `module` | Raise errors (`module(..., package.seeall)` would hand out the game's globals). |
| `require` | Only `bit`, `string`, `table`, `math`, `coroutine`, `table.new`, `table.clear` (the mod's own copies). Everything else raises an error: no C modules, and no `require('_G')`, `('debug')` or `('io')`. Another mod's exports go through `chef.require`. |
| `package` | A per-mod stub (`loaded`, `preload`, empty `path`/`cpath`). No `loadlib`. |
| `debug` | `traceback` and `getinfo` (levels shifted past the wrapper, `func` removed). No `getlocal`, `getupvalue`, `setupvalue`, `getregistry`, `sethook`, `getmetatable`, `setfenv`. |
| `getfenv` / `setfenv` | A function of the game, of the loader or of another mod reads as the caller's own environment and can't be changed. Level 0 (the thread) reads as the mod's own and can't be set. |
| `collectgarbage` | `count`, `step` and `collect` only. Other options (`stop`, ...) do nothing. |

**File policy** (`sb.check`, applied to `io.open` and `io.lines`):
- **Reads are allowed** anywhere under the loader's folder and the game's settings folder (the same folder,
  `%APPDATA%\Arrowhead\Helldivers2\`, `saves\` included), and under the game's `data\`. Reads are also allowed for
  `.log .txt .json .csv .dat` files directly in the old `%LOCALAPPDATA%\` folder, so a mod can pick up its own old
  files.
- **Writes are allowed** only directly in the loader's folder, only as `.log .txt .json .csv .dat`, with names made
  of `[%w_%-%.]`, and never `chef_loader*` or `chef_data_*`. Saved tables go through `chef.save_table`.
- **Refused always:** `..`, a `:` after the drive (alternate data streams), `~` (8.3 short names such as
  `CHEF_L~1.LOG`), names ending in a dot or a space (Windows drops them, which would alias a protected file),
  wildcards, control characters and NUL, device names (`CON`, `NUL`, `COM1`, ...), UNC and `\\?\` paths, and paths
  over 400 characters.
- **Case and slashes:** comparisons are case-insensitive, and `/` counts as `\`.
- **Old files carry over:** a read of a missing file directly in the loader's folder falls back to the same name in
  the old `%LOCALAPPDATA%\` folder.
- **Denials are logged:** the first 10 per mod go to `chef_loader.log` as `blocked: <mod> tried to open <path>
  (<mode>): <reason>`, with the player's folders shown as `%APPDATA%` / `%LOCALAPPDATA%`.

**Fail closed:** if the locked-down space can't be built, no loader mod starts. The log and the screen say so.

**Verified in the simulator** (an escape test mod, 107 checks):
- **90 attempts refused:** everything in the tables above, plus `setfenv` on the loader's frames, bytecode through
  a `load` reader, `getmetatable('').__index` edits, `_G.update`/`rawset(_G, 'init')` hijacks, and the path tricks
  listed above.
- **17 intended uses still work.**
- **The game's globals were untouched after the run:** no new globals, and `string.format` and `render` intact.

## Crash guard

Some engine calls end the game with a native fault (a null read on a stale handle or the wrong kind of unit), which
`pcall` can't catch. So the loader learns from the crash instead.

- **Breadcrumbs** go to `chef_loader_trace.txt`, flushed as they are written:
  - `> owner|call` / `< owner|call`: the first time each engine call is made, and its return.
  - `>> owner|job @<s>` / `<< owner|job`: a per-frame job starting and ending.
  - `#### clean shutdown`: written when the game reaches `shutdown()`.
- **Next launch (rule 3):**
  - **A first call that never returned** is certain: it is skipped from then on, and the mod that made it is turned
    off.
  - **A per-frame job that was open** (and started within 60 s) is only suspected. It is skipped if the next launch
    dies in it again.
  - **A launch that reached `shutdown()`** is never blamed. The game often crashes by itself after a menu quit.
- **State** (`chef_loader_state.txt`):
  - `rule: 3`
  - `skip: <owner|call>`
  - `suspect: <key>`
  - `off: <mod> <fingerprint> <reason>`
- **Coming back on:** a mod turned off comes back on by itself when its source changes (an update: the fingerprint
  differs). `-- HD2-Keep-On-Crash: yes` in a mod's first lines keeps it on, with only the crashing call skipped.
- **Refused centrally:** engine calls known to end the game are refused before they reach the engine.

## Other mods' boot scripts

A mod that ships its own `boot` (instead of `HD2-Boot`) would normally replace the loader or be replaced by it.

- **When it deploys before the loader:** the loader runs it too.
  - **Its own space:** it gets an environment whose `_G` is itself, with `loadstring`/`load`/`dofile` sealed to that
    environment. A boot that loads code can't overwrite the loader's callbacks: that was a bug with another mod's
    loader in older builds.
  - **Full access:** it otherwise keeps everything, as the game would give it. Locking it down would only break it
    (the file-mod installer swaps game files at exit), and a boot deployed after the loader gets everything anyway.
    The log line says `with full access`.
  - **Callbacks:** each of its callbacks is called after the loader's own, crash-guarded, and switched off after 20
    errors.
  - **Identical copies** (fingerprint) run once.
- **When it deploys after the loader:** the game runs only that mod's `boot`, and no loader mod runs. Nothing a loader
  can do about it.
- **Skipped:**
  - Boots that are copies of this loader (they carry the `--@@LOADER@@` marker).
  - Other mod loaders: a boot whose source mentions both `HD2-Addon` and `9ba626afa44a3aa3`, or carries
    `__boot_mod_loader`, such as Boot Mod Loader. Running one would start every addon a second time. The log and the
    screen name it.

## Services and helpers

The `chef` table each mod receives, by api level. The full list with signatures is in docs/MODDING.md.

| api | Adds |
|---|---|
| 1 | Logging (`chef.log`, `chef.own_log`), options (`chef.options`), world and mission state, the camera, keys, guarded engine calls (`chef.call`), drawing (`rect`, `text`, `bitmap`, colors), unit kinds and loot scans. |
| 2 | `after_startup`, read-only `capabilities` / `has`, saved settings, shared values and events, `chef.require` with `-- HD2-Requires:` version checks, the in-game options menu (F9), key bindings, the `CowboyBingusModLoader` / `ModOptionsMenu` look-alikes, dev mode (F11 reload; test builds only). |
| 3 | Safe unit access (`units_near` over the shared scan), spawning, linking, particles and lights cleaned up at world changes, timers and work spread over frames with a frame budget per mod, the game's settings file, host and player count, shapes (triangles, circles, rings, arcs), sprite sheets, on-screen messages, typed text, key labels, `save_table`/`load_table`, the mod list. |

**Colors below native Render Scale:** the loader draws in the UI world, which shows colors differently from the
game's world. Every color a mod hands it is converted with per-channel curves measured in game
(stored = U⁻¹(N(c))). A see-through color gets the alpha and color that fit best over three backgrounds.

## Compat layer

Filled in only where the game lacks it. Nothing of the game's is replaced.

- **Added to the globals:**
  - `bit`: the full LuaJIT API with identical results, checked against native LuaJIT on 19,850 vectors.
  - `table.new`, `table.clear` and `table.unpack`.
  - `require('bit')`, `require('table.new')` and `require('table.clear')`.
- **In each mod's environment:** an `xpcall` that passes extra arguments, and a `load` that takes a string or a
  reader (text only).
- **Not possible from a script:** `ffi`, the JIT and LuaJIT bytecode.

## Files on the player's computer

All in `%APPDATA%\Arrowhead\Helldivers2\`.
- **Why there:** the game keeps its own settings there, so every player has the folder; the game's Lua can't create
  folders; and Mod Lag Watchdog logs there too.
- **Fallback:** if the folder can't be written, the loader uses `%LOCALAPPDATA%\`.
- **Mods find the folder** in `chef.log_directory`.

| File | Holds |
|---|---|
| `chef_loader.log` | The log. Appended each launch, started fresh once it passes 1 MB; at most 4 MB written per launch. |
| `chef_loader_state.txt` | The crash state (see Crash guard). |
| `chef_loader_trace.txt` | This launch's breadcrumbs (written again with only what's open whenever it passes 200 KB). |
| `chef_loader_settings.txt` | Saved settings and options-menu values: `<mod>\t<key>\t<b\|n\|s>\t<value>` per line. |
| `chef_loader_dev.txt` | Made by hand: dev mode's file list (`reload = <key>` optional; test builds only). |
| `chef_data_<author>_<mod>_<name>.lua` | A mod's saved table. It is text only and is loaded with an empty environment. |
| `<name>.log` | A mod's own log (`chef.own_log`). |

**Moving from `%LOCALAPPDATA%`** (where older builds kept these files): on the first launch, the state, settings,
dev list and breadcrumbs are copied, checked and removed from the old place. A file already in the new place wins.

The old place keeps a trace:
- **The old `chef_loader.log`** gets a last line pointing to the new place.
- **A mod's old own log** gets the same line the first time the mod opens its log.
- **Saved tables** are read from the old place until the mod saves again.
- **A mod's own files** read through `io.open` fall back to the old place the same way, so settings a mod kept carry
  over.

## Log reference

**At start-up:**
- `==== Chef Shared Loader 1.0.0 starting`
- `lua: ...`: the probe's flags and numbers, ending with `flavor=lua51 / luajit / luajit-like`.
- `added the LuaJIT parts this game lacks: ...` and `each addon gets LuaJIT's load and xpcall`.
- `found N addon(s), N boot-style script(s) and N option file(s) in N patch files (x ms)`.
- `mods run locked down: ... (sandbox 1.0.0)`, and on the first launch after the move,
  `moved from %LOCALAPPDATA% ...`.

**Per mod:**
- `started <mod> <version> (<patch>)`
- `two copies of <mod>: running the one deployed last (...)`
- `not started: <mod> <why>`
- `kept off: <mod> (...)`
- `blocked: <mod> tried to open ...`

**Other boots:**
- `running another mod's boot script too, with full access ...`
- `another mod loader's boot script in <patch> (...): not run ...`

**When the numbers move (at most every 60 s, else every 10 minutes):** `status: loader avg/max ms | <mod> on avg/max ms ...`

**Crash guard:**
- `the last launch crashed in: <owner|call> (that call is skipped from now on)`
- `the last launch ended while <job> was running; ...`

## Cost

- **Start-up:** about 1 ms in the simulator for the patch scan; a test build adds the probe's 200k-step timing loop
  (about 1.7 ms).
- **Per frame with no mods:** about 0.005 ms.
- **Lockdown:** a mod's global lookup takes one more table hop (mod env → base → globals). Simulator timings didn't
  change measurably.
- **`bit` on Lua 5.1, per call:**

| Call | Cost |
|---|---|
| `band` with a low mask (`0xFF`, `0xFFFF`, ...) | 0.19 us |
| Shifts | 0.15 us |
| `band`, `bor`, `bxor` with any other value | about 0.6 us |
| `tohex` | 0.8 us |

## Test builds and release builds

`tools/build.py --test N` sets the loader's `TEST` line to N. Only a test build has dev mode (`chef_loader_dev.txt`)
and the probe's 200k-step Lua timing loop, and its log starts `Chef Shared Loader 1.0.0 Test N starting`. A release
build (no `--test`) leaves `TEST` nil: no dev mode, no timing loop. Everything else is the same code.

## Source layout and build

| Path | What it is |
|---|---|
| `src/loader.lua` | The boot script. It carries the five modules below inline, because the game runs boot as one script. |
| `src/chef_loader/compat.lua` | The LuaJIT parts. |
| `src/chef_loader/probe.lua` | The once-a-launch Lua probe. |
| `src/chef_loader/services.lua` | The api 2 services, the options menu, the look-alikes and dev mode. |
| `src/chef_loader/utilities.lua` | The api 3 utilities. |
| `src/chef_loader/sandbox.lua` | The locked-down space (Security model). |
| `tools/splice.py` | Copies the five modules into loader.lua; `--check` exits 1 if they're out of step. |
| `tools/build.py` | `python3 tools/build.py <out> --header-from <a Lua patch that works on the current game> [--test N]`. Byte-identical output, and it refuses to build when loader.lua is out of step. |
| `tools/pack_addon.py` | Packs a loader mod from a `mod.json` into an Arsenal zip. |
| `tools/hd2_patch.py` | The patch archive format. |
| `art/` | The release art (`cards.py`: thumbnail, gallery, GitHub and AyakaMods pictures). |
| `examples/` | `hello_addon`, `hello_boot` and `utilities_test`. |
| `docs/MODDING.md` | The guide for mod makers. |

**Edit, then splice.** Edit a module in `src/chef_loader/`, then run `tools/splice.py`. The modules after the first
are spliced in as fields (`services.utilities`, `services.sandbox`), not locals: the loader's main function sits near
Lua 5.1's limit of 200 active locals (about a dozen free), so new start-up code goes in `do ... end` blocks or table fields.

## Known limits

- **A mod that replaces `boot` itself** gets the game's whole Lua whatever any loader does. The lockdown covers loader
  mods only.
- **The engine's script API** (`stingray`, `Unit`, `World`, ...) is reachable by design. Engine tables are shared, so
  a mod can still replace an engine function for every mod. That is tampering, not access to the computer.
- **No time limit:** a mod can still loop forever or allocate without limit, which hangs the game. Lua 5.1 has no
  cheap instruction limit.
- **Bingus-style hooks:** a mod that hooked the frame by assigning `_G.update` reached the engine in older builds; it
  no longer does. Such a mod should return `update` from its table or use `HD2-Boot`.

## Support

If you like my mods, you can support me on [Patreon](https://www.patreon.com/c/Chefboiardee).

## License

All rights reserved, except that your own mods written for it are yours. See [LICENSE](LICENSE).
