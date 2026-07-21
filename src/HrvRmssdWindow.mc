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

// Quality-based publication requirements for the rolling window.
const HRV_MIN_VALID_PAIRS = 35;
const HRV_MIN_USABLE_FRACTION = 0.80;
const HRV_MAX_ARTIFACT_FRACTION = 0.20;
const HRV_MAX_DROPOUT_SECONDS = 5;

class HrvMeasurement {
    var rmssd as Float;
    // Normalized signal quality, 0.0 (poor) through 1.0 (excellent).
    var quality as Float;

    function initialize(value as Float, score as Float) {
        rmssd = value;
        quality = score;
    }
}

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
    // Per-second quality statistics, retained for the same 60-second window.
    private var mRawPerSecond as Array<Number> = [] as Array<Number>;
    private var mAcceptedPerSecond as Array<Number> = [] as Array<Number>;
    private var mRejectedPerSecond as Array<Number> = [] as Array<Number>;
    private var mLastQuality as Float or Null = null;

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

    function getLastQuality() as Float or Null {
        return mLastQuality;
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
        return HRV_MIN_VALID_PAIRS;
    }

    // Feed one second of beat-to-beat intervals (ms).
    // Returns window RMSSD only when:
    //   - this second delivered at least one accepted NN (live signal), and
    //   - the rolling window is full with enough NN samples.
    // Empty / dropout seconds age the window but do NOT republish stale RMSSD.
    function addOneSecBeatToBeatIntervals(beatToBeatIntervals as Array) as HrvMeasurement or Null {
        mSecondsCount++;
        var acceptedThisSec = 0;
        var rawAtStart = mRawBeats;
        var rejectedAtStart = mRejectRange + mRejectJump;

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

        mRawPerSecond.add(mRawBeats - rawAtStart);
        mAcceptedPerSecond.add(acceptedThisSec);
        mRejectedPerSecond.add((mRejectRange + mRejectJump) - rejectedAtStart);
        trimQualityWindow();

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
            mLastQuality = calculateQuality();
            return null;
        }

        // Require a complete time window and quality-qualified NN data.
        var validPairs = getValidPairCount();
        var usableFraction = getUsableFraction();
        var artifactFraction = getArtifactFraction();
        var maxDropout = getMaxConsecutiveDropoutSeconds();
        mLastQuality = calculateQuality();
        if (mSecondsCount < mWindowSeconds
            || validPairs < HRV_MIN_VALID_PAIRS
            || usableFraction < HRV_MIN_USABLE_FRACTION
            || artifactFraction > HRV_MAX_ARTIFACT_FRACTION
            || maxDropout > HRV_MAX_DROPOUT_SECONDS) {
            mLastRmssd = null;
            return null;
        }

        mLastRmssd = calculate();
        if (mLastRmssd == null || mLastQuality == null) {
            return null;
        }
        return new HrvMeasurement(mLastRmssd as Float, mLastQuality as Float);
    }

    private function trimQualityWindow() as Void {
        if (mRawPerSecond.size() > mWindowSeconds) {
            mRawPerSecond = mRawPerSecond.slice(1, null) as Array<Number>;
            mAcceptedPerSecond = mAcceptedPerSecond.slice(1, null) as Array<Number>;
            mRejectedPerSecond = mRejectedPerSecond.slice(1, null) as Array<Number>;
        }
    }

    private function getValidPairCount() as Number {
        var count = 0;
        for (var i = 1; i < mHasValidPredecessor.size(); i++) {
            if (mHasValidPredecessor[i]) {
                count++;
            }
        }
        return count;
    }

    private function getUsableFraction() as Float {
        var raw = 0;
        var accepted = 0;
        for (var i = 0; i < mRawPerSecond.size(); i++) {
            raw += mRawPerSecond[i];
            accepted += mAcceptedPerSecond[i];
        }
        return raw > 0 ? accepted.toFloat() / raw.toFloat() : 0.0;
    }

    private function getArtifactFraction() as Float {
        var raw = 0;
        var rejected = 0;
        for (var i = 0; i < mRawPerSecond.size(); i++) {
            raw += mRawPerSecond[i];
            rejected += mRejectedPerSecond[i];
        }
        return raw > 0 ? rejected.toFloat() / raw.toFloat() : 1.0;
    }

    private function getMaxConsecutiveDropoutSeconds() as Number {
        var longest = 0;
        var current = 0;
        for (var i = 0; i < mAcceptedPerSecond.size(); i++) {
            if (mAcceptedPerSecond[i] == 0) {
                current++;
                if (current > longest) {
                    longest = current;
                }
            } else {
                current = 0;
            }
        }
        return longest;
    }

    private function calculateQuality() as Float {
        if (mSecondsCount < mWindowSeconds) {
            return 0.0;
        }
        var usable = getUsableFraction();
        var pairScore = getValidPairCount().toFloat() / 50.0;
        if (pairScore > 1.0) {
            pairScore = 1.0;
        }
        var dropoutScore = 1.0 - getMaxConsecutiveDropoutSeconds().toFloat()
                           / HRV_MAX_DROPOUT_SECONDS.toFloat();
        if (dropoutScore < 0.0) {
            dropoutScore = 0.0;
        }
        // Usability dominates; pair density and continuity refine the score.
        var score = usable * 0.5 + pairScore * 0.3 + dropoutScore * 0.2;
        if (score > 1.0) {
            score = 1.0;
        }
        return score;
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
        mLastQuality = null;
        mRecentAccepted = [] as Array<Float>;
        mReacquireCandidates = [] as Array<Float>;
        mRawPerSecond = [] as Array<Number>;
        mAcceptedPerSecond = [] as Array<Number>;
        mRejectedPerSecond = [] as Array<Number>;
        mRawBeats = 0;
        mAcceptedBeats = 0;
        mRejectRange = 0;
        mRejectJump = 0;
        mLastRawRr = null;
    }
}
