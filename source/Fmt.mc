import Toybox.Lang;
import Toybox.System;

// Display formatting. Pace/time helpers adapted from Lift's Utils.mc.
module Fmt {
    const M_PER_MI = 1609.344;
    const M_PER_KM = 1000.0;

    function pad2(n as Number) as String {
        return n < 10 ? "0" + n.toString() : n.toString();
    }

    // Seconds per unit -> "M:SS". Anything slower than 99:59 or null -> "--:--".
    function pace(secPerUnit as Float or Null) as String {
        if (secPerUnit == null || secPerUnit <= 0.0 || secPerUnit >= 6000.0) {
            return "--:--";
        }
        var s = (secPerUnit + 0.5).toNumber();
        return (s / 60).toString() + ":" + pad2(s % 60);
    }

    // m/s -> pace per `unitM` metres.
    function paceFromSpeed(speed as Float or Null, unitM as Float) as String {
        if (speed == null || speed < 0.3) {
            return "--:--";
        }
        return pace(unitM / speed);
    }

    // Metres -> "4.87" in units of `unitM`.
    function dist(meters as Float, unitM as Float) as String {
        return (meters / unitM).format("%.2f");
    }

    // Timer ms -> "M:SS" under an hour, "H:MM:SS" at or above.
    function timer(ms as Number) as String {
        var total = ms / 1000;
        if (total < 0) {
            total = 0;
        }
        var h = total / 3600;
        var m = (total % 3600) / 60;
        var s = total % 60;
        if (h > 0) {
            return h.toString() + ":" + pad2(m) + ":" + pad2(s);
        }
        return m.toString() + ":" + pad2(s);
    }

    // "9:00", "9:0", "9" or "9.5" (decimal minutes) -> seconds per unit.
    // Anything unparseable or out of a sane range (2:00..30:00) -> 0.
    // Only digits, one optional ':' or '.', are accepted; toNumber() alone
    // would happily read "9:00:00" or "9abc" as 9.
    function parsePace(text as String) as Float {
        var s = trim(text);
        if (s.length() == 0 || !digitsAndOne(s, ':') && !digitsAndOne(s, '.')) {
            return 0.0;
        }
        var sec = 0.0;
        var colon = s.find(":");
        if (colon != null) {
            var m = s.substring(0, colon);
            var r = s.substring(colon + 1, s.length());
            if (m == null || m.length() == 0 || r == null || r.length() == 0) {
                return 0.0;
            }
            var mn = m.toNumber();
            var sn = r.toNumber();
            if (mn == null || sn == null || sn >= 60) {
                return 0.0;
            }
            sec = mn * 60.0 + sn;
        } else {
            var f = s.toFloat();
            if (f == null) {
                return 0.0;
            }
            sec = f * 60.0;
        }
        if (sec < 120.0 || sec > 1800.0) {
            return 0.0;
        }
        return sec;
    }

    // True if `s` is digits with at most one occurrence of `sep`.
    function digitsAndOne(s as String, sep as Char) as Boolean {
        var chars = s.toCharArray();
        var seps = 0;
        for (var i = 0; i < chars.size(); i++) {
            var ch = chars[i];
            if (ch == sep) {
                seps++;
            } else if (ch < '0' || ch > '9') {
                return false;
            }
        }
        return seps <= 1;
    }

    function trim(text as String) as String {
        var chars = text.toCharArray();
        var a = 0;
        var b = chars.size();
        while (a < b && chars[a] == ' ') { a++; }
        while (b > a && chars[b - 1] == ' ') { b--; }
        if (a == 0 && b == chars.size()) {
            return text;
        }
        var out = text.substring(a, b);
        return out != null ? out : "";
    }

    // Metres per display distance unit, from the watch's settings.
    function distUnitM() as Float {
        return System.getDeviceSettings().distanceUnits == System.UNIT_METRIC ? M_PER_KM : M_PER_MI;
    }

    // Metres per display pace unit, from the watch's settings.
    function paceUnitM() as Float {
        return System.getDeviceSettings().paceUnits == System.UNIT_METRIC ? M_PER_KM : M_PER_MI;
    }
}
