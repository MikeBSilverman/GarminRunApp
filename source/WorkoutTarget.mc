import Toybox.Activity;
import Toybox.Lang;
import Toybox.UserProfile;

// The pace or heart-rate target the status band judges against. It comes
// from the native workout engine (Garmin Coach, daily suggested workouts,
// calendar workouts) or, when no workout target is active, from the goal
// heart rate or goal pace setting (heart rate wins when both are set).
//
// Activity.getCurrentWorkoutStep() is documented as throwing from data
// fields, but shipping data fields call it successfully; it is guarded here
// so a firmware that does throw just shows "no target".
//
// Target encodings follow the FIT workout_step message:
//   speed:      targetValueLow/High in mm/s (low = slower); 0 = open bound.
//               Some firmware (and the simulator) hands over m/s instead; a
//               value under 100 can't be mm/s for a run, so it is read as m/s.
//               (An FR965 run read as mm/s turned 8:10/mi into 0.003 m/s and
//               showed SLOW DOWN all workout.)
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
    hidden const MMPS_MIN = 100.0;   // speed values at or above this are mm/s
    hidden const HYST = 0.015;       // 1.5% dead band before status changes
    hidden const STOP_FRACTION = 0.65;   // of the slow bound: below this you've stopped or walk
    hidden const STOP_SPEED = 1.6;       // m/s (16:46/mi) when there is no slow pace bound
    hidden const BPM_MIN = 30.0;         // goal HR values outside this are typos
    hidden const BPM_MAX = 250.0;

    var kind as Number = KIND_NONE;
    var source as Number = SOURCE_NONE;
    var low as Float = 0.0;   // pace: slow bound m/s (0 = open); HR: low bpm (0 = open)
    var high as Float = 0.0;  // pace: fast bound m/s (OPEN_HIGH = open); HR: high bpm
    var hasWorkout as Boolean = false;
    var stepLabel as String = "";   // "REST", "WARM UP", or the step name
    var isRest as Boolean = false;
    var status as Number = STATUS_NONE;

    hidden var _zones as Array<Number> or Null = null;
    hidden var _goalSpeed as Float = 0.0;   // m/s, 0 = no goal
    hidden var _goalTol as Float = 0.0;     // fraction of goal speed
    hidden var _goalHrLo as Float = 0.0;    // bpm, 0 = no floor
    hidden var _goalHrHi as Float = 0.0;    // bpm, 0 = no HR goal

    function initialize() {
    }

    // Goal pace fallback: secPerUnit over unitM metres, tolerance in seconds
    // per unit. 0 disables.
    function setGoal(secPerUnit as Float, unitM as Float, tolSec as Float) as Void {
        if (secPerUnit <= 0.0) {
            _goalSpeed = 0.0;
        } else {
            _goalSpeed = unitM / secPerUnit;
            _goalTol = tolSec > 0.0 ? tolSec / secPerUnit : 0.0;
        }
        reapplyGoal();
    }

    // Goal heart rate fallback from the setting text (see parseHr). Wins
    // over the goal pace. Blank or unreadable = none.
    function setGoalHr(spec as String) as Void {
        var r = null;
        if (Fmt.trim(spec).length() > 0) {
            if (_zones == null) {
                _zones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_RUNNING);
            }
            r = parseHr(spec, _zones);
        }
        _goalHrLo = r != null ? r[0] : 0.0;
        _goalHrHi = r != null ? r[1] : 0.0;
        reapplyGoal();
    }

    function hasGoalHr() as Boolean {
        return _goalHrHi > 0.0;
    }

    // Goal HR setting text to [low, high] bpm (low 0 = no floor), or null:
    //   "2"       zone 2 of the watch's running zones
    //   "1-2"     zones 1 to 2
    //   "130-145" a bpm range
    //   "145"     a ceiling only: never HR LOW
    // zones is UserProfile.getHeartRateZones(): [z1 min, z1 max, ... z5 max].
    function parseHr(spec as String, zones as Array<Number> or Null) as Array<Float> or Null {
        var s = Fmt.trim(spec);
        if (s.length() == 0 || !Fmt.digitsAndOne(s, '-')) {
            return null;
        }
        var dash = s.find("-");
        var a = (dash != null ? s.substring(0, dash) : s) as String;
        var b = (dash != null ? s.substring(dash + 1, s.length()) : s) as String;
        if (a.length() == 0 || b.length() == 0 || a.length() > 3 || b.length() > 3) {
            return null;
        }
        var lo = a.toNumber();
        var hi = b.toNumber();
        if (lo == null || hi == null) {
            return null;
        }
        if (lo > hi) {
            var t = lo;
            lo = hi;
            hi = t;
        }
        if (lo >= 1 && hi <= 5) {
            if (zones == null || zones.size() < 6) {
                return null;
            }
            return [zones[lo - 1].toFloat(), zones[hi].toFloat()] as Array<Float>;
        }
        if (lo < BPM_MIN || hi > BPM_MAX) {
            return null;
        }
        return [dash != null ? lo.toFloat() : 0.0, hi.toFloat()] as Array<Float>;
    }

    // A goal setting changed: replace a goal target in force (or fill an
    // empty one). A workout target stays.
    hidden function reapplyGoal() as Void {
        if (source == SOURCE_GOAL) {
            kind = KIND_NONE;
            source = SOURCE_NONE;
        }
        applyGoal();
    }

    function goalSpeed() as Float {
        return _goalSpeed;
    }

    // On a step judged on pace, the goal HR's top doubles as a ceiling: true
    // when hr is over it (row 3 shows HR in red). Workouts often carry HR as
    // a secondary target, which data fields can't read and the watch shows
    // but never alerts on.
    function hrOverCap(hr as Number or Null) as Boolean {
        return kind == KIND_PACE && !isRest && _goalHrHi > 0.0 && hr != null && hr > _goalHrHi;
    }

    hidden function applyGoal() as Void {
        if (kind != KIND_NONE || isRest) {
            return;
        }
        if (_goalHrHi > 0.0) {
            low = _goalHrLo;
            high = _goalHrHi;
            kind = KIND_HR;
            source = SOURCE_GOAL;
            return;
        }
        if (_goalSpeed <= 0.0) {
            return;
        }
        // Slower pace = lower speed. Tolerance is symmetric in time per unit.
        low = _goalSpeed / (1.0 + _goalTol);
        high = _goalSpeed / (1.0 - _goalTol);
        kind = KIND_PACE;
        source = SOURCE_GOAL;
    }

    // Re-reads the workout step. Returns true when the target changed (new
    // step, rest/active switch), so the caller can restart its settle period.
    function refresh() as Boolean {
        var wasKind = kind;
        var wasLow = low;
        var wasHigh = high;
        var wasRest = isRest;
        var wasLabel = stepLabel;
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
        return wasKind != kind || wasLow != low || wasHigh != high
            || wasRest != isRest || !stepLabel.equals(wasLabel);
    }

    hidden function readWorkout() as Void {
        var info = Activity.getCurrentWorkoutStep();   // guarded: only called from refresh()'s try
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
                // A recovery step with its own target (a recovery run built
                // as a workout: "Recovery, HR zone 2") is judged; one without
                // (the jog between intervals) stays quiet like a rest.
                if (inten == Activity.WORKOUT_INTENSITY_RECOVERY) {
                    isRest = false;
                }
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
    function setFrom(targetType as Number or Null, lo as Numeric or Null, hi as Numeric or Null,
                     zones as Array<Number> or Null) as Void {
        kind = KIND_NONE;
        if (targetType == null || lo == null || hi == null) {
            return;
        }
        // Floats from here: speed values may arrive as m/s Floats.
        var fl = lo.toFloat();
        var fh = hi.toFloat();
        if (targetType == Activity.WORKOUT_STEP_TARGET_SPEED) {
            if (fl <= 0.0 && fh <= 0.0) {
                return;
            }
            var a = speedValue(fl);
            var b = speedValue(fh);
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
            if (fl > 100.0 || fh > 100.0) {
                low = fl > 100.0 ? fl - 100.0 : fl;
                high = fh > 100.0 ? fh - 100.0 : fh;
            } else if (fl == fh && fl >= 1.0 && fl <= 5.0 && zones != null && zones.size() >= 6) {
                var z = fl.toNumber();
                low = zones[z - 1].toFloat();
                high = zones[z].toFloat();
            } else if (fl > 0.0 && fh > 0.0 && zones != null && zones.size() > 0) {
                var maxHr = zones[zones.size() - 1].toFloat();
                low = maxHr * fl / 100.0;
                high = maxHr * fh / 100.0;
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

    // m/s from a speed target value in mm/s or m/s (see the class comment).
    hidden function speedValue(v as Float) as Float {
        return v >= MMPS_MIN ? v / 1000.0 : v;
    }

    // Instant speed (m/s) under which the runner counts as stopped or
    // walking: 65% of the slow pace bound, or a brisk walk when there is none
    // (open bound, HR target, no target).
    function stopSpeed() as Float {
        return kind == KIND_PACE && low > 0.0 ? low * STOP_FRACTION : STOP_SPEED;
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
