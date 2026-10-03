import Toybox.Lang;

// What survives Resume Later. The watch reloads data fields when a
// suspended activity resumes, so CourseRunField saves this to
// Application.Storage and loads it back into the new instance.
//
// Stored as a plain array, tagged with a format version and the activity's
// start time (seconds since the epoch, from Activity.Info.startTime) so
// state from another activity or an older build is never applied:
//   [VER, startSec, timerMs, lapStartMs, lapStartDist, stepStartMs, stepStartDist, tracker]
// where tracker is CourseTracker.snapshot(), validated by CourseTracker.restore().
class RunState {
    hidden const VER = 2;

    var timerMs as Number = 0;
    var lapStartMs as Number = 0;
    var lapStartDist as Float = 0.0;
    var stepStartMs as Number = 0;
    var stepStartDist as Float = 0.0;
    var tracker as Object or Null = null;

    function initialize() {
    }

    function encode(startSec as Number, timer as Number, lapMs as Number, lapDist as Float,
                    stepMs as Number, stepDist as Float, trackerSnap as Array<Float or Number>) as Array {
        return [VER, startSec, timer, lapMs, lapDist, stepMs, stepDist, trackerSnap];
    }

    // Loads a stored value. False unless it has this format, belongs to the
    // activity that started at `startSec`, and was saved no later than
    // `nowMs` of timer time. Lap and step marks are clamped into [0, saved
    // timer]; the tracker part is left for CourseTracker.restore().
    function decode(s as Object or Null, startSec as Number, nowMs as Number) as Boolean {
        if (!(s instanceof Array) || s.size() != 8) {
            return false;
        }
        var ver = s[0];
        var start = s[1];
        var t = s[2];
        var lapMs = s[3];
        var lapDist = s[4];
        var stepMs = s[5];
        var stepDist = s[6];
        if (!(ver instanceof Number) || ver != VER
            || !(start instanceof Number) || start != startSec
            || !(t instanceof Number) || t <= 0 || t > nowMs
            || !(lapMs instanceof Number) || !(stepMs instanceof Number)
            || !(lapDist instanceof Float || lapDist instanceof Number)
            || !(stepDist instanceof Float || stepDist instanceof Number)) {
            return false;
        }
        var ld = (lapDist as Float or Number).toFloat();
        var sd = (stepDist as Float or Number).toFloat();
        timerMs = t;
        lapStartMs = lapMs >= 0 && lapMs <= t ? lapMs : t;
        // NaN != NaN; and in Monkey C NaN >= 0.0 is true, so test it first.
        lapStartDist = ld != ld || ld < 0.0 || ld > 1.0e6 ? 0.0 : ld;
        stepStartMs = stepMs >= 0 && stepMs <= t ? stepMs : 0;
        stepStartDist = sd != sd || sd < 0.0 || sd > 1.0e6 ? 0.0 : sd;
        tracker = s[7] as Object or Null;
        return true;
    }
}
