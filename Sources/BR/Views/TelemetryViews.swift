import BRCore
import Charts
import SwiftUI

struct SpeedChartView: View {
    var store: BurnStore

    private var isReading: Bool { store.speedHistory.phase == .verifying }
    private var title: String { isReading ? "实时读取速度" : "实时写入速度" }
    private var speedKB: Double? {
        isReading ? store.verificationSpeed.kilobytesPerSecond : store.snapshot.speedKB
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Status updates can arrive between timeline ticks. Include the newest reading immediately.
            let date = max(context.date, store.lastStatusAt ?? context.date)
            let seconds = store.elapsed(at: date)
            let samples = store.speedHistory.samples(at: seconds)
            StudioPanel(title: title, symbol: "speedometer") {
                let stale = store.lastStatusAt.map { context.date.timeIntervalSince($0) > 5 } ?? false
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(!stale ? speedKB.map { String(format: "%.2f", $0 / 1000) } ?? "—" : "—")
                        .font(.largeTitle.weight(.semibold)).monospacedDigit()
                    Text("MB/s").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let factor = store.snapshot.speedX, !stale, !isReading {
                        Text(String(format: "%.1f×", factor)).font(.headline.monospaced()).foregroundStyle(
                            StudioStyle.accent)
                    }
                }
                Text(stale && store.isBusy ? "等待新的设备读数…" : sourceDescription)
                    .font(.caption).foregroundStyle(.secondary)
                Chart(samples) { sample in
                    AreaMark(x: .value("相对秒数", sample.seconds - seconds), y: .value("MB/s", sample.megabytesPerSecond))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [StudioStyle.accent.opacity(0.22), StudioStyle.accent.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("相对秒数", sample.seconds - seconds), y: .value("MB/s", sample.megabytesPerSecond))
                        .foregroundStyle(StudioStyle.accent).lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXScale(domain: -SpeedHistory.windowDuration...0)
                .chartYScale(domain: 0...max(16, (samples.map(\.megabytesPerSecond).max() ?? 0) * 1.2))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(StudioStyle.border)
                        AxisValueLabel().foregroundStyle(.secondary)
                    }
                }
                .frame(height: 96)
                .overlay {
                    if samples.isEmpty {
                        Text(isReading ? "等待读取速度数据" : store.snapshot.phase == .writing ? "等待写入速度数据" : "最近 60 秒暂无写入速度数据")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(8).background(StudioStyle.surface.opacity(0.9), in: Capsule())
                    }
                }
                .accessibilityLabel(isReading ? "最近 60 秒读取速度估算曲线" : "最近 60 秒写入速度曲线")
            }
        }
    }

    private var sourceDescription: String {
        if store.isDemo { return isReading ? "模拟读数 · 根据校验进度估算" : "模拟读数" }
        return isReading ? "根据校验进度估算 · 1 MB = 1,000,000 字节" : "设备实时报告 · 1 MB = 1,000,000 字节"
    }
}

struct CurrentProgressView: View {
    var store: BurnStore

    private var snapshot: BurnSnapshot { store.snapshot }

    var body: some View {
        StudioPanel(title: title, symbol: snapshot.phase == .verifying ? "checkmark.shield" : "opticaldisc") {
            Text(snapshot.progress.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                .foregroundStyle(stateColor)
            ProgressView(value: snapshot.progress ?? (snapshot.phase.isActive ? nil : 0))
                .progressViewStyle(.linear).tint(stateColor)
                .accessibilityLabel(title)
                .accessibilityValue(snapshot.progress.map { "\(Int($0 * 100)) 百分比" } ?? "等待进度")
            KeyValueRow(label: "当前阶段", value: snapshot.cancelling ? "正在停止" : snapshot.phase.title)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                KeyValueRow(label: "已用时间", value: BurnFormat.duration(store.elapsed(at: context.date)))
            }
            if let track = snapshot.track, snapshot.phase.isActive {
                KeyValueRow(label: "当前轨道", value: "\(track) / \(store.image?.tracks ?? 1)")
            }
            Text(detail)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch snapshot.phase {
        case .verifying: "校验进度"
        case .preparing, .writing, .finishing: "刻录进度"
        default: "任务进度"
        }
    }

    private var stateColor: Color {
        switch snapshot.phase {
        case .completed: .green
        case .failed: .red
        case .idle, .cancelled: .secondary
        default: StudioStyle.accent
        }
    }

    private var detail: String {
        if snapshot.cancelling { return "正在等待设备完成清理。" }
        switch snapshot.phase {
        case .idle: return "开始任务后显示实时进度。"
        case .preparing: return "正在准备光盘与写入轨道。"
        case .writing: return "显示系统报告的当前写入进度。"
        case .finishing: return store.completedOptions.finalize ? "正在关闭轨道与封盘，请稍候。" : "正在关闭当前会话，请稍候。"
        case .verifying: return "回读光盘并检查写入完整性。"
        case .completed: return store.completedOptions.verify ? "写入完成，校验通过。" : "写入完成，未执行校验。"
        case .failed: return snapshot.error ?? "任务未能完成，请查看任务日志。"
        case .cancelled: return "任务已停止，设备清理已结束。"
        }
    }
}

#Preview {
    HStack {
        SpeedChartView(store: BurnStore())
        CurrentProgressView(store: BurnStore()).frame(width: 250)
    }.padding().frame(width: 750)
}
