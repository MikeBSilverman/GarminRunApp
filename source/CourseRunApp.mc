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

    // Settings changed in Garmin Connect / Connect IQ app.
    function onSettingsChanged() as Void {
        if (_field != null) {
            (_field as CourseRunField).loadSettings();
        }
        WatchUi.requestUpdate();
    }
}
