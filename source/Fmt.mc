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

    // Metres per display distance unit, from the watch's settings.
    function distUnitM() as Float {
        return System.getDeviceSettings().distanceUnits == System.UNIT_METRIC ? M_PER_KM : M_PER_MI;
    }

    // Metres per display pace unit, from the watch's settings.
    function paceUnitM() as Float {
        return System.getDeviceSettings().paceUnits == System.UNIT_METRIC ? M_PER_KM : M_PER_MI;
    }
}
