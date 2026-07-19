// -*- mode: Javascript;-*-

import Toybox.Lang;
using Toybox.Application as App;

var view as HrWidgetView or Null;
var model as PersistentChartModel or Null;
var hrModel as PersistentChartModel or Null;
var hrvModel as PersistentChartModel or Null;

// Storage keys must be strings (symbols are not stable across builds).
const LAST_VALUES = "last_values";
const LAST_VALUE_TIME = "last_value_time";
const RANGE_MULT = "range_mult";
const INVERT = "invert";
const ALERT_ENABLED = "alert_enabled";
const ALERT_THRESHOLD = "alert_threshold";
const PLOT_MODE = "plot_mode";
const HRV_WINDOW = "hrv_window";

// Plot modes
const MODE_HR = 0;
const MODE_HRV = 1;

// Default rolling RMSSD window (seconds). User can change via menu.
const HRV_WINDOW_DEFAULT = 60;


class HrWidgetApp extends App.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        view = new HrWidgetView();
    }

    function onStop(state) {
        // Ensure sensors are released when the process ends (menu may have
        // kept them running while stacked over the main view).
        if (view != null) {
            view.keepSensorsForMenu = false;
            view.stopSensors();
        }
        // Write here for the app case
        if (hrModel != null) {
            hrModel.write_data();
        }
        if (hrvModel != null) {
            hrvModel.write_data();
        }
    }


    function getInitialView() {
        return [view, new HrWidgetDelegate()];
    }
}
