# CourseRun

A full-screen Garmin data field for racing and training on a course. It lives inside the watch's own **Run** activity, so Garmin Coach workouts, suggested workouts, course navigation, Garmin Connect and Strava all keep working exactly as before.

```
   [  ON PACE   AHEAD 0:09  ]     green / red / blue band: how you're doing vs. target
             4.87                  distance along the COURSE, not GPS distance
     COURSE MI · FIN 1:57:35       where the number comes from, and projected finish
      8:58     |    8:58           course average pace | last mile (or km, or lap)
   COURSE AVG  |  LAST MI
     43:41     |    162            time | heart rate
```

## Why

Race courses are measured along the shortest legal line and nobody runs it. GPS reads a half marathon at 13.3 or 13.4 miles, so your watch pace looks slower than your real course pace. CourseRun uses the course you loaded to show distance **along the route**, the pace that goes with it, and whether you're on your goal.

## What you see

| On screen | Meaning |
|---|---|
| **COURSE READY 13.14 MI** (before Start) | A course is loaded and its length is known. Green. |
| **NO COURSE** (before Start) | No course loaded. Hold UP > Navigation > Courses. Orange. Everything still works, using GPS distance. |
| **CHECK LENGTH** (before Start) | The loaded course is more than 5% off the race distance you set. Wrong course, or the setting was left on after a race. Orange. |
| **ON PACE / SLOW DOWN / SPEED UP** | Green, red, blue. Compares your last 30 s of pace with the current workout step's target, or with your goal pace when no workout is loaded. |
| **AHEAD 0:09 / BEHIND 0:12** | Goal-pace mode: seconds ahead of or behind your goal at this point in the course. |
| **RUN 8:44-9:09** | Workout mode: the step name and its pace range, fastest first. |
| **HR OK / HR HIGH / HR LOW** | The step has a heart-rate target instead of pace. |
| **REST / RECOVERY / WARM UP / COOL DOWN** | Steps with no target. Not an error. |
| **NO GOAL SET** | No workout target and no goal pace in settings. The band is simply off. |
| **COURSE MI** | The big number is distance along the course. |
| **GPS MI** | No course. The big number is plain GPS distance. |
| **OFF COURSE MI** (orange) | The course stopped advancing while you kept moving. Distance is being added from GPS until you rejoin. |
| **TO GO MI** | Setting "Big number shows: Distance to go". Run plus to-go always equals the course length. |
| **FIN 1:57:35** | Projected finish time, from remaining course distance and a blend of your average and recent pace. |
| **MI 5  8:52** | Flashes for 6 s at each course mile (or km) with that split. Native auto-laps use GPS distance, so they drift from the mile markers; these don't. |
| **COURSE AVG** | Time divided by course distance. Differs from the watch's own Avg Pace on purpose. |
| **LAST MI / LAST KM / LAP PACE** | Right-hand pace. Choose in settings. Shows AVG (1ST) dimmed until the first full mile. |

Colours follow the activity's background setting (light or dark). Units follow the watch's System > Units.

## One-time setup

1. Install CourseRun (see **Install** below).
2. On the watch: **Run** > hold **UP** > **Run Settings** > **Data Screens** > **Add New** > **Custom Data**.
3. Pick the **1 field** layout. Then choose **Connect IQ Fields** > **CourseRun**.
4. In the Connect IQ phone app: **My Device** > **CourseRun** > **Settings**. Set a **Goal pace** if you race without a workout. Leave **Race distance** at 0 until race week.

## Race-morning checklist

1. Run app open, GPS locked (the ring goes green).
2. Hold **UP** > **Navigation** > **Courses** > the race > **Do Course** (not "in Reverse").
3. If you're following a workout: hold **UP** > **Training** > **Workouts** > pick it > **Do Workout**.
4. Swipe to CourseRun. It should say **COURSE READY** with the right distance.
5. Gun: press **START**. From then on the big number is course distance.

Some firmware versions drop the course when a workout is added afterwards. If **COURSE READY** disappears after step 3, redo step 2. **Rehearse this on a training run the week before the race.**

Getting the course onto the watch: most races publish a GPX. Import it in Garmin Connect (**Training & Planning** > **Courses** > **Import**), or copy a Strava route, or draw it in the course creator, then **Send to Device**.

## If something looks wrong

| Screen shows | Do |
|---|---|
| **NO COURSE** before Start | Hold UP > Navigation > Courses > Do Course. |
| **CHECK LENGTH** before Start | Wrong course loaded, or the **Race distance** setting is left over from a previous race. Fix whichever is wrong. |
| **GPS MI** after Start | The course wasn't loaded. Load it now (same menu); CourseRun picks it up mid-run. |
| **OFF COURSE MI** | You've left the route or the watch locked onto the wrong part of a loop. Get back on the route; it recovers by itself. |
| A bare number on a coloured block | The field is in a 2- or 4-field layout. Use the 1-field layout. |
| Band says **NO HR** | The step has a heart-rate target but no heart rate is available. Check the strap or wrist sensor. |
| Band stays grey with **NO GOAL SET** | No workout target and no goal pace. Set one in settings, or load a workout. |

## Settings

| Setting | Meaning |
|---|---|
| **Goal pace** | e.g. `9:00`, in your watch's pace units. Used when no workout target is active. Blank = off. |
| **Goal pace leeway** | Seconds per mile/km that still count as on pace. Default 10. |
| **Vibrate when you drift off pace** | Off / goal pace only (default) / always. Workouts already alert on their own. At most one buzz per 15 s. |
| **Race distance** | e.g. `13.11` (miles) or `21.1` (km). The finish then reads exactly this even if the course file measures a little long or short. Only applies when the loaded course is within 5% of it. **Set back to 0 after the race.** |
| **Big number shows** | Distance run (default) or distance to go. |
| **Right-hand pace** | Last mile or km (watch units, default), last mile, last km, or lap pace on course distance. |
| **ON PACE band: seconds of pace to average** | Default 30. Higher is steadier but slower to react. |

## What gets recorded

The activity's official distance and pace stay the watch's own GPS values; no data field can change them. CourseRun adds its own fields to the activity file, which Garmin Connect shows on the activity page:

| Field | Where |
|---|---|
| Course Distance | Chart over the run, and the activity summary |
| Lap Course Distance | Laps table, next to each lap's GPS distance |
| Course Pace | Summary, in decimal minutes (8.97 min/mi = 8:58) |

Units are fixed from the watch's setting when the Run app opens. Strava ignores these extra fields.

## Install

**From the Connect IQ store** (when published): install like any data field.

**Sideload**: copy `CourseRun.prg` to the watch's `GARMIN\APPS\` folder over USB and unplug. Settings are not reachable from the phone app for a sideloaded build; the defaults are goal pace off, race distance 0, alerts in goal mode only. To change them, edit the defaults in `resources/settings/properties.xml` before building.

## Privacy and safety

CourseRun asks for two permissions: read your heart-rate zones, and write two extra fields into the activity you already record. It has no network access and never reads raw GPS. See [SECURITY.md](SECURITY.md).

## For developers

Monkey C, `type="datafield"`, Connect IQ SDK 9.2. Targets Forerunner 265/265s/570/955/965/970, fēnix 7, fēnix 8, epix 2 Pro. Peak memory about 29 KB against the 128 KB limit on the smallest of those.

```
scripts/test.sh          # static checks + 27 unit tests in the simulator
python scripts/check.py  # static checks only (what CI runs)
```

Build commands, layout notes and the module map are in [CLAUDE.md](CLAUDE.md). Bug reports and pull requests are welcome.

MIT licensed.
