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
//            COURSE MI · FIN 1:56:30   (or a split flash for 6 s, or GEL n)
//         course avg pace     |   last mile / last km / lap pace
//              time   |   heart rate   |   cadence
//
// In a workout row 2 is STEP AVG | LAST 30S and the time is the step's
// (LEFT or STEP); see CLAUDE.md for the positions.
//
// Before START the band reports whether a course is loaded ("COURSE READY"),
// or TREADMILL in the Treadmill profile, where there is none.
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
    hidden const ALERT_HOLD_MS = 10000;   // a verdict must last this long before it buzzes
    hidden const STOP_TICKS = 3;          // seconds below the stop speed that make a stop
    hidden const SETTLE_MS = 30000;    // no pace verdict for this long after a step starts
    hidden const HR_SETTLE_MS = 120000;   // heart rate lags effort: HR targets settle longer
    hidden const STATE_KEY = "run";
    hidden const SAVE_EVERY_MS = 180000;   // Resume Later always stops the timer, which saves
    hidden const REFRESH_TICKS = 15;       // poll the workout step; step callbacks cover changes
    hidden const LONG_AGO_MS = -1000000;   // "never" for last-alert and last-stop times
    hidden const MIN_SPEED_MS = 5000;      // a step this young has too little to read a speed from
    hidden const RATIO_MIN_GPS_M = 1000.0; // GPS this far before the course/GPS ratio is trusted
    hidden const RATIO_MIN = 0.95;         // course/GPS ratio clamp
    hidden const RATIO_MAX = 1.05;
    hidden const PROJECT_MIN_M = 400.0;    // course covered before projecting a finish
    hidden const GOAL_GAP_MIN_M = 50.0;    // course covered before ahead/behind

    hidden var _tracker as CourseTracker;
    hidden var _buf as PaceBuffer;      // course distance: splits, rolling pace
    hidden var _gpsBuf as PaceBuffer;   // GPS distance: the band's current speed
    hidden var _gpsDist as Float = 0.0;
    hidden var _target as WorkoutTarget;
    hidden var _gel as GelReminder;
    hidden var _fit as FitRecorder;

    hidden var _timerMs as Number = 0;
    hidden var _lastTimerMs as Number = -1;
    hidden var _running as Boolean = false;   // timer advanced on the last compute
    hidden var _hr as Number or Null = null;
    hidden var _cadence as Number or Null = null;
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
    hidden var _unitText as String = " MI";    // distance unit, after a number
    hidden var _paceText as String = "MI ";    // pace unit, before a split number
    hidden var _screenH as Number = 454;
    hidden var _treadmill as Boolean = false;   // Treadmill profile: no course, wrist distance

    // Start of the current workout step (or of the run): settle period,
    // STEP AVG, LAST 30S and the step timer
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
    hidden var _lastAlertMs as Number = LONG_AGO_MS;
    hidden var _statusSinceMs as Number = 0;   // when the band's verdict last changed

    // Stops (traffic lights, walk breaks) with the timer running
    hidden var _slowTicks as Number = 0;
    hidden var _stopMs as Number = LONG_AGO_MS;   // last running tick spent stopped

    function initialize() {
        DataField.initialize();
        _tracker = new CourseTracker();
        _buf = new PaceBuffer(BUFFER_SLOTS, SAMPLE_MS);
        _gpsBuf = new PaceBuffer(GPS_SLOTS, SAMPLE_MS);
        _target = new WorkoutTarget();
        _gel = new GelReminder();
        _treadmill = isTreadmill();
        cacheDeviceSettings();
        _fit = new FitRecorder(self, _distUnit);
        loadSettings();
    }

    hidden function cacheDeviceSettings() as Void {
        var ds = System.getDeviceSettings();
        var kmDist = ds.distanceUnits == System.UNIT_METRIC;
        var kmPace = ds.paceUnits == System.UNIT_METRIC;
        _distUnit = kmDist ? Fmt.M_PER_KM : Fmt.M_PER_MI;
        _paceUnit = kmPace ? Fmt.M_PER_KM : Fmt.M_PER_MI;
        _unitText = kmDist ? " KM" : " MI";
        _paceText = kmPace ? "KM " : "MI ";
        _screenH = ds.screenHeight;
    }

    function loadSettings() as Void {
        cacheDeviceSettings();
        _officialLen = Props.num("courseLength", 0.0);
        var smooth = Props.num("smoothSeconds", 30.0);
        if (smooth < 5.0) {
            smooth = 5.0;
        } else if (smooth > 120.0) {
            smooth = 120.0;
        }
        _smoothMs = (smooth * 1000).toNumber();
        _rollingUnit = Props.num("rollingUnit", 0.0).toNumber();
        _showToGo = Props.num("distanceMode", 0.0).toNumber() == 1;
        _goalTolSec = Props.num("goalTolerance", 10.0);
        _goalSec = Fmt.parsePace(Props.str("goalPace"));
        _alerts = Props.num("alerts", 1.0).toNumber();
        _gel.setTimes(Props.num("gelFirst", 0.0).toNumber(), Props.num("gelEvery", 30.0).toNumber());

        _tracker.setOfficialLength(_officialLen * _distUnit);
        if (_target.setGoals(_goalSec, _paceUnit, _goalTolSec, Props.str("goalHr"))) {
            // A new goal mid-run: judge it afresh, after the settle period.
            newStep();
        }
    }

    // The activity profile is fixed for the field's life, so this is read once.
    hidden function isTreadmill() as Boolean {
        if (Activity has :getProfileInfo) {
            try {
                var p = Activity.getProfileInfo();
                return p != null && p.subSport == Activity.SUB_SPORT_TREADMILL;
            } catch (e) {
            }
        }
        return false;
    }

    // ---- activity lifecycle -------------------------------------------------

    function onTimerReset() as Void {
        _tracker.reset();
        _buf.reset();
        _gpsBuf.reset();
        _gpsDist = 0.0;
        _fit.reset();
        _target.clearStatus();
        _timerMs = 0;
        _lastTimerMs = -1;
        _running = false;
        _stepStartMs = 0;
        _stepStartDist = 0.0;
        _lapStartMs = 0;
        _lapStartDist = 0.0;
        _lastSplitIdx = 0;
        _splitUntilMs = 0;
        _gel.reset();
        _lastSaveMs = 0;
        _lastAlertStatus = WorkoutTarget.STATUS_NONE;
        _lastAlertMs = LONG_AGO_MS;
        _statusSinceMs = 0;
        _slowTicks = 0;
        _stopMs = LONG_AGO_MS;
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
        _target.clearStatus();
    }

    // Called once a second by the Run activity, before and after START.
    function compute(info as Activity.Info) as Void {
        var timer = info.timerTime;
        _timerMs = timer != null ? timer : 0;
        _hr = info.currentHeartRate;
        _cadence = info.currentCadence;
        var started = info.startTime;
        _startSec = started != null ? started.value() : null;

        _running = false;
        if (_timerMs == 0) {
            // Before START: learn the course length so the lock is right
            // before the gun and the band can say COURSE READY.
            _tracker.preview(info.distanceToDestination);
        } else if (_lastTimerMs < 0) {
            // First compute of an instance created mid-activity (Resume
            // Later, or the field added during a run): pick up any saved
            // state; the timer may not be running yet, so no update.
            restoreState();
        } else if (_timerMs != _lastTimerMs) {
            // Timer is running. When it is stopped or paused timerTime does
            // not change, and neither must the course distance, the pace
            // history, or the recorded fields.
            _running = true;
            runningTick(info);
        }
        _lastTimerMs = _timerMs;

        // Step callbacks cover transitions; this catches anything missed
        // (e.g. the field added mid-workout).
        _tick++;
        if (_tick % REFRESH_TICKS == 0 && _target.refresh()) {
            newStep();
        }

        judge();
    }

    hidden function runningTick(info as Activity.Info) as Void {
        var gps = info.elapsedDistance;
        _gpsDist = gps != null ? gps : _gpsDist;
        _tracker.update(_gpsDist, info.distanceToDestination);
        _buf.add(_timerMs, _tracker.courseDist);
        _gpsBuf.add(_timerMs, _gpsDist);
        _fit.update(_tracker.courseDist, _timerMs);
        trackStop(info.currentSpeed);
        checkSplit();
        checkGel();
        if (_timerMs - _lastSaveMs >= SAVE_EVERY_MS) {
            saveState();
        }
    }

    // A gel is due: buzz, and push the full-screen alert over whichever data
    // page is showing; the pill on this page stays for the minute either way.
    hidden function checkGel() as Void {
        if (!_gel.check(_timerMs)) {
            return;
        }
        buzz(Attention.TONE_ALERT_HI);
        if (self has :showAlert) {
            try {
                showAlert(new GelAlert(_gel.count));
            } catch (e) {
            }
        }
    }

    // The band's verdict for this second, recorded and alerted on while running.
    hidden function judge() as Void {
        var was = _target.status;
        var settle = _target.kind == WorkoutTarget.KIND_HR ? HR_SETTLE_MS : SETTLE_MS;
        if (!_running || _target.isRest || _timerMs - _stepStartMs < settle
            || _timerMs - _stopMs < _smoothMs) {
            // Paused, a rest step, settling into the step (or the start of
            // the run), or stopped with the timer running and until the stop
            // has left the smoothing window: no verdict; the band shows the
            // target or step.
            _target.clearStatus();
        } else {
            _target.evaluate(currentSpeed(), _hr);
        }
        var status = _target.status;
        if (status != was) {
            _statusSinceMs = _timerMs;
        }
        if (_running) {
            _fit.setBand(status);
            maybeAlert(status);
        }
    }

    // A stop with the timer running (a light, a walk break): the watch's
    // instant speed under WorkoutTarget.stopSpeed() for STOP_TICKS seconds.
    // Without this the band said SPEED UP at every light and for 30 s after,
    // while the stop was still in the smoothed speed.
    hidden function trackStop(speed as Float or Null) as Void {
        if (speed != null && speed < _target.stopSpeed()) {
            _slowTicks++;
            if (_slowTicks >= STOP_TICKS) {
                _stopMs = _timerMs;
            }
        } else {
            _slowTicks = 0;
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
        _gel.skipTo(_timerMs);
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
        return scaledGpsSpeed(_smoothMs);
    }

    // The band's speed clipped to the current workout step (LAST 30S): the
    // smoothing window, or the time in the step when that is shorter, so the
    // number starts fresh with each step and never includes the recovery
    // before it. Null in the first 5 s (too little to read anything from).
    hidden function stepSpeed() as Float or Null {
        var inStep = _timerMs - _stepStartMs;
        if (inStep < MIN_SPEED_MS) {
            return null;
        }
        var v = scaledGpsSpeed(inStep < _smoothMs ? inStep : _smoothMs);
        return v != null && v > 0.0 ? v : null;
    }

    hidden function scaledGpsSpeed(windowMs as Number) as Float or Null {
        var v = _gpsBuf.smoothedSpeed(_timerMs, _gpsDist, windowMs);
        if (v == null) {
            return null;
        }
        var k = 1.0;
        if (_gpsDist > RATIO_MIN_GPS_M && _tracker.mode == CourseTracker.MODE_COURSE) {
            k = _tracker.courseDist / _gpsDist;
            k = k < RATIO_MIN ? RATIO_MIN : (k > RATIO_MAX ? RATIO_MAX : k);
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
            _splitText = _paceText + idx.toString()
                         + "  " + Fmt.pace(split);
            _splitUntilMs = _timerMs + SPLIT_FLASH_MS;
        }
        _lastSplitIdx = idx;
    }

    // One alert per SLOW DOWN / SPEED UP episode, once it has lasted
    // ALERT_HOLD_MS (slowing for a light, a brief surge), at most every
    // ALERT_GAP_MS; an episode that starts inside the gap alerts when the gap
    // ends. Called every running tick.
    hidden function maybeAlert(status as Number) as Void {
        var goal = _target.source == WorkoutTarget.SOURCE_GOAL;
        if (_alerts == 0 || (_alerts == 1 && !goal)) {
            return;
        }
        if (status != WorkoutTarget.STATUS_FAST && status != WorkoutTarget.STATUS_SLOW) {
            _lastAlertStatus = status;
            return;
        }
        if (status == _lastAlertStatus || _timerMs - _lastAlertMs < ALERT_GAP_MS
            || _timerMs - _statusSinceMs < ALERT_HOLD_MS) {
            return;
        }
        _lastAlertStatus = status;
        _lastAlertMs = _timerMs;
        buzz(status == WorkoutTarget.STATUS_FAST ? Attention.TONE_ALERT_HI : Attention.TONE_ALERT_LO);
    }

    // Follows the watch's vibration and tone settings.
    hidden function buzz(tone as Attention.Tone) as Void {
        var ds = System.getDeviceSettings();
        if (ds.vibrateOn && Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(60, 400)] as Array<Attention.VibeProfile>);
        }
        if (ds.tonesOn && Attention has :playTone) {
            Attention.playTone(tone);
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

    // Distance to go in metres when the big number shows it, else null.
    hidden function toGoMeters() as Float or Null {
        return _showToGo ? _tracker.remainingMeters() : null;
    }

    hidden function avgSecPerMeter() as Float or Null {
        return Fmt.secPerMeter(_timerMs, _tracker.courseDist);
    }

    // Projected finish (timer ms) from remaining course distance and a blend
    // of average and recent pace. Null without a course or early in the run.
    hidden function projectedFinishMs() as Number or Null {
        var rem = _tracker.remainingMeters();
        var avg = avgSecPerMeter();
        if (rem == null || avg == null || _tracker.courseDist < PROJECT_MIN_M) {
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
        if (gs <= 0.0 || _tracker.courseDist < GOAL_GAP_MIN_M) {
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
            var hi = _target.high.toNumber().toString();
            return _target.low > 0.0 ? _target.low.toNumber().toString() + "-" + hi + " BPM" : "UNDER " + hi + " BPM";
        }
        return "";
    }

    // A workout is running: row 2 and the row 3 timer follow the step.
    hidden function inWorkout() as Boolean {
        return _target.hasWorkout && _timerMs > 0;
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

    // Hero label for the distance mode ("COURSE MI"); orange when off course.
    hidden function modeLabel() as String {
        if (_tracker.mode == CourseTracker.MODE_COURSE) {
            return "COURSE" + _unitText;
        }
        if (_tracker.mode == CourseTracker.MODE_OFF) {
            return "OFF COURSE" + _unitText;
        }
        return (_treadmill ? "TREADMILL" : "GPS") + _unitText;
    }

    hidden function modeColor(normal as Number) as Number {
        return _tracker.mode == CourseTracker.MODE_OFF ? Graphics.COLOR_ORANGE : normal;
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

        var toGo = toGoMeters();
        var hero = toGo != null ? toGo : _tracker.courseDist;
        var status = _target.status;

        if (h < _screenH * 3 / 4) {
            drawCompact(dc, w, h, fg, dim, status, hero);
            return;
        }

        drawBand(dc, w, h, dim, status);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, Layout.pct(h, Layout.HERO_Y), Layout.heroFont(h), Fmt.dist(hero, _distUnit), Layout.VCENTER);
        drawHeroLabel(dc, w, h, fg, dim, toGo != null);
        var workout = inWorkout();
        drawRow2(dc, w, h, fg, dim, workout);
        drawRow3(dc, w, h, fg, dim, workout);
    }

    // Under the hero: a split flash, a gel reminder, or mode + projected finish.
    hidden function drawHeroLabel(dc as Graphics.Dc, w as Number, h as Number, fg as Number,
                                  dim as Number, toGo as Boolean) as Void {
        var cx = w / 2;
        var y = Layout.pct(h, Layout.LABEL_Y);
        var label;
        var color = dim;
        if (_gel.showing(_timerMs)) {
            // Black on an orange pill for a minute, over the split flash too
            // (the watch's own lap screen shows the split).
            label = "GEL " + _gel.count.toString();
            Layout.drawPill(dc, cx, y, label, Layout.labelFont(), Layout.pct(w, 8), Graphics.COLOR_ORANGE);
            color = Graphics.COLOR_BLACK;
        } else if (_splitUntilMs > _timerMs && _timerMs > 0) {
            label = _splitText;
            color = fg;
        } else {
            label = toGo ? "TO GO" + _unitText : modeLabel();
            color = toGo ? dim : modeColor(dim);
            var fin = projectedFinishMs();
            if (fin != null) {
                label = label + " · FIN " + Fmt.timer(fin);
            }
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Layout.labelFont(), label, Layout.VCENTER);
    }

    // Row 2: course average pace | rolling / lap pace. In a workout the
    // overall average is no use, so the left is the step's average on course
    // distance (the rep split) and the right the pace behind the band (last
    // 30 s by default), restarted at each step: a distance window never fills
    // on short reps and would span the recovery.
    hidden function drawRow2(dc as Graphics.Dc, w as Number, h as Number, fg as Number,
                             dim as Number, workout as Boolean) as Void {
        var avg = avgSecPerMeter();
        var leftLabel = _tracker.mode == CourseTracker.MODE_COURSE ? "COURSE AVG" : "AVG PACE";
        var leftSpm = avg;
        var rightLabel;
        var rightSpm = null;
        if (workout) {
            leftLabel = "STEP AVG";
            leftSpm = Fmt.secPerMeter(_timerMs - _stepStartMs, _tracker.courseDist - _stepStartDist);
            rightLabel = "LAST " + (_smoothMs / 1000).toString() + "S";
            var sv = stepSpeed();
            rightSpm = sv != null ? 1.0 / sv : null;
        } else if (_rollingUnit == 3) {
            rightLabel = "LAP PACE";
            rightSpm = Fmt.secPerMeter(_timerMs - _lapStartMs, _tracker.courseDist - _lapStartDist);
        } else {
            var rollM = rollingWindowM();
            rightLabel = rollM == Fmt.M_PER_MI ? "LAST MI" : "LAST KM";
            rightSpm = _buf.rollingSecPerMeter(_timerMs, _tracker.courseDist, rollM);
        }
        var rightColor = fg;
        if (rightSpm == null && !workout) {
            // Before a full window is covered, show the average so far, dimmed.
            rightSpm = avg;
            rightColor = dim;
            if (_rollingUnit != 3) {
                rightLabel = "AVG (1ST)";
            }
        }

        var lx = Layout.pct(w, Layout.ROW2_LEFT_X);
        var rx = Layout.pct(w, Layout.ROW2_RIGHT_X);
        var y = Layout.pct(h, Layout.ROW2_Y);
        var ly = Layout.pct(h, Layout.ROW2_LABEL_Y);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, y, Layout.valueFont(h), paceText(leftSpm), Layout.VCENTER);
        dc.setColor(rightColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rx, y, Layout.valueFont(h), paceText(rightSpm), Layout.VCENTER);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, ly, Layout.labelFont(), leftLabel, Layout.VCENTER);
        dc.drawText(rx, ly, Layout.labelFont(), rightLabel, Layout.VCENTER);
        dc.drawLine(w / 2, Layout.pct(h, Layout.DIVIDER_TOP), w / 2, Layout.pct(h, Layout.DIVIDER_BOTTOM));
    }

    hidden function paceText(spm as Float or Null) as String {
        return Fmt.pace(spm != null ? spm * _paceUnit : null);
    }

    // Row 3: timer | heart rate | cadence. The timer is m:ss, then h:mm past
    // an hour, so three columns fit inside the chord at 87% height. In a
    // workout it is the step's: time left in a timed step, else time in it.
    hidden function drawRow3(dc as Graphics.Dc, w as Number, h as Number, fg as Number,
                             dim as Number, workout as Boolean) as Void {
        var timeMs = _timerMs;
        var timeLabel = "TIME";
        if (workout) {
            timeMs = _timerMs - _stepStartMs;
            timeLabel = "STEP";
            if (_target.stepMs > 0) {
                timeMs = _target.stepMs - timeMs;
                timeLabel = "LEFT";
            }
        }
        var tx = Layout.pct(w, Layout.TIME_X);
        var hx = Layout.pct(w, Layout.HR_X);
        var cadX = Layout.pct(w, Layout.CAD_X);
        var y = Layout.pct(h, Layout.ROW3_Y);
        var ly = Layout.pct(h, Layout.ROW3_LABEL_Y);
        var font = Layout.rowFont(h);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, y, font, Fmt.timerShort(timeMs < 0 ? 0 : timeMs), Layout.VCENTER);
        dc.drawText(cadX, y, font, _cadence != null ? _cadence.toString() : "--", Layout.VCENTER);
        var hrText = _hr != null ? _hr.toString() : "--";
        if (_target.hrOverCap(_hr)) {
            // White on a red pill: red digits on black were too dark to read
            // on the FR965 (0.6.0).
            Layout.drawPill(dc, hx, y, hrText, font, Layout.pct(w, 4), Graphics.COLOR_RED);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        }
        dc.drawText(hx, y, font, hrText, Layout.VCENTER);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, ly, Layout.labelFont(), timeLabel, Layout.VCENTER);
        dc.drawText(hx, ly, Layout.labelFont(), "HR", Layout.VCENTER);
        dc.drawText(cadX, ly, Layout.labelFont(), "CAD", Layout.VCENTER);
    }

    hidden function drawBand(dc as Graphics.Dc, w as Number, h as Number, dim as Number,
                             status as Number) as Void {
        if (_timerMs == 0) {
            drawPrestartBand(dc, w, h);
            return;
        }
        var line1;
        var line2 = "";
        var textColor = dim;
        if (_target.isRest) {
            line1 = _target.stepLabel;
        } else if (_target.kind == WorkoutTarget.KIND_NONE) {
            line1 = _target.hasWorkout ? "NO TARGET" : "NO GOAL SET";
            line2 = _target.stepLabel;
        } else {
            line1 = statusWords(status);
            if (status == WorkoutTarget.STATUS_NONE) {
                line2 = rangeText();
            } else {
                var fill = statusColor(status);
                dc.setColor(fill, fill);
                dc.fillRectangle(0, 0, w, Layout.pct(h, Layout.BAND_FILL));
                textColor = Graphics.COLOR_WHITE;
                if (_target.source == WorkoutTarget.SOURCE_GOAL && _target.kind == WorkoutTarget.KIND_PACE) {
                    line2 = goalLine();
                } else {
                    // The step average is in row 2 during a workout.
                    var lbl = _target.stepLabel;
                    line2 = (lbl.length() > 0 ? lbl + " " : "") + rangeText();
                }
            }
        }
        drawBandText(dc, w, h, textColor, line1, line2);
    }

    // Before START: is the course loaded?
    hidden function drawPrestartBand(dc as Graphics.Dc, w as Number, h as Number) as Void {
        var line1;
        var line2 = "";
        var color = Graphics.COLOR_ORANGE;
        if (!_tracker.hasCourse() && _treadmill) {
            // Indoors there is no course to load; distance is the watch's.
            line1 = "TREADMILL";
            color = Graphics.COLOR_DK_GREEN;
        } else if (!_tracker.hasCourse()) {
            line1 = "NO COURSE";
            line2 = "NAVIGATION > COURSES";
        } else if (_tracker.lengthMismatch) {
            line1 = "CHECK LENGTH";
            line2 = Fmt.dist(_tracker.loadedLengthMeters() as Float, _distUnit)
                    + " LOADED, " + Fmt.dist(_officialLen * _distUnit, _distUnit) + " SET";
        } else {
            line1 = "COURSE READY";
            line2 = Fmt.dist(_tracker.lengthMeters() as Float, _distUnit) + _unitText;
            color = Graphics.COLOR_DK_GREEN;
        }
        drawBandText(dc, w, h, color, line1, line2);
    }

    hidden function drawBandText(dc as Graphics.Dc, w as Number, h as Number, color as Number,
                                 line1 as String, line2 as String) as Void {
        var cx = w / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (line2.length() > 0) {
            dc.drawText(cx, Layout.pct(h, Layout.BAND_Y1), Layout.bandFont(h), line1, Layout.VCENTER);
            dc.drawText(cx, Layout.pct(h, Layout.BAND_Y2), Layout.labelFont(), line2, Layout.VCENTER);
        } else {
            dc.drawText(cx, Layout.pct(h, Layout.BAND_Y_SINGLE), Layout.bandFont(h), line1, Layout.VCENTER);
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
        var label;
        if (_timerMs == 0) {
            label = _tracker.hasCourse() ? "COURSE READY" : (_treadmill ? "TREADMILL" : "NO COURSE");
        } else if (_gel.showing(_timerMs)) {
            label = "GEL " + _gel.count.toString();
            labelColor = Graphics.COLOR_ORANGE;
        } else {
            label = modeLabel();
            labelColor = modeColor(labelColor);
        }
        var cx = w / 2;
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, Layout.pct(h, 42), Graphics.FONT_NUMBER_MILD, Fmt.dist(meters, _distUnit), Layout.VCENTER);
        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, Layout.pct(h, 82), Graphics.FONT_XTINY, label, Layout.VCENTER);
    }
}
