import Foundation

actor ImageFileService {
    private let commands = ImageCommandRunner()
    private let files = FileManager.default

    func build(
        sources: [URL], volumeName: String, fileSystem: DataDiscFileSystem, destination: URL,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        try ImagePreflight.validateSelection(sources, destination: destination)
        if let issue = ImagePreflight.volumeNameIssue(volumeName) { throw ImageCreationError(issue) }
        let work = try workspace(for: destination)
        defer { try? files.removeItem(at: work) }
        let staging = work.appendingPathComponent("content", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        await update(ImageUpdate(.preparing, "检查文件可读性与文件系统限制…"))
        var entries: [StagingEntry] = []
        for source in sources {
            // Directory enumeration canonicalizes ancestors such as /var → /private/var.
            let rootComponents = source.resolvingSymlinksInPath().pathComponents
            for item in try validateTree(source, fileSystem: fileSystem) {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let components = item.resolvingSymlinksInPath().pathComponents
                guard components.starts(with: rootComponents) else {
                    throw ImageCreationError("源文件夹路径发生变化，请重新添加：\(source.lastPathComponent)")
                }
                let relativePath = ([source.lastPathComponent] + components.dropFirst(rootComponents.count))
                    .joined(separator: "/")
                entries.append(
                    StagingEntry(
                        source: item, destination: staging.appendingPathComponent(relativePath),
                        isDirectory: values.isDirectory == true,
                        bytes: values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0)))
            }
        }
        try await stage(entries, fileSystem: fileSystem, update: update)
        // Validate the completed snapshot before passing it to the image builder.
        _ = try validateTree(staging, fileSystem: fileSystem)
        let image = work.appendingPathComponent("image.iso")
        let layoutArguments =
            [staging.path] + fileSystem.arguments
            + ["-default-volume-name", volumeName.trimmingCharacters(in: .whitespacesAndNewlines)]
        await update(ImageUpdate(.building, "正在计算镜像布局与预计大小…"))
        let estimateOutput = try await commands.run(
            "/usr/bin/hdiutil", arguments: ["makehybrid", "-print-size"] + layoutArguments)
        let estimate = ImageSizeEstimate(output: estimateOutput)
        _ = try await commands.run(
            "/usr/bin/hdiutil",
            arguments: ["makehybrid", "-o", image.path] + layoutArguments,
            poll: {
                let attributes = try? FileManager.default.attributesOfItem(atPath: image.path)
                let written = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let total = estimate.map { " / 预计 \(BurnFormat.bytes($0.bytes))" } ?? ""
                await update(
                    ImageUpdate(
                        .building, "已生成 \(BurnFormat.bytes(written))\(total)",
                        progress: estimate?.progress(writtenBytes: written), isProgressEstimated: estimate != nil))
            }
        )
        try await publish(image, to: destination, update: update)
    }

    private struct StagingEntry {
        let source: URL
        let destination: URL
        let isDirectory: Bool
        let bytes: Int64
    }

    private func stage(
        _ entries: [StagingEntry], fileSystem: DataDiscFileSystem,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        let totalBytes = try entries.reduce(Int64(0)) { total, entry in
            let sum = total.addingReportingOverflow(entry.bytes)
            guard !sum.overflow else { throw ImageCreationError("所选文件的总大小超过支持范围。") }
            return sum.partialValue
        }
        var copiedBytes: Int64 = 0
        var lastUpdate = Date.distantPast
        await update(ImageUpdate(.copying, "准备暂存 \(BurnFormat.bytes(totalBytes)) 数据…", progress: 0))
        for entry in entries {
            try Task.checkCancellation()
            try validateItem(entry.source, fileSystem: fileSystem)
            let attributes = try files.attributesOfItem(atPath: entry.source.path)
            let expectedType: FileAttributeType = entry.isDirectory ? .typeDirectory : .typeRegular
            guard attributes[.type] as? FileAttributeType == expectedType else {
                throw ImageCreationError("源文件类型在检查后发生变化：\(entry.source.lastPathComponent)。请重新创建。")
            }
            if entry.isDirectory {
                try files.createDirectory(at: entry.destination, withIntermediateDirectories: true)
                continue
            }
            guard (attributes[.size] as? NSNumber)?.int64Value == entry.bytes else {
                throw ImageCreationError("源文件在检查后发生变化：\(entry.source.lastPathComponent)。请重新创建。")
            }
            let input = try FileHandle(forReadingFrom: entry.source)
            defer { try? input.close() }
            guard files.createFile(atPath: entry.destination.path, contents: nil) else {
                throw ImageCreationError("无法暂存文件：\(entry.source.lastPathComponent)")
            }
            let output = try FileHandle(forWritingTo: entry.destination)
            defer { try? output.close() }
            var remaining = entry.bytes
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Int(min(1_048_576, remaining))), !data.isEmpty else {
                    throw ImageCreationError("源文件读取提前结束：\(entry.source.lastPathComponent)")
                }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
                copiedBytes += Int64(data.count)
                if Date().timeIntervalSince(lastUpdate) >= 0.15 {
                    await update(
                        ImageUpdate(
                            .copying,
                            "暂存 \(entry.source.lastPathComponent) · \(BurnFormat.bytes(copiedBytes)) / \(BurnFormat.bytes(totalBytes))",
                            progress: totalBytes > 0 ? Double(copiedBytes) / Double(totalBytes) : 0))
                    lastUpdate = .now
                }
            }
            let current = try files.attributesOfItem(atPath: entry.source.path)
            guard (current[.size] as? NSNumber)?.int64Value == entry.bytes,
                current[.modificationDate] as? Date == attributes[.modificationDate] as? Date
            else { throw ImageCreationError("源文件在复制期间发生变化：\(entry.source.lastPathComponent)。请重新创建。") }
            // Keep ordinary file dates/modes; optical data images intentionally omit xattrs and resource forks.
            try files.setAttributes(
                attributes.filter { $0.key == .posixPermissions || $0.key == .modificationDate },
                ofItemAtPath: entry.destination.path)
        }
        try Task.checkCancellation()
        await update(ImageUpdate(.copying, "暂存完成 · \(BurnFormat.bytes(copiedBytes))", progress: 1))
    }

    func copyDisc(
        device: DiscDevice, format: DiscCopyFormat, destination: URL,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        if let issue = ImagePreflight.copyIssue(device: device) { throw ImageCreationError(issue) }
        guard let name = device.mediaBSDName,
            name.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        else { throw ImageCreationError("系统未提供有效的完整光盘设备地址。") }
        let source = URL(fileURLWithPath: "/dev/\(name)")
        // DiscRecording supplies the node, never an arbitrary disk selected by the user.
        // Verify readable ISO/UDF sectors before creating any image, excluding audio CDs.
        guard try Self.hasDataDiscSignature(source) else {
            throw ImageCreationError("仅支持 ISO 9660 / UDF 数据光盘；音频 CD、混合轨道和其他文件系统暂不支持。")
        }
        let work = try workspace(for: destination)
        defer { try? files.removeItem(at: work) }
        let rawImage = work.appendingPathComponent("disc.cdr")
        await update(ImageUpdate(.copying, "从 \(device.name) 读取光盘扇区…"))
        let infoData = try await commands.run("/usr/sbin/diskutil", arguments: ["info", "-plist", source.path])
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        guard let bytes = (info?["TotalSize"] as? NSNumber)?.uint64Value, bytes > 0,
            info?["DeviceIdentifier"] as? String == name
        else { throw ImageCreationError("无法确定来源光盘的完整扇区大小。") }
        try await copySectors(from: source, to: rawImage, bytes: bytes, update: update)
        let image: URL
        if format == .dmg {
            image = work.appendingPathComponent("image.dmg")
            await update(ImageUpdate(.building, "光盘读取完成，正在压缩 DMG…"))
            _ = try await commands.run(
                "/usr/bin/hdiutil",
                arguments: [
                    "convert", rawImage.path, "-format", "UDZO", "-puppetstrings", "-o", image.path,
                ]
            ) { progress in
                await update(ImageUpdate(.building, "正在压缩 DMG…", progress: progress))
            }
        } else {
            image = rawImage
        }
        if format != .dmg, try !Self.hasDataDiscSignature(image) {
            throw ImageCreationError("复制结果没有有效的数据光盘标识，未保存为镜像。")
        }
        try await publish(image, to: destination, update: update)
    }

    private func copySectors(
        from source: URL, to output: URL, bytes: UInt64,
        update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard files.createFile(atPath: output.path, contents: nil) else {
            throw ImageCreationError("无法创建光盘镜像临时文件。")
        }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var copied: UInt64 = 0
        var lastUpdate = Date.distantPast
        while copied < bytes {
            try Task.checkCancellation()
            let count = Int(min(1_048_576, bytes - copied))
            guard let data = try input.read(upToCount: count), !data.isEmpty else {
                throw ImageCreationError("光盘读取提前结束，未保存不完整的镜像。")
            }
            try writer.write(contentsOf: data)
            copied += UInt64(data.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.15 || copied == bytes {
                await update(
                    ImageUpdate(
                        .copying,
                        "已读取 \(BurnFormat.bytes(Int64(clamping: copied))) / \(BurnFormat.bytes(Int64(clamping: bytes)))",
                        progress: Double(copied) / Double(bytes)))
                lastUpdate = .now
            }
        }
        try Task.checkCancellation()
        try writer.synchronize()
    }

    private func workspace(for destination: URL) throws -> URL {
        guard destination.isFileURL else { throw ImageCreationError("请选择本地保存位置。") }
        let attributes = try? files.attributesOfItem(atPath: destination.path)
        if let attributes, attributes[.type] as? FileAttributeType != .typeRegular {
            throw ImageCreationError("保存位置必须是普通文件，不能替换文件夹或符号链接。")
        }
        let work = destination.deletingLastPathComponent()
            .appendingPathComponent(".DiscStudio-\(UUID())", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: false)
        return work
    }

    private func publish(
        _ image: URL, to destination: URL, update: @Sendable (ImageUpdate) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ImageCreationError("系统未生成有效的镜像文件。") }
        await update(ImageUpdate(.finishing, "正在保存到 \(destination.lastPathComponent)…"))
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: image)
        } else {
            try files.moveItem(at: image, to: destination)
        }
    }

    private func validateTree(_ source: URL, fileSystem: DataDiscFileSystem) throws -> [URL] {
        try validateItem(source, fileSystem: fileSystem)
        var items = [source]
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            // Throw on traversal errors instead of quietly omitting unreadable subdirectories.
            var traversalError: (any Error)?
            guard
                let enumerator = files.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    errorHandler: { _, error in
                        traversalError = error
                        return false
                    }
                )
            else { throw ImageCreationError("无法读取文件夹：\(source.lastPathComponent)") }
            for case let item as URL in enumerator {
                try validateItem(item, fileSystem: fileSystem)
                items.append(item)
            }
            if let traversalError { throw traversalError }
        }
        return items
    }

    private func validateItem(_ url: URL, fileSystem: DataDiscFileSystem) throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw ImageCreationError("无法将符号链接或特殊文件加入数据光盘：\(url.lastPathComponent)。请添加实际文件。")
        }
        guard files.isReadableFile(atPath: url.path) else {
            throw ImageCreationError("没有读取权限：\(url.lastPathComponent)")
        }
        if fileSystem == .isoJoliet {
            if (values.fileSize ?? 0) >= 4_294_967_296 {
                throw ImageCreationError("“\(url.lastPathComponent)”达到 4 GB，请切换到 UDF 文件系统。")
            }
            if url.lastPathComponent.utf16.count > 64 {
                throw ImageCreationError("“\(url.lastPathComponent)”的名称超过 Joliet 限制，请切换到 UDF 文件系统。")
            }
        }
    }

    /// Recognizes the sector-aligned ISO volume descriptor or UDF recognition sequence.
    static func hasDataDiscSignature(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 16 * 2048)
        let data = try handle.read(upToCount: 16 * 2048) ?? Data()
        for offset in stride(from: 0, to: data.count, by: 2048) where offset + 6 <= data.count {
            let marker = String(decoding: data[(offset + 1)..<(offset + 6)], as: UTF8.self)
            if ["CD001", "NSR02", "NSR03"].contains(marker) { return true }
        }
        return false
    }
}
