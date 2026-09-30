import Foundation

public enum BurnPhase: String, Sendable, Codable, CaseIterable {
    case idle, preparing, writing, finishing, verifying, completed, failed, cancelled

    public var title: String {
        switch self {
        case .idle: "等待开始"
        case .preparing: "准备刻录"
        case .writing: "正在写入"
        case .finishing: "正在结束写入"
        case .verifying: "正在回读校验"
        case .completed: "刻录完成"
        case .failed: "刻录失败"
        case .cancelled: "已取消"
        }
    }

    public var isActive: Bool { [.preparing, .writing, .finishing, .verifying].contains(self) }
}

public struct DiscDevice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let media: String
    public let present: Bool
    public let blank: Bool
    public let busy: Bool
    public let canWrite: Bool
    public let freeBlocks: UInt64
    public let speeds: [Double]
    public let baseSpeed: Double
    public let bufferCapacity: Int64?
    public let underrunProtection: Bool?
    public let vendor: String?
    public let product: String?
    public let firmware: String?
    public let interconnect: String?
    public let location: String?
    public let writableMedia: [String]
    public let mediaBSDName: String?
    public let mediaTrackCount: Int
    public let mediaSessionCount: Int

    public init(dictionary: [String: Any]) {
        id = dictionary["id"] as? String ?? ""
        name = dictionary["name"] as? String ?? "光盘驱动器"
        media = dictionary["media"] as? String ?? "未知介质"
        present = dictionary["present"] as? Bool ?? false
        blank = dictionary["blank"] as? Bool ?? false
        busy = dictionary["busy"] as? Bool ?? false
        canWrite = dictionary["canWrite"] as? Bool ?? false
        freeBlocks = (dictionary["freeBlocks"] as? NSNumber)?.uint64Value ?? 0
        speeds = Array(
            Set(
                (dictionary["speeds"] as? [NSNumber] ?? []).map(\.doubleValue)
                    .filter { $0.isFinite && $0 > 0 })
        ).sorted()
        baseSpeed = (dictionary["baseSpeed"] as? NSNumber)?.doubleValue ?? 1385
        let capacity = (dictionary["bufferCapacity"] as? NSNumber)?.int64Value
        bufferCapacity = capacity.flatMap { $0 > 0 ? $0 : nil }
        underrunProtection = dictionary["underrunProtection"] as? Bool
        vendor = Self.hardwareText(dictionary["vendor"])
        product = Self.hardwareText(dictionary["product"])
        firmware = Self.hardwareText(dictionary["firmware"])
        interconnect = Self.hardwareText(dictionary["interconnect"])
        location = Self.hardwareText(dictionary["location"])
        writableMedia = (dictionary["writableMedia"] as? [String] ?? []).compactMap(Self.hardwareText)
        mediaBSDName = Self.hardwareText(dictionary["mediaBSDName"])
        mediaTrackCount = (dictionary["mediaTrackCount"] as? NSNumber)?.intValue ?? 0
        mediaSessionCount = (dictionary["mediaSessionCount"] as? NSNumber)?.intValue ?? 0
    }

    private static func hardwareText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.caseInsensitiveCompare("Unknown") == .orderedSame ? nil : text
    }

    public var status: String {
        if busy { return "设备忙碌" }
        if !present { return "等待插入光盘" }
        return blank ? "空白光盘 · 可写入" : "光盘已有数据"
    }

    public func speedLabel(_ speed: Double) -> String {
        let factor = baseSpeed > 0 ? speed / baseSpeed : 0
        return String(format: "%.1f× · %.1f MB/s", factor, speed / 1000)
    }
}

public struct DiscImage: Sendable {
    public let url: URL
    public let fileBytes: Int64
    public let burnBytes: Int64
    public let blocks: UInt64
    public let tracks: Int

    public init(url: URL, dictionary: [String: Any]) {
        self.url = url
        fileBytes = (dictionary["fileBytes"] as? NSNumber)?.int64Value ?? 0
        burnBytes = (dictionary["burnBytes"] as? NSNumber)?.int64Value ?? 0
        blocks = (dictionary["blocks"] as? NSNumber)?.uint64Value ?? 0
        tracks = (dictionary["tracks"] as? NSNumber)?.intValue ?? 0
    }
}

public struct BurnOptions: Sendable, Equatable {
    public var speed: Double = 0
    public var finalize = true
    public var verify = true
    public var eject = true
    public init() {}
}

public struct BurnSnapshot: Sendable {
    public var phase: BurnPhase = .idle
    public var progress: Double?
    public var speedKB: Double?
    public var speedX: Double?
    public var rawState: String?
    /// Preserve the SDK's raw value; its public header does not specify a unit.
    public var currentSpeedRaw: String?
    public var track: Int?
    public var error: String?
    public var cancelling = false

    public init() {}

    public init(dictionary: [String: Any]) {
        phase = BurnPhase(rawValue: dictionary["phase"] as? String ?? "") ?? .preparing
        rawState = dictionary["rawState"] as? String
        currentSpeedRaw = dictionary["currentSpeedRaw"] as? String
        if let value = (dictionary["progress"] as? NSNumber)?.doubleValue, value.isFinite {
            progress = min(1, max(0, value))
        }
        if phase == .writing {
            if let value = (dictionary["speedKB"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 {
                speedKB = value
            }
            if let value = (dictionary["speedX"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 {
                speedX = value
            }
        }
        track = (dictionary["track"] as? NSNumber)?.intValue
        error = dictionary["error"] as? String
        if let detail = dictionary["errorDetail"] as? String {
            error = [error, detail].compactMap { $0 }.joined(separator: " · ")
        }
        cancelling = dictionary["cancelling"] as? Bool ?? false
        if phase == .completed { progress = 1 }
    }
}

public struct SpeedSample: Identifiable, Sendable {
    public let id = UUID()
    public let progress: Double
    public let megabytesPerSecond: Double
    public init(progress: Double, megabytesPerSecond: Double) {
        self.progress = progress
        self.megabytesPerSecond = megabytesPerSecond
    }
}

public struct SpeedHistory: Sendable {
    public private(set) var phase: BurnPhase = .writing
    public private(set) var progress: Double?
    public private(set) var samples: [SpeedSample] = []

    public init() {}

    public mutating func beginPhase(_ phase: BurnPhase) {
        guard phase == .writing || phase == .verifying, phase != self.phase else { return }
        self.phase = phase
        progress = nil
        samples = []
    }

    public mutating func record(progress: Double?, megabytesPerSecond: Double?) {
        guard let progress, progress.isFinite, (0...1).contains(progress) else { return }
        // A device can restart its progress for a new track. Never connect that reset backwards.
        if let previous = self.progress, progress < previous { samples = [] }
        self.progress = progress
        guard let megabytesPerSecond, megabytesPerSecond.isFinite, megabytesPerSecond >= 0 else { return }
        let sample = SpeedSample(progress: progress, megabytesPerSecond: megabytesPerSecond)
        // Keep the entire phase at 0.1% resolution, bounded even during hours of frequent updates.
        // Each retained point uses its actual reported progress, not the bucket boundary.
        if let last = samples.last, Int(last.progress * 1000) == Int(progress * 1000),
            samples.count > 1 || last.progress == progress
        {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
    }

    public mutating func record(_ measurement: VerificationSpeedMeasurement) {
        let speed = measurement.kilobytesPerSecond / 1000
        // The first average measures this whole interval, including its starting progress.
        if samples.isEmpty {
            record(progress: measurement.progressRange.lowerBound, megabytesPerSecond: speed)
        }
        record(progress: measurement.progressRange.upperBound, megabytesPerSecond: speed)
    }
}

public struct VerificationSpeedMeasurement: Sendable {
    public let progressRange: ClosedRange<Double>
    public let kilobytesPerSecond: Double
}

/// DiscRecording exposes write speed only. Estimate verification throughput from progress instead.
public struct VerificationSpeedEstimator: Sendable {
    public private(set) var kilobytesPerSecond: Double?
    private var baseline: (progress: Double, seconds: TimeInterval, track: Int?, bytes: Int64)?

    public init() {}

    @discardableResult
    public mutating func update(
        _ snapshot: BurnSnapshot, totalBytes: Int64, at seconds: TimeInterval
    ) -> VerificationSpeedMeasurement? {
        guard snapshot.phase == .verifying, !snapshot.cancelling,
            let progress = snapshot.progress, progress.isFinite, (0...1).contains(progress),
            totalBytes > 0, seconds.isFinite, seconds >= 0
        else {
            self = Self()
            return nil
        }
        let current = (progress: progress, seconds: seconds, track: snapshot.track, bytes: totalBytes)
        guard let baseline, baseline.track == snapshot.track, baseline.bytes == totalBytes,
            progress >= baseline.progress, seconds >= baseline.seconds
        else {
            self.baseline = current
            kilobytesPerSecond = nil
            return nil
        }
        // Accumulate at least one second so closely spaced notifications do not produce spikes.
        let interval = seconds - baseline.seconds
        guard interval >= 1 else { return nil }
        return measure(progress: progress, at: seconds)
    }

    /// A successful verification completes the last interval even if its final callback is under a second away.
    public mutating func finish(totalBytes: Int64, at seconds: TimeInterval) -> VerificationSpeedMeasurement? {
        guard let baseline, baseline.bytes == totalBytes, baseline.progress < 1,
            seconds.isFinite, seconds > baseline.seconds
        else { return nil }
        return measure(progress: 1, at: seconds)
    }

    private mutating func measure(progress: Double, at seconds: TimeInterval) -> VerificationSpeedMeasurement? {
        guard let baseline, seconds > baseline.seconds else { return nil }
        let speed = (progress - baseline.progress) * Double(baseline.bytes) / (seconds - baseline.seconds) / 1000
        guard speed.isFinite else { return nil }
        let measurement = VerificationSpeedMeasurement(
            progressRange: baseline.progress...progress, kilobytesPerSecond: speed)
        kilobytesPerSecond = speed
        self.baseline = (progress, seconds, baseline.track, baseline.bytes)
        return measurement
    }
}

public struct BurnLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let message: String
    var isSpeedSample = false
    public init(_ message: String) { self.message = message }
}

public enum BurnPreflight {
    public static func issue(image: DiscImage?, device: DiscDevice?, options: BurnOptions) -> String? {
        guard let image else { return "选择一个光盘镜像以开始。" }
        guard let device else { return "连接 USB 或内置光盘刻录机。" }
        guard device.canWrite else { return "所选光驱不支持刻录，请选择刻录机。" }
        guard !device.busy else { return "设备正忙，请稍后重试。" }
        guard device.present else { return "请插入空白可写光盘。" }
        guard device.blank else { return "光盘已有数据，请更换空白光盘。" }
        guard image.blocks > 0, device.freeBlocks >= image.blocks else { return "光盘容量不足，或设备尚未报告可用容量。" }
        guard options.speed == 0 || device.speeds.contains(options.speed) else { return "所选写入速度不可用，请重新选择。" }
        return nil
    }
}

public enum BurnFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    public static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
