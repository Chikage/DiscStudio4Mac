import Testing

@testable import BRCore

struct ProgressTimeEstimatorTests {
    @Test func waitsForEnoughObservationsThenEstimatesOnlyRemainingWork() throws {
        var estimator = ProgressTimeEstimator()
        #expect(estimator.estimate(at: 0) == .unavailable)
        estimator.update(progress: 0.2, at: 100)
        #expect(estimator.estimate(at: 100) == .learning)
        estimator.update(progress: 0.24, at: 104)
        #expect(estimator.estimate(at: 104) == .learning)
        estimator.update(progress: 0.25, at: 105)
        guard case .remaining(let seconds) = estimator.estimate(at: 105) else {
            Issue.record("Expected an estimate after five seconds of steady progress")
            return
        }
        #expect(abs(seconds - 75) < 0.001)
        #expect(estimator.estimate(at: 104.9) == estimator.estimate(at: 105))
        // Silence must not count down to a fictional completion.
        #expect(estimator.estimate(at: 110) == estimator.estimate(at: 105))
    }

    @Test func smoothsBurstsButAdaptsToSustainedSpeedChanges() {
        var estimator = ProgressTimeEstimator()
        for second in 0...10 {
            estimator.update(progress: Double(second) / 100, at: Double(second))
        }
        estimator.update(progress: 0.2, at: 11)
        guard case .remaining(let afterBurst) = estimator.estimate(at: 11) else {
            Issue.record("Expected an estimate after a burst")
            return
        }
        #expect(afterBurst > 65 && afterBurst < 80)
        for second in 12...41 {
            estimator.update(progress: 0.2 + Double(second - 11) * 0.002, at: Double(second))
        }
        guard case .remaining(let afterSlowdown) = estimator.estimate(at: 41) else {
            Issue.record("Expected an estimate at the slower rate")
            return
        }
        #expect(afterSlowdown > afterBurst * 2)
    }

    @Test func stallsWithOrWithoutCallbacksAndRelearnsOnResume() {
        for repeatedUpdates in [false, true] {
            var estimator = ProgressTimeEstimator()
            estimator.update(progress: 0, at: 0)
            estimator.update(progress: 0.1, at: 10)
            if repeatedUpdates {
                for second in 11...25 { estimator.update(progress: 0.1, at: Double(second)) }
            }
            #expect(estimator.estimate(at: 25) == .stalled)
            estimator.update(progress: 0.11, at: 26)
            #expect(estimator.estimate(at: 26) == .learning)
            estimator.update(progress: 0.16, at: 31)
            guard case .remaining(let seconds) = estimator.estimate(at: 31) else {
                Issue.record("Expected a fresh estimate after resuming")
                return
            }
            #expect(abs(seconds - 84) < 0.001)
        }
    }

    @Test func resetsOnProgressRegressionMissingDataAndInvalidClock() {
        for invalidProgress in [nil, Double.nan, Double.infinity, -0.1, 1.1] {
            var estimator = ProgressTimeEstimator()
            estimator.update(progress: 0, at: 0)
            estimator.update(progress: 0.5, at: 5)
            estimator.update(progress: invalidProgress, at: 6)
            #expect(estimator.estimate(at: 6) == .unavailable)
        }
        var estimator = ProgressTimeEstimator()
        estimator.update(progress: 0.4, at: 10)
        estimator.update(progress: 0.5, at: 20)
        estimator.update(progress: 0.1, at: 21)
        #expect(estimator.estimate(at: 21) == .learning)
        estimator.update(progress: 0.2, at: 20)
        #expect(estimator.estimate(at: 20) == .learning)
        estimator.update(progress: 0.3, at: .nan)
        #expect(estimator.estimate(at: 22) == .unavailable)
    }

    @Test func notificationFrequencyDoesNotChangeTheEstimate() {
        var frequent = ProgressTimeEstimator()
        var periodic = ProgressTimeEstimator()
        for tick in 0...1000 {
            frequent.update(progress: Double(tick) / 2000, at: Double(tick) / 100)
            if tick % 100 == 0 {
                periodic.update(progress: Double(tick) / 2000, at: Double(tick) / 100)
            }
        }
        #expect(frequent.estimate(at: 10) == periodic.estimate(at: 10))
    }

    @Test func fullProgressWaitsForTheOperationToFinish() {
        var estimator = ProgressTimeEstimator()
        estimator.update(progress: 0.9, at: 0)
        estimator.update(progress: 1, at: 5)
        #expect(estimator.estimate(at: 5) == .finishing)
        #expect(estimator.estimate(at: 60) == .finishing)
        #expect(ProgressTimeEstimate.remaining(2).title == "少于 5 秒")
        #expect(ProgressTimeEstimate.remaining(63).title == "约 00:01:10")
        #expect(ProgressTimeEstimate.remaining(601).title == "约 00:11:00")
    }
}
