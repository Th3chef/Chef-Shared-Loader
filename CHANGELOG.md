# Changelog

## 0.2.0 (in testing)

- Open to every mod author: any mod with a
  `-- HD2-Addon: mods/<author>/<name>` or `-- HD2-Boot: mods/<author>/<name>` file runs, side by side and crash-guarded.
- Shared services (api 2): `after_startup`, capabilities, saved settings per mod, shared values and events between
  mods, `require` of another mod's exports with version checks, a log of its own for any mod, and look-alikes of
  `CowboyBingusModLoader` and `ModOptionsMenu`.
- An in-game options menu (F9) with every mod's options and key bindings, saved between launches, with doubled keys
  marked, a search (/) and the loader's own Budget warning setting.
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
