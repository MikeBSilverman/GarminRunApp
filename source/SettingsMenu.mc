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

    // A list setting's value. A missing key reads as its properties.xml
    // default, so the first list value only covers a throwing firmware.
    function num(def as Array) as Number {
        return Props.num(def[0] as String, ((def[2] as Array<Number>)[0]).toFloat()).toNumber();
    }

    // The root item's sublabel for a list def, "goalPace" or "goalHr".
    function sub(key as String or Array) as String {
        if (key instanceof Array) {
            return listSub(key);
        }
        return key.equals("goalPace") ? paceSub() : hrSub();
    }

    // Saves a choice, refreshes the root item's sublabel and closes `pops` views.
    function commit(key as String, value as Number or String, parent as WatchUi.MenuItem,
                    subKey as String or Array, pops as Number) as Void {
        Props.set(key, value);
        parent.setSubLabel(sub(subKey));
        for (var i = 0; i < pops; i++) {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }

    // White centred picker text: a title (bottom-aligned), a separator or an entry.
    function text(t as String, font as Graphics.FontDefinition or Null, title as Boolean) as WatchUi.Text {
        var opts = {:text => t,
                    :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                    :locY => title ? WatchUi.LAYOUT_VALIGN_BOTTOM : WatchUi.LAYOUT_VALIGN_CENTER,
                    :color => Graphics.COLOR_WHITE};
        if (font != null) {
            opts[:font] = font;
        }
        return new WatchUi.Text(opts);
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
        var v = num(def);
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
        var sec = Fmt.parsePace(Props.str("goalPace"));
        return sec > 0.0 ? Fmt.pace(sec) + paceUnitText() : "Off";
    }

    // The goal HR setting text as people read it.
    function hrSub() as String {
        var s = Fmt.trim(Props.str("goalHr"));
        if (s.length() == 0) {
            return "Off";
        }
        var parts = Fmt.splitDash(s);
        var range = parts[0] != null;
        var n = parts[1].toNumber();
        if (n != null && n <= 5) {
            return (range ? "Zones " : "Zone ") + s;
        }
        return (range ? s : "Under " + s) + " bpm";
    }
}

class SettingsRoot extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({:title => "CourseRun"});
        addItem(new WatchUi.MenuItem("Goal pace", SettingsLists.paceSub(), :pace, null));
        addItem(new WatchUi.MenuItem("Goal heart rate", SettingsLists.hrSub(), :hr, null));
        var defs = SettingsLists.all();
        for (var i = 0; i < defs.size(); i++) {
            addItem(new WatchUi.MenuItem(defs[i][1] as String, SettingsLists.listSub(defs[i]), defs[i], null));
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
        } else if (id instanceof Array) {
            var def = id;
            var values = def[2] as Array<Number>;
            var labels = def[3] as Array;
            var c = new WatchUi.Menu2({:title => def[1] as String});
            for (var i = 0; i < values.size(); i++) {
                c.addItem(new WatchUi.MenuItem(SettingsLists.label(labels[i] as String or ResourceId), null, i, null));
            }
            c.setFocus(SettingsLists.indexOf(values, SettingsLists.num(def)));
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
        SettingsLists.commit(_def[0] as String, values[item.getId() as Number], _parent, _def, 1);
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
            SettingsLists.commit("goalPace", "", _parent, "goalPace", 1);
            return;
        }
        // Minutes : seconds in 5 s steps, starting at the current goal.
        var sec = Fmt.parsePace(Props.str("goalPace"));
        var s = sec > 0.0 ? (sec + 0.5).toNumber() : 540;
        var mins = new NumberFactory(4, 15, 1, false);
        var secs = new NumberFactory(0, 55, 5, true);
        var picker = new WatchUi.Picker({
            :title => SettingsLists.text("Goal pace" + SettingsLists.paceUnitText(), null, true),
            :pattern => [mins, SettingsLists.text(":", Graphics.FONT_LARGE, false), secs],
            :defaults => [mins.indexOf(s / 60), 0, secs.indexOf(s % 60)]
        });
        WatchUi.pushView(picker, new GoalPickerDelegate(_parent, "goalPace"), WatchUi.SLIDE_LEFT);
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
            SettingsLists.commit("goalHr", id, _parent, "goalHr", 1);
            return;
        }
        // Start from the current bpm goal (zones and blank start at 130-148).
        var parts = Fmt.splitDash(Fmt.trim(Props.str("goalHr")));
        var loN = parts[0] != null ? (parts[0] as String).toNumber() : null;
        var hiN = parts[1].toNumber();
        if (hiN == null || hiN < 90) {
            hiN = 148;
        }
        if (loN == null || loN < 80) {
            loN = 130;
        }
        var title = SettingsLists.text(id == :range ? "Low - high bpm" : "Warn above bpm", null, true);
        var hiF = new NumberFactory(90, 200, 1, false);
        var picker;
        if (id == :range) {
            var loF = new NumberFactory(80, 190, 1, false);
            picker = new WatchUi.Picker({
                :title => title,
                :pattern => [loF, SettingsLists.text("-", Graphics.FONT_LARGE, false), hiF],
                :defaults => [loF.indexOf(loN), 0, hiF.indexOf(hiN)]
            });
        } else {
            picker = new WatchUi.Picker({:title => title, :pattern => [hiF], :defaults => [hiF.indexOf(hiN)]});
        }
        WatchUi.pushView(picker, new GoalPickerDelegate(_parent, "goalHr"), WatchUi.SLIDE_LEFT);
    }
}

// Accepts a goal picker: pace as m:ss (minutes : seconds columns), HR as
// one ceiling or a low - high pair. Closes the picker and the choice menu.
class GoalPickerDelegate extends WatchUi.PickerDelegate {
    hidden var _parent as WatchUi.MenuItem;
    hidden var _key as String;

    function initialize(parent as WatchUi.MenuItem, key as String) {
        PickerDelegate.initialize();
        _parent = parent;
        _key = key;
    }

    function onAccept(values as Array) as Boolean {
        var spec;
        if (_key.equals("goalPace")) {
            spec = (values[0] as Number).toString() + ":" + Fmt.pad2(values[2] as Number);
        } else if (values.size() >= 3) {
            var a = values[0] as Number;
            var b = values[2] as Number;
            spec = (a < b ? a : b).toString() + "-" + (a < b ? b : a).toString();
        } else {
            spec = (values[0] as Number).toString();
        }
        SettingsLists.commit(_key, spec, _parent, _key, 2);
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
        return SettingsLists.text(_pad ? Fmt.pad2(v) : v.toString(), Graphics.FONT_NUMBER_MILD, false);
    }

    // Index of the nearest step at or below v, clamped.
    function indexOf(v as Number) as Number {
        var i = (v - _lo) / _step;
        var n = getSize();
        return i < 0 ? 0 : (i >= n ? n - 1 : i);
    }
}
