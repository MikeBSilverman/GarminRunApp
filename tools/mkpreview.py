"""Build a scratch copy of the app with seeded values for one screen state.

Usage: python tools/mkpreview.py <scenario> [dark]
Scenarios: prestart | goal | workout | rest | split | mismatch | offcourse | togo | compact
Output: bin/preview/ (a full project copy with CourseRunField.mc patched)."""
import sys, shutil, os
# scenarios: prestart | goal | workout | rest | split | mismatch | compact
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SP = os.path.join(R, "bin", "preview")
os.makedirs(SP, exist_ok=True)
scenario = sys.argv[1]
dark = len(sys.argv) > 2 and sys.argv[2] == "dark"
for d in ("source", "resources"):
    if os.path.exists(SP + "/" + d):
        shutil.rmtree(SP + "/" + d)
    shutil.copytree(R + "/" + d, SP + "/" + d)
for f in ("manifest.xml", "monkey.jungle", "developer_key.der"):
    shutil.copy(R + "/" + f, SP + "/" + f)

p = SP + "/source/CourseRunField.mc"
s = open(p, newline='').read().replace('\r\n', '\n')

common = '''
        for (var i = 1; i <= 1310; i++) { _buf.add(i * 2000, i * 5.98); }
        _tracker.preview(21097.5);
        _tracker.update(0.0, 21097.5); _tracker.update(7900.0, 21097.5 - 7837.0);
        _timerMs = 2621000; _lastTimerMs = 2621000; _hr = 162; _running = true;
        _speed = 3.05;
'''
seeds = {
    "prestart": '''
        _tracker.preview(21140.0);
        _timerMs = 0;
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
seed = "        _target.refresh();\n        // PREVIEW SEED" + seeds[scenario]
s = s.replace("        _target.refresh();\n    }\n\n    hidden function cacheDeviceSettings", seed + "    }\n\n    hidden function cacheDeviceSettings", 1)
assert "PREVIEW SEED" in s
# freeze compute and periodic refresh
s = s.replace("        var timer = info.timerTime;", "        if (true) { return; }\n        var timer = info.timerTime;", 1)
if dark:
    s = s.replace("        var bg = getBackgroundColor();", "        var bg = Graphics.COLOR_BLACK;", 1)
    s = s.replace("        dc.setColor(fg, bg);\n        dc.clear();", "        dc.setColor(fg, bg);\n        dc.clear();\n        dc.setColor(bg, bg); dc.fillRectangle(0, 0, w, h);", 1)
open(p, "w", newline='').write(s)
print("preview:", scenario, "dark" if dark else "light")
