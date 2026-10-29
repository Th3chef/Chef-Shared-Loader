"""Chef Shared Loader release art: thumbnail (1254x1254, and the 512x512 mod manager icon), gallery photo (1920x1080),
GitHub social preview (1280x640), the Nexus header (1300x372) and the AyakaMods cover (1600x1000, the title inside
the middle 1200 px the site's mod cards show). Each picture is an HTML page over a blurred shot of the game
(scene.jpg): the title in Anton, everything else in Barlow Condensed (both SIL Open Font License, from @fontsource, in
fonts/). Each picture shows both looks of my F9 menu as the loader draws them (the full screen look on the ship, the
compact panel in missions, their layout, colors and rows taken from services.lua; the game's font redrawn in Barlow
Condensed caps), with made-up mods open in them, and the loader's core features beside them. Needs Python 3 with
Pillow, and Edge or Chrome to screenshot.

How I build the set (from the repo root, the browser on the same system as the out dir):
1. python3 art/make_art.py <out dir> [version, default 1.4.0]
   writes one self-contained page per picture into <out dir>, named after the PNG it becomes (thumbnail_1254.html
   and so on; the fonts, the menu's title picture from src/menu_banner.png and the background are all embedded),
   then prints each page's screenshot size. The badge is the version's x.y; the menus are always the 1.4 menus.
   (--mod <name> is still taken and ignored: the menus always show the made-up Example Mod.)
2. Screenshot each page at its own size with a headless Edge or Chrome (both Chromium, same flags), e.g. on Windows:
     "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe" --headless=new --disable-gpu
       --hide-scrollbars --force-device-scale-factor=1 --default-background-color=00000000 --virtual-time-budget=2000
       --user-data-dir=<an empty temp folder> --window-size=1254,1254
       --screenshot=<out dir>\\thumbnail_1254.png file:///<out dir>/thumbnail_1254.html
   (google-chrome or chrome.exe take the same flags). The sizes:
     thumbnail_1254             1254,1254
     gallery_1920x1080          1920,1080
     GitHub-Social-1280x640     1280,640
     AyakaMods-Cover-1600x1000  1600,1000
     header_1300x372            1300,372
3. python3 art/make_art.py --thumb <out dir>
   makes thumbnail.png (512x512, the mod zip's icon) from thumbnail_1254.png with Pillow (LANCZOS).
"""
import base64, io, os, sys
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
VERSION = ['1.4.0']                     # (the one the art is made for, from the command line)
# the full screen look's title picture, the loader's own (src/menu_banner.png)
BANNER = base64.b64encode(open(os.path.join(HERE, '..', 'src', 'menu_banner.png'), 'rb').read()).decode()
FONTS = {'Anton': 'anton-latin-400-normal.woff2', 'BC': 'barlow-condensed-latin-600-normal.woff2',
         'BCB': 'barlow-condensed-latin-800-normal.woff2'}
TAGLINE = 'One Lua mod loader for Helldivers 2, and one F9 menu for every mod.'
# The core features: a headline, its line under it, and the short tag the small pictures use. Each one says only what
# README.md says (the section it comes from after it).
FEATURES = [
    ('One loader, every Lua mod', 'Loader addons and HD2 Lua Runtime mods, side by side', 'EVERY LUA MOD'),   # intro, Other mods' boot scripts
    ('One F9 menu for every mod', 'Two looks; keyboard, mouse or controller', 'ONE F9 MENU'),                   # Running mods > Options menu
    ('On/off for every mod', 'Off stops a mod at once and keeps it off', 'ON/OFF PER MOD'),                     # Crash guard > Switching a mod off
    ('Crash guard + hang watchdog', 'Crashing calls skipped, hung mods stopped, Crash Recovery in F9', 'CRASH GUARD'),  # Crash guard, Known limits
    ('Locked-down sandbox', "Mods can't change game settings or run console commands", 'LOCKED DOWN'),          # Security model
    ('Performance monitor', "Every mod's milliseconds a frame, live", 'PERFORMANCE MONITOR'),                  # Running mods > Performance monitor
]
# the made-up mods in the menus: the open one (its name, version and its status on the title bar) and the others in
# the full screen look's list (name, version)
MOD = ('EXAMPLE MOD', '1.0.0')
STATUS = ('RUNNING', ' - STARTED IN 3.0 MS', ', +913 KB')
OTHERS = [('RUNTIME MOD', '2.0.1'), ('YOUR MOD', '0.3.0')]
# the switch's hint, as the loader shows it on the selected switch row
SWITCH_HINT = 'OFF: STOPS NOW AND STAYS OFF. ON: STARTS AGAIN THE NEXT TIME YOU LAUNCH THE GAME.'
SIZE_HINT = 'HOW BIG THE MARKERS ARE ON SCREEN.'
# the key hints (services.lua HINTS.value: a toggle, a choice, a slider or a color selected), ARROWS MOVE optional
HINTS_VALUE = [(['ARROWS'], 'MOVE', True), (['<', '>'], 'CHANGE', False), (['DEL'], 'DEFAULT', False),
               (['F9'], 'CLOSE', False)]

# What doesn't fit goes as the loader drops it: in a .fit box, the parts marked data-d go in that order until the
# box's text fits (a version after a name, the status's memory then its time, the optional ARROWS MOVE pair)
FIT = """<script>document.fonts.ready.then(function () {
  document.querySelectorAll('.fit').forEach(function (c) {
    var ds = Array.prototype.slice.call(c.querySelectorAll('[data-d]'));
    ds.sort(function (a, b) { return a.getAttribute('data-d') - b.getAttribute('data-d'); });
    for (var i = 0; i < ds.length && c.scrollWidth > c.clientWidth + 1; i++) ds[i].remove();
  });
});</script>"""


def background(W, H):
    """the game, blurred hard and darkened toward the edges, so the menus carry the picture"""
    im = Image.open(os.path.join(HERE, 'scene.jpg')).convert('RGB')
    k = max(W / im.width, H / im.height)
    im = im.resize((int(im.width * k + 1), int(im.height * k + 1)), Image.LANCZOS)
    x0, y0 = (im.width - W) // 2, (im.height - H) // 2
    im = im.crop((x0, y0, x0 + W, y0 + H)).filter(ImageFilter.GaussianBlur(max(W, H) / 90))
    im = ImageEnhance.Color(ImageEnhance.Brightness(im).enhance(0.36)).enhance(0.55).convert('RGBA')
    vig = Image.new('L', (W, H), 0)
    ImageDraw.Draw(vig).ellipse((-W * 0.2, -H * 0.25, W * 1.2, H * 1.25), fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(min(W, H) / 4))
    dark = Image.new('RGBA', (W, H), (0, 0, 0, 255)); dark.putalpha(vig.point(lambda p: int((255 - p) * 0.85)))
    im.alpha_composite(dark)
    return im.convert('RGB')


def b64(img_or_name):
    if isinstance(img_or_name, str):
        return base64.b64encode(open(os.path.join(HERE, 'fonts', img_or_name), 'rb').read()).decode()
    buf = io.BytesIO(); img_or_name.save(buf, 'JPEG', quality=90); return base64.b64encode(buf.getvalue()).decode()


# Colors as they show on screen (services.lua nav.pal through nav.TONE): the menus' white, the state green, gray
# (values off, versions, arrows, pane titles), dim (the full look's versions), the subheadings' gold, the hint gray,
# the lit row's olive band, the dark panels and the rule.
CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
:root { --y:#ffe710; --ink:#111; --wh:#e9e4d8; --gr:#7eaa6c; --gy:#929a93; --dm:#7e857f; --sub:#afa073; --hi:#a3aaa4;
  --olive:#4e4c1e; --pan:#282a28; --scr:#1e201f; --rule:#3d413d; --line:rgba(255,231,16,.32); }
body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; background:#0b0c0b; position:relative; }
.bg { position:absolute; inset:0; background:url(data:image/jpeg;base64,%(bg)s) no-repeat; background-size:100%% 100%%; }
/* a faint grid and a warm light behind the menus */
.grid { position:absolute; inset:0; pointer-events:none;
  background-image:linear-gradient(rgba(255,231,16,.045) 1px, transparent 1px), linear-gradient(90deg, rgba(255,231,16,.045) 1px, transparent 1px);
  background-size:%(g)dpx %(g)dpx; -webkit-mask-image:radial-gradient(ellipse at 62%% 45%%, #000 10%%, transparent 70%%); }
.glow { position:absolute; border-radius:50%%; pointer-events:none;
  background:radial-gradient(closest-side, rgba(255,205,40,.22), rgba(255,205,40,.07) 55%%, rgba(255,205,40,0)); }
.title { font-family:'Anton'; color:var(--y); letter-spacing:0.015em; line-height:0.94; text-transform:uppercase;
  text-shadow:0 0.035em 0 #000, 0 0 0.1em rgba(0,0,0,.9), 0 0 0.45em rgba(255,214,40,.28); white-space:nowrap; }
.badge { display:inline-block; font-family:'BCB'; text-transform:none; background:var(--y); color:var(--ink); padding:0.02em 0.3em 0;
  line-height:1.05; letter-spacing:0.03em; box-shadow:0 0.08em 0.25em rgba(0,0,0,.7), 0 0 0.6em rgba(255,231,16,.5); }
.tag { font-family:'BC'; color:#efe8d8; line-height:1.18;
  text-shadow:0 0.05em 0.05em #000, 0 0 0.3em rgba(0,0,0,.95); }
/* the features: each with a lit row's yellow edge */
.feats { position:absolute; font-family:'BCB'; }
.feats .f { position:relative; padding:0.04em 0 0.06em 0.75em; margin-bottom:0.62em; }
.feats .f::before { content:''; position:absolute; left:0; top:0.12em; bottom:0.1em; width:0.16em; background:var(--y);
  box-shadow:0 0 0.45em rgba(255,231,16,.7); }
.feats .f b { display:block; font-weight:normal; color:#f6f1e4; text-transform:uppercase; letter-spacing:0.025em;
  line-height:1.05; text-shadow:0 0.05em 0.1em #000; }
.feats .f span { display:block; font-family:'BC'; font-size:0.66em; color:#c4bfb1; letter-spacing:0.01em; margin-top:0.12em;
  text-shadow:0 0.05em 0.1em #000; }
.chips { position:absolute; display:flex; flex-wrap:wrap; gap:0.4em; font-family:'BCB'; }
.chips span { background:rgba(14,15,14,.88); color:var(--y); padding:0.1em 0.5em 0.04em 0.6em; letter-spacing:0.05em;
  border-left:0.2em solid var(--y); box-shadow:0 0.1em 0.3em rgba(0,0,0,.6), 0 0 0.5em rgba(255,231,16,.18); white-space:nowrap; }
/* a look's label: a yellow tab */
.lab { position:absolute; display:flex; align-items:baseline; gap:0.45em; font-family:'BCB'; color:var(--ink);
  background:var(--y); padding:0.1em 0.5em 0.04em; letter-spacing:0.06em; white-space:nowrap; z-index:5;
  box-shadow:0 0 0.9em rgba(255,231,16,.4), 0 0.15em 0.4em rgba(0,0,0,.7); }
.lab small { font-family:'BC'; font-size:0.66em; letter-spacing:0.05em; color:rgba(17,17,17,.72); }

/* both looks: the game's font in caps */
.fs, .cp, .pm { position:absolute; font-family:'BC'; text-transform:uppercase; letter-spacing:0.045em; color:var(--wh);
  line-height:1; white-space:nowrap; }
.fit { overflow:hidden; } [data-d] { white-space:pre; }
.g { color:var(--gy); } .d { color:var(--dm); } .gr { color:var(--gr); } .yl { color:var(--y); } .hi { color:var(--hi); }

/* the full screen look: the header with the title picture and the loader's name, a yellow rule, the mods on the left
   and the open mod's rows on the right in two panes, the hints along the bottom */
.fs { background:var(--scr); display:flex; flex-direction:column; overflow:hidden;
  box-shadow:0 1.6em 3.2em rgba(0,0,0,.8), 0 0 0 1px rgba(0,0,0,.9), 0 0 3em rgba(255,214,40,.12); }
.fs .hd { flex:0 0 auto; height:3.1em; background:var(--pan); display:flex; align-items:center; justify-content:space-between;
  padding:0.3em 1.25em 0; }
.fs .hd img { height:1.75em; image-rendering:pixelated; display:block; }
.fs .yr { flex:0 0 auto; height:0.14em; background:var(--y); box-shadow:0 0 0.6em rgba(255,231,16,.35); }
.fs .bd { display:flex; gap:1.1em; padding:0.75em 1.25em 0.6em; }
.fs .pn { background:var(--pan); border:1px solid var(--line); position:relative; overflow:hidden; padding-bottom:0.5em; }
.fs .pt { height:2.15em; display:flex; align-items:center; margin:0 0.45em 0.25em; padding:0.15em 0.15em 0;
  border-bottom:1px solid var(--line); color:var(--gy); }
.fs .pt .s { margin-left:auto; padding-left:1em; }
.fs .r { position:relative; height:1.95em; display:flex; align-items:center; padding-left:0.9em; }
.fs .r.i { padding-left:2.7em; }
.fs .r.h { padding-left:0.6em; color:var(--y); }
.fs .r.sub { padding-left:2.4em; color:var(--sub); }
.fs .r.t { background:linear-gradient(rgba(232,232,226,.035), rgba(232,232,226,.035)) no-repeat; background-size:calc(100%% - 0.6em) 100%%; }
.fs .r.lit { background:var(--olive); }
.fs .r.lit::before, .fs .r.edge::before { content:''; position:absolute; left:0; top:0; bottom:0; width:0.3em; background:var(--y); }
.fs .r.div::after { content:''; position:absolute; left:0.6em; right:0.6em; bottom:0; height:1px; background:rgba(255,231,16,.35); }
.fs .r .l { flex:0 1 auto; overflow:hidden; }
.fs .sep { height:0.75em; display:flex; align-items:center; padding:0 0.9em; }
.fs .sep i { display:block; width:calc(100%% - 1em); height:1px; background:var(--rule); }
/* the value column at 55%% of the row; a choice's < just left of it, every value's text after it */
.fs .v { position:absolute; left:calc(0.9em + 0.55 * (100%% - 1.8em)); top:0; bottom:0; display:flex; align-items:center; }
.fs .a { color:var(--gy); } .fs .lit .a { color:var(--y); }
.fs .a.o { visibility:hidden; }
.fs .v .al { margin-right:0.55em; } .fs .v .ar { margin-left:0.55em; }
.fs .sl { position:absolute; right:calc(100%% + 0.9em); width:6.2em; height:0.15em; top:calc(50%% - 0.075em); background:var(--rule); }
.fs .sl i { position:absolute; left:0; top:0; bottom:0; background:var(--gr); }
.fs .sl b { position:absolute; top:-0.15em; width:0.45em; height:0.45em; margin-left:-0.225em; background:var(--gr); }
.fs .lit .sl i, .fs .lit .sl b { background:var(--y); }
.fs .sw { position:absolute; right:calc(100%% + 0.3em); width:1.35em; height:1.35em; top:0.3em; }
.fs .ft { flex:0 0 auto; border-top:1px solid var(--line); padding:0.55em 1.25em 0.85em; }
.fs .ft .note { font-size:0.8em; color:var(--hi); height:1.4em; }

/* the compact panel: a dark panel in a thin yellow frame, the yellow title bar, the rows, the hints under a thin line */
.cp { background:rgba(30,32,31,.97); border:0.09em solid var(--y);
  box-shadow:0 1.4em 3em rgba(0,0,0,.85), 0 0 2.2em rgba(255,231,16,.28), 0 0 0 1px rgba(0,0,0,.8); }
.cp .bar { background:var(--y); color:var(--ink); height:2.05em; display:flex; align-items:center; padding:0.1em 1.05em 0; }
.cp .bar .st { margin-left:auto; padding-left:0.9em; color:rgba(17,17,17,.74); display:flex; align-items:center; }
.cp .bar .sq { display:inline-block; width:0.62em; height:0.62em; background:var(--ink); padding:0.09em; margin-right:0.45em; margin-top:-0.1em; }
.cp .bar .sq i { display:block; width:100%%; height:100%%; background:var(--gr); }
.cp .bar .k { margin-left:0.9em; }
.cp .rows { position:relative; padding-top:0.15em; }
.cp .r { position:relative; height:1.8em; display:flex; align-items:center; padding:0 1.05em 0 1.35em; }
.cp .r.i { padding-left:3.15em; }
.cp .r.h { padding-left:1.05em; color:var(--y); }
.cp .r.sub { padding-left:2.85em; color:var(--sub); }
.cp .r.lit { background:var(--olive); }
.cp .r.lit::before { content:''; position:absolute; left:0; top:0; bottom:0; width:0.3em; background:var(--y); }
.cp .r .l { flex:1 1 auto; min-width:0; overflow:hidden; }
.cp .r .v { flex:0 0 auto; margin-left:0.9em; display:flex; align-items:center; }
.cp .r .v .a { color:var(--y); }
.cp .r .v .al { margin-right:0.45em; } .cp .r .v .ar { margin-left:0.45em; }
.cp .r .v .sw { display:inline-block; width:1.2em; height:1.2em; margin-left:0.45em; }
.cp .sep { height:0.75em; display:flex; align-items:center; padding:0 1.05em 0 1.35em; }
.cp .sep i { display:block; flex:1; height:1px; background:var(--rule); }
.cp .sb { position:absolute; right:0.12em; width:0.15em; }
.cp .sb::before { content:''; position:absolute; left:50%%; top:0; bottom:0; width:1px; background:var(--rule); }
.cp .sb i { position:absolute; left:0; right:0; background:rgba(255,231,16,.6); }
.cp .ft { border-top:1px solid rgba(255,231,16,.27); padding:0.4em 1.05em 0.3em; }
.cp .ft .note { color:var(--hi); line-height:1.35em; white-space:normal; }
/* a hint line: each key a light chip in ink, its word close after it, the next pair further off */
.keys { display:flex; align-items:center; height:1.8em; }
.keys .p { display:flex; align-items:center; margin-right:1.25em; flex:0 0 auto; }
.keys b { font-weight:normal; background:var(--wh); color:var(--ink); padding:0.06em 0.3em 0; height:1.3em; min-width:1.2em;
  display:inline-flex; align-items:center; justify-content:center; margin-right:0.28em; }
.keys .w { margin-left:0.3em; }

/* the performance monitor: a dark panel in a thin yellow frame with a yellow bar on top */
.pm { background:rgba(30,32,31,.96); border:1px solid rgba(255,231,16,.6); border-top:0.3em solid var(--y); padding:0.15em 0 0.45em;
  box-shadow:0 1.2em 2.6em rgba(0,0,0,.8), 0 0 1.8em rgba(255,231,16,.18); }
.pm .tt { color:var(--y); padding:0.4em 0.8em 0.25em; }
.pm .r { display:flex; align-items:center; height:1.6em; padding:0 0.8em; color:#dcded8; }
.pm .r .n { flex:1 1 auto; }
.pm .r .c { width:3.7em; text-align:right; }
.pm .r.hd { color:#96ffb4; } .pm .r.al { color:#fff; } .pm .r.dm { color:var(--gy); }
"""


def keys(segs, size=None):
    """a hint line (services.lua hint_line): keys as chips, the word after them; the optional pair goes first"""
    out = []
    for ks, word, opt in segs:
        out.append('<span class="p"%s>%s<span class="w">%s</span></span>' % (
            ' data-d="1"' if opt else '', ''.join('<b>%s</b>' % esc(k) for k in ks), word))
    return '<div class="keys fit">%s</div>' % ''.join(out)


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def ver(v, cls):
    """a version after a name, dropped whole when it doesn't fit (as nav.ver_after does)"""
    return '<span class="%s" data-d="1"> %s</span>' % (cls, v)


def status(dark):
    """the open mod's status: the state word, then its start's time and memory (memory dropped first, then the time)"""
    w, t, m = STATUS
    if dark:      # (the compact bar: all in the bar's dim ink, the state's square before it)
        return ('<span class="st fit"><span class="sq"><i></i></span><span>%s</span><span data-d="2">%s</span>'
                '<span data-d="1">%s</span></span>') % (w, t, m)
    return '<span class="s"><span class="gr">%s</span><span data-d="2">%s</span><span data-d="1">%s</span></span>' % (w, t, m)


# ---- the full screen look ----
# The right pane's lines, as the loader lays out a mod's entry: (kind, label, value, extra). Kinds: back, switch, sep,
# fold (open: '-'), foldc (closed: its count, '+'), sub, row (toggle, choice, slider, color; i: indented under a sub).
FULL_LINES = [
    ('back', '&lt; BACK', None, None),
    ('switch', MOD[0], 'ON', None),
    ('sep', None, None, None),
    ('fold', 'MARKERS', None, None),
    ('row', 'SHOW MARKERS', 'ON', 'toggle'),
    ('row', 'MARKER SIZE', 'MEDIUM', 'choice'),
    ('sub', 'PLACEMENT', None, None),
    ('rowi', 'MOVE SIDEWAYS', '-60', ('slider', 0.35)),
    ('rowi', 'OPACITY (%)', '80', ('slider', 0.78)),
    ('rowi', 'MARKER COLOR', 'FFE710', ('color', '#ffe710')),
    ('rowi', 'SHOW ON MAP', 'OFF', 'toggle'),
    ('foldc', 'SOUNDS', '(3)', None),
    ('foldc', 'LOOT', '(5)', None),
]


def full_rows(pick, lit):
    """the right pane's rows (pick: which of FULL_LINES to show; lit: the selected one)"""
    out, tk = [], 0
    for i in pick:
        kind, label, val, ex = FULL_LINES[i]
        on = i == lit
        if kind == 'back':
            out.append('<div class="r yl%s">%s</div>' % (' lit' if on else '', label))
        elif kind == 'sep':
            out.append('<div class="sep"><i></i></div>')
        elif kind == 'fold':
            out.append('<div class="r h"><span class="l">%s</span><span class="v"><span class="a al o">&lt;</span>-</span></div>' % label)
        elif kind == 'foldc':
            out.append('<div class="r h"><span class="l">%s <span class="g">%s</span></span>'
                       '<span class="v"><span class="a al o">&lt;</span>+</span></div>' % (label, val))
        elif kind == 'sub':
            out.append('<div class="r sub">%s</div>' % label)
        else:
            tk += 1
            cls = ['r'] + (['i'] if kind == 'rowi' else []) + (['t'] if tk % 2 == 0 else []) + (['lit'] if on else [])
            vcls = 'g' if val == 'OFF' else 'gr'
            if kind == 'switch':
                lab = '<span class="l fit" style="max-width:calc(0.55 * (100%% - 1.8em) - 0.6em)">%s%s</span>' % (
                    label, ver(MOD[1], 'hi' if on else 'd'))
            else:
                lab = '<span class="l">%s</span>' % label
            t = ex[0] if isinstance(ex, tuple) else ex
            if t in ('choice', 'slider', 'color'):
                pre = ''
                if t == 'slider':
                    f = ex[1]
                    pre = '<span class="sl"><i style="width:%.0f%%"></i><b style="left:%.0f%%"></b></span>' % (f * 100, f * 100)
                if t == 'color':
                    pre = '<span class="sw" style="background:%s"></span>' % ex[1]
                v = '<span class="v">%s<span class="a al">&lt;</span><span class="%s">%s</span><span class="a ar">&gt;</span></span>' % (
                    pre, vcls, val)
            else:
                v = '<span class="v"><span class="a al o">&lt;</span><span class="%s">%s</span></span>' % (vcls, val)
            out.append('<div class="%s">%s%s</div>' % (' '.join(cls), lab, v))
    return ''.join(out)


def fullview(x, y, w, size, pick=None, lit=1, note=True, mods=4, extra='', stat=True):
    """the full screen look at x, y, w wide, its text size px a letter (the box as tall as its rows make it)"""
    pick = list(range(len(FULL_LINES))) if pick is None else pick
    vtag = VERSION[0]
    lst = [('CHEF SHARED LOADER', vtag, 'div'), (MOD[0], MOD[1], 'edge')] + [(n, v, '') for n, v in OTHERS]
    left = ''.join('<div class="r fit %s"><span class="%s">%s</span>%s</div>' % (
        c, 'yl' if c == 'edge' else 'g', n, ver(v, 'd')) for n, v, c in lst[:mods])
    hint = '<div class="note fit">%s</div>' % SWITCH_HINT if note else ''
    return ('<div class="fs" style="left:%dpx;top:%dpx;width:%dpx;font-size:%.2fpx%s">'
            '<div class="hd"><img src="data:image/png;base64,%s"><span class="g">CHEF SHARED LOADER %s</span></div>'
            '<div class="yr"></div>'
            '<div class="bd"><div class="pn" style="flex:0 0 27%%"><div class="pt"><span>MODS</span><span class="s">%d</span></div>%s</div>'
            '<div class="pn" style="flex:1 1 auto;min-width:0"><div class="pt fit"><span>%s</span>%s</div>%s</div></div>'
            '<div class="ft">%s%s</div></div>') % (
        x, y, w, size, extra, BANNER, vtag, len(lst), left, MOD[0], status(False) if stat else '', full_rows(pick, lit), hint,
        keys(HINTS_VALUE))


# ---- the compact panel ----
CP_LINES = [
    ('back', '&lt; BACK', None, None),
    ('switch', MOD[0], 'ON', None),
    ('sep', None, None, None),
    ('fold', 'MARKERS', None, None),
    ('row', 'SHOW MARKERS', 'ON', None),
    ('row', 'MARKER SIZE', 'MEDIUM', 'choice'),
    ('sub', 'PLACEMENT', None, None),
    ('rowi', 'MOVE SIDEWAYS', '-60', 'slider'),
    ('rowi', 'OPACITY (%)', '80', 'slider'),
    ('rowi', 'MARKER COLOR', 'FFE710', ('color', '#ffe710')),
    ('rowi', 'SHOW ON MAP', 'OFF', None),
    ('foldc', 'SOUNDS', '(3)', None),
    ('fold', 'LOOT', None, None),
    ('row', 'SHOW SAMPLES', 'ON', None),
    ('row', 'SHOW MEDALS', 'OFF', None),
]


def compactview(x, y, w, size, pick=None, lit=5, note=SIZE_HINT, more=True, extra=''):
    """the compact panel at x, y, w wide, its text size px a letter; more: a scroll track (more lines than room)"""
    pick = list(range(len(CP_LINES))) if pick is None else pick
    rows = []
    for i in pick:
        kind, label, val, ex = CP_LINES[i]
        on = i == lit
        if kind == 'back':
            rows.append('<div class="r%s"><span class="%s">%s</span></div>' % (' lit' if on else '', 'w' if on else 'yl', label))
        elif kind == 'sep':
            rows.append('<div class="sep"><i></i></div>')
        elif kind == 'fold':
            rows.append('<div class="r h"><span class="l">%s</span><span class="v">-</span></div>' % label)
        elif kind == 'foldc':
            rows.append('<div class="r h"><span class="l">%s <span class="g">%s</span></span><span class="v">+</span></div>' % (label, val))
        elif kind == 'sub':
            rows.append('<div class="r sub">%s</div>' % label)
        else:
            cls = 'r' + (' i' if kind == 'rowi' else '') + (' lit' if on else '')
            lab = label + (ver(MOD[1], 'hi' if on else 'g') if kind == 'switch' else '')
            vc = 'g' if val == 'OFF' else 'gr'
            # (a choice or a slider selected: < value > in yellow arrows; a color: its swatch after the value)
            if on and ex in ('choice', 'slider'):
                v = '<span class="a al">&lt;</span><span class="%s">%s</span><span class="a ar">&gt;</span>' % (vc, val)
            else:
                v = '<span class="%s">%s</span>' % (vc, val)
            if isinstance(ex, tuple):
                v += '<span class="sw" style="background:%s"></span>' % ex[1]
            rows.append('<div class="%s"><span class="l fit">%s</span><span class="v">%s</span></div>' % (cls, lab, v))
    sb = ''
    if more:
        # (the thumb over the first lines in view, the track down the rows' height)
        sb = '<span class="sb" style="top:0.3em;bottom:0.3em"><i style="top:0;height:62%"></i></span>'
    nt = '<div class="note">%s</div>' % note if note else ''
    return ('<div class="cp" style="left:%dpx;top:%dpx;width:%dpx;font-size:%.2fpx%s">'
            '<div class="bar fit"><span>%s</span>%s<span class="k">F9</span></div>'
            '<div class="rows">%s%s</div><div class="ft">%s%s</div></div>') % (
        x, y, w, size, extra, MOD[0], status(True), ''.join(rows), sb, nt, keys(HINTS_VALUE))


def perf(x, y, w, size, extra=''):
    """the performance monitor (utilities.lua): the frame, all mods, each mod's ms, share and worst call, the loader"""
    rows = [('FRAME 16.7 MS  60 FPS', ['MS', 'SHARE', 'WORST'], 'hd'), ('ALL MODS', ['0.92', '5.5%', ''], 'al'),
            (MOD[0], ['0.61', '3.7%', '2.4'], ''), (OTHERS[0][0], ['0.24', '1.4%', '0.9'], ''),
            (OTHERS[1][0], ['0.02', '0.1%', '0.3'], ''), ('LOADER', ['0.05', '0.3%', ''], ''),
            ('THIS MONITOR', ['0.01', '0.1%', ''], 'dm')]
    body = ''.join('<div class="r %s"><span class="n">%s</span>%s</div>' % (
        c, n, ''.join('<span class="c">%s</span>' % v for v in vs)) for n, vs, c in rows)
    return ('<div class="pm" style="left:%dpx;top:%dpx;width:%dpx;font-size:%.2fpx%s"><div class="tt">PERFORMANCE MONITOR</div>'
            '%s</div>') % (x, y, w, size, extra, body)


def label(x, y, size, text, small=''):
    return '<div class="lab" style="left:%dpx;top:%dpx;font-size:%dpx">%s%s</div>' % (
        x, y, size, text, '<small>%s</small>' % small if small else '')


def glow(x, y, rx, ry=None):
    ry = ry or rx
    return '<div class="glow" style="left:%dpx;top:%dpx;width:%dpx;height:%dpx"></div>' % (x - rx, y - ry, 2 * rx, 2 * ry)


def feats(x, y, w, size, which=None, sub=True):
    which = range(len(FEATURES)) if which is None else which
    items = ''.join('<div class="f"><b>%s</b>%s</div>' % (FEATURES[i][0], '<span>%s</span>' % FEATURES[i][1] if sub else '')
                    for i in which)
    return '<div class="feats" style="left:%dpx;top:%dpx;width:%dpx;font-size:%dpx">%s</div>' % (x, y, w, size, items)


def chips(x, y, w, size, which, center=False):
    return '<div class="chips" style="left:%dpx;top:%dpx;width:%dpx;font-size:%dpx%s">%s</div>' % (
        x, y, w, size, ';justify-content:center' if center else '', ''.join('<span>%s</span>' % FEATURES[i][2] for i in which))


def page(W, H, body, grid=40):
    """one picture as a self-contained page, exactly W x H, fonts and background embedded"""
    fonts = '\n'.join("@font-face{font-family:'%s';src:url(data:font/woff2;base64,%s) format('woff2');}" % (n, b64(f))
                      for n, f in FONTS.items())
    return ('<!doctype html><html><head><meta charset="utf-8"><style>%s\n%s</style></head><body><div class="bg"></div>'
            '<div class="grid"></div>%s%s</body></html>') % (
        fonts, CSS % {'W': W, 'H': H, 'bg': b64(background(W, H)), 'g': grid}, body, FIT)


def thumb(out):
    """the 512x512 icon from the big square screenshot"""
    Image.open(os.path.join(out, 'thumbnail_1254.png')).convert('RGB').resize((512, 512), Image.LANCZOS).save(
        os.path.join(out, 'thumbnail.png'))
    print('thumbnail.png')


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--thumb':
        return thumb(sys.argv[2])
    args = sys.argv[1:]
    if '--mod' in args:
        i = args.index('--mod'); del args[i:i + 2]
    out = args[0]
    ver_ = args[1] if len(args) > 1 else '1.4.0'
    VERSION[0] = ver_
    badge = 'v' + '.'.join(ver_.split('.')[:2])
    os.makedirs(out, exist_ok=True)
    b = badge

    def title2(x, y, size, bsize, tag=None, tsize=0, tw=0):
        """the title on two lines, the badge after LOADER, the tagline under it"""
        t = ('<div style="position:absolute;left:%dpx;top:%dpx"><div class="title" style="font-size:%dpx">Chef Shared<br>Loader'
             ' <span class="badge" style="font-size:%dpx;vertical-align:%dpx;margin-left:%dpx">%s</span></div>') % (
            x, y, size, bsize, round(size * 0.28), round(size * 0.1), b)
        if tag:
            t += '<div class="tag" style="font-size:%dpx;width:%dpx;margin-top:%dpx">%s</div>' % (tsize, tw, round(tsize * 0.7), tag)
        return t + '</div>'

    def title1(x, y, size, bsize, center=False, w=0):
        """the title on one line with the badge after it"""
        return ('<div style="position:absolute;left:%dpx;top:%dpx;%s"><span class="title" style="font-size:%dpx">Chef Shared Loader</span>'
                '<span class="badge" style="font-size:%dpx;vertical-align:%dpx;margin-left:%dpx">%s</span></div>') % (
            x, y, 'width:%dpx;text-align:center' % w if center else '', size, bsize, round(size * 0.3), round(size * 0.14), b)

    # (the lines each picture's menus show: a few of each kind, the parts that make each look its own)
    FP = [0, 1, 2, 3, 5, 6, 7, 8, 10]            # full: back, the switch (lit), rule, heading, choice, sub, 2 sliders, off
    CPK = [0, 1, 2, 3, 4, 5, 6, 7, 10, 11]       # compact: back, switch, rule, heading, on, choice (lit), sub, slider, off, fold
    jobs = [
        # 16:9: the title, the tagline and the six features on the left; the full screen look behind on the right,
        # the compact panel in front of its right edge, the monitor under the full look
        ('gallery_1920x1080.png', 1920, 1080,
         glow(1250, 470, 760, 520)
         + title2(70, 64, 108, 46, TAGLINE, 31, 520)
         + feats(72, 430, 560, 33)
         + label(650, 50, 28, 'FULLSCREEN', 'ON THE SHIP')
         + fullview(650, 92, 960, 18, pick=FP)
         + label(1392, 300, 28, 'COMPACT', 'IN MISSIONS')
         + compactview(1392, 342, 480, 16, pick=CPK)
         + perf(880, 690, 480, 16)),
        # square (the Nexus tile and the 512 icon): the title and tagline across the top, the full screen look under
        # them, the compact panel in front of its lower right corner, the six features as tags beside it
        ('thumbnail_1254.png', 1254, 1254,
         glow(560, 560, 640, 460)
         + title1(0, 34, 124, 52, center=True, w=1254)
         + '<div class="tag" style="position:absolute;left:0;top:184px;width:1254px;text-align:center;font-size:34px">%s</div>' % TAGLINE
         + label(44, 262, 34, 'FULLSCREEN')
         + fullview(44, 310, 960, 19.5, pick=FP, note=False)
         + label(764, 676, 34, 'COMPACT')
         + compactview(764, 724, 450, 15, pick=CPK, note=None)
         + chips(44, 880, 690, 38, range(6))),
        # GitHub (1280x640, 40 px kept clear all round): the title and four features on the left, the two looks right,
        # the monitor under the full look
        ('GitHub-Social-1280x640.png', 1280, 640,
         glow(880, 300, 480, 340)
         + title2(44, 44, 74, 32, TAGLINE, 22, 400)
         + feats(46, 318, 420, 25, which=[0, 1, 3, 4], sub=False)
         + label(486, 42, 19, 'FULLSCREEN', 'ON THE SHIP')
         + fullview(486, 72, 590, 10.9, pick=FP, note=False)
         + label(962, 196, 19, 'COMPACT', 'IN MISSIONS')
         + compactview(962, 225, 278, 9.3, pick=CPK, note=None)
         + perf(520, 420, 300, 10)),
        # 1.6:1, everything inside the middle 1200 px (the card crops the sides): the text left, the full screen look
        # right, the compact panel in front of its lower right corner, the monitor beside it
        ('AyakaMods-Cover-1600x1000.png', 1600, 1000,
         glow(1000, 470, 560, 420)
         + title2(212, 118, 92, 40, TAGLINE, 27, 430)
         + feats(214, 440, 470, 27)
         + label(700, 118, 24, 'FULLSCREEN', 'ON THE SHIP')
         + fullview(700, 154, 690, 13.2, pick=FP[:-1])
         + label(1104, 468, 22, 'COMPACT', 'IN MISSIONS')
         + compactview(1104, 502, 296, 10.2, pick=CPK)
         + perf(726, 640, 350, 11.6)),
        # the Nexus header (1300x372): Nexus fades the lower half and puts the page's title, stats and buttons over
        # it, and its Manage button sits top right, so everything stays in the upper half, clear of that corner
        ('header_1300x372.png', 1300, 372,
         glow(880, 110, 420, 200)
         + title1(30, 26, 58, 24)
         + '<div class="tag" style="position:absolute;left:32px;top:104px;width:540px;font-size:20px">%s</div>' % TAGLINE
         + chips(32, 144, 570, 14, [0, 1, 2, 3, 4])
         + label(596, 4, 13, 'FULLSCREEN', 'ON THE SHIP')
         + fullview(596, 24, 460, 8.6, pick=[1, 3, 5, 7], note=False, stat=False)
         + label(1000, 50, 13, 'COMPACT', 'IN MISSIONS')
         + compactview(1000, 70, 222, 7.4, pick=[1, 3, 5, 6, 7], note=None, more=False)),
    ]
    for name, W, H, body in jobs:
        open(os.path.join(out, name[:-4] + '.html'), 'wb').write(page(W, H, body).encode('utf-8'))
        print('%s.html  screenshot at --window-size=%d,%d as %s' % (name[:-4], W, H, name))


if __name__ == '__main__':
    main()
