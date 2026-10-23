#!/usr/bin/env python3
"""Builds the standalone Chef Shared Loader for Arsenal.

  python3 tools/build.py <out dir> --header-from <a working Lua patch>            -> Chef-Shared-Loader-<ver>.zip (release)
  python3 tools/build.py <out dir> --header-from <a working Lua patch> --test N   -> Chef-Shared-Loader-<ver>-Test-N.zip

The zip holds one patch with the game's `boot` script replaced by src/loader.lua (with compat.lua, probe.lua,
services.lua and utilities.lua copied in; tools/splice.py --check must pass), plus manifest.json and thumbnail.png.
Same zip byte for byte on every build. Test builds share the loader's own GUID and update it in place, as my script
mods' test builds do.

A test build also sets the loader's TEST line (`local TEST = N --@@TEST@@`): only a test build has dev mode
(chef_loader_dev.txt) and the probe's Lua timing loop, and its log says "Test N". A release build leaves TEST nil.
The boot script that went into the patch is written next to the zip too (chef_loader_boot.lua), for the simulator
and for mods that carry the loader built in.
"""
import json, os, re, subprocess, sys, zipfile, shutil
sys.dont_write_bytecode = True          # no __pycache__ in the kit
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, 'tools'))
import hd2_patch as h

VERSION = '0.2.0'
GUID = '2d6f0b8e-91c4-4a37-b5e2-7c0a94f13d58'      # Chef Shared Loader (the same id since its first test build)
ZIP_DATE = (2026, 10, 23, 0, 0, 0)

args = sys.argv[1:]
OUT = args[0]
TEST = int(args[args.index('--test') + 1]) if '--test' in args else None
assert '--header-from' in args, 'pass --header-from <a Lua patch that works on the current game>'
HEADER = open(args[args.index('--header-from') + 1], 'rb').read()[12:72]
assert len(HEADER) == 60

if subprocess.call([sys.executable, os.path.join(HERE, 'tools', 'splice.py'), '--check']) != 0:
    sys.exit('loader.lua is out of step with src/chef_loader/*.lua: run tools/splice.py first')

def zip_dir(src, dest):
    paths = []
    for root, dirs, files in os.walk(src):
        dirs.sort()
        paths += [os.path.join(root, f) for f in sorted(files)]
    paths.sort(key=lambda p: os.path.relpath(p, src).replace(os.sep, '/'))
    with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in paths:
            info = zipfile.ZipInfo(os.path.relpath(full, src).replace(os.sep, '/'), ZIP_DATE)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, open(full, 'rb').read(), compresslevel=9)

name = f'Chef Shared Loader {VERSION}' + (f' Test {TEST}' if TEST else '')
d = os.path.join(OUT, 'loader')
shutil.rmtree(d, ignore_errors=True)
os.makedirs(d)
src = open(os.path.join(HERE, 'src', 'loader.lua'), 'rb').read()
MARK = re.compile(rb'^local TEST = nil --@@TEST@@', re.M)
assert len(MARK.findall(src)) == 1, 'loader.lua needs exactly one "local TEST = nil --@@TEST@@" line'
if TEST:
    src = MARK.sub(b'local TEST = %d --@@TEST@@' % TEST, src)
h.write_lua_archive(os.path.join(d, '9ba626afa44a3aa3.patch_0'), [(h.resource_hash('boot'), h.lua_resource(src))], HEADER)
json.dump({'Version': 1, 'Guid': GUID, 'Name': name, 'IconPath': 'thumbnail.png',
           'Description': ("Runs Lua mods on the current game build (Lua 5.1) for any mod author: finds every Chef Shared Loader mod "
                           "in your installed mods and runs each in its own space, side by side, with no fight over the game's "
                           "boot script (mods that still replace boot run too when Chef Shared Loader is deployed last). Puts back the "
                           "pure-Lua parts of LuaJIT mods use. A mod that crashes the game is switched off on the next launch "
                           "and named in chef_loader.log (%APPDATA%\\Arrowhead\\Helldivers2). Mods run locked down: no programs, no native code, "
                           "files only in the game's own folders. Mod makers: see docs/MODDING.md in the source kit.")},
          open(os.path.join(d, 'manifest.json'), 'w'), indent=2)
shutil.copy(os.path.join(HERE, 'tools', 'thumbnail.png'), d)
z = os.path.join(OUT, f'Chef-Shared-Loader-{VERSION}' + (f'-Test-{TEST}' if TEST else '') + '.zip')
zip_dir(d, z)
# the boot script next to the zip, for the simulator
open(os.path.join(OUT, 'chef_loader_boot.lua'), 'wb').write(src)
print(z)
