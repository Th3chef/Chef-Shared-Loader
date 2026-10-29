#!/usr/bin/env python3
"""Runs a Chef Shared Loader mod in a simulated game, without Helldivers 2.

  python3 tools/modsim/modsim.py <your_mod.lua | mod.json> [more .lua files] [options]

  --seconds N             how long the session runs (default 120): the title screen from 0 s, the ship from 10 s,
                          a mission from 40 s to the end
  --scenario NAME         normal (default) or next_mission (halfway through the mission a new mission world
                          replaces it: every unit of the old one is gone, and asking one anything is a crash)
  --press KEY@S           a key pressed at S seconds, e.g. --press f6@70 (engine key names: 'f6', 'tab', 'left ctrl')
  --hold KEY@A-B          a key held from A to B seconds, e.g. --hold "left ctrl@70-72"
  --click BUTTON@S        a mouse button (left, right, middle) pressed at S seconds and let go a frame later
  --join S                a second player starts joining at S seconds and is in 3 s later
  --no-options            a mod.json's Arsenal options are left unticked (by default every one is ticked, as Arsenal does)
  --header-from PATCH     a Lua patch from the game (data/9ba626afa44a3aa3.patch_0); not needed to simulate
  --full-log              print the whole chef_loader.log, not only the lines about your mod
  --keep DIR              keep the simulated game folder (logs, saved settings, patches) in DIR

Needs python3 with Pillow (tools/build.py uses it) and lua5.1 on the PATH. The loader is built from this repository's
src with tools/build.py, your files are packed into patches with tools/hd2_patch.py the way a mod manager deploys
them, and the session runs on plain Lua 5.1 like the game's. See tools/modsim/README.md."""
import json, os, re, shutil, struct, subprocess, sys, tempfile
sys.dont_write_bytecode = True          # no __pycache__ in the repository
HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(KIT, 'tools'))
import hd2_patch as h
import pack_addon

SIM = os.path.join(HERE, 'modsim.lua')
HEADER_RE = re.compile(r'^-- HD2-(Addon|Boot|Lang|Options): (mods/[\w\-]+(?:/[\w\-]+)+)\s*$')
KEY_RE = re.compile(r'^[a-z0-9 +\-./]+$')
LOG_DIR = os.path.join('A', 'Arrowhead', 'Helldivers2')
FLAT = 'A\\Arrowhead\\Helldivers2\\'     # the same folder off Windows: the backslashes are part of a file's name there
SETTINGS = '''render_settings = {
	render_resolution = [ 2560 1440 ]
	shadows = "high"
}
screen_resolution = [ 2560 1440 ]
fullscreen = true
'''


def die(msg):
    sys.exit('modsim: ' + msg)


def parse_args(argv):
    a = dict(files=[], seconds=120.0, scenario='normal', press=[], hold=[], click=[], join=None, options=True,
             header=None, full=False, keep=None)
    i = 0
    def value():
        nonlocal i
        i += 1
        if i >= len(argv): die(argv[i - 1] + ' needs a value')
        return argv[i]
    def at(s, what):
        m = re.match(r'^(.+)@([0-9.]+)$', s)
        if not m: die('%s takes NAME@SECONDS, not %r' % (what, s))
        return m.group(1).lower(), float(m.group(2))
    while i < len(argv):
        x = argv[i]
        if x == '--seconds': a['seconds'] = float(value())
        elif x == '--scenario':
            a['scenario'] = value()
            if a['scenario'] not in ('normal', 'next_mission'): die('--scenario is normal or next_mission')
        elif x == '--press': a['press'].append(at(value(), '--press'))
        elif x == '--hold':
            m = re.match(r'^(.+)@([0-9.]+)-([0-9.]+)$', value())
            if not m: die('--hold takes KEY@FROM-TO')
            a['hold'].append((m.group(1).lower(), float(m.group(2)), float(m.group(3))))
        elif x == '--click':
            b, t = at(value(), '--click')
            if b not in ('left', 'right', 'middle'): die('--click takes left, right or middle')
            a['click'].append((b, t))
        elif x == '--join': a['join'] = float(value())
        elif x == '--no-options': a['options'] = False
        elif x == '--header-from': a['header'] = value()
        elif x == '--full-log': a['full'] = True
        elif x == '--keep': a['keep'] = value()
        elif x in ('-h', '--help'): print(__doc__); sys.exit(0)
        elif x.startswith('--'): die('unknown option ' + x)
        else: a['files'].append(x)
        i += 1
    if not a['files']: print(__doc__); sys.exit(2)
    for k, *_ in a['press'] + a['hold']:
        if not KEY_RE.match(k): die('%r is not a key name' % k)
    return a


def header_line(path, src, need=True):
    first = src.split(b'\n', 1)[0].decode('utf-8', 'replace').rstrip('\r')
    m = HEADER_RE.match(first)
    if not m:
        if not need: return None, None
        die('%s: the first line must be "-- HD2-Addon: mods/<you>/<name>" (or HD2-Boot, HD2-Lang, HD2-Options)' % path)
    return m.group(1), m.group(2)


def collect(a):
    """-> the patches to deploy, each a list of (resource name, source bytes), and the mod names to report on"""
    patches, names = [], []
    for path in a['files']:
        if path.endswith('.json'):
            spec = json.load(open(path, encoding='utf-8'))
            base = os.path.dirname(os.path.abspath(path))
            core = []
            for item in spec.get('lua', []):
                src = open(os.path.join(base, item['file']), 'rb').read()
                # (a file with no header goes in all the same, as tools/pack_addon.py packs it: the start-up stub
                # shipped as the mod's boot, say)
                kind, name = header_line(item['file'], src, need=False)
                core.append((item['resource'], src))
                if name and kind != 'Options': names.append(name)
            patches.append(core)
            # each Arsenal option is a folder of its own, deployed as a patch of its own
            for o in spec.get('options', []) if a['options'] else []:
                text = ('-- HD2-Options: %s\nreturn %s\n' % (o['addon'], o['table'])).encode()
                patches.append([(o['addon'] + '/options/' + o['folder'], text)])
        else:
            src = open(path, 'rb').read()
            kind, name = header_line(path, src)
            res = name + '/options/sim' if kind == 'Options' else name
            patches.append([(res, src)])
            if kind != 'Options': names.append(name)
    return patches, names


def lua_str(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def sim_settings(a):
    parts = ['SCENARIO = %s' % lua_str(a['scenario']), 'SIMSECS = %g' % a['seconds']]
    parts.append('PRESS = {' + ', '.join('{ %s, %g }' % (lua_str(k), t) for k, t in a['press']) + '}')
    parts.append('HOLD = {' + ', '.join('{ %s, %g, %g }' % (lua_str(k), f, t) for k, f, t in a['hold']) + '}')
    parts.append('CLICK = {' + ', '.join('{ %s, %g }' % (lua_str(b), t) for b, t in a['click']) + '}')
    if a['join'] is not None: parts.append('JOIN = %g' % a['join'])
    return ' '.join(parts)


def log_files(run):
    """the loader's folder: real folders (APPDATA joined with backslashes on Windows), or, on Linux and macOS, files
    in the run folder named 'A\\Arrowhead\\Helldivers2\\<name>' (the backslashes are part of the name there)"""
    out = {}
    d = os.path.join(run, LOG_DIR)
    if os.path.isdir(d):
        for f in os.listdir(d): out[f] = os.path.join(d, f)
    for f in os.listdir(run):
        if f.startswith(FLAT): out[f[len(FLAT):]] = os.path.join(run, f)
    return out


def read(p): return open(p, encoding='utf-8', errors='replace').read() if p and os.path.exists(p) else ''


def main():
    a = parse_args(sys.argv[1:])
    patches, names = collect(a)
    tmp = tempfile.mkdtemp(prefix='modsim-')
    try:
        # the patch header: bytes 12-72 are engine metadata the game checks and my loader doesn't, so for the
        # simulator I make a stand-in (a real one only matters for a zip you install)
        hdr = a['header']
        if hdr is None:
            hdr = os.path.join(tmp, 'header.patch_0')
            open(hdr, 'wb').write(struct.pack('<III', h.MAGIC, 0, 0) + pack_addon.HEADER)
        b = subprocess.run([sys.executable, os.path.join(KIT, 'tools', 'build.py'), os.path.join(tmp, 'out'),
                            '--header-from', os.path.abspath(hdr)], cwd=KIT, capture_output=True, text=True)
        if b.returncode != 0: die('tools/build.py failed:\n' + b.stdout + b.stderr)
        run = os.path.join(tmp, 'run')
        os.makedirs(os.path.join(run, 'data')); os.makedirs(os.path.join(run, LOG_DIR)); os.makedirs(os.path.join(run, 'L'))
        # I deploy the loader first (patch_0), then each of your folders as the next patch, the way Arsenal does
        for ext in ('', '.gpu_resources', '.stream'):
            shutil.copy(os.path.join(tmp, 'out', 'loader', '9ba626afa44a3aa3.patch_0' + ext), os.path.join(run, 'data'))
        for n, entries in enumerate(patches, 1):
            h.write_lua_archive(os.path.join(run, 'data', '9ba626afa44a3aa3.patch_%d' % n),
                                [(h.resource_hash(r), h.lua_resource(src)) for r, src in entries],
                                open(hdr, 'rb').read()[12:72])
        # the game's settings file, for chef.setting (the loader joins APPDATA and the rest with backslashes)
        cfg = (os.path.join(run, LOG_DIR, 'user_settings.config') if os.name == 'nt'
               else os.path.join(run, FLAT + 'user_settings.config'))
        open(cfg, 'w').write(SETTINGS)
        env = dict(os.environ, APPDATA=os.path.join(run, 'A'), LOCALAPPDATA=os.path.join(run, 'L'))
        try:
            p = subprocess.run(['lua5.1', '-e', sim_settings(a), SIM], cwd=run, env=env, capture_output=True,
                               text=True, errors='replace', timeout=120 + a['seconds'] * 4)
        except FileNotFoundError:
            die('lua5.1 is not on the PATH')
        except subprocess.TimeoutExpired:
            die('the session ran over %d s without ending' % (120 + a['seconds'] * 4))
        files = log_files(run)
        log = read(files.get('chef_loader.log'))
        print('== chef_loader.log' + ('' if a['full'] else ' (the lines about %s)' % ', '.join(names)))
        for line in log.splitlines():
            if a['full'] or any(n in line for n in names):
                print(line)
        for f in sorted(files):
            if f.endswith('.log') and not f.startswith('chef_loader'):
                print('== ' + f); sys.stdout.write(read(files[f]))
        print('== chef_loader_health.txt'); sys.stdout.write(read(files.get('chef_loader_health.txt')) or '(not written)\n')
        print('== the simulated game')
        sys.stdout.write(p.stdout)
        if p.returncode != 0:
            sys.stdout.write(p.stderr)
            # the loader's breadcrumbs: a call opened (">") and never closed is where the game ended, and what the
            # loader skips from the next launch on
            trace = read(files.get('chef_loader_trace.txt')).splitlines()
            if trace:
                print('== chef_loader_trace.txt (its last lines)')
                print('\n'.join(trace[-6:]))
            print('modsim: the game would have ended here (exit %d)' % p.returncode)
        if a['keep']:
            shutil.rmtree(a['keep'], ignore_errors=True)
            shutil.copytree(run, a['keep'])
            print('modsim: the game folder is kept in ' + a['keep'])
        sys.exit(p.returncode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
