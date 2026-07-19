// -*- mode: Javascript;-*-
// Burst RMSSD calculator with light artifact filtering.
//
// Formula (Kubios / Task Force of ESC/NASPE):
//   RMSSD = sqrt( 1/(N-1) * sum_{i=1}^{N-1} (NN[i+1] - NN[i])^2 )
// where NN are accepted normal-to-normal intervals in ms.
//
// Optical PPG delivers RR in short bursts of variable length. This calculator
// accumulates NN beats for the current burst. If a burst runs longer than
// HRV_ROLL_SECONDS, older NN samples roll off so RMSSD always reflects the
// most recent window of the burst. The caller resets between bursts.

import Toybox.Lang;
import Toybox.Math;

// Physiological RR bounds (ms).
const RR_MIN_MS = 250.0;
const RR_MAX_MS = 2000.0;

// Max fractional change vs previous accepted RR (50% — PPG-friendly).
const RR_MAX_CHANGE = 0.50;

// Minimum accepted NN intervals to publish RMSSD from a burst.
const HRV_MIN_BEATS = 5;

// Within a long burst, only keep the most recent N seconds of NN data.
const HRV_ROLL_SECONDS = 30;

class HrvRmssdWindow {
    // Accepted NN intervals for the current burst (parallel age array).
    private var mIntervals as Array<Float> = [] as Array<Float>;
    private var mAges as Array<Number> = [] as Array<Number>;
    private var mLastAccepted as Float or Null = null;
    private var mLastRmssd as Float or Null = null;
    // Seconds that contained at least one accepted beat this burst (lifetime).
    private var mActiveSeconds as Number = 0;
    private var mHadBeatThisSecond as Boolean = false;

    // Debug counters (lifetime of current burst until reset).
    private var mRawBeats as Number = 0;
    private var mAcceptedBeats as Number = 0;
    private var mRejectRange as Number = 0;
    private var mRejectJump as Number = 0;
    private var mLastRawRr as Float or Null = null;

    function initialize() {
        reset();
    }

    function getLastRmssd() as Float or Null {
        return mLastRmssd;
    }

    // How many seconds in this burst had at least one accepted NN (lifetime).
    function getActiveSeconds() as Number {
        return mActiveSeconds;
    }

    function getAcceptedCount() as Number {
        return mIntervals.size();
    }

    function getRawBeats() as Number {
        return mRawBeats;
    }

    function getAcceptedBeatsTotal() as Number {
        return mAcceptedBeats;
    }

    function getRejectRange() as Number {
        return mRejectRange;
    }

    function getRejectJump() as Number {
        return mRejectJump;
    }

    function getLastAccepted() as Float or Null {
        return mLastAccepted;
    }

    function getLastRawRr() as Float or Null {
        return mLastRawRr;
    }

    function getMinBeatsRequired() as Number {
        return HRV_MIN_BEATS;
    }

    function getRollSeconds() as Number {
        return HRV_ROLL_SECONDS;
    }

    // Feed one second of beat-to-beat intervals (ms).
    // Ages existing NN by 1 s, drops samples older than HRV_ROLL_SECONDS,
    // then adds new accepted beats. Returns RMSSD when enough NN remain.
    function addOneSecBeatToBeatIntervals(beatToBeatIntervals as Array) as Float or Null {
        ageAndRoll();
        mHadBeatThisSecond = false;

        if (beatToBeatIntervals != null) {
            for (var i = 0; i < beatToBeatIntervals.size(); i++) {
                var interval = beatToBeatIntervals[i];
                if (interval == null) {
                    continue;
                }
                var rr = interval.toFloat();
                mRawBeats++;
                mLastRawRr = rr;

                // 1) Physiological range.
                if (rr < RR_MIN_MS || rr > RR_MAX_MS) {
                    mRejectRange++;
                    continue;
                }

                // 2) Successive-change threshold vs last accepted NN.
                if (mLastAccepted != null) {
                    var prev = mLastAccepted as Float;
                    var delta = rr - prev;
                    if (delta < 0) {
                        delta = -delta;
                    }
                    if (delta > prev * RR_MAX_CHANGE) {
                        mRejectJump++;
                        continue;
                    }
                }

                mIntervals.add(rr);
                mAges.add(0);
                mLastAccepted = rr;
                mAcceptedBeats++;
                mHadBeatThisSecond = true;
            }
        }

        if (mHadBeatThisSecond) {
            mActiveSeconds++;
        }

        return tryPublish();
    }

    // Age every buffered NN by 1 s; drop those past the roll window.
    private function ageAndRoll() as Void {
        if (mIntervals.size() == 0) {
            return;
        }
        var newIntervals = [] as Array<Float>;
        var newAges = [] as Array<Number>;
        for (var i = 0; i < mIntervals.size(); i++) {
            var age = mAges[i] + 1;
            if (age < HRV_ROLL_SECONDS) {
                newIntervals.add(mIntervals[i]);
                newAges.add(age);
            }
        }
        mIntervals = newIntervals;
        mAges = newAges;
        // If the roll window emptied, drop successive-filter anchor.
        if (mIntervals.size() == 0) {
            mLastAccepted = null;
        }
    }

    // Compute RMSSD from whatever is currently buffered (burst end).
    function finalize() as Float or Null {
        return tryPublish();
    }

    private function tryPublish() as Float or Null {
        if (mIntervals.size() < HRV_MIN_BEATS) {
            return null;
        }
        var value = calculate();
        if (value != null) {
            mLastRmssd = value;
        }
        return value;
    }

    private function calculate() as Float or Null {
        if (mIntervals.size() < 2) {
            return null;
        }

        var sumSquares = 0.0;
        var count = 0;
        var prev = mIntervals[0];
        for (var i = 1; i < mIntervals.size(); i++) {
            var cur = mIntervals[i];
            var diff = cur - prev;
            sumSquares += diff * diff;
            count++;
            prev = cur;
        }

        if (count < 1) {
            return null;
        }

        return Math.sqrt(sumSquares / count).toFloat();
    }

    // Clear burst buffers. Keeps mLastRmssd so the UI can hold the last value.
    function reset() as Void {
        mIntervals = [] as Array<Float>;
        mAges = [] as Array<Number>;
        mLastAccepted = null;
        mActiveSeconds = 0;
        mHadBeatThisSecond = false;
        mRawBeats = 0;
        mAcceptedBeats = 0;
        mRejectRange = 0;
        mRejectJump = 0;
        mLastRawRr = null;
    }

    // Full wipe including last published RMSSD.
    function resetAll() as Void {
        reset();
        mLastRmssd = null;
    }
}
