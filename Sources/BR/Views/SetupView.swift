import BRCore
import SwiftUI

struct SetupView: View {
    @Bindable var store: BurnStore
    @State private var dropTarget = false
    @State private var sharedImage: SharedImageSelection?
    private let accessoryWidth: CGFloat = 20
    private let controlSpacing: CGFloat = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.largeTitle).foregroundStyle(StudioStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disc Studio").font(.title.bold())
                        Text("光盘刻录工作台").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)

                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("01", "光盘镜像")
                    Button {
                        FilePanels.chooseImage(store: store)
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: store.image == nil ? "square.and.arrow.down" : "doc.zipper")
                                .font(.largeTitle).foregroundStyle(StudioStyle.accent)
                                .accessibilityHidden(true)
                            if store.selectedSession.isLoadingImage {
                                ProgressView().controlSize(.small)
                                Text("正在解析镜像…").font(.subheadline)
                            } else {
                                Text(store.image?.url.lastPathComponent ?? "选择或拖入镜像")
                                    .font(.headline).lineLimit(2).truncationMode(.middle)
                                    .multilineTextAlignment(.center)
                                Text(
                                    store.image.map { BurnFormat.bytes($0.burnBytes) + " · \($0.tracks) 条轨道" }
                                        ?? "ISO · DMG · CDR · CUE · TOC"
                                )
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 24).padding(.horizontal, 12).frame(maxWidth: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .background(
                            dropTarget ? StudioStyle.accent.opacity(0.12) : StudioStyle.surface,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    StudioStyle.accent.opacity(dropTarget ? 0.8 : 0.3),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    .buttonStyle(.plain).disabled(!store.canEditSelectedSession)
                    .help(store.image.map { $0.url.path + "\n点击更换镜像（⌘O）" } ?? "选择光盘镜像（⌘O）")
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, store.canEditSelectedSession else { return false }
                        store.selectImage(url)
                        return true
                    } isTargeted: {
                        dropTarget = $0
                    }
                    if store.sessions.count > 1 {
                        Button {
                            sharedImage = store.image.map(SharedImageSelection.init)
                        } label: {
                            Label("同一镜像刻录到多台…", systemImage: "opticaldiscdrive")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.image == nil || store.isDemo || store.imageCreation.isBusy)
                        Text("选择一次镜像，勾选两台或更多刻录机同时写入。不同镜像可分别设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let image = store.image {
                        let exceedsCapacity =
                            store.selectedDevice.map {
                                $0.present && image.blocks > $0.freeBlocks
                            } ?? false
                        KeyValueRow(
                            label: "镜像文件", value: BurnFormat.bytes(image.fileBytes),
                            valueColor: exceedsCapacity ? .red : .primary
                        )
                        .help(exceedsCapacity ? "镜像所需容量超过光盘可用容量" : "")
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        sectionLabel("02", "目标设备")
                        Spacer()
                        Button {
                            store.refreshDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless).help("刷新设备")
                        .frame(width: accessoryWidth)
                        .accessibilityLabel("刷新刻录设备").disabled(store.isDemo)
                    }
                    if store.sessions.allSatisfy({ $0.deviceID.isEmpty }) {
                        Label("未发现刻录机", systemImage: "externaldrive.badge.questionmark")
                            .font(.subheadline.weight(.medium))
                        Text("连接光盘刻录机后，设备将自动出现在这里。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: controlSpacing) {
                            Picker("刻录设备", selection: $store.selectedDeviceID) {
                                ForEach(store.sessions) { Text(store.label(for: $0)).tag($0.deviceID) }
                            }
                            .pickerStyle(.menu).labelsHidden().lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                            .disabled(store.imageCreation.isBusy)
                            .help(store.selectedDevice?.name ?? "选择刻录设备")
                            Group {
                                if let device = store.selectedDevice {
                                    DeviceStatusIcon(device: device)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: accessoryWidth, height: 24)
                        }
                        if let device = store.selectedDevice {
                            KeyValueRow(label: "介质类型", value: device.present ? device.media : "—")
                            KeyValueRow(
                                label: "可用容量",
                                value: device.present
                                    ? BurnFormat.bytes(
                                        Int64(clamping: min(device.freeBlocks, UInt64(Int64.max / 2048))) * 2048) : "—")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("03", "刻录选项")
                    HStack(spacing: controlSpacing) {
                        Text("写入速度").fixedSize()
                        Picker("写入速度", selection: $store.options.speed) {
                            Text("自动 · 设备最高速度").tag(0.0)
                            if let device = store.selectedDevice {
                                ForEach(device.speeds, id: \.self) { speed in Text(device.speedLabel(speed)).tag(speed)
                                }
                            }
                        }
                        .pickerStyle(.menu).labelsHidden()
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.trailing, accessoryWidth + controlSpacing)
                    Divider()
                    optionToggle("完成后封盘", subtitle: "关闭光盘，提升读取兼容性", isOn: $store.options.finalize)
                    optionToggle("写入后校验", subtitle: "回读光盘，与写入数据校验和比对", isOn: $store.options.verify)
                    optionToggle("完成后弹出", subtitle: "全部操作完成后弹出光盘", isOn: $store.options.eject)
                }.disabled(!store.canEditSelectedSession)
            }.padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppVersionView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .sheet(item: $sharedImage) { selection in
            SharedImageBurnView(store: store, image: selection.image)
        }
    }

    private func sectionLabel(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.caption.monospaced().bold()).foregroundStyle(StudioStyle.accent)
            Text(title).font(.headline)
        }
    }

    private func optionToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
    }
}

private struct DeviceStatusIcon: View {
    let device: DiscDevice

    private var symbol: String {
        if device.busy { return "hourglass" }
        if !device.present { return "tray.and.arrow.down" }
        return device.blank ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var color: Color {
        if device.busy { return StudioStyle.accent }
        if !device.present { return .secondary }
        return device.blank ? .green : StudioStyle.accent
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(height: 24)
            .help(device.status)
            .accessibilityLabel("设备状态：\(device.status)")
    }
}

#Preview { SetupView(store: BurnStore()).frame(height: 800) }

#Preview("设备状态") {
    HStack(spacing: 16) {
        DeviceStatusIcon(device: DiscDevice(dictionary: ["busy": true]))
        DeviceStatusIcon(device: DiscDevice(dictionary: [:]))
        DeviceStatusIcon(device: DiscDevice(dictionary: ["present": true, "blank": true]))
        DeviceStatusIcon(device: DiscDevice(dictionary: ["present": true]))
    }.padding()
}

struct SharedImageSelection: Identifiable {
    let id = UUID()
    let image: DiscImage

    init(_ image: DiscImage) { self.image = image }
}

struct SharedImageBurnView: View {
    let store: BurnStore
    let image: DiscImage
    @State private var selectedIDs: Set<UUID>
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(store: BurnStore, image: DiscImage) {
        self.store = store
        self.image = image
        _selectedIDs = State(
            initialValue: store.sharedImageIssue(image, for: store.selectedSession) == nil
                ? [store.selectedSession.id] : [])
    }

    private var targets: [BurnSession] { store.sessions.filter { !$0.deviceID.isEmpty } }
    private var canStart: Bool {
        !store.isDemo && !isPreparing && !selectedIDs.isEmpty
            && targets.filter { selectedIDs.contains($0.id) }.count == selectedIDs.count
            && targets.filter { selectedIDs.contains($0.id) }.allSatisfy {
                store.sharedImageIssue(image, for: $0) == nil
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("同一镜像 · 多机刻录").font(.title2.bold())
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "opticaldisc.fill").font(.largeTitle).foregroundStyle(StudioStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(image.url.lastPathComponent).font(.headline)
                    Text(image.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("每张光盘写入 \(BurnFormat.bytes(image.burnBytes)) · \(image.tracks) 条轨道")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("选择刻录机").font(.headline)
                Spacer()
                Text("已选 \(selectedIDs.count) 台 · \(selectedIDs.count) 份相同内容")
                    .font(.subheadline).foregroundStyle(StudioStyle.accent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(targets) { session in
                        targetRow(session)
                    }
                    if targets.isEmpty {
                        Text("连接刻录机并插入空白光盘后，设备会出现在这里。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if isPreparing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在为 \(selectedIDs.count) 台设备准备镜像，全部就绪后开始写入…")
                        .font(.subheadline)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("仅写入勾选的设备，使用各自显示的刻录选项。开始后中断写入可能导致光盘无法使用。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(isPreparing ? "取消准备" : "取消") {
                    if isPreparing { store.cancelSharedImageBurn() }
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(selectedIDs.count > 1 ? "同时刻录到 \(selectedIDs.count) 台设备" : "刻录到 \(selectedIDs.count) 台设备") {
                    errorMessage = nil
                    isPreparing = true
                    store.startSharedImageBurn(image: image, targetIDs: selectedIDs) { error in
                        isPreparing = false
                        errorMessage = error
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(!canStart)
            }
            .controlSize(.large)
        }
        .padding(24).frame(width: 650, height: 610)
        .background(StudioStyle.background)
        .interactiveDismissDisabled(isPreparing)
        .onDisappear { if isPreparing { store.cancelSharedImageBurn() } }
    }

    private func targetRow(_ session: BurnSession) -> some View {
        let selected = selectedIDs.contains(session.id)
        let issue = store.sharedImageIssue(image, for: session)
        return Toggle(
            isOn: Binding(
                get: { selectedIDs.contains(session.id) },
                set: { if $0 { selectedIDs.insert(session.id) } else { selectedIDs.remove(session.id) } }
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.label(for: session)).font(.subheadline.weight(.semibold))
                Text(issue ?? "\(session.device?.media ?? "光盘") · 就绪")
                    .font(.caption).foregroundStyle(issue == nil ? Color.secondary : Color.red)
                Text(
                    "速度：\(session.options.speed == 0 ? "自动" : String(format: "%.1f MB/s", session.options.speed / 1000)) · 封盘：\(session.options.finalize ? "是" : "否") · 校验：\(session.options.verify ? "是" : "否") · 弹出：\(session.options.eject ? "是" : "否")"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .disabled(isPreparing || (!selected && issue != nil))
        .padding(14)
        .background(
            selected ? StudioStyle.accent.opacity(0.1) : StudioStyle.surface, in: RoundedRectangle(cornerRadius: 10)
        )
        .help(session.deviceID)
    }
}
