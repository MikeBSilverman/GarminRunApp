import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// On-watch settings (AppBase.getSettingsView, opened from the activity's
// settings menu). Lists and pickers only: the watch has no keyboard. Writes
// the same properties as the phone app, then reloads the field. Course
// length and smoothing stay phone-only (set once, rarely touched).

// Numeric settings picked from a list: [property, title, values, labels].
// Labels are Strings or string resource ids (shared with the phone app).
module SettingsLists {
    function all() as Array<Array> {
        return [
            ["gelFirst", "First gel", [0, 30, 40, 45, 50, 60, 75, 90],
             ["Off", "30 min", "40 min", "45 min", "50 min", "60 min", "75 min", "90 min"]],
            ["gelEvery", "Then every", [0, 20, 25, 30, 35, 40, 45],
             ["Just one", "20 min", "25 min", "30 min", "35 min", "40 min", "45 min"]],
            ["goalTolerance", "Pace leeway", [5, 10, 15, 20, 30],
             ["5 s", "10 s", "15 s", "20 s", "30 s"]],
            ["alerts", "Drift alerts", [0, 1, 2],
             [Rez.Strings.AlertsOff, Rez.Strings.AlertsGoal, Rez.Strings.AlertsAlways]],
            ["rollingUnit", "Right-hand pace", [0, 1, 2, 3],
             [Rez.Strings.UnitAuto, Rez.Strings.UnitMile, Rez.Strings.UnitKm, Rez.Strings.UnitLap]],
            ["distanceMode", "Big number", [0, 1],
             [Rez.Strings.DistanceRun, Rez.Strings.DistanceToGo]]
        ] as Array<Array>;
    }

    function label(l as String or ResourceId) as String {
        return l instanceof String ? l : WatchUi.loadResource(l as ResourceId) as String;
    }

    function getNum(key as String, dflt as Number) as Number {
        try {
            var v = Application.Properties.getValue(key);
            if (v instanceof Number || v instanceof Float) {
                return v.toNumber();
            }
        } catch (e) {
        }
        return dflt;
    }

    function getStr(key as String) as String {
        try {
            var v = Application.Properties.getValue(key);
            if (v instanceof String) {
                return v;
            }
        } catch (e) {
        }
        return "";
    }

    function set(key as String, value as Number or String) as Void {
        try {
            Application.Properties.setValue(key, value);
        } catch (e) {
            return;
        }
        (Application.getApp() as CourseRunApp).onSettingsChanged();
    }

    // Index of v in values, or of the nearest value below it, or 0.
    function indexOf(values as Array<Number>, v as Number) as Number {
        var best = 0;
        for (var i = 0; i < values.size(); i++) {
            if (values[i] <= v) {
                best = i;
            }
        }
        return best;
    }

    function listSub(def as Array) as String {
        var values = def[2] as Array<Number>;
        var labels = def[3] as Array;
        var dflt = (def[0] as String).equals("gelEvery") ? 30 : ((def[0] as String).equals("goalTolerance") ? 10
                   : ((def[0] as String).equals("alerts") ? 1 : 0));
        var v = getNum(def[0] as String, dflt);
        for (var i = 0; i < values.size(); i++) {
            if (values[i] == v) {
                return label(labels[i] as String or ResourceId);
            }
        }
        return v.toString();
    }

    function paceUnitText() as String {
        return System.getDeviceSettings().paceUnits == System.UNIT_METRIC ? " /km" : " /mi";
    }

    function paceSub() as String {
        var sec = Fmt.parsePace(getStr("goalPace"));
        return sec > 0.0 ? Fmt.pace(sec) + paceUnitText() : "Off";
    }

    // The goal HR setting text as people read it.
    function hrSub() as String {
        var s = Fmt.trim(getStr("goalHr"));
        if (s.length() == 0) {
            return "Off";
        }
        var dash = s.find("-");
        var hi = (dash != null ? s.substring(dash + 1, s.length()) : s) as String;
        var n = hi.toNumber();
        if (n != null && n <= 5) {
            return (dash != null ? "Zones " : "Zone ") + s;
        }
        return (dash != null ? s : "Under " + s) + " bpm";
    }
}

class SettingsRoot extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({:title => "CourseRun"});
        addItem(new WatchUi.MenuItem("Goal pace", SettingsLists.paceSub(), :pace, null));
        addItem(new WatchUi.MenuItem("Goal heart rate", SettingsLists.hrSub(), :hr, null));
        var defs = SettingsLists.all();
        for (var i = 0; i < defs.size(); i++) {
            addItem(new WatchUi.MenuItem(defs[i][1] as String, SettingsLists.listSub(defs[i]), i, null));
        }
    }
}

class SettingsRootDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :pace) {
            var m = new WatchUi.Menu2({:title => "Goal pace"});
            m.addItem(new WatchUi.MenuItem("Off", null, :off, null));
            m.addItem(new WatchUi.MenuItem("Set pace", SettingsLists.paceSub(), :set, null));
            WatchUi.pushView(m, new PaceMenuDelegate(item), WatchUi.SLIDE_LEFT);
        } else if (id == :hr) {
            var h = new WatchUi.Menu2({:title => "Goal HR"});
            h.addItem(new WatchUi.MenuItem("Off", null, "", null));
            h.addItem(new WatchUi.MenuItem("Zone 2", null, "2", null));
            h.addItem(new WatchUi.MenuItem("Zones 1-2", null, "1-2", null));
            h.addItem(new WatchUi.MenuItem("Ceiling", "Only warn above", :ceiling, null));
            h.addItem(new WatchUi.MenuItem("Range", "Low and high bpm", :range, null));
            WatchUi.pushView(h, new HrMenuDelegate(item), WatchUi.SLIDE_LEFT);
        } else if (id instanceof Number) {
            var def = SettingsLists.all()[id];
            var values = def[2] as Array<Number>;
            var labels = def[3] as Array;
            var c = new WatchUi.Menu2({:title => def[1] as String});
            for (var i = 0; i < values.size(); i++) {
                c.addItem(new WatchUi.MenuItem(SettingsLists.label(labels[i] as String or ResourceId), null, i, null));
            }
            var cur = SettingsLists.getNum(def[0] as String, values[0]);
            c.setFocus(SettingsLists.indexOf(values, cur));
            WatchUi.pushView(c, new ListMenuDelegate(item, def), WatchUi.SLIDE_LEFT);
        }
    }
}

class ListMenuDelegate extends WatchUi.Menu2InputDelegate {
    hidden var _parent as WatchUi.MenuItem;
    hidden var _def as Array;

    function initialize(parent as WatchUi.MenuItem, def as Array) {
        Menu2InputDelegate.initialize();
        _parent = parent;
        _def = def;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var values = _def[2] as Array<Number>;
        SettingsLists.set(_def[0] as String, values[item.getId() as Number]);
        _parent.setSubLabel(SettingsLists.listSub(_def));
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

class PaceMenuDelegate extends WatchUi.Menu2InputDelegate {
    hidden var _parent as WatchUi.MenuItem;

    function initialize(parent as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        _parent = parent;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (item.getId() == :off) {
            SettingsLists.set("goalPace", "");
            _parent.setSubLabel(SettingsLists.paceSub());
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }
        // Minutes : seconds in 5 s steps, starting at the current goal.
        var sec = Fmt.parsePace(SettingsLists.getStr("goalPace"));
        var s = sec > 0.0 ? (sec + 0.5).toNumber() : 540;
        var mins = new NumberFactory(4, 15, 1, false);
        var secs = new NumberFactory(0, 55, 5, true);
        var picker = new WatchUi.Picker({
            :title => new WatchUi.Text({:text => "Goal pace" + SettingsLists.paceUnitText(),
                                        :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                                        :locY => WatchUi.LAYOUT_VALIGN_BOTTOM,
                                        :color => Graphics.COLOR_WHITE}),
            :pattern => [mins, new WatchUi.Text({:text => ":", :font => Graphics.FONT_LARGE,
                                                 :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                                                 :locY => WatchUi.LAYOUT_VALIGN_CENTER,
                                                 :color => Graphics.COLOR_WHITE}), secs],
            :defaults => [mins.indexOf(s / 60), 0, secs.indexOf(s % 60)]
        });
        WatchUi.pushView(picker, new PacePickerDelegate(_parent), WatchUi.SLIDE_LEFT);
    }
}

class PacePickerDelegate extends WatchUi.PickerDelegate {
    hidden var _parent as WatchUi.MenuItem;

    function initialize(parent as WatchUi.MenuItem) {
        PickerDelegate.initialize();
        _parent = parent;
    }

    function onAccept(values as Array) as Boolean {
        var m = values[0] as Number;
        var s = values[2] as Number;
        SettingsLists.set("goalPace", m.toString() + ":" + Fmt.pad2(s));
        _parent.setSubLabel(SettingsLists.paceSub());
        WatchUi.popView(WatchUi.SLIDE_RIGHT);   // the picker
        WatchUi.popView(WatchUi.SLIDE_RIGHT);   // Off / Set pace
        return true;
    }

    function onCancel() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

class HrMenuDelegate extends WatchUi.Menu2InputDelegate {
    hidden var _parent as WatchUi.MenuItem;

    function initialize(parent as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        _parent = parent;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof String) {
            SettingsLists.set("goalHr", id);
            _parent.setSubLabel(SettingsLists.hrSub());
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }
        // Start from the current bpm goal (zones and blank start at 130-148).
        var spec = Fmt.trim(SettingsLists.getStr("goalHr"));
        var dash = spec.find("-");
        var lo = (dash != null ? spec.substring(0, dash) : "") as String;
        var hi = (dash != null ? spec.substring(dash + 1, spec.length()) : spec) as String;
        var loN = lo.toNumber();
        var hiN = hi.toNumber();
        if (hiN == null || hiN < 90) {
            hiN = 148;
        }
        if (loN == null || loN < 80) {
            loN = 130;
        }
        var title = new WatchUi.Text({:text => id == :range ? "Low - high bpm" : "Warn above bpm",
                                      :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                                      :locY => WatchUi.LAYOUT_VALIGN_BOTTOM,
                                      :color => Graphics.COLOR_WHITE});
        var hiF = new NumberFactory(90, 200, 1, false);
        var picker;
        if (id == :range) {
            var loF = new NumberFactory(80, 190, 1, false);
            picker = new WatchUi.Picker({
                :title => title,
                :pattern => [loF, new WatchUi.Text({:text => "-", :font => Graphics.FONT_LARGE,
                                                    :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                                                    :locY => WatchUi.LAYOUT_VALIGN_CENTER,
                                                    :color => Graphics.COLOR_WHITE}), hiF],
                :defaults => [loF.indexOf(loN), 0, hiF.indexOf(hiN)]
            });
        } else {
            picker = new WatchUi.Picker({:title => title, :pattern => [hiF], :defaults => [hiF.indexOf(hiN)]});
        }
        WatchUi.pushView(picker, new HrPickerDelegate(_parent), WatchUi.SLIDE_LEFT);
    }
}

class HrPickerDelegate extends WatchUi.PickerDelegate {
    hidden var _parent as WatchUi.MenuItem;

    function initialize(parent as WatchUi.MenuItem) {
        PickerDelegate.initialize();
        _parent = parent;
    }

    function onAccept(values as Array) as Boolean {
        var spec;
        if (values.size() >= 3) {
            var a = values[0] as Number;
            var b = values[2] as Number;
            spec = (a < b ? a : b).toString() + "-" + (a < b ? b : a).toString();
        } else {
            spec = (values[0] as Number).toString();
        }
        SettingsLists.set("goalHr", spec);
        _parent.setSubLabel(SettingsLists.hrSub());
        WatchUi.popView(WatchUi.SLIDE_RIGHT);   // the picker
        WatchUi.popView(WatchUi.SLIDE_RIGHT);   // the HR choices
        return true;
    }

    function onCancel() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

// lo..hi in steps, as picker entries.
class NumberFactory extends WatchUi.PickerFactory {
    hidden var _lo as Number;
    hidden var _hi as Number;
    hidden var _step as Number;
    hidden var _pad as Boolean;

    function initialize(lo as Number, hi as Number, step as Number, pad as Boolean) {
        PickerFactory.initialize();
        _lo = lo;
        _hi = hi;
        _step = step;
        _pad = pad;
    }

    function getSize() as Number {
        return (_hi - _lo) / _step + 1;
    }

    function getValue(index as Number) as Object or Null {
        return _lo + index * _step;
    }

    function getDrawable(index as Number, selected as Boolean) as WatchUi.Drawable or Null {
        var v = _lo + index * _step;
        return new WatchUi.Text({:text => _pad ? Fmt.pad2(v) : v.toString(),
                                 :font => Graphics.FONT_NUMBER_MILD,
                                 :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                                 :locY => WatchUi.LAYOUT_VALIGN_CENTER,
                                 :color => Graphics.COLOR_WHITE});
    }

    // Index of the nearest step at or below v, clamped.
    function indexOf(v as Number) as Number {
        var i = (v - _lo) / _step;
        var n = getSize();
        return i < 0 ? 0 : (i >= n ? n - 1 : i);
    }
}
