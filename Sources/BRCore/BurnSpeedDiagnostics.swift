import Foundation

/// Samples existing callbacks only; never polls the drive or changes its write speed.
struct BurnSpeedDiagnostics {
    private var lastReportAt: TimeInterval?
    private var lastTrack: Int?
    private var pending: (snapshot: BurnSnapshot, seconds: TimeInterval)?
    private var minimumKB: Double?
    private var maximumKB: Double?
    private var count = 0

    mutating func record(_ snapshot: BurnSnapshot, at seconds: TimeInterval) -> [String] {
        var messages: [String] = []
        if snapshot.phase != .writing || (lastReportAt != nil && snapshot.track != lastTrack) {
            if let message = flush() { messages.append(message) }
            self = Self()
        }
        guard snapshot.phase == .writing else { return messages }
        pending = (snapshot, seconds)
        lastTrack = snapshot.track
        count += 1
        if let speed = snapshot.speedKB, speed.isFinite, speed >= 0 {
            minimumKB = min(minimumKB ?? speed, speed)
            maximumKB = max(maximumKB ?? speed, speed)
        }
        if lastReportAt == nil || seconds - (lastReportAt ?? seconds) >= 15 {
            if let message = flush() { messages.append(message) }
            lastReportAt = seconds
        }
        return messages
    }

    private mutating func flush() -> String? {
        guard let pending else { return nil }
        let snapshot = pending.snapshot
        let progress = snapshot.progress.map { String(format: "%.2f%%", $0 * 100) } ?? "未提供"
        let track = snapshot.track.map(String.init) ?? "未提供"
        let speed = snapshot.speedKB.map { String(format: "%.3f KB/s（%.3f MB/s）", $0, $0 / 1000) } ?? "未提供"
        let factor = snapshot.speedX.map { String(format: "%.3f×", $0) } ?? "未提供"
        let range: String
        if let minimumKB, let maximumKB {
            range = String(format: "%.3f–%.3f KB/s", minimumKB, maximumKB)
        } else {
            range = "未提供"
        }
        let message = "[写入速度采样] 采样点已用 \(BurnFormat.duration(pending.seconds))；轨道=\(track)；进度=\(progress)；"
            + "DRStatusProgressCurrentKPS=\(speed)；DRStatusProgressCurrentXFactor=\(factor)；"
            + "DRStatusCurrentSpeedKey(raw)=\(snapshot.currentSpeedRaw ?? "未提供")；"
            + "状态=\(snapshot.rawState ?? snapshot.phase.rawValue)；本段最低–最高=\(range)；回调数=\(count)"
        self.pending = nil
        minimumKB = nil
        maximumKB = nil
        count = 0
        return message
    }
}
