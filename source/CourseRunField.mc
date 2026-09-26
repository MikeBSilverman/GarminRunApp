import Toybox.Activity;
import Toybox.Application;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Full-screen run field:
//
//   [ status band: ON PACE / SLOW DOWN / SPEED UP + target or ahead/behind ]
//                  course distance (hero)
//            COURSE MI · FIN 1:56:30   (or a split flash for 6 s)
//         course avg pace     |   last mile / last km / lap pace
//              time           |   heart rate
//
// Before START the band reports whether a course is loaded ("COURSE READY").
// Designed for a 1-field data screen; in a smaller slot it draws a compact
// version (course distance on the status colour with a label).
class CourseRunField extends WatchUi.DataField {
    hidden const SAMPLE_MS = 2000;
    hidden const BUFFER_SLOTS = 900;   // 30 min of history at 2 s
    hidden const SPLIT_FLASH_MS = 6000;
    hidden const ALERT_GAP_MS = 15000;

    hidden var _tracker as CourseTracker;
    hidden var _buf as PaceBuffer;
    hidden var _target as WorkoutTarget;
    hidden var _fit as FitRecorder;

    hidden var _timerMs as Number = 0;
    hidden var _lastTimerMs as Number = -1;
    hidden var _running as Boolean = false;   // timer advanced on the last compute
    hidden var _hr as Number or Null = null;
    hidden var _speed as Float or Null = null;
    hidden var _tick as Number = 0;

    // Settings
    hidden var _smoothMs as Number = 30000;
    hidden var _rollingUnit as Number = 0;   // 0 watch units, 1 mile, 2 km, 3 lap
    hidden var _officialLen as Float = 0.0;  // display distance units
    hidden var _showToGo as Boolean = false;
    hidden var _goalSec as Float = 0.0;      // goal pace, seconds per pace unit
    hidden var _goalTolSec as Float = 10.0;
    hidden var _alerts as Number = 1;        // 0 off, 1 goal mode only, 2 always

    // Cached device settings
    hidden var _distUnit as Float = Fmt.M_PER_MI;
    hidden var _paceUnit as Float = Fmt.M_PER_MI;
    hidden var _screenH as Number = 454;

    // Lap pace
    hidden var _lapStartMs as Number = 0;
    hidden var _lapStartDist as Float = 0.0;

    // Split flash
    hidden var _lastSplitIdx as Number = 0;
    hidden var _splitText as String = "";
    hidden var _splitUntilMs as Number = 0;

    // Alerts
    hidden var _lastAlertStatus as Number = 0;
    hidden var _lastAlertMs as Number = -100000;

    function initialize() {
        DataField.initialize();
        _tracker = new CourseTracker();
        _buf = new PaceBuffer(BUFFER_SLOTS, SAMPLE_MS);
        _target = new WorkoutTarget();
        cacheDeviceSettings();
        _fit = new FitRecorder(self, _distUnit);
        loadSettings();
        _target.refresh();
    }

    hidden function cacheDeviceSettings() as Void {
        var ds = System.getDeviceSettings();
        _distUnit = ds.distanceUnits == System.UNIT_METRIC ? Fmt.M_PER_KM : Fmt.M_PER_MI;
        _paceUnit = ds.paceUnits == System.UNIT_METRIC ? Fmt.M_PER_KM : Fmt.M_PER_MI;
        _screenH = ds.screenHeight;
    }

    function loadSettings() as Void {
        cacheDeviceSettings();
        _officialLen = readFloat("courseLength", 0.0);
        var smooth = readFloat("smoothSeconds", 30.0);
        if (smooth < 5.0) {
            smooth = 5.0;
        } else if (smooth > 120.0) {
            smooth = 120.0;
        }
        _smoothMs = (smooth * 1000).toNumber();
        _rollingUnit = readFloat("rollingUnit", 0.0).toNumber();
        _showToGo = readFloat("distanceMode", 0.0).toNumber() == 1;
        _goalTolSec = readFloat("goalTolerance", 10.0);
        _goalSec = Fmt.parsePace(readString("goalPace"));
        _alerts = readFloat("alerts", 1.0).toNumber();

        _tracker.setOfficialLength(_officialLen * _distUnit);
        _target.setGoal(_goalSec, _paceUnit, _goalTolSec);
    }

    hidden function readFloat(key as String, dflt as Float) as Float {
        try {
            var v = Application.Properties.getValue(key);
            if (v instanceof Number || v instanceof Float || v instanceof Double) {
                return v.toFloat();
            }
        } catch (e) {
        }
        return dflt;
    }

    hidden function readString(key as String) as String {
        try {
            var v = Application.Properties.getValue(key);
            if (v instanceof String) {
                return v;
            }
        } catch (e) {
        }
        return "";
    }

    // ---- activity lifecycle -------------------------------------------------

    function onTimerReset() as Void {
        _tracker.reset();
        _buf.reset();
        _fit.reset();
        _target.status = WorkoutTarget.STATUS_NONE;
        _timerMs = 0;
        _lastTimerMs = -1;
        _running = false;
        _lapStartMs = 0;
        _lapStartDist = 0.0;
        _lastSplitIdx = 0;
        _splitUntilMs = 0;
    }

    function onTimerLap() as Void {
        _lapStartMs = _timerMs;
        _lapStartDist = _tracker.courseDist;
        _fit.onLap(_tracker.courseDist);
    }

    function onWorkoutStarted() as Void {
        _target.refresh();
    }

    function onWorkoutStepComplete() as Void {
        _target.refresh();
    }

    // Called once a second by the Run activity, before and after START.
    function compute(info as Activity.Info) as Void {
        var timer = info.timerTime;
        _timerMs = timer != null ? timer : 0;
        _hr = info.currentHeartRate;

        if (_timerMs == 0) {
            // Before START: learn the course length so the lock is right
            // before the gun and the band can say COURSE READY.
            _tracker.preview(info.distanceToDestination);
            _running = false;
        } else if (_timerMs != _lastTimerMs) {
            // Timer is running. When it is stopped or paused timerTime does
            // not change, and neither must the course distance, the pace
            // history, or the recorded fields.
            _running = true;
            var gps = info.elapsedDistance;
            _tracker.update(gps != null ? gps : 0.0, info.distanceToDestination);
            _buf.add(_timerMs, _tracker.courseDist);
            _fit.update(_tracker.courseDist, _timerMs);
            checkSplit();
        } else {
            _running = false;
        }
        _lastTimerMs = _timerMs;

        // Step callbacks cover transitions; this catches anything missed
        // (e.g. the field added mid-workout).
        _tick++;
        if (_tick % 5 == 0) {
            _target.refresh();
        }

        _speed = _running ? _buf.smoothedSpeed(_timerMs, _tracker.courseDist, _smoothMs) : null;
        var prev = _target.status;
        var status = _target.evaluate(_speed, _hr);
        if (_running && status != prev) {
            maybeAlert(status);
        }
    }

    hidden function checkSplit() as Void {
        var idx = (_tracker.courseDist / _paceUnit).toNumber();
        if (idx <= _lastSplitIdx) {
            return;
        }
        var startT = _buf.timeAtDistance((idx - 1) * _paceUnit);
        if (startT != null) {
            var split = (_timerMs - startT) / 1000.0;
            _splitText = (_paceUnit == Fmt.M_PER_MI ? "MI " : "KM ") + idx.toString()
                         + "  " + Fmt.pace(split);
            _splitUntilMs = _timerMs + SPLIT_FLASH_MS;
        }
        _lastSplitIdx = idx;
    }

    hidden function maybeAlert(status as Number) as Void {
        var goal = _target.source == WorkoutTarget.SOURCE_GOAL;
        if (_alerts == 0 || (_alerts == 1 && !goal)) {
            return;
        }
        if (status != WorkoutTarget.STATUS_FAST && status != WorkoutTarget.STATUS_SLOW) {
            _lastAlertStatus = status;
            return;
        }
        if (status == _lastAlertStatus || _timerMs - _lastAlertMs < ALERT_GAP_MS) {
            return;
        }
        _lastAlertStatus = status;
        _lastAlertMs = _timerMs;
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(60, 400)] as Array<Attention.VibeProfile>);
        }
        if (Attention has :playTone) {
            Attention.playTone(status == WorkoutTarget.STATUS_FAST
                               ? Attention.TONE_ALERT_HI : Attention.TONE_ALERT_LO);
        }
    }

    // ---- derived values ----------------------------------------------------

    hidden function rollingWindowM() as Float {
        if (_rollingUnit == 1) {
            return Fmt.M_PER_MI;
        }
        if (_rollingUnit == 2) {
            return Fmt.M_PER_KM;
        }
        return _paceUnit;
    }

    // Hero distance in metres and whether it is distance-to-go.
    hidden function heroMeters() as [Float, Boolean] {
        if (_showToGo) {
            var r = _tracker.remainingMeters();
            if (r != null) {
                return [r, true];
            }
        }
        return [_tracker.courseDist, false];
    }

    hidden function avgSecPerMeter() as Float or Null {
        var cd = _tracker.courseDist;
        if (cd > 10.0 && _timerMs > 0) {
            return _timerMs / 1000.0 / cd;
        }
        return null;
    }

    // Projected finish (timer ms) from remaining course distance and a blend
    // of average and recent pace. Null without a course or early in the run.
    hidden function projectedFinishMs() as Number or Null {
        var rem = _tracker.remainingMeters();
        var avg = avgSecPerMeter();
        if (rem == null || avg == null || _tracker.courseDist < 400.0) {
            return null;
        }
        var spm = avg;
        var roll = _buf.rollingSecPerMeter(_timerMs, _tracker.courseDist, rollingWindowM());
        if (roll != null) {
            spm = (avg + roll) / 2.0;
        }
        return _timerMs + (rem * spm * 1000.0).toNumber();
    }

    // Seconds ahead (negative) or behind (positive) the goal pace.
    hidden function goalDeltaSec() as Float or Null {
        var gs = _target.goalSpeed();
        if (gs <= 0.0 || _tracker.courseDist < 50.0) {
            return null;
        }
        return _timerMs / 1000.0 - _tracker.courseDist / gs;
    }

    // ---- band text ---------------------------------------------------------

    hidden function statusWords(status as Number) as String {
        var hr = _target.kind == WorkoutTarget.KIND_HR;
        if (status == WorkoutTarget.STATUS_ON) {
            return hr ? "HR OK" : "ON PACE";
        }
        if (status == WorkoutTarget.STATUS_FAST) {
            return hr ? "HR HIGH" : "SLOW DOWN";
        }
        if (status == WorkoutTarget.STATUS_SLOW) {
            return hr ? "HR LOW" : "SPEED UP";
        }
        if (hr) {
            return _hr == null ? "NO HR" : "HR TARGET";
        }
        return "TARGET";
    }

    hidden function rangeText() as String {
        if (_target.kind == WorkoutTarget.KIND_PACE) {
            var fast = Fmt.paceFromSpeed(_target.high, _paceUnit);
            var slow = Fmt.paceFromSpeed(_target.low, _paceUnit);
            if (_target.openLow()) {
                return "FASTER THAN " + fast;
            }
            if (_target.openHigh()) {
                return "SLOWER THAN " + slow;
            }
            return fast + "-" + slow;
        }
        if (_target.kind == WorkoutTarget.KIND_HR) {
            return _target.low.toNumber().toString() + "-" + _target.high.toNumber().toString() + " BPM";
        }
        return "";
    }

    hidden function goalLine() as String {
        var d = goalDeltaSec();
        if (d == null) {
            return "GOAL " + Fmt.pace(_goalSec);
        }
        var dd = d as Float;
        if (dd > -1.0 && dd < 1.0) {
            return "ON GOAL";
        }
        return (dd < 0.0 ? "AHEAD " : "BEHIND ") + Fmt.pace(dd < 0.0 ? -dd : dd);
    }

    hidden function statusColor(status as Number) as Number {
        if (status == WorkoutTarget.STATUS_ON) {
            return Graphics.COLOR_DK_GREEN;
        }
        if (status == WorkoutTarget.STATUS_FAST) {
            return Graphics.COLOR_RED;
        }
        return Graphics.COLOR_DK_BLUE;
    }

    // ---- drawing -----------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var bg = getBackgroundColor();
        var fg = bg == Graphics.COLOR_BLACK ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var dim = bg == Graphics.COLOR_BLACK ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_DK_GRAY;

        dc.setColor(fg, bg);
        dc.clear();

        var hero = heroMeters();
        var status = _target.status;

        if (h < _screenH * 3 / 4) {
            drawCompact(dc, w, h, fg, dim, status, hero[0]);
            return;
        }

        var cx = w / 2;
        var vc = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

        drawBand(dc, w, h, dim, status);

        // Hero.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, Layout.pct(h, 39), Layout.heroFont(h), Fmt.dist(hero[0], _distUnit), vc);

        // Label line under the hero: split flash, or mode + projected finish.
        var unit = _distUnit == Fmt.M_PER_MI ? " MI" : " KM";
        var label;
        var labelColor = dim;
        if (_splitUntilMs > _timerMs && _timerMs > 0) {
            label = _splitText;
            labelColor = fg;
        } else {
            if (hero[1]) {
                label = "TO GO" + unit;
            } else if (_tracker.mode == CourseTracker.MODE_COURSE) {
                label = "COURSE" + unit;
            } else if (_tracker.mode == CourseTracker.MODE_OFF) {
                label = "OFF COURSE" + unit;
                labelColor = Graphics.COLOR_ORANGE;
            } else {
                label = "GPS" + unit;
            }
            var fin = projectedFinishMs();
            if (fin != null) {
                label = label + " · FIN " + Fmt.timer(fin);
            }
        }
        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, Layout.pct(h, 53), Layout.labelFont(), label, vc);

        // Row 2: course average pace | rolling / lap pace.
        var avg = avgSecPerMeter();
        var lx = Layout.pct(w, 30);
        var rx = Layout.pct(w, 70);
        var rightLabel;
        var rightSpm = null;
        if (_rollingUnit == 3) {
            rightLabel = "LAP PACE";
            var ld = _tracker.courseDist - _lapStartDist;
            if (ld > 10.0 && _timerMs > _lapStartMs) {
                rightSpm = (_timerMs - _lapStartMs) / 1000.0 / ld;
            }
        } else {
            var rollM = rollingWindowM();
            rightLabel = rollM == Fmt.M_PER_MI ? "LAST MI" : "LAST KM";
            rightSpm = _buf.rollingSecPerMeter(_timerMs, _tracker.courseDist, rollM);
        }

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, Layout.pct(h, 61), Layout.valueFont(h),
                    Fmt.pace(avg != null ? avg * _paceUnit : null), vc);
        if (rightSpm != null) {
            dc.drawText(rx, Layout.pct(h, 61), Layout.valueFont(h), Fmt.pace(rightSpm * _paceUnit), vc);
        } else {
            // Before a full window is covered, show the average so far, dimmed.
            dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rx, Layout.pct(h, 61), Layout.valueFont(h),
                        Fmt.pace(avg != null ? avg * _paceUnit : null), vc);
            if (_rollingUnit != 3) {
                rightLabel = "AVG (1ST)";
            }
        }
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, Layout.pct(h, 69), Layout.labelFont(),
                    _tracker.mode == CourseTracker.MODE_COURSE ? "COURSE AVG" : "AVG PACE", vc);
        dc.drawText(rx, Layout.pct(h, 69), Layout.labelFont(), rightLabel, vc);
        dc.drawLine(cx, Layout.pct(h, 57), cx, Layout.pct(h, 90));

        // Row 3: timer | heart rate.
        var tx = Layout.pct(w, 34);
        var hx = Layout.pct(w, 66);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, Layout.pct(h, 79), Layout.rowFont(h), Fmt.timer(_timerMs), vc);
        dc.drawText(hx, Layout.pct(h, 79), Layout.rowFont(h), _hr != null ? _hr.toString() : "--", vc);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, Layout.pct(h, 87), Layout.labelFont(), "TIME", vc);
        dc.drawText(hx, Layout.pct(h, 87), Layout.labelFont(), "HR", vc);
    }

    hidden function drawBand(dc as Graphics.Dc, w as Number, h as Number, dim as Number,
                             status as Number) as Void {
        var cx = w / 2;
        var vc = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        var line1;
        var line2 = "";
        var fill = null;
        var textColor = dim;

        if (_timerMs == 0) {
            // Before START: is the course loaded?
            if (!_tracker.hasCourse()) {
                line1 = "NO COURSE";
                line2 = "NAVIGATION > COURSES";
                textColor = Graphics.COLOR_ORANGE;
            } else if (_tracker.lengthMismatch) {
                line1 = "CHECK LENGTH";
                line2 = Fmt.dist(_tracker.loadedLengthMeters() as Float, _distUnit)
                        + " LOADED, " + Fmt.dist(_officialLen * _distUnit, _distUnit) + " SET";
                textColor = Graphics.COLOR_ORANGE;
            } else {
                line1 = "COURSE READY";
                line2 = Fmt.dist(_tracker.lengthMeters() as Float, _distUnit)
                        + (_distUnit == Fmt.M_PER_MI ? " MI" : " KM");
                textColor = Graphics.COLOR_DK_GREEN;
            }
        } else if (_target.isRest) {
            line1 = _target.stepLabel;
        } else if (_target.kind == WorkoutTarget.KIND_NONE) {
            line1 = _target.hasWorkout ? "NO TARGET" : "NO GOAL SET";
            line2 = _target.stepLabel;
        } else if (status == WorkoutTarget.STATUS_NONE) {
            line1 = statusWords(status);
            line2 = rangeText();
        } else {
            fill = statusColor(status);
            textColor = Graphics.COLOR_WHITE;
            line1 = statusWords(status);
            if (_target.source == WorkoutTarget.SOURCE_GOAL) {
                line2 = goalLine();
            } else {
                var lbl = _target.stepLabel;
                line2 = (lbl.length() > 0 ? lbl + " " : "") + rangeText();
            }
        }

        if (fill != null) {
            dc.setColor(fill, fill);
            dc.fillRectangle(0, 0, w, Layout.pct(h, 28));
        }
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        if (line2.length() > 0) {
            dc.drawText(cx, Layout.pct(h, 16), Layout.bandFont(h), line1, vc);
            dc.drawText(cx, Layout.pct(h, 23), Layout.labelFont(), line2, vc);
        } else {
            dc.drawText(cx, Layout.pct(h, 18), Layout.bandFont(h), line1, vc);
        }
    }

    // Smaller slot (the field was added to a 2+ field layout): course
    // distance on the status colour with a label.
    hidden function drawCompact(dc as Graphics.Dc, w as Number, h as Number, fg as Number,
                                dim as Number, status as Number, meters as Float) as Void {
        var textColor = fg;
        var labelColor = dim;
        if (_timerMs > 0 && status != WorkoutTarget.STATUS_NONE && !_target.isRest) {
            var fill = statusColor(status);
            dc.setColor(fill, fill);
            dc.fillRectangle(0, 0, w, h);
            textColor = Graphics.COLOR_WHITE;
            labelColor = Graphics.COLOR_WHITE;
        }
        var unit = _distUnit == Fmt.M_PER_MI ? " MI" : " KM";
        var label;
        if (_timerMs == 0) {
            label = _tracker.hasCourse() ? "COURSE READY" : "NO COURSE";
        } else if (_tracker.mode == CourseTracker.MODE_COURSE) {
            label = "COURSE" + unit;
        } else if (_tracker.mode == CourseTracker.MODE_OFF) {
            label = "OFF COURSE" + unit;
            labelColor = Graphics.COLOR_ORANGE;
        } else {
            label = "GPS" + unit;
        }
        var cx = w / 2;
        var vc = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 42 / 100, Graphics.FONT_NUMBER_MILD, Fmt.dist(meters, _distUnit), vc);
        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 82 / 100, Graphics.FONT_XTINY, label, vc);
    }
}
