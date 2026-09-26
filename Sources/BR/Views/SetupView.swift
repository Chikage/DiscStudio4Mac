import BRCore
import SwiftUI

struct SetupView: View {
    @Bindable var store: BurnStore
    @State private var dropTarget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.largeTitle).foregroundStyle(StudioStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BR").font(.title.bold())
                        Text("DISC STUDIO").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
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
                            if store.isLoadingImage {
                                ProgressView().controlSize(.small)
                                Text("正在解析镜像…").font(.subheadline)
                            } else {
                                Text(store.image?.url.lastPathComponent ?? "选择或拖入镜像")
                                    .font(.headline).lineLimit(2).multilineTextAlignment(.center)
                                Text(
                                    store.image.map { BurnFormat.bytes($0.burnBytes) + " · \($0.tracks) 条轨道" }
                                        ?? "ISO · DMG · CDR · CUE · TOC"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 24).padding(.horizontal, 12).frame(maxWidth: .infinity)
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
                    .buttonStyle(.plain).disabled(store.isBusy || store.isDemo)
                    .help("选择光盘镜像（⌘O）")
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, !store.isBusy, !store.isDemo else { return false }
                        store.selectImage(url)
                        return true
                    } isTargeted: {
                        dropTarget = $0
                    }
                    if let image = store.image {
                        KeyValueRow(label: "镜像文件", value: BurnFormat.bytes(image.fileBytes))
                        KeyValueRow(label: "占用容量", value: BurnFormat.bytes(image.burnBytes))
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
                        .accessibilityLabel("刷新刻录设备").disabled(store.isBusy || store.isDemo)
                    }
                    if store.devices.isEmpty {
                        Label("未发现刻录机", systemImage: "externaldrive.badge.questionmark")
                            .font(.subheadline.weight(.medium))
                        Text("连接光盘刻录机后，设备将自动出现在这里。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("刻录设备", selection: $store.selectedDeviceID) {
                            ForEach(store.devices) { Text($0.name).tag($0.id) }
                        }.labelsHidden().disabled(store.isBusy || store.isDemo)
                            .onChange(of: store.selectedDeviceID) { store.options.speed = 0 }
                        if let device = store.selectedDevice {
                            StatusPill(
                                title: device.status, color: device.present && device.blank ? .green : .secondary)
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
                    Picker("写入速度", selection: $store.options.speed) {
                        Text("自动 · 设备最高速度").tag(0.0)
                        if let device = store.selectedDevice {
                            ForEach(device.speeds, id: \.self) { speed in Text(device.speedLabel(speed)).tag(speed) }
                        }
                    }.pickerStyle(.menu)
                    Divider()
                    optionToggle("完成后封盘", subtitle: "关闭光盘，提升读取兼容性", isOn: $store.options.finalize)
                    optionToggle("写入后校验", subtitle: "回读光盘，与写入数据校验和比对", isOn: $store.options.verify)
                    optionToggle("完成后弹出", subtitle: "全部操作完成后弹出光盘", isOn: $store.options.eject)
                }.disabled(store.isBusy || store.isDemo)

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("所有镜像均在本机处理")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(width: 300)
        .background(.regularMaterial)
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
        }.toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
    }
}

#Preview { SetupView(store: BurnStore()).frame(height: 800) }
