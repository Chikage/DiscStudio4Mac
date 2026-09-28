import Foundation
import Testing

@testable import BRCore

@MainActor
private final class ControlledBurnEngine: BurnSessionEngine {
    var onStatus: (@MainActor (BurnSnapshot) -> Void)?
    var preparations: [(URL, @MainActor (Result<DiscImage, any Error>) -> Void)] = []
    var starts: [(String, BurnOptions)] = []
    var cancellations = 0
    var ejections: [String] = []
    var failsToStart = false

    func prepareImage(at url: URL, completion: @escaping @MainActor (Result<DiscImage, any Error>) -> Void) {
        preparations.append((url, completion))
    }
    func finishPreparing(_ index: Int = 0, fails: Bool = false) {
        let (url, completion) = preparations[index]
        if fails {
            completion(.failure(CocoaError(.fileReadCorruptFile)))
        } else {
            completion(
                .success(
                    DiscImage(
                        url: url,
                        dictionary: [
                            "fileBytes": 204800, "burnBytes": 204800, "blocks": 100, "tracks": 1,
                        ])))
        }
    }
    func start(onDevice identifier: String, options: BurnOptions) throws {
        starts.append((identifier, options))
        if failsToStart { throw CocoaError(.fileWriteUnknown) }
    }
    func cancel() { cancellations += 1 }
    func eject(_ identifier: String) throws { ejections.append(identifier) }
    func send(_ phase: BurnPhase, progress: Double? = nil, speed: Double? = nil) {
        var snapshot = BurnSnapshot()
        snapshot.phase = phase
        snapshot.progress = progress
        snapshot.speedKB = speed
        if phase == .failed { snapshot.error = "设备已断开" }
        onStatus?(snapshot)
    }
}

@MainActor
struct MultiBurnTests {
    private func device(_ id: String, busy: Bool = false) -> DiscDevice {
        DiscDevice(dictionary: [
            "id": id, "name": "同型号刻录机", "present": true, "blank": true,
            "busy": busy, "canWrite": true, "freeBlocks": 1000, "speeds": [5540.0, 11080.0],
        ])
    }
    private func setup() -> (BurnStore, [ControlledBurnEngine]) {
        var engines: [ControlledBurnEngine] = []
        let store = BurnStore(makeEngine: {
            let engine = ControlledBurnEngine()
            engines.append(engine)
            return engine
        })
        store.updateDevices([device("A"), device("B"), device("C")])
        return (store, engines)
    }
    private func load(_ url: String, on id: String, store: BurnStore, engine: ControlledBurnEngine) {
        store.selectedDeviceID = id
        store.selectImage(URL(fileURLWithPath: url))
        engine.finishPreparing(engine.preparations.count - 1)
    }

    @Test func differentImagesOptionsAndProgressRunConcurrently() throws {
        let (store, engines) = setup()
        load("/first.iso", on: "A", store: store, engine: engines[0])
        store.options.speed = 5540
        store.options.verify = false
        store.startBurn()
        let first = store.selectedSession
        engines[0].send(.writing, progress: 0.2, speed: 5000)

        load("/second.iso", on: "B", store: store, engine: engines[1])
        store.options.speed = 11080
        store.startBurn()
        engines[1].send(.writing, progress: 0.7, speed: 10000)
        #expect(store.activeBurnCount == 2)
        #expect(engines[0].starts.map(\.0) == ["A"])
        #expect(engines[1].starts.map(\.0) == ["B"])
        #expect(!first.completedOptions.verify)
        #expect(store.selectedSession.completedOptions.verify)
        #expect(first.image?.url.path == "/first.iso")
        #expect(store.image?.url.path == "/second.iso")
        #expect(first.snapshot.progress == 0.2)
        #expect(first.speedHistory.samples.last?.megabytesPerSecond == 5)
        #expect(store.selectedSession.speedHistory.samples.last?.megabytesPerSecond == 10)
        #expect(first.logText.contains("first.iso"))
        #expect(!first.logText.contains("second.iso"))
        store.options.verify = false
        store.selectImage(URL(fileURLWithPath: "/forbidden.iso"))
        store.startBurn()
        store.eject()
        #expect(engines[1].starts.count == 1)
        #expect(engines[1].preparations.count == 1)
        #expect(engines[1].ejections.isEmpty)
        #expect(store.options.verify)

        // Switching away does not hide global activity from quit/image-creation protection.
        store.selectedDeviceID = "C"
        #expect(store.canEditSelectedSession && store.isBusy)
        store.mode = .buildISO
        store.createImage(to: URL(fileURLWithPath: "/unused.iso"))
        #expect(!store.imageCreation.isBusy)
        engines[0].send(.completed, progress: 1)
        #expect(store.isBusy)
        engines[1].send(.completed, progress: 1)
        #expect(!store.isBusy)
    }

    @Test func sharedImageUsesSeparatePreparationsAndFailureDoesNotBlockOtherStarts() throws {
        let (store, engines) = setup()
        load("/shared.iso", on: "A", store: store, engine: engines[0])
        store.applyImageToOtherDevices()
        #expect(engines.allSatisfy { $0.preparations.first?.0.path == "/shared.iso" })
        #expect(store.readySessions.count == 1)
        engines[1].finishPreparing()
        engines[2].finishPreparing()
        let requests = store.readySessions.compactMap(\.burnRequest)
        engines[0].failsToStart = true
        store.startBurns(requests + requests)
        #expect(engines.allSatisfy { $0.starts.count == 1 })
        #expect(store.sessions[0].snapshot.phase == .failed)
        #expect(store.sessions[0].errorMessage != nil)
        #expect(store.activeBurnCount == 2)
        engines[1].send(.failed)
        #expect(store.sessions[2].snapshot.phase == .preparing)
        #expect(store.activeBurnCount == 1)
    }

    @Test func cancellationTargetsOneDeviceAndWaitsForCleanup() {
        let (store, engines) = setup()
        for (index, id) in ["A", "B"].enumerated() {
            load("/shared.iso", on: id, store: store, engine: engines[index])
            store.startBurn()
        }
        store.selectedDeviceID = "A"
        store.cancel()
        store.cancel()
        #expect(engines[0].cancellations == 1 && engines[1].cancellations == 0)
        #expect(store.activeBurnCount == 2)
        #expect(store.snapshot.cancelling)
        #expect(!store.canEditSelectedSession)
        engines[1].send(.writing, progress: 0.4, speed: 9000)
        engines[0].send(.cancelled)
        #expect(store.activeBurnCount == 1)
        #expect(store.sessions[1].snapshot.progress == 0.4)
        #expect(store.canEditSelectedSession)
    }

    @Test func disconnectedDeviceRetainsItsJobAndIdentity() {
        let (store, engines) = setup()
        load("/a.iso", on: "A", store: store, engine: engines[0])
        store.startBurn()
        let session = store.selectedSession
        store.updateDevices([device("B"), device("C")])
        #expect(store.selectedDeviceID == "A")
        #expect(session.device == nil && session.isBusy)
        #expect(store.isBusy)
        store.cancel()
        #expect(engines[0].cancellations == 1)
        engines[0].send(.failed)
        #expect(!store.canBurn)
        store.updateDevices([device("C"), device("A"), device("B")])
        #expect(store.selectedSession === session)
        #expect(store.sessions.count == 3)
        #expect(store.canBurn)
        #expect(session.errorMessage != nil)
    }

    @Test func confirmationCannotStartChangedOrNewlyReadyJobs() throws {
        let (store, engines) = setup()
        load("/a.iso", on: "A", store: store, engine: engines[0])
        let request = try #require(store.selectedSession.burnRequest)
        load("/b.iso", on: "B", store: store, engine: engines[1])
        store.startBurns([request])
        #expect(engines[0].starts.count == 1 && engines[1].starts.isEmpty)
        let stale = try #require(store.selectedSession.burnRequest)
        store.options.verify = false
        store.startBurns([stale])
        #expect(engines[1].starts.isEmpty)
        #expect(store.errorMessage != nil)
        let changedFile = try #require(store.selectedSession.burnRequest)
        load("/b.iso", on: "B", store: store, engine: engines[1])
        store.startBurns([changedFile])
        #expect(engines[1].starts.isEmpty)
        let disconnected = try #require(store.selectedSession.burnRequest)
        store.updateDevices([device("A"), device("C")])
        store.startBurns([disconnected])
        #expect(engines[1].starts.isEmpty)
    }

    @Test func imagePanelAndOutOfOrderParsingStayBoundToTheirSession() {
        let (store, engines) = setup()
        let sessionA = store.selectedSession.id
        store.selectedDeviceID = "B"
        store.selectImage(URL(fileURLWithPath: "/a-old.iso"), sessionID: sessionA)
        store.selectImage(URL(fileURLWithPath: "/a-new.iso"), sessionID: sessionA)
        engines[0].finishPreparing(1)
        engines[0].finishPreparing(0)
        #expect(store.sessions[0].image?.url.path == "/a-new.iso")
        #expect(store.image == nil)
        store.selectImage(URL(fileURLWithPath: "/b.iso"))
        engines[1].finishPreparing(fails: true)
        #expect(store.errorMessage != nil && store.image == nil)
        #expect(store.sessions[0].errorMessage == nil)
    }

    @Test func copyingImageSkipsActiveJobsAndPreservesPerDeviceOptions() {
        let (store, engines) = setup()
        load("/running.iso", on: "A", store: store, engine: engines[0])
        store.options.speed = 5540
        store.startBurn()
        load("/new.iso", on: "B", store: store, engine: engines[1])
        store.selectedDeviceID = "C"
        store.options.verify = false
        store.selectedDeviceID = "B"
        store.applyImageToOtherDevices()
        engines[2].finishPreparing()
        #expect(engines[0].preparations.count == 1)
        #expect(store.sessions[0].image?.url.path == "/running.iso")
        #expect(store.sessions[2].image?.url.path == "/new.iso")
        #expect(!store.sessions[2].options.verify)
        store.selectedDeviceID = "A"
        #expect(store.options.speed == 5540)
    }

    @Test func demoDoesNotTouchNativeEnginesAndRestoresRealConfiguration() {
        var engines: [ControlledBurnEngine] = []
        let store = BurnStore(makeEngine: {
            let engine = ControlledBurnEngine()
            engines.append(engine)
            return engine
        })
        store.updateDevices([device("A")])
        load("/real.iso", on: "A", store: store, engine: engines[0])
        store.options.verify = false
        let original = store.selectedSession
        store.startDemo()
        #expect(store.sessions.count == 3 && store.activeBurnCount == 3)
        #expect(store.sessions[0].image?.url == store.sessions[1].image?.url)
        #expect(store.sessions[1].image?.url != store.sessions[2].image?.url)
        store.startBurn()
        store.applyImageToOtherDevices()
        for session in store.sessions { session.cancel() }
        store.exitDemo()
        #expect(!store.isDemo)
        #expect(store.selectedSession === original)
        #expect(store.image?.url.path == "/real.iso")
        #expect(!store.options.verify)
        #expect(engines.allSatisfy { $0.starts.isEmpty && $0.cancellations == 0 && $0.ejections.isEmpty })
        #expect(engines.count == 4)
        #expect(engines.dropFirst().allSatisfy { $0.preparations.isEmpty })
    }

    @Test func sharedSelectionPreparesOnlyCheckedDevicesThenStartsTogether() throws {
        let (store, engines) = setup()
        load("/unselected.iso", on: "C", store: store, engine: engines[2])
        load("/source.iso", on: "A", store: store, engine: engines[0])
        store.selectedDeviceID = "B"
        store.options.verify = false
        store.selectedDeviceID = "A"
        let source = try #require(store.image)
        let ids = Set(store.sessions.prefix(2).map(\.id))
        var completed = false
        var failure: String?
        store.startSharedImageBurn(image: source, targetIDs: ids) {
            completed = true
            failure = $0
        }
        #expect(store.isBusy && !store.canBurn && !store.canEditSelectedSession)
        #expect(engines[0].preparations.last?.0.path == "/source.iso")
        #expect(engines[1].preparations.last?.0.path == "/source.iso")
        #expect(engines[2].preparations.count == 1)
        store.options.verify = false
        store.selectImage(URL(fileURLWithPath: "/must-not-replace.iso"))
        #expect(store.options.verify)
        #expect(engines[0].preparations.count == 2)
        engines[0].finishPreparing(1)
        #expect(!completed && engines.allSatisfy { $0.starts.isEmpty })
        // A separately confirmed start cannot steal a reserved destination.
        store.startBurn()
        #expect(engines[0].starts.isEmpty)
        engines[1].finishPreparing()
        #expect(completed && failure == nil)
        #expect(store.activeBurnCount == 2)
        #expect(engines[0].starts.count == 1 && engines[1].starts.count == 1)
        #expect(!engines[1].starts[0].1.verify)
        #expect(engines[2].starts.isEmpty)
        #expect(store.sessions[2].image?.url.path == "/unselected.iso")
    }

    @Test func sharedSelectionCancellationCannotStartFromLateCallbacks() throws {
        let (store, engines) = setup()
        load("/source.iso", on: "A", store: store, engine: engines[0])
        let source = try #require(store.image)
        var completionCount = 0
        store.startSharedImageBurn(image: source, targetIDs: Set(store.sessions.prefix(2).map(\.id))) { error in
            completionCount += 1
            #expect(error?.contains("取消") == true)
        }
        engines[0].finishPreparing(1)
        store.cancelSharedImageBurn()
        engines[1].finishPreparing()
        #expect(completionCount == 1)
        #expect(engines.allSatisfy { $0.starts.isEmpty })
        #expect(!store.isBusy && !store.isLoadingImage && store.canEditSelectedSession)
    }

    @Test func sharedSelectionFailureOrDisconnectPreventsAllWrites() throws {
        for disconnect in [false, true] {
            let (store, engines) = setup()
            load("/source.iso", on: "A", store: store, engine: engines[0])
            let source = try #require(store.image)
            var failure: String?
            store.startSharedImageBurn(image: source, targetIDs: Set(store.sessions.prefix(2).map(\.id))) {
                failure = $0
            }
            engines[0].finishPreparing(1)
            if disconnect { store.updateDevices([device("A"), device("C")]) }
            engines[1].finishPreparing(fails: !disconnect)
            #expect(failure?.contains("均未开始写入") == true)
            #expect(engines.allSatisfy { $0.starts.isEmpty })
            #expect(!store.isBusy)
        }
    }

    @Test func sharedSelectionValidatesDestinationsAgainstSourceImage() throws {
        let (store, engines) = setup()
        load("/source.iso", on: "A", store: store, engine: engines[0])
        let source = try #require(store.image)
        let second = store.sessions[1]
        #expect(second.image == nil)
        #expect(store.sharedImageIssue(source, for: second) == nil)
        store.updateDevices([device("A"), device("B", busy: true), device("C")])
        #expect(store.sharedImageIssue(source, for: second) != nil)
        var failure: String?
        store.startSharedImageBurn(image: source, targetIDs: [store.sessions[0].id, second.id]) { failure = $0 }
        #expect(failure != nil)
        #expect(engines[0].preparations.count == 1 && engines[1].preparations.isEmpty)
        store.startSharedImageBurn(image: source, targetIDs: []) { failure = $0 }
        #expect(failure?.contains("请选择") == true)
        #expect(engines.allSatisfy { $0.starts.isEmpty })
    }

    @Test func sharedSelectionRejectsChangedOptionsAndNewlyDiscoveredDevicesStayUnselected() throws {
        let (store, engines) = setup()
        load("/source.iso", on: "A", store: store, engine: engines[0])
        store.options.speed = 5540
        let source = try #require(store.image)
        var failure: String?
        store.startSharedImageBurn(image: source, targetIDs: [store.sessions[0].id, store.sessions[1].id]) {
            failure = $0
        }
        // Device/media updates can invalidate a previously selected speed during asynchronous parsing.
        let noSpeeds = DiscDevice(dictionary: [
            "id": "A", "name": "同型号刻录机", "present": true, "blank": true,
            "canWrite": true, "freeBlocks": 1000,
        ])
        store.updateDevices([noSpeeds, device("B"), device("C"), device("D")])
        engines[0].finishPreparing(1)
        engines[1].finishPreparing()
        #expect(failure?.contains("已改变") == true)
        #expect(engines.allSatisfy { $0.starts.isEmpty })
        #expect(store.sessions[3].image == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BR_TEST_IMAGE"] != nil))
    func nativeEnginesPrepareTheSameImageIndependently() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BR_TEST_IMAGE"])
        let url = URL(fileURLWithPath: path)
        let first = NativeBurnSessionEngine()
        let second = NativeBurnSessionEngine()
        let images = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[DiscImage], any Error>) in
            var results: [Result<DiscImage, any Error>] = []
            let receive: @MainActor (Result<DiscImage, any Error>) -> Void = { result in
                results.append(result)
                if results.count == 2 {
                    continuation.resume(with: Result { try results.map { try $0.get() } })
                }
            }
            first.prepareImage(at: url, completion: receive)
            second.prepareImage(at: url, completion: receive)
        }
        #expect(images.count == 2)
        #expect(images.allSatisfy { $0.blocks > 0 && $0.tracks == 1 })
        #expect(images[0].blocks == images[1].blocks)
        // Replacing one engine's layout must not discard the other's successfully prepared layout.
        let failed = await withCheckedContinuation { continuation in
            first.prepareImage(at: URL(fileURLWithPath: "/missing.iso")) { result in
                if case .failure = result {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
        #expect(failed)
        do {
            try second.start(onDevice: "nonexistent-device", options: BurnOptions())
            Issue.record("An invalid device must never start")
        } catch {
            #expect(error.localizedDescription.contains("断开"))
        }
    }
}
