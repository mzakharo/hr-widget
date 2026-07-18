// -*- mode: Javascript;-*-

using Toybox.Graphics;
using Toybox.Sensor as Sensor;
using Toybox.System as System;
using Toybox.WatchUi as Ui;
using Toybox.Application as App;
using Toybox.Attention as Attention;

class HrWidgetView extends Ui.View {
    var invert = false;
    var chart;
    var have_connected = false;
    var alert_enabled = false;
    var alert_threshold = 80;
    var alert_active = false;

    function toggle_colors() {
        invert = !invert;
    }

    function toggle_alert() {
        alert_enabled = !alert_enabled;
        if (!alert_enabled) {
            alert_active = false;
        }
    }

    function set_alert_threshold(bpm) {
        alert_threshold = bpm;
    }

    //! Load your resources here
    function onLayout(dc) {
    }

    //! Restore the state of the app and prepare the view to be shown
    function onShow() {
        if (model == null) {
            model = new PersistentChartModel();
            model.read_data();

            chart = new Chart(model);

            var app = App.getApp();
            if (app.getProperty(INVERT) == true) {
                invert = true;
            }
            if (app.getProperty(ALERT_ENABLED) == true) {
                alert_enabled = true;
            }
            var saved_threshold = app.getProperty(ALERT_THRESHOLD);
            if (saved_threshold != null) {
                alert_threshold = saved_threshold;
            }
        }

        Sensor.setEnabledSensors( [Sensor.SENSOR_HEARTRATE] );
        Sensor.enableSensorEvents( method(:onSensor) );
    }

    //! Called when this View is removed from the screen. Save the
    //! state of your app here.
    function onHide() {
        // Write here for the widget case
        model.write_data();
        var app = App.getApp();
        app.setProperty(INVERT, invert);
        app.setProperty(ALERT_ENABLED, alert_enabled);
        app.setProperty(ALERT_THRESHOLD, alert_threshold);
    }

    //! Update the view
    function onUpdate(dc) {
        var fg = invert ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        var bg = invert ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var duration_label;
        if (model.get_range_minutes() < 60) {
            duration_label = model.get_range_minutes().toNumber() + " MINUTES";
        }
        else {
            duration_label = (model.get_range_minutes() / 60).toNumber() + " HOURS";
        }

        // When the low HR alert is enabled, the label turns yellow and shows
        // the configured threshold instead of the word "HEART".
        var label_color = alert_enabled ? Graphics.COLOR_YELLOW : fg;
        var heart_label = alert_enabled
            ? ("< " + alert_threshold) : "HEART";
        var hr_label = alert_enabled
            ? ("< " + alert_threshold) : "HR";

        // TODO this is maybe just a tiny bit too ad-hoc
        if (dc.getWidth() == 218 && dc.getHeight() == 218) {
            // Fenix 3
            dc.setColor(label_color, Graphics.COLOR_TRANSPARENT);
            text(dc, 109, 15, Graphics.FONT_TINY, heart_label);
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            text(dc, 109, 45, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            text(dc, 109, 192, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [23, 75, 195, 172], fg, Graphics.COLOR_RED,
                       30, true, true, false, self);
        } else if (dc.getWidth() == 205 && dc.getHeight() == 148) {
            // Vivoactive, FR920xt, Epix
            dc.setColor(label_color, Graphics.COLOR_TRANSPARENT);
            text(dc, 70, 25, Graphics.FONT_MEDIUM, hr_label);
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            text(dc, 120, 25, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            text(dc, 102, 135, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [10, 45, 195, 120], fg, Graphics.COLOR_RED,
                       30, true, true, false, self);
        } else {
            // Generic layout, scaled to the device (e.g. Forerunner 970, 454x454)
            var w = dc.getWidth();
            var h = dc.getHeight();
            dc.setColor(label_color, Graphics.COLOR_TRANSPARENT);
            text(dc, w / 2, h * 7 / 100, Graphics.FONT_TINY, heart_label);
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            text(dc, w / 2, h * 21 / 100, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            text(dc, w / 2, h * 88 / 100, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [w * 11 / 100, h * 34 / 100,
                            w * 89 / 100, h * 79 / 100],
                       fg, Graphics.COLOR_RED, 30, true, true, false, self);
        }
    }

    function fmt_num(num) {
        if (num == null) {
            return "---";
        }
        else {
            return "" + num;
        }
    }

    function text(dc, x, y, font, s) {
        dc.drawText(x, y, font, s,
                    Graphics.TEXT_JUSTIFY_CENTER|Graphics.TEXT_JUSTIFY_VCENTER);
    }

    var vibrateData = [new Attention.VibeProfile( 25, 100),
                       new Attention.VibeProfile( 50, 100),
                       new Attention.VibeProfile( 75, 100),
                       new Attention.VibeProfile(100, 100),
                       new Attention.VibeProfile( 75, 100),
                       new Attention.VibeProfile( 50, 100),
                       new Attention.VibeProfile( 25, 100)];

    var alertVibeData = [new Attention.VibeProfile(100, 400),
                         new Attention.VibeProfile(  0, 200),
                         new Attention.VibeProfile(100, 400),
                         new Attention.VibeProfile(  0, 200),
                         new Attention.VibeProfile(100, 400)];

    function fire_low_hr_alert() {
        var settings = System.getDeviceSettings();

        // Play a tone if the device supports tones and the user has them on.
        if ((Attention has :playTone) && settings.tonesOn) {
            Attention.playTone(Attention.TONE_ALARM);
        }

        // Vibrate if the device supports it and vibration is enabled.
        if ((Attention has :vibrate) && settings.vibrateOn) {
            Attention.vibrate(alertVibeData);
        }
    }

    function check_threshold(hr) {
        if (!alert_enabled || hr == null) {
            return;
        }
        if (hr < alert_threshold) {
            // Only fire once per time the HR crosses below the threshold.
            if (!alert_active) {
                alert_active = true;
                fire_low_hr_alert();
            }
        }
        else {
            alert_active = false;
        }
    }

    function onSensor(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heartRate != null && !have_connected) {
            if (Attention has :playTone) {
                Attention.playTone(Attention.TONE_START);
            }
            Attention.vibrate(vibrateData);
            have_connected = true;
        }
        check_threshold(sensorInfo.heartRate);
        model.new_value(sensorInfo.heartRate);
        Ui.requestUpdate();
    }
}

class HrWidgetDelegate extends Ui.InputDelegate {
    function onKey(evt) {
        if (evt.getKey() == Ui.KEY_ENTER) {
            Ui.pushView(new Rez.Menus.MainMenu(), new MenuDelegate(),
                        Ui.SLIDE_LEFT);
            return true;
        }
        return false;
    } 
}

class MenuDelegate extends Ui.MenuInputDelegate {
    function onMenuItem(item) {
        if (item == :set_period) {
            Ui.pushView(new Rez.Menus.PeriodMenu(), new PeriodMenuDelegate(),
                        Ui.SLIDE_LEFT);
            return;
        }
        else if (item == :swap_colors) {
            view.toggle_colors();
            return;
        }
        else if (item == :toggle_alert) {
            view.toggle_alert();
            return;
        }
        else if (item == :set_threshold) {
            Ui.pushView(new Rez.Menus.ThresholdMenu(),
                        new ThresholdMenuDelegate(), Ui.SLIDE_LEFT);
            return;
        }
        Ui.popView(Ui.SLIDE_RIGHT);
    }
}

class ThresholdMenuDelegate extends Ui.MenuInputDelegate {
    function onMenuItem(item) {
        if (item == :bpm_70) {
            view.set_alert_threshold(70);
        }
        else if (item == :bpm_75) {
            view.set_alert_threshold(75);
        }
        else if (item == :bpm_80) {
            view.set_alert_threshold(80);
        }
        else if (item == :bpm_85) {
            view.set_alert_threshold(85);
        }
        else if (item == :bpm_90) {
            view.set_alert_threshold(90);
        }
        else if (item == :bpm_95) {
            view.set_alert_threshold(95);
        }
        else if (item == :bpm_100) {
            view.set_alert_threshold(100);
        }
        Ui.popView(Ui.SLIDE_RIGHT);
    }
}

class PeriodMenuDelegate extends Ui.MenuInputDelegate {
    function onMenuItem(item) {
        if (item == :min_2) {
            model.set_range_minutes(2.5);
        }
        else if (item == :min_5) {
            model.set_range_minutes(5);
        }
        else if (item == :min_10) {
            model.set_range_minutes(10);
        }
        else if (item == :min_15) {
            model.set_range_minutes(15);
        }
        else if (item == :min_30) {
            model.set_range_minutes(30);
        }
        else if (item == :min_45) {
            model.set_range_minutes(45);
        }
        else if (item == :hour_1) {
            model.set_range_minutes(60);
        }
        else if (item == :hour_2) {
            model.set_range_minutes(120);
        }
        else if (item == :hour_8) {
            model.set_range_minutes(480);
        }
        else if (item == :hour_24) {
            model.set_range_minutes(1440);
        }
        Ui.popView(Ui.SLIDE_RIGHT);
    } 
}
