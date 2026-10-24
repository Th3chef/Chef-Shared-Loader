#!/usr/bin/env python3
"""Copies src/chef_loader/compat.lua, probe.lua, services.lua, utilities.lua, sandbox.lua and runtime.lua into src/loader.lua between their @@BEGIN/@@END lines.
The game runs boot as one script, so the loader carries them inline; these six files stay the tested originals.
  python3 tools/splice.py          -> rewrites loader.lua
  python3 tools/splice.py --check  -> exits 1 if loader.lua's copies differ from the originals"""
import os, re, sys
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADER = os.path.join(HERE, 'src', 'loader.lua')

def block(name, var):
    body = open(os.path.join(HERE, 'src', 'chef_loader', name), encoding='utf-8').read().rstrip('\n')
    assert body.endswith('return M'), name
    body = body[:-len('return M')].rstrip('\n')
    # a dotted name is a field (no new local: the loader's main chunk is at Lua 5.1's 200 locals)
    target = var if '.' in var else 'local ' + var
    return (f'-- @@BEGIN {name}@@ (copied from src/chef_loader/{name} by tools/splice.py; edit that file, not this)\n'
            f'{target} = (function()\n{body}\nreturn M\nend)()\n-- @@END {name}@@')

def spliced(src):
    for name, var in (('compat.lua', 'compat'), ('probe.lua', 'probe'), ('services.lua', 'services'),
                      ('utilities.lua', 'services.utilities'), ('sandbox.lua', 'services.sandbox'),
                      ('runtime.lua', 'services.runtime')):
        pat = re.compile(r'^-- @@BEGIN %s@@.*?^-- @@END %s@@' % (re.escape(name), re.escape(name)), re.S | re.M)
        assert len(pat.findall(src)) == 1, name
        src = pat.sub(lambda m: block(name, var), src)
    return src

src = open(LOADER, encoding='utf-8').read()
new = spliced(src)
if '--check' in sys.argv:
    sys.exit(0 if new == src else 1)
open(LOADER, 'w', encoding='utf-8').write(new)
print('spliced compat.lua, probe.lua, services.lua, utilities.lua, sandbox.lua and runtime.lua into loader.lua')
