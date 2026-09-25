import Toybox.Lang;

// Turns the native Run app's course navigation into "distance covered along
// the course".
//
// While a course is being navigated, Activity.Info.distanceToDestination is
// the distance remaining along the route. Course distance covered is then
// (course length - remaining). Course length is learned from the first
// non-null reading: length = remaining + distance already covered, so starting
// navigation a little into the run still works.
//
// When remaining distance is null (off course, or no course loaded) the
// tracker advances by the GPS distance delta instead and reports that mode so
// the screen can flag it. When the course reading returns, distance snaps back
// to the course value. Course distance never goes backwards.
//
// Optional official length (from settings) rescales the course value, so a
// GPX that measures 13.25 mi still reads 13.11 at the finish of a half.
class CourseTracker {
    enum {
        MODE_GPS = 0,     // never had a course reading: plain GPS distance
        MODE_COURSE = 1,  // on course: distance from the route
        MODE_OFF = 2      // had a course, lost it: GPS fallback
    }

    var courseDist as Float = 0.0;
    var mode as Number = MODE_GPS;

    hidden var _length as Float or Null = null;
    hidden var _official as Float = 0.0;
    hidden var _lastGps as Float or Null = null;

    function initialize() {
    }

    function reset() as Void {
        courseDist = 0.0;
        mode = MODE_GPS;
        _length = null;
        _lastGps = null;
    }

    // Official course length in metres; 0 disables rescaling.
    function setOfficialLength(meters as Float) as Void {
        _official = meters > 0.0 ? meters : 0.0;
    }

    // Course length in metres as displayed (official if set), or null if no
    // course has been seen yet.
    function lengthMeters() as Float or Null {
        if (_length == null) {
            return null;
        }
        return _official > 0.0 ? _official : _length;
    }

    // Distance left to the finish in metres, or null if no course has been
    // seen. Uses the same course distance the screen shows, so run + to-go
    // always equals the course length.
    function remainingMeters() as Float or Null {
        var len = lengthMeters();
        if (len == null) {
            return null;
        }
        var r = len - courseDist;
        return r > 0.0 ? r : 0.0;
    }

    // gps: Activity.Info.elapsedDistance (m). dtd: distanceToDestination (m) or null.
    function update(gps as Float, dtd as Float or Null) as Void {
        var delta = 0.0;
        if (_lastGps != null) {
            delta = gps - _lastGps;
            if (delta < 0.0) {
                delta = 0.0;
            }
        }
        _lastGps = gps;

        if (dtd != null && dtd >= 0.0) {
            if (_length == null) {
                _length = dtd + courseDist;
            }
            var len = _length as Float;
            var cand = len - dtd;
            if (_official > 0.0 && len > 0.0) {
                cand = cand * _official / len;
            }
            if (cand > courseDist) {
                courseDist = cand;
            }
            mode = MODE_COURSE;
        } else {
            courseDist += delta;
            if (mode == MODE_COURSE) {
                mode = MODE_OFF;
            }
        }
    }
}
