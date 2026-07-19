// -*- mode: Javascript;-*-

import Toybox.Lang;
using Toybox.System as System;
using Toybox.Application as App;
using Toybox.Application.Storage;

class PersistentChartModel extends ChartModel {
    function initialize() {
        ChartModel.initialize();
    }

    function read_data() as Void {
        try {
            var old_range_mult = Storage.getValue(RANGE_MULT);
            if (old_range_mult != null) {
                range_mult = old_range_mult as Number or Float;
            }
            else {
                range_mult = 1;
            }

            var old_values = Storage.getValue(LAST_VALUES) as Array or Null;
            var old_time = Storage.getValue(LAST_VALUE_TIME);
            if (old_values != null && old_time != null) {
                values = new[values_size] as Array<Number or Null>;
                var delta = (System.getTimer() - (old_time as Number)) / 1000 / range_mult;
                if (delta > 0) { // Ignore old data from before reboot
                    for (var i = 0; i < values.size() - delta; i++) {
                        values[i] = old_values[i + delta] as Number or Null;
                    }
                }
            }
            else {
                values = new[values_size] as Array<Number or Null>;
            }
        }
        catch (ex) {
            values = new[values_size] as Array<Number or Null>;
            range_mult = 1;
        }

        update_min_max();
    }

    function write_data() as Void {
        Storage.setValue(LAST_VALUES, values);
        Storage.setValue(LAST_VALUE_TIME, System.getTimer());
        Storage.setValue(RANGE_MULT, range_mult);
    }
}
