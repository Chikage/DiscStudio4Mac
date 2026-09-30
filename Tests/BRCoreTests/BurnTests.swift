import DiscBridge
import Foundation
import Testing

@testable import BRCore

struct BurnTests {
    private func image(blocks: UInt64 = 100) -> DiscImage {
        DiscImage(
            url: URL(fileURLWithPath: "/test.iso"),
            dictionary: [
                "fileBytes": 204800, "burnBytes": 204800, "blocks": NSNumber(value: blocks), "tracks": 1,
            ])
    }

    private func device(_ changes: [String: Any] = [:]) -> DiscDevice {
        var values: [String: Any] = [
            "id": "test", "name": "Test", "present": true,
            "blank": true, "busy": false, "canWrite": true, "freeBlocks": 100, "speeds": [5540.0],
        ]
        values.merge(changes) { _, new in new }
        return DiscDevice(dictionary: values)
    }

    @Test func capacityUsesTrackBlocksAndAcceptsExactFit() {
        #expect(BurnPreflight.issue(image: image(), device: device(), options: BurnOptions()) == nil)
        #expect(BurnPreflight.issue(image: image(blocks: 101), device: device(), options: BurnOptions()) != nil)
        #expect(BurnPreflight.issue(image: image(), device: device(["freeBlocks": 0]), options: BurnOptions()) != nil)
    }

    @Test func rejectsMissingBusyAndUsedMedia() {
        #expect(BurnPreflight.issue(image: nil, device: device(), options: BurnOptions()) != nil)
        #expect(BurnPreflight.issue(image: image(), device: nil, options: BurnOptions()) != nil)
        for values in [["busy": true], ["blank": false], ["present": false], ["canWrite": false]] {
            #expect(BurnPreflight.issue(image: image(), device: device(values), options: BurnOptions()) != nil)
        }
    }

    @Test func rejectsStaleSpeed() {
        var options = BurnOptions()
        options.speed = 5540
        #expect(BurnPreflight.issue(image: image(), device: device(), options: options) == nil)
        options.speed = 11080
        #expect(BurnPreflight.issue(image: image(), device: device(), options: options) != nil)
    }

    @Test func telemetryDoesNotInventUnavailableOrInvalidValues() {
        let absent = BurnSnapshot(dictionary: ["phase": "writing"])
        #expect(absent.progress == nil)
        #expect(absent.speedKB == nil)
        let invalid = BurnSnapshot(dictionary: ["phase": "writing", "progress": Double.nan, "speedKB": -1])
        #expect(invalid.progress == nil)
        #expect(invalid.speedKB == nil)
        let clamped = BurnSnapshot(dictionary: ["phase": "writing", "progress": 1.2, "speedKB": 11080])
        #expect(clamped.progress == 1)
        #expect(clamped.speedKB == 11080)
        let raw = BurnSnapshot(dictionary: [
            "phase": "writing", "rawState": "DRStatusStateTrackWrite", "currentSpeedRaw": "8992",
        ])
        #expect(raw.rawState == "DRStatusStateTrackWrite")
        #expect(raw.currentSpeedRaw == "8992")
    }

    @Test func verificationDoesNotShowStaleWriteSpeedOrPrematureCompletion() {
        let verifying = BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0.2, "speedKB": 9000])
        #expect(verifying.phase.isActive)
        #expect(verifying.speedKB == nil)
        #expect(verifying.progress == 0.2)
        #expect(BurnSnapshot(dictionary: ["phase": "completed"]).progress == 1)
        #expect(!BurnPhase.failed.isActive)
        #expect(!BurnPhase.cancelled.isActive)
    }

    @Test func safeDefaultsAndSpeedUnits() {
        let options = BurnOptions()
        #expect(options.verify && options.finalize && options.eject)
        #expect(options.speed == 0)
        #expect(device().speedLabel(11080).contains("11.1 MB/s"))
        #expect(BurnFormat.duration(3661) == "01:01:01")
    }

    @Test func missingBufferCapacityAndDuplicateSpeedsRemainHonest() {
        #expect(device(["bufferCapacity": 0]).bufferCapacity == nil)
        #expect(device(["bufferCapacity": -1]).bufferCapacity == nil)
        #expect(device(["bufferCapacity": 2_097_152]).bufferCapacity == 2_097_152)
        #expect(device(["speeds": [5540.0, 5540.0, Double.nan]]).speeds == [5540])
    }

    @Test func hardwareMetadataOmitsMissingAndUnreportedValues() {
        let absent = device()
        #expect(absent.vendor == nil && absent.product == nil && absent.firmware == nil)
        #expect(absent.interconnect == nil && absent.location == nil)
        #expect(absent.writableMedia.isEmpty)

        let incomplete = device([
            "vendor": " \n", "product": 42, "firmware": NSNull(),
            "interconnect": " unknown ", "location": "Unknown", "writableMedia": ["", "Unknown"],
        ])
        #expect(incomplete.vendor == nil && incomplete.product == nil && incomplete.firmware == nil)
        #expect(incomplete.interconnect == nil && incomplete.location == nil)
        #expect(incomplete.writableMedia.isEmpty)
    }

    @Test func hardwareMetadataPreservesReportedValuesWithoutMedia() {
        let drive = device([
            "present": false, "vendor": " HL-DT-ST ", "product": "BD-RE BP55EB40",
            "firmware": "1.00", "interconnect": "USB", "location": "External",
            "writableMedia": ["CD", "DVD", "BD"], "bufferCapacity": 4_161_536,
        ])
        #expect(drive.vendor == "HL-DT-ST")
        #expect(drive.product == "BD-RE BP55EB40")
        #expect(drive.firmware == "1.00")
        #expect(drive.interconnect == "USB" && drive.location == "External")
        #expect(drive.writableMedia == ["CD", "DVD", "BD"])
        #expect(drive.bufferCapacity == 4_161_536)
    }

    @Test func speedHistoryRetainsTheWholePhaseAtHighUpdateRates() {
        var history = SpeedHistory()
        for tick in 0...100_000 {
            history.record(progress: Double(tick) / 100_000, megabytesPerSecond: 17)
        }
        #expect(history.samples.count <= 1002)
        #expect(history.samples.first?.progress == 0)
        #expect(history.samples.last?.progress == 1)
        #expect(history.progress == 1)
    }

    @Test func speedHistoryUsesReportedProgressAndUpdatesRepeatedReadings() {
        var history = SpeedHistory()
        history.record(progress: 0.13, megabytesPerSecond: 11.81)
        history.record(progress: 0.13, megabytesPerSecond: 7)
        #expect(history.samples.count == 1)
        history.record(progress: 0.1305, megabytesPerSecond: 12)
        #expect(history.samples.count == 2)
        #expect(history.samples.last?.progress == 0.1305)
        #expect(history.samples.last?.megabytesPerSecond == 12)
        history.record(progress: 0.5, megabytesPerSecond: 0)
        #expect(history.samples.map(\.progress) == [0.13, 0.1305, 0.5])
        #expect(history.samples.last?.megabytesPerSecond == 0)
    }

    @Test func speedHistoryDoesNotInventMissingProgressOrSpeed() {
        var history = SpeedHistory()
        for progress in [nil, Double.nan, -0.1, 1.1] {
            history.record(progress: progress, megabytesPerSecond: 12)
        }
        #expect(history.samples.isEmpty)
        #expect(history.progress == nil)
        for speed in [nil, Double.nan, Double.infinity, -1] {
            history.record(progress: 0.2, megabytesPerSecond: speed)
        }
        #expect(history.samples.isEmpty)
        #expect(history.progress == 0.2)
        history.record(progress: 0.3, megabytesPerSecond: 12)
        history.record(progress: 0.4, megabytesPerSecond: nil)
        #expect(history.samples.last?.progress == 0.3)
        #expect(history.progress == 0.4)
    }

    @Test func speedHistoryResetsWhenDeviceProgressRestartsEvenWithoutSpeed() {
        var history = SpeedHistory()
        history.record(progress: 0.8, megabytesPerSecond: 12)
        history.record(progress: 0.1, megabytesPerSecond: nil)
        #expect(history.samples.isEmpty)
        #expect(history.progress == 0.1)
        history.record(progress: 0.2, megabytesPerSecond: 10)
        #expect(history.samples.map(\.progress) == [0.2])
    }

    @Test func verificationStartsANewSpeedCurveAndRetainsItsMeaningAfterCompletion() {
        var history = SpeedHistory()
        history.record(progress: 0.9, megabytesPerSecond: 17)
        history.beginPhase(.finishing)
        #expect(history.samples.count == 1)
        history.beginPhase(.verifying)
        #expect(history.samples.isEmpty)
        #expect(history.progress == nil)
        #expect(history.phase == .verifying)
        history.record(progress: 0.1, megabytesPerSecond: 12)
        history.beginPhase(.verifying)
        history.beginPhase(.completed)
        #expect(history.samples.map(\.megabytesPerSecond) == [12])
        #expect(history.progress == 0.1)
        #expect(history.phase == .verifying)
        history.beginPhase(.writing)
        #expect(history.samples.isEmpty)
        #expect(history.phase == .writing)
    }

    @Test func verificationSpeedEstimatesReadProgressWithoutReusingWriteSpeed() throws {
        var estimator = VerificationSpeedEstimator()
        var snapshot = BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0.1, "speedKB": 9000])
        estimator.update(snapshot, totalBytes: 100_000_000, at: 10)
        #expect(estimator.kilobytesPerSecond == nil)
        snapshot.progress = 0.11
        estimator.update(snapshot, totalBytes: 100_000_000, at: 10.2)
        #expect(estimator.kilobytesPerSecond == nil)
        snapshot.progress = 0.12
        estimator.update(snapshot, totalBytes: 100_000_000, at: 11)
        let speed = try #require(estimator.kilobytesPerSecond)
        #expect(abs(speed - 2000) < 0.001)
        estimator.update(snapshot, totalBytes: 100_000_000, at: 12)
        #expect(estimator.kilobytesPerSecond == 0)
        snapshot.phase = .completed
        estimator.update(snapshot, totalBytes: 100_000_000, at: 13)
        #expect(estimator.kilobytesPerSecond == nil)
    }

    @Test func verificationCurveIncludesItsMeasuredStartAndSuccessfulEnd() throws {
        var estimator = VerificationSpeedEstimator()
        var history = SpeedHistory()
        history.beginPhase(.verifying)
        var snapshot = BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0, "track": 1])
        #expect(estimator.update(snapshot, totalBytes: 100_000_000, at: 10) == nil)
        snapshot.progress = 0.2
        let firstReading = estimator.update(snapshot, totalBytes: 100_000_000, at: 11)
        let first = try #require(firstReading)
        history.record(first)
        #expect(first.progressRange == 0...0.2)
        #expect(history.samples.map(\.progress) == [0, 0.2])
        snapshot.progress = 0.94
        let intermediateReading = estimator.update(snapshot, totalBytes: 100_000_000, at: 15)
        history.record(try #require(intermediateReading))
        let finalReading = estimator.finish(totalBytes: 100_000_000, at: 15.3)
        let last = try #require(finalReading)
        history.record(last)
        #expect(last.progressRange == 0.94...1)
        #expect(abs(last.kilobytesPerSecond - 20_000) < 0.001)
        #expect(history.samples.first?.progress == 0)
        #expect(history.samples.last?.progress == 1)
        #expect(estimator.finish(totalBytes: 100_000_000, at: 16) == nil)
    }

    @Test func verificationDoesNotInventAnUnobservedStartOrFinishAfterFailure() throws {
        var estimator = VerificationSpeedEstimator()
        var history = SpeedHistory()
        var snapshot = BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0.3])
        estimator.update(snapshot, totalBytes: 100_000_000, at: 10)
        snapshot.progress = 0.5
        let reading = estimator.update(snapshot, totalBytes: 100_000_000, at: 11)
        history.record(try #require(reading))
        #expect(history.samples.first?.progress == 0.3)
        #expect(estimator.finish(totalBytes: 200_000_000, at: 12) == nil)
        #expect(estimator.finish(totalBytes: 100_000_000, at: 11) == nil)
        snapshot.phase = .failed
        estimator.update(snapshot, totalBytes: 100_000_000, at: 12)
        #expect(estimator.finish(totalBytes: 100_000_000, at: 13) == nil)
        #expect(history.samples.last?.progress == 0.5)
    }

    @Test func verificationCanFinishBeforeItsFirstRegularSpeedReading() throws {
        var estimator = VerificationSpeedEstimator()
        var history = SpeedHistory()
        estimator.update(BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0]), totalBytes: 1_000_000, at: 10)
        let reading = estimator.finish(totalBytes: 1_000_000, at: 10.5)
        history.record(try #require(reading))
        #expect(history.samples.map(\.progress) == [0, 1])
        #expect(history.samples.last?.megabytesPerSecond == 2)
    }

    @Test func verificationSpeedResetsAcrossTracksMissingProgressAndCancellation() {
        var estimator = VerificationSpeedEstimator()
        var snapshot = BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0.5, "track": 1])
        estimator.update(snapshot, totalBytes: 100_000_000, at: 10)
        snapshot.track = 2
        snapshot.progress = 0.6
        estimator.update(snapshot, totalBytes: 100_000_000, at: 11)
        #expect(estimator.kilobytesPerSecond == nil)
        snapshot.progress = 0.1
        estimator.update(snapshot, totalBytes: 100_000_000, at: 12)
        #expect(estimator.kilobytesPerSecond == nil)
        snapshot.progress = 0.2
        estimator.update(snapshot, totalBytes: 100_000_000, at: 13)
        #expect(estimator.kilobytesPerSecond != nil)
        snapshot.progress = nil
        estimator.update(snapshot, totalBytes: 100_000_000, at: 14)
        #expect(estimator.kilobytesPerSecond == nil)
        snapshot.progress = 0.3
        estimator.update(snapshot, totalBytes: 100_000_000, at: 15)
        #expect(estimator.kilobytesPerSecond == nil)
        snapshot.progress = 0.4
        estimator.update(snapshot, totalBytes: 100_000_000, at: 16)
        #expect(estimator.kilobytesPerSecond != nil)
        snapshot.cancelling = true
        estimator.update(snapshot, totalBytes: 100_000_000, at: 17)
        #expect(estimator.kilobytesPerSecond == nil)
    }

    @Test func verificationSpeedRejectsUnavailableSizeAndInvalidTiming() {
        var estimator = VerificationSpeedEstimator()
        var snapshot = BurnSnapshot(dictionary: ["phase": "verifying", "progress": 0.1])
        estimator.update(snapshot, totalBytes: 0, at: 10)
        #expect(estimator.kilobytesPerSecond == nil)
        estimator.update(snapshot, totalBytes: 100_000_000, at: 10)
        snapshot.progress = 0.2
        estimator.update(snapshot, totalBytes: 100_000_000, at: 9)
        #expect(estimator.kilobytesPerSecond == nil)
        estimator.update(snapshot, totalBytes: 100_000_000, at: .nan)
        #expect(estimator.kilobytesPerSecond == nil)
    }

    @MainActor @Test func demoCannotStartRealBurnAndCanBeCancelled() {
        let store = BurnStore()
        store.startDemo()
        #expect(store.isDemo && store.isBusy)
        #expect(!store.canBurn)
        store.startBurn()
        #expect(store.isDemo)
        store.cancel()
        #expect(store.snapshot.phase == .cancelled)
        #expect(store.activeBurnCount == 2)
        for session in store.sessions { session.cancel() }
        #expect(!store.isBusy)
        store.exitDemo()
        #expect(!store.isDemo)
        #expect(store.image == nil)
    }

    @MainActor @Test func nativeAdapterRejectsInvalidPath() async {
        let engine = BRDiscEngine()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            engine.prepareImage(at: URL(fileURLWithPath: "/nonexistent/BR-test.iso")) { metadata, error in
                continuation.resume(returning: metadata == nil && error != nil)
            }
        }
        #expect(result)
    }

    @MainActor @Test func nativeAdapterRejectsUnpreparedBurn() {
        let engine = BRDiscEngine()
        #expect(throws: (any Error).self) {
            try engine.start(onDevice: "invalid", speed: 0, finalize: true, verify: true, eject: false)
        }
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BR_TEST_IMAGE"] != nil))
    func nativeLayoutParsesGeneratedISO() async throws {
        guard let path = ProcessInfo.processInfo.environment["BR_TEST_IMAGE"] else { return }
        let engine = BRDiscEngine()
        let metadata = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<DiscImage, any Error>) in
            let url = URL(fileURLWithPath: path)
            engine.prepareImage(at: url) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    continuation.resume(returning: DiscImage(url: url, dictionary: metadata))
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
        #expect(metadata.blocks > 0)
        #expect(metadata.tracks == 1)
        #expect(metadata.burnBytes > 0)
    }
}
