import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Full-screen gel reminder pushed by the field (DataField.showAlert), so it
// shows over whichever data page is up. The watch dismisses it on a button
// press or after its timeout.
class GelAlert extends WatchUi.DataFieldAlert {
    hidden var _n as Number;

    function initialize(n as Number) {
        DataFieldAlert.initialize();
        _n = n;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_ORANGE);
        dc.clear();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, Layout.pct(h, 42), Graphics.FONT_LARGE, "GEL " + _n.toString(), Layout.VCENTER);
        dc.drawText(w / 2, Layout.pct(h, 60), Graphics.FONT_SMALL, "TIME TO FUEL", Layout.VCENTER);
    }
}
