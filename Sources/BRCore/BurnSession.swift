import Foundation
import Observation

/// Immutable confirmation: the session, preparation generation and options must still match at start.
public struct BurnRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let deviceID: String
    public let deviceName: String
    public let imageURL: URL
    public let burnBytes: Int64
    public let options: BurnOptions
    let imageGeneration: Int
}

@MainActor @Observable
public final class BurnSession: Identifiable {
    public let id = UUID()
    public private(set) var deviceID = ""
    public private(set) var deviceName = "未选择设备"
    public private(set) var device: DiscDevice?
    public private(set) var image: DiscImage?
    public internal(set) var options = BurnOptions()
    public private(set) var snapshot = BurnSnapshot()
    public private(set) var speedHistory = SpeedHistory()
    public private(set) var verificationSpeed = VerificationSpeedEstimator()
    public private(set) var timeEstimator = ProgressTimeEstimator()
    public private(set) var logs: [BurnLogEntry] = []
    public private(set) var isLoadingImage = false
    public private(set) var isDemo = false
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public private(set) var lastStatusAt: Date?
    public private(set) var completedOptions = BurnOptions()
    public var errorMessage: String?

    @ObservationIgnored private let engine: any BurnSessionEngine
    @ObservationIgnored private var imageGeneration = 0
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    init(engine: any BurnSessionEngine) {
        self.engine = engine
        engine.onStatus = { [weak self] update in
            guard let self, self.isBusy else { return }
            self.receive(update)
        }
    }

    public var isBusy: Bool { snapshot.phase.isActive }
    public var preflightIssue: String? { BurnPreflight.issue(image: image, device: device, options: options) }
    public var canBurn: Bool { !isDemo && !isBusy && !isLoadingImage && preflightIssue == nil }
    public var burnRequest: BurnRequest? {
        guard canBurn, let image else { return nil }
        return BurnRequest(
            sessionID: id, deviceID: deviceID, deviceName: deviceName,
            imageURL: image.url, burnBytes: image.burnBytes, options: options, imageGeneration: imageGeneration)
    }

    func updateDevice(_ device: DiscDevice?) {
        self.device = device
        if let device {
            deviceID = device.id
            deviceName = device.name
        }
        if !isBusy, options.speed != 0, !(device?.speeds.contains(options.speed) ?? false) {
            options.speed = 0
        }
    }

    func selectImage(_ url: URL, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isBusy, !isDemo else {
            completion?(false)
            return
        }
        imageGeneration += 1
        let generation = imageGeneration
        let accessing = url.startAccessingSecurityScopedResource()
        isLoadingImage = true
        image = nil
        snapshot = BurnSnapshot()
        speedHistory = SpeedHistory()
        verificationSpeed = VerificationSpeedEstimator()
        timeEstimator = ProgressTimeEstimator()
        startedAt = nil
        finishedAt = nil
        lastStatusAt = nil
        errorMessage = nil
        engine.prepareImage(at: url) { [weak self] result in
            guard let self, generation == self.imageGeneration else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                completion?(false)
                return
            }
            self.isLoadingImage = false
            self.scopedURL?.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
            switch result {
            case .failure(let error):
                if accessing { url.stopAccessingSecurityScopedResource() }
                self.errorMessage = error.localizedDescription
                self.appendLog("镜像解析失败：\(error.localizedDescription)")
                completion?(false)
            case .success(let preparedImage):
                if accessing { self.scopedURL = url }
                self.image = preparedImage
                self.appendLog("镜像已载入：\(url.lastPathComponent)，\(self.image?.tracks ?? 0) 条轨道。")
                completion?(true)
            }
        }
    }

    func startBurn() {
        guard canBurn else {
            errorMessage = preflightIssue ?? "当前无法开始刻录。"
            return
        }
        resetSession()
        snapshot.phase = .preparing
        appendLog("开始刻录：\(image?.url.lastPathComponent ?? "") → \(deviceName)")
        appendLog("封盘：\(options.finalize ? "开启" : "保留追加能力")；回读校验：\(options.verify ? "开启" : "关闭")；欠载保护：已请求。")
        do {
            try engine.start(onDevice: deviceID, options: completedOptions)
        } catch {
            var failure = BurnSnapshot()
            failure.phase = .failed
            failure.error = error.localizedDescription
            receive(failure)
        }
    }

    public func cancel() {
        guard snapshot.phase.isActive, !snapshot.cancelling else { return }
        snapshot.cancelling = true
        appendLog("已请求停止，等待刻录引擎完成清理。")
        if isDemo {
            demoTask?.cancel()
            var cancelled = BurnSnapshot()
            cancelled.phase = .cancelled
            receive(cancelled)
        } else {
            engine.cancel()
        }
    }

    func eject() {
        guard !isBusy, !isDemo else { return }
        do { try engine.eject(deviceID) } catch { errorMessage = error.localizedDescription }
    }

    public func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }

    public func remainingTime(at date: Date) -> String {
        if snapshot.cancelling { return "正在停止" }
        switch snapshot.phase {
        case .writing, .verifying: return timeEstimator.estimate(at: elapsed(at: date)).title
        case .preparing, .finishing: return "暂无法估算"
        case .completed: return "已完成"
        case .idle, .failed, .cancelled: return "—"
        }
    }

    public var logText: String {
        let formatter = ISO8601DateFormatter()
        return
            (["Disc Studio 刻录日志\(isDemo ? " [演示数据]" : "")", "设备：\(deviceName) · \(deviceID)"]
            + logs.map {
                "[\(formatter.string(from: $0.date))] \($0.message)"
            }).joined(separator: "\n")
    }

    private func appendLog(_ message: String) {
        logs.append(BurnLogEntry(message))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    private func resetSession() {
        snapshot = BurnSnapshot()
        speedHistory = SpeedHistory()
        verificationSpeed = VerificationSpeedEstimator()
        timeEstimator = ProgressTimeEstimator()
        startedAt = Date()
        finishedAt = nil
        lastStatusAt = nil
        completedOptions = options
        errorMessage = nil
    }

    private func receive(_ update: BurnSnapshot) {
        let previous = snapshot.phase
        let now = Date()
        let seconds = elapsed(at: now)
        if previous == .verifying, update.phase == .completed,
            let measurement = verificationSpeed.finish(totalBytes: image?.burnBytes ?? 0, at: seconds)
        {
            speedHistory.record(measurement)
        }
        if previous != update.phase || snapshot.track != update.track {
            timeEstimator = ProgressTimeEstimator()
        }
        snapshot = update
        lastStatusAt = now
        if previous != update.phase { appendLog(update.phase.title) }
        speedHistory.beginPhase(update.phase)
        if let measurement = verificationSpeed.update(update, totalBytes: image?.burnBytes ?? 0, at: seconds) {
            speedHistory.record(measurement)
        }
        let speed = update.phase == .verifying ? verificationSpeed.kilobytesPerSecond : update.speedKB
        if update.phase == .writing || update.phase == .verifying {
            speedHistory.record(progress: update.progress, megabytesPerSecond: speed.map { $0 / 1000 })
            timeEstimator.update(progress: update.progress, at: seconds)
        }
        if !update.phase.isActive && update.phase != .idle {
            finishedAt = Date()
            if let error = update.error, update.phase == .failed {
                errorMessage = error
                appendLog(error)
            }
            if update.phase == .completed {
                appendLog(completedOptions.verify ? "写入与回读校验均已完成。" : "写入完成；本次未执行回读校验。")
                appendLog(completedOptions.finalize ? "已请求并完成封盘。" : "本次保留追加能力，实际取决于介质支持。")
            }
        }
    }

    /// This path never invokes DRBurn, even with physical drives connected.
    func startDemo(device: DiscDevice, imageName: String, offset: Int) {
        guard !isBusy, !isLoadingImage else { return }
        isDemo = true
        updateDevice(device)
        image = DiscImage(
            url: URL(fileURLWithPath: "/演示/" + imageName),
            dictionary: [
                "fileBytes": 3_221_225_472, "burnBytes": 3_221_225_472, "blocks": 1_572_864, "tracks": 1,
            ])
        options = BurnOptions()
        resetSession()
        appendLog("进入演示模式。所有数据均为模拟，不会写入任何设备。")
        snapshot.phase = .preparing
        demoTask = Task { [weak self] in
            for tick in 0...(90 + offset) {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let step = max(0, tick - offset)
                let phase: BurnPhase =
                    step < 5
                    ? .preparing : step < 65 ? .writing : step < 73 ? .finishing : step < 90 ? .verifying : .completed
                var update = BurnSnapshot()
                update.phase = phase
                update.progress =
                    phase == .writing
                    ? Double(step - 5) / 60
                    : phase == .verifying ? Double(step - 73) / 17 : phase == .completed ? 1 : nil
                if phase == .writing {
                    update.speedKB = 10100 + sin(Double(step) * 0.6) * 720
                    update.speedX = (update.speedKB ?? 0) / 1385
                }
                update.track = 1
                self.receive(update)
            }
        }
    }

    deinit {
        demoTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
