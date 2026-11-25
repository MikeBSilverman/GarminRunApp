import Toybox.Lang;

// What the screen shows once LAP has been pressed, kept apart from the
// drawing so it can be unit tested: whether the hero splits, which pace the
// right of row 2 shows, and how band line 2 shares its slot with the
// projected finish.
module LapLogic {
    // Right-hand pace of row 2.
    const RIGHT_STEP = 0;      // workout: LAST 30S of the step
    const RIGHT_LAP = 1;       // "Lap average" setting: LAP PACE
    const RIGHT_LAP_AVG = 2;   // a lap shorter than the rolling window
    const RIGHT_ROLLING = 3;   // LAST MI / LAST KM

    const ROLLING_UNIT_LAP = 3;   // the rollingUnit setting's "Lap average"
    const FIN_SWAP_MS = 3000;     // band line 2 and FIN take turns this long

    // LAP pressed (or a workout step ended) on a run that is not in a
    // workout now: the hero splits into total | lap distance and the
    // projected finish moves to the band.
    function split(lapStartMs as Number, inWorkout as Boolean) as Boolean {
        return lapStartMs > 0 && !inWorkout;
    }

    // The rolling pace restarts at a lap: the lap's own average until the
    // lap covers a full window (lapM < windowM), then the rolling pace again.
    function rightMode(inWorkout as Boolean, rollingUnit as Number, lapStartMs as Number,
                       lapM as Float, windowM as Float) as Number {
        if (inWorkout) {
            return RIGHT_STEP;
        }
        if (rollingUnit == ROLLING_UNIT_LAP) {
            return RIGHT_LAP;
        }
        return lapStartMs > 0 && lapM < windowM ? RIGHT_LAP_AVG : RIGHT_ROLLING;
    }

    // A right-hand pace that isn't ready yet shows the overall average,
    // dimmed; a step's or a young lap's own number shows "--" instead.
    function fallsBackToAverage(mode as Number) as Boolean {
        return mode == RIGHT_ROLLING || mode == RIGHT_LAP;
    }

    // Band line 2 and the finish on one line ("AHEAD 0:09 · 1:57:35").
    function joined(line2 as String, finTimer as String) as String {
        return line2 + " · " + finTimer;
    }

    // Band line 2 once the finish has moved into the band: the finish alone
    // when the band has nothing of its own, both when `joinedFits` the
    // chord, else taking turns every FIN_SWAP_MS of timer time.
    function bandLine2(line2 as String, finTimer as String, joinedFits as Boolean,
                       timerMs as Number) as String {
        if (line2.length() == 0) {
            return "FIN " + finTimer;
        }
        if (joinedFits) {
            return joined(line2, finTimer);
        }
        return (timerMs / FIN_SWAP_MS) % 2 == 0 ? line2 : "FIN " + finTimer;
    }
}
