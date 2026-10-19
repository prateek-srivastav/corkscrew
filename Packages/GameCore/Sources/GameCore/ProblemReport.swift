import Foundation

/// A report about a crash or an error, which the user reads before sending it anywhere: what
/// happened, Corkscrew and the Mac, the program and its settings, Wine's backtrace and the end of
/// the log. Paths in the home folder show as `~/…`, and the user name as `<user>`.
public struct ProblemReport: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// A Windows program crashed (Wine's backtrace is in its log, or its own handler wrote a crash
        /// dump), or Wine itself did, or the program showed an error and quit. (The relay accepts only
        /// these four kinds.)
        case crash
        /// A program didn't start.
        case launchFailed
        /// An action in Corkscrew failed.
        case error
        /// Corkscrew itself quit unexpectedly (macOS's crash report).
        case appCrash
    }

    public var kind: Kind
    public var title: String
    /// One line: Wine's "Unhandled …" line, the exception in a crash dump, the program's error
    /// dialog, or the error message.
    public var summary: String
    /// "Name: value" lines: Corkscrew and the Mac, then the program and its settings.
    public var details: [String]
    public var backtrace: String?
    /// The end of the program's log.
    public var log: String?
    /// What the user was doing, if they say.
    public var note = ""
    public var date = Date()

    public init(kind: Kind, title: String, summary: String, details: [String], backtrace: String? = nil, log: String? = nil) {
        self.kind = kind
        self.title = title
        self.summary = Self.redacted(summary)
        self.details = details.map { Self.redacted($0) }
        self.backtrace = backtrace.map { Self.redacted($0) }
        self.log = log.map { Self.redacted($0) }
    }

    // MARK: Text

    /// The whole report, as Markdown: what the user reads, copies, and pastes into an issue.
    public var text: String {
        var parts = ["## \(title)", summary]
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append("**What I was doing:** \(note)") }
        parts.append("### Details\n" + details.map { "- \($0)" }.joined(separator: "\n"))
        if let backtrace { parts.append("### Backtrace\n```\n\(backtrace)\n```") }
        if let log { parts.append("### Log (the end)\n```\n\(log)\n```") }
        return parts.joined(separator: "\n\n")
    }

    /// A new issue on the repository's Bug report form, filled in. GitHub takes URLs up to about
    /// 8,000 characters, so the backtrace and log are cut to fit; the app copies the whole report
    /// to the clipboard for the rest.
    public func issueURL(repository: URL, backend: String? = nil, fromSource: Bool = false, limit: Int = 7_500) -> URL {
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [(String, String)] = [
            ("template", "bug_report.yml"),
            ("title", title),
            ("what", ([summary] + (note.isEmpty ? [] : ["What I was doing: \(note)"])).joined(separator: "\n\n")),
            ("steps", note.isEmpty ? "(Corkscrew offered this report after the \(kind == .appCrash ? "crash" : "problem").)" : note),
            ("version", details.first { $0.hasPrefix("Corkscrew: ") }.map { String($0.dropFirst(11)) } ?? ""),
            ("install", fromSource ? "Built from source" : "Terminal install (curl)"),
            ("mac", details.filter { $0.hasPrefix("Mac: ") || $0.hasPrefix("macOS: ") }.map { $0.split(separator: " ", maxSplits: 1)[1] }
                .joined(separator: ", ")),
        ]
        if let backend { fields.append(("backend", backend)) }
        let head = "### Details\n" + details.map { "- \($0)" }.joined(separator: "\n")
        let cut = "\n… (cut to fit the link: the whole report is on the clipboard, paste it here)"
        func url(logs: String) -> URL {
            components.queryItems = (fields + [("logs", logs)]).map { URLQueryItem(name: $0.0, value: $0.1) }
            return components.url!
        }
        let body = [head, backtrace.map { "Backtrace:\n\($0)" }, log.map { "Log (the end):\n\($0)" }].compactMap { $0 }.joined(separator: "\n\n")
        // Cut from the end until the encoded URL fits.
        var length = body.count
        while url(logs: String(body.prefix(length)) + (length < body.count ? cut : "")).absoluteString.count > limit, length > 0 {
            length = max(0, length - max(200, (length / 10)))
        }
        return url(logs: String(body.prefix(length)) + (length < body.count ? cut : ""))
    }

    // MARK: Sending

    /// Where Send Report posts reports: the Cloudflare Worker in `relay/`, which keeps the whole
    /// report (the backtrace and log too) privately and opens a public GitHub issue with a summary.
    /// Nil: the app opens a filled-in GitHub issue instead.
    public static let relayURL: URL? = URL(string: "https://corkscrew-relay.corkscrew-relay.workers.dev/")

    /// The report as JSON, for the server at `relay`.
    public func request(to relay: URL) throws -> URLRequest { try Self.post(self, to: relay) }

    /// Posts the report. The server answers `{"issue": "<link>"}` with the issue it opened, if any.
    public func send(to relay: URL) async throws -> URL? { try await Self.send(request(to: relay)) }

    /// `value` as JSON, posted to the relay: a report, or settings a player shares.
    static func post(_ value: some Encodable, to url: URL) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(value)
        return request
    }

    /// Sends a request from `post(_:to:)`. Throws unless the relay answers 2xx; returns the issue's link, if any.
    static func send(_ request: URLRequest) async throws -> URL? {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (answer?["issue"] as? String).flatMap(URL.init(string:))
    }

    // MARK: Wine crashes

    /// The last crash in a launch log: Wine's "Unhandled …" line and winedbg's backtrace after it,
    /// up to its system information. Reads only the end of the file (launch logs can be hundreds
    /// of MB with Wine's debug channels on). Nil when the program didn't crash.
    public static func crash(inLog url: URL, maxBytes: Int = 4 << 20) -> (summary: String, backtrace: String)? {
        tail(of: url, maxBytes: maxBytes).flatMap(crash(in:))
    }

    /// Lines that start a crash in Wine's output.
    static let crashMarkers = ["wine: Unhandled", "Unhandled exception:", "to unimplemented function", "err:seh:NtRaiseException"]
    /// Crashes of Steam's web pages (its browser), which Steam restarts: not the program's.
    static let ignoredCrashModules = ["steamwebhelper", "libcef"]

    static func crash(in text: String) -> (summary: String, backtrace: String)? {
        // Windows programs end lines with \r\n, which Swift counts as one Character: split on any newline.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var end = lines.endIndex
        // From the last crash back, skipping the ones in Steam's web helper.
        while let start = lines[..<end].lastIndex(where: { line in crashMarkers.contains { line.contains($0) } }) {
            // winedbg's "Unhandled exception:" follows Wine's own "wine: Unhandled" line: start at the first.
            var first = start
            while first > lines.startIndex, crashMarkers.contains(where: { lines[first - 1].contains($0) }) { first -= 1 }
            // winedbg lists every loaded module, often hundreds; its system information ends the block.
            var last = min(lines.endIndex, start + 3_000)
            if let info = lines[start..<last].firstIndex(where: { $0.contains("System information:") }) {
                last = min(lines.endIndex, info + 6)
            }
            let block = lines[first..<last].joined(separator: "\n")
            if !ignoredCrashModules.contains(where: { block.contains("in \($0)") }) {
                return (String(lines[first]).trimmingCharacters(in: .whitespaces), block)
            }
            end = first
        }
        return nil
    }

    // MARK: Error dialogs

    /// What Wine's `msgbox` debug channel (WINEDEBUG `+msgbox`) prints for each message box, the
    /// dialog Windows programs show their errors in: `00d0:trace:msgbox:MSGBOX_OnInit L"text"`.
    static let dialogMarker = #"trace:msgbox:MSGBOX_OnInit L""#

    /// The text of the last message box in a launch log, on one line. Nil when the program showed
    /// none, or when the last one asked a question ("Exit Setup?"): quitting was then the answer.
    public static func errorDialog(inLog url: URL, maxBytes: Int = 4 << 20) -> String? {
        tail(of: url, maxBytes: maxBytes).flatMap(errorDialog(in:))
    }

    static func errorDialog(in text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.contains(dialogMarker) }),
              let start = line.range(of: dialogMarker)?.upperBound else { return nil }
        let message = unquoted(line[start...]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !message.isEmpty, !message.hasSuffix("?"), !message.hasSuffix("？") else { return nil }
        return message
    }

    /// Wine's quoted text (`debugstr_w`) up to its closing quote: `\n`, `\r`, `\t`, `\"`, `\\`, and
    /// `\XXXX` (a UTF-16 unit in hex) for any other character outside ASCII. Wine cuts long texts,
    /// marked by `...` after the quote.
    static func unquoted(_ text: Substring) -> String {
        var units: [UInt16] = []
        var rest = text
        while let c = rest.popFirst() {
            if c == "\"" {
                if rest.hasPrefix("...") { units += "…".utf16 }
                break
            }
            guard c == "\\", let e = rest.popFirst() else {
                units += String(c).utf16
                continue
            }
            switch e {
            case "n", "r", "t": units += " ".utf16
            case "\"", "\\": units += String(e).utf16
            default:
                let hex = String(e) + rest.prefix(3)
                if hex.count == 4, hex.allSatisfy(\.isHexDigit), let unit = UInt16(hex, radix: 16) {
                    units.append(unit)
                    rest = rest.dropFirst(3)
                } else {
                    units += "\\\(e)".utf16
                }
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Crash dumps

    /// Where a game's crash handler may write dumps: the game's folder and the bottle's user folders
    /// (AppData, Documents). A Steam game's folder is its install folder, and Steam's crash handler,
    /// which games can use too, writes to Steam's `dumps` folder. None for Steam itself.
    public static func dumpFolders(for game: Game, prefix: URL) -> [URL] {
        let folder = game.executable.deletingLastPathComponent()
        let users = prefix.appending(path: "drive_c/users", directoryHint: .isDirectory)
        guard let store = game.store else { return [folder, users] }
        guard let appID = store.appID else { return [] }
        let installed = Steam.installedApps(steamRoot: folder, prefix: prefix).first { $0.appID == appID }
        return (installed.map { [$0.installFolder] } ?? []) + [folder.appending(path: "dumps", directoryHint: .isDirectory), users]
    }

    /// The newest crash dump (`*.dmp`, `*.mdmp`) changed since `since` in `folders` and their
    /// subfolders (not through links) that one of `executables` (file names) wrote of itself
    /// with its own crash handler, which Wine's log doesn't show. Helpers (Steam, launchers, crash
    /// reporters) write dumps too: their first module is another program. `file` is the dump's name,
    /// with the Mac's name (some handlers put the computer name in it) as `<host>`. `wrote` is the
    /// address an access violation wrote to.
    public static func crashDump(in folders: [URL], since: Date, executables: [String], host: String? = nil)
        -> (summary: String, file: String, wrote: UInt64?)? {
        var dumps: [(url: URL, date: Date)] = []
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            // A pool per file: the enumerator's objects are autoreleased, and a game's folder with
            // 100,000 files would keep them all until the search ends.
            var more = true
            while more {
                more = autoreleasepool {
                    guard let url = files.nextObject() as? URL else { return false }
                    if ["dmp", "mdmp"].contains(url.pathExtension.lowercased()),
                       let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date >= since {
                        dumps.append((url, date))
                    }
                    return true
                }
            }
        }
        let host = host ?? hostName
        for dump in dumps.sorted(by: { $0.date > $1.date }) {
            guard let data = try? Data(contentsOf: dump.url, options: .alwaysMapped),
                  let crash = executables.lazy.compactMap({ crashDump(data, executable: $0) }).first else { continue }
            let file = dump.url.lastPathComponent
            return (crash.summary, host.count < 3 ? file : file.replacingOccurrences(of: host, with: "<host>", options: .caseInsensitive),
                    crash.wrote)
        }
        return nil
    }

    /// The exception in a minidump and where it happened, "Access violation (c0000005) at
    /// Game.exe+0x27c2fc9", and the address an access violation wrote to. Nil unless the dump holds
    /// an exception and its first module, the program, is `executable`.
    static func crashDump(_ dump: Data, executable: String) -> (summary: String, wrote: UInt64?)? {
        func read(_ offset: Int, _ size: Int) -> UInt64? {
            guard offset >= 0, offset <= dump.count - size else { return nil }
            return dump.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                (0..<size).reduce(UInt64(0)) { value, i in value | UInt64(bytes[offset + i]) << (8 * i) }
            }
        }
        func u32(_ offset: Int) -> Int? { read(offset, 4).map { Int($0) } }
        // The header: "MDMP", version, stream count, directory; entries are (type, size, offset).
        guard dump.starts(with: "MDMP".utf8), let count = u32(8), let directory = u32(12) else { return nil }
        var streams: [Int: Int] = [:]
        for entry in stride(from: directory, to: directory + 12 * min(count, 256), by: 12) {
            guard let type = u32(entry), let offset = u32(entry + 8) else { return nil }
            streams[type] = streams[type] ?? offset
        }
        // Exception stream (6): thread id, alignment, then code, flags, record, address, parameter
        // count, alignment, parameters. An access violation's are (1 for a write, the address).
        // Module list (4): count, then 108-byte entries: base, size, …, name at +20 (byte length, UTF-16LE).
        guard let exception = streams[6], let code = u32(exception + 8), let address = read(exception + 24, 8),
              let list = streams[4], let modules = u32(list).map({ min($0, 4096) }) else { return nil }
        func module(_ index: Int) -> (base: UInt64, size: UInt64, name: String)? {
            let entry = list + 4 + 108 * index
            guard let base = read(entry, 8), let size = read(entry + 8, 4), let name = u32(entry + 20), let length = u32(name),
                  name + 4 + length <= dump.count,
                  let path = String(data: dump.dropFirst(name + 4).prefix(length), encoding: .utf16LittleEndian) else { return nil }
            return (base, size, path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path)
        }
        guard modules > 0, module(0)?.name.lowercased() == executable.lowercased() else { return nil }
        let place = (0..<modules).lazy.compactMap(module).first { address >= $0.base && address - $0.base < $0.size }
            .map { "\($0.name)+0x\(String(address - $0.base, radix: 16))" } ?? "0x\(String(address, radix: 16))"
        let wrote = code == 0xc000_0005 && (u32(exception + 32) ?? 0) >= 2 && read(exception + 40, 8) == 1 ? read(exception + 48, 8) : nil
        return ("\(exceptionNames[code] ?? "Exception") (\(String(format: "%08x", UInt32(code)))) at \(place)", wrote)
    }

    /// Windows exception codes crash handlers catch most.
    static let exceptionNames = [0xc000_0005: "Access violation", 0xc000_001d: "Illegal instruction",
                                 0xc000_0094: "Integer division by zero", 0xc000_00fd: "Stack overflow",
                                 0xc000_0374: "Heap corruption", 0xc000_0409: "Stack buffer overrun",
                                 0x8000_0003: "Breakpoint", 0xe06d_7363: "C++ exception"]

    // MARK: Mod hooks

    /// What our Wine prints when it refuses a program's VirtualProtect outside Wine's memory, such as
    /// on D3DMetal's functions: `wine: refused VirtualProtect on host memory 0x21235e000-0x21235f000`.
    static let refusedChangeMarker = "wine: refused VirtualProtect on host memory "

    /// Whether the program crashed writing to memory that Wine had refused to make writable for it:
    /// a mod's hook into D3DMetal, which `GameProfile.modHooks` lets through.
    public static func refusedHook(inLog url: URL, wrote address: UInt64, maxBytes: Int = 4 << 20) -> Bool {
        tail(of: url, maxBytes: maxBytes).map { refusedHook(in: $0, wrote: address) } ?? false
    }

    static func refusedHook(in text: String, wrote address: UInt64) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            guard let start = line.range(of: refusedChangeMarker)?.upperBound else { return false }
            let bounds = line[start...].split(separator: "-").compactMap(hex)
            return bounds.count == 2 && bounds[0] <= address && address < bounds[1]
        }
    }

    /// The address in a Wine crash's "page fault on write access to 000000021235E14E" (winedbg:
    /// "0x21235e14e"). Nil for any other crash.
    public static func writeAddress(inCrash summary: String) -> UInt64? {
        summary.range(of: "write access to ").flatMap { hex(summary[$0.upperBound...].prefix { !$0.isWhitespace }) }
    }

    static func hex(_ text: Substring) -> UInt64? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        return UInt64(digits.hasPrefix("0x") ? String(digits.dropFirst(2)) : digits, radix: 16)
    }

    /// The Mac's name up to its first dot, as Wine's computer name starts.
    static var hostName: String {
        var name = [CChar](repeating: 0, count: 256)
        gethostname(&name, name.count)
        return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.split(separator: ".").first.map(String.init) ?? ""
    }

    // MARK: Corkscrew's own crashes

    /// macOS's report of a Corkscrew crash (`~/Library/Logs/DiagnosticReports/Corkscrew-*.ips`):
    /// the exception and the crashed thread's frames. Nil for a file that isn't one.
    public static func appCrash(ipsFile url: URL, details: [String]) -> ProblemReport? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let newline = text.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        let exception = body["exception"] as? [String: Any]
        let summary = [exception?["type"] as? String, (exception?["signal"] as? String).map { "(\($0))" },
                       (body["termination"] as? [String: Any])?["indicator"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        let images = (body["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
        var frames: [String] = []
        if let threads = body["threads"] as? [[String: Any]], let index = body["faultingThread"] as? Int, threads.indices.contains(index) {
            for (number, frame) in ((threads[index]["frames"] as? [[String: Any]]) ?? []).enumerated() {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                let symbol = (frame["symbol"] as? String).map { "\($0) + \(frame["symbolLocation"] as? Int ?? 0)" }
                    ?? "+\(frame["imageOffset"] as? Int ?? 0)"
                frames.append("\(number)  \(image)  \(symbol)")
            }
        }
        return ProblemReport(kind: .appCrash, title: "Corkscrew quit unexpectedly",
                             summary: summary.isEmpty ? url.lastPathComponent : summary, details: details,
                             backtrace: frames.isEmpty ? String(text.prefix(20_000)) : frames.joined(separator: "\n"))
    }

    // MARK: Helpers

    /// The last `maxBytes` of a file, from its first full line.
    public static func tail(of url: URL, maxBytes: Int = 4 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }

    /// The last `lines` lines of a log, at most `maxBytes`.
    public static func logTail(of url: URL, lines: Int = 200, maxBytes: Int = 64 << 10) -> String? {
        guard let text = tail(of: url, maxBytes: maxBytes) else { return nil }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }

    /// The home folder as `~`, and the user name (in Wine's `C:\users\<name>` too) as `<user>`.
    static func redacted(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var text = text.replacingOccurrences(of: home, with: "~")
        if user.count >= 3 {
            text = text.replacingOccurrences(of: "/Users/\(user)", with: "/Users/<user>")
                .replacingOccurrences(of: #"\users\\#(user)"#, with: #"\users\<user>"#, options: .caseInsensitive)
        }
        return text
    }
}

extension GraphicsBackend {
    /// The name the issue forms' "Graphics backend" field lists.
    public var formName: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        }
    }
}
