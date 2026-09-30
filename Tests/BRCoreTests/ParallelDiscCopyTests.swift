import Foundation
import Testing

@testable import BRCore

private actor ControlledImageService: ImageFileServicing {
    enum Step: Sendable {
        case progress(UInt64)
        case finish, fail
    }
    struct Call: Sendable {
        let device: DiscDevice
        let format: DiscCopyFormat
        let destination: URL
    }
    private let channel = AsyncStream<Step>.makeStream()
    private(set) var calls: [Call] = []
    private(set) var cancellationObserved = false
    var delayCleanup = false
    private var cleanup: CheckedContinuation<Void, Never>?

    func holdCleanup() { delayCleanup = true }
    func finishCleanup() {
        cleanup?.resume()
        cleanup = nil
    }
    func send(_ step: Step) { channel.continuation.yield(step) }
    func build(
        sources: [URL], volumeName: String, fileSystem: DataDiscFileSystem, destination: URL,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws { throw ImageCreationError("Unexpected build") }

    func copyDisc(
        device: DiscDevice, format: DiscCopyFormat, destination: URL,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        calls.append(Call(device: device, format: format, destination: destination))
        await update(ImageUpdate(.copying, device.id, progress: 0, readBytes: 0, totalReadBytes: 100_000_000))
        for await step in channel.stream {
            switch step {
            case .progress(let bytes):
                await update(
                    ImageUpdate(
                        .copying, device.id, progress: Double(bytes) / 100_000_000,
                        readBytes: bytes, totalReadBytes: 100_000_000))
            case .finish: return
            case .fail: throw ImageCreationError("\(device.id) 读取失败")
            }
        }
        cancellationObserved = Task.isCancelled
        if delayCleanup { await withCheckedContinuation { cleanup = $0 } }
        try Task.checkCancellation()
    }
}

@MainActor
struct ParallelDiscCopyTests {
    private func device(_ id: String, label: String? = nil, node: String? = nil) -> DiscDevice {
        DiscDevice(dictionary: [
            "id": id, "name": "同型号光驱", "present": true, "blank": false,
            "mediaBSDName": node ?? "disk\(id == "A" ? 41 : id == "B" ? 42 : 43)",
            "volumeName": label ?? "光盘 \(id)", "mediaTrackCount": 1, "mediaSessionCount": 1,
        ])
    }

    private func setup(_ devices: [DiscDevice]? = nil) -> (BurnStore, [ControlledImageService]) {
        var services: [ControlledImageService] = []
        let store = BurnStore(
            makeEngine: { NativeBurnSessionEngine() },
            makeImageService: {
                let service = ControlledImageService()
                services.append(service)
                return service
            })
        store.updateDevices(devices ?? [device("A"), device("B"), device("C")])
        store.mode = .copyDisc
        return (store, Array(services.dropFirst()))
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for image task")
    }

    @Test func independentDrivesKeepFormatsProgressAndResultsWhileSelectionChanges() async throws {
        let (store, services) = setup()
        let first = store.sessions[0].discCopy
        let second = store.sessions[1].discCopy
        store.createImage(to: URL(fileURLWithPath: "/tmp/A.iso"))
        store.selectedDeviceID = "B"
        store.imageCreation.copyFormat = .dmg
        #expect(store.imageCreationIssue == nil)
        store.createImage(to: URL(fileURLWithPath: "/tmp/B.dmg"))
        #expect(store.activeDiscCopyCount == 2)
        await services[0].send(.progress(20_000_000))
        await services[1].send(.progress(70_000_000))
        try await waitFor { first.readBytes == 20_000_000 && second.readBytes == 70_000_000 }
        #expect(first.status.progress == 0.2 && second.status.progress == 0.7)
        #expect(await services[0].calls.first?.format == .iso)
        #expect(await services[1].calls.first?.format == .dmg)
        store.selectedDeviceID = "C"
        #expect(!store.imageCreation.isBusy && store.isBusy && store.isCreatingImage)
        #expect(store.canEditSelectedSession)
        store.selectedDeviceID = "A"
        #expect(!store.canEditSelectedSession && !store.canBurn)
        store.startDemo()
        #expect(!store.isDemo)
        store.mode = .buildISO
        store.createImage(to: URL(fileURLWithPath: "/tmp/blocked.iso"))
        #expect(!store.dataImageCreation.isBusy)
        await services[0].send(.finish)
        try await waitFor { first.status.phase == .completed }
        #expect(store.isBusy && store.activeDiscCopyCount == 1)
        await services[1].send(.fail)
        try await waitFor { !store.isBusy }
        #expect(first.outputURL?.lastPathComponent == "A.iso")
        #expect(second.status.phase == .failed && second.outputURL == nil)
        #expect(first.errorMessage == nil && second.errorMessage == "B 读取失败")
        #expect(!first.logs.contains { $0.message.contains("B.dmg") })
        #expect(first.readSpeedLabel() == "—" && second.readSpeedLabel() == "—")
    }

    @Test func cancellingOneDriveWaitsForItsCleanupAndLeavesTheOtherRunning() async throws {
        let (store, services) = setup()
        await services[0].holdCleanup()
        store.createImage(to: URL(fileURLWithPath: "/tmp/A.iso"))
        let request = try #require(store.discCopyRequest(for: store.sessions[1]))
        store.createDiscImage(request, to: URL(fileURLWithPath: "/tmp/B.iso"))
        let first = store.sessions[0].discCopy
        let second = store.sessions[1].discCopy
        try await waitFor { first.status.phase == .copying && second.status.phase == .copying }
        first.cancel()
        for _ in 0..<200 {
            if await services[0].cancellationObserved { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await services[0].cancellationObserved)
        #expect(first.isBusy && first.isCancelling && store.activeDiscCopyCount == 2)
        store.createImage(to: URL(fileURLWithPath: "/tmp/duplicate.iso"))
        #expect(await services[0].calls.count == 1)
        await services[1].send(.progress(50_000_000))
        try await waitFor { second.readBytes == 50_000_000 }
        #expect(!second.isCancelling)
        await services[0].finishCleanup()
        try await waitFor { first.status.phase == .cancelled }
        #expect(store.activeDiscCopyCount == 1 && store.isBusy)
        await services[1].send(.finish)
        try await waitFor { !store.isBusy }
    }

    @Test func saveRequestKeepsOriginalDriveAndFormatAndRejectsChangedMedia() async throws {
        let (store, services) = setup()
        let request = try #require(store.discCopyRequest(for: store.selectedSession))
        store.selectedSession.discCopy.copyFormat = .cdr
        store.selectedDeviceID = "B"
        store.createDiscImage(request, to: URL(fileURLWithPath: "/tmp/original.iso"))
        try await waitFor { store.sessions[0].discCopy.status.phase == .copying }
        #expect(await services[0].calls.first?.format == .iso)
        #expect(await services[1].calls.isEmpty)
        await services[0].send(.finish)
        try await waitFor { !store.isBusy }
        store.updateDevices([device("A", label: "另一张光盘"), device("B")])
        store.createDiscImage(request, to: URL(fileURLWithPath: "/tmp/stale.iso"))
        #expect(store.sessions[0].discCopy.errorMessage?.contains("已改变") == true)
        #expect(await services[0].calls.count == 1)
    }

    @Test func destinationsCannotBeSharedByActiveCopiesAndDisconnectKeepsHistory() async throws {
        let (store, services) = setup()
        let first = store.sessions[0]
        let secondRequest = try #require(store.discCopyRequest(for: store.sessions[1]))
        store.createImage(to: URL(fileURLWithPath: "/tmp/shared.iso"))
        store.createDiscImage(secondRequest, to: URL(fileURLWithPath: "/private/tmp/SHARED.iso"))
        #expect(store.sessions[1].discCopy.errorMessage?.contains("同一位置") == true)
        #expect(!store.sessions[1].discCopy.isBusy)
        store.createDiscImage(secondRequest, to: URL(fileURLWithPath: "/tmp/second.iso"))
        store.updateDevices([device("B")])
        #expect(store.sessions[0] === first && first.device == nil && first.discCopy.isBusy)
        await services[0].send(.fail)
        try await waitFor { first.discCopy.status.phase == .failed }
        #expect(store.sessions[1].discCopy.isBusy)
        store.updateDevices([device("A"), device("B")])
        #expect(store.sessions[0] === first && first.discCopy.errorMessage != nil)
        await services[1].send(.finish)
        try await waitFor { !store.isBusy }
    }

    @Test func batchUsesLabelsAndAddsSuffixesWithoutOverwritingExistingFiles() async throws {
        let (store, services) = setup([device("A", label: "照片 2026"), device("B", label: "照片 2026")])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiscStudio-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("照片 2026.iso")
        try Data("keep me".utf8).write(to: existing)
        let requests = store.readyDiscCopyRequests
        store.createDiscImages(requests + requests, in: root)
        #expect(store.activeDiscCopyCount == 2)
        #expect(
            store.sessions.map { $0.discCopy.destinationURL?.lastPathComponent } == [
                "照片 2026 (2).iso", "照片 2026 (3).iso",
            ])
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        await services[0].send(.finish)
        await services[1].send(.finish)
        try await waitFor { !store.isBusy }
        #expect(await services[0].calls.count == 1)
        #expect(await services[1].calls.count == 1)
    }
}

struct DiscCopyNamingAndSpeedTests {
    @Test func discLabelsProduceSafeUnicodeNamesAndFallbacks() {
        #expect(DiscImageName.fileName(label: "旅行 照片", format: .iso) == "旅行 照片.iso")
        #expect(DiscImageName.fileName(label: "Unknown", format: .cdr) == "Unknown.cdr")
        #expect(DiscImageName.fileName(label: " A/B:C\nD ", format: .dmg) == "A_B_C_D.dmg")
        for label in [nil, "", "  ", ".."] {
            #expect(DiscImageName.fileName(label: label, format: .iso) == "光盘副本.iso")
        }
        #expect(DiscImageName.fileName(label: String(repeating: "照片", count: 100), format: .iso).utf8.count <= 184)
        #expect(DiscDevice(dictionary: ["volumeName": "盘名"]).volumeName == "盘名")
    }

    @Test func speedMeasuresBytesWaitsForSamplesAndExpiresStaleValues() {
        var speed = DiscReadSpeedEstimator()
        speed.update(bytes: 0, total: 10_000_000, at: 10)
        speed.update(bytes: 1_000_000, total: 10_000_000, at: 10.2)
        #expect(speed.speed(at: 10.2) == nil)
        speed.update(bytes: 2_000_000, total: 10_000_000, at: 11)
        #expect(speed.speed(at: 11) == 2_000_000)
        #expect(speed.speed(at: 17) == nil)
        speed.update(bytes: 2_000_000, total: 10_000_000, at: 18)
        #expect(speed.speed(at: 18) == 0)
        speed.update(bytes: 1_000_000, total: 10_000_000, at: 19)
        #expect(speed.speed(at: 19) == nil)
        speed.update(bytes: 2_000_000, total: 20_000_000, at: 20)
        #expect(speed.speed(at: 20) == nil)
        speed.update(bytes: 3_000_000, total: 20_000_000, at: 19)
        #expect(speed.speed(at: 19) == nil)
    }

    @Test func shortReadCompletesFinalSpeedIntervalAndRejectsInvalidCounts() {
        var speed = DiscReadSpeedEstimator()
        speed.update(bytes: 0, total: 1_000_000, at: 1)
        speed.update(bytes: 1_000_000, total: 1_000_000, at: 1.5)
        #expect(speed.speed(at: 1.5) == 2_000_000)
        speed.update(bytes: 2, total: 1, at: 2)
        #expect(speed.speed(at: 2) == nil)
    }
}

@Suite(.serialized)
struct ConcurrentDiscImageIntegrationTests {
    @Test func separateRawDevicesCopyConcurrentlyWithExactBytesAndProgress() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("DiscStudio-concurrent-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let runner = ImageCommandRunner()
        var nodes: [String] = []
        var originals: [URL] = []
        do {
            for index in 0..<2 {
                let source = root.appendingPathComponent("payload\(index).bin")
                try Data(repeating: UInt8(index + 1), count: 8 * 1_048_576).write(to: source)
                let original = root.appendingPathComponent("original\(index).iso")
                try await ImageFileService().build(
                    sources: [source], volumeName: "Concurrent \(index)", fileSystem: .isoJoliet, destination: original
                ) { _ in }
                originals.append(original)
                let attachment = try await runner.run(
                    "/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nomount", "-plist", original.path])
                let start = try #require(attachment.range(of: Data("<?xml".utf8)))
                let plist =
                    try PropertyListSerialization.propertyList(from: attachment[start.lowerBound...], format: nil)
                    as? [String: Any]
                let entities = try #require(plist?["system-entities"] as? [[String: Any]])
                nodes.append(try #require(entities.compactMap { $0["dev-entry"] as? String }.first))
            }
            let devices = nodes.enumerated().map { index, node in
                DiscDevice(dictionary: [
                    "id": "virtual\(index)", "name": "Virtual \(index)", "present": true, "blank": false,
                    "mediaBSDName": URL(fileURLWithPath: node).lastPathComponent,
                    "mediaTrackCount": 1, "mediaSessionCount": 1,
                ])
            }
            let outputs = (0..<2).map { root.appendingPathComponent("copy\($0).iso") }
            let first = DiscCopyProgressRecorder()
            let second = DiscCopyProgressRecorder()
            async let a: Void = ImageFileService().copyDisc(device: devices[0], format: .iso, destination: outputs[0]) {
                await first.record($0)
            }
            async let b: Void = ImageFileService().copyDisc(device: devices[1], format: .iso, destination: outputs[1]) {
                await second.record($0)
            }
            _ = try await (a, b)
            for index in 0..<2 {
                #expect(try Data(contentsOf: outputs[index]) == Data(contentsOf: originals[index]))
                let updates = await (index == 0 ? first : second).values.filter { $0.readBytes != nil }
                #expect(updates.first?.readBytes == 0)
                #expect(updates.last?.progress == 1)
                #expect(updates.last?.readBytes == updates.last?.totalReadBytes)
                #expect(updates.contains { ($0.progress ?? 0) > 0 && ($0.progress ?? 1) < 1 })
            }
        } catch {
            for node in nodes { _ = try? await runner.run("/usr/bin/hdiutil", arguments: ["detach", node]) }
            throw error
        }
        for node in nodes { _ = try await runner.run("/usr/bin/hdiutil", arguments: ["detach", node]) }
        #expect(try files.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".DiscStudio-") })
    }
}

private actor DiscCopyProgressRecorder {
    private(set) var values: [ImageUpdate] = []
    func record(_ update: ImageUpdate) { values.append(update) }
}
