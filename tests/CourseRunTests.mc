import Toybox.Activity;
import Toybox.Lang;
import Toybox.Test;

// Unit tests. Run with:
//   monkeyc -d fr965 -f monkey.jungle -o bin/CourseRun-test.prg -y developer_key.der --unit-test
//   monkeydo bin/CourseRun-test.prg fr965 -t
module CourseRunTests {

    // Helper (not a test).
    function near(a as Float or Null, b as Float, tol as Float) as Boolean {
        if (a == null) {
            return false;
        }
        var d = a - b;
        return d < tol && d > -tol;
    }

    // ---- PaceBuffer --------------------------------------------------------

    // Constant 3 m/s, one tick per second for 12 minutes.
    (:test)
    function paceBufferConstantSpeed(logger as Logger) as Boolean {
        var b = new PaceBuffer(600, 2000);
        var t = 0;
        var d = 0.0;
        for (var s = 1; s <= 720; s++) {
            t = s * 1000;
            d = s * 3.0;
            b.add(t, d);
        }
        var roll = b.rollingSecPerMeter(t, d, 1609.344);
        var v = b.smoothedSpeed(t, d, 30000);
        logger.debug("roll=" + roll + " v=" + v + " size=" + b.size());
        Test.assert(near(roll, 1.0 / 3.0, 0.001));
        Test.assert(near(v, 3.0, 0.01));
        Test.assert(b.size() == 360);
        return true;
    }

    // Rolling pace is null until a full mile is covered.
    (:test)
    function paceBufferNeedsFullWindow(logger as Logger) as Boolean {
        var b = new PaceBuffer(600, 2000);
        for (var s = 1; s <= 100; s++) {
            b.add(s * 1000, s * 3.0);
        }
        Test.assert(b.rollingSecPerMeter(100000, 300.0, 1609.344) == null);
        return true;
    }

    // First half at 3 m/s, second half at 4 m/s: the last mile reflects only
    // the faster section, the smoothed speed only the last 30 s.
    (:test)
    function paceBufferChangingSpeed(logger as Logger) as Boolean {
        var b = new PaceBuffer(600, 2000);
        var d = 0.0;
        var t = 0;
        for (var s = 1; s <= 900; s++) {
            d += s <= 450 ? 3.0 : 4.0;
            t = s * 1000;
            b.add(t, d);
        }
        var roll = b.rollingSecPerMeter(t, d, 1609.344);
        var v = b.smoothedSpeed(t, d, 30000);
        Test.assert(near(roll, 0.25, 0.001));
        Test.assert(near(v, 4.0, 0.01));
        return true;
    }

    // Ring wrap: a 20-minute buffer after 60 minutes still answers correctly.
    (:test)
    function paceBufferWraps(logger as Logger) as Boolean {
        var b = new PaceBuffer(600, 2000);
        var t = 0;
        var d = 0.0;
        for (var s = 1; s <= 3600; s++) {
            t = s * 1000;
            d = s * 2.5;
            b.add(t, d);
        }
        Test.assert(b.size() == 600);
        Test.assert(near(b.rollingSecPerMeter(t, d, 1609.344), 0.4, 0.001));
        // A window older than the buffer returns null instead of garbage.
        Test.assert(b.rollingSecPerMeter(t, d, 5000.0) == null);
        return true;
    }

    // Timer pause: time stands still, distance stands still, pace unaffected.
    (:test)
    function paceBufferTimerBackwardsResets(logger as Logger) as Boolean {
        var b = new PaceBuffer(600, 2000);
        for (var s = 1; s <= 100; s++) {
            b.add(s * 1000, s * 3.0);
        }
        b.add(1000, 3.0);
        Test.assert(b.size() == 1);
        return true;
    }

    // ---- CourseTracker -----------------------------------------------------

    // GPS reads 2% long; course distance follows the route instead.
    (:test)
    function courseTrackerOnCourse(logger as Logger) as Boolean {
        var c = new CourseTracker();
        var len = 21097.5;
        for (var s = 0; s <= 1000; s++) {
            var route = s * 3.0;
            c.update(route * 1.02, len - route);
        }
        Test.assert(c.mode == CourseTracker.MODE_COURSE);
        Test.assert(near(c.courseDist, 3000.0, 0.5));
        Test.assert(near(c.lengthMeters(), len, 0.5));
        return true;
    }

    // Off course (null) advances by GPS delta, then snaps back to the route.
    (:test)
    function courseTrackerFallbackAndSnapBack(logger as Logger) as Boolean {
        var c = new CourseTracker();
        var len = 10000.0;
        c.update(0.0, len);
        c.update(1000.0, len - 1000.0);
        c.update(1100.0, null);
        c.update(1200.0, null);
        Test.assert(c.mode == CourseTracker.MODE_OFF);
        Test.assert(near(c.courseDist, 1200.0, 0.01));
        // Back on course, route says 1150: hold at 1200 (never backwards)...
        c.update(1250.0, len - 1150.0);
        Test.assert(c.mode == CourseTracker.MODE_COURSE);
        Test.assert(near(c.courseDist, 1200.0, 0.01));
        // ...until the route catches up.
        c.update(1400.0, len - 1300.0);
        Test.assert(near(c.courseDist, 1300.0, 0.01));
        return true;
    }

    // No course at all: plain GPS distance.
    (:test)
    function courseTrackerNoCourse(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.update(0.0, null);
        c.update(500.0, null);
        Test.assert(c.mode == CourseTracker.MODE_GPS);
        Test.assert(near(c.courseDist, 500.0, 0.01));
        Test.assert(c.lengthMeters() == null);
        return true;
    }

    // Navigation started 400 m into the run: length = remaining + covered.
    (:test)
    function courseTrackerLateStart(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.update(0.0, null);
        c.update(400.0, null);
        c.update(410.0, 9600.0);
        Test.assert(near(c.lengthMeters(), 10000.0, 0.5));
        Test.assert(near(c.courseDist, 400.0, 0.5));
        c.update(1410.0, 8600.0);
        Test.assert(near(c.courseDist, 1400.0, 0.5));
        return true;
    }

    // GPX measures 21300 m; official 21097.5 m rescales to the official finish.
    (:test)
    function courseTrackerOfficialLength(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.setOfficialLength(21097.5);
        c.update(0.0, 21300.0);
        c.update(10650.0, 10650.0);
        Test.assert(near(c.courseDist, 21097.5 / 2, 1.0));
        c.update(21400.0, 0.0);
        Test.assert(near(c.courseDist, 21097.5, 1.0));
        Test.assert(near(c.lengthMeters(), 21097.5, 0.1));
        return true;
    }

    // Distance to go = course length - course distance; null without a course.
    (:test)
    function courseTrackerRemaining(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.update(0.0, null);
        Test.assert(c.remainingMeters() == null);
        c.update(10.0, 10000.0);
        c.update(3100.0, 7000.0);
        Test.assert(near(c.remainingMeters(), 7000.0, 0.5));
        // Off course: to-go shrinks with GPS progress.
        c.update(3200.0, null);
        Test.assert(near(c.remainingMeters(), 6900.0, 0.5));
        // Past the finish: clamps at zero.
        c.update(20000.0, null);
        Test.assert(near(c.remainingMeters(), 0.0, 0.01));
        return true;
    }

    // ---- WorkoutTarget -----------------------------------------------------

    // Speed target in mm/s: 2.9-3.1 m/s. Low is the slow bound.
    (:test)
    function workoutTargetPace(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 2900, 3100, null);
        Test.assert(w.kind == WorkoutTarget.KIND_PACE);
        Test.assert(near(w.low, 2.9, 0.0001));
        Test.assert(near(w.high, 3.1, 0.0001));
        Test.assert(w.status(3.0, null) == WorkoutTarget.STATUS_ON);
        Test.assert(w.status(3.3, null) == WorkoutTarget.STATUS_FAST);
        Test.assert(w.status(2.5, null) == WorkoutTarget.STATUS_SLOW);
        Test.assert(w.status(null, null) == WorkoutTarget.STATUS_NONE);
        // Reversed order is normalised.
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 3100, 2900, null);
        Test.assert(near(w.low, 2.9, 0.0001));
        return true;
    }

    // Zero speed target (e.g. %-based bug) means no target.
    (:test)
    function workoutTargetZeroIsNone(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 0, 0, null);
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        w.setFrom(Activity.WORKOUT_STEP_TARGET_OPEN, 0, 0, null);
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        Test.assert(w.status(3.0, 150) == WorkoutTarget.STATUS_NONE);
        return true;
    }

    // HR: bpm + 100 encoding, zone number, and percent of max.
    (:test)
    function workoutTargetHeartRate(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 245, 255, null);
        Test.assert(w.kind == WorkoutTarget.KIND_HR);
        Test.assert(near(w.low, 145.0, 0.01) && near(w.high, 155.0, 0.01));
        Test.assert(w.status(null, 160) == WorkoutTarget.STATUS_FAST);
        Test.assert(w.status(null, 150) == WorkoutTarget.STATUS_ON);
        Test.assert(w.status(null, 140) == WorkoutTarget.STATUS_SLOW);

        var zones = [100, 120, 140, 155, 170, 190] as Array<Number>;
        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 2, 2, zones);
        Test.assert(near(w.low, 120.0, 0.01) && near(w.high, 140.0, 0.01));

        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 70, 80, zones);
        Test.assert(near(w.low, 133.0, 0.01) && near(w.high, 152.0, 0.01));
        return true;
    }

    // ---- Fmt ---------------------------------------------------------------

    (:test)
    function fmtValues(logger as Logger) as Boolean {
        Test.assertEqual(Fmt.pace(538.4), "8:58");
        Test.assertEqual(Fmt.pace(539.6), "9:00");
        Test.assertEqual(Fmt.pace(null), "--:--");
        Test.assertEqual(Fmt.timer(2621000), "43:41");
        Test.assertEqual(Fmt.timer(5461000), "1:31:01");
        Test.assertEqual(Fmt.dist(7837.0, Fmt.M_PER_MI), "4.87");
        return true;
    }
}
