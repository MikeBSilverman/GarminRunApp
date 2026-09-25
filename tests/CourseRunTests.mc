import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

// Unit tests. Run with:
//   monkeyc -d fr965 -f monkey.jungle -o bin/CourseRun-test.prg -y developer_key.der --unit-test
//   monkeydo bin/CourseRun-test.prg fr965 -t
module CourseRunTests {

    // Helper (a (:test) annotation would make the runner execute it).
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

    // Off course (null) advances by GPS delta, then rejoins the route.
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
        // Route says 1150 (behind us): keep counting GPS, never go backwards...
        c.update(1250.0, len - 1150.0);
        Test.assert(c.mode == CourseTracker.MODE_OFF);
        Test.assert(near(c.courseDist, 1250.0, 0.01));
        // ...until the route catches up.
        c.update(1400.0, len - 1300.0);
        Test.assert(c.mode == CourseTracker.MODE_COURSE);
        Test.assert(near(c.courseDist, 1300.0, 0.01));
        return true;
    }

    // Loop course: the watch snaps to the finish (dtd 0) at the start line.
    // Pre-start preview keeps the largest value, so the length is right.
    (:test)
    function courseTrackerPreviewIgnoresFinishSnap(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.preview(21097.5);
        c.preview(3.0);
        c.preview(null);
        Test.assert(c.hasCourse());
        Test.assert(near(c.lengthMeters(), 21097.5, 0.1));
        c.update(0.0, 21097.5);
        c.update(500.0, 20600.0);
        Test.assert(near(c.courseDist, 497.5, 0.1));
        return true;
    }

    // First reading is the distance to the start point (300 m); the real
    // course (21 km) appears a little later. The length re-locks upward.
    (:test)
    function courseTrackerRelocksEarly(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.update(0.0, 300.0);
        c.update(100.0, 200.0);
        Test.assert(near(c.courseDist, 100.0, 0.1));
        c.update(300.0, 21097.5);
        Test.assert(near(c.lengthMeters(), 21197.5, 0.1));
        c.update(1300.0, 20097.5);
        Test.assert(near(c.courseDist, 1100.0, 0.1));
        // Late in the run a bigger dtd (wrong-lap snap) must NOT re-lock.
        c.update(12000.0, 9297.5);
        Test.assert(near(c.courseDist, 11900.0, 0.1));
        c.update(12100.0, 25000.0);
        Test.assert(near(c.lengthMeters(), 21197.5, 0.1));
        Test.assert(near(c.courseDist, 11900.0, 0.1));
        return true;
    }

    // Course value stuck while GPS keeps moving: after 20 s and 50 m switch
    // to GPS distance (OFF), then rejoin when the course value catches up.
    (:test)
    function courseTrackerStallDetection(logger as Logger) as Boolean {
        var c = new CourseTracker();
        var len = 10000.0;
        c.update(0.0, len);
        c.update(1000.0, 9000.0);
        var gps = 1000.0;
        for (var i = 1; i <= 19; i++) {
            gps += 3.0;
            c.update(gps, 9000.0);
        }
        Test.assert(c.mode == CourseTracker.MODE_COURSE);
        Test.assert(near(c.courseDist, 1000.0, 0.01));
        gps += 3.0;
        c.update(gps, 9000.0);
        Test.assert(c.mode == CourseTracker.MODE_OFF);
        Test.assert(near(c.courseDist, 1060.0, 0.01));
        gps += 3.0;
        c.update(gps, 9000.0);
        Test.assert(near(c.courseDist, 1063.0, 0.01));
        c.update(gps + 100.0, 8800.0);
        Test.assert(c.mode == CourseTracker.MODE_COURSE);
        Test.assert(near(c.courseDist, 1200.0, 0.01));
        return true;
    }

    // Official length only applies when the loaded course is within 5%.
    (:test)
    function courseTrackerOfficialMismatch(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.setOfficialLength(21097.5);
        c.preview(8046.0);   // a 5-mile training course with the race setting left on
        Test.assert(c.lengthMismatch);
        Test.assert(near(c.lengthMeters(), 8046.0, 0.1));
        c.update(0.0, 8046.0);
        c.update(4023.0, 4023.0);
        Test.assert(near(c.courseDist, 4023.0, 0.1));
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
        Test.assert(w.evaluate(3.0, null) == WorkoutTarget.STATUS_ON);
        Test.assert(w.evaluate(3.3, null) == WorkoutTarget.STATUS_FAST);
        Test.assert(w.evaluate(2.5, null) == WorkoutTarget.STATUS_SLOW);
        Test.assert(w.evaluate(null, null) == WorkoutTarget.STATUS_NONE);
        // Reversed order is normalised.
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 3100, 2900, null);
        Test.assert(near(w.low, 2.9, 0.0001));
        return true;
    }

    // A zero bound is open on that side: "faster than 9:00" must not flag
    // faster running as TOO FAST.
    (:test)
    function workoutTargetOneSided(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 0, 3000, null);
        Test.assert(w.kind == WorkoutTarget.KIND_PACE);
        Test.assert(w.openLow());
        Test.assert(w.evaluate(2.0, null) == WorkoutTarget.STATUS_ON);
        Test.assert(w.evaluate(3.5, null) == WorkoutTarget.STATUS_FAST);
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 3000, 0, null);
        Test.assert(w.openHigh());
        w.status = WorkoutTarget.STATUS_NONE;
        Test.assert(w.evaluate(5.0, null) == WorkoutTarget.STATUS_ON);
        Test.assert(w.evaluate(2.5, null) == WorkoutTarget.STATUS_SLOW);
        return true;
    }

    // Hysteresis: leaving the range needs 1.5% beyond it; coming back needs
    // to be inside it.
    (:test)
    function workoutTargetHysteresis(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 2900, 3100, null);
        Test.assert(w.evaluate(3.0, null) == WorkoutTarget.STATUS_ON);
        Test.assert(w.evaluate(3.13, null) == WorkoutTarget.STATUS_ON);   // < 1.5% over
        Test.assert(w.evaluate(3.16, null) == WorkoutTarget.STATUS_FAST);
        Test.assert(w.evaluate(3.11, null) == WorkoutTarget.STATUS_FAST); // still just over
        Test.assert(w.evaluate(3.09, null) == WorkoutTarget.STATUS_ON);
        Test.assert(w.evaluate(2.87, null) == WorkoutTarget.STATUS_ON);   // < 1.5% under
        Test.assert(w.evaluate(2.85, null) == WorkoutTarget.STATUS_SLOW);
        return true;
    }

    // Goal pace fallback: 9:00/mi with 10 s leeway when no workout target.
    (:test)
    function workoutTargetGoal(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        Test.assert(w.kind == WorkoutTarget.KIND_PACE);
        Test.assert(w.source == WorkoutTarget.SOURCE_GOAL);
        Test.assert(near(Fmt.M_PER_MI / w.low, 550.0, 0.5));
        Test.assert(near(Fmt.M_PER_MI / w.high, 530.0, 0.5));
        // A real workout target wins over the goal.
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 2900, 3100, null);
        Test.assert(near(w.low, 2.9, 0.001));
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
        Test.assert(w.evaluate(3.0, 150) == WorkoutTarget.STATUS_NONE);
        return true;
    }

    // HR: bpm + 100 encoding, zone number, and percent of max.
    (:test)
    function workoutTargetHeartRate(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 245, 255, null);
        Test.assert(w.kind == WorkoutTarget.KIND_HR);
        Test.assert(near(w.low, 145.0, 0.01) && near(w.high, 155.0, 0.01));
        Test.assert(w.evaluate(null, 160) == WorkoutTarget.STATUS_FAST);
        Test.assert(w.evaluate(null, 150) == WorkoutTarget.STATUS_ON);
        Test.assert(w.evaluate(null, 140) == WorkoutTarget.STATUS_SLOW);

        var zones = [100, 120, 140, 155, 170, 190] as Array<Number>;
        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 2, 2, zones);
        Test.assert(near(w.low, 120.0, 0.01) && near(w.high, 140.0, 0.01));

        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 70, 80, zones);
        Test.assert(near(w.low, 133.0, 0.01) && near(w.high, 152.0, 0.01));
        return true;
    }


    // ---- Robustness: hostile and degenerate inputs -------------------------

    // Garbage from the watch must never throw or produce negative distance.
    (:test)
    function trackerHostileInputs(logger as Logger) as Boolean {
        var c = new CourseTracker();
        c.preview(-5.0);
        c.preview(0.0);
        Test.assert(!c.hasCourse());
        c.update(0.0, -100.0);          // negative dtd treated as no course value
        c.update(-50.0, null);          // GPS going backwards: ignored
        Test.assert(c.courseDist >= 0.0);
        c.update(1000000.0, 0.0);       // dtd 0 with a huge GPS jump
        Test.assert(c.courseDist >= 0.0);
        Test.assert(c.remainingMeters() == null || (c.remainingMeters() as Float) >= 0.0);
        c.setOfficialLength(-1.0);
        c.setOfficialLength(0.0);
        return true;
    }

    (:test)
    function paceBufferHostileInputs(logger as Logger) as Boolean {
        var b = new PaceBuffer(4, 2000);
        Test.assert(b.rollingSecPerMeter(0, 0.0, 1609.344) == null);
        Test.assert(b.smoothedSpeed(0, 0.0, 30000) == null);
        Test.assert(b.timeAtDistance(10.0) == null);
        Test.assert(b.distanceAtTime(10) == null);
        b.add(0, 0.0);
        b.add(2000, 0.0);          // no movement
        b.add(4000, 0.0);
        Test.assert(b.smoothedSpeed(6000, 0.0, 30000) == 0.0);
        Test.assert(b.rollingSecPerMeter(6000, 0.0, 1.0) == null);
        // Window of zero or negative metres must not divide by zero.
        Test.assert(b.rollingSecPerMeter(6000, 100.0, 0.0) == null);
        // Tiny capacity wraps without error.
        for (var i = 0; i < 50; i++) {
            b.add(10000 + i * 2000, i * 10.0);
        }
        Test.assert(b.size() == 4);
        return true;
    }

    (:test)
    function workoutTargetHostileInputs(logger as Logger) as Boolean {
        var w = new WorkoutTarget();
        w.setFrom(null, null, null, null);
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 3, 3, null);      // zone but no zones known
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        w.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 3, 3, [] as Array<Number>);
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        w.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, -5, -5, null);
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        w.setFrom(99, 1, 2, null);                                           // unknown target type
        Test.assert(w.kind == WorkoutTarget.KIND_NONE);
        Test.assert(w.evaluate(null, null) == WorkoutTarget.STATUS_NONE);
        w.setGoal(-1.0, Fmt.M_PER_MI, 10.0);
        Test.assert(w.goalSpeed() == 0.0);
        w.setGoal(540.0, Fmt.M_PER_MI, -10.0);                              // negative leeway = zero
        Test.assert(near(w.low, w.high, 0.0001));
        return true;
    }

    (:test)
    function fmtHostileInputs(logger as Logger) as Boolean {
        Test.assertEqual(Fmt.pace(-1.0), "--:--");
        Test.assertEqual(Fmt.pace(999999.0), "--:--");
        Test.assertEqual(Fmt.paceFromSpeed(0.0, Fmt.M_PER_MI), "--:--");
        Test.assertEqual(Fmt.paceFromSpeed(null, Fmt.M_PER_MI), "--:--");
        Test.assertEqual(Fmt.timer(-5000), "0:00");
        Test.assertEqual(Fmt.parsePace("   ").toString(), "0.000000");
        Test.assertEqual(Fmt.parsePace(":").toString(), "0.000000");
        Test.assertEqual(Fmt.parsePace("1:00").toString(), "0.000000");   // below 2:00 floor
        Test.assertEqual(Fmt.parsePace("45:00").toString(), "0.000000");  // above 30:00 ceiling
        Test.assertEqual(Fmt.parsePace("9:00:00").toString(), "0.000000");
        Test.assertEqual(Fmt.parsePace("-9:00").toString(), "0.000000");
        return true;
    }

    // ---- Efficiency: no heap growth over a long run ------------------------

    // Simulates an hour of once-a-second updates through every model and
    // asserts the heap does not grow. The buffers are allocated once; the
    // per-second path must not allocate anything that survives.
    (:test)
    function noHeapGrowthOverAnHour(logger as Logger) as Boolean {
        var c = new CourseTracker();
        var b = new PaceBuffer(900, 2000);
        var w = new WorkoutTarget();
        w.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        var len = 21097.5;
        // Warm up so lazy allocations happen before measuring.
        for (var s = 1; s <= 600; s++) {
            c.update(s * 3.0, len - s * 2.97);
            b.add(s * 1000, c.courseDist);
            w.evaluate(b.smoothedSpeed(s * 1000, c.courseDist, 30000), 150);
            b.rollingSecPerMeter(s * 1000, c.courseDist, Fmt.M_PER_MI);
        }
        var before = System.getSystemStats().usedMemory;
        for (var s = 601; s <= 4200; s++) {
            c.update(s * 3.0, len - s * 2.97);
            b.add(s * 1000, c.courseDist);
            w.evaluate(b.smoothedSpeed(s * 1000, c.courseDist, 30000), 150);
            b.rollingSecPerMeter(s * 1000, c.courseDist, Fmt.M_PER_MI);
            Fmt.pace(538.0);
            Fmt.timer(s * 1000);
        }
        var after = System.getSystemStats().usedMemory;
        logger.debug("heap before=" + before + " after=" + after);
        Test.assert(after - before < 2048);
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
        Test.assert(near(Fmt.parsePace("9:00"), 540.0, 0.01));
        Test.assert(near(Fmt.parsePace(" 8:45 "), 525.0, 0.01));
        Test.assert(near(Fmt.parsePace("9.5"), 570.0, 0.01));
        Test.assert(near(Fmt.parsePace(""), 0.0, 0.01));
        Test.assert(near(Fmt.parsePace("abc"), 0.0, 0.01));
        Test.assert(near(Fmt.parsePace("9:75"), 0.0, 0.01));
        return true;
    }
}
