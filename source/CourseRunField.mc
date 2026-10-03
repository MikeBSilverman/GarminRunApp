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
//
// Resume Later reloads data fields, which would restart course distance at
// 0 mid-run, so the run state (RunState) is saved to Application.Storage
// every 3 minutes and when the timer stops, and restored by the first
// compute() of a new instance of the same activity.
class CourseRunField extends WatchUi.DataField {
    hidden const SAMPLE_MS = 2000;
    hidden const BUFFER_SLOTS = 900;   // 30 min of history at 2 s
    hidden const GPS_SLOTS = 64;       // 128 s at 2 s: covers the 120 s smoothing max
    hidden const SPLIT_FLASH_MS = 6000;
    hidden const ALERT_GAP_MS = 15000;
    hidden const SETTLE_MS = 30000;    // no pace verdict for this long after a step starts
    hidden const STATE_KEY = "run";
    hidden const SAVE_EVERY_MS = 180000;   // Resume Later always stops the timer, which saves
    hidden const REFRESH_TICKS = 15;       // poll the workout step; step callbacks cover changes

    hidden var _tracker as CourseTracker;
    hidden var _buf as PaceBuffer;      // course distance: splits, rolling pace
    hidden var _gpsBuf as PaceBuffer;   // GPS distance: the band's current speed
    hidden var _gpsDist as Float = 0.0;
    hidden var _target as WorkoutTarget;
    hidden var _fit as FitRecorder;

    hidden var _timerMs as Number = 0;
    hidden var _lastTimerMs as Number = -1;
    hidden var _running as Boolean = false;   // timer advanced on the last compute
    hidden var _hr as Number or Null = null;
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

    // Start of the current workout step (or of the run): settle period and
    // the step's average pace in the band
    hidden var _stepStartMs as Number = 0;
    hidden var _stepStartDist as Float = 0.0;

    // Resume Later persistence
    hidden var _startSec as Number or Null = null;   // activity start, identifies it
    hidden var _lastSaveMs as Number = 0;

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
        _gpsBuf = new PaceBuffer(GPS_SLOTS, SAMPLE_MS);
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
        _gpsBuf.reset();
        _gpsDist = 0.0;
        _fit.reset();
        _target.status = WorkoutTarget.STATUS_NONE;
        _timerMs = 0;
        _lastTimerMs = -1;
        _running = false;
        _stepStartMs = 0;
        _stepStartDist = 0.0;
        _lapStartMs = 0;
        _lapStartDist = 0.0;
        _lastSplitIdx = 0;
        _splitUntilMs = 0;
        _lastSaveMs = 0;
        _lastAlertStatus = WorkoutTarget.STATUS_NONE;
        _lastAlertMs = -100000;
        clearState();
    }

    function onTimerStop() as Void {
        saveState();
    }

    function onTimerLap() as Void {
        _lapStartMs = _timerMs;
        _lapStartDist = _tracker.courseDist;
        _fit.onLap(_tracker.courseDist);
    }

    function onWorkoutStarted() as Void {
        _target.refresh();
        newStep();
    }

    // The native app starts a new lap at each step but calls only this, not
    // onTimerLap (seen on FR965), so lap distance and lap pace restart here.
    function onWorkoutStepComplete() as Void {
        _target.refresh();
        newStep();
        onTimerLap();
    }

    // A new target: drop the old verdict and give the smoothed speed time to
    // reflect the new effort before judging it.
    hidden function newStep() as Void {
        _stepStartMs = _timerMs;
        _stepStartDist = _tracker.courseDist;
        _target.status = WorkoutTarget.STATUS_NONE;
    }

    // Called once a second by the Run activity, before and after START.
    function compute(info as Activity.Info) as Void {
        var timer = info.timerTime;
        _timerMs = timer != null ? timer : 0;
        _hr = info.currentHeartRate;
        var started = info.startTime;
        _startSec = started != null ? started.value() : null;

        if (_timerMs == 0) {
            // Before START: learn the course length so the lock is right
            // before the gun and the band can say COURSE READY.
            _tracker.preview(info.distanceToDestination);
            _running = false;
        } else if (_lastTimerMs < 0) {
            // First compute of an instance created mid-activity (Resume
            // Later, or the field added during a run): pick up any saved
            // state; the timer may not be running yet, so no update.
            restoreState();
            _running = false;
        } else if (_timerMs != _lastTimerMs) {
            // Timer is running. When it is stopped or paused timerTime does
            // not change, and neither must the course distance, the pace
            // history, or the recorded fields.
            _running = true;
            var gps = info.elapsedDistance;
            _gpsDist = gps != null ? gps : _gpsDist;
            _tracker.update(_gpsDist, info.distanceToDestination);
            _buf.add(_timerMs, _tracker.courseDist);
            _gpsBuf.add(_timerMs, _gpsDist);
            _fit.update(_tracker.courseDist, _timerMs);
            checkSplit();
            if (_timerMs - _lastSaveMs >= SAVE_EVERY_MS) {
                saveState();
            }
        } else {
            _running = false;
        }
        _lastTimerMs = _timerMs;

        // Step callbacks cover transitions; this catches anything missed
        // (e.g. the field added mid-workout).
        _tick++;
        if (_tick % REFRESH_TICKS == 0 && _target.refresh()) {
            newStep();
        }

        var status;
        if (!_running || _target.isRest || _timerMs - _stepStartMs < SETTLE_MS) {
            // Stopped, a rest step, or settling into the step (or the start
            // of the run): no verdict; the band shows the target or step.
            _target.status = WorkoutTarget.STATUS_NONE;
            status = _target.status;
        } else {
            status = _target.evaluate(currentSpeed(), _hr);
        }
        if (_running) {
            _fit.setBand(status);
            maybeAlert(status);
        }
    }

    // ---- Resume Later persistence -----------------------------------------

    hidden function saveState() as Void {
        if (_startSec == null || _timerMs <= 0) {
            return;
        }
        _lastSaveMs = _timerMs;
        var state = new RunState().encode(_startSec as Number, _timerMs, _lapStartMs, _lapStartDist,
                                          _stepStartMs, _stepStartDist, _tracker.snapshot());
        try {
            Application.Storage.setValue(STATE_KEY, state as Array<Application.Storage.ValueType>);
        } catch (e) {
            // Storage full or unavailable: the field still works, it just
            // can't survive Resume Later.
        }
    }

    hidden function clearState() as Void {
        try {
            Application.Storage.deleteValue(STATE_KEY);
        } catch (e) {
        }
    }

    // Carry on from this activity's saved state, if there is any. Anything
    // malformed or from another activity is ignored (RunState.decode,
    // CourseTracker.restore).
    hidden function restoreState() as Void {
        if (_startSec == null) {
            return;
        }
        var stored = null;
        try {
            stored = Application.Storage.getValue(STATE_KEY);
        } catch (e) {
            return;
        }
        var rs = new RunState();
        if (!rs.decode(stored, _startSec as Number, _timerMs) || !_tracker.restore(rs.tracker)) {
            return;
        }
        var cd = _tracker.courseDist;
        _lapStartMs = rs.lapStartMs;
        _lapStartDist = rs.lapStartDist <= cd ? rs.lapStartDist : cd;
        _stepStartMs = rs.stepStartMs;
        _stepStartDist = rs.stepStartDist <= cd ? rs.stepStartDist : cd;
        _lastSplitIdx = (cd / _paceUnit).toNumber();
        _fit.onLap(_lapStartDist);
        _gpsDist = _tracker.lastGps();
        _buf.add(rs.timerMs, cd);
        _gpsBuf.add(rs.timerMs, _gpsDist);
        _lastSaveMs = rs.timerMs;
    }

    // Speed for the band: GPS distance over the smoothing window, scaled to
    // the course's measure by the run's course/GPS ratio. Course distance
    // comes from projecting onto the route, which advances unevenly round
    // bends (30 s course speed was 2.7% noisy on an FR965 run, more than a
    // 10 s/mi band), so it drives the totals but not the instant verdict.
    hidden function currentSpeed() as Float or Null {
        var v = _gpsBuf.smoothedSpeed(_timerMs, _gpsDist, _smoothMs);
        if (v == null) {
            return null;
        }
        var k = 1.0;
        if (_gpsDist > 1000.0 && _tracker.mode == CourseTracker.MODE_COURSE) {
            k = _tracker.courseDist / _gpsDist;
            k = k < 0.95 ? 0.95 : (k > 1.05 ? 1.05 : k);
        }
        return v * k;
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

    // One alert per SLOW DOWN / SPEED UP episode, at most every ALERT_GAP_MS;
    // an episode that starts inside the gap alerts when the gap ends. Called
    // every running tick. Follows the watch's vibration and tone settings.
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
        var ds = System.getDeviceSettings();
        if (ds.vibrateOn && Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(60, 400)] as Array<Attention.VibeProfile>);
        }
        if (ds.tonesOn && Attention has :playTone) {
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

    // "AVG 8:41 · " for the current workout step, once it has 100 m of
    // course distance; empty before that (and for HR targets).
    hidden function stepAvgText() as String {
        var d = _tracker.courseDist - _stepStartDist;
        var t = _timerMs - _stepStartMs;
        if (_target.kind != WorkoutTarget.KIND_PACE || d < 100.0 || t <= 0) {
            return "";
        }
        return "AVG " + Fmt.pace(t / 1000.0 / d * _paceUnit) + " · ";
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
                // The verdict is the last 30 s; the step's average says how
                // the step as a whole is going (lap pace, in effect).
                var avg = stepAvgText();
                var lbl = _target.stepLabel;
                line2 = (avg.length() > 0 ? avg : (lbl.length() > 0 ? lbl + " " : "")) + rangeText();
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
