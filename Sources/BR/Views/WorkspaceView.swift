import BRCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var store: BurnStore
    @State private var confirmBurn = false
    @State private var confirmCancel = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disc Studio").font(.headline)
                Spacer()
                Picker("工作模式", selection: $store.mode) {
                    ForEach(StudioMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                .disabled(store.isBusy || store.isLoadingImage || store.isDemo)
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
                        HStack(alignment: .top, spacing: 18) {
                            SpeedChartView(store: store).frame(maxWidth: .infinity)
                            CurrentProgressView(store: store).frame(width: 250)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 18) {
                            LogView(store: store).frame(maxWidth: .infinity)
                            DeviceInfoView(device: store.selectedDevice, isDemo: store.isDemo)
                                .frame(width: 250)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }.padding(24).padding(.top, 0)
                }
                footer
            }.background(StudioStyle.background)
        }
        .frame(minWidth: 1050, minHeight: 480)
        .tint(StudioStyle.accent)
        .alert("开始写入光盘？", isPresented: $confirmBurn) {
            Button("取消", role: .cancel) {}
            Button("开始刻录") { store.startBurn() }
        } message: {
            Text(
                "镜像：\(store.image?.url.lastPathComponent ?? "")\n设备：\(store.selectedDevice?.name ?? "")\n写入：\(BurnFormat.bytes(store.image?.burnBytes ?? 0))\n封盘：\(store.options.finalize ? "是" : "否") · 校验：\(store.options.verify ? "是" : "否")\n开始后中断写入可能导致光盘无法使用。"
            )
        }
        .alert("停止当前刻录？", isPresented: $confirmCancel) {
            Button("继续刻录", role: .cancel) {}
            Button("停止刻录", role: .destructive) { store.cancel() }
        } message: {
            Text(store.isDemo ? "将停止演示任务。" : "中断写入可能导致光盘无法使用。停止后请等待设备完成清理。")
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
                Text("光盘刻录工作台").font(.title2.bold())
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

    private var footer: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    store.isBusy
                        ? (store.snapshot.cancelling ? "正在停止，请等待设备清理…" : "刻录期间请保持光驱连接")
                        : store.isDemo ? "演示任务已结束" : store.preflightIssue ?? "已就绪，可以开始刻录"
                )
                .font(.subheadline.weight(.medium))
                Text(
                    store.isDemo
                        ? "演示任务不访问真实刻录设备。" : store.isBusy ? "Mac 将保持唤醒，任务完成后恢复。" : "支持 CD / DVD / BD，具体取决于光驱与介质。"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy {
                Button("停止刻录", role: .destructive) { confirmCancel = true }
                    .disabled(store.snapshot.cancelling).controlSize(.large)
            } else {
                Button {
                    store.eject()
                } label: {
                    Image(systemName: "eject")
                }
                .help("弹出光盘").accessibilityLabel("弹出光盘")
                .disabled(store.selectedDevice?.present != true || store.isDemo)
                Button {
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
    var store: BurnStore
    var body: some View {
        StudioPanel(title: "任务日志", symbol: "list.bullet.rectangle") {
            HStack {
                Text("记录每一个关键状态").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出日志…") { FilePanels.exportLog(store: store) }.buttonStyle(.borderless)
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
