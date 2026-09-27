import BRCore
import SwiftUI

struct SetupView: View {
    @Bindable var store: BurnStore
    @State private var dropTarget = false
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
                        HStack(spacing: 12) {
                            Group {
                                if store.isLoadingImage {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: store.image == nil ? "square.and.arrow.down" : "doc.zipper")
                                        .font(.title2).foregroundStyle(StudioStyle.accent)
                                        .accessibilityHidden(true)
                                }
                            }.frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    store.isLoadingImage
                                        ? "正在解析镜像…" : store.image?.url.lastPathComponent ?? "选择或拖入镜像"
                                )
                                    .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                Text(
                                    store.image.map { BurnFormat.bytes($0.burnBytes) + " · \($0.tracks) 条轨道" }
                                        ?? "ISO · DMG · CDR · CUE · TOC"
                                )
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .background(
                            dropTarget ? StudioStyle.accent.opacity(0.12) : StudioStyle.surface,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    StudioStyle.accent.opacity(dropTarget ? 0.8 : 0.3),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    .buttonStyle(.plain).disabled(store.isBusy || store.isDemo)
                    .help(store.image.map { $0.url.path + "\n点击更换镜像（⌘O）" } ?? "选择光盘镜像（⌘O）")
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, !store.isBusy, !store.isDemo else { return false }
                        store.selectImage(url)
                        return true
                    } isTargeted: {
                        dropTarget = $0
                    }
                    if let image = store.image {
                        let exceedsCapacity = store.selectedDevice.map {
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
                        .accessibilityLabel("刷新刻录设备").disabled(store.isBusy || store.isDemo)
                    }
                    if store.devices.isEmpty {
                        Label("未发现刻录机", systemImage: "externaldrive.badge.questionmark")
                            .font(.subheadline.weight(.medium))
                        Text("连接光盘刻录机后，设备将自动出现在这里。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: controlSpacing) {
                            Picker("刻录设备", selection: $store.selectedDeviceID) {
                                ForEach(store.devices) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.menu).labelsHidden().lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                            .disabled(store.isBusy || store.isDemo)
                            .help(store.selectedDevice?.name ?? "选择刻录设备")
                            .onChange(of: store.selectedDeviceID) { store.options.speed = 0 }
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
                                ForEach(device.speeds, id: \.self) { speed in Text(device.speedLabel(speed)).tag(speed) }
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
                }.disabled(store.isBusy || store.isDemo)
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
