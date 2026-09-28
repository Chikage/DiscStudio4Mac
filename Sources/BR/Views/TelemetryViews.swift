import BRCore
import Charts
import SwiftUI

struct BurnTelemetryView: View {
    var store: BurnSession

    private var snapshot: BurnSnapshot { store.snapshot }
    private var isReading: Bool { store.speedHistory.phase == .verifying }
    private var progress: Double? {
        switch snapshot.phase {
        case .writing, .verifying: snapshot.progress
        case .completed: 1
        case .finishing, .failed, .cancelled: store.speedHistory.progress
        case .idle, .preparing: nil
        }
    }
    private var speedKB: Double? {
        isReading ? store.verificationSpeed.kilobytesPerSecond : snapshot.speedKB
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let stale = store.lastStatusAt.map { context.date.timeIntervalSince($0) > 5 } ?? false
            StudioPanel(
                title: isReading ? "校验进度与速度" : "刻录进度与速度", symbol: isReading ? "checkmark.shield" : "opticaldisc"
            ) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                            .font(.largeTitle.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(stateColor)
                        Text(isReading ? "校验进度" : "刻录进度")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 24)
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(!stale ? speedKB.map { String(format: "%.2f", $0 / 1000) } ?? "—" : "—")
                                .font(.title.weight(.semibold)).monospacedDigit()
                            Text("MB/s").font(.subheadline).foregroundStyle(.secondary)
                            if let factor = snapshot.speedX, !stale, !isReading {
                                Text(String(format: "%.1f×", factor))
                                    .font(.subheadline.monospaced()).foregroundStyle(StudioStyle.accent)
                            }
                        }
                        Text(speedDescription(stale: stale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                BurnSpeedChart(
                    samples: store.speedHistory.samples, progress: progress,
                    isReading: isReading, stateColor: stateColor)
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    TelemetryMetric(title: "当前阶段", value: snapshot.cancelling ? "正在停止" : snapshot.phase.title)
                    TelemetryMetric(title: "已用时间", value: BurnFormat.duration(store.elapsed(at: context.date)))
                    TelemetryMetric(title: "本阶段预计剩余", value: store.remainingTime(at: context.date))
                    if let track = snapshot.track, snapshot.phase.isActive {
                        TelemetryMetric(title: "当前轨道", value: "\(track) / \(store.image?.tracks ?? 1)")
                    }
                }
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speedDescription(stale: Bool) -> String {
        if stale && snapshot.phase.isActive { return "等待新的设备读数…" }
        let title = isReading ? "实时读取速度 · 估算" : "实时写入速度"
        return store.isDemo ? "\(title) · 模拟数据" : title
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
        case .idle: return "开始任务后，速度曲线将随进度从左向右绘制。"
        case .preparing: return "正在准备光盘与写入轨道。"
        case .writing: return "显示系统报告的写入进度与速度。"
        case .finishing: return store.completedOptions.finalize ? "正在关闭轨道与封盘，请稍候。" : "正在关闭当前会话，请稍候。"
        case .verifying: return "回读光盘并检查写入完整性，读取速度根据校验进度估算。"
        case .completed: return store.completedOptions.verify ? "写入完成，校验通过。" : "写入完成，未执行校验。"
        case .failed: return snapshot.error ?? "任务未能完成，请查看任务日志。"
        case .cancelled: return "任务已停止，设备清理已结束。"
        }
    }
}

private struct TelemetryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct BurnSpeedChart: View {
    let samples: [SpeedSample]
    let progress: Double?
    let isReading: Bool
    var stateColor: Color = StudioStyle.accent

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("进度", sample.progress), y: .value("MB/s", sample.megabytesPerSecond))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [StudioStyle.accent.opacity(0.22), StudioStyle.accent.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("进度", sample.progress), y: .value("MB/s", sample.megabytesPerSecond))
                    .foregroundStyle(StudioStyle.accent).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let progress {
                RuleMark(x: .value("当前进度", progress))
                    .foregroundStyle(stateColor.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(
                        position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(stateColor)
                    }
            }
            if let last = samples.last {
                PointMark(x: .value("进度", last.progress), y: .value("MB/s", last.megabytesPerSecond))
                    .foregroundStyle(StudioStyle.accent).symbolSize(32)
            }
        }
        .chartXScale(domain: 0.0...1.0, range: .plotDimension(padding: 4))
        .chartYScale(domain: 0...max(16, (samples.map(\.megabytesPerSecond).max() ?? 0) * 1.2))
        .chartXAxis {
            AxisMarks(values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine().foregroundStyle(StudioStyle.border)
                AxisTick().foregroundStyle(StudioStyle.border)
                AxisValueLabel(
                    anchor: value.as(Double.self) == 0 ? .topLeading : value.as(Double.self) == 1 ? .topTrailing : .top,
                    collisionResolution: .disabled
                ) {
                    if let progress = value.as(Double.self) {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(Color.primary.opacity(0.65))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(StudioStyle.border)
                AxisValueLabel().foregroundStyle(Color.primary.opacity(0.65))
            }
        }
        .frame(height: 152)
        .padding(.top, 20)
        .overlay {
            if samples.isEmpty {
                Text(isReading ? "等待校验进度与读取速度" : "等待刻录进度与写入速度")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8).background(StudioStyle.surface.opacity(0.9), in: Capsule())
            }
        }
        .accessibilityLabel(isReading ? "按校验进度绘制的读取速度曲线" : "按刻录进度绘制的写入速度曲线")
        .accessibilityValue(progress.map { "当前进度 \(Int($0 * 100))%，横轴 0% 至 100%，纵轴 MB/s" } ?? "等待进度与速度数据")
    }
}

#Preview("等待开始") {
    BurnTelemetryView(store: BurnStore().selectedSession).padding().frame(width: 700)
}

#Preview("写入 13% · 深色") {
    BurnSpeedChart(
        samples: (0...13).map {
            SpeedSample(progress: Double($0) / 100, megabytesPerSecond: $0 == 8 ? 7 : 11.8)
        }, progress: 0.13, isReading: false
    )
    .padding(24).frame(width: 700).preferredColorScheme(.dark)
}

#Preview("校验 100% · 浅色") {
    BurnSpeedChart(
        samples: (0...100).map {
            SpeedSample(progress: Double($0) / 100, megabytesPerSecond: 18 + sin(Double($0) * 0.2) * 2)
        }, progress: 1, isReading: true, stateColor: .green
    )
    .padding(24).frame(width: 700).preferredColorScheme(.light)
}
