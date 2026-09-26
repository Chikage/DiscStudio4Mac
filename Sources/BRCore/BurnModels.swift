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
    public let freeBlocks: UInt64
    public let speeds: [Double]
    public let baseSpeed: Double
    public let bufferCapacity: Int64?
    public let underrunProtection: Bool?

    public init(dictionary: [String: Any]) {
        id = dictionary["id"] as? String ?? ""
        name = dictionary["name"] as? String ?? "光盘驱动器"
        media = dictionary["media"] as? String ?? "未知介质"
        present = dictionary["present"] as? Bool ?? false
        blank = dictionary["blank"] as? Bool ?? false
        busy = dictionary["busy"] as? Bool ?? false
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

public struct BurnOptions: Sendable {
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
    public var track: Int?
    public var error: String?
    public var cancelling = false

    public init() {}

    public init(dictionary: [String: Any]) {
        phase = BurnPhase(rawValue: dictionary["phase"] as? String ?? "") ?? .preparing
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
    public let seconds: Double
    public let megabytesPerSecond: Double
    public init(seconds: Double, megabytesPerSecond: Double) {
        self.seconds = seconds
        self.megabytesPerSecond = megabytesPerSecond
    }
}

public struct BurnLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum BurnPreflight {
    public static func issue(image: DiscImage?, device: DiscDevice?, options: BurnOptions) -> String? {
        guard let image else { return "选择一个光盘镜像以开始。" }
        guard let device else { return "连接 USB 或内置光盘刻录机。" }
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
