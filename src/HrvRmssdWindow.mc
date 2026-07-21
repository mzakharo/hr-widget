// -*- mode: Javascript;-*-
// Sliding-window RMSSD calculator with light artifact filtering.
//
// Formula (Kubios / Task Force of ESC/NASPE):
//   RMSSD = sqrt( 1/(N-1) * sum_{i=1}^{N-1} (NN[i+1] - NN[i])^2 )
// where NN are accepted normal-to-normal intervals in ms.
//
// Filtering for optical PPG:
//   1) Physiological range: drop RR outside 300–1500 ms (~200–40 bpm).
//   2) Local robust gate: compare RR with the median of recent accepted beats,
//      using max(20% of median, 3 x median absolute deviation) as the limit.
//   3) Reacquire after three mutually consistent rejected beats, allowing a
//      genuine sustained heart-rate change to establish a new local baseline.
//   4) Publish once the time window is full and we have enough accepted
//      NN samples. Rejected/missing beats break the successive NN sequence,
//      so RMSSD never joins two accepted intervals across an artifact or gap.

import Toybox.Lang;
import Toybox.Math;

// Physiological RR bounds (ms).
const RR_MIN_MS = 300.0;
const RR_MAX_MS = 1500.0;

const RR_BASELINE_SIZE = 9;
const RR_BASELINE_MIN = 5;
const RR_MEDIAN_FRACTION = 0.20;
const RR_MAD_MULTIPLIER = 3.0;
const RR_REACQUIRE_COUNT = 3;
const RR_REACQUIRE_FRACTION = 0.125;


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
    // Whether each interval is truly successive to the accepted interval before it.
    // Index 0 is always false; arrays remain aligned when the window is sliced.
    private var mHasValidPredecessor as Array<Boolean> = [] as Array<Boolean>;
    private var mSequenceBroken as Boolean = true;
    private var mLastAccepted as Float or Null = null;
    private var mLastRmssd as Float or Null = null;
    // Short local baseline used only for robust artifact classification.
    private var mRecentAccepted as Array<Float> = [] as Array<Float>;
    // Range-valid outliers used to detect a sustained shift to a new rate.
    private var mReacquireCandidates as Array<Float> = [] as Array<Float>;

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
            mSequenceBroken = true;
            mReacquireCandidates = [] as Array<Float>;
        }

        if (beatToBeatIntervals != null) {
            for (var i = 0; i < beatToBeatIntervals.size(); i++) {
                var interval = beatToBeatIntervals[i];
                if (interval == null) {
                    mSequenceBroken = true;
                    mReacquireCandidates = [] as Array<Float>;
                    continue;
                }
                var rr = interval.toFloat();
                mRawBeats++;
                mLastRawRr = rr;

                // 1) Physiological range.
                if (rr < RR_MIN_MS || rr > RR_MAX_MS) {
                    mRejectRange++;
                    mSequenceBroken = true;
                    mReacquireCandidates = [] as Array<Float>;
                    continue;
                }

                // 2) Robust local median/MAD gate. If several rejected beats
                // agree with each other, reacquire them as a sustained shift.
                if (isLocalArtifact(rr)) {
                    mRejectJump++;
                    mSequenceBroken = true;
                    if (!tryReacquire(rr)) {
                        continue;
                    }
                } else {
                    mReacquireCandidates = [] as Array<Float>;
                }

                var hasValidPredecessor = mLastAccepted != null && !mSequenceBroken;
                mIntervals.add(rr);
                mSecondMarks.add(mSecondsCount);
                mHasValidPredecessor.add(hasValidPredecessor);
                mLastAccepted = rr;
                mSequenceBroken = false;
                addToBaseline(rr);
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
            mHasValidPredecessor = mHasValidPredecessor.slice(start, null) as Array<Boolean>;
            // The first retained interval has no retained predecessor.
            if (mHasValidPredecessor.size() > 0) {
                mHasValidPredecessor[0] = false;
            }
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

    private function isLocalArtifact(rr as Float) as Boolean {
        if (mRecentAccepted.size() < RR_BASELINE_MIN) {
            return false;
        }

        var center = median(mRecentAccepted);
        var deviations = [] as Array<Float>;
        for (var i = 0; i < mRecentAccepted.size(); i++) {
            var deviation = mRecentAccepted[i] - center;
            if (deviation < 0) {
                deviation = -deviation;
            }
            deviations.add(deviation);
        }
        var mad = median(deviations);
        var limit = center * RR_MEDIAN_FRACTION;
        var adaptiveLimit = mad * RR_MAD_MULTIPLIER;
        if (adaptiveLimit > limit) {
            limit = adaptiveLimit;
        }

        var distance = rr - center;
        if (distance < 0) {
            distance = -distance;
        }
        return distance > limit;
    }

    // Returns true only when this RR completes a consistent new-rate run.
    private function tryReacquire(rr as Float) as Boolean {
        if (mReacquireCandidates.size() > 0) {
            var candidateCenter = median(mReacquireCandidates);
            var distance = rr - candidateCenter;
            if (distance < 0) {
                distance = -distance;
            }
            if (distance > candidateCenter * RR_REACQUIRE_FRACTION) {
                mReacquireCandidates = [] as Array<Float>;
            }
        }
        mReacquireCandidates.add(rr);

        if (mReacquireCandidates.size() < RR_REACQUIRE_COUNT) {
            return false;
        }

        // Establish the consistent outlier run as the new robust baseline.
        mRecentAccepted = [] as Array<Float>;
        // The current (last) candidate is added by the normal acceptance path.
        for (var i = 0; i < mReacquireCandidates.size() - 1; i++) {
            addToBaseline(mReacquireCandidates[i]);
        }
        mReacquireCandidates = [] as Array<Float>;
        return true;
    }

    private function addToBaseline(rr as Float) as Void {
        mRecentAccepted.add(rr);
        if (mRecentAccepted.size() > RR_BASELINE_SIZE) {
            mRecentAccepted = mRecentAccepted.slice(1, null) as Array<Float>;
        }
    }

    private function median(values as Array<Float>) as Float {
        var sorted = values.slice(0, null) as Array<Float>;
        // Small fixed arrays: insertion sort avoids relying on device sort APIs.
        for (var i = 1; i < sorted.size(); i++) {
            var value = sorted[i];
            var j = i - 1;
            while (j >= 0 && sorted[j] > value) {
                sorted[j + 1] = sorted[j];
                j--;
            }
            sorted[j + 1] = value;
        }
        var middle = sorted.size() / 2;
        if ((sorted.size() % 2) == 0) {
            return (sorted[middle - 1] + sorted[middle]) / 2.0;
        }
        return sorted[middle];
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
            if (mHasValidPredecessor[i]) {
                var diff = cur - prev;
                sumSquares += diff * diff;
                count++;
            }
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
        mHasValidPredecessor = [] as Array<Boolean>;
        mSequenceBroken = true;
        mLastAccepted = null;
        mLastRmssd = null;
        mRecentAccepted = [] as Array<Float>;
        mReacquireCandidates = [] as Array<Float>;
        mRawBeats = 0;
        mAcceptedBeats = 0;
        mRejectRange = 0;
        mRejectJump = 0;
        mLastRawRr = null;
    }
}
