# CourseRun

A full-screen Garmin Connect IQ **data field** for racing and training on a course. It runs inside the native **Run** activity, so Garmin Coach, daily suggested workouts, course navigation, Garmin Connect sync and Strava all work exactly as before.

```
   [  ON PACE  8:44-9:09  ]     status band: current workout step target
            4.87                course distance (not GPS distance)
         COURSE MI
     8:58   |   8:58            course average pace | rolling last-mile pace
   AVG PACE | LAST MI
    43:41   |   162             timer | heart rate
```

## What it shows

| Item | Meaning |
|---|---|
| **Course distance** | Distance covered *along the loaded course*: course length minus the watch's "distance remaining". GPS over-reads on a race (wide turns, weaving), so this matches the mile markers and gives your true course pace. With no course loaded it shows plain GPS distance and says `DISTANCE`. |
| **(GPS)** tag, orange | You are off course, so the watch stopped reporting distance remaining. The field adds GPS distance until you rejoin, then snaps back to the course. |
| **Avg pace** | Timer time ÷ course distance. Your course pace; no chip-time math needed. |
| **Last mi** | Time for the most recent mile (or km) of course distance. Dimmed until the first full mile, showing average pace instead. |
| **Status band** | Green = on pace, red = too fast, blue = too slow, gray = no target. Compares ~30 s smoothed course pace against the current workout step's target range. Heart-rate targets show `HR ON / HIGH / LOW`. |
| **Time, HR** | Activity timer and current heart rate. |
| **To go** | Optional (setting): course distance remaining instead of distance run. Run + to go always equals the course length. |

## Install (sideload)

1. Build `bin/CourseRun.prg` (see CLAUDE.md), or use a built copy.
2. Plug the watch in over USB and copy `CourseRun.prg` to `GARMIN\APPS\`. Unplug.
3. On the watch: **Run** > hold **UP** > **Run Settings** > **Data Screens** > **Add New** > **Custom Data** > layout with **1 field** > choose **Connect IQ** > **CourseRun**.
4. Optional settings (Connect IQ phone app > My Device > CourseRun > Settings):
   - **Official course length**: e.g. `13.11` for a half. Rescales the course so a GPX that measures a little long or short still reads the official distance. `0` = use the course as loaded.
   - **Pace indicator smoothing**: seconds of pace averaged for the status band (default 30).
   - **Rolling pace window**: watch units, 1 mile, or 1 km.
   - **Big number shows**: distance run (default) or distance to go. Distance to go needs a course; without one it shows distance run.

Units follow the watch: set **System > Units** to kilometers or miles and every distance and pace switches. Colors follow the activity's background setting, so dark and light backgrounds both work.

## Race-day / workout workflow

1. **Get the course on the watch** (once per race): download the race's GPX (most races publish one, or copy a Strava route), import it in Garmin Connect (**Training & Planning > Courses > Import**), and send it to the device. Or draw it in the Garmin Connect course creator.
2. **Start the run**: Run > pick today's workout (Garmin Coach / suggested workout / calendar) as normal.
3. **Add the course**: hold **UP** > **Navigation** > **Courses** > pick the course > **Do Course**. The workout keeps running. For a race with no workout, just do the course.
4. Start at the start line, press **START**, and swipe to the CourseRun screen.

## Limitations

- Connect IQ has no access to the training calendar, so you still choose the workout in the native Run app. CourseRun only *reads* the current step's target.
- Garmin documents the workout-step call as unavailable to data fields, but it works on current firmware and is used by other store fields. If a firmware ever blocks it, the band simply stays gray.
- Some %-based targets report as zero (a known Garmin bug). They show as "no target".
- On courses that loop over themselves, the watch can re-lock to the wrong lap after going off course. Course distance never goes backwards, which limits the damage.
- Only up to two Connect IQ fields can run per activity on most watches (four on FR970 / fenix 8).
