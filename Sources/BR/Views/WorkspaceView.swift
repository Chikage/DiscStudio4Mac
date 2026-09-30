import BRCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var store: BurnStore
    @State private var confirmBurn = false
    @State private var sharedImage: SharedImageSelection?
    @State private var confirmCancel = false
    @State private var pendingBurns: [BurnRequest] = []
    @State private var cancelSession: BurnSession?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disc Studio").font(.headline)
                Spacer()
                Picker("工作模式", selection: $store.mode) {
                    ForEach(StudioMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                .disabled(store.isDemo)
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            Divider()
            if store.mode == .burn {
                burnWorkspace
            } else {
                ImageWorkspaceView(store: store)
            }
        }
        .frame(minWidth: 1050, minHeight: 530)
        .tint(StudioStyle.accent)
    }

    private var burnWorkspace: some View {
        HStack(spacing: 0) {
            SetupView(store: store)
            Divider()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        if store.isDemo {
                            Label("演示模式 · 所有读数均为模拟数据，不会写入光盘", systemImage: "play.rectangle")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(
                                    StudioStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if store.sessions.count > 1 { sessionOverview }
                        BurnTelemetryView(store: store.selectedSession)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 18) {
                            LogView(store: store.selectedSession).frame(maxWidth: .infinity)
                            DeviceInfoView(device: store.selectedDevice, isDemo: store.isDemo)
                                .frame(width: 250)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                footer
            }.background(StudioStyle.background)
        }
        .frame(minWidth: 1050, minHeight: 480)
        .tint(StudioStyle.accent)
        .sheet(item: $sharedImage) { selection in
            SharedImageBurnView(store: store, image: selection.image)
        }
        .sheet(isPresented: $confirmBurn) {
            BurnConfirmationView(requests: pendingBurns) { store.startBurns(pendingBurns) }
        }
        .alert("停止当前刻录？", isPresented: $confirmCancel) {
            Button("继续刻录", role: .cancel) {}
            Button("停止刻录", role: .destructive) { cancelSession?.cancel() }
        } message: {
            Text(
                "设备：\(cancelSession?.deviceName ?? "")\n"
                    + (store.isDemo ? "将停止这台设备的演示任务。" : "中断写入可能导致光盘无法使用。停止后请等待设备完成清理。其他设备将继续刻录。"))
        }
        .alert(
            "操作未完成",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("知道了") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.label(for: store.selectedSession)).font(.title2.bold())
                Text("\(store.activeBurnCount) 台正在刻录 · 每台设备可使用不同镜像")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isDemo {
                Button("退出演示") { store.exitDemo() }.disabled(store.isBusy)
            } else {
                Button {
                    store.startDemo()
                } label: {
                    Label("界面演示", systemImage: "play.circle")
                }
                .disabled(store.isBusy || store.isLoadingImage)
            }
        }.padding(24)
    }

    private var sessionOverview: some View {
        StudioPanel(title: "设备任务", symbol: "opticaldiscdrive") {
            HStack {
                Text("点击设备查看进度、配置镜像或单独停止。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("启动所有就绪设备（\(store.readySessions.count)）") {
                    pendingBurns = store.readySessions.compactMap(\.burnRequest)
                    confirmBurn = true
                }
                .disabled(store.readySessions.isEmpty)
            }
            ForEach(store.sessions) { session in
                BurnSessionRow(
                    session: session, label: store.label(for: session), selected: session.id == store.selectedSession.id
                ) {
                    store.selectedDeviceID = session.deviceID
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    store.selectedSession.isBusy
                        ? (store.snapshot.cancelling ? "正在停止，请等待设备清理…" : "刻录期间请保持光驱连接")
                        : store.isDemo ? "演示任务已结束" : store.preflightIssue ?? "已就绪，可以开始刻录"
                )
                .font(.subheadline.weight(.medium))
                Text(
                    store.isDemo
                        ? "演示任务不访问真实刻录设备。"
                        : store.selectedSession.isBusy ? "Mac 将保持唤醒，任务完成后恢复。" : "支持 CD / DVD / BD，具体取决于光驱与介质。"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.selectedSession.isBusy {
                Button("停止此设备", role: .destructive) {
                    cancelSession = store.selectedSession
                    confirmCancel = true
                }
                .disabled(store.snapshot.cancelling).controlSize(.large)
            } else {
                Button {
                    store.eject()
                } label: {
                    Image(systemName: "eject")
                }
                .help("弹出光盘").accessibilityLabel("弹出光盘")
                .disabled(store.selectedDevice?.present != true || !store.canEditSelectedSession)
                if store.sessions.count > 1 {
                    Button("多机刻录…") {
                        sharedImage = store.image.map(SharedImageSelection.init)
                    }
                    .disabled(store.image == nil || store.isDemo)
                }
                Button {
                    pendingBurns = [store.selectedSession.burnRequest].compactMap { $0 }
                    confirmBurn = true
                } label: {
                    Label("开始刻录", systemImage: "flame.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canBurn)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(.bar)
    }
}

struct LogView: View {
    var store: BurnSession
    var body: some View {
        StudioPanel(title: "任务日志", symbol: "list.bullet.rectangle") {
            HStack {
                Text("记录每一个关键状态").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出日志…") { FilePanels.exportLog(session: store) }.buttonStyle(.borderless)
            }
            if store.logs.isEmpty {
                Text("任务事件将显示在这里。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(store.logs.reversed()) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Text(item.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                                    .fixedSize()
                                Text(item.message).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 100)
            }
        }
    }
}

struct DeviceInfoView: View {
    let device: DiscDevice?
    var isDemo = false

    var body: some View {
        StudioPanel(title: "光驱信息", symbol: "opticaldiscdrive") {
            if isDemo {
                Text("演示模式不显示硬件信息。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if device == nil {
                Text("连接并选择光驱后显示设备信息。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if details.isEmpty {
                Text("设备未提供硬件信息。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(details, id: \.label) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(detail.label).foregroundStyle(.secondary).fixedSize()
                            Spacer(minLength: 0)
                            Text(detail.value)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var details: [(label: String, value: String)] {
        guard let device, !isDemo else { return [] }
        let location = device.location.map {
            switch $0 {
            case "Internal": "内置"
            case "External": "外置"
            default: $0
            }
        }
        let fields: [(String, String?)] = [
            ("厂商", device.vendor),
            ("型号", device.product),
            ("固件版本", device.firmware),
            ("连接方式", device.interconnect),
            ("设备位置", location),
            (
                "写入缓存",
                device.bufferCapacity.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
                }
            ),
            ("支持刻录", device.writableMedia.isEmpty ? nil : device.writableMedia.joined(separator: " · ")),
        ]
        return fields.compactMap { label, value in value.map { (label, $0) } }
    }
}

#Preview("Light") { WorkspaceView(store: BurnStore()).preferredColorScheme(.light) }
#Preview("Dark") { WorkspaceView(store: BurnStore()).preferredColorScheme(.dark) }
#Preview("Compact") { WorkspaceView(store: BurnStore()).frame(width: 1050, height: 480) }

private struct BurnSessionRow: View {
    let session: BurnSession
    let label: String
    let selected: Bool
    let select: () -> Void

    private var status: String {
        if session.snapshot.cancelling { return "正在停止" }
        if session.isBusy { return session.snapshot.phase.title }
        if session.discCopy.isBusy { return "正在提取镜像" }
        if session.snapshot.phase != .idle { return session.snapshot.phase.title }
        if session.device == nil { return "设备已断开" }
        if session.isLoadingImage { return "正在解析镜像…" }
        return session.errorMessage ?? session.preflightIssue ?? "已就绪"
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? StudioStyle.accent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.subheadline.weight(.semibold))
                    Text(session.image?.url.lastPathComponent ?? "尚未选择镜像")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(status).font(.caption).lineLimit(2)
                    if let progress = session.snapshot.progress {
                        HStack(spacing: 8) {
                            ProgressView(value: progress).frame(width: 90)
                            Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }.font(.caption)
                    }
                }
                .foregroundStyle(session.snapshot.phase == .failed ? .red : .secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? StudioStyle.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("设备：\(session.deviceID)\n镜像：\(session.image?.url.path ?? "未选择")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，\(session.image?.url.lastPathComponent ?? "尚未选择镜像")")
        .accessibilityValue(status + (session.snapshot.progress.map { "，\(Int($0 * 100))%" } ?? ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

private struct BurnConfirmationView: View {
    let requests: [BurnRequest]
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("开始写入 \(requests.count) 台设备？").font(.title2.bold())
            Text("请核对每台设备的镜像与选项。中断写入可能导致光盘无法使用。")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(requests, id: \.sessionID) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(request.deviceName, systemImage: "opticaldiscdrive").font(.headline)
                            Text(request.deviceID).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(request.imageURL.path).font(.subheadline)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(
                                "写入容量：\(BurnFormat.bytes(request.burnBytes)) · 速度：\(request.options.speed == 0 ? "自动" : String(format: "%.1f MB/s", request.options.speed / 1000))"
                            )
                            Text(
                                "封盘：\(request.options.finalize ? "是" : "否") · 校验：\(request.options.verify ? "是" : "否") · 完成后弹出：\(request.options.eject ? "是" : "否")"
                            )
                        }
                        .font(.caption)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始刻录") {
                    start()
                    dismiss()
                }
                .buttonStyle(.borderedProminent).disabled(requests.isEmpty)
            }
        }
        .padding(24).frame(width: 600, height: 480)
    }
}
