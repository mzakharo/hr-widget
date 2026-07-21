// -*- mode: Javascript;-*-

import Toybox.Lang;
import Toybox.Graphics;
using Toybox.Sensor as Sensor;
using Toybox.System as System;
using Toybox.WatchUi as Ui;
using Toybox.Application as App;
using Toybox.Application.Storage;
using Toybox.Attention as Attention;
using Toybox.Math as Math;
using Toybox.Time as Time;

class HrWidgetView extends Ui.View {
    var invert as Boolean = false;
    var chart as Chart or Null;
    var have_connected as Boolean = false;
    var alert_enabled as Boolean = false;
    var alert_threshold as Number = 40;
    var alert_active as Boolean = false;
    // Epoch seconds of last alert fire; used for 60s cooldown.
    var alert_last_fire as Number = 0;

    // Fresh install defaults to HRV chart.
    var plot_mode as Number = MODE_HRV;

    var hrvWindow as HrvRmssdWindow or Null;
    var usingBeatIntervals as Boolean = false;
    // Last good HR (bpm). Beat-interval seconds are often empty; hold instead of null gaps.
    var lastHr as Number or Null = null;
    var hrMissedSeconds as Number = 0;
    // Last good RMSSD for the big readout.
    var lastHrv as Float or Null = null;
    // Quality associated with the latest published RMSSD (0.0 through 1.0).
    var lastHrvQuality as Float or Null = null;
    // Fresh RR-derived BPM for the HRV title (null when this second had no RR).
    var liveRrBpm as Number or Null = null;

    // Debug overlay (menu: RR Debug).

    var debugMode as Boolean = false;
    var dbgCallbacks as Number = 0;
    var dbgEmptySecs as Number = 0;
    var dbgLastBucketCount as Number = 0;
    var dbgLastRawLine as String = "-";
    var dbgHasHrData as Boolean = false;

    function initialize() {
        View.initialize();
    }

    function toggle_colors() as Void {
        invert = !invert;
    }

    function toggle_alert() as Void {
        alert_enabled = !alert_enabled;
        if (!alert_enabled) {
            alert_active = false;
        } else {
            // Evaluate immediately when turning alert on.
            check_hrv_threshold();
        }
    }


    function toggle_mode() as Void {
        if (plot_mode == MODE_HR) {
            plot_mode = MODE_HRV;
            model = hrvModel;
        } else {
            plot_mode = MODE_HR;
            model = hrModel;
        }
        if (chart != null && model != null) {
            chart = new Chart(model);
        }
    }

    function toggle_debug() as Void {
        debugMode = !debugMode;
    }

    function set_alert_threshold(value as Number) as Void {
        alert_threshold = value;
        // Re-evaluate immediately against current chart average.
        check_hrv_threshold();
    }


    // Chart history period — applies to both HR and HRV time charts.
    function set_range_minutes(range as Float or Number) as Void {
        if (hrModel != null) {
            hrModel.set_range_minutes(range);
        }
        if (hrvModel != null) {
            hrvModel.set_range_minutes(range);
        }
    }

    //! Load your resources here
    function onLayout(dc as Dc) as Void {
    }

    //! Restore the state of the app and prepare the view to be shown
    function onShow() as Void {
        if (hrModel == null) {
            hrModel = new PersistentChartModel("hr_");
            hrModel.read_data();

            // HRV is a continuous time-series chart (same X as HR).
            hrvModel = new PersistentChartModel("hrv_");
            hrvModel.read_data();

            // Keep both models on the same time range.
            var range = hrModel.get_range_minutes();
            hrvModel.set_range_minutes(range);

            if (Storage.getValue(INVERT) == true) {
                invert = true;
            }
            if (Storage.getValue(ALERT_ENABLED) == true) {
                alert_enabled = true;
            }
            var saved_threshold = Storage.getValue(ALERT_THRESHOLD);
            if (saved_threshold != null) {
                alert_threshold = saved_threshold as Number;
            }
            var saved_mode = Storage.getValue(PLOT_MODE);
            if (saved_mode != null) {
                plot_mode = saved_mode as Number;
            }

            lastHrv = findLastNonNull(hrvModel);
            hrModel.current = null;
            hrvModel.current = lastHrv;

            if (plot_mode == MODE_HRV) {
                model = hrvModel;
            } else {
                model = hrModel;
            }

            chart = new Chart(model);
            hrvWindow = new HrvRmssdWindow();
            lastHr = null;
            hrMissedSeconds = 0;
        }

        startSensors();
    }

    function startSensors() as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE] as Array<Sensor.SensorType>);

        if (Sensor has :registerSensorDataListener) {
            Sensor.registerSensorDataListener(method(:onSensorData), {
                :period => 1,
                :heartBeatIntervals => {
                    :enabled => true
                }
            });
            usingBeatIntervals = true;
            // Secondary 1 Hz Sensor.Info path (HR only; does not touch HRV).
            Sensor.enableSensorEvents(method(:onSensor));
        } else {
            Sensor.enableSensorEvents(method(:onSensor));
            usingBeatIntervals = false;
        }
    }

    function stopSensors() as Void {
        if (usingBeatIntervals && (Sensor has :unregisterSensorDataListener)) {
            Sensor.unregisterSensorDataListener();
        }
        Sensor.enableSensorEvents(null);
    }

    // Scan chart buffer newest→oldest for last plotted value.
    function findLastNonNull(m as PersistentChartModel or Null) as Float or Null {
        if (m == null) {
            return null;
        }
        var vals = m.get_values();
        for (var i = vals.size() - 1; i >= 0; i--) {
            if (vals[i] != null) {
                return (vals[i] as Numeric).toFloat();
            }
        }
        return null;
    }

    //! Called when this View is removed from the screen. Save the
    //! state of your app here.
    function onHide() as Void {
        stopSensors();

        if (hrModel != null) {
            hrModel.write_data();
        }
        if (hrvModel != null) {
            hrvModel.write_data();
        }
        Storage.setValue(INVERT, invert);
        Storage.setValue(ALERT_ENABLED, alert_enabled);
        Storage.setValue(ALERT_THRESHOLD, alert_threshold);
        Storage.setValue(PLOT_MODE, plot_mode);
    }

    //! Update the view
    function onUpdate(dc as Dc) as Void {
        if (debugMode) {
            drawDebug(dc);
            return;
        }

        var fg = invert ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        var bg = invert ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var isHrv = plot_mode == MODE_HRV;

        var block_color = isHrv ? Graphics.COLOR_BLUE : Graphics.COLOR_RED;
        // HRV values are typically much smaller than HR; use a tighter default range.
        var range_min_size = isHrv ? 10 : 30;

        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var duration_label;
        if (model.get_range_minutes() < 60) {
            duration_label = model.get_range_minutes().toNumber() + " MINUTES";
        } else {
            duration_label = (model.get_range_minutes() / 60).toNumber() + " HOURS";
        }

        // Title: live RR BPM in HRV mode; threshold indicator when alert on in HR mode.
        var title_label;
        if (isHrv) {
            // Live RR-derived BPM only — dashes when this second had no RR stream.
            if (liveRrBpm != null) {
                title_label = "HR " + liveRrBpm;
            } else {
                title_label = "HR ---";
            }
        } else if (alert_enabled) {
            title_label = "> " + alert_threshold;
        } else {
            title_label = "HEART";
        }

        var short_label;
        if (isHrv) {
            short_label = liveRrBpm != null ? ("" + liveRrBpm) : "---";
        } else if (alert_enabled) {
            short_label = "> " + alert_threshold;
        } else {
            short_label = "HR";
        }

        // HRV uses a red→yellow→green signal-quality gradient. HR retains the
        // existing yellow alert indication.
        var value_color = isHrv
            ? qualityColor(lastHrvQuality, fg)
            : (alert_enabled ? Graphics.COLOR_YELLOW : fg);
        var label_color = fg;



        // TODO this is maybe just a tiny bit too ad-hoc
        if (dc.getWidth() == 218 && dc.getHeight() == 218) {
            // Fenix 3
            dc.setColor(label_color, Graphics.COLOR_TRANSPARENT);
            text(dc, 109, 15, Graphics.FONT_TINY, title_label);
            dc.setColor(value_color, Graphics.COLOR_TRANSPARENT);
            text(dc, 109, 45, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            text(dc, 109, 192, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [23, 75, 195, 172] as Array<Number>, fg, block_color,
                       range_min_size, true, true, false, self);
        } else if (dc.getWidth() == 205 && dc.getHeight() == 148) {
            // Vivoactive, FR920xt, Epix
            dc.setColor(label_color, Graphics.COLOR_TRANSPARENT);
            text(dc, 70, 25, Graphics.FONT_MEDIUM, short_label);
            dc.setColor(value_color, Graphics.COLOR_TRANSPARENT);
            text(dc, 120, 25, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            text(dc, 102, 135, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [10, 45, 195, 120] as Array<Number>, fg, block_color,
                       range_min_size, true, true, false, self);
        } else {
            // Generic layout, scaled to the device (e.g. Forerunner 970, 454x454)
            var w = dc.getWidth();
            var h = dc.getHeight();
            dc.setColor(label_color, Graphics.COLOR_TRANSPARENT);
            text(dc, w / 2, h * 7 / 100, Graphics.FONT_TINY, title_label);
            dc.setColor(value_color, Graphics.COLOR_TRANSPARENT);
            text(dc, w / 2, h * 21 / 100, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            text(dc, w / 2, h * 88 / 100, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [w * 11 / 100, h * 34 / 100,
                            w * 89 / 100, h * 79 / 100] as Array<Number>,
                       fg, block_color, range_min_size, true, true, false, self);
        }

    }

    function drawDebug(dc as Dc) as Void {
        var fg = invert ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        var bg = invert ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();
        var x = w / 12;
        var y = h / 14;
        var dy = h / 16;
        var font = Graphics.FONT_XTINY;

        dc.drawText(w / 2, y, Graphics.FONT_TINY, "RR DEBUG",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        y += dy + 4;

        var lines = [] as Array<String>;
        lines.add("cb:" + dbgCallbacks + " empty:" + dbgEmptySecs);
        lines.add("listener:" + (usingBeatIntervals ? "beat" : "hr-only"));
        lines.add("hrData:" + (dbgHasHrData ? "yes" : "no"));
        lines.add("bucket n:" + dbgLastBucketCount);
        lines.add("raw RR: " + dbgLastRawLine);

        if (hrvWindow != null) {
            var sec = hrvWindow.getSecondsCount();
            var win = hrvWindow.getWindowSeconds();
            var acc = hrvWindow.getAcceptedCount();
            var need = hrvWindow.getMinBeatsRequired();
            var rmssd = hrvWindow.getLastRmssd();
            var quality = hrvWindow.getLastQuality();
            var lastAcc = hrvWindow.getLastAccepted();
            var lastRaw = hrvWindow.getLastRawRr();

            lines.add("win:" + sec + "/" + win + "s");
            lines.add("NN now:" + acc + "/" + need
                      + " ok:" + hrvWindow.getAcceptedBeatsTotal());
            lines.add("rej rng:" + hrvWindow.getRejectRange()
                      + " jump:" + hrvWindow.getRejectJump());
            lines.add("last raw:" + (lastRaw != null ? lastRaw.toNumber() + "ms" : "-"));
            lines.add("last NN:" + (lastAcc != null ? lastAcc.toNumber() + "ms" : "-"));
            lines.add("rmssd:" + (rmssd != null
                      ? (Math.round(rmssd * 10.0) / 10.0).format("%.1f")
                      : "null"));
            lines.add("quality:" + (quality != null
                      ? Math.round(quality * 100.0).toNumber() + "%"
                      : "-"));
        } else {
            lines.add("hrvWindow: null");
        }

        lines.add("HOLD hrv:" + (lastHrv != null ? lastHrv.format("%.1f") : "-")
                  + " hr:" + (lastHr != null ? lastHr.toString() : "-"));
        lines.add("model cur:" + fmt_num(hrvModel != null ? hrvModel.get_current() : null));

        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(x, y, font, lines[i],
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            y += dy;
        }
    }

    function fmt_num(num as Numeric or Null) as String {


        if (num == null) {
            return "---";
        }
        // Show whole numbers for HR; one decimal for HRV RMSSD.
        if (plot_mode == MODE_HRV) {
            var rounded = Math.round((num as Float) * 10.0) / 10.0;
            return rounded.format("%.1f");
        }
        return "" + (num as Number).toNumber();
    }

    function qualityColor(quality as Float or Null, fallback as ColorType) as ColorType {
        if (quality == null) {
            return fallback;
        }
        var q = quality as Float;
        if (q < 0.0) {
            q = 0.0;
        } else if (q > 1.0) {
            q = 1.0;
        }

        // 0.0 = red, 0.5 = yellow, 1.0 = green.
        var red;
        var green;
        if (q < 0.5) {
            red = 255;
            green = Math.round(q * 2.0 * 255.0).toNumber();
        } else {
            red = Math.round((1.0 - q) * 2.0 * 255.0).toNumber();
            green = 255;
        }
        // Connect IQ colors are packed 0xRRGGBB values.
        return (red * 65536 + green * 256) as ColorType;
    }

    function text(dc as Dc, x as Number, y as Number,
                  font as FontDefinition, s as String) as Void {
        dc.drawText(x, y, font, s,
                    Graphics.TEXT_JUSTIFY_CENTER|Graphics.TEXT_JUSTIFY_VCENTER);
    }

    var vibrateData = [new Attention.VibeProfile( 25, 100),
                       new Attention.VibeProfile( 50, 100),
                       new Attention.VibeProfile( 75, 100),
                       new Attention.VibeProfile(100, 100),
                       new Attention.VibeProfile( 75, 100),
                       new Attention.VibeProfile( 50, 100),
                       new Attention.VibeProfile( 25, 100)] as Array<Attention.VibeProfile>;

    var alertVibeData = [new Attention.VibeProfile(100, 400),
                         new Attention.VibeProfile(  0, 200),
                         new Attention.VibeProfile(100, 400),
                         new Attention.VibeProfile(  0, 200),
                         new Attention.VibeProfile(100, 400)] as Array<Attention.VibeProfile>;

    function fire_hrv_alert() as Void {
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

    // High average-HRV alert: fire once when chart average crosses above threshold.
    // Also enforces a 60-second cooldown between fires.
    function check_hrv_threshold() as Void {
        if (!alert_enabled) {
            return;
        }
        if (hrvModel == null) {
            return;
        }

        var avg = hrvModel.get_avg();
        if (avg == null) {
            return;
        }

        if (avg.toFloat() > alert_threshold.toFloat()) {
            // Only fire once per time average crosses above the threshold,
            // and not again within the cooldown window.
            if (!alert_active) {
                var now = Time.now().value();
                if (now - alert_last_fire >= 60) {
                    alert_active = true;
                    alert_last_fire = now;
                    fire_hrv_alert();
                }
            }
        } else {
            alert_active = false;
        }
    }



    function noteConnected() as Void {
        if (!have_connected) {
            if (Attention has :playTone) {
                Attention.playTone(Attention.TONE_START);
            }
            if (Attention has :vibrate) {
                Attention.vibrate(vibrateData);
            }
            have_connected = true;
        }
    }

    // 1 Hz Sensor.Info callback. When beat intervals are active this is only
    // a backup HR path and must NOT also advance the chart (onSensorData does).
    function onSensor(sensorInfo as Sensor.Info) as Void {
        if (usingBeatIntervals) {
            // Keep lastHr fresh if beat path is empty, but do not double-plot.
            var hr = sensorInfo.heartRate;
            if (hr != null && hr > 0) {
                lastHr = hr;
                hrMissedSeconds = 0;
                noteConnected();
            }
            return;
        }
        updateHr(sensorInfo.heartRate);
        Ui.requestUpdate();
    }

    // Prefer watch-computed HR; fall back to last RR; hold last good value
    // so empty beat-interval seconds do not punch holes in the HR chart.
    function updateHr(hr as Number or Null) as Void {
        if (hr != null && hr > 0) {
            lastHr = hr;
            hrMissedSeconds = 0;
            noteConnected();
            if (hrModel != null) {
                hrModel.new_value(hr);
            }
            return;
        }

        // No fresh sample this second.
        hrMissedSeconds++;
        if (lastHr != null && hrMissedSeconds <= 5) {
            // Hold last good HR briefly (common when a 1 Hz RR bucket is empty).
            if (hrModel != null) {
                hrModel.new_value(lastHr);
            }
        } else {
            // Prolonged dropout — record a gap.
            if (hrModel != null) {
                hrModel.new_value(null);
            }
        }
    }


    function hrFromIntervals(intervals as Array) as Number or Null {
        if (intervals == null || intervals.size() == 0) {
            return null;
        }
        var lastInterval = intervals[intervals.size() - 1];
        if (lastInterval != null && lastInterval > 0) {
            return Math.round(60000.0 / lastInterval.toFloat()).toNumber();
        }
        return null;
    }

    // Beat-to-beat interval callback (1 Hz). Updates both HR and HRV models.
    function onSensorData(sensorData as Sensor.SensorData) as Void {
        dbgCallbacks++;

        if (!(sensorData has :heartRateData) || sensorData.heartRateData == null) {
            dbgHasHrData = false;
            dbgLastBucketCount = 0;
            dbgEmptySecs++;
            dbgLastRawLine = "(no hrData)";
            // Still try the smoothed HR from Sensor.getInfo().
            var info = Sensor.getInfo();
            updateHr(info != null ? info.heartRate : null);
            updateHrv([] as Array);
            Ui.requestUpdate();
            return;
        }

        dbgHasHrData = true;
        var intervals = sensorData.heartRateData.heartBeatIntervals;
        dbgLastBucketCount = intervals.size();
        if (intervals.size() == 0) {
            dbgEmptySecs++;
            dbgLastRawLine = "(empty)";
        } else {
            // Show up to 5 most recent RR values this second.
            var n = intervals.size();
            var start = n > 5 ? n - 5 : 0;
            var s = "";
            for (var i = start; i < n; i++) {
                if (i > start) {
                    s = s + ",";
                }
                var v = intervals[i];
                s = s + (v != null ? v.toString() : "?");
            }
            if (n > 5) {
                s = "…" + s;
            }
            dbgLastRawLine = s + " ms";
        }

        // Prefer device HR (smoother); fall back to instantaneous RR-derived HR.
        var info2 = Sensor.getInfo();
        var hr = (info2 != null) ? info2.heartRate : null;
        if (hr == null) {
            hr = hrFromIntervals(intervals);
        }
        updateHr(hr);
        updateHrv(intervals);
        Ui.requestUpdate();
    }

    // Continuous 60s rolling-window HRV (time-series chart, same X as HR).
    // Every second advances the window. RMSSD is published only after the
    // window is full and ≥60 accepted NN samples are present.
    function updateHrv(intervals as Array) as Void {
        if (hrvModel == null || hrvWindow == null) {
            return;
        }

        // Title BPM is a live stream indicator: only set when this second
        // delivered at least one RR interval; otherwise clear to dashes.
        if (intervals != null && intervals.size() > 0) {
            var lastInterval = intervals[intervals.size() - 1];
            if (lastInterval != null && lastInterval > 0) {
                liveRrBpm = Math.round(60000.0 / lastInterval.toFloat()).toNumber();
            } else {
                liveRrBpm = null;
            }
        } else {
            liveRrBpm = null;
        }

        var measurement = hrvWindow.addOneSecBeatToBeatIntervals(intervals);
        // Color reflects current-window quality even when the last numeric HRV
        // is being held because the present window does not qualify.
        lastHrvQuality = hrvWindow.getLastQuality();

        if (measurement != null) {
            var rounded = Math.round(measurement.rmssd * 10.0) / 10.0;
            lastHrv = rounded;
            hrvModel.new_value(rounded);
        } else if (hrvWindow.getSecondsCount() >= hrvWindow.getWindowSeconds()) {
            // Signal drop / not enough NN — chart gap; hold last big readout.
            hrvModel.new_value(null);
            if (lastHrv != null) {
                hrvModel.current = lastHrv;
            }
        } else {
            // Warmup — do not advance chart; hold last readout if any.
            hrvModel.current = lastHrv;
        }

        // Alert tracks chart average HRV (visible non-null points).
        check_hrv_threshold();
    }

}


class HrWidgetDelegate extends Ui.InputDelegate {
    function initialize() {
        InputDelegate.initialize();
    }

    function onKey(evt as Ui.KeyEvent) as Boolean {
        if (evt.getKey() == Ui.KEY_ENTER) {
            Ui.pushView(new Rez.Menus.MainMenu(), new MenuDelegate(),
                        Ui.SLIDE_LEFT);
            return true;
        }
        return false;
    }
}

class MenuDelegate extends Ui.MenuInputDelegate {
    function initialize() {
        MenuInputDelegate.initialize();
    }

    function onMenuItem(item as Symbol) as Void {
        if (item == :set_period) {
            Ui.pushView(new Rez.Menus.PeriodMenu(), new PeriodMenuDelegate(),
                        Ui.SLIDE_LEFT);
            return;
        }
        else if (item == :toggle_mode) {
            view.toggle_mode();
            return;
        }
        else if (item == :toggle_debug) {
            view.toggle_debug();
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
    function initialize() {
        MenuInputDelegate.initialize();
    }

    function onMenuItem(item as Symbol) as Void {
        if (item == :hrv_20) {
            view.set_alert_threshold(20);
        }
        else if (item == :hrv_25) {
            view.set_alert_threshold(25);
        }
        else if (item == :hrv_30) {
            view.set_alert_threshold(30);
        }
        else if (item == :hrv_35) {
            view.set_alert_threshold(35);
        }
        else if (item == :hrv_40) {
            view.set_alert_threshold(40);
        }
        else if (item == :hrv_45) {
            view.set_alert_threshold(45);
        }
        else if (item == :hrv_50) {
            view.set_alert_threshold(50);
        }
        else if (item == :hrv_55) {
            view.set_alert_threshold(55);
        }
        else if (item == :hrv_60) {
            view.set_alert_threshold(60);
        }
        else if (item == :hrv_65) {
            view.set_alert_threshold(65);
        }
        else if (item == :hrv_70) {
            view.set_alert_threshold(70);
        }
        Ui.popView(Ui.SLIDE_RIGHT);
    }
}


class PeriodMenuDelegate extends Ui.MenuInputDelegate {
    function initialize() {
        MenuInputDelegate.initialize();
    }

    function onMenuItem(item as Symbol) as Void {
        if (item == :min_2) {
            view.set_range_minutes(2.5);
        }
        else if (item == :min_5) {
            view.set_range_minutes(5);
        }
        else if (item == :min_10) {
            view.set_range_minutes(10);
        }
        else if (item == :min_15) {
            view.set_range_minutes(15);
        }
        else if (item == :min_30) {
            view.set_range_minutes(30);
        }
        else if (item == :min_45) {
            view.set_range_minutes(45);
        }
        else if (item == :hour_1) {
            view.set_range_minutes(60);
        }
        else if (item == :hour_2) {
            view.set_range_minutes(120);
        }
        else if (item == :hour_8) {
            view.set_range_minutes(480);
        }
        else if (item == :hour_24) {
            view.set_range_minutes(1440);
        }
        Ui.popView(Ui.SLIDE_RIGHT);
    }
}
