// -*- mode: Javascript;-*-

import Toybox.Lang;
using Toybox.Application as App;

var view as HrWidgetView or Null;
var model as PersistentChartModel or Null;

// Storage keys must be strings (symbols are not stable across builds).
const LAST_VALUES = "last_values";
const LAST_VALUE_TIME = "last_value_time";
const RANGE_MULT = "range_mult";
const INVERT = "invert";
const ALERT_ENABLED = "alert_enabled";
const ALERT_THRESHOLD = "alert_threshold";

class HrWidgetApp extends App.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        view = new HrWidgetView();
    }

    function onStop(state) {
        // Write here for the app case
        if (model != null) {
            model.write_data();
        }
    }

    function getInitialView() {
        return [view, new HrWidgetDelegate()];
    }
}
