"""Build the Connect IQ store hero banner (1440x720) from simulator screenshots.

Usage: python art/build_banner.py <big_shot.png> <small_shot.png>
The screenshots are full simulator-window captures of the FR965 (the window
shows a photo of the watch on white). The watch is cut out by making the
white background transparent. Fonts: Poppins, shared with the Lift banner.
"""
import sys
import os
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_banner_lib import *  # noqa: F401,F403

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
# Poppins-Light reads airy at this size. Mike picked (from six variants):
# height 0.86, tracking -8, plus a mild 8% horizontal condense. A nine-letter
# word tolerates the condense that Lift's four-letter wordmark did not.
word = make_text("CourseRun", F("Poppins-Light.ttf", 96), WHITE, track=-8, vsquash=0.86, condense=0.92)
tag = make_text("Race the course, not the GPS.", F("Poppins-Medium.ttf", 38), GREEN, track=-1.5)
subs = [make_text("Distance and pace along the route.", F("Poppins-Regular.ttf", 30), LITE, track=-1),
        make_text("On-pace band from your workout", F("Poppins-Regular.ttf", 30), LITE, track=-1),
        make_text("or goal pace. Projected finish.", F("Poppins-Regular.ttf", 30), LITE, track=-1)]

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
