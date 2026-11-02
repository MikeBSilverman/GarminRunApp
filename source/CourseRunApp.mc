import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class CourseRunApp extends Application.AppBase {
    hidden var _field as CourseRunField or Null = null;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        _field = new CourseRunField();
        return [_field];
    }

    // On-watch settings, from the activity's settings menu (SettingsMenu.mc).
    function getSettingsView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] or Null {
        return [new SettingsRoot(), new SettingsRootDelegate()];
    }

    // Settings changed in Garmin Connect / Connect IQ app, or on the watch.
    function onSettingsChanged() as Void {
        if (_field != null) {
            (_field as CourseRunField).loadSettings();
        }
        WatchUi.requestUpdate();
    }
}
