import Foundation

/// The sender's answer to the developer's note on a report's issue, from Reply on the Reports page.
/// The relay (`POST /reply`) keeps the answer and the logs privately and comments on the issue that
/// there is one: the issue was opened by the relay, so the sender can't comment there themselves.
public struct ReportReply: Encodable, Sendable, Equatable {
    public var issue: Int
    /// The key the relay gave with the report (`ProblemReport.Sent`). Reports sent with 1.0.2 and
    /// older have none; the relay takes their replies but marks them as unchecked.
    public var key: String?
    public var text: String
    public var logs: [Log]

    public struct Log: Encodable, Sendable, Equatable {
        /// The file's name, like `launch-2026-10-21_20-30-00.log`.
        public var name: String
        public var text: String

        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    public init(issue: Int, key: String?, text: String, logs: [Log] = []) {
        self.issue = issue
        self.key = key
        self.text = text
        self.logs = logs
    }

    /// `/reply` on the report relay.
    public static func url(relay: URL) -> URL { relay.appending(path: "reply") }

    public func request(to relay: URL) throws -> URLRequest { try ProblemReport.post(self, to: Self.url(relay: relay)) }

    /// Throws unless the relay kept the reply (2xx).
    public func send(to relay: URL) async throws { _ = try await ProblemReport.send(request(to: relay)) }

    // MARK: Logs

    /// The newest `count` launch logs in a program's log folder, newest first. Their names hold the
    /// time (`launch-2026-10-21_20-30-00.log`), so they sort by it.
    public static func launchLogs(in folder: URL, count: Int = 3) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("launch-") && $0.hasSuffix(".log") }.sorted(by: >).prefix(count)
            .map { folder.appending(path: $0, directoryHint: .notDirectory) }
    }

    /// The start and the end of a launch log, with the home folder and user name hidden as in
    /// reports: the start has the command, the bottle and the settings, the end what happened last.
    /// At most about `headBytes + tailBytes`, so three logs fit in the relay's 1 MB.
    public static func excerpt(of url: URL, headLines: Int = 150, tailLines: Int = 400,
                               headBytes: Int = 32 << 10, tailBytes: Int = 96 << 10) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil else { return nil }
        let text: String
        if size <= UInt64(headBytes + tailBytes) {
            guard let data = try? handle.readToEnd() else { return nil }
            let lines = Self.lines(String(decoding: data, as: UTF8.self))
            text = lines.count <= headLines + tailLines ? lines.joined(separator: "\n")
                : (lines.prefix(headLines) + [cut] + lines.suffix(tailLines)).joined(separator: "\n")
        } else {
            guard let data = try? handle.read(upToCount: headBytes), let end = ProblemReport.tail(of: url, maxBytes: tailBytes) else { return nil }
            // The last line read is cut off.
            let head = Self.lines(String(decoding: data, as: UTF8.self)).dropLast().prefix(headLines)
            text = (head + [cut] + Self.lines(end).suffix(tailLines)).joined(separator: "\n")
        }
        return ProblemReport.redacted(text)
    }

    /// Where an excerpt leaves lines out.
    static let cut = "[…]"

    // Windows programs end lines with \r\n, which Swift counts as one Character: split on any newline.
    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }
}
