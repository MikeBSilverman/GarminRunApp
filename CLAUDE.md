# CourseRun: Connect IQ data field

Full-screen run data field (Monkey C, `type="datafield"`). Primary device: **fr965** (owner's watch). See README.md for what it does.

## Layout
- `source/CourseRunField.mc`: the DataField. `compute()` (1 Hz) feeds the models, `onUpdate()` draws.
- `source/CourseTracker.mc`: course distance from `Activity.Info.distanceToDestination`. `preview()` learns the length before START (keeps the max, so a finish-point snap on a loop course can't lock 0). Early-run upward re-lock. Stall detector: course value stuck 20 s while GPS moves 50 m => MODE_OFF, add GPS delta. Official-length rescale only within 5% (else `lengthMismatch`).
- `source/PaceBuffer.mc`: ring buffer of (timer ms, course m), 900 slots at 2 s. Rolling-distance pace and smoothed speed by binary search + interpolation.
- `source/WorkoutTarget.mc`: parses `Activity.getCurrentWorkoutStep()`. Speed targets are mm/s (low = slower, 0 = open bound); HR >100 = bpm+100, 1..5 with low==high = zone, else % max HR. Goal-pace fallback (`setGoal`) when no workout target. `evaluate()` has 1.5% hysteresis. Rest/warm-up steps: `isRest`/`stepLabel`.
- `source/FitRecorder.mc`: FIT developer fields (course distance record/lap/session, course pace session). Two id sets: 0-3 miles, 4-7 km; labels in `resources/fit/fit_contributions.xml` (sortOrder must be unique across all fields).
- `source/Fmt.mc`, `source/Layout.mc`: formatting and percentage layout (ported/trimmed from `C:\Source\LiftApp\SRAGarmin`).
- `tests/CourseRunTests.mc`: `(:test)` unit tests (behaviour, hostile inputs, heap-growth check). Stripped from normal builds.
- `scripts/check.py`: static checks CI runs (permissions allowlist, no network/GPS APIs, no keys/secrets, XML + FIT ids, guarded firmware calls, LF endings). `scripts/test.sh` = checks + unit tests.

## Build (Bash tool; SDK 9.2.0)
```
SDK="/c/Users/mikeb/AppData/Roaming/Garmin/ConnectIQ/Sdks/connectiq-sdk-win-9.2.0-2026-06-09-92a1605b2/bin"
"$SDK/monkeyc.bat" -d fr965 -f monkey.jungle -o bin/CourseRun.prg -y developer_key.der -l 2 -w      # sideload
"$SDK/monkeyc.bat" -e -o bin/CourseRun.iq -f monkey.jungle -y developer_key.der -l 2 -w              # all devices / store
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
- Band lines at 16%/23% of height, band fill 28%; anything higher clips on the round bezel. Keep band strings under ~16 chars at FONT_SMALL.
- Split flash overrides the hero label for 6 s at each course mile/km.

## Constraints
- Memory: FR970 and fenix 8 give data fields 128 KB (others 256 KB). Current peak ≈ 19 KB. Avoid layouts XML and big string tables.
- FR965 fonts are large: hero `FONT_NUMBER_MEDIUM`, paces `FONT_LARGE`; `FONT_NUMBER_HOT`/`NUMBER_MILD` for paces overflow the columns. Screens ≤ 320 px step down one size.
- `getCurrentWorkoutStep()` is documented as throwing in data fields but works; keep it in try/catch.
- Devices: fr955/965/265/265s/570 (42/47mm)/970, fenix 7 family, epix 2 Pro, fenix 8 family.
