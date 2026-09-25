import Toybox.Lang;

// Fixed-size ring buffer of (timer ms, course distance m) samples.
//
// Both series are non-decreasing while the activity runs (timer time stops
// during pauses, course distance is clamped monotonic by CourseTracker), so
// lookups use binary search and linear interpolation between samples.
//
// Two queries feed the screen:
//   rollingSecPerMeter  - time to cover the most recent N metres (last mile)
//   smoothedSpeed       - distance covered over the most recent N ms
// Both take the *current* point as the newest end, so they update every
// compute() tick even though samples are only stored every `intervalMs`.
class PaceBuffer {
    hidden var _t as Array<Number>;
    hidden var _d as Array<Float>;
    hidden var _cap as Number;
    hidden var _interval as Number;
    hidden var _count as Number = 0;
    hidden var _next as Number = 0;

    function initialize(capacity as Number, intervalMs as Number) {
        _cap = capacity;
        _interval = intervalMs;
        _t = new Array<Number>[capacity];
        _d = new Array<Float>[capacity];
        for (var i = 0; i < capacity; i++) {
            _t[i] = 0;
            _d[i] = 0.0;
        }
    }

    function reset() as Void {
        _count = 0;
        _next = 0;
    }

    function size() as Number {
        return _count;
    }

    // Store a sample if at least `intervalMs` has passed since the last one.
    // A timer that goes backwards means a new activity: start over.
    function add(tMs as Number, dM as Float) as Void {
        if (_count > 0) {
            var last = _t[(_next - 1 + _cap) % _cap];
            if (tMs < last) {
                reset();
            } else if (tMs - last < _interval) {
                return;
            }
        }
        _t[_next] = tMs;
        _d[_next] = dM;
        _next = (_next + 1) % _cap;
        if (_count < _cap) {
            _count++;
        }
    }

    // Logical index 0 = oldest sample.
    hidden function phys(i as Number) as Number {
        return (_next - _count + i + _cap) % _cap;
    }

    // Interpolated timer time (ms) at which course distance reached `dist`.
    // Null if `dist` is older than the oldest stored sample.
    function timeAtDistance(dist as Float) as Float or Null {
        if (_count == 0 || dist < _d[phys(0)]) {
            return null;
        }
        var lo = 0;
        var hi = _count - 1;
        while (lo < hi) {
            var mid = (lo + hi + 1) / 2;
            if (_d[phys(mid)] <= dist) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        var a = phys(lo);
        if (lo == _count - 1) {
            return _t[a].toFloat();
        }
        var b = phys(lo + 1);
        var dd = _d[b] - _d[a];
        if (dd <= 0.0) {
            return _t[a].toFloat();
        }
        return _t[a] + (_t[b] - _t[a]) * (dist - _d[a]) / dd;
    }

    // Interpolated course distance (m) at timer time `t` (ms).
    // Null if `t` is older than the oldest stored sample.
    function distanceAtTime(t as Number) as Float or Null {
        if (_count == 0 || t < _t[phys(0)]) {
            return null;
        }
        var lo = 0;
        var hi = _count - 1;
        while (lo < hi) {
            var mid = (lo + hi + 1) / 2;
            if (_t[phys(mid)] <= t) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        var a = phys(lo);
        if (lo == _count - 1) {
            return _d[a];
        }
        var b = phys(lo + 1);
        var dt = _t[b] - _t[a];
        if (dt <= 0) {
            return _d[a];
        }
        return _d[a] + (_d[b] - _d[a]) * (t - _t[a]).toFloat() / dt;
    }

    // Seconds per metre over the most recent `windowM` metres, ending at the
    // current point. Null until a full window has been covered, or if the
    // window reaches further back than the buffer holds.
    function rollingSecPerMeter(nowT as Number, nowD as Float, windowM as Float) as Float or Null {
        var startD = nowD - windowM;
        if (startD < 0.0) {
            return null;
        }
        var tStart = timeAtDistance(startD);
        if (tStart == null) {
            return null;
        }
        var dt = nowT - tStart;
        if (dt <= 0.0) {
            return null;
        }
        return dt / 1000.0 / windowM;
    }

    // Metres per second over the most recent `windowMs`, ending at the current
    // point. Early in the run (less history than the window) it uses whatever
    // history exists once there is at least 5 s of it.
    function smoothedSpeed(nowT as Number, nowD as Float, windowMs as Number) as Float or Null {
        if (_count == 0) {
            return null;
        }
        var p0 = phys(0);
        var t0 = nowT - windowMs;
        var d0 = null;
        if (t0 < _t[p0]) {
            if (nowT - _t[p0] < 5000) {
                return null;
            }
            t0 = _t[p0];
            d0 = _d[p0];
        } else {
            d0 = distanceAtTime(t0);
        }
        if (d0 == null) {
            return null;
        }
        var dt = nowT - t0;
        if (dt <= 0) {
            return null;
        }
        var v = (nowD - d0) * 1000.0 / dt;
        return v < 0.0 ? 0.0 : v;
    }
}
