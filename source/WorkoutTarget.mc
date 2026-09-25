import Toybox.Activity;
import Toybox.Lang;
import Toybox.UserProfile;

// The pace or heart-rate target the status band judges against. It comes
// from the native workout engine (Garmin Coach, daily suggested workouts,
// calendar workouts) or, when no workout target is active, from the goal
// pace setting.
//
// Activity.getCurrentWorkoutStep() is documented as throwing from data
// fields, but shipping data fields call it successfully; it is guarded here
// so a firmware that does throw just shows "no target".
//
// Target encodings follow the FIT workout_step message:
//   speed:      targetValueLow/High in mm/s (low = slower); 0 = open bound
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
    enum {
        SOURCE_NONE = 0,
        SOURCE_WORKOUT = 1,
        SOURCE_GOAL = 2
    }

    hidden const OPEN_HIGH = 99.0;   // m/s; "no fast limit"
    hidden const HYST = 0.015;       // 1.5% dead band before status changes

    var kind as Number = KIND_NONE;
    var source as Number = SOURCE_NONE;
    var low as Float = 0.0;   // pace: slow bound m/s (0 = open); HR: low bpm
    var high as Float = 0.0;  // pace: fast bound m/s (OPEN_HIGH = open); HR: high bpm
    var hasWorkout as Boolean = false;
    var stepLabel as String = "";   // "REST", "WARM UP", or the step name
    var isRest as Boolean = false;
    var status as Number = STATUS_NONE;

    hidden var _zones as Array<Number> or Null = null;
    hidden var _goalSpeed as Float = 0.0;   // m/s, 0 = no goal
    hidden var _goalTol as Float = 0.0;     // fraction of goal speed

    function initialize() {
    }

    // Goal pace fallback: secPerUnit over unitM metres, tolerance in seconds
    // per unit. 0 disables.
    function setGoal(secPerUnit as Float, unitM as Float, tolSec as Float) as Void {
        if (secPerUnit <= 0.0) {
            _goalSpeed = 0.0;
            return;
        }
        _goalSpeed = unitM / secPerUnit;
        _goalTol = tolSec > 0.0 ? tolSec / secPerUnit : 0.0;
        applyGoal();
    }

    function goalSpeed() as Float {
        return _goalSpeed;
    }

    hidden function applyGoal() as Void {
        if (kind != KIND_NONE || _goalSpeed <= 0.0 || isRest) {
            return;
        }
        // Slower pace = lower speed. Tolerance is symmetric in time per unit.
        low = _goalSpeed / (1.0 + _goalTol);
        high = _goalSpeed / (1.0 - _goalTol);
        kind = KIND_PACE;
        source = SOURCE_GOAL;
    }

    function refresh() as Void {
        kind = KIND_NONE;
        source = SOURCE_NONE;
        hasWorkout = false;
        stepLabel = "";
        isRest = false;
        if (Activity has :getCurrentWorkoutStep) {
            try {
                readWorkout();
            } catch (e) {
                kind = KIND_NONE;
            }
        }
        applyGoal();
    }

    hidden function readWorkout() as Void {
        var info = Activity.getCurrentWorkoutStep();
        if (info == null) {
            return;
        }
        hasWorkout = true;
        var inten = info.intensity;
        isRest = inten == Activity.WORKOUT_INTENSITY_REST
              || inten == Activity.WORKOUT_INTENSITY_RECOVERY;
        stepLabel = intensityLabel(inten, info.name);

        var step = info.step;
        if (step instanceof Activity.WorkoutIntervalStep) {
            step = isRest ? step.restStep : step.activeStep;
        }
        if (step instanceof Activity.WorkoutStep) {
            var tt = step.targetType;
            if (tt == Activity.WORKOUT_STEP_TARGET_HEART_RATE && _zones == null) {
                _zones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_RUNNING);
            }
            setFrom(tt, step.targetValueLow, step.targetValueHigh, _zones);
            if (kind != KIND_NONE) {
                source = SOURCE_WORKOUT;
            }
        }
    }

    hidden function intensityLabel(inten as Number or Null, name as String or Null) as String {
        if (inten == Activity.WORKOUT_INTENSITY_REST) {
            return "REST";
        }
        if (inten == Activity.WORKOUT_INTENSITY_RECOVERY) {
            return "RECOVERY";
        }
        if (inten == Activity.WORKOUT_INTENSITY_WARMUP) {
            return "WARM UP";
        }
        if (inten == Activity.WORKOUT_INTENSITY_COOLDOWN) {
            return "COOL DOWN";
        }
        if (name != null && name.length() > 0 && name.length() <= 12) {
            return name.toUpper();
        }
        return "";
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
            if (a > 0.0 && b > 0.0 && a > b) {
                var tmp = a;
                a = b;
                b = tmp;
            }
            // A zero bound means "open" on that side.
            low = a > 0.0 ? a : 0.0;
            high = b > 0.0 ? b : OPEN_HIGH;
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

    function openLow() as Boolean {
        return kind == KIND_PACE && low <= 0.0;
    }

    function openHigh() as Boolean {
        return kind == KIND_PACE && high >= OPEN_HIGH;
    }

    // Updates and returns `status`. speed in m/s (smoothed), hr in bpm.
    // Leaving the range needs the value to be 1.5% outside it; returning
    // needs it back inside. This stops the band flickering at the edge.
    function evaluate(speed as Float or Null, hr as Number or Null) as Number {
        var v = null;
        if (kind == KIND_PACE) {
            v = speed;
        } else if (kind == KIND_HR) {
            v = hr != null ? hr.toFloat() : null;
        }
        if (v == null) {
            status = STATUS_NONE;
            return status;
        }
        var val = v as Float;
        var next = STATUS_ON;
        if (status == STATUS_FAST) {
            next = val > high ? STATUS_FAST : (val < low * (1.0 - HYST) ? STATUS_SLOW : STATUS_ON);
        } else if (status == STATUS_SLOW) {
            next = val < low ? STATUS_SLOW : (val > high * (1.0 + HYST) ? STATUS_FAST : STATUS_ON);
        } else {
            if (val > high * (1.0 + HYST)) {
                next = STATUS_FAST;
            } else if (val < low * (1.0 - HYST)) {
                next = STATUS_SLOW;
            }
        }
        status = next;
        return status;
    }
}
