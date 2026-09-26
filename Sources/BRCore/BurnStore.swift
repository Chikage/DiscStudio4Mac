import DiscBridge
import Foundation
import Observation

@MainActor @Observable
public final class BurnStore {
    public private(set) var devices: [DiscDevice] = []
    public var selectedDeviceID: String = ""
    public private(set) var image: DiscImage?
    public var options = BurnOptions()
    public private(set) var snapshot = BurnSnapshot()
    public private(set) var speedHistory = SpeedHistory()
    public private(set) var verificationSpeed = VerificationSpeedEstimator()
    public private(set) var logs: [BurnLogEntry] = []
    public private(set) var isLoadingImage = false
    public private(set) var isDemo = false
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public private(set) var lastStatusAt: Date?
    public private(set) var completedOptions = BurnOptions()
    public var errorMessage: String?

    @ObservationIgnored private let engine = BRDiscEngine()
    @ObservationIgnored private var imageGeneration = 0
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var didStart = false

    public init() {}

    public var selectedDevice: DiscDevice? { devices.first { $0.id == selectedDeviceID } }
    public var isBusy: Bool { snapshot.phase.isActive }
    public var preflightIssue: String? { BurnPreflight.issue(image: image, device: selectedDevice, options: options) }
    public var canBurn: Bool { !isDemo && !isBusy && !isLoadingImage && preflightIssue == nil }

    public func connect() {
        guard !didStart else { return }
        didStart = true
        // The Objective-C adapter guarantees main-run-loop callbacks; no legacy object crosses actors.
        engine.onDevices = { [weak self] values in
            let devices = values.map(DiscDevice.init(dictionary:))
            MainActor.assumeIsolated {
                guard let self, !self.isDemo else { return }
                self.devices = devices
                if !self.isBusy && !self.devices.contains(where: { $0.id == self.selectedDeviceID }) {
                    self.selectedDeviceID = self.devices.first?.id ?? ""
                }
                if !self.isBusy, self.options.speed != 0,
                    !(self.selectedDevice?.speeds.contains(self.options.speed) ?? false)
                {
                    self.options.speed = 0
                }
            }
        }
        engine.onStatus = { [weak self] dictionary in
            let snapshot = BurnSnapshot(dictionary: dictionary)
            MainActor.assumeIsolated { self?.receive(snapshot) }
        }
        engine.observeDevices()
        appendLog("Disc Studio 已就绪，等待选择镜像与刻录设备。")
    }

    public func refreshDevices() { if !isDemo { engine.refreshDevices() } }

    public func selectImage(_ url: URL) {
        guard !isBusy, !isDemo else { return }
        imageGeneration += 1
        let generation = imageGeneration
        let accessing = url.startAccessingSecurityScopedResource()
        isLoadingImage = true
        image = nil
        snapshot = BurnSnapshot()
        speedHistory = SpeedHistory()
        verificationSpeed = VerificationSpeedEstimator()
        startedAt = nil
        finishedAt = nil
        lastStatusAt = nil
        errorMessage = nil
        engine.prepareImage(at: url) { [weak self] dictionary, error in
            let preparedImage = dictionary.map { DiscImage(url: url, dictionary: $0) }
            MainActor.assumeIsolated {
                guard let self, generation == self.imageGeneration else {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    return
                }
                self.isLoadingImage = false
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = nil
                if let error {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    self.errorMessage = error.localizedDescription
                    self.appendLog("镜像解析失败：\(error.localizedDescription)")
                } else if let preparedImage {
                    if accessing { self.scopedURL = url }
                    self.image = preparedImage
                    self.appendLog("镜像已载入：\(url.lastPathComponent)，\(self.image?.tracks ?? 0) 条轨道。")
                }
            }
        }
    }

    public func startBurn() {
        guard canBurn else {
            errorMessage = preflightIssue ?? "当前无法开始刻录。"
            return
        }
        resetSession()
        snapshot.phase = .preparing
        appendLog("开始刻录：\(image?.url.lastPathComponent ?? "") → \(selectedDevice?.name ?? "")")
        appendLog("封盘：\(options.finalize ? "开启" : "保留追加能力")；回读校验：\(options.verify ? "开启" : "关闭")；欠载保护：已请求。")
        do {
            try engine.start(
                onDevice: selectedDeviceID, speed: options.speed,
                finalize: options.finalize, verify: options.verify, eject: options.eject)
        } catch {
            var failure = BurnSnapshot()
            failure.phase = .failed
            failure.error = error.localizedDescription
            receive(failure)
        }
    }

    public func cancel() {
        guard isBusy, !snapshot.cancelling else { return }
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

    public func eject() {
        guard !isBusy, !isDemo else { return }
        do { try engine.ejectDevice(selectedDeviceID) } catch { errorMessage = error.localizedDescription }
    }

    public func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }

    public var logText: String {
        let formatter = ISO8601DateFormatter()
        return
            (["Disc Studio 刻录日志\(isDemo ? " [演示数据]" : "")"]
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
        startedAt = Date()
        finishedAt = nil
        lastStatusAt = nil
        completedOptions = options
        errorMessage = nil
    }

    private func receive(_ update: BurnSnapshot) {
        let previous = snapshot.phase
        snapshot = update
        let now = Date()
        lastStatusAt = now
        if previous != update.phase { appendLog(update.phase.title) }
        let seconds = elapsed(at: now)
        speedHistory.beginPhase(update.phase)
        verificationSpeed.update(update, totalBytes: image?.burnBytes ?? 0, at: seconds)
        let speed = update.phase == .verifying ? verificationSpeed.kilobytesPerSecond : update.speedKB
        if let speed {
            speedHistory.append(SpeedSample(seconds: seconds, megabytesPerSecond: speed / 1000))
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
    public func startDemo() {
        guard !isBusy, !isLoadingImage else { return }
        isDemo = true
        image = DiscImage(
            url: URL(fileURLWithPath: "/演示/Archive-2026.iso"),
            dictionary: [
                "fileBytes": 3_221_225_472, "burnBytes": 3_221_225_472, "blocks": 1_572_864, "tracks": 1,
            ])
        devices = [
            DiscDevice(dictionary: [
                "id": "demo", "name": "演示刻录机", "media": "DVD-R",
                "present": true, "blank": true, "busy": false, "freeBlocks": 2_298_496,
                "speeds": [5540.0, 11080.0], "baseSpeed": 1385.0,
                "bufferCapacity": 2_097_152, "underrunProtection": true,
            ])
        ]
        selectedDeviceID = "demo"
        options = BurnOptions()
        resetSession()
        appendLog("进入演示模式。所有数据均为模拟，不会写入任何设备。")
        snapshot.phase = .preparing
        demoTask = Task { [weak self] in
            for step in 0...90 {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard let self, !Task.isCancelled else { return }
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

    public func exitDemo() {
        guard isDemo, !isBusy else { return }
        demoTask = nil
        isDemo = false
        image = nil
        snapshot = BurnSnapshot()
        speedHistory = SpeedHistory()
        verificationSpeed = VerificationSpeedEstimator()
        logs = []
        startedAt = nil
        finishedAt = nil
        lastStatusAt = nil
        selectedDeviceID = ""
        engine.refreshDevices()
        appendLog("已返回真实设备模式。")
    }
}
