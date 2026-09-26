"""Shared helpers for the store art: colours, fonts, watch cutout, text rendering."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter

NAVY = (10, 22, 40, 255)
WHITE = (248, 250, 252, 255)
LITE = (203, 213, 225, 255)
GREEN = (74, 222, 128, 255)
W, H = 1440, 720
FD = "C:/Source/LiftApp/docs/userguide/fonts/"


def F(n, s):
    return ImageFont.truetype(FD + n, s)


def cut_watch(path):
    # A screen copy of the simulator window: title/menu bar on top, status
    # bar at the bottom, watch photo on a white client area in between.
    # Only the white that touches the image border is removed (flood fill),
    # so white text on the watch screen survives.
    im = Image.open(path).convert("RGB")
    w, h = im.size
    im = im.crop((60, 95, w - 60, h - 70))
    w, h = im.size
    marker = (255, 0, 255)
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w // 2, 0), (w // 2, h - 1)):
        if im.getpixel(seed) != marker:
            ImageDraw.floodfill(im, seed, marker, thresh=40)
    im = im.convert("RGBA")
    px = im.load()
    for y in range(h):
        for x in range(w):
            if px[x, y][:3] == marker:
                px[x, y] = (0, 0, 0, 0)
    im = im.crop(im.getbbox())
    alpha = im.split()[3].filter(ImageFilter.GaussianBlur(0.6))
    im.putalpha(alpha)
    return im


def fit_h(im, h):
    r = h / im.height
    return im.resize((int(im.width * r), h), Image.LANCZOS)


def make_text(text, font, fill, track=0, vsquash=1.0, condense=1.0):
    sc = Image.new("RGBA", (2600, 400), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sc)
    cx = 80
    for ch in text:
        sd.text((cx, 80), ch, font=font, fill=fill)
        cx += font.getlength(ch) + track
    sc = sc.crop(sc.getbbox())
    if vsquash != 1.0 or condense != 1.0:
        sc = sc.resize((max(1, int(sc.width * condense)), max(1, int(sc.height * vsquash))), Image.LANCZOS)
    return sc


