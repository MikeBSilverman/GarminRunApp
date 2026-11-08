import Toybox.Application;
import Toybox.Lang;

// Guarded reads and writes of the app's settings (Application.Properties),
// shared by the field and the on-watch settings menu. A missing key reads
// as its properties.xml default; `dflt` covers a firmware that throws.
module Props {
    function num(key as String, dflt as Float) as Float {
        try {
            var v = Application.Properties.getValue(key);
            if (v instanceof Number || v instanceof Float || v instanceof Double) {
                return v.toFloat();
            }
        } catch (e) {
        }
        return dflt;
    }

    function str(key as String) as String {
        try {
            var v = Application.Properties.getValue(key);
            if (v instanceof String) {
                return v;
            }
        } catch (e) {
        }
        return "";
    }

    // Writes a setting, then reloads it into the running field.
    function set(key as String, value as Number or String) as Void {
        try {
            Application.Properties.setValue(key, value);
        } catch (e) {
            return;
        }
        (Application.getApp() as CourseRunApp).onSettingsChanged();
    }
}
