import AppKit
import BRCore
import SwiftUI

struct ImageWorkspaceView: View {
    @Bindable var store: BurnStore
    private var job: ImageCreationStore { store.imageCreation }
    private var isBuilding: Bool { store.mode == .buildISO }
    private var issue: String? {
        isBuilding ? job.buildIssue : ImagePreflight.copyIssue(device: store.selectedDevice)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.mode.title).font(.title2.bold())
                        Text(isBuilding ? "将文件和文件夹整理成可挂载、可刻录的数据光盘镜像。" : "读取光驱中的数据光盘，保存到 Mac。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 18) {
                            if isBuilding {
                                ImageSourcesView(job: job, disabled: store.isBusy)
                                DataImageOptionsView(job: job).disabled(store.isBusy)
                            } else {
                                DiscCopyOptionsView(store: store).disabled(store.isBusy)
                                DeviceInfoView(device: store.selectedDevice)
                            }
                        }.frame(width: 390)
                        VStack(spacing: 18) {
                            imageProgress
                            imageLog
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(24)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        job.isCancelling
                            ? "正在停止并清理临时文件…" : job.isBusy ? job.status.phase.title : issue ?? "已就绪，选择保存位置即可开始"
                    )
                    .font(.subheadline.weight(.medium))
                    Text(job.isBusy ? "任务期间 Mac 将保持唤醒。" : "保存位置需要足够空间容纳临时数据与最终镜像。")
                        .font(.caption).foregroundStyle(.secondary)
                    AppVersionView()
                        .padding(.top, 4)
                }
                Spacer()
                if job.isBusy {
                    Button("取消任务", role: .destructive) { job.cancel() }
                        .disabled(job.isCancelling).controlSize(.large)
                } else {
                    Button {
                        FilePanels.saveImage(store: store)
                    } label: {
                        Label(isBuilding ? "创建 ISO…" : "保存光盘镜像…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(issue != nil || store.isBusy || store.isLoadingImage || store.isDemo)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(.bar)
        }
        .background(StudioStyle.background)
        .alert(
            "镜像任务未完成",
            isPresented: Binding(
                get: { job.errorMessage != nil }, set: { if !$0 { job.errorMessage = nil } }
            )
        ) {
            Button("知道了") { job.errorMessage = nil }
        } message: {
            Text(job.errorMessage ?? "")
        }
    }

    private var imageProgress: some View {
        StudioPanel(title: "任务进度", symbol: "doc.badge.gearshape") {
            HStack {
                Text(job.status.phase.title).font(.title3.weight(.semibold))
                Spacer()
                if let progress = job.status.progress {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        if job.status.phase.isActive {
                            Text(job.status.isProgressEstimated ? "当前阶段 · 估算" : "当前阶段")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ProgressView(value: job.status.progress ?? (job.isBusy ? nil : 0))
                .accessibilityLabel("当前镜像任务进度")
                .accessibilityValue(
                    job.status.progress.map {
                        "\(job.status.isProgressEstimated ? "估算 " : "")\(Int($0 * 100)) 百分比"
                    } ?? "正在计算")
            Text(job.status.detail).font(.subheadline).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 10) {
                    KeyValueRow(label: "已用时间", value: BurnFormat.duration(job.elapsed(at: context.date)))
                    KeyValueRow(label: "本阶段预计剩余", value: job.remainingTime(at: context.date))
                }
            }
            if let output = job.outputURL {
                HStack {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    Button("用于刻录") {
                        store.mode = .burn
                        store.selectImage(output)
                    }.disabled(store.isBusy)
                }.padding(.top, 4)
            }
            if job.isBusy && job.status.progress == nil {
                Text("当前阶段未提供百分比，请等待系统完成。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if job.isBusy {
                Text(
                    job.status.isProgressEstimated
                        ? "按已生成镜像大小估算，系统完成构建后才会保存。"
                        : "显示当前阶段的进度，进入下一阶段时重新计量。"
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var imageLog: some View {
        StudioPanel(title: "任务记录", symbol: "list.bullet.rectangle") {
            if job.logs.isEmpty {
                Text("开始后显示检查、复制与保存结果。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(job.logs.suffix(8).reversed()) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                }
            }
        }
    }
}

private struct ImageSourcesView: View {
    var job: ImageCreationStore
    let disabled: Bool
    @State private var targeted = false

    var body: some View {
        StudioPanel(title: "光盘内容", symbol: "folder") {
            HStack {
                Button("添加文件或文件夹…") { FilePanels.addDataFiles(job: job) }
                Spacer()
                Button("清空") { job.clearSources() }.disabled(job.sources.isEmpty)
            }.disabled(disabled)
            if job.sources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(StudioStyle.accent)
                    Text("拖入文件或文件夹").font(.headline)
                    Text("支持多选，文件夹保留原有层级。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(job.sources, id: \.self) { url in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(
                                        .secondary
                                    )
                                    .lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    job.removeSource(url)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless).disabled(disabled)
                                .accessibilityLabel("移除 \(url.lastPathComponent)")
                            }.help(url.path)
                        }
                    }
                }.frame(height: 180)
            }
            Text("\(job.sources.count) 个根目录项目 · 创建期间请保持源文件可读")
                .font(.caption).foregroundStyle(.secondary)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioStyle.accent.opacity(targeted ? 1 : 0), lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard !disabled else { return false }
            job.addSources(urls)
            return true
        } isTargeted: {
            targeted = $0
        }
    }
}

private struct DataImageOptionsView: View {
    @Bindable var job: ImageCreationStore
    var body: some View {
        StudioPanel(title: "镜像设置", symbol: "slider.horizontal.3") {
            HStack {
                Text("光盘名称").font(.subheadline)
                TextField("光盘名称", text: $job.volumeName)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("文件系统", selection: $job.fileSystem) {
                ForEach(DataDiscFileSystem.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(job.fileSystem.detail).font(.caption).foregroundStyle(.secondary)
            if let issue = ImagePreflight.volumeNameIssue(job.volumeName) {
                Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
            Text("生成普通数据光盘，不会自动制作启动盘、音频 CD 或 DVD 视频菜单。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DiscCopyOptionsView: View {
    @Bindable var store: BurnStore
    var body: some View {
        @Bindable var job = store.imageCreation
        StudioPanel(title: "来源光盘", symbol: "opticaldiscdrive") {
            HStack {
                Text("光盘驱动器").font(.subheadline)
                Spacer()
                Button("刷新") { store.refreshDevices() }
            }
            if store.devices.isEmpty {
                Text("连接光驱并插入数据光盘后，设备会出现在这里。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Picker("来源光驱", selection: $store.selectedDeviceID) {
                    ForEach(store.devices) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                if let device = store.selectedDevice {
                    KeyValueRow(label: "介质", value: device.media)
                    Text(device.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Picker("镜像格式", selection: $job.copyFormat) {
                ForEach(DiscCopyFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("读取 ISO 9660 / UDF 数据光盘的扇区。暂不支持音频 CD、混合轨道、多会话或受保护光盘。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("复制期间请保持光驱连接，并关闭正在使用光盘的其他应用。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview("文件制作") {
    let store = BurnStore()
    store.mode = .buildISO
    return ImageWorkspaceView(store: store).frame(width: 1050, height: 740)
}

#Preview("光盘复制 · 深色") {
    let store = BurnStore()
    store.mode = .copyDisc
    return ImageWorkspaceView(store: store).preferredColorScheme(.dark).frame(width: 1050, height: 740)
}
