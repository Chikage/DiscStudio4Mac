import BRCore
import SwiftUI

struct DiscCopyOverviewView: View {
    @Bindable var store: BurnStore

    var body: some View {
        StudioPanel(title: "光驱提取任务", symbol: "opticaldiscdrive") {
            HStack {
                Text("\(store.activeDiscCopyCount) 台正在提取 · 点击设备查看详情或单独停止")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("提取全部就绪光驱（\(store.readyDiscCopyRequests.count)）…") {
                    FilePanels.saveDiscImages(store: store)
                }.disabled(store.readyDiscCopyRequests.isEmpty)
            }
            ForEach(store.sessions) { session in
                DiscCopyTaskRow(
                    session: session, label: store.label(for: session),
                    selected: session.id == store.selectedSession.id
                ) { store.selectedDeviceID = session.deviceID }
            }
        }
    }
}

private struct DiscCopyTaskRow: View {
    let session: BurnSession
    let label: String
    let selected: Bool
    let select: () -> Void
    private var job: ImageCreationStore { session.discCopy }
    private var status: String {
        if job.isCancelling { return "正在停止" }
        if session.isBusy { return "正在刻录" }
        if session.isLoadingImage { return "正在准备镜像" }
        if job.status.phase != .idle { return job.status.phase.title }
        return ImagePreflight.copyIssue(device: session.device) ?? "已就绪"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? StudioStyle.accent : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).font(.subheadline.weight(.semibold))
                        Text(job.destinationURL?.lastPathComponent ?? session.device?.volumeName ?? "未提供光盘标签")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 12) {
                            if job.status.phase == .copying { Text(job.readSpeedLabel()).monospacedDigit() }
                            Text(status)
                        }.font(.caption)
                        if let progress = job.status.progress {
                            HStack(spacing: 8) {
                                ProgressView(value: progress).frame(width: 110)
                                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            }.font(.caption)
                        }
                    }.foregroundStyle(job.status.phase == .failed ? .red : .secondary)
                }
                .padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(selected ? StudioStyle.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("设备：\(session.deviceID)\n\(job.errorMessage ?? job.destinationURL?.path ?? status)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(label)，\(job.destinationURL?.lastPathComponent ?? session.device?.volumeName ?? "未提供光盘标签")"
            )
            .accessibilityValue(
                status + (job.status.progress.map { "，\(Int($0 * 100))%" } ?? "") + "，\(job.readSpeedLabel())"
            )
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        }
    }
}

#Preview("提取任务") {
    DiscCopyOverviewView(store: BurnStore()).padding().frame(width: 1000)
}
