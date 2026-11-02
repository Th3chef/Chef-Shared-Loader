# modsim: run your mod without the game

`modsim.py` runs a Chef Shared Loader mod in a simulated Helldivers 2 session on plain Lua 5.1 (the game's Lua), in a
second or two. It builds the loader from this repository's `src`, packs your files into patches the way a mod manager
deploys them, plays a short session (title screen, ship, mission) and prints what happened: your mod's log lines,
its own log files, the health file and a summary of what was drawn.

It's for catching the easy things before you start the game: a Lua error, a mod that doesn't start, a requirement that
isn't met, an option that's refused, a call the loader refuses, a hook that's too slow, a color kept across frames.
What looks right in the game still needs the game.

## What you need

- `python3` with Pillow (`tools/build.py` uses it for the menu's title picture): `pip install pillow`.
- `lua5.1` on the PATH (on Debian or Ubuntu: `apt install lua5.1`; on macOS: `brew install lua@5.1`). On Windows, run
  it in WSL.
- No game files. `tools/build.py` asks for a Lua patch from the game (`--header-from`) for the header its patches
  carry; the game checks that header, the loader doesn't, so for the simulator a stand-in is made for you. To use the
  real one, pass `--header-from <game>/data/9ba626afa44a3aa3.patch_0` (the first patch file, with Chef Shared Loader
  installed and deployed). You need the real one only for a zip you install in the game (see `tools/pack_addon.py`).

## Running it

```
python3 tools/modsim/modsim.py examples/hello_addon/mod.json
python3 tools/modsim/modsim.py my_mod.lua --seconds 90 --press f6@50
python3 tools/modsim/modsim.py my_mod.lua my_mod_de.lua --scenario next_mission
```

The first arguments are your files:
- **A `.lua` file:** its first line names it (`-- HD2-Addon: mods/you/my_mod`, or `HD2-Boot`, `HD2-Lang`,
  `HD2-Options`). Each file is deployed as a patch of its own.
- **A `mod.json`** (the format `tools/pack_addon.py` takes): its `lua` files go in one patch, and each of its
  `options` in a patch of its own, all ticked, as Arsenal ticks them by default (`--no-options` leaves them out). A
  file without a header line goes in too: the start-up stub shipped as your mod's `boot` (see "Carrying the stub" in
  docs/MODDING.md) is then the boot the simulated game runs, as it would be in the game.

| Option | What it does |
|---|---|
| `--seconds N` | How long the session runs: 120 by default. The mission settles at 43 s, so give it more than that. |
| `--scenario normal` | The title screen from 0 s, the ship from 10 s, a mission from 40 s to the end. |
| `--scenario next_mission` | The same, and halfway through the mission a new mission world replaces it: every unit of the old one is gone, and asking one anything ends the run as a crash. Your mod should drop what it kept when `chef.world_id()` changes. |
| `--press KEY@S` | A key pressed at S seconds (one frame). Key names are the engine's: `f6`, `tab`, `left ctrl`, `numpad +`. `--press f9@50` opens the loader's options menu. |
| `--hold KEY@A-B` | A key held from A to B seconds. |
| `--click BUTTON@S` | A mouse button (`left`, `right`, `middle`) down for one frame at S seconds. |
| `--join S` | A second player starts joining at S seconds and is in 3 s later (`chef.players()`, `chef.joining()`, the `players` event). |
| `--full-log` | The whole `chef_loader.log`, not only the lines that name your mod. |
| `--keep DIR` | Keeps the simulated game folder in DIR: `data/` with the patches, and the loader's folder with its log, settings, breadcrumbs and your saved files. Off Windows, that folder's files are named `A\Arrowhead\Helldivers2\<name>` (the loader joins the path with backslashes). |
| `--header-from PATCH` | A Lua patch from the game for the patches' header (see above). |

The exit code is the session's: 0, 3 when the game would have crashed, and 1 or 2 for a problem with the simulator
or its arguments.

## What it prints

```
== chef_loader.log (the lines about mods/example/hello_addon)
12:00:00    0.0 s | started mods/example/hello_addon 1.0.0 (9ba626afa44a3aa3.patch_1; 0.1 ms, +57 KB)
12:00:00   43.0 s | [mods/example/hello_addon] mission started (world 3)
12:00:01  120.0 s | [mods/example/hello_addon] bye
== chef_loader_health.txt
name    state    why    kind    version    errors    ms_avg ...
mods/example/hello_addon    running        addon    1.0.0    0    0.003 ...
== the simulated game
session: 120 s (7200 frames): title 0-10 s, ship 10-40 s, mission from 40 s
drawn: 4620 rects (1 in the busiest frame), 0 triangles, 0 bitmaps, 0 world lines; texts made 1, changed 0
texts on screen at the end: HELLO, HELLDIVERS!
texts drawn during the session (the first 40): HELLO, HELLDIVERS!
units: spawned 0, destroyed 0, linked 0; particle effects 0; light colors set 0
```

- **The log lines** that name your mod: started or not (and why), your `chef.log` lines, Lua errors, refused calls,
  budget warnings, a mod switched off. A mod's own log (`chef.own_log`) is printed after them.
- **A crash** prints `GAME CRASH at <s> s: <what>` and the last lines of the loader's breadcrumbs
  (`chef_loader_trace.txt`). A call opened with `>` and never closed is the one the loader skips from the next launch.
- **A `WARNING`** when your mod drew with a color made in an earlier frame: in the game those draw white.
- `print()` in your mod writes to the simulated game's output, after the summary.

## What's simulated

- **The start-up:** the game runs the `boot` in the highest patch (the loader's start-up stub), whose `require`
  finds the loader's core among the patches, as in the game. Your mod is found, checked and started by the loader
  you built, with its whole lockdown, crash guard and services.
- **Worlds:** the title screen (no levels), the ship (one level, about 1,500 units), a mission (600 levels, about
  2,000 units) and the UI world above them (where `chef.TOP` layers draw). Each world settles 3 s after it appears,
  so `chef.world()`, `chef.in_mission()` and the `world` / `mission_start` events come then.
- **Units for watches:** in the mission: the camera, the player's Helldiver (`4d1c334d294dfa97`, at 0, 1, 9, with a
  `head` node and one light), eight medals (`773c4184e4bad0df`), a runtime-built unit (`46cab355bd8d4d37`) and
  filler units of 40 kinds of their own (`f111000000000000` to `f111000000000039`). 20 s into the mission the player
  picks up two medals: they leave the world. Units don't move.
- **Spawning:** every kind in the world is loaded, and so is `beefbeefbeefbeef`, a stand-in for a unit your own
  patch would ship. Spawned units, links, particle effects and lights are counted.
- **The camera:** at 0, 0, 10 in the mission, looking along (0.6, 0.8, 0), vertical field of view 0.9;
  `chef.world_to_screen` is a real perspective projection on a 2560 x 1440 screen.
- **Rays against boxes:** `Math.ray_box_intersection` is a real ray against an oriented box, so `chef.ray_box` gives
  true distances, misses and 0 from inside; `Unit.box` gives every unit a box 0.8 x 0.8 x 2 m whose middle is 1 m
  above its position, facing +y. There's no world raycast (the game has none for Lua either). What the game itself
  answers for a ray that starts inside a box isn't known yet: don't build on that 0.
- **Drawing:** screen GUIs for rects, triangles and bitmaps, and the game's font (retained texts, measured with
  advances like the real font's). Nothing is rendered: draws are counted, and the texts are listed.
- **Keyboard and mouse:** the engine's key names, and only the presses you script. The cursor rests mid-screen, the
  mouse doesn't move and the wheel doesn't turn. The mouse's dead zone is modeled, so `chef.hold_mouse` works.
- **Timers and the clock:** 60 frames a second, `update(dt)` then `render()` each frame; `chef.after`, `chef.every`,
  `chef.spread`, the frame budget and the hang watchdog run as in the game (timings are your computer's).
- **Files:** the loader's folder (log, settings, `chef.save` / `chef.save_table`, your own logs), and the game's
  settings file with a 2560 x 1440 render resolution for `chef.setting`. Each run starts from an empty folder.
- **The session:** an online session from the ship on, hosted by this game alone (`--join` adds a player).
- **Crashes the engine would have:** asking a unit of a world that's gone anything, asking a destroyed unit or a
  runtime-built unit where it is or its box, `Unit.has_camera` without a camera name, a text at a NaN or infinite
  position, `Math.ray_box_intersection` given anything but three Vector3s and a Matrix4x4.
  (Through `chef`, the loader refuses the known ones first; a call straight to the engine isn't refused.)

## What isn't

- How it looks: nothing is drawn, so check layout, colors and sizes in the game.
- The game itself: no gameplay, no enemies, no HUD, no map, no pause screen, no controller, no other players' games.
  Engine calls the simulator doesn't have (most of the engine) answer `nil` and a reason through `chef.call`, and
  raise an error when called straight.
- Your textures, units and other resources: only Lua resources are read from the patches.
- Below native render scale, other mods' boot scripts, what trusted mods are given (the Steam lobby, their own
  files, game patch files), and a second launch (what the loader does after a crash): `--keep` keeps the folder to
  look at.
- Dev mode: the loader is built as a release build.
- Performance: Lua runs at your computer's speed, without the game's load.
