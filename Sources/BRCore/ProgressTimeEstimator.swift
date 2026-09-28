import Foundation

public enum ProgressTimeEstimate: Sendable, Equatable {
    case unavailable, learning, stalled, finishing
    case remaining(TimeInterval)

    public var title: String {
        switch self {
        case .unavailable: "暂无法估算"
        case .learning: "估算中…"
        case .stalled: "等待进度更新"
        case .finishing: "等待阶段完成"
        case .remaining(let seconds):
            if seconds < 5 {
                "少于 5 秒"
            } else {
                // Avoid presenting second-level precision for a fluctuating prediction.
                "约 \(BurnFormat.duration(ceil(seconds / roundingStep(seconds)) * roundingStep(seconds)))"
            }
        }
    }

    private func roundingStep(_ seconds: TimeInterval) -> TimeInterval {
        seconds < 60 ? 5 : seconds < 600 ? 10 : 60
    }
}

/// Estimates only the current operation; callers reset it when the phase or work unit changes.
public struct ProgressTimeEstimator: Sendable {
    private struct Reading: Sendable {
        let progress: Double
        let seconds: TimeInterval
    }

    private var readings: [Reading] = []
    private var latest: Reading?
    private var lastAdvanceAt: TimeInterval?
    private var smoothedRate: Double?
    private static let window: TimeInterval = 15
    private static let warmup: TimeInterval = 5
    private static let stallInterval: TimeInterval = 15

    public init() {}

    public mutating func update(progress: Double?, at seconds: TimeInterval) {
        guard let progress, progress.isFinite, (0...1).contains(progress), seconds.isFinite, seconds >= 0 else {
            self = Self()
            return
        }
        if let latest,
            progress < latest.progress || seconds < latest.seconds
                || (progress > latest.progress && seconds - (lastAdvanceAt ?? latest.seconds) >= Self.stallInterval)
        {
            self = Self()
        }
        if latest == nil || progress > (latest?.progress ?? 0) { lastAdvanceAt = seconds }
        let reading = Reading(progress: progress, seconds: seconds)
        latest = reading
        // Sample at most once a second, so notification frequency cannot bias the smoothing.
        let interval = seconds - (readings.last?.seconds ?? seconds)
        guard readings.isEmpty || interval >= 1 else { return }
        readings.append(reading)
        while readings.count > 1, readings[1].seconds <= seconds - Self.window { readings.removeFirst() }
        guard let first = readings.first, seconds - first.seconds >= Self.warmup else { return }
        let rate = (progress - first.progress) / (seconds - first.seconds)
        guard rate > 0 else { smoothedRate = nil; return }
        // The rolling 15-second rate rejects short bursts; an 8-second exponential smoother limits jumps.
        let weight = 1 - exp(-interval / 8)
        smoothedRate = smoothedRate.map { $0 + weight * (rate - $0) } ?? rate
    }

    public func estimate(at seconds: TimeInterval) -> ProgressTimeEstimate {
        // A SwiftUI timeline tick can precede a newly delivered progress notification.
        guard let latest, seconds.isFinite, seconds >= 0 else { return .unavailable }
        guard latest.progress < 1 else { return .finishing }
        if seconds - (lastAdvanceAt ?? latest.seconds) >= Self.stallInterval { return .stalled }
        guard let rate = smoothedRate, rate > 0 else { return .learning }
        let remaining = (1 - latest.progress) / rate
        guard remaining.isFinite, remaining < Double(Int.max) / 2 else { return .unavailable }
        return .remaining(remaining)
    }
}
