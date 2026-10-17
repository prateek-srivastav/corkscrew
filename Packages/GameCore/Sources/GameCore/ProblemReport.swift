import Foundation

/// A report about a crash or an error, which the user reads before sending it anywhere: what
/// happened, Corkscrew and the Mac, the program and its settings, Wine's backtrace and the end of
/// the log. Paths in the home folder show as `~/…`, and the user name as `<user>`.
public struct ProblemReport: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// A Windows program crashed (Wine's backtrace is in its log), or Wine itself did.
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
    /// One line: Wine's "Unhandled …" line, or the error message.
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
    public func request(to relay: URL) throws -> URLRequest {
        var request = URLRequest(url: relay, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(self)
        return request
    }

    /// Posts the report. The server answers `{"issue": "<link>"}` with the issue it opened, if any.
    public func send(to relay: URL) async throws -> URL? {
        let (data, response) = try await URLSession.shared.data(for: request(to: relay))
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
