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
art/screens for the snippet.

## Replaying a run (`replay.py`)

Feeds an activity FIT file (Garmin Connect > Export Original) through Python
ports of the field's models and its compute loop, and reports per workout step
(or per lap without a workout): seconds shown as ON PACE / SLOW DOWN / SPEED UP,
actual pace, the alerts the field would fire and the Run app's own pace alerts;
then a per-mile table (course mile, the watch's own distance then, split,
ahead/behind goal) and any OFF COURSE episodes.
```
python tools/replay.py run.fit                          # workout or goal run
python tools/replay.py run.fit --goal 8:55 --alerts always
python tools/replay.py run.fit --course COURSE.fit      # replay CourseTracker too (.fit or .gpx)
python tools/replay.py half.fit --course lap.gpx --laps 3 --fit-to-run     --official 13.1094 --goal 8:55 --write-course race.gpx
python tools/replay.py run.fit --smooth 15 --changes --csv run.csv
```
distanceToDestination isn't in the FIT file. Without `--course` the pace model
runs on the field's recorded `course_dist` (or GPS distance). With `--course`
(Garmin Connect > Courses > Export, or any GPX) it is simulated by projecting
each GPS fix onto the course, and CourseTracker is replayed on it; the report
compares that with the recorded course_dist (within ~20-35 m on the first FR965
run, whose matcher noise was about twice the watch's).

`--fit-to-run` re-cuts a looped route to start where the run started (best fit
over the first km, so a route that passes the start twice still lines up) and
finish where it ended, adding the run's own track for a finish chute off the
route; `--laps` is the number of laps in the race; `--write-course` saves the
course used as a GPX that can be loaded on the watch. `--official` is the
official-length setting.

From v0.3.0 the field records `band_status` each second, and the report adds a
match % between the replay and what the watch showed. Heart-rate zone targets
aren't replayed. Keep the ports in step with source/*.mc. Needs
`pip install fitparse`.
