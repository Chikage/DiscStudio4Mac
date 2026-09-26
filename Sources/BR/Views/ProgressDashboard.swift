import BRCore
import SwiftUI

struct ProgressDashboard: View {
    var store: BurnStore

    private var stateColor: Color {
        switch store.snapshot.phase {
        case .completed: .green
        case .failed: .red
        case .cancelled, .idle: .secondary
        default: StudioStyle.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("刻录进度", systemImage: "opticaldisc").font(.headline)
                Spacer()
                StatusPill(title: store.snapshot.cancelling ? "正在停止" : store.snapshot.phase.title, color: stateColor)
            }
            HStack(spacing: 28) {
                ZStack {
                    Circle().stroke(StudioStyle.border, lineWidth: 10)
                    Circle().trim(from: 0, to: store.snapshot.progress ?? 0)
                        .stroke(stateColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 6) {
                        Image(systemName: store.snapshot.phase == .completed ? "checkmark" : "opticaldisc")
                            .font(.title2).foregroundStyle(stateColor)
                        Text(store.snapshot.progress.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                            .font(.largeTitle.weight(.semibold)).monospacedDigit()
                    }
                }
                .frame(width: 100, height: 100)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("系统报告进度")
                .accessibilityValue(store.snapshot.progress.map { "\(Int($0 * 100)) 百分比" } ?? "尚未提供")
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline).font(.title2.weight(.semibold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    if store.isBusy && store.snapshot.progress == nil {
                        ProgressView().controlSize(.small)
                    }
                    if let track = store.snapshot.track, store.isBusy {
                        Text("轨道 \(track) / \(store.image?.tracks ?? 1)").font(.caption.monospaced()).foregroundStyle(
                            .secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                stage("准备", symbol: "doc.text.magnifyingglass", phase: .preparing)
                stage("写入", symbol: "flame", phase: .writing)
                stage(store.completedOptions.finalize ? "封盘" : "关闭会话", symbol: "lock", phase: .finishing)
                stage("校验", symbol: "checkmark.shield", phase: .verifying)
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    MetricView(
                        title: "已用时间", value: BurnFormat.duration(store.elapsed(at: context.date)), detail: "包含准备、写入与校验"
                    )
                    MetricView(
                        title: "占用容量", value: store.image.map { BurnFormat.bytes($0.burnBytes) } ?? "—",
                        detail: "轨道扇区 × 2048 字节")
                    MetricView(title: "校验策略", value: verificationLabel, detail: "光盘回读 · 轨道校验和")
                }
            }
        }
        .padding(20)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioStyle.border))
    }

    private var headline: String {
        switch store.snapshot.phase {
        case .idle: "准备好下一张光盘"
        case .preparing: "正在准备设备与轨道"
        case .writing: "正在将镜像写入光盘"
        case .finishing: store.completedOptions.finalize ? "正在关闭轨道与封盘" : "正在关闭当前会话"
        case .verifying: "正在检查写入完整性"
        case .completed: store.completedOptions.verify ? "写入完成，校验通过" : "写入完成，未执行校验"
        case .failed: "任务未能完成"
        case .cancelled: "刻录已停止"
        }
    }

    private var subtitle: String {
        switch store.snapshot.phase {
        case .idle: "选择镜像、插入空白光盘，即可开始。实时读数将在任务启动后显示。"
        case .preparing: "刻录引擎正在准备光盘。请勿断开设备。"
        case .writing: "百分比由系统刻录引擎报告；不同阶段的进度可能重新计算。"
        case .finishing: "正在处理光盘目录与会话信息，此阶段可能需要几分钟。"
        case .verifying: "回读光盘并比对写入时计算的校验和，确保数据完整。"
        case .completed: store.completedOptions.finalize ? "本次已完成封盘。你可以取出光盘并在其他设备读取。" : "本次保留追加能力，实际可追加性取决于介质。"
        case .failed: store.snapshot.error ?? "请检查任务日志、光驱连接和光盘状态后重试。"
        case .cancelled: "设备清理已结束。被中断写入的光盘可能无法再次使用。"
        }
    }

    private var verificationLabel: String {
        let enabled = store.snapshot.phase == .idle ? store.options.verify : store.completedOptions.verify
        if !enabled { return "未启用" }
        return store.snapshot.phase == .completed ? "已通过" : "回读校验"
    }

    private func stage(_ title: String, symbol: String, phase: BurnPhase) -> some View {
        let active = store.snapshot.phase == phase
        return Label(title, systemImage: symbol)
            .font(.subheadline.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? stateColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? stateColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview { ProgressDashboard(store: BurnStore()).padding().frame(width: 760) }
