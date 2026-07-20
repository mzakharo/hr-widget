// -*- mode: Javascript;-*-
// Sliding-window RMSSD calculator with light artifact filtering.
//
// Formula (Kubios / Task Force of ESC/NASPE):
//   RMSSD = sqrt( 1/(N-1) * sum_{i=1}^{N-1} (NN[i+1] - NN[i])^2 )
// where NN are accepted normal-to-normal intervals in ms.
//
// Filtering for optical PPG (stricter than the original light gate):
//   1) Physiological range: drop RR outside 300–1500 ms (~200–40 bpm).
//   2) Successive-change: drop RR that jumps more than 25% from the last
//      accepted RR (ECG-style; rejects motion/ectopic spikes more aggressively).
//   3) Publish once the time window is full and we have enough accepted
//      NN samples. Rejected beats are simply omitted from the NN series.

import Toybox.Lang;
import Toybox.Math;

// Physiological RR bounds (ms).
const RR_MIN_MS = 300.0;
const RR_MAX_MS = 1500.0;

// Max fractional change vs previous accepted RR (25% — ECG-style).
const RR_MAX_CHANGE = 0.25;


// Fixed rolling window length (seconds).
const HRV_WINDOW_SECONDS = 60;

// Minimum accepted NN intervals before publishing RMSSD.
const HRV_MIN_BEATS = 60;

class HrvRmssdWindow {
    private var mWindowSeconds as Number = HRV_WINDOW_SECONDS;
    private var mSecondsCount as Number = 0;
    // Accepted NN intervals and the second they arrived.
    private var mIntervals as Array<Float> = [] as Array<Float>;
    private var mSecondMarks as Array<Number> = [] as Array<Number>;
    private var mLastAccepted as Float or Null = null;
    private var mLastRmssd as Float or Null = null;

    // Debug counters (lifetime of this window instance).
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

    function getWindowSeconds() as Number {
        return mWindowSeconds;
    }

    function getSecondsCount() as Number {
        return mSecondsCount;
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

    // Feed one second of beat-to-beat intervals (ms).
    // Returns window RMSSD only when:
    //   - this second delivered at least one accepted NN (live signal), and
    //   - the rolling window is full with enough NN samples.
    // Empty / dropout seconds age the window but do NOT republish stale RMSSD.
    function addOneSecBeatToBeatIntervals(beatToBeatIntervals as Array) as Float or Null {
        mSecondsCount++;
        var acceptedThisSec = 0;

        // No fresh RR this second — clear live raw marker.
        if (beatToBeatIntervals == null || beatToBeatIntervals.size() == 0) {
            mLastRawRr = null;
        }

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
                mSecondMarks.add(mSecondsCount);
                mLastAccepted = rr;
                mAcceptedBeats++;
                acceptedThisSec++;
            }
        }

        // Drop data older than the rolling window.
        var cutoff = mSecondsCount - mWindowSeconds;
        var start = 0;
        while (start < mSecondMarks.size() && mSecondMarks[start] <= cutoff) {
            start++;
        }
        if (start > 0) {
            mIntervals = mIntervals.slice(start, null) as Array<Float>;
            mSecondMarks = mSecondMarks.slice(start, null) as Array<Number>;
        }

        // No live accepted beat this second → do not publish (signal drop / all rejected).
        if (acceptedThisSec < 1) {
            mLastRmssd = null;
            return null;
        }

        // Window not full yet, or not enough NN samples.
        if (mSecondsCount < mWindowSeconds || mIntervals.size() < HRV_MIN_BEATS) {
            mLastRmssd = null;
            return null;
        }

        mLastRmssd = calculate();
        return mLastRmssd;
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

    function reset() as Void {
        mSecondsCount = 0;
        mIntervals = [] as Array<Float>;
        mSecondMarks = [] as Array<Number>;
        mLastAccepted = null;
        mLastRmssd = null;
        mRawBeats = 0;
        mAcceptedBeats = 0;
        mRejectRange = 0;
        mRejectJump = 0;
        mLastRawRr = null;
    }
}
