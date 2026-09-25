import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Full-screen run field:
//
//   [ status band: ON PACE / TOO FAST / TOO SLOW + target range ]
//                  course distance (hero)
//         course avg pace     |   rolling last-mile pace
//              timer          |   heart rate
//
// Designed for a 1-field data screen. In a smaller slot it draws a compact
// version (course distance on the status colour).
class CourseRunField extends WatchUi.DataField {
    hidden const SAMPLE_MS = 2000;
    hidden const BUFFER_SLOTS = 600;  // 20 min of history at 2 s

    hidden var _tracker as CourseTracker;
    hidden var _buf as PaceBuffer;
    hidden var _target as WorkoutTarget;

    hidden var _timerMs as Number = 0;
    hidden var _hr as Number or Null = null;
    hidden var _tick as Number = 0;

    hidden var _smoothMs as Number = 30000;
    hidden var _rollingUnit as Number = 0;  // 0 watch units, 1 mile, 2 km
    hidden var _officialLen as Float = 0.0; // in display distance units

    function initialize() {
        DataField.initialize();
        _tracker = new CourseTracker();
        _buf = new PaceBuffer(BUFFER_SLOTS, SAMPLE_MS);
        _target = new WorkoutTarget();
        loadSettings();
        _target.refresh();
    }

    function loadSettings() as Void {
        _officialLen = readFloat("courseLength", 0.0);
        _smoothMs = (readFloat("smoothSeconds", 30.0) * 1000).toNumber();
        if (_smoothMs < 5000) {
            _smoothMs = 5000;
        }
        _rollingUnit = readFloat("rollingUnit", 0.0).toNumber();
        _tracker.setOfficialLength(_officialLen * Fmt.distUnitM());
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

    // ---- activity lifecycle -------------------------------------------------

    function onTimerReset() as Void {
        _tracker.reset();
        _buf.reset();
        _timerMs = 0;
    }

    function onWorkoutStarted() as Void {
        _target.refresh();
    }

    function onWorkoutStepComplete() as Void {
        _target.refresh();
    }

    // Called once a second by the Run activity.
    function compute(info as Activity.Info) as Void {
        var timer = info.timerTime;
        _timerMs = timer != null ? timer : 0;
        _hr = info.currentHeartRate;

        if (_timerMs > 0) {
            var gps = info.elapsedDistance;
            _tracker.update(gps != null ? gps : 0.0, info.distanceToDestination);
            _buf.add(_timerMs, _tracker.courseDist);
        }

        // Step callbacks cover transitions; this catches anything missed
        // (e.g. the field added mid-workout).
        _tick++;
        if (_tick % 5 == 0) {
            _target.refresh();
        }
    }

    // ---- drawing ------------------------------------------------------------

    hidden function rollingWindowM() as Float {
        if (_rollingUnit == 1) {
            return Fmt.M_PER_MI;
        }
        if (_rollingUnit == 2) {
            return Fmt.M_PER_KM;
        }
        return Fmt.paceUnitM();
    }

    hidden function statusColor(status as Number) as Number {
        if (status == WorkoutTarget.STATUS_ON) {
            return Graphics.COLOR_DK_GREEN;
        }
        if (status == WorkoutTarget.STATUS_FAST) {
            return Graphics.COLOR_RED;
        }
        if (status == WorkoutTarget.STATUS_SLOW) {
            return Graphics.COLOR_BLUE;
        }
        return Graphics.COLOR_DK_GRAY;
    }

    hidden function statusText(status as Number) as String {
        var hr = _target.kind == WorkoutTarget.KIND_HR;
        if (status == WorkoutTarget.STATUS_ON) {
            return hr ? "HR ON" : "ON PACE";
        }
        if (status == WorkoutTarget.STATUS_FAST) {
            return hr ? "HR HIGH" : "TOO FAST";
        }
        if (status == WorkoutTarget.STATUS_SLOW) {
            return hr ? "HR LOW" : "TOO SLOW";
        }
        if (_target.kind != WorkoutTarget.KIND_NONE) {
            return "TARGET";
        }
        return _target.hasWorkout ? "NO TARGET" : "NO WORKOUT";
    }

    hidden function targetText(paceUnit as Float) as String {
        if (_target.kind == WorkoutTarget.KIND_PACE) {
            // Faster pace first, the way paces are usually written.
            return Fmt.paceFromSpeed(_target.high, paceUnit) + "-" + Fmt.paceFromSpeed(_target.low, paceUnit);
        }
        if (_target.kind == WorkoutTarget.KIND_HR) {
            return _target.low.toNumber().toString() + "-" + _target.high.toNumber().toString() + " bpm";
        }
        return "";
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var bg = getBackgroundColor();
        var fg = bg == Graphics.COLOR_BLACK ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var dim = bg == Graphics.COLOR_BLACK ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_DK_GRAY;

        var distUnit = Fmt.distUnitM();
        var paceUnit = Fmt.paceUnitM();
        var cd = _tracker.courseDist;

        var speed = _buf.smoothedSpeed(_timerMs, cd, _smoothMs);
        var status = _target.status(speed, _hr);
        var band = statusColor(status);

        dc.setColor(fg, bg);
        dc.clear();

        var screenH = System.getDeviceSettings().screenHeight;
        if (h < screenH * 3 / 4) {
            drawCompact(dc, w, h, band, cd, distUnit);
            return;
        }

        var cx = w / 2;
        var vc = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

        // Status band across the top.
        dc.setColor(band, band);
        dc.fillRectangle(0, 0, w, Layout.pct(h, 25));
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var tgt = targetText(paceUnit);
        if (tgt.length() > 0) {
            dc.drawText(cx, Layout.pct(h, 12), Layout.bandFont(h), statusText(status), vc);
            dc.drawText(cx, Layout.pct(h, 20), Layout.labelFont(), tgt, vc);
        } else {
            dc.drawText(cx, Layout.pct(h, 16), Layout.bandFont(h), statusText(status), vc);
        }

        // Hero: course distance.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, Layout.pct(h, 38), Layout.heroFont(h), Fmt.dist(cd, distUnit), vc);

        var label = "DISTANCE";
        if (_tracker.mode != CourseTracker.MODE_GPS) {
            label = "COURSE";
        }
        label = label + (distUnit == Fmt.M_PER_MI ? " MI" : " KM");
        if (_tracker.mode == CourseTracker.MODE_OFF) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            label = label + " (GPS)";
        } else {
            dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        }
        dc.drawText(cx, Layout.pct(h, 50), Layout.labelFont(), label, vc);

        // Row 2: course average pace | rolling last-mile pace.
        var avgSpm = null;
        if (cd > 10.0 && _timerMs > 0) {
            avgSpm = _timerMs / 1000.0 / cd;
        }
        var rollM = rollingWindowM();
        var rollSpm = _buf.rollingSecPerMeter(_timerMs, cd, rollM);
        var lx = Layout.pct(w, 30);
        var rx = Layout.pct(w, 70);

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, Layout.pct(h, 60), Layout.valueFont(h),
                    Fmt.pace(avgSpm != null ? avgSpm * paceUnit : null), vc);
        if (rollSpm != null) {
            dc.drawText(rx, Layout.pct(h, 60), Layout.valueFont(h), Fmt.pace(rollSpm * paceUnit), vc);
        } else {
            // Before a full window is covered, show the average so far, dimmed.
            dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rx, Layout.pct(h, 60), Layout.valueFont(h),
                        Fmt.pace(avgSpm != null ? avgSpm * paceUnit : null), vc);
        }
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, Layout.pct(h, 68), Layout.labelFont(), "AVG PACE", vc);
        dc.drawText(rx, Layout.pct(h, 68), Layout.labelFont(), rollM == Fmt.M_PER_MI ? "LAST MI" : "LAST KM", vc);

        // Divider between the two columns.
        dc.drawLine(cx, Layout.pct(h, 55), cx, Layout.pct(h, 89));

        // Row 3: timer | heart rate.
        var tx = Layout.pct(w, 34);
        var hx = Layout.pct(w, 66);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, Layout.pct(h, 78), Layout.rowFont(h), Fmt.timer(_timerMs), vc);
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(hx, Layout.pct(h, 78), Layout.rowFont(h), _hr != null ? _hr.toString() : "--", vc);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, Layout.pct(h, 86), Layout.labelFont(), "TIME", vc);
        dc.drawText(hx, Layout.pct(h, 86), Layout.labelFont(), "HR", vc);
    }

    // Smaller slot: course distance on the status colour.
    hidden function drawCompact(dc as Graphics.Dc, w as Number, h as Number,
                                band as Number, cd as Float, distUnit as Float) as Void {
        dc.setColor(band, band);
        dc.fillRectangle(0, 0, w, h);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var txt = Fmt.dist(cd, distUnit);
        if (_tracker.mode == CourseTracker.MODE_OFF) {
            txt = txt + "*";
        }
        dc.drawText(w / 2, h / 2, Graphics.FONT_NUMBER_MILD, txt,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
