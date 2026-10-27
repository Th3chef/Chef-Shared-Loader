"""Chef Shared Loader release art: thumbnail (1254x1254, and the 512x512 mod manager icon), gallery photo (1920x1080),
GitHub social preview (1280x640), the Nexus header (1300x372) and the AyakaMods cover (1600x1000, the title inside
the middle the site's mod cards show). Each picture is an HTML page over a blurred shot of the game (scene.jpg): the
title and badge in Anton and Barlow Condensed, the log and the options menu in JetBrains Mono (all SIL Open Font
License, from @fontsource, in fonts/). The menu and the monitor follow the loader's own (its pixel font redrawn in a
mono face), with a made-up Example Mod open in the menu. Needs Python 3 with Pillow, and Edge or Chrome to screenshot.

How I build the set (from the repo root, the browser on the same system as the out dir):
1. python3 art/make_art.py <out dir> [version, default 1.3.0]
   writes one self-contained page per picture into <out dir>, named after the PNG it becomes (thumbnail_1254.html
   and so on; the fonts, the menu's title picture from src/menu_banner.png and the background are all embedded),
   then prints each page's screenshot size.
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
VERSION = ['1.3.0']                     # (the one the art is made for, from the command line)
# the full screen menu's title picture, the loader's own (src/menu_banner.png)
BANNER = base64.b64encode(open(os.path.join(HERE, '..', 'src', 'menu_banner.png'), 'rb').read()).decode()
FONTS = {'Anton': 'anton-latin-400-normal.woff2', 'Barlow Condensed': 'barlow-condensed-latin-600-normal.woff2',
         'Barlow Condensed B': 'barlow-condensed-latin-800-normal.woff2', 'Mono': 'jetbrains-mono-latin-500-normal.woff2',
         'Mono B': 'jetbrains-mono-latin-700-normal.woff2'}
TAGLINE = 'One Lua loader for every Helldivers 2 mod, HD2 Lua Runtime mods too: side by side, crash-guarded and locked down. F9 opens one options menu for all of them.'
FEATURES = ['FULL SCREEN F9 MENU', 'CONTROLLER + MOUSE', 'OVER THE GAME UI', 'LANGUAGE FILES', 'PERFORMANCE MONITOR', 'CRASH GUARD', 'LOCKED DOWN', 'WORKS BESIDE OTHER LOADERS', 'ANY AUTHOR']


def background(W, H):
    """the game, blurred and darkened toward the edges (dark enough for the windows to stand out)"""
    im = Image.open(os.path.join(HERE, 'scene.jpg')).convert('RGB')
    k = max(W / im.width, H / im.height)
    im = im.resize((int(im.width * k + 1), int(im.height * k + 1)), Image.LANCZOS)
    x0, y0 = (im.width - W) // 2, (im.height - H) // 2
    im = im.crop((x0, y0, x0 + W, y0 + H)).filter(ImageFilter.GaussianBlur(max(W, H) / 140))
    im = ImageEnhance.Color(ImageEnhance.Brightness(im).enhance(0.5)).enhance(0.7).convert('RGBA')
    vig = Image.new('L', (W, H), 0)
    ImageDraw.Draw(vig).ellipse((-W * 0.25, -H * 0.3, W * 1.25, H * 1.3), fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(min(W, H) / 5))
    dark = Image.new('RGBA', (W, H), (0, 0, 0, 255)); dark.putalpha(vig.point(lambda p: int((255 - p) * 0.8)))
    im.alpha_composite(dark)
    return im


def b64(img_or_name):
    if isinstance(img_or_name, str):
        return base64.b64encode(open(os.path.join(HERE, 'fonts', img_or_name), 'rb').read()).decode()
    buf = io.BytesIO(); img_or_name.save(buf, 'PNG'); return base64.b64encode(buf.getvalue()).decode()


CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; background:#000; position:relative; }
.bg { position:absolute; inset:0; background:url(data:image/png;base64,%(bg)s) no-repeat; background-size:100%% 100%%; }
.title { font-family:'Anton'; color:#ffe710; letter-spacing:0.02em; line-height:0.95; text-transform:uppercase;
  text-shadow: 0 0.04em 0 #000, 0 0 0.12em rgba(0,0,0,.9), 0 0 0.35em rgba(0,0,0,.6); }
.badge { display:inline-block; font-family:'Barlow Condensed B'; background:#ffe710; color:#111; padding:0.04em 0.32em 0.02em;
  border:0.06em solid #111; box-shadow:0 0.08em 0.25em rgba(0,0,0,.6); letter-spacing:0.03em; }
.tag { font-family:'Barlow Condensed'; color:#f6ead2; line-height:1.15;
  text-shadow: 0 0.05em 0.05em #000, 0 0 0.3em rgba(0,0,0,.95), 0 0 0.6em rgba(0,0,0,.7); }
.feat { font-family:'Barlow Condensed B'; color:#111; display:flex; flex-wrap:wrap; gap:0.35em; }
.feat span { background:rgba(255,231,16,.95); padding:0.06em 0.4em 0.02em; border:0.05em solid #111; letter-spacing:0.04em;
  box-shadow:0 0.06em 0.2em rgba(0,0,0,.55); }
.plate { position:absolute; background:linear-gradient(rgba(10,9,7,.84),rgba(10,9,7,.76)); border:3px solid #ffe710;
  box-shadow:0 8px 30px rgba(0,0,0,.6); }
/* the performance monitor */
.perf { position:absolute; background:rgba(8,12,10,.93); border:2px solid rgba(255,231,16,.6); border-top:0.25em solid #ffe710;
  border-radius:0.3em; box-shadow:0 0.5em 1.6em rgba(0,0,0,.7); font-family:'Mono'; color:#dcdcdc; padding-bottom:0.45em; }
.perf .ph { font-family:'Mono B'; color:#ffe710; padding:0.45em 0.75em 0.3em; letter-spacing:0.03em; }
.perf .row { display:flex; justify-content:space-between; gap:1.2em; padding:0.14em 0.75em; white-space:pre; }
.perf .row.hd { color:#96ffb4; } .perf .row.w { color:#fff; font-family:'Mono B'; }
/* the full screen menu (1.2.0): the title picture, the mods on the left, the open mod's options on the right, the
   hints along the bottom */
.fs { position:absolute; background:#090b0a; border:2px solid rgba(255,231,16,.55); border-radius:0.25em;
  box-shadow:0 0.8em 2.6em rgba(0,0,0,.85), 0 0 0 1px #000; font-family:'Mono'; color:#e8e8e2; overflow:hidden; }
.fs .hdr { background:#111513; display:flex; align-items:center; justify-content:space-between; padding:0.55em 1em;
  border-bottom:0.18em solid #ffe710; }
.fs .hdr img { height:1.9em; image-rendering:pixelated; display:block; }
.fs .hdr .ver { color:#7d877f; font-size:0.8em; letter-spacing:0.04em; }
.fs .body { display:flex; gap:0.8em; padding:0.8em 1em 0.7em; }
.fs .pane { background:#111513; border:1px solid rgba(255,231,16,.28); }
.fs .pt { display:flex; justify-content:space-between; color:#7d877f; padding:0.45em 0.7em 0.35em; font-size:0.85em;
  border-bottom:1px solid rgba(255,231,16,.28); margin:0 0.3em 0.3em; letter-spacing:0.04em; }
.fs .ln { display:flex; justify-content:space-between; align-items:center; gap:0.8em; padding:0.2em 0.7em 0.2em 1em;
  white-space:nowrap; }
.fs .ln .val { display:inline-block; min-width:2.2em; text-align:right; }
.fs .ln.lit { background:rgba(255,231,16,.16); box-shadow:inset 0.22em 0 0 #ffe710; }
.fs .ln.lit > span:first-child { color:#ffe710; }
.fs .ln .n { color:#7d877f; }
.fs .hd { color:#ffe710; font-family:'Mono B'; padding:0.45em 0.7em 0.15em; font-size:0.85em; letter-spacing:0.05em; }
.fs .on { color:#8fe08f; font-family:'Mono B'; } .fs .off { color:#7d877f; font-family:'Mono B'; }
.fs .arr { color:#7d877f; } .fs .lit .arr { color:#ffe710; }
.fs .sl { display:inline-block; width:5em; height:0.18em; background:#4a524c; position:relative; vertical-align:middle;
  margin-right:0.7em; } .fs .sl i { position:absolute; left:0; top:0; bottom:0; background:#8fe08f; }
.fs .key { font-family:'Mono B'; color:#111; background:#e8e8e2; padding:0 0.35em; border-radius:0.15em; }
.fs .foot { border-top:0.12em solid rgba(255,231,16,.35); padding:0.55em 1em 0.6em; display:flex; gap:1.3em;
  align-items:center; color:#7d877f; font-size:0.85em; white-space:nowrap; }
.fs .foot.clash { color:#ffe710; }
"""


def perf(x, y, w, size):
    """the performance monitor (the loader's own option): each mod's milliseconds a frame, share and worst call"""
    rows = [('FRAME 16.7 MS 60 FPS', 'MS  SHARE WORST', 'hd'), ('ALL MODS', '0.92  5.5%', 'w'),
            ('EXAMPLE MOD', '0.75  4.5%  3.1', ''), ('YOUR MOD', '0.12  0.7%  0.4', ''), ('LOADER', '0.05  0.3%', '')]
    body = ''.join('<div class="row %s"><span>%s</span><span>%s</span></div>' % (c, l, v) for l, v, c in rows)
    return ('<div class="perf" style="left:%dpx;top:%dpx;width:%dpx;font-size:%dpx"><div class="ph">PERFORMANCE MONITOR</div>'
            '%s</div>') % (x, y, w, size, body)


def fullmenu(x, y, w, size, pick=None):
    """the full screen options menu, as on the ship: the mods on the left, Example Mod's options open on the right,
    and along the bottom the hint for a key two options use (pick: which of the right pane's lines to show)"""
    mods = [('Chef Shared Loader', '9', False), ('Example Mod', '27', True), ('Your Mod', '4', False)]
    left = ''.join('<div class="ln%s"><span>%s</span><span class="n">%s</span></div>' % (' lit' if l else '', n, c)
                   for n, c, l in mods)
    def tog(label, on, lit=False):
        return '<div class="ln%s"><span>%s</span><span class="%s">%s</span></div>' % (
            ' lit' if lit else '', label, 'on' if on else 'off', 'ON' if on else 'OFF')
    def sld(label, v, f):
        return ('<div class="ln"><span>%s</span><span><span class="sl"><i style="width:%d%%"></i></span>'
                '<span class="arr">&lt;</span> <span class="on val">%s</span> <span class="arr">&gt;</span></span></div>') % (label, f, v)
    def key(label, k, lit=False):
        return '<div class="ln%s"><span>%s</span><span class="key">%s</span></div>' % (' lit' if lit else '', label, k)
    right = [ '<div class="hd">MARKERS</div>', tog('Show overlay', True), sld('Range', '150', 60), sld('Opacity (%)', '50', 50),
              tog('Show enemies', True), tog('Show common samples', False), '<div class="hd">KEYS</div>',
              key('Hide key', 'F7 !', lit=True), key('Menu key', 'F6')]
    if pick: right = [right[i] for i in pick]
    foot = '<div class="foot clash">F7 ALSO USED BY: YOUR MOD (TOGGLE)</div>'
    return ('<div class="fs" style="left:%dpx;top:%dpx;width:%dpx;font-size:%dpx">'
            '<div class="hdr"><img src="data:image/png;base64,%s"><span class="ver">CHEF SHARED LOADER %s</span></div>'
            '<div class="body"><div class="pane" style="flex:0 0 36%%"><div class="pt"><span>MODS</span><span>3</span></div>%s</div>'
            '<div class="pane" style="flex:1"><div class="pt"><span>EXAMPLE MOD</span></div>%s</div></div>%s</div>') % (
        x, y, w, size, BANNER, VERSION[0], left, ''.join(right), foot)


def feats(size):
    return '<div class="feat" style="font-size:%dpx">%s</div>' % (size, ''.join('<span>%s</span>' % f for f in FEATURES))


def page(W, H, body):
    """one picture as a self-contained page, exactly W x H, fonts and background embedded"""
    fonts = '\n'.join("@font-face{font-family:'%s';src:url(data:font/woff2;base64,%s) format('woff2');}" % (n, b64(f))
                      for n, f in FONTS.items())
    return '<!doctype html><html><head><meta charset="utf-8"><style>%s\n%s</style></head><body><div class="bg"></div>%s</body></html>' % (
        fonts, CSS % {'W': W, 'H': H, 'bg': b64(background(W, H))}, body)


def thumb(out):
    """the 512x512 icon from the big square screenshot"""
    Image.open(os.path.join(out, 'thumbnail_1254.png')).convert('RGB').resize((512, 512), Image.LANCZOS).save(
        os.path.join(out, 'thumbnail.png'))
    print('thumbnail.png')


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--thumb':
        return thumb(sys.argv[2])
    out = sys.argv[1]
    ver = sys.argv[2] if len(sys.argv) > 2 else '1.3.0'
    VERSION[0] = ver
    badge = 'v' + '.'.join(ver.split('.')[:2])
    os.makedirs(out, exist_ok=True)
    v = {'b': badge, 't': TAGLINE}
    jobs = [
        # square: the title at the top, the full screen menu with the monitor over its corner, the tagline at the bottom
        ('thumbnail_1254.png', 1254, 1254, """
      <div style="position:absolute;left:0;right:0;top:48px;text-align:center">
        <div class="title" style="font-size:124px">Chef Shared Loader</div>
        <div style="margin-top:18px"><span class="badge" style="font-size:44px">%(b)s</span></div>
      </div>""" % v + fullmenu(64, 318, 1126, 28) + perf(96, 660, 400, 17) + """
      <div style="position:absolute;left:70px;right:70px;bottom:40px;text-align:center">
        <div class="tag" style="font-size:36px">%(t)s</div>
      </div>""" % v),
        # 16:9: the text on the left, the menu and the monitor on the right
        ('gallery_1920x1080.png', 1920, 1080, """
      <div class="plate" style="left:64px;top:96px;width:600px;padding:38px 38px 40px">
        <div class="title" style="font-size:100px">Chef Shared<br>Loader</div>
        <div style="margin:20px 0 24px"><span class="badge" style="font-size:42px">%(b)s</span></div>
        <div class="tag" style="font-size:33px">%(t)s</div>
        <div style="margin-top:28px">%(f)s</div>
      </div>""" % dict(v, f=feats(28)) + fullmenu(712, 120, 1150, 28) + perf(1300, 742, 572, 22)),
        ('GitHub-Social-1280x640.png', 1280, 640, """
      <div class="plate" style="left:44px;top:44px;width:430px;padding:24px 26px 26px">
        <div class="title" style="font-size:64px">Chef Shared<br>Loader</div>
        <div style="margin:14px 0 16px"><span class="badge" style="font-size:28px">%(b)s</span></div>
        <div class="tag" style="font-size:21px">%(t)s</div>
        <div style="margin-top:16px">%(f)s</div>
      </div>""" % dict(v, f=feats(17)) + fullmenu(506, 64, 730, 17) + perf(930, 432, 310, 13)),
        # 1.6:1, everything inside the middle 1190x800
        ('AyakaMods-Cover-1600x1000.png', 1600, 1000, """
      <div class="plate" style="left:210px;top:150px;width:450px;padding:28px 30px 30px">
        <div class="title" style="font-size:78px">Chef Shared<br>Loader</div>
        <div style="margin:16px 0 18px"><span class="badge" style="font-size:32px">%(b)s</span></div>
        <div class="tag" style="font-size:25px">%(t)s</div>
        <div style="margin-top:20px">%(f)s</div>
      </div>""" % dict(v, f=feats(19)) + fullmenu(690, 176, 700, 18) + perf(1050, 586, 340, 14)),
        # the Nexus header (1300x372): Nexus fades the lower half and puts the page's title, stats and buttons over
        # it, and its Manage button sits top right, so everything stays in the upper half, clear of that corner
        ('header_1300x372.png', 1300, 372, """
      <div style="position:absolute;left:30px;top:34px;width:560px">
        <div style="white-space:nowrap"><span class="title" style="font-size:58px">Chef Shared Loader</span>
          <span class="badge" style="font-size:24px;vertical-align:14px;margin-left:12px">%(b)s</span></div>
        <div class="tag" style="font-size:19px;margin-top:12px">%(t)s</div>
      </div>""" % v + fullmenu(620, 16, 520, 9.5, pick=[0, 1, 2, 3, 6, 7])),
    ]
    for name, W, H, body in jobs:
        open(os.path.join(out, name[:-4] + '.html'), 'wb').write(page(W, H, body).encode('utf-8'))
        print('%s.html  screenshot at --window-size=%d,%d as %s' % (name[:-4], W, H, name))


if __name__ == '__main__':
    main()
