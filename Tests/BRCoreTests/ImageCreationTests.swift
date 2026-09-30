import Foundation
import Testing

@testable import BRCore

struct ImageCreationTests {
    @Test func copyRequiresReadableNonblankSingleSessionMedia() {
        let ready: [String: Any] = [
            "id": "drive", "present": true, "blank": false, "busy": false,
            "mediaBSDName": "disk42", "mediaTrackCount": 1, "mediaSessionCount": 1,
        ]
        #expect(ImagePreflight.copyIssue(device: DiscDevice(dictionary: ready)) == nil)
        #expect(ImagePreflight.copyIssue(device: nil) != nil)
        for change: [String: Any] in [
            ["present": false], ["blank": true], ["busy": true],
            ["mediaBSDName": ""], ["mediaTrackCount": 2], ["mediaSessionCount": 2],
        ] {
            #expect(
                ImagePreflight.copyIssue(device: DiscDevice(dictionary: ready.merging(change) { _, b in b })) != nil)
        }
    }

    @Test func sourceReadFailureReportsDeviceProblemInsteadOfSaveFailure() {
        let source = URL(fileURLWithPath: "/dev/rdisk8")
        for (code, message) in [
            (POSIXErrorCode.EBUSY, "占用"), (.EACCES, "权限"), (.EIO, "I/O"), (.ENXIO, "不可用"),
        ] {
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
            let cocoa = NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSUnderlyingErrorKey: underlying, NSFilePathErrorKey: "/dev/disk8"])
            let error = DiscSourceReadError(source: source, underlyingError: cocoa)
            #expect(error.localizedDescription.contains("无法读取来源光盘"))
            #expect(error.localizedDescription.contains(source.path))
            #expect(error.localizedDescription.contains(message))
            #expect(!error.localizedDescription.contains("保存"))
        }
    }

    @Test func copyRejectsDevicePathsThatAreNotWholeDiscBSDNames() async {
        for name in ["rdisk8", "disk8s1", "/dev/disk8", "disk8/other", "../disk8"] {
            let device = DiscDevice(dictionary: [
                "id": "invalid", "present": true, "blank": false, "mediaBSDName": name,
            ])
            do {
                try await ImageFileService().copyDisc(
                    device: device, format: .iso, destination: URL(fileURLWithPath: "/unused.iso")
                ) { _ in }
                Issue.record("Invalid device name unexpectedly accepted")
            } catch {
                #expect(error.localizedDescription.contains("有效的完整光盘设备地址"))
            }
        }
    }

    @Test func rejectsOverlappingDestinationsAndRootNameCollisions() throws {
        let a = URL(fileURLWithPath: "/tmp/example/content")
        let b = URL(fileURLWithPath: "/tmp/another/CONTENT")
        #expect(throws: ImageCreationError.self) {
            try ImagePreflight.validateSelection([a, b], destination: URL(fileURLWithPath: "/tmp/out.iso"))
        }
        for destination in [a, a.appendingPathComponent("out.iso")] {
            #expect(throws: ImageCreationError.self) {
                try ImagePreflight.validateSelection([a], destination: destination)
            }
        }
        try ImagePreflight.validateSelection([a], destination: URL(fileURLWithPath: "/tmp/example/content2/out.iso"))
        #expect(ImagePreflight.volumeNameIssue("照片 2026") == nil)
        for name in [" ", "bad/name", "bad:name", "bad\nname", String(repeating: "a", count: 33)] {
            #expect(ImagePreflight.volumeNameIssue(name) != nil)
        }
    }

    @Test func progressParsingPreservesIndeterminateAndRejectsNoise() {
        #expect(ImageCommandRunner.percentage("PERCENT:12.5") == 0.125)
        #expect(ImageCommandRunner.percentage("PERCENT: -1.000000") == -1)
        #expect(ImageCommandRunner.percentage("PERCENT:100.0") == 1)
        #expect(ImageCommandRunner.percentage("PERCENT:nan") == nil)
        #expect(ImageCommandRunner.percentage("created: /tmp/100.iso") == nil)
    }

    @Test func constructionEstimateUsesSectorsAndWaitsForProcessSuccess() throws {
        let estimate = try #require(ImageSizeEstimate(output: Data("notice\n262321 (0x000000000400b1) sectors\n".utf8)))
        #expect(estimate.bytes == 537_233_408)
        #expect(estimate.progress(writtenBytes: 0) == 0)
        #expect(estimate.progress(writtenBytes: estimate.bytes / 2) == 0.5)
        #expect(estimate.progress(writtenBytes: estimate.bytes) == 0.99)
        #expect(estimate.progress(writtenBytes: .max) == 0.99)
        for output in ["not a size", "0 (0x0) sectors", "9223372036854775807 (0x7fffffffffffffff) sectors"] {
            #expect(ImageSizeEstimate(output: Data(output.utf8)) == nil)
        }
    }

    @Test func commandProgressIncludesFinalUnterminatedOutput() async throws {
        let recorder = ImageUpdateRecorder()
        _ = try await ImageCommandRunner().run(
            "/usr/bin/printf", arguments: ["PERCENT:10\rPERCENT:42"]
        ) { progress in
            await recorder.record(ImageUpdate(.building, "Compression", progress: progress))
        }
        #expect(await recorder.values.map(\.progress) == [0.1, 0.42])
    }

    @Test func processCancellationWaitsForExit() async throws {
        let runner = ImageCommandRunner()
        let task = Task { try await runner.run("/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(250))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled command unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @MainActor @Test func imageTaskLocksItsOwnInputsAndDemoEntry() async throws {
        let store = BurnStore()
        let job = store.imageCreation
        job.addSources([URL(fileURLWithPath: "/nonexistent/source")])
        store.mode = .buildISO
        store.createImage(to: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).iso"))
        #expect(store.isBusy)
        #expect(store.canEditSelectedSession)
        #expect(!store.canBurn)
        store.startDemo()
        #expect(!store.isDemo)
        job.clearSources()
        #expect(job.sources.count == 1)
        job.cancel()
        while job.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isBusy)
        #expect(job.outputURL == nil)
    }
}

@Suite(.serialized)
struct ImageFileIntegrationTests {
    private let files = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent("DiscStudio-test-\(UUID())", isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func buildingReportsByteProgressThenEstimatedImageProgress() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("large.bin")
        try Data(repeating: 0xA5, count: 10 * 1_048_576).write(to: source)
        let recorder = ImageUpdateRecorder()
        try await ImageFileService().build(
            sources: [source], volumeName: "Progress", fileSystem: .isoJoliet,
            destination: root.appendingPathComponent("result.iso")
        ) { await recorder.record($0) }
        let updates = await recorder.values
        let staging = updates.filter { $0.phase == .copying }
        #expect(staging.first?.progress == 0)
        #expect(staging.contains { $0.progress == 0.1 })
        #expect(staging.last?.progress == 1)
        #expect(staging.allSatisfy { !$0.isProgressEstimated })
        let building = updates.filter { $0.phase == .building && $0.progress != nil }
        #expect(!building.isEmpty)
        #expect(building.allSatisfy { $0.isProgressEstimated && (0...0.99).contains($0.progress ?? -1) })
        #expect(building.contains { ($0.progress ?? 0) > 0 && $0.detail.contains("预计") })
        #expect(updates.last?.phase == .finishing)
    }

    @Test func zeroByteSelectionFinishesStagingWithoutInvalidProgress() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("empty folder")
        try files.createDirectory(at: source, withIntermediateDirectories: false)
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        let recorder = ImageUpdateRecorder()
        try await ImageFileService().build(
            sources: [source], volumeName: "Empty", fileSystem: .udf,
            destination: root.appendingPathComponent("empty.iso")
        ) { await recorder.record($0) }
        let updates = await recorder.values
        #expect(updates.filter { $0.phase == .copying }.last?.progress == 1)
        #expect(updates.compactMap(\.progress).allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    @Test func generatedISOAndUDFMountWithExactFileContents() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent("资料 folder")
        try files.createDirectory(at: folder.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("中文 notes.txt")
        let payload = Data("镜像内容 test\n".utf8)
        try payload.write(to: note)
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
        let binary = root.appendingPathComponent("random.bin")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: binary)
        let runner = ImageCommandRunner()
        for system in DataDiscFileSystem.allCases {
            let output = root.appendingPathComponent("archive-\(system.rawValue).iso")
            // Exercise successful replacement of an existing destination too.
            try Data("old image".utf8).write(to: output)
            try await ImageFileService().build(
                sources: [folder, binary], volumeName: "测试光盘", fileSystem: system, destination: output
            ) { _ in }
            #expect(try ImageFileService.hasDataDiscSignature(output))
            let mount = root.appendingPathComponent("mount-\(system.rawValue)")
            try files.createDirectory(at: mount, withIntermediateDirectories: false)
            _ = try await runner.run(
                "/usr/bin/hdiutil",
                arguments: [
                    "attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, output.path,
                ])
            do {
                #expect(try Data(contentsOf: mount.appendingPathComponent("资料 folder/中文 notes.txt")) == payload)
                #expect(try Data(contentsOf: mount.appendingPathComponent("random.bin")) == bytes)
                #expect(try Data(contentsOf: mount.appendingPathComponent("资料 folder/.hidden")) == Data("hidden".utf8))
                #expect(files.fileExists(atPath: mount.appendingPathComponent("资料 folder/空目录").path))
                _ = try await runner.run("/usr/bin/hdiutil", arguments: ["detach", mount.path])
            } catch {
                _ = try? await runner.run("/usr/bin/hdiutil", arguments: ["detach", mount.path])
                throw error
            }
            #expect(try files.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".DiscStudio-") })
        }
    }

    @Test(arguments: [false, true])
    func copiesVirtualDataDiscToAllSupportedFormats(mounted: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("payload.txt")
        let payload = Data("Disc copy sector fixture\n".utf8)
        try payload.write(to: source)
        let original = root.appendingPathComponent("original.iso")
        let service = ImageFileService()
        try await service.build(
            sources: [source], volumeName: "Copy Test", fileSystem: .isoJoliet, destination: original
        ) { _ in }
        let runner = ImageCommandRunner()
        let sourceMount = root.appendingPathComponent("source-mount")
        try files.createDirectory(at: sourceMount, withIntermediateDirectories: false)
        let mountArguments = mounted ? ["-nobrowse", "-mountpoint", sourceMount.path] : ["-nomount"]
        let attachment = try await runner.run(
            "/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-plist"] + mountArguments + [original.path])
        // New macOS versions prepend a deprecation notice before the property list.
        let xmlStart = try #require(attachment.range(of: Data("<?xml".utf8)))
        let plist =
            try PropertyListSerialization.propertyList(from: attachment[xmlStart.lowerBound...], format: nil)
            as? [String: Any]
        let entities = try #require(plist?["system-entities"] as? [[String: Any]])
        let node = try #require(entities.compactMap { $0["dev-entry"] as? String }.first)
        let diskInfoData = try await runner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", node])
        let diskInfo = try PropertyListSerialization.propertyList(from: diskInfoData, format: nil) as? [String: Any]
        let deviceBytes = try #require(diskInfo?["TotalSize"] as? Int)
        let device = DiscDevice(dictionary: [
            "id": "virtual-fixture", "name": "Virtual Data Disc", "present": true, "blank": false,
            "mediaBSDName": URL(fileURLWithPath: node).lastPathComponent, "mediaTrackCount": 1, "mediaSessionCount": 1,
        ])
        do {
            for format in DiscCopyFormat.allCases {
                let output = root.appendingPathComponent("copy.\(format.rawValue)")
                try await service.copyDisc(device: device, format: format, destination: output) { _ in }
                if format != .dmg {
                    // Preserve every device sector, including the original trailing CD padding.
                    let copied = try Data(contentsOf: output)
                    #expect(copied.count == deviceBytes)
                    #expect(try copied == Data(contentsOf: original).prefix(deviceBytes))
                }
                let mount = root.appendingPathComponent("copy-mount-\(format.rawValue)")
                try files.createDirectory(at: mount, withIntermediateDirectories: false)
                _ = try await runner.run(
                    "/usr/bin/hdiutil",
                    arguments: ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, output.path])
                do {
                    #expect(try Data(contentsOf: mount.appendingPathComponent("payload.txt")) == payload)
                    _ = try await runner.run("/usr/bin/hdiutil", arguments: ["detach", mount.path])
                } catch {
                    _ = try? await runner.run("/usr/bin/hdiutil", arguments: ["detach", mount.path])
                    throw error
                }
                if mounted {
                    #expect(try Data(contentsOf: sourceMount.appendingPathComponent("payload.txt")) == payload)
                }
            }
            try await checkCancelledDiscCopy(device: device, root: root)
            _ = try await runner.run("/usr/bin/hdiutil", arguments: ["detach", node])
        } catch {
            _ = try? await runner.run("/usr/bin/hdiutil", arguments: ["detach", node])
            throw error
        }
        #expect(try files.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".DiscStudio-") })
    }

    // Explicitly opt in to a read-only hardware check; normal test runs use virtual discs only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BR_TEST_OPTICAL_DEVICE"] != nil))
    func mountedPhysicalDiscReadsSectorsAndCancelsCleanly() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["BR_TEST_OPTICAL_DEVICE"])
        #expect(name.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil)
        let runner = ImageCommandRunner()
        let infoData = try await runner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/\(name)"])
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        _ = try #require(info?["OpticalMediaType"] as? String)
        let mount = try #require(info?["MountPoint"] as? String)
        #expect(!mount.isEmpty)
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let device = DiscDevice(dictionary: [
            "id": "optical-hardware", "name": "Optical Hardware Test", "present": true, "blank": false,
            "mediaBSDName": name, "mediaTrackCount": 1, "mediaSessionCount": 1,
        ])
        try await checkCancelledDiscCopy(device: device, root: root)
        let afterData = try await runner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/\(name)"])
        let after = try PropertyListSerialization.propertyList(from: afterData, format: nil) as? [String: Any]
        #expect(after?["MountPoint"] as? String == mount)
    }

    private func checkCancelledDiscCopy(device: DiscDevice, root: URL) async throws {
        let output = root.appendingPathComponent("cancelled.iso")
        let original = Data("preserve existing image".utf8)
        try original.write(to: output)
        let recorder = ImageUpdateRecorder()
        let task = Task {
            try await ImageFileService().copyDisc(device: device, format: .iso, destination: output) {
                await recorder.record($0)
                if $0.phase == .copying, ($0.progress ?? 0) > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            try await task.value
            Issue.record("Cancelled disc copy unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        let updates = await recorder.values
        #expect(updates.contains { $0.phase == .copying && ($0.progress ?? 0) > 0 })
        #expect(!updates.contains { $0.phase == .finishing })
        #expect(try Data(contentsOf: output) == original)
        #expect(try files.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".DiscStudio-") })
    }

    @Test func failurePreservesExistingOutputAndCleansStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.iso")
        let original = Data("preserve me".utf8)
        try original.write(to: output)
        let source = root.appendingPathComponent("missing")
        do {
            try await ImageFileService().build(
                sources: [source], volumeName: "Test", fileSystem: .isoJoliet, destination: output
            ) { _ in }
            Issue.record("Missing source unexpectedly succeeded")
        } catch {
            #expect(try Data(contentsOf: output) == original)
            #expect(try files.contentsOfDirectory(atPath: root.path) == ["existing.iso"])
        }
    }

    @Test func oversizedFilesAndSymbolicLinksAreNotSilentlyOmitted() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let large = root.appendingPathComponent("large.bin")
        #expect(files.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 4_294_967_296)
        try handle.close()
        let output = root.appendingPathComponent("archive.iso")
        do {
            try await ImageFileService().build(
                sources: [large], volumeName: "Test", fileSystem: .isoJoliet, destination: output
            ) { _ in }
            Issue.record("Joliet accepted an oversized file")
        } catch {
            #expect(error.localizedDescription.contains("UDF"))
            #expect(!files.fileExists(atPath: output.path))
        }
        let link = root.appendingPathComponent("link")
        try files.createSymbolicLink(at: link, withDestinationURL: large)
        do {
            try await ImageFileService().build(
                sources: [link], volumeName: "Test", fileSystem: .udf, destination: output
            ) { _ in }
            Issue.record("Symbolic link unexpectedly accepted")
        } catch {
            #expect(error.localizedDescription.contains("符号链接"))
        }
    }

    @Test func cancelledBuildLeavesNoPartialImageOrStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("content".utf8).write(to: source)
        let output = root.appendingPathComponent("archive.iso")
        let (stream, continuation) = AsyncStream<ImageUpdate>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            try await ImageFileService().build(
                sources: [source], volumeName: "Test", fileSystem: .isoJoliet, destination: output
            ) {
                continuation.yield($0)
            }
        }
        for await update in stream where update.phase == .copying {
            task.cancel()
            break
        }
        do {
            try await task.value
            Issue.record("Cancelled image unexpectedly succeeded")
        } catch { #expect(error is CancellationError) }
        #expect(!files.fileExists(atPath: output.path))
        #expect(try files.contentsOfDirectory(atPath: root.path) == ["source.txt"])
    }
}

private actor ImageUpdateRecorder {
    private(set) var values: [ImageUpdate] = []
    func record(_ update: ImageUpdate) { values.append(update) }
}
