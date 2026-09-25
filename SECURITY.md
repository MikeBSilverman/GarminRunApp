# Security and privacy

## What CourseRun can and cannot do

CourseRun is a Garmin Connect IQ **data field**. It runs inside the watch's own Run activity in a sandbox that Garmin controls. The manifest requests exactly two permissions, and the build fails if the code touches anything else:

| Permission | Why |
|---|---|
| `UserProfile` | Reads your heart-rate zones so a workout step that targets "Zone 3" can be turned into beats per minute. Read-only. |
| `FitContributor` | Writes course distance and course pace into the activity file you already record, so Garmin Connect can show them. |

It does **not** request `Communications` (no network access of any kind), `Positioning` (it never reads raw GPS coordinates; it uses only the distances the Run activity already computes), `Background`, `Sensor`, or `SensorHistory`.

Consequences:

- **Nothing leaves the watch** except the activity file that Garmin already syncs. CourseRun cannot send data anywhere.
- **No accounts, tokens or keys** exist in the app. The Connect IQ developer signing key is a local file that is git-ignored and never committed. CI scans every push for accidentally committed secrets.
- **Settings are plain numbers and one short text field** (goal pace). The text is parsed with bounds checks and falls back to "no goal" on anything unexpected; it is never executed or sent anywhere.
- **The activity's own distance and pace are untouched.** CourseRun adds extra fields; it cannot alter the official record.

## Robustness

- Every call into Garmin APIs whose availability varies by firmware (`getCurrentWorkoutStep`, `createField`, `Attention`) is guarded with `has` checks and `try/catch`, so a missing feature degrades to "no target" or "no recording" rather than a crash.
- All numeric inputs from the watch (`timerTime`, `elapsedDistance`, `distanceToDestination`, `currentHeartRate`) are null-checked and clamped. Course distance never goes backwards; the pace buffer resets if the timer goes backwards.
- Memory use is bounded: two fixed arrays of 900 samples, allocated once. The unit tests include a leak check that runs an hour of simulated samples and asserts the heap does not grow.
- The field does no work in `onUpdate` beyond formatting and drawing; all computation happens once per second in `compute`.

## Reporting a problem

Open a GitHub issue. If you believe you have found something that could affect other users' data, email the maintainer instead (address in the GitHub profile) and allow a few days for a reply before disclosing.
