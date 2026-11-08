"""Build a scratch copy of the app with seeded values for one screen state.

Usage: python tools/mkpreview.py <scenario> [dark]
Scenarios: prestart | goal | hrgoal | workout | workoutcap | gel | rest | split | mismatch | offcourse | togo | compact
           | treadpre | treadmill
Output: bin/preview/ (a full project copy with CourseRunField.mc patched)."""
import os
import shutil
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SP = os.path.join(R, "bin", "preview")
os.makedirs(SP, exist_ok=True)
scenario = sys.argv[1] if len(sys.argv) > 1 else ""
dark = len(sys.argv) > 2 and sys.argv[2] == "dark"
for d in ("source", "resources"):
    if os.path.exists(os.path.join(SP, d)):
        shutil.rmtree(os.path.join(SP, d))
    shutil.copytree(os.path.join(R, d), os.path.join(SP, d))
for f in ("manifest.xml", "monkey.jungle", "developer_key.der"):
    shutil.copy(os.path.join(R, f), os.path.join(SP, f))

p = os.path.join(SP, "source", "CourseRunField.mc")
s = open(p, newline='', encoding='utf-8').read().replace('\r\n', '\n')

common = '''
        for (var i = 1; i <= 1310; i++) { _buf.add(i * 2000, i * 5.98); }
        _tracker.preview(21097.5);
        _tracker.update(0.0, 21097.5); _tracker.update(7900.0, 21097.5 - 7837.0);
        _timerMs = 2621000; _lastTimerMs = 2621000; _hr = 162; _running = true;
'''
seeds = {
    "prestart": '''
        _tracker.preview(21140.0);
        _timerMs = 0;
''',
    "hrgoal": common + '''
        _target.setGoalHr("145");
        _target.evaluate(2.9, 152);
''',
    "treadpre": '''
        _treadmill = true;
        _timerMs = 0;
''',
    "treadmill": '''
        _treadmill = true;
        for (var i = 1; i <= 600; i++) { _buf.add(i * 2000, i * 5.98); }
        _tracker.update(0.0, null); _tracker.update(3590.0, null);
        _timerMs = 1200000; _lastTimerMs = 1200000; _hr = 138; _running = true;
        _target.setGoalHr("145");
        _target.evaluate(2.9, 138);
''',
    "goal": common + '''
        _target.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        _target.evaluate(2.90, 162);
''',
    "workout": common + '''
        _target.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 2930, 3070, null);
        _target.source = WorkoutTarget.SOURCE_WORKOUT; _target.hasWorkout = true; _target.stepLabel = "RUN";
        _target.evaluate(3.2, 162); _target.evaluate(3.2, 162);
''',
    "workoutcap": common + '''
        _target.setGoalHr("130-148");
        _target.setFrom(Activity.WORKOUT_STEP_TARGET_SPEED, 2930, 3070, null);
        _target.source = WorkoutTarget.SOURCE_WORKOUT; _target.hasWorkout = true; _target.stepLabel = "RUN";
        _target.stepMs = 420000; _stepStartMs = _timerMs - 200000; _stepStartDist = _tracker.courseDist - 640.0;
        for (var i = 1; i <= 60; i++) { _gpsBuf.add(_timerMs - 120000 + i * 2000, i * 6.0); }
        _gpsDist = 360.0;
        _hr = 152; _target.evaluate(3.0, 152); _target.evaluate(3.0, 152);
''',
    "gel": common + '''
        _target.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        _target.evaluate(2.98, 162);
        _gel.setTimes(43, 30); _gel.check(_timerMs);
''',
    "rest": common + '''
        _target.hasWorkout = true; _target.isRest = true; _target.stepLabel = "RECOVERY";
''',
    "split": common + '''
        _target.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        _target.evaluate(3.0, 162);
        _splitText = "MI 5  8:52"; _splitUntilMs = _timerMs + 60000;
''',
    "mismatch": '''
        _officialLen = 13.11; _tracker.setOfficialLength(13.11 * Fmt.M_PER_MI);
        _tracker.preview(8046.0);
        _timerMs = 0;
''',
    "offcourse": common + '''
        _target.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        _target.evaluate(2.75, 162);
        _tracker.mode = CourseTracker.MODE_OFF;
''',
    "togo": common + '''
        _target.setFrom(Activity.WORKOUT_STEP_TARGET_HEART_RATE, 245, 260, null);
        _target.source = WorkoutTarget.SOURCE_WORKOUT; _target.hasWorkout = true; _target.stepLabel = "TEMPO";
        _target.evaluate(3.0, 152);
        _showToGo = true;
''',
    "compact": common + '''
        _target.setGoal(540.0, Fmt.M_PER_MI, 10.0);
        _target.evaluate(3.0, 162);
        _screenH = 2000;
''',
}


def patch(src, old, new):
    """Replace `old` once; fail loudly if the field's code has moved on."""
    assert old in src, "mkpreview anchor not found: " + old.strip().split("\n")[0]
    return src.replace(old, new, 1)


if scenario not in seeds:
    sys.exit("scenario must be one of: " + " | ".join(sorted(seeds)))
seed = "        loadSettings();\n        // PREVIEW SEED" + seeds[scenario]
s = patch(s, "        loadSettings();\n    }\n\n    hidden function cacheDeviceSettings",
          seed + "    }\n\n    hidden function cacheDeviceSettings")
# freeze compute and periodic refresh
s = patch(s, "        var timer = info.timerTime;", "        if (true) { return; }\n        var timer = info.timerTime;")
if dark:
    s = patch(s, "        var bg = getBackgroundColor();", "        var bg = Graphics.COLOR_BLACK;")
    s = patch(s, "        dc.setColor(fg, bg);\n        dc.clear();",
              "        dc.setColor(fg, bg);\n        dc.clear();\n        dc.setColor(bg, bg); dc.fillRectangle(0, 0, w, h);")
open(p, "w", newline='', encoding='utf-8').write(s)
print("preview:", scenario, "dark" if dark else "light")
