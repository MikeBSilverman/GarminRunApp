# Security and privacy

## What CourseRun can and cannot do

CourseRun is a Garmin Connect IQ **data field**. It runs inside the watch's own Run activity in a sandbox that Garmin controls. The manifest requests exactly two permissions, and the build fails if the code touches anything else:

| Permission | Why |
|---|---|
| `UserProfile` | Reads your heart-rate zones so a workout step that targets "Zone 3" can be turned into beats per minute. Read-only. |
| `FitContributor` | Writes course distance, course pace and the pace band's state into the activity file you already record, so Garmin Connect can show them. |

It does **not** request `Communications` (no network access of any kind), `Positioning` (it never reads raw GPS coordinates; it uses only the distances the Run activity already computes), `Background`, `Sensor`, or `SensorHistory`.

Consequences:

- **Nothing leaves the watch** except the activity file that Garmin already syncs. CourseRun cannot send data anywhere.
- **No accounts, tokens or keys** exist in the app. The Connect IQ developer signing key is a local file that is git-ignored and never committed. CI scans every push for accidentally committed secrets.
- **One small record is kept on the watch** (Application.Storage, which needs no permission) so the field can carry on after Stop > Resume Later: activity start time, timer, lap and step marks, course length, course and GPS distance. No location. It is overwritten during the run and deleted when the activity is saved or discarded. When read back it must match the format version and the activity's start time, and every value is type- and range-checked (including NaN) before use; anything else is ignored.
- **Settings are plain numbers and one short text field** (goal pace). The text is parsed with bounds checks and falls back to "no goal" on anything unexpected; it is never executed or sent anywhere.
- **The activity's own distance and pace are untouched.** CourseRun adds extra fields; it cannot alter the official record.

## Robustness

- Every call into Garmin APIs whose availability varies by firmware (`getCurrentWorkoutStep`, `createField`, `Attention`) and every storage or settings call is guarded with `has` checks and `try/catch`, so a missing feature degrades to "no target", "no recording" or "no Resume Later" rather than a crash. `scripts/check.py` fails the build if one isn't.
- Inputs from the watch (`timerTime`, `elapsedDistance`, `distanceToDestination`, `currentHeartRate`) are null-checked; distances are clamped where it matters. Course distance never goes backwards, implausible jumps ahead are ignored, and the pace buffer resets if the timer goes backwards.
- Memory use is bounded: two ring buffers (900 and 64 samples of time and distance), allocated once. The unit tests include a leak check that runs an hour of simulated samples and asserts the heap does not grow.
- `compute` (once a second) does constant work with no allocation in the steady state. `onUpdate` formats and draws, plus two lookups in the pace buffer for the projected finish and rolling pace, only while the screen is showing.

## Reporting a problem

Open a GitHub issue. If you believe you have found something that could affect other users' data, email the maintainer instead (address in the GitHub profile) and allow a few days for a reply before disclosing.
