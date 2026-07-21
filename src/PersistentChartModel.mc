// -*- mode: Javascript;-*-

import Toybox.Lang;
using Toybox.System as System;
using Toybox.Application as App;
using Toybox.Application.Storage;

// Connect IQ Storage cannot store null. Encode chart gaps as this sentinel
// (invalid for HR bpm, RMSSD ms, and lnRMSSD) and convert back on read.
const STORAGE_NULL_SENTINEL = -1;

class PersistentChartModel extends ChartModel {
    private var mKeyPrefix as String;

    function initialize(keyPrefix as String) {
        mKeyPrefix = keyPrefix;
        ChartModel.initialize();
    }

    private function key(name as String) as String {
        return mKeyPrefix + name;
    }

    function read_data() as Void {
        try {
            // Caller may pre-set range_mult = 0 for point-series (HRV bursts).
            var pointSeries = (range_mult != null && range_mult.toFloat() <= 0);

            if (!pointSeries) {
                var old_range_mult = Storage.getValue(key(RANGE_MULT));
                if (old_range_mult != null) {
                    range_mult = old_range_mult as Number or Float;
                } else {
                    // Fall back to shared range so HR stays consistent on first run.
                    var shared = Storage.getValue(RANGE_MULT);
                    if (shared != null) {
                        range_mult = shared as Number or Float;
                    } else {
                        range_mult = 1;
                    }
                }

                // Guard against corrupt / zero range in time-series mode.
                if (range_mult == null || range_mult.toFloat() <= 0) {
                    range_mult = 1;
                }
            } else {
                // Keep point-series marker; still persist 0 on write.
                range_mult = 0;
            }

            var old_values = Storage.getValue(key(LAST_VALUES)) as Array or Null;
            var old_time = Storage.getValue(key(LAST_VALUE_TIME));
            values = new[values_size] as Array<Numeric or Null>;

            if (old_values != null) {
                var srcSize = old_values.size();
                if (pointSeries) {
                    // Point-series mode (HRV bursts): restore slots as-is, no time aging.
                    var copyN = srcSize < values_size ? srcSize : values_size;
                    for (var i = 0; i < copyN; i++) {
                        values[i] = decodeStored(old_values[i]);
                    }
                } else if (old_time != null) {
                    // Time-series mode (HR): age bins by elapsed wall time.
                    var elapsedMs = System.getTimer() - (old_time as Number);
                    // Timer resets on reboot → negative; drop stale history.
                    if (elapsedMs >= 0) {
                        var elapsedSec = elapsedMs / 1000;
                        var mult = range_mult.toFloat();
                        var delta = (elapsedSec.toFloat() / mult).toNumber();
                        if (delta < 0) {
                            delta = 0;
                        }
                        if (delta < values_size) {
                            for (var j = 0; j < values_size - delta; j++) {
                                var srcIdx = j + delta;
                                if (srcIdx >= 0 && srcIdx < srcSize) {
                                    values[j] = decodeStored(old_values[srcIdx]);
                                }
                            }
                        }
                        // else: everything aged out → leave all null
                    }
                }
            }
        } catch (ex) {
            values = new[values_size] as Array<Numeric or Null>;
            if (range_mult == null || range_mult.toFloat() < 0) {
                range_mult = 1;
            }
        }

        current = null;
        update_min_max();
    }


    function write_data() as Void {
        try {
            // Storage rejects null array elements — encode gaps first.
            var stored = new[values_size] as Array<Numeric>;
            if (values != null) {
                var n = values.size();
                if (n > values_size) {
                    n = values_size;
                }
                for (var i = 0; i < n; i++) {
                    stored[i] = encodeStored(values[i]);
                }
                // Any remaining slots (size mismatch) stay as sentinel.
                for (var j = n; j < values_size; j++) {
                    stored[j] = STORAGE_NULL_SENTINEL;
                }
            } else {
                for (var k = 0; k < values_size; k++) {
                    stored[k] = STORAGE_NULL_SENTINEL;
                }
            }

            Storage.setValue(key(LAST_VALUES), stored);
            Storage.setValue(key(LAST_VALUE_TIME), System.getTimer());
            Storage.setValue(key(RANGE_MULT), range_mult);
            // Shared range key is for the HR time chart only.
            if (range_mult != null && range_mult.toFloat() > 0) {
                Storage.setValue(RANGE_MULT, range_mult);
            }

        } catch (ex) {
            // Avoid crashing the app on hide/stop if storage fails.
        }
    }

    private function encodeStored(v as Numeric or Null) as Numeric {
        if (v == null) {
            return STORAGE_NULL_SENTINEL;
        }
        return v;
    }

    private function decodeStored(v) as Numeric or Null {
        if (v == null) {
            return null;
        }
        // Sentinel or any non-positive junk from older builds.
        if (v instanceof Number || v instanceof Float) {
            if (v.toFloat() < 0) {
                return null;
            }
            return v as Numeric;
        }
        return null;
    }
}
