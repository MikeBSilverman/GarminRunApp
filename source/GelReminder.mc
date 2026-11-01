import Toybox.Lang;

// Fuel reminders on the activity timer (paused time doesn't count): the first
// at firstMin, then every everyMin (0 = just the one). firstMin 0 = off.
class GelReminder {
    hidden const SHOW_MS = 60000;   // how long the screen shows a reminder

    var count as Number = 0;        // reminders given this run
    hidden var _firstMs as Number = 0;
    hidden var _everyMs as Number = 0;
    hidden var _sinceMs as Number = -1;   // timer at the last reminder

    function initialize() {
    }

    function setTimes(firstMin as Number, everyMin as Number) as Void {
        _firstMs = firstMin > 0 ? firstMin * 60000 : 0;
        _everyMs = everyMin > 0 ? everyMin * 60000 : 0;
    }

    // Reminders due by timerMs.
    function dueBy(timerMs as Number) as Number {
        if (_firstMs <= 0 || timerMs < _firstMs) {
            return 0;
        }
        if (_everyMs <= 0) {
            return 1;
        }
        return (timerMs - _firstMs) / _everyMs + 1;
    }

    // A running tick: true when a new reminder is due (buzz once).
    function check(timerMs as Number) as Boolean {
        var n = dueBy(timerMs);
        if (n <= count) {
            return false;
        }
        count = n;
        _sinceMs = timerMs;
        return true;
    }

    // Catch up silently (Resume Later restore): reminders already given
    // before the field was reloaded aren't repeated.
    function skipTo(timerMs as Number) as Void {
        count = dueBy(timerMs);
    }

    function reset() as Void {
        count = 0;
        _sinceMs = -1;
    }

    function showing(timerMs as Number) as Boolean {
        return _sinceMs >= 0 && timerMs >= _sinceMs && timerMs - _sinceMs < SHOW_MS;
    }
}
