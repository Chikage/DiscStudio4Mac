import AppKit
import BRCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct BRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = BurnStore()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        Window("Disc Studio · 光盘与镜像", id: "main") {
            WorkspaceView(store: store)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .task {
                    delegate.store = store
                    store.connect()
                    if CommandLine.arguments.contains("--demo") { store.startDemo() }
                }
                .onOpenURL {
                    guard !store.isBusy, !store.isDemo else { return }
                    store.mode = .burn
                    store.selectImage($0)
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开光盘镜像…") { FilePanels.chooseImage(store: store) }
                    .keyboardShortcut("o").disabled(store.isBusy || store.isDemo)
                Button("从光盘创建镜像") { store.mode = .copyDisc }
                    .disabled(store.isBusy || store.isDemo || store.isLoadingImage)
                Button("从文件创建 ISO") { store.mode = .buildISO }
                    .keyboardShortcut("n").disabled(store.isBusy || store.isDemo || store.isLoadingImage)
            }
            CommandMenu("刻录") {
                Button("刷新刻录设备") { store.refreshDevices() }
                    .keyboardShortcut("r").disabled(store.isBusy || store.isDemo)
                Button("导出任务日志…") { FilePanels.exportLog(store: store) }
                Divider()
                Button("运行界面演示") { store.startDemo() }
                    .disabled(store.isBusy || store.isLoadingImage)
            }
            CommandGroup(after: .toolbar) {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: BurnStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.isBusy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "光盘任务仍在进行"
        alert.informativeText = "请先在窗口中停止当前任务，并等待清理完成后再退出。"
        alert.addButton(withTitle: "返回任务")
        alert.runModal()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        store?.isBusy != true
    }
}

@MainActor
enum FilePanels {
    static func chooseImage(store: BurnStore) {
        guard !store.isBusy, !store.isDemo else { return }
        let panel = NSOpenPanel()
        panel.title = "选择光盘镜像"
        panel.message = "支持 ISO、DMG、CDR、CUE、TOC。CUE/TOC 引用的数据文件需保持在原位置。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url, !store.isBusy, !store.isDemo {
                store.mode = .burn
                store.selectImage(url)
            }
        }
    }

    static func addDataFiles(job: ImageCreationStore) {
        guard !job.isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "添加数据光盘内容"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { result in
            if result == .OK { job.addSources(panel.urls) }
        }
    }

    static func saveImage(store: BurnStore) {
        guard !store.isBusy, !store.isLoadingImage, !store.isDemo else { return }
        let mode = store.mode
        let job = store.imageCreation
        let extensionName = mode == .buildISO ? "iso" : job.copyFormat.rawValue
        let panel = NSSavePanel()
        panel.title = mode == .buildISO ? "创建数据光盘 ISO" : "保存光盘镜像"
        panel.nameFieldStringValue = mode == .buildISO ? "\(job.volumeName).iso" : "光盘副本.\(extensionName)"
        panel.allowedContentTypes = [UTType(filenameExtension: extensionName) ?? .diskImage]
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url, store.mode == mode else { return }
            store.createImage(to: url)
        }
    }

    static func exportLog(store: BurnStore) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Disc Studio-刻录日志.txt"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do { try store.logText.write(to: url, atomically: true, encoding: .utf8) } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
