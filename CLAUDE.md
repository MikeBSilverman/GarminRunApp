# CourseRun: Connect IQ data field

Full-screen run data field (Monkey C, `type="datafield"`). Primary device: **fr965** (owner's watch). See README.md for what it does.

## Layout
- `source/CourseRunField.mc`: the DataField. `compute()` (1 Hz) feeds the models, `onUpdate()` draws.
- `source/CourseTracker.mc`: course distance from `Activity.Info.distanceToDestination`. `preview()` learns the length before START (keeps the max, so a finish-point snap on a loop course can't lock 0). Early-run upward re-lock. Stall detector: course value stuck 20 s while GPS moves 50 m => MODE_OFF, add GPS delta. Official-length rescale only within 5% (else `lengthMismatch`). At START a first dtd < 100 m under the previewed length replaces it (preview includes the walk to the start). Course advancing but < 400 m behind the shown distance (after OFF, or a turnaround the route cuts short): back to COURSE, shown distance grows at half the course rate until caught up. A reading > 400 m (+2x GPS delta) ahead is ignored as a leap (wrong lap / finish snap on a lapped course), except the first after START.
- `source/PaceBuffer.mc`: ring buffer of (timer ms, course m), 900 slots at 2 s. Rolling-distance pace and smoothed speed by binary search + interpolation.
- `source/WorkoutTarget.mc`: parses `Activity.getCurrentWorkoutStep()`. Speed targets are mm/s, or m/s when < 100 (FR965 appears to hand m/s: v0.2.0 showed SLOW DOWN all workout) (low = slower, 0 = open bound); HR >100 = bpm+100, 1..5 with low==high = zone, else % max HR. Goal-pace fallback (`setGoal`) when no workout target. `evaluate()` has 1.5% hysteresis. Rest/warm-up steps: `isRest`/`stepLabel`.
- `source/FitRecorder.mc`: FIT developer fields (course distance record/lap/session, course pace session, `band_status` record id 8 for replay). Two id sets: 0-3 miles, 4-7 km; labels in `resources/fit/fit_contributions.xml` (sortOrder must be unique across all fields).
- `source/RunState.mc`: Resume Later state, `[VER=2, startSec, timerMs, lapMs, lapDist, stepMs, stepDist, tracker.snapshot()]` in Application.Storage key "run"; `decode()` validates (format, same activity start, not ahead of the timer) and clamps.
- `source/Fmt.mc`, `source/Layout.mc`: formatting and percentage layout (ported/trimmed from `C:\Source\LiftApp\SRAGarmin`).
- `tests/CourseRunTests.mc`: `(:test)` unit tests (behaviour, hostile inputs, heap-growth check). Stripped from normal builds.
- `scripts/check.py`: static checks CI runs (permissions allowlist, no network/GPS APIs, no keys/secrets, XML + FIT ids, guarded firmware calls, LF endings). `scripts/test.sh` = checks + unit tests.

## Build (Bash tool; SDK 9.2.0)
```
SDK="/c/Users/mikeb/AppData/Roaming/Garmin/ConnectIQ/Sdks/connectiq-sdk-win-9.2.0-2026-06-09-92a1605b2/bin"
scripts/build.sh            # -> bin/CourseRun-<version>.prg (fr965 sideload) and bin/CourseRun-<version>.iq (store)
```
Output files carry the manifest version (Mike's rule: always name builds by version). Bump `version=` in manifest.xml first; patch for fixes (0.2.1), minor for features. Under the hood:
```
"$SDK/monkeyc.bat" -d fr965 -f monkey.jungle -o bin/CourseRun-0.4.1.prg -y developer_key.der -l 2 -w   # sideload
"$SDK/monkeyc.bat" -e -o bin/CourseRun-0.4.1.iq -f monkey.jungle -y developer_key.der -l 2 -w           # all devices / store
```
`developer_key.der` is the same key as Lift, copied locally and git-ignored.

## Tests
```
"$SDK/simulator.exe" &                       # must be running
"$SDK/monkeyc.bat" -d fr965 -f monkey.jungle -o bin/CourseRun-test.prg -y developer_key.der --unit-test -l 2 -w
MSYS2_ARG_CONV_EXCL='*' "$SDK/monkeydo.bat" bin/CourseRun-test.prg fr965 /t
```
In Git Bash, monkeydo needs `/t` (Windows style) and `MSYS2_ARG_CONV_EXCL='*'` so the flag isn't path-mangled.

## Field behaviour
- `compute()` runs before START too (timerTime 0): tracker.preview only. While running, updates happen only when timerTime changed, so pause/stop freezes distance, buffer and FIT writes.
- Band lines at 16%/23% of height, band fill 28%; anything higher clips on the round bezel. Hero at 39%, its label at 53% (Mike wanted clear separation), row 2 at 61%/69%, row 3 at 79%/87%. Keep band strings under ~16 chars at FONT_SMALL.
- Split flash overrides the hero label for 6 s at each course mile/km.
- Band speed (`currentSpeed()`) is GPS distance over the smoothing window x the run's course/GPS ratio (clamped 0.95-1.05), from a 64-slot GPS PaceBuffer. Course distance projected onto a route is too jumpy for the instant verdict (2.7% sd at 30 s on a real FR965 run); it drives totals, splits and goal gap.
- No verdict (STATUS_NONE, recorded as such) while stopped, on rest/recovery steps, and for 30 s after the run starts or a workout step changes (`newStep()`); the band shows the target only.
- Alerts: one per SLOW DOWN / SPEED UP episode, 15 s apart; `maybeAlert()` runs every running tick so an episode starting inside the gap alerts when it ends. Honours `vibrateOn`/`tonesOn`.
- Resume Later: state saved every 3 min and on `onTimerStop`, cleared on `onTimerReset`; restored by the first compute of an instance created mid-activity (`_lastTimerMs < 0` with timer > 0), which is not treated as a running tick. Unverified on hardware whether the field is actually reloaded.
- Workout band line 2: `AVG m:ss · range` (step average on course distance from `_stepStartDist`, after 100 m), else `label range`. Mike chose this (PacePro-style: verdict on the short window, average for the step) over ahead/behind or lap pace in row 2.
- Course distance follows the course file: a square-cornered drawn route reads longer than GPS when corners are cut (run 3: +61 m, 1.4%). Not a bug; README explains.
- Workout step polled every 15 ticks (`REFRESH_TICKS`); step callbacks cover transitions.
- Monkey C NaN quirk: `NaN >= 0.0` is true (`<` is false, `NaN != NaN` true). Check stored floats with `x != x`; `0.0/0.0` throws at runtime, `Math.sqrt(-1.0)` gives NaN in tests.
- Workout step changes call `onWorkoutStepComplete` but not `onTimerLap`, so the step callback restarts the lap too.
- `tools/replay.py run.fit [--course COURSE.fit]` replays a FIT file through Python ports of the models (CourseTracker too, with a course); update it with logic changes.

## Constraints
- Memory: FR970 and fenix 8 give data fields 128 KB (others 256 KB). Current peak ≈ 19 KB. Avoid layouts XML and big string tables.
- FR965 fonts are large: hero `FONT_NUMBER_MEDIUM`, paces `FONT_LARGE`; `FONT_NUMBER_HOT`/`NUMBER_MILD` for paces overflow the columns. Screens ≤ 320 px step down one size.
- `getCurrentWorkoutStep()` is documented as throwing in data fields but works; keep it in try/catch.
- Devices: fr955/965/265/265s/570 (42/47mm)/970, fenix 7 family, epix 2 Pro, fenix 8 family.
