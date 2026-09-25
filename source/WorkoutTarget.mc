import Toybox.Activity;
import Toybox.Lang;
import Toybox.UserProfile;

// The current workout step's target, read from the native workout engine
// (Garmin Coach, daily suggested workouts, calendar workouts).
//
// Activity.getCurrentWorkoutStep() is documented as throwing from data
// fields, but shipping data fields call it successfully; it is guarded here
// so a firmware that does throw just shows "no target".
//
// Target encodings follow the FIT workout_step message:
//   speed:      targetValueLow/High in mm/s (low = slower)
//   heart rate: > 100 means bpm + 100; 1..5 with low == high is a zone;
//               otherwise 1..100 is percent of max HR
class WorkoutTarget {
    enum {
        KIND_NONE = 0,
        KIND_PACE = 1,
        KIND_HR = 2
    }
    enum {
        STATUS_NONE = 0,
        STATUS_ON = 1,
        STATUS_FAST = 2,  // pace faster than range, or HR above range
        STATUS_SLOW = 3   // pace slower than range, or HR below range
    }

    var kind as Number = KIND_NONE;
    var low as Float = 0.0;   // pace: slow bound m/s; HR: low bpm
    var high as Float = 0.0;  // pace: fast bound m/s; HR: high bpm
    var hasWorkout as Boolean = false;

    function initialize() {
    }

    function refresh() as Void {
        kind = KIND_NONE;
        hasWorkout = false;
        if (!(Activity has :getCurrentWorkoutStep)) {
            return;
        }
        try {
            var info = Activity.getCurrentWorkoutStep();
            if (info == null) {
                return;
            }
            hasWorkout = true;
            var step = info.step;
            if (step instanceof Activity.WorkoutIntervalStep) {
                var inten = info.intensity;
                if (inten == Activity.WORKOUT_INTENSITY_REST
                        || inten == Activity.WORKOUT_INTENSITY_RECOVERY) {
                    step = step.restStep;
                } else {
                    step = step.activeStep;
                }
            }
            if (step instanceof Activity.WorkoutStep) {
                var tt = step.targetType;
                var zones = null;
                if (tt == Activity.WORKOUT_STEP_TARGET_HEART_RATE) {
                    zones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_RUNNING);
                }
                setFrom(tt, step.targetValueLow, step.targetValueHigh, zones);
            }
        } catch (e) {
            kind = KIND_NONE;
        }
    }

    // Pure parser, separated from refresh() so it can be unit tested.
    function setFrom(targetType as Number or Null, lo as Number or Null, hi as Number or Null,
                     zones as Array<Number> or Null) as Void {
        kind = KIND_NONE;
        if (targetType == null || lo == null || hi == null) {
            return;
        }
        if (targetType == Activity.WORKOUT_STEP_TARGET_SPEED) {
            if (lo <= 0 && hi <= 0) {
                return;
            }
            var a = lo / 1000.0;
            var b = hi / 1000.0;
            if (a > b) {
                var tmp = a;
                a = b;
                b = tmp;
            }
            low = a;
            high = b;
            kind = KIND_PACE;
        } else if (targetType == Activity.WORKOUT_STEP_TARGET_HEART_RATE) {
            if (lo > 100 || hi > 100) {
                low = (lo > 100 ? lo - 100 : lo).toFloat();
                high = (hi > 100 ? hi - 100 : hi).toFloat();
            } else if (lo == hi && lo >= 1 && lo <= 5 && zones != null && zones.size() >= 6) {
                low = zones[lo - 1].toFloat();
                high = zones[lo].toFloat();
            } else if (lo > 0 && hi > 0 && zones != null && zones.size() > 0) {
                var maxHr = zones[zones.size() - 1].toFloat();
                low = maxHr * lo / 100.0;
                high = maxHr * hi / 100.0;
            } else {
                return;
            }
            if (low > high) {
                var tmp2 = low;
                low = high;
                high = tmp2;
            }
            kind = KIND_HR;
        }
    }

    // speed in m/s (smoothed), hr in bpm.
    function status(speed as Float or Null, hr as Number or Null) as Number {
        if (kind == KIND_PACE) {
            if (speed == null) {
                return STATUS_NONE;
            }
            if (speed > high) {
                return STATUS_FAST;
            }
            if (speed < low) {
                return STATUS_SLOW;
            }
            return STATUS_ON;
        }
        if (kind == KIND_HR) {
            if (hr == null) {
                return STATUS_NONE;
            }
            if (hr > high) {
                return STATUS_FAST;
            }
            if (hr < low) {
                return STATUS_SLOW;
            }
            return STATUS_ON;
        }
        return STATUS_NONE;
    }
}
