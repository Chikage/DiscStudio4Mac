import Foundation

public enum StudioMode: String, CaseIterable, Sendable {
    case burn, copyDisc, buildISO

    public var title: String {
        switch self {
        case .burn: "镜像刻录"
        case .copyDisc: "光盘转镜像"
        case .buildISO: "文件制作 ISO"
        }
    }
}

public enum DiscCopyFormat: String, CaseIterable, Sendable {
    case iso, cdr, dmg
    public var title: String {
        switch self {
        case .iso: "ISO · 数据光盘"
        case .cdr: "CDR · DVD/CD 主映像"
        case .dmg: "DMG · 压缩镜像"
        }
    }
}

public enum DataDiscFileSystem: String, CaseIterable, Sendable {
    case isoJoliet, udf
    public var title: String {
        switch self {
        case .isoJoliet: "ISO 9660 + Joliet · 广泛兼容"
        case .udf: "UDF · 支持大文件和长文件名"
        }
    }
    public var detail: String {
        switch self {
        case .isoJoliet: "适合通用数据光盘。单个文件须小于 4 GB，名称最多 64 个 UTF-16 字符。"
        case .udf: "适合 DVD / BD 数据归档，支持 4 GB 及以上文件。输出扩展名仍为 .iso。"
        }
    }
    var arguments: [String] { self == .isoJoliet ? ["-iso", "-joliet"] : ["-udf"] }
}

public enum ImagePhase: String, Sendable {
    case idle, preparing, copying, building, finishing, completed, failed, cancelled
    public var title: String {
        switch self {
        case .idle: "等待开始"
        case .preparing: "正在检查源文件"
        case .copying: "正在复制数据"
        case .building: "正在生成镜像"
        case .finishing: "正在保存镜像"
        case .completed: "镜像已保存"
        case .failed: "镜像创建失败"
        case .cancelled: "已取消"
        }
    }
    public var isActive: Bool { [.preparing, .copying, .building, .finishing].contains(self) }
}

public struct ImageUpdate: Sendable {
    public let phase: ImagePhase
    public let detail: String
    public let progress: Double?
    public init(_ phase: ImagePhase, _ detail: String, progress: Double? = nil) {
        self.phase = phase
        self.detail = detail
        self.progress = progress
    }
}

struct ImageCreationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

public enum ImagePreflight {
    public static func copyIssue(device: DiscDevice?) -> String? {
        guard let device else { return "连接并选择一个光盘驱动器。" }
        guard !device.busy else { return "光驱正忙，请等待当前任务完成。" }
        guard device.present, !device.blank else { return "请插入需要复制的数据光盘。" }
        guard device.mediaBSDName != nil else { return "系统尚未提供可读取的光盘，请稍后刷新。" }
        guard device.mediaTrackCount <= 1, device.mediaSessionCount <= 1 else {
            return "暂不支持多轨或多会话光盘，请使用单轨数据光盘。"
        }
        return nil
    }

    public static func volumeNameIssue(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 32,
            name.rangeOfCharacter(from: .controlCharacters) == nil,
            !name.contains("/"), !name.contains(":")
        else { return "光盘名称需为 1–32 个字符，不能包含斜杠、冒号或控制字符。" }
        return nil
    }

    static func validateSelection(_ sources: [URL], destination: URL) throws {
        guard !sources.isEmpty else { throw ImageCreationError("请至少添加一个文件或文件夹。") }
        let output = destination.resolvingSymlinksInPath().standardizedFileURL.path
        var names = Set<String>()
        for source in sources {
            guard source.isFileURL else { throw ImageCreationError("仅支持本地文件和文件夹。") }
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard output != path, !output.hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
                throw ImageCreationError("镜像不能保存在选中的源文件夹内，也不能覆盖源文件。")
            }
            let name = source.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(name).inserted else {
                throw ImageCreationError("根目录存在同名项目“\(source.lastPathComponent)”。请先重命名或移除其中一个。")
            }
        }
    }
}
