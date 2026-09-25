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
//     length (the first reading can be the distance to the start point).
//
// Distance covered never goes backwards. If the course value stops advancing
// while GPS distance keeps growing (off course, wrong lap, or the watch
// stopped navigating), the tracker adds GPS distance instead and reports
// MODE_OFF so the screen can flag it.
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

    var courseDist as Float = 0.0;
    var mode as Number = MODE_GPS;
    var lengthMismatch as Boolean = false;

    hidden var _length as Float or Null = null;
    hidden var _official as Float = 0.0;
    hidden var _lastGps as Float or Null = null;
    hidden var _stallTicks as Number = 0;
    hidden var _stallGps as Float = 0.0;

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
            courseDist += delta;
            if (mode == MODE_COURSE) {
                mode = MODE_OFF;
            }
            return;
        }

        var implied = dtd + courseDist;
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

        if (cand > courseDist) {
            courseDist = cand;
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
