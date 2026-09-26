"""Build the Connect IQ store cover image (500x500, under 300 KB).

Usage: python art/build_cover.py <watch_shot.png>
Same watch cutout and typography as build_banner.py: the goal-pace screen
centred on navy, wordmark and tagline below.
"""
import os
import sys
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_banner_lib as lib

S = 500
canvas = Image.new("RGBA", (S, S), lib.NAVY)

watch = lib.fit_h(lib.cut_watch(sys.argv[1]), 318)
canvas.alpha_composite(watch, ((S - watch.width) // 2, 22))

word = lib.make_text("CourseRun", lib.F("Poppins-Light.ttf", 64), lib.WHITE, track=-5, vsquash=0.86, condense=0.92)
tag = lib.make_text("Race the course, not the GPS.", lib.F("Poppins-Medium.ttf", 27), lib.GREEN, track=-1)

y = 362
canvas.alpha_composite(word, ((S - word.width) // 2, y)); y += word.height + 14
canvas.alpha_composite(tag, ((S - tag.width) // 2, y))

out = "art/CourseRun_Cover_500x500.png"
canvas.convert("RGB").save(out, "PNG", optimize=True)
print("saved", out, os.path.getsize(out) // 1024, "KB")
