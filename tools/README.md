# tools/ — screen previews and store art

The simulator can't record a real activity, so screen states are previewed by
building a scratch copy of the app with seeded values.

```
tools/preview.sh fr965 goal dark       # -> bin/preview/shot_fr965_goal.png (simulator window capture)
tools/preview.sh fenix7s compact       # small-screen / 2-field layout check
```
Scenarios: prestart, goal, workout, rest, split, mismatch, offcourse, togo, compact.
`mkpreview.py` seeds the state (edit the `seeds` dict to add one); `shot.ps1`
moves the simulator window to the top-left and copies it from the screen.
(Rendering the window by handle instead leaves the watch screen transparent.)

Store art is built from those captures:
```
python art/build_banner.py bin/preview/shot_fr965_goal.png bin/preview/shot_fr965_workout.png   # 1440x720 hero
python art/build_cover.py  bin/preview/shot_fr965_goal.png                                       # 500x500 cover
```
Screen images for the listing (art/screens/*.png, raw 454x454) are cut from the
captures using the band geometry: the band starts at the top of the display and
ends at 28% of its height, which gives the diameter; see the git history of
art/screens for the snippet, or ask Claude to regenerate them.
