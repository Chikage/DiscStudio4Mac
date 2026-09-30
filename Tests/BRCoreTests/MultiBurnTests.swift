import Foundation
import Testing

@testable import BRCore

@MainActor
private final class ControlledBurnEngine: BurnSessionEngine {
    var onStatus: (@MainActor (BurnSnapshot) -> Void)?
    var onDiagnostic: (@MainActor (String) -> Void)?
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

private actor CrossModeImageService: ImageFileServicing {
    private var operations: [URL: CheckedContinuation<Void, any Error>] = [:]
    var pendingCount: Int { operations.count }

    func build(
        sources: [URL], volumeName: String, fileSystem: DataDiscFileSystem, destination: URL,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        await update(ImageUpdate(.building, "文件镜像测试进度", progress: 0.3))
        try await waitForCompletion(destination)
    }

    func copyDisc(
        device: DiscDevice, format: DiscCopyFormat, destination: URL,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        await update(ImageUpdate(.copying, "光盘提取测试进度", progress: 0.6))
        try await waitForCompletion(destination)
    }

    private func waitForCompletion(_ destination: URL) async throws {
        try await withCheckedThrowingContinuation { operations[destination] = $0 }
        // Cancellation keeps the resource reserved until simulated cleanup is complete.
        try Task.checkCancellation()
    }

    func finish(_ destination: URL, fails: Bool = false) {
        let continuation = operations.removeValue(forKey: destination)
        if fails {
            continuation?.resume(throwing: CocoaError(.fileReadUnknown))
        } else {
            continuation?.resume()
        }
    }
}

@MainActor
struct MultiBurnTests {
    private func device(_ id: String, busy: Bool = false, readable: Bool = false) -> DiscDevice {
        DiscDevice(dictionary: [
            "id": id, "name": "同型号刻录机", "present": true, "blank": !readable,
            "busy": busy, "canWrite": true, "freeBlocks": 1000, "speeds": [5540.0, 11080.0],
            "mediaBSDName": "disk42", "volumeName": id,
        ])
    }
    private func setup(imageService: (any ImageFileServicing)? = nil) -> (BurnStore, [ControlledBurnEngine]) {
        var engines: [ControlledBurnEngine] = []
        let store = BurnStore(makeEngine: {
            let engine = ControlledBurnEngine()
            engines.append(engine)
            return engine
        }, makeImageService: { imageService ?? ImageFileService() })
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
        #expect(engines[0].starts[0].1.speed == 5540)
        #expect(engines[1].starts[0].1.speed == 11080)
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

        // Switching modes does not hide global activity from quit protection.
        store.selectedDeviceID = "C"
        #expect(store.canEditSelectedSession && store.isBusy)
        store.mode = .buildISO
        engines[0].send(.completed, progress: 1)
        #expect(store.isBusy)
        engines[1].send(.completed, progress: 1)
        #expect(!store.isBusy)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let completed = await condition()
        try #require(completed, "Timed out waiting for the controlled operation")
    }

    @Test func burningCopyingAndBuildingKeepIndependentProgressAndCancellation() async throws {
        let service = CrossModeImageService()
        let (store, engines) = setup(imageService: service)
        load("/burn.iso", on: "A", store: store, engine: engines[0])
        store.startBurn()
        engines[0].send(.writing, progress: 0.2)
        // Even a stale device report must not allow reads from a drive being burned.
        store.updateDevices([device("A", readable: true), device("B", readable: true), device("C")])
        store.mode = .copyDisc
        #expect(store.imageCreationIssue?.contains("刻录") == true)
        store.selectedDeviceID = "B"
        #expect(store.imageCreationIssue == nil)
        let copy = store.imageCreation
        let copyURL = URL(fileURLWithPath: "/tmp/cross-mode-copy.iso")
        store.createImage(to: copyURL)
        store.mode = .buildISO
        let build = store.imageCreation
        build.addSources([URL(fileURLWithPath: "/test-source")])
        #expect(store.imageCreationIssue == nil)
        let buildURL = URL(fileURLWithPath: "/tmp/cross-mode-build.iso")
        store.createImage(to: buildURL)
        try await waitUntil { await service.pendingCount == 2 }
        #expect(store.activeBurnCount == 1 && store.activeDiscCopyCount == 1 && build.isBusy)
        #expect(copy.status.progress == 0.6 && build.status.progress == 0.3)
        store.mode = .burn
        store.selectedDeviceID = "A"
        #expect(store.snapshot.progress == 0.2)
        store.mode = .copyDisc
        store.selectedDeviceID = "B"
        #expect(store.imageCreation === copy)
        copy.cancel()
        #expect(copy.isBusy && copy.isCancelling)
        #expect(store.discCopyRequest(for: store.selectedSession) == nil)
        engines[0].send(.verifying, progress: 0.7)
        await service.finish(copyURL)
        try await waitUntil { !copy.isBusy }
        #expect(copy.status.phase == .cancelled && copy.outputURL == nil)
        #expect(build.isBusy && store.activeBurnCount == 1)
        await service.finish(buildURL, fails: true)
        try await waitUntil { !build.isBusy }
        #expect(build.status.phase == .failed && store.isBusy)
        store.selectedDeviceID = "A"
        #expect(store.snapshot.phase == .verifying && store.snapshot.progress == 0.7)
        engines[0].send(.completed, progress: 1)
        #expect(!store.isBusy)
    }

    @Test func imageJobsAllowSharedBurnPreparationAndStartsOnOtherDevices() async throws {
        let service = CrossModeImageService()
        let (store, engines) = setup(imageService: service)
        store.updateDevices([device("A"), device("B"), device("C", readable: true)])
        let copyURL = URL(fileURLWithPath: "/tmp/shared-burn-copy.iso")
        let buildURL = URL(fileURLWithPath: "/tmp/shared-burn-build.iso")
        store.dataImageCreation.addSources([URL(fileURLWithPath: "/source")])
        store.createDataImage(to: buildURL)
        store.selectedDeviceID = "C"
        store.mode = .copyDisc
        store.createImage(to: copyURL)
        load("/burn.iso", on: "A", store: store, engine: engines[0])
        store.mode = .burn
        #expect(store.canBurn)
        store.applyImageToOtherDevices()
        #expect(engines[1].preparations.count == 1 && engines[2].preparations.isEmpty)
        engines[1].finishPreparing()
        #expect(store.readySessions.map(\.deviceID) == ["A", "B"])
        let image = try #require(store.image)
        var completed = false
        store.startSharedImageBurn(image: image, targetIDs: Set(store.sessions.prefix(2).map(\.id))) {
            #expect($0 == nil)
            completed = true
        }
        engines[0].finishPreparing(1)
        #expect(store.discCopyIssue(for: store.sessions[0])?.contains("准备") == true)
        #expect(!store.canEditSelectedSession && !completed)
        engines[1].finishPreparing(1)
        #expect(completed && store.activeBurnCount == 2)
        #expect(store.activeDiscCopyCount == 1 && store.dataImageCreation.isBusy)
        try await waitUntil { await service.pendingCount == 2 }
        await service.finish(buildURL)
        await service.finish(copyURL)
        try await waitUntil { !store.isCreatingImage }
        #expect(store.isBusy && store.dataImageCreation.outputURL == buildURL)
        engines[0].send(.completed)
        engines[1].send(.completed)
        #expect(!store.isBusy)
    }

    @Test func copyingReservesOnlyItsDriveUntilCancellationCleanupFinishes() async throws {
        let service = CrossModeImageService()
        let (store, engines) = setup(imageService: service)
        load("/burn.iso", on: "A", store: store, engine: engines[0])
        let request = try #require(store.selectedSession.burnRequest)
        let image = try #require(store.image)
        store.updateDevices([device("A", readable: true), device("B"), device("C")])
        store.mode = .copyDisc
        let copyURL = URL(fileURLWithPath: "/tmp/reserved-copy.iso")
        store.createImage(to: copyURL)
        let copy = store.imageCreation
        try await waitUntil { await service.pendingCount == 1 }
        store.updateDevices([device("A"), device("B"), device("C")])
        for cancelling in [false, true] {
            if cancelling { copy.cancel() }
            store.mode = .burn
            #expect(!store.canBurn && !store.canEditSelectedSession)
            #expect(store.preflightIssue?.contains("提取") == true)
            #expect(store.selectedSession.burnRequest == nil)
            #expect(store.sharedImageIssue(image, for: store.selectedSession) != nil)
            store.startBurns([request])
            store.selectImage(URL(fileURLWithPath: "/must-not-replace.iso"))
            store.eject()
            #expect(engines[0].starts.isEmpty && engines[0].ejections.isEmpty)
            #expect(engines[0].preparations.count == 1)
        }
        load("/other.iso", on: "B", store: store, engine: engines[1])
        store.startBurn()
        #expect(engines[1].starts.count == 1 && store.isBusy)
        await service.finish(copyURL)
        try await waitUntil { !copy.isBusy }
        store.selectedDeviceID = "A"
        #expect(store.canBurn && store.canEditSelectedSession)
        store.startBurns([request])
        #expect(engines[0].starts.count == 1)
        engines[0].send(.completed)
        engines[1].send(.completed)
        #expect(!store.isBusy)
    }

    @Test(arguments: [false, true])
    func buildingAndCopyingCannotShareAnActiveDestination(copyFirst: Bool) async throws {
        let service = CrossModeImageService()
        let (store, _) = setup(imageService: service)
        store.updateDevices([device("A", readable: true)])
        let request = try #require(store.discCopyRequest(for: store.selectedSession))
        let destination = URL(fileURLWithPath: "/tmp/cross-mode-conflict.iso")
        let alias = URL(fileURLWithPath: "/tmp/CROSS-MODE-CONFLICT.iso")
        store.dataImageCreation.addSources([URL(fileURLWithPath: "/source")])
        let first = copyFirst ? store.selectedSession.discCopy : store.dataImageCreation
        let second = copyFirst ? store.dataImageCreation : store.selectedSession.discCopy
        if copyFirst {
            store.createDiscImage(request, to: destination)
            store.createDataImage(to: alias)
        } else {
            store.createDataImage(to: destination)
            store.createDiscImage(request, to: alias)
        }
        #expect(first.isBusy && !second.isBusy)
        #expect(second.errorMessage?.contains("同一位置") == true)
        try await waitUntil { await service.pendingCount == 1 }
        await service.finish(destination)
        try await waitUntil { !first.isBusy }
        if copyFirst {
            store.createDataImage(to: alias)
        } else {
            store.createDiscImage(request, to: alias)
        }
        #expect(second.isBusy && second.errorMessage == nil)
        try await waitUntil { await service.pendingCount == 1 }
        await service.finish(alias)
        try await waitUntil { !store.isBusy }
        #expect(second.outputURL == alias)
    }

    @Test func imageOutputsCannotReplaceReservedBurnSourcesOrBeBurnedWhileSaving() async throws {
        let service = CrossModeImageService()
        let (store, engines) = setup(imageService: service)
        store.updateDevices([device("A"), device("B", readable: true), device("C")])
        load("/tmp/protected-burn.iso", on: "A", store: store, engine: engines[0])
        let image = try #require(store.image)
        let copyRequest = try #require(store.discCopyRequest(for: store.sessions[1]))
        store.dataImageCreation.addSources([URL(fileURLWithPath: "/source")])
        store.startSharedImageBurn(image: image, targetIDs: [store.selectedSession.id]) { #expect($0 == nil) }
        store.createDataImage(to: image.url)
        #expect(!store.dataImageCreation.isBusy)
        #expect(store.dataImageCreation.errorMessage?.contains("用于刻录") == true)
        engines[0].finishPreparing(1)
        #expect(store.activeBurnCount == 1)
        store.createDataImage(to: image.url)
        store.createDiscImage(copyRequest, to: image.url)
        #expect(!store.isCreatingImage)
        #expect(store.sessions[1].discCopy.errorMessage?.contains("用于刻录") == true)
        engines[0].send(.completed)
        let burnRequest = try #require(store.selectedSession.burnRequest)
        store.createDataImage(to: image.url)
        #expect(store.dataImageCreation.isBusy)
        #expect(!store.canBurn && store.readySessions.isEmpty)
        #expect(store.preflightIssue?.contains("正在生成或替换") == true)
        #expect(store.sharedImageIssue(image, for: store.selectedSession) != nil)
        store.startBurns([burnRequest])
        #expect(engines[0].starts.count == 1)
        try await waitUntil { await service.pendingCount == 1 }
        await service.finish(image.url)
        try await waitUntil { !store.isBusy }
    }

    @Test func savedCopyRequestSurvivesTabSwitchButRechecksDriveReservation() async throws {
        let service = CrossModeImageService()
        let (store, engines) = setup(imageService: service)
        store.updateDevices([device("A", readable: true), device("B"), device("C")])
        let request = try #require(store.discCopyRequest(for: store.selectedSession))
        store.mode = .buildISO
        store.selectedDeviceID = "B"
        let destination = URL(fileURLWithPath: "/tmp/captured-copy.iso")
        store.createDiscImage(request, to: destination)
        let copy = store.sessions[0].discCopy
        #expect(copy.isBusy && copy.copySource?.id == "A")
        #expect(!store.selectedSession.discCopy.isBusy)
        try await waitUntil { await service.pendingCount == 1 }
        await service.finish(destination)
        try await waitUntil { !copy.isBusy }
        store.updateDevices([device("A"), device("B"), device("C")])
        load("/burn.iso", on: "A", store: store, engine: engines[0])
        store.startBurn()
        store.updateDevices([device("A", readable: true), device("B"), device("C")])
        store.createDiscImage(request, to: destination)
        #expect(!copy.isBusy && copy.errorMessage?.contains("刻录") == true)
        engines[0].send(.completed)
    }

    @Test func diagnosticLogsStayWithTheirDeviceAndRetainStartupAfterManySamples() throws {
        let (store, engines) = setup()
        load("/first.iso", on: "A", store: store, engine: engines[0])
        store.options.speed = 5540
        store.startBurn()
        let first = store.selectedSession
        engines[0].onDiagnostic?("[原生速度请求] native-A")
        load("/second.iso", on: "B", store: store, engine: engines[1])
        store.startBurn()
        engines[1].onDiagnostic?("[原生速度请求] native-B")
        // Each track begins a sample immediately, allowing retention testing without wall-clock waits.
        for track in 1...405 {
            var update = BurnSnapshot()
            update.phase = .writing
            update.track = track
            update.speedKB = 5000
            engines[0].onStatus?(update)
        }
        #expect(first.logs.filter(\.isSpeedSample).count == 400)
        #expect(first.logText.contains("已省略 5 条"))
        #expect(first.logText.contains("[所选写入速度] 5540.000 KB/s"))
        #expect(first.logText.contains("native-A"))
        #expect(!first.logText.contains("native-B"))
        #expect(store.selectedSession.logText.contains("自动 · 请求设备最高速度"))
        #expect(store.selectedSession.logText.contains("native-B"))
        #expect(!store.selectedSession.logText.contains("native-A"))
        engines[0].send(.failed)
        engines[0].onDiagnostic?("late-callback")
        #expect(first.logText.contains("设备已断开"))
        #expect(!first.logText.contains("late-callback"))
        store.selectedDeviceID = "A"
        store.startBurn()
        engines[0].send(.writing, speed: 1000)
        let restartedSample = first.logs.last(where: { $0.isSpeedSample })
        #expect(restartedSample?.message.contains("本段最低–最高=1000.000–1000.000 KB/s") == true)
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
        store.options.speed = 11080
        store.selectedDeviceID = "A"
        store.options.speed = 5540
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
        #expect(engines[0].starts[0].1.speed == 5540)
        #expect(engines[1].starts[0].1.speed == 11080)
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
        var diagnosticMessages: [String] = []
        second.onDiagnostic = { diagnosticMessages.append($0) }
        do {
            try second.start(onDevice: "nonexistent-device", options: BurnOptions())
            Issue.record("An invalid device must never start")
        } catch {
            #expect(error.localizedDescription.contains("断开"))
        }
        #expect(diagnosticMessages.contains { $0.contains("输入 speed=0.000") && $0.contains("DRDeviceBurnSpeedMax") })
        #expect(diagnosticMessages.contains { $0.contains("轨道 1") && $0.contains("DRMaxBurnSpeedKey=") })
    }
}
