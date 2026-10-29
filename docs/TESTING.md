# Checking your mod before the game

Two tools in this repository help you write a Chef Shared Loader mod without starting Helldivers 2 each time: type
stubs that give your editor every `chef` helper, and a simulator that runs your mod through a short game session.
Neither replaces a run in the game. The helpers themselves are described in [MODDING.md](MODDING.md).

## Autocomplete and checks in your editor

`docs/types/chef.lua` describes every `chef` helper and field for the Lua language server (LuaLS): parameters,
return values, the option spec, the watch, timer and binding objects, the `chef.mods()` entries, the events and the
capability names. The file is only read by your editor. Don't ship it with your mod.

**VS Code:** install the "Lua" extension (by sumneko, the Lua language server), then add a `.luarc.json` to your mod's
folder:

```json
{
  "runtime.version": "Lua 5.1",
  "workspace.library": ["<path to this repository>/docs/types"]
}
```

or put the same two settings in VS Code's own settings (`"Lua.runtime.version"` and `"Lua.workspace.library"`).
Copying `docs/types/chef.lua` into your mod's folder works too (keep it out of what you pack). Any editor that runs
the Lua language server (Neovim, Zed, JetBrains with a LuaLS plugin) takes the same `.luarc.json`.

Then tell the editor what `chef` is. In an addon:

```lua
-- HD2-Addon: mods/you/my_mod
---@type Chef
local chef = ...
```

In a boot-style script (`-- HD2-Boot:`) `chef` is a global, already typed by the stubs. Your addon's returned table
can be typed as `---@type ChefAddon` (`version`, `update`, `render`, `shutdown`, `on_stop`).

Now `chef.` lists the helpers, `chef.option('size', { type = ` offers the row types, and a wrong argument or a typo
in a helper's name is underlined. The helpers new in 1.4.0 say so ("from 1.4.0"): check `chef.has('<capability>')`
before using one, so your mod still runs on an older loader.

## Running your mod in the simulator

`tools/modsim/modsim.py` builds the loader from this repository, deploys your files as patches, and runs a
simulated session on plain Lua 5.1 (the game's Lua): the title screen, the ship, then a mission. It prints your
mod's log lines, the health file and what was drawn.

```
python3 tools/modsim/modsim.py my_mod.lua
python3 tools/modsim/modsim.py mod.json --seconds 90 --press f6@50
python3 tools/modsim/modsim.py my_mod.lua --scenario next_mission
```

- **Needs** `python3` with Pillow and `lua5.1` (on Windows, in WSL). No game files: a real game patch is only needed
  for a zip you install.
- **Shows** whether your mod starts, its `chef.log` lines and own logs, Lua errors, refused calls, budget warnings,
  the texts it drew, and a crash where the game would have crashed (a unit kept from a world that's gone, say, with
  `--scenario next_mission`).
- **Doesn't show** how it looks, or anything of the game beyond what a mod reads through the loader. What's
  simulated and what isn't: [tools/modsim/README.md](../tools/modsim/README.md).

The `examples/` mods run as they are:

```
python3 tools/modsim/modsim.py examples/hello_addon/mod.json
python3 tools/modsim/modsim.py examples/utilities_test/util_test.lua
```
