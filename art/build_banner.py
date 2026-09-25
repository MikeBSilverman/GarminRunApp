"""Build the Connect IQ store hero banner (1440x720) from simulator screenshots.

Usage: python art/build_banner.py <big_shot.png> <small_shot.png>
The screenshots are full simulator-window captures of the FR965 (the window
shows a photo of the watch on white). The watch is cut out by making the
white background transparent. Fonts: Poppins, shared with the Lift banner.
"""
import sys
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


def make_text(text, font, fill, track=0, vsquash=1.0):
    sc = Image.new("RGBA", (2600, 400), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sc)
    cx = 80
    for ch in text:
        sd.text((cx, 80), ch, font=font, fill=fill)
        cx += font.getlength(ch) + track
    sc = sc.crop(sc.getbbox())
    if vsquash != 1.0:
        sc = sc.resize((sc.width, max(1, int(sc.height * vsquash))), Image.LANCZOS)
    return sc


big_path, small_path = sys.argv[1], sys.argv[2]
canvas = Image.new("RGBA", (W, H), NAVY)

big = fit_h(cut_watch(big_path), 640)
small = fit_h(cut_watch(small_path), 410)
bx, by = 1140 - big.width // 2, 360 - big.height // 2
canvas.alpha_composite(big, (bx, by))
sx, sy = 860 - small.width // 2, 480 - small.height // 2
canvas.alpha_composite(small, (sx, sy))

LX = 110
icon = Image.open("art/courserun_icon_512.png").convert("RGBA").resize((86, 86), Image.LANCZOS)
word = make_text("CourseRun", F("Poppins-Light.ttf", 96), WHITE, track=-4, vsquash=0.85)
tag = make_text("Race the course, not the GPS.", F("Poppins-Medium.ttf", 38), GREEN)
subs = [make_text("Distance and pace along the route.", F("Poppins-Regular.ttf", 30), LITE),
        make_text("On-pace band from your workout", F("Poppins-Regular.ttf", 30), LITE),
        make_text("or goal pace. Projected finish.", F("Poppins-Regular.ttf", 30), LITE)]

gap_icon, gap_word, gap_tag, line = 26, 18, 28, 12
total = 86 + gap_icon + word.height + gap_word + tag.height + gap_tag + sum(s.height for s in subs) + line * (len(subs) - 1)
y = (H - total) // 2
canvas.alpha_composite(icon, (LX, y)); y += 86 + gap_icon
canvas.alpha_composite(word, (LX, y)); y += word.height + gap_word
canvas.alpha_composite(tag, (LX, y)); y += tag.height + gap_tag
for s in subs:
    canvas.alpha_composite(s, (LX, y)); y += s.height + line

out = "art/CourseRun_Hero_Banner_1440x720.png"
canvas.convert("RGB").save(out, "PNG")
print("saved", out)
