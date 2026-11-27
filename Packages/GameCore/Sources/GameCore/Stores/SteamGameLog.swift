import Foundation

/// Steam's own account of a game's programs, from `logs/gameprocess_log.txt`. Steam adds a line for
/// each program it follows for the game, the one it started and the ones those start
/// (`AppID 1174180 adding PID 300 as a tracked process ""C:\…\RDR2.exe" -args"`), and one when it
/// stops following a program: it exited (`AppID 1174180 no longer tracking PID 300, exit code 0`),
/// or still runs as the game ends (`Game 1174180 going away; no longer tracking PID 940`). At
/// `Remove 1174180 from running list` the game has ended, and Steam's library shows Play again.
/// The PIDs are Windows', not the Mac's, so a program is known by its path. The log holds every
/// earlier launch too: only what Steam writes after `init` counts.
struct SteamGameLog {
    struct Program: Equatable, Sendable {
        /// The process id in Windows, as Steam has it.
        var pid: Int
        /// As Steam wrote it: `C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\RDR2.exe`.
        var path: String
    }

    let file: URL
    private let appID: String
    private var offset: UInt64
    /// What Steam follows for the game now, in the order they started.
    private(set) var programs: [Program] = []
    /// Everything Steam followed for the game since `init`, in the order they started.
    private(set) var started: [Program] = []
    /// Steam ended the game after starting it, and hasn't started it again.
    private(set) var hasEnded = false

    /// More than this written between two looks is skipped: the latest lines are at the end.
    private static let maxRead: UInt64 = 256 * 1024

    init(steamRoot: URL, appID: String) {
        file = steamRoot.appending(path: "logs/gameprocess_log.txt")
        self.appID = appID
        offset = Self.size(of: file)
    }

    /// Reads what Steam wrote since the last call; true when that said something of the game. A
    /// line is read once it is complete.
    @discardableResult
    mutating func update() -> Bool {
        let size = Self.size(of: file)
        // A new log: Steam started over.
        if size < offset { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let skipped = size - offset > Self.maxRead
        let start = skipped ? size - Self.maxRead : offset
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)),
              let end = data.lastIndex(of: 0x0A) else { return false }
        offset = start + UInt64(data.distance(from: data.startIndex, to: end)) + 1
        var text = String(decoding: data[..<end], as: UTF8.self)
        // Skipping ahead lands in the middle of a line.
        if skipped, let newline = text.firstIndex(where: \.isNewline) { text = String(text[text.index(after: newline)...]) }
        return ingest(text)
    }

    /// Takes in lines of the log; true when one was about the game.
    @discardableResult
    mutating func ingest(_ text: String) -> Bool {
        var changed = false
        // Steam ends its lines with "\r\n", one Character in Swift: splitting at "\n" wouldn't.
        for line in text.split(whereSeparator: \.isNewline) {
            if let program = Self.added(in: line, marker: "AppID \(appID) adding PID ") {
                programs.append(program)
                started.append(program)
                hasEnded = false
            } else if let pid = Self.number(after: "AppID \(appID) no longer tracking PID ", in: line)
                        ?? Self.number(after: "Game \(appID) going away; no longer tracking PID ", in: line) {
                if let index = programs.lastIndex(where: { $0.pid == pid }) { programs.remove(at: index) }
            } else if line.contains("Remove \(appID) from running list") {
                programs = []
                hasEnded = !started.isEmpty
            } else {
                continue
            }
            changed = true
        }
        return changed
    }

    /// `<marker>300 as a tracked process ""C:\…\RDR2.exe" -args"`: the program is the first word
    /// in the quotes, itself quoted when its path has spaces.
    private static func added(in line: Substring, marker: String) -> Program? {
        guard let pid = number(after: marker, in: line),
              let found = line.range(of: "as a tracked process \"") else { return nil }
        let command = line[found.upperBound...]
        let path = command.hasPrefix("\"") ? command.dropFirst().prefix { $0 != "\"" } : command.prefix { $0 != " " && $0 != "\"" }
        return path.isEmpty ? nil : Program(pid: pid, path: String(path))
    }

    private static func number(after marker: String, in line: Substring) -> Int? {
        guard let found = line.range(of: marker) else { return nil }
        return Int(line[found.upperBound...].prefix(while: \.isNumber))
    }

    /// Not `URL.resourceValues`: a URL keeps the size it read first.
    private static func size(of file: URL) -> UInt64 {
        var info = stat()
        return stat(file.path, &info) == 0 ? UInt64(info.st_size) : 0
    }
}
