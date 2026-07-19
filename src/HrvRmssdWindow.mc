// -*- mode: Javascript;-*-
// Sliding-window RMSSD calculator with light artifact filtering.
//
// Formula (Kubios / Task Force of ESC/NASPE):
//   RMSSD = sqrt( 1/(N-1) * sum_{i=1}^{N-1} (NN[i+1] - NN[i])^2 )
// where NN are accepted normal-to-normal intervals in ms.
//
// Filtering is intentionally light for optical PPG:
//   1) Physiological range: drop RR outside 250–2000 ms (~240–30 bpm).
//   2) Successive-change: drop RR that jumps more than 50% from the last
//      accepted RR (looser than ECG 20–25% rules; PPG is noisier).
//   3) Publish once the time window is full and we have enough accepted
//      beats to form successive differences. No hard artifact-rate veto —
//      rejected beats are simply omitted from the NN series.

import Toybox.Lang;
import Toybox.Math;

// Physiological RR bounds (ms).
const RR_MIN_MS = 250.0;
const RR_MAX_MS = 2000.0;

// Max fractional change vs previous accepted RR (50% — PPG-friendly).
const RR_MAX_CHANGE = 0.50;

class HrvRmssdWindow {
    private var mWindowSeconds as Number;
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

    function initialize(windowSeconds as Number) {
        mWindowSeconds = windowSeconds;
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
        var minBeats = mWindowSeconds / 4;
        if (minBeats < 3) {
            minBeats = 3;
        }
        return minBeats;
    }

    function setWindowSeconds(windowSeconds as Number) as Void {
        mWindowSeconds = windowSeconds;
        reset();
    }

    // Feed one second of beat-to-beat intervals (ms).
    // Returns window RMSSD once full and enough beats remain, else null.
    function addOneSecBeatToBeatIntervals(beatToBeatIntervals as Array) as Float or Null {
        mSecondsCount++;

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
                        // Spike / ectopic / motion — skip this beat only.
                        mRejectJump++;
                        continue;
                    }
                }

                mIntervals.add(rr);
                mSecondMarks.add(mSecondsCount);
                mLastAccepted = rr;
                mAcceptedBeats++;
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

        // Window not full yet.
        if (mSecondsCount < mWindowSeconds) {
            mLastRmssd = null;
            return null;
        }

        // Need at least a few successive pairs. ~0.25 beat/sec is enough to
        // produce a value; stricter gates blanked PPG too often.
        var minBeats = mWindowSeconds / 4;
        if (minBeats < 3) {
            minBeats = 3;
        }
        if (mIntervals.size() < minBeats) {
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


