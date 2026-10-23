"""Chef Shared Loader release art: thumbnail (1254x1254, and the 512x512 Arsenal one), gallery photo (1920x1080),
GitHub social preview (1280x640), the Nexus header (1300x372) and the AyakaMods cover (1600x1000, the title inside the middle the site's mod cards
show). HTML rendered with Playwright Chromium over a blurred shot of the game (scene.jpg): the title and badge in
Anton and Barlow Condensed, the log and the options menu in JetBrains Mono (all SIL Open Font License, from
@fontsource, in fonts/). The menu and the monitor follow the loader's own (its pixel font redrawn in a mono face).
python3 art/cards.py <out dir> [version, e.g. 1.0.0]"""
import base64, io, os, sys
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = {'Anton': 'anton-latin-400-normal.woff2', 'Barlow Condensed': 'barlow-condensed-latin-600-normal.woff2',
         'Barlow Condensed B': 'barlow-condensed-latin-800-normal.woff2', 'Mono': 'jetbrains-mono-latin-500-normal.woff2',
         'Mono B': 'jetbrains-mono-latin-700-normal.woff2'}
TAGLINE = 'One shared Lua loader for every Helldivers 2 mod: side by side, crash-guarded and locked down, with an in-game options menu and a performance monitor'
FEATURES = ['ANY AUTHOR', 'F9 OPTIONS MENU', 'PERFORMANCE MONITOR', 'CRASH GUARD', 'LOCKED DOWN', 'MOD API + GUIDE']


def background(W, H):
    """the game, blurred and darkened toward the edges (a touch darker than Treasure Radar's, for the windows)"""
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
.perf .row { display:flex; justify-content:space-between; padding:0.14em 0.75em; white-space:pre; }
.perf .row.hd { color:#96ffb4; } .perf .row.w { color:#fff; font-family:'Mono B'; }
/* the options menu (F9) */
.menu { position:absolute; background:rgba(8,10,9,.95); border:2px solid #ffe710; border-radius:0.3em;
  box-shadow:0 0.6em 2em rgba(0,0,0,.8); font-family:'Mono'; color:#e8e8e2; }
.menu .head { font-family:'Mono B'; background:#ffe710; color:#111; padding:0.4em 0.75em; display:flex; justify-content:space-between; }
.menu .grp { font-family:'Mono B'; color:#ffe710; padding:0.55em 0.75em 0.15em; letter-spacing:0.04em; }
.menu .row { display:flex; justify-content:space-between; padding:0.18em 0.75em 0.18em 1.4em; }
.menu .row.sel { background:rgba(255,231,16,.16); box-shadow:inset 0.2em 0 0 #ffe710; }
.menu .v { font-family:'Mono B'; color:#8fe08f; }
.menu .k { font-family:'Mono B'; color:#111; background:#e8e8e2; padding:0 0.35em; border-radius:0.15em; }
.menu .foot { color:#7d877f; padding:0.5em 0.75em 0.55em; border-top:1px solid rgba(255,231,16,.25); margin-top:0.4em;
  white-space:nowrap; font-size:0.85em; }
"""


def perf(x, y, w, size):
    """the performance monitor (the loader's own option): each mod's milliseconds a frame, share and worst call"""
    rows = [('FRAME 16.7 MS 60 FPS', 'MS  SHARE WORST', 'hd'), ('ALL MODS', '0.92  5.5%', 'w'),
            ('TREASURE RADAR', '0.75  4.5%  3.1', ''), ('YOUR MOD', '0.12  0.7%  0.4', ''), ('LOADER', '0.05  0.3%', '')]
    body = ''.join('<div class="row %s"><span>%s</span><span>%s</span></div>' % (c, l, v) for l, v, c in rows)
    return ('<div class="perf" style="left:%dpx;top:%dpx;width:%dpx;font-size:%dpx"><div class="ph">PERFORMANCE MONITOR</div>'
            '%s</div>') % (x, y, w, size, body)


def menu(x, y, w, size):
    """the options menu (F9): the mods in alphabetical order; Enter opens one"""
    def row(label, n, sel=False):
        return '<div class="row%s"><span>%s</span><span class="v">&gt;</span></div>' % (' sel' if sel else '', label)
    body = ''.join([
        '<div class="head"><span>CHEF SHARED LOADER OPTIONS</span><span>F9</span></div>',
        row('Chef Shared Loader', 3), row('Treasure Radar', 27, sel=True), row('Your Mod', 4),
        '<div class="foot">Enter open &nbsp; / search &nbsp; F9 close</div>'])
    return '<div class="menu" style="left:%dpx;top:%dpx;width:%dpx;font-size:%dpx">%s</div>' % (x, y, w, size, body)


def feats(size):
    return '<div class="feat" style="font-size:%dpx">%s</div>' % (size, ''.join('<span>%s</span>' % f for f in FEATURES))


def render(page, W, H, body):
    fonts = '\n'.join("@font-face{font-family:'%s';src:url(data:font/woff2;base64,%s) format('woff2');}" % (n, b64(f))
                      for n, f in FONTS.items())
    html = '<html><head><style>%s\n%s</style></head><body><div class="bg"></div>%s</body></html>' % (
        fonts, CSS % {'W': W, 'H': H, 'bg': b64(background(W, H))}, body)
    page.set_viewport_size({'width': W, 'height': H})
    page.set_content(html)
    page.wait_for_timeout(300)
    return page.screenshot(type='png')


def main():
    out = sys.argv[1]
    ver = sys.argv[2] if len(sys.argv) > 2 else '1.0.0'
    badge = 'v' + '.'.join(ver.split('.')[:2])
    os.makedirs(out, exist_ok=True)
    v = {'b': badge, 't': TAGLINE}
    jobs = [
        # square: the title at the top, the log behind the menu in the middle, the tagline at the bottom
        ('thumbnail_1254.png', 1254, 1254, """
      <div style="position:absolute;left:0;right:0;top:54px;text-align:center">
        <div class="title" style="font-size:128px">Chef Shared Loader</div>
        <div style="margin-top:20px"><span class="badge" style="font-size:46px">%(b)s</span></div>
      </div>""" % v + menu(80, 340, 760, 36) + perf(420, 712, 760, 32) + """
      <div style="position:absolute;left:70px;right:70px;bottom:44px;text-align:center">
        <div class="tag" style="font-size:38px">%(t)s</div>
      </div>""" % v),
        # 16:9: the text on the left, the windows on the right
        ('gallery_1920x1080.png', 1920, 1080, """
      <div class="plate" style="left:70px;top:110px;width:640px;padding:40px 40px 42px">
        <div class="title" style="font-size:104px">Chef Shared<br>Loader</div>
        <div style="margin:22px 0 26px"><span class="badge" style="font-size:44px">%(b)s</span></div>
        <div class="tag" style="font-size:35px">%(t)s</div>
        <div style="margin-top:30px">%(f)s</div>
      </div>""" % dict(v, f=feats(30)) + menu(790, 150, 780, 34) + perf(1060, 500, 790, 31)),
        ('GitHub-Social-1280x640.png', 1280, 640, """
      <div class="plate" style="left:48px;top:58px;width:470px;padding:30px 30px 32px">
        <div class="title" style="font-size:78px">Chef Shared<br>Loader</div>
        <div style="margin:18px 0 20px"><span class="badge" style="font-size:34px">%(b)s</span></div>
        <div class="tag" style="font-size:25px">%(t)s</div>
        <div style="margin-top:20px">%(f)s</div>
      </div>""" % dict(v, f=feats(20)) + menu(560, 80, 430, 18) + perf(790, 300, 440, 17)),
        # 1.6:1, the plate inside the middle 1190x800
        ('AyakaMods-Cover-1600x1000.png', 1600, 1000, """
      <div class="plate" style="left:210px;top:160px;width:480px;padding:32px 32px 34px">
        <div class="title" style="font-size:86px">Chef Shared<br>Loader</div>
        <div style="margin:18px 0 22px"><span class="badge" style="font-size:36px">%(b)s</span></div>
        <div class="tag" style="font-size:28px">%(t)s</div>
        <div style="margin-top:22px">%(f)s</div>
      </div>""" % dict(v, f=feats(21)) + menu(740, 180, 470, 20) + perf(960, 420, 470, 19)),
        # the Nexus header (1300x372): Nexus fades the lower half and puts the page's title, stats and buttons over
        # it, and its Manage button sits top right, so everything stays in the upper half, clear of that corner
        ('header_1300x372.png', 1300, 372, """
      <div style="position:absolute;left:30px;top:34px;width:560px">
        <div style="white-space:nowrap"><span class="title" style="font-size:58px">Chef Shared Loader</span>
          <span class="badge" style="font-size:24px;vertical-align:14px;margin-left:12px">%(b)s</span></div>
        <div class="tag" style="font-size:19px;margin-top:12px">%(t)s</div>
      </div>""" % v + menu(596, 30, 268, 13) + perf(880, 30, 296, 12)),
    ]
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page()
        for name, W, H, body in jobs:
            open(os.path.join(out, name), 'wb').write(render(page, W, H, body))
            print(name)
        b.close()
    Image.open(os.path.join(out, 'thumbnail_1254.png')).convert('RGB').resize((512, 512), Image.LANCZOS).save(
        os.path.join(out, 'thumbnail.png'))
    print('thumbnail.png')


if __name__ == '__main__':
    main()
