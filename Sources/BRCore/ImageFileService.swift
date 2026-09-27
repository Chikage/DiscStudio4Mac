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
        for source in sources { try validateTree(source, fileSystem: fileSystem) }
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            await update(ImageUpdate(.copying, "暂存 \(index + 1)/\(sources.count)：\(source.lastPathComponent)"))
            _ = try await commands.run(
                "/usr/bin/ditto",
                arguments: [
                    "--norsrc", "--noextattr", "--noacl", source.path,
                    staging.appendingPathComponent(source.lastPathComponent).path,
                ])
        }
        // Validate the actual snapshot too, including files created while the sources were copied.
        try validateTree(staging, fileSystem: fileSystem)
        let image = work.appendingPathComponent("image.iso")
        await update(ImageUpdate(.building, "正在构建 \(fileSystem.title) 镜像…"))
        _ = try await commands.run(
            "/usr/bin/hdiutil",
            arguments: ["makehybrid", "-o", image.path, staging.path] + fileSystem.arguments
                + ["-default-volume-name", volumeName.trimmingCharacters(in: .whitespacesAndNewlines)]
        )
        try await publish(image, to: destination, update: update)
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

    private func validateTree(_ source: URL, fileSystem: DataDiscFileSystem) throws {
        try validateItem(source, fileSystem: fileSystem)
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
            for case let item as URL in enumerator { try validateItem(item, fileSystem: fileSystem) }
            if let traversalError { throw traversalError }
        }
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
