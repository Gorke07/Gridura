import Foundation
import os.log

/// File logger, `~/Library/Application Support/app.gridura.Gridura/Logs/app-yyyy-MM-dd.log`,
/// 7-day retention.
final class LogManager {
    static let shared = LogManager()

    enum Level: String {
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    let maxRetentionDays = 7
    let fileExtension = "log"
    let dateFormat = "yyyy-MM-dd"

    private let writeQueue = DispatchQueue(label: "com.griduraapp.logger")
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var fileHandle: FileHandle?
    private var currentDayString: String?

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("app.gridura.Gridura/Logs", isDirectory: true)
    }

    private init() {}

    func log(_ level: Level, _ message: String) {
        let stamp = timestampFormatter.string(from: Date())
        let line = "\(stamp) [\(level.rawValue)] \(message)\n"
        writeQueue.async { [weak self] in self?.write(line) }
    }

    func info(_ message: String) { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }

    /// Packages today's log file into a `.zip` next to the Logs directory.
    enum LogExportError: LocalizedError {
        case noLogFile
        case packagingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noLogFile: return NSLocalizedString("No log file", comment: "")
            case .packagingFailed(let error): return String(format: NSLocalizedString("Failed to package log file: %@", comment: ""), error.localizedDescription)
            }
        }
    }

    func export() throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == fileExtension } ?? []
        guard !files.isEmpty else { throw LogExportError.noLogFile }

        let stamp = dayFormatter.string(from: Date())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gridura-Logs-\(stamp).zip")
        try? FileManager.default.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directoryURL.path, destination.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LogExportError.packagingFailed(error)
        }
        guard process.terminationStatus == 0 else {
            throw LogExportError.packagingFailed(NSError(domain: "Gridura", code: Int(process.terminationStatus)))
        }
        return destination
    }

    private func write(_ line: String) {
        let day = dayFormatter.string(from: Date())
        if currentDayString != day {
            fileHandle?.closeFile()
            fileHandle = nil
            currentDayString = day
            cleanupOldFiles()
        }
        guard let handle = openHandle(forDay: day) else { return }
        if let data = line.data(using: .utf8) {
            do { try handle.write(contentsOf: data) }
            catch { os_log("LogManager Error: Failed to write data: %{public}@", "\(error)") }
        }
    }

    private func openHandle(forDay day: String) -> FileHandle? {
        if let h = fileHandle { return h }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let url = directoryURL.appendingPathComponent("app-\(day).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            fileHandle = h
            return h
        } catch {
            os_log("LogManager Error: Failed to open file handle: %{public}@", "\(error)")
            return nil
        }
    }

    private func cleanupOldFiles() {
        let cutoff = Date().addingTimeInterval(-Double(maxRetentionDays) * 86_400)
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys)
        else { return }
        for file in files where file.pathExtension == fileExtension {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let created = values.creationDate, created < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
            os_log("LogManager: Removed old log file: %{public}@", file.lastPathComponent)
        }
    }
}
