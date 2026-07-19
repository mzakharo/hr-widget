// -*- mode: Javascript;-*-

import Toybox.Lang;
using Toybox.System as System;
using Toybox.Application as App;

class ChartModel {
    var current as Numeric or Null = null;
    var values_size as Number = 150;
    var values as Array<Numeric or Null> or Null;
    var range_mult as Number or Float or Null;
    var range_mult_count as Number = 0;

    var min as Numeric or Null;
    var max as Numeric or Null;
    var min_i as Number or Null;
    var max_i as Number or Null;

    function initialize() {
        set_range_minutes(2.5);
    }

    function get_values() as Array<Numeric or Null> {
        if (values == null) {
            values = new[values_size] as Array<Numeric or Null>;
        }
        return values;
    }

    function get_range_minutes() as Float or Number {
        var mult = (range_mult == null) ? 1 : range_mult;
        var size = (values == null) ? values_size : values.size();
        return (size * mult / 60);
    }

    function set_range_minutes(range as Float or Number) as Void {
        var new_mult = range * 60 / values_size;
        if (new_mult != range_mult) {
            range_mult = new_mult;
            values = new[values_size] as Array<Numeric or Null>;
            range_mult_count = 0;
            current = null;
        }
    }


    function get_current() as Numeric or Null {
        return current;
    }

    function get_min() as Numeric or Null {
        return min;
    }

    function get_max() as Numeric or Null {
        return max;
    }

    function get_min_i() as Number or Null {
        return min_i;
    }

    function get_max_i() as Number or Null {
        return max_i;
    }

    function get_min_max_interesting() as Boolean {
        return min != null and max != null and max != 0 and min != max;
    }


    function new_value(new_value as Numeric or Null) as Void {
        if (values == null) {
            values = new[values_size] as Array<Numeric or Null>;
        }
        if (range_mult == null || range_mult.toFloat() <= 0) {
            range_mult = 1;
        }

        current = new_value;
        range_mult_count++;
        if (range_mult_count >= range_mult) {
            for (var i = 1; i < values.size(); i++) {
                values[i - 1] = values[i];
            }
            values[values.size() - 1] = current;
            range_mult_count = 0;
        }

        update_min_max();
    }

    function update_min_max() as Void {
        min = null;
        max = null;
        min_i = 0;
        max_i = 0;

        if (values == null) {
            return;
        }

        for (var i = 0; i < values.size(); i++) {
            var item = values[i];
            if (item != null) {
                if (min == null || item < min) {
                    min_i = i;
                    min = item;
                }
                if (max == null || item > max) {
                    max_i = i;
                    max = item;
                }
            }
        }

        // Chart.draw expects numeric min/max; use zeros when empty.
        if (min == null) {
            min = 0;
            max = 0;
        }
    }

}
