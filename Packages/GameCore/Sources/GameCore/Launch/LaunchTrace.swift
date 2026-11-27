import Foundation

/// A timeline of a Steam game's launch, written next to its log as `launch-tracking.log`: where the
/// launch was and which programs ran, whenever either changed.
struct LaunchTrace: Sendable {
    private let file: URL
    private var last = ""

    init(besides log: URL) {
        file = log.deletingLastPathComponent().appending(path: "launch-tracking.log")
        append("# \(log.lastPathComponent)")
    }

    /// Writes `state` unless it is the one written last.
    mutating func note(_ state: String) {
        guard state != last else { return }
        last = state
        append(state)
    }

    /// The programs of `processes` that matter here: Wine's own services (`C:\windows`) don't.
    static func programs(_ processes: [BottleProcesses.Entry]) -> String {
        Set(processes.filter { !$0.isWineService }.map(\.fileName)).sorted().joined(separator: " ")
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func append(_ line: String) {
        let data = Data("\(Self.time.string(from: .now)) \(line)\n".utf8)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
