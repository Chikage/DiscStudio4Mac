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
            "blank": true, "busy": false, "freeBlocks": 100, "speeds": [5540.0],
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
        for values in [["busy": true], ["blank": false], ["present": false]] {
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

    @MainActor @Test func demoCannotStartRealBurnAndCanBeCancelled() {
        let store = BurnStore()
        store.startDemo()
        #expect(store.isDemo && store.isBusy)
        #expect(!store.canBurn)
        store.startBurn()
        #expect(store.isDemo)
        store.cancel()
        #expect(store.snapshot.phase == .cancelled)
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
