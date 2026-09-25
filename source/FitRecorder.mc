import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.WatchUi;

// Writes course distance and course pace into the activity FIT file as
// Connect IQ developer fields. Garmin Connect shows them on the activity
// (chart, laps, summary); Strava ignores developer fields. The activity's own
// distance is never changed.
//
// Garmin Connect's labels and units come from resources/fit/fit_contributions.xml
// and are fixed at build time, so there are two field sets (miles, km) and
// only the one matching the watch's units at activity start is created.
class FitRecorder {
    // Field ids must match fit_contributions.xml.
    hidden const MI_BASE = 0;
    hidden const KM_BASE = 4;

    hidden var _record as FitContributor.Field or Null = null;   // course distance over time
    hidden var _lap as FitContributor.Field or Null = null;      // course distance this lap
    hidden var _dist as FitContributor.Field or Null = null;     // session course distance
    hidden var _pace as FitContributor.Field or Null = null;     // session course pace, decimal min
    hidden var _unitM as Float;
    hidden var _lapStart as Float = 0.0;

    function initialize(field as WatchUi.DataField, unitM as Float) {
        _unitM = unitM;
        var km = unitM == Fmt.M_PER_KM;
        var base = km ? KM_BASE : MI_BASE;
        var u = km ? "km" : "mi";
        try {
            _record = field.createField("course_dist", base, FitContributor.DATA_TYPE_FLOAT,
                {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => u});
            _lap = field.createField("lap_course_dist", base + 1, FitContributor.DATA_TYPE_FLOAT,
                {:mesgType => FitContributor.MESG_TYPE_LAP, :units => u});
            _dist = field.createField("total_course_dist", base + 2, FitContributor.DATA_TYPE_FLOAT,
                {:mesgType => FitContributor.MESG_TYPE_SESSION, :units => u});
            _pace = field.createField("course_pace", base + 3, FitContributor.DATA_TYPE_FLOAT,
                {:mesgType => FitContributor.MESG_TYPE_SESSION, :units => "min/" + u});
        } catch (e) {
            // Recording is a bonus; the screen works without it.
        }
    }

    function reset() as Void {
        _lapStart = 0.0;
    }

    // New lap started: lap course distance counts from here.
    function onLap(courseDist as Float) as Void {
        _lapStart = courseDist;
    }

    // Called every compute() while the timer runs.
    function update(courseDist as Float, timerMs as Number) as Void {
        var d = courseDist / _unitM;
        if (_record != null) {
            _record.setData(d);
        }
        if (_lap != null) {
            var l = (courseDist - _lapStart) / _unitM;
            _lap.setData(l > 0.0 ? l : 0.0);
        }
        if (_dist != null) {
            _dist.setData(d);
        }
        if (_pace != null && courseDist > 10.0 && timerMs > 0) {
            _pace.setData(timerMs / 60000.0 / d);
        }
    }
}
