import Foundation
import Observation

@MainActor @Observable
public final class ImageCreationStore {
    public private(set) var sources: [URL] = []
    public var volumeName = "Data Disc"
    public var fileSystem = DataDiscFileSystem.isoJoliet
    public var copyFormat = DiscCopyFormat.iso
    public private(set) var status = ImageUpdate(.idle, "选择来源并设置保存位置后开始。")
    public private(set) var outputURL: URL?
    public private(set) var destinationURL: URL?
    public private(set) var copySource: DiscDevice?
    public private(set) var readBytes: UInt64?
    public private(set) var totalReadBytes: UInt64?
    public private(set) var isCancelling = false
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public private(set) var timeEstimator = ProgressTimeEstimator()
    public private(set) var logs: [BurnLogEntry] = []
    public var errorMessage: String?
    private var readSpeed = DiscReadSpeedEstimator()
    @ObservationIgnored private let service: any ImageFileServicing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    public convenience init() { self.init(service: ImageFileService()) }
    init(service: any ImageFileServicing) { self.service = service }
    public var isBusy: Bool { status.phase.isActive }
    public var buildIssue: String? {
        sources.isEmpty ? "添加需要放入数据光盘的文件或文件夹。" : ImagePreflight.volumeNameIssue(volumeName)
    }

    public func addSources(_ urls: [URL]) {
        guard !isBusy else { return }
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            if !sources.contains(normalized) { sources.append(normalized) }
        }
    }

    public func removeSource(_ url: URL) {
        guard !isBusy else { return }
        sources.removeAll { $0 == url }
    }

    public func clearSources() {
        guard !isBusy else { return }
        sources = []
    }

    public func build(to destination: URL) {
        guard !isBusy else { return }
        if let buildIssue {
            errorMessage = buildIssue
            return
        }
        let sources = sources
        let name = volumeName
        let system = fileSystem
        copySource = nil
        begin(destination: destination, scopedSources: sources) { service, update in
            try await service.build(
                sources: sources, volumeName: name, fileSystem: system, destination: destination, update: update)
        }
    }

    public func copyDisc(_ device: DiscDevice, to destination: URL, format: DiscCopyFormat? = nil) {
        guard !isBusy else { return }
        if let issue = ImagePreflight.copyIssue(device: device) {
            errorMessage = issue
            return
        }
        let format = format ?? copyFormat
        copySource = device
        begin(destination: destination, scopedSources: []) { service, update in
            try await service.copyDisc(device: device, format: format, destination: destination, update: update)
        }
    }

    private func begin(
        destination: URL, scopedSources: [URL],
        operation:
            @escaping @Sendable (any ImageFileServicing, @Sendable (ImageUpdate) async -> Void) async throws -> Void
    ) {
        outputURL = nil
        destinationURL = destination
        readBytes = nil
        totalReadBytes = nil
        readSpeed = DiscReadSpeedEstimator()
        errorMessage = nil
        isCancelling = false
        startedAt = .now
        finishedAt = nil
        timeEstimator = ProgressTimeEstimator()
        logs = []
        receive(ImageUpdate(.preparing, "准备创建：\(destination.lastPathComponent)"))
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "创建光盘镜像")
        let scopedURLs = (scopedSources + [destination]).filter { $0.startAccessingSecurityScopedResource() }
        task = Task {
            defer {
                for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                activity = nil
                finishedAt = .now
                isCancelling = false
                task = nil
            }
            do {
                try await operation(service) { [weak self] update in await self?.receive(update) }
                outputURL = destination
                receive(ImageUpdate(.completed, "已保存：\(destination.path)", progress: 1))
            } catch is CancellationError {
                receive(ImageUpdate(.cancelled, "任务已停止，临时文件已清理。"))
            } catch {
                errorMessage = error.localizedDescription
                receive(ImageUpdate(.failed, error.localizedDescription))
            }
        }
    }

    public func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        task?.cancel()
    }

    private func receive(_ update: ImageUpdate) {
        if update.phase == .copying, let bytes = update.readBytes, let total = update.totalReadBytes {
            readBytes = bytes
            totalReadBytes = total
            readSpeed.update(bytes: bytes, total: total, at: ProcessInfo.processInfo.systemUptime)
        } else {
            readSpeed = DiscReadSpeedEstimator()
        }
        if status.phase != update.phase || status.isProgressEstimated != update.isProgressEstimated {
            timeEstimator = ProgressTimeEstimator()
        }
        timeEstimator.update(progress: update.progress, at: elapsed(at: .now))
        if status.phase != update.phase || (update.progress == nil && status.detail != update.detail) {
            logs.append(BurnLogEntry(update.detail))
            if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        }
        status = update
    }

    public func readSpeedLabel(at seconds: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        guard status.phase == .copying, !isCancelling else { return "—" }
        guard let speed = readSpeed.speed(at: seconds) else { return "等待读数" }
        return String(format: "%.1f MB/s", speed / 1_000_000)
    }

    public func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }

    public func remainingTime(at date: Date) -> String {
        if isCancelling { return "正在停止" }
        switch status.phase {
        case .preparing, .copying, .building, .finishing:
            return timeEstimator.estimate(at: elapsed(at: date)).title
        case .completed: return "已完成"
        case .idle, .failed, .cancelled: return "—"
        }
    }
}
