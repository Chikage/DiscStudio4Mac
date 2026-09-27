import Darwin
import Foundation

/// Runs only explicit executables and arguments, without shell interpolation or pipe backpressure.
actor ImageCommandRunner {
    func run(
        _ executable: String, arguments: [String],
        progress: @Sendable (Double?) async -> Void = { _ in },
        poll: @Sendable () async -> Void = {}
    ) async throws -> Data {
        try Task.checkCancellation()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("DiscStudio-command-\(UUID()).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw ImageCreationError("无法创建镜像任务的临时日志。")
        }
        defer { try? FileManager.default.removeItem(at: log) }
        let writer = try FileHandle(forWritingTo: log)
        let reader = try FileHandle(forReadingFrom: log)
        defer {
            try? writer.close()
            try? reader.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = writer
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        var output = Data()
        var pending = ""
        do {
            repeat {
                let data = try reader.readToEnd() ?? Data()
                output.append(data)
                if output.count > 1_048_576 { output = Data(output.suffix(1_048_576)) }
                pending += String(decoding: data, as: UTF8.self)
                while let boundary = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(pending[..<boundary])
                    pending.removeSubrange(...boundary)
                    if let value = Self.percentage(line) { await progress(value < 0 ? nil : value) }
                }
                if pending.count > 8192 { pending = String(pending.suffix(8192)) }
                try Task.checkCancellation()
                await poll()
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(150))
            } while true
            let finalData = try reader.readToEnd() ?? Data()
            output.append(finalData)
            pending += String(decoding: finalData, as: UTF8.self)
            for line in pending.split(whereSeparator: \.isNewline) {
                if let value = Self.percentage(String(line)) { await progress(value < 0 ? nil : value) }
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            // Await exit before removing staging files or reporting that cancellation finished.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning {
                if Date() >= deadline { kill(process.processIdentifier, SIGKILL) }
                // A detached wait is deliberately not cancelled with the image task.
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
            }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output.suffix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImageCreationError(detail.isEmpty ? "系统镜像工具失败（\(process.terminationStatus)）。" : detail)
        }
        return output
    }

    /// -1 is the documented indeterminate sentinel; no guessed overall percentages.
    static func percentage(_ line: String) -> Double? {
        guard line.hasPrefix("PERCENT:"),
            let value = Double(line.dropFirst(8).trimmingCharacters(in: .whitespaces)), value.isFinite
        else { return nil }
        return value < 0 ? -1 : min(1, value / 100)
    }
}
