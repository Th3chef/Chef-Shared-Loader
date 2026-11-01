#!/usr/bin/env python3
"""Packs a Chef Shared Loader mod into an Arsenal / HD2 Mod Manager zip.

  python3 tools/pack_addon.py <mod.json> <out dir> [--header-from <a Lua patch that works on the current game>]

mod.json (saved as UTF-8):
  {
    "name": "My Mod",                       shown in the mod manager
    "version": "1.0.0",
    "guid": "<a new uuid of your own>",
    "description": "What it does. Needs Chef Shared Loader 1.0.0 or newer.",
    "thumbnail": "thumbnail.png",            optional
    "lua": [                                 the core folder: your addon / boot-style script and any extra Lua
      {"resource": "mods/you/my_mod", "file": "my_mod.lua"}
    ],
    "options": [                             optional Arsenal options: each is a folder with one options file
      {"folder": "fast", "name": "Fast Mode", "description": "...", "addon": "mods/you/my_mod", "table": "{ fast = true }"}
    ]
  }

Each Lua file must start with its header line ("-- HD2-Addon: mods/you/my_mod", "-- HD2-Boot: mods/you/my_mod",
"-- HD2-Options: mods/you/my_mod" for an options file, or "-- HD2-Lang: mods/you/my_language" for a language file); one
text editor's UTF-8 mark in front of it is fine. A note says so when the loader won't use a file or will skip its name,
and the pack still goes through.
Every resource is a Lua resource in a 9ba626afa44a3aa3 patch, the way Arsenal deploys mods. The zip is the same byte
for byte on every build."""
import json, os, re, sys, uuid, zipfile, shutil
sys.dont_write_bytecode = True          # no __pycache__ in the kit
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hd2_patch as h

ZIP_DATE = (2026, 10, 23, 0, 0, 0)
# the header of a Lua patch (engine metadata only); --header-from takes it from a patch that works on the current game
HEADER = bytes.fromhex('0000000000000000000000000000000000000000ea7b0000000000000000'
                       '000000000000000000000000000000000000000000000000000000000000')
# What the loader reads of a Lua file (read_patch in loader.lua): the first 112 bytes of its text, past one UTF-8 mark,
# then the kind and the name up to the first character a name can't hold, then ALLOW on that name.
HEADS = (b'-- HD2-Addon: ', b'-- HD2-Boot: ', b'-- HD2-Lang: ', b'-- HD2-Options: ')
WINDOW = 112
HEADER_RE = re.compile(rb'-- HD2-[A-Za-z]+: ([A-Za-z0-9_/.\-]+)')
ALLOW = re.compile(rb'mods/[A-Za-z0-9_\-]+/[A-Za-z0-9_\-/]*[A-Za-z0-9_\-]')


def header_name(file, src):
    """-> the name the loader runs this Lua file under, or None (with a note on why it won't run it)."""
    at = 3 if src[:3] == b'\xef\xbb\xbf' else 0
    line = src[at:].split(b'\n', 1)[0]
    if not line.startswith(HEADS):
        print('note: %s has no "-- HD2-Addon:" / "-- HD2-Boot:" / "-- HD2-Lang:" / "-- HD2-Options:" first line, so Chef Shared Loader will not use it on its own' % file)
        return None
    m = HEADER_RE.match(src, at, WINDOW)
    if not m:
        print('note: %s has no name after its "-- HD2-" header, so Chef Shared Loader will skip it' % file)
        return None
    name = m.group(1).decode()
    if HEADER_RE.match(line).group(1) != m.group(1):
        print('note: %s has a name too long for the first line: Chef Shared Loader reads only "%s"' % (file, name))
    if '//' in name or not ALLOW.fullmatch(m.group(1)):
        print('note: %s is named "%s", so Chef Shared Loader will skip it: the name must be mods/<author>/<name>, more parts allowed (letters, digits, _ and -)' % (file, name))
        return None
    return name


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


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    sys.stdout.reconfigure(errors='backslashreplace')       # (a mod's name on a console that can't show it)
    spec_path, out = args[0], args[1]
    header = HEADER
    if '--header-from' in args:
        header = h.lua_header_from(args[args.index('--header-from') + 1])
    assert len(header) == 60
    try:
        spec = json.load(open(spec_path, encoding='utf-8-sig'))
    except UnicodeDecodeError:
        sys.exit('%s is not UTF-8: save it as UTF-8, not ANSI' % spec_path)
    base = os.path.dirname(os.path.abspath(spec_path))
    for key in ('name', 'version', 'guid', 'lua'):
        if key not in spec:
            sys.exit('mod.json needs "%s"' % key)
    uuid.UUID(spec['guid'])
    d = os.path.join(out, 'pack')
    shutil.rmtree(d, ignore_errors=True)
    entries, names = [], set()
    for item in spec['lua']:
        src = open(os.path.join(base, item['file']), 'rb').read()
        names.add(header_name(item['file'], src))
        entries.append((h.resource_hash(item['resource']), h.lua_resource(src)))
    core = os.path.join(d, 'core'); os.makedirs(core)
    h.write_lua_archive(os.path.join(core, '9ba626afa44a3aa3.patch_0'), entries, header)
    options = [{'Name': spec['name'] + ' (core)', 'Description': 'The mod itself. Keep this ticked.', 'Include': ['core']}]
    for o in spec.get('options', []):
        folder = os.path.join(d, o['folder']); os.makedirs(folder)
        text = ('-- HD2-Options: %s\nreturn %s\n' % (o['addon'], o['table'])).encode()
        aim = header_name('option ' + o['folder'], text)
        if aim and aim not in names:
            print('note: option %s is for %s, which no Lua file here names: it does nothing unless that mod is installed' % (o['folder'], aim))
        h.write_lua_archive(os.path.join(folder, '9ba626afa44a3aa3.patch_0'),
                            [(h.resource_hash(o['addon'] + '/options/' + o['folder']), h.lua_resource(text))], header)
        options.append({'Name': o['name'], 'Description': o.get('description', ''), 'Include': [o['folder']]})
    manifest = {'Version': 1, 'Guid': spec['guid'], 'Name': spec['name'] + ' ' + spec['version'],
                'Description': spec.get('description', '') or 'Needs Chef Shared Loader 1.0.0 or newer.', 'Options': options}
    if spec.get('thumbnail'):
        shutil.copy(os.path.join(base, spec['thumbnail']), os.path.join(d, 'thumbnail.png'))
        manifest['IconPath'] = 'thumbnail.png'
    json.dump(manifest, open(os.path.join(d, 'manifest.json'), 'w'), indent=2)
    z = os.path.join(out, '%s-%s.zip' % (spec['name'].replace(' ', '-'), spec['version']))
    zip_dir(d, z)
    print(z)


if __name__ == '__main__':
    main()
