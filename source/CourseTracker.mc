import Toybox.Lang;

// Turns the native Run app's course navigation into "distance covered along
// the course".
//
// While a course is being navigated, Activity.Info.distanceToDestination
// (dtd) is the distance remaining along the route, so distance covered is
// (course length - dtd). The course length is learned from dtd:
//   - before the timer starts, preview() keeps the largest dtd seen, so a
//     brief snap to the finish point at the start line of a loop course
//     doesn't lock a length of zero;
//   - early in the run, a dtd that implies a longer course re-locks the
//     length (the first reading can be the distance to the start point);
//   - at START, a first reading up to 100 m under the previewed length
//     becomes the length: the preview included the walk to the start line
//     (seen on an FR965 loop: the whole run read 16 m long).
//
// Distance covered never goes backwards. If the course value stops advancing
// while GPS distance keeps growing (off course, wrong lap, or the watch
// stopped navigating), the tracker adds GPS distance instead and reports
// MODE_OFF so the screen can flag it. When the course value advances again
// but sits below the distance shown (GPS added meanwhile, or a turnaround
// the route cuts short), the shown distance grows at half the course rate
// until the course catches up: back to MODE_COURSE at once, never backwards,
// and no minutes of OFF COURSE while the gap closes (seen replaying a
// lapped half marathon: 7.5 min).
//
// A reading more than 400 m ahead of what GPS movement allows is ignored
// (treated as not advancing): on a lapped course the watch could match a
// later lap, or snap to the finish when passing it on lap 1, and distance
// never goes backwards, so taking it would lock in a lap's error. If the
// watch keeps saying it, the stall detector reports OFF COURSE and counts
// GPS until the course value makes sense again.
//
// An optional official length rescales the course value (a GPX that measures
// 13.25 mi still reads 13.11 at the finish), but only when the loaded course
// is within 5% of it; otherwise lengthMismatch is set and no rescale happens.
class CourseTracker {
    enum {
        MODE_GPS = 0,     // never had a course reading: plain GPS distance
        MODE_COURSE = 1,  // on course: distance from the route
        MODE_OFF = 2      // had a course, not advancing: GPS fallback
    }

    hidden const RELOCK_MIN_M = 500.0;     // early-run window for re-locking length
    hidden const STALL_SECS = 20;          // course value stuck this long...
    hidden const STALL_GPS_M = 50.0;       // ...while GPS moved this far => off course
    hidden const RESCALE_TOL = 0.05;       // official vs loaded length tolerance
    hidden const START_SNAP_M = 100.0;     // preview lead-in dropped at START
    hidden const CATCHUP_M = 400.0;        // course this close behind: catch up, don't stay off
    hidden const LEAP_M = 400.0;           // course this far ahead of GPS movement: ignored
    hidden const MAX_M = 1000000.0;        // 1000 km: sanity bound on restored values

    var courseDist as Float = 0.0;
    var mode as Number = MODE_GPS;
    var lengthMismatch as Boolean = false;

    hidden var _length as Float or Null = null;
    hidden var _official as Float = 0.0;
    hidden var _lastGps as Float or Null = null;
    hidden var _stallTicks as Number = 0;
    hidden var _stallGps as Float = 0.0;
    hidden var _lastCand as Float or Null = null;   // last course value, for its rate

    function initialize() {
    }

    function reset() as Void {
        courseDist = 0.0;
        mode = MODE_GPS;
        lengthMismatch = false;
        _length = null;
        _lastGps = null;
        _stallTicks = 0;
        _stallGps = 0.0;
        _lastCand = null;
    }

    // State for Resume Later, which reloads the field: [length (-1 = none),
    // courseDist, mode, last GPS distance]. Stall bookkeeping restarts.
    function snapshot() as Array<Float or Number> {
        return [
            _length != null ? _length as Float : -1.0,
            courseDist,
            mode,
            lastGps()
        ] as Array<Float or Number>;
    }

    // GPS distance at the last update (0 before any).
    function lastGps() as Float {
        return _lastGps != null ? _lastGps as Float : 0.0;
    }

    // Restores a snapshot(). Anything malformed (older version, corrupt
    // storage) is rejected and leaves the tracker untouched.
    function restore(s as Object or Null) as Boolean {
        if (!(s instanceof Array) || s.size() != 4) {
            return false;
        }
        var m = s[2];
        if (!(m instanceof Number)) {
            return false;
        }
        var v = new Array<Float>[4];
        for (var i = 0; i < 4; i++) {
            var x = s[i];
            if (!(x instanceof Float || x instanceof Number)) {
                return false;
            }
            v[i] = (x as Float or Number).toFloat();
        }
        var len = v[0];
        var dist = v[1];
        var gps = v[3];
        // NaN is the one value not equal to itself. (Monkey C evaluates
        // NaN >= 0.0 as true, so range checks alone don't catch it.)
        if (len != len || dist != dist || gps != gps
            || !(dist >= 0.0 && dist < MAX_M && gps >= 0.0 && gps < MAX_M && len < MAX_M)
            || m < MODE_GPS || m > MODE_OFF) {
            return false;
        }
        _length = len > 0.0 ? len : null;
        courseDist = dist;
        mode = m;
        _lastGps = gps;
        _lastCand = null;
        _stallTicks = 0;
        _stallGps = 0.0;
        checkMismatch();
        return true;
    }

    // Official course length in metres; 0 disables rescaling.
    function setOfficialLength(meters as Float) as Void {
        _official = meters > 0.0 ? meters : 0.0;
        checkMismatch();
    }

    // True once a course has been seen (before or after the timer started).
    function hasCourse() as Boolean {
        return _length != null && (_length as Float) > 0.0;
    }

    // Loaded course length in metres (as navigated, before any rescale).
    function loadedLengthMeters() as Float or Null {
        return _length;
    }

    // Course length in metres as displayed (official if set and plausible).
    function lengthMeters() as Float or Null {
        if (_length == null) {
            return null;
        }
        return useOfficial() ? _official : _length;
    }

    // Distance left to the finish in metres, or null without a course. Built
    // on the displayed course distance, so run + to-go = course length.
    function remainingMeters() as Float or Null {
        var len = lengthMeters();
        if (len == null) {
            return null;
        }
        var r = len - courseDist;
        return r > 0.0 ? r : 0.0;
    }

    hidden function useOfficial() as Boolean {
        return _official > 0.0 && _length != null && !lengthMismatch;
    }

    hidden function checkMismatch() as Void {
        lengthMismatch = false;
        if (_official > 0.0 && _length != null && (_length as Float) > 0.0) {
            var ratio = (_length as Float) / _official;
            lengthMismatch = ratio > 1.0 + RESCALE_TOL || ratio < 1.0 - RESCALE_TOL;
        }
    }

    // Before the timer starts: learn the course length from navigation.
    function preview(dtd as Float or Null) as Void {
        if (dtd == null || dtd <= 0.0) {
            return;
        }
        if (_length == null || dtd > (_length as Float)) {
            _length = dtd;
            checkMismatch();
        }
    }

    // gps: Activity.Info.elapsedDistance (m). dtd: distanceToDestination (m) or
    // null. Call once per second only while the timer is running.
    function update(gps as Float, dtd as Float or Null) as Void {
        var first = _lastGps == null;
        var delta = 0.0;
        if (_lastGps != null) {
            delta = gps - _lastGps;
            if (delta < 0.0) {
                delta = 0.0;
            }
        }
        _lastGps = gps;

        if (dtd == null || dtd < 0.0) {
            // No course value at all.
            _lastCand = null;
            courseDist += delta;
            if (mode == MODE_COURSE) {
                mode = MODE_OFF;
            }
            return;
        }

        var implied = dtd + courseDist;
        if (first && _length != null) {
            var gap = (_length as Float) - dtd;
            if (gap > 0.0 && gap < START_SNAP_M) {
                _length = dtd;
                checkMismatch();
            }
        }
        if (_length == null) {
            _length = implied;
            checkMismatch();
        } else {
            var len = _length as Float;
            var early = courseDist < RELOCK_MIN_M || courseDist < len * 0.1;
            if (early && implied > len * (1.0 + RESCALE_TOL)) {
                _length = implied;
                checkMismatch();
            }
        }

        var len2 = _length as Float;
        var cand = len2 - dtd;
        if (useOfficial() && len2 > 0.0) {
            cand = cand * _official / len2;
        }

        if (!first && cand - courseDist > delta * 2.0 + LEAP_M) {
            // Implausible leap ahead: treat as no advance (stall logic below).
            _lastCand = null;
            cand = courseDist;
        }
        var step = _lastCand != null ? cand - (_lastCand as Float) : 0.0;
        _lastCand = cand;

        if (cand > courseDist) {
            courseDist = cand;
            mode = MODE_COURSE;
            _stallTicks = 0;
            _stallGps = 0.0;
            return;
        }

        // Course advancing (at least half the GPS rate, so jitter doesn't
        // count) but behind the shown distance: close the gap gradually.
        if (step > 1.0 && step >= delta * 0.5 && courseDist - cand < CATCHUP_M) {
            courseDist += step * 0.5;
            mode = MODE_COURSE;
            _stallTicks = 0;
            _stallGps = 0.0;
            return;
        }

        // Course value not advancing.
        _stallTicks++;
        _stallGps += delta;
        if (mode == MODE_OFF) {
            courseDist += delta;
        } else if (_stallTicks >= STALL_SECS && _stallGps >= STALL_GPS_M) {
            mode = MODE_OFF;
            courseDist += _stallGps;
        }
    }
}
