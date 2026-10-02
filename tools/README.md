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

## Replaying a run (`replay.py`)

Feeds an activity FIT file (Garmin Connect > Export Original) through Python
ports of PaceBuffer and WorkoutTarget and the field's compute loop, and prints
per workout step: seconds shown as ON PACE / SLOW DOWN / SPEED UP, actual pace,
the alerts the field would fire, and the native Run app's own pace alerts.
```
python tools/replay.py run.fit                      # current logic
python tools/replay.py run.fit --legacy             # v0.2.0 logic, to compare
python tools/replay.py run.fit --target-units mps   # firmware gives m/s targets
python tools/replay.py run.fit --settle 20 --smooth 15 --changes --csv run.csv
python tools/replay.py run.fit --course COURSE.fit  # replay CourseTracker too (.fit or .gpx)
python tools/replay.py half.fit --course lap.gpx --laps 3 --fit-to-run --official 13.1094 --goal 8:55     --write-course race.gpx                         # lapped race from a one-lap route
```
`--fit-to-run` re-cuts a looped route to start where the run started (best fit
over the first km, so a route that passes the start twice still lines up) and
finish where it ended; `--write-course` saves the result as a GPX that can be
loaded on the watch. `--goal` replays goal-pace mode; with no workout the
report is per lap, plus a per-mile table (course mile, watch distance then,
split, ahead/behind goal) and any OFF COURSE episodes.
distanceToDestination isn't in the FIT file. Without `--course` the pace model
runs on the field's recorded `course_dist` (or GPS). With `--course` (Garmin
Connect > Courses > Export, FIT or GPX) dtd is simulated by projecting each GPS
fix onto the course, searching forward from the last match, and CourseTracker
is replayed on it; the report compares that with the recorded course_dist
(within ~20 m on the first FR965 run). `--official` sets the official length. From v0.3.0 the field
records `band_status`, and the report adds a match % against what the watch
showed. Keep the ports in step with source/*.mc. Needs `pip install fitparse`.
