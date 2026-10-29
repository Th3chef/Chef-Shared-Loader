#!/usr/bin/env python3
"""Builds the standalone Chef Shared Loader for Arsenal.

  python3 tools/build.py <out dir> --header-from <a working Lua patch>            -> Chef-Shared-Loader-<ver>.zip (release)
  python3 tools/build.py <out dir> --header-from <a working Lua patch> --test N   -> Chef-Shared-Loader-<ver>-Test-N.zip

The zip holds one patch with two Lua resources, plus manifest.json and thumbnail.png:
  boot                            the start-up stub, src/stub.lua: frozen (its sha256 is below; the build stops if the
                                  file changed). It does what the game's own boot does, then loads the core with require.
  mods/chef_shared_loader/core_1  the loader itself: src/loader.lua (with compat.lua, probe.lua, services.lua,
                                  utilities.lua, sandbox.lua and runtime.lua copied in; tools/splice.py --check must pass)
Same zip byte for byte on every build. Test builds share the loader's own GUID and update it in place.

A test build also sets the loader's TEST line (`local TEST = N --@@TEST@@`): only a test build has dev mode
(chef_loader_dev.txt) and the probe's Lua timing loop, and its log says "Test N". A release build leaves TEST nil.
Written next to the zip too: chef_loader_boot.lua (the core as it went into the patch, for the simulator, which can
also run it as a boot, and for mods that carry the loader built in) and chef_loader_stub.lua (the stub, for mods that
ship it as their own boot).
"""
import hashlib, json, os, re, subprocess, sys, zipfile, shutil
sys.dont_write_bytecode = True          # no __pycache__ in the kit
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, 'tools'))
import hd2_patch as h

import re
# the version comes from the loader itself, so the zip, the manifest and the log always agree
VERSION = re.search(r"^local VERSION = '([^']+)'", open(os.path.join(HERE, 'src', 'loader.lua'), encoding='utf-8').read(), re.M).group(1)
GUID = '2d6f0b8e-91c4-4a37-b5e2-7c0a94f13d58'      # Chef Shared Loader's mod id (fixed: mod managers match updates by it)
ZIP_DATE = (2026, 10, 29, 0, 0, 0)
# The start-up stub is frozen: mods ship it byte for byte as their own boot, and the loader tells it from a changed copy
# by its fingerprint (scan.STUB in loader.lua). A new stub is a new core name (core_2) and a new release of both.
STUB_SHA256 = '7da502fea32b041b320bc7b14b7cf6d24b0334860fced8832e8ca2b3910477e1'
CORE = 'mods/chef_shared_loader/core_1'

args = sys.argv[1:]
OUT = args[0]
TEST = int(args[args.index('--test') + 1]) if '--test' in args else None
assert '--header-from' in args, 'pass --header-from <a Lua patch that works on the current game>'
HEADER = open(args[args.index('--header-from') + 1], 'rb').read()[12:72]
assert len(HEADER) == 60

# Test builds only, opt in: with CSL_BUILD_CACHE=<dir> (a test runner sets one per run, for the dozens of suites that each
# build the same Test 1), a build is made once per set of inputs into <dir> and copied from there into <out dir>. The
# key is every input of the output: the src files, this script and its helpers, the header bytes and the test number.
# A release build (no --test) never uses it.
CACHE = os.environ.get('CSL_BUILD_CACHE')
if CACHE and TEST:
    import fcntl, zlib
    key = hashlib.sha256()
    ins = sorted(os.path.relpath(os.path.join(r, f), HERE).replace(os.sep, '/')
                 for r, ds, fs in os.walk(os.path.join(HERE, 'src')) for f in fs)
    ins += ['tools/build.py', 'tools/hd2_patch.py', 'tools/splice.py', 'tools/thumbnail.png']
    for rel in ins:
        key.update(rel.encode() + b'\0' + open(os.path.join(HERE, rel), 'rb').read() + b'\0')
    key.update(HEADER + b'%d\0' % TEST + sys.version.encode() + zlib.ZLIB_RUNTIME_VERSION.encode())
    built = os.path.join(CACHE, key.hexdigest()[:32])
    os.makedirs(CACHE, exist_ok=True)
    with open(built + '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)              # (suites building at once: one builds, the others wait for it)
        if not os.path.exists(os.path.join(built, '.done')):
            shutil.rmtree(built, ignore_errors=True)
            env = dict(os.environ); del env['CSL_BUILD_CACHE']
            p = subprocess.run([sys.executable, os.path.abspath(__file__), built] + args[1:], env=env,
                               capture_output=True, text=True)
            if p.returncode:
                sys.stdout.write(p.stdout); sys.stderr.write(p.stderr); sys.exit(p.returncode)
            open(os.path.join(built, '.done'), 'w').close()
    d = os.path.join(OUT, 'loader')
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(OUT, exist_ok=True)
    shutil.copytree(os.path.join(built, 'loader'), d)
    for f in sorted(os.listdir(built)):
        if f not in ('loader', '.done'): shutil.copyfile(os.path.join(built, f), os.path.join(OUT, f))
    print(os.path.join(OUT, next(f for f in os.listdir(built) if f.endswith('.zip'))))
    sys.exit(0)

if subprocess.call([sys.executable, os.path.join(HERE, 'tools', 'splice.py'), '--check']) != 0:
    sys.exit('loader.lua is out of step with src/chef_loader/*.lua: run tools/splice.py first')

stub = open(os.path.join(HERE, 'src', 'stub.lua'), 'rb').read()
if hashlib.sha256(stub).hexdigest() != STUB_SHA256:
    sys.exit('src/stub.lua changed: the start-up stub is frozen (mods ship it byte for byte); put it back')

def stub_fp(b):           # loader.lua's fingerprint()
    h = len(b)
    for x in b: h = (h * 31 + x) % 2147483647
    return '%x' % h

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
m = re.search(rb"^scan\.STUB, scan\.CORE, scan\.prev = '([0-9a-f]+)', '([^']+)'", src, re.M)
assert m and m.group(1).decode() == stub_fp(stub) and m.group(2).decode() == CORE, \
    "loader.lua's scan.STUB / scan.CORE don't match src/stub.lua and " + CORE
assert stub.count(b"'" + CORE.encode() + b"'") == 1 and stub.splitlines()[0].endswith(b'--@@LOADER@@')
# the menu's title picture (src/menu_banner.png, 534 x 74) as a texture of my own patch; services.lua draws it by id
BANNER = 'mods/chef_shared_loader/menu_banner'
from PIL import Image
banner = Image.open(os.path.join(HERE, 'src', 'menu_banner.png')).convert('RGBA')
assert banner.size == (534, 74), banner.size
assert ("local BANNER_TEX = '%016x'" % h.resource_hash(BANNER)).encode() in src, "services.lua's BANNER_TEX isn't " + BANNER
h.write_lua_archive(os.path.join(d, '9ba626afa44a3aa3.patch_0'),
                    [(h.resource_hash('boot'), h.lua_resource(stub)), (h.resource_hash(CORE), h.lua_resource(src))], HEADER,
                    textures=[(h.resource_hash(BANNER), h.texture_rgba_header(*banner.size), banner.tobytes())])
json.dump({'Version': 1, 'Guid': GUID, 'Name': name, 'IconPath': 'thumbnail.png',
           'Description': ("One Lua loader for every mod: runs them side by side, "
                           "crash-guarded and locked down. F9 opens one options menu for every mod (keyboard, "
                           "mouse or controller) and a performance monitor, drawn over the game's menus. Keep it at the highest "
                           "priority. Log: chef_loader.log in %APPDATA%\\Arrowhead\\Helldivers2. "
                           "Mod Source: github.com/Th3chef/Chef-Shared-Loader")},
          open(os.path.join(d, 'manifest.json'), 'w'), indent=2)
shutil.copy(os.path.join(HERE, 'tools', 'thumbnail.png'), d)
z = os.path.join(OUT, f'Chef-Shared-Loader-{VERSION}' + (f'-Test-{TEST}' if TEST else '') + '.zip')
zip_dir(d, z)
# the core next to the zip (the simulator runs it as a boot too) and the stub, for mods that ship it as their boot
open(os.path.join(OUT, 'chef_loader_boot.lua'), 'wb').write(src)
open(os.path.join(OUT, 'chef_loader_stub.lua'), 'wb').write(stub)
print(z)
