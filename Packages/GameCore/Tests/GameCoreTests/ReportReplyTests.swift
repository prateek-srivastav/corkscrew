import Foundation
import Testing
@testable import GameCore

struct ReportReplyTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReportReplyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func postsToReplyNextToTheRelay() throws {
        let relay = URL(string: "https://corkscrew-relay.example.workers.dev/")!
        #expect(ReportReply.url(relay: relay).absoluteString == "https://corkscrew-relay.example.workers.dev/reply")

        let request = try ReportReply(issue: 57, key: nil, text: "From the disc image.",
                                      logs: [.init(name: "launch-1.log", text: "line")]).request(to: relay)
        #expect(request.httpMethod == "POST")
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(json["issue"] as? Int == 57)
        // No key (a report from 1.0.2 or older): left out, as the relay reads it.
        #expect(json.keys.sorted() == ["issue", "logs", "text"])
        #expect((json["logs"] as? [[String: String]]) == [["name": "launch-1.log", "text": "line"]])
    }

    @Test func picksTheNewestLaunchLogs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["launch-2026-10-21_20-30-00.log", "launch-2026-10-21_20-31-25.log", "launch-2026-10-20_09-00-00.log",
                     "launch-2026-10-21_20-33-10.log", "retina.log", "crash-dialog.log"] {
            try Data().write(to: folder.appending(path: name))
        }
        #expect(ReportReply.launchLogs(in: folder).map(\.lastPathComponent)
            == ["launch-2026-10-21_20-33-10.log", "launch-2026-10-21_20-31-25.log", "launch-2026-10-21_20-30-00.log"])
        #expect(ReportReply.launchLogs(in: folder.appending(path: "missing")).isEmpty)
    }

    @Test func keepsAShortLogWholeWithPathsHidden() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "launch-1.log")
        try "# cwd: \(NSHomeDirectory())/Games\r\n# backend: wined3d\nlast line".write(to: log, atomically: true, encoding: .utf8)
        #expect(ReportReply.excerpt(of: log) == "# cwd: ~/Games\n# backend: wined3d\nlast line")
    }

    @Test func keepsTheStartAndTheEndOfALongLog() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "launch-1.log")
        try (1...1_000).map { "line \($0)" }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

        let lines = try #require(ReportReply.excerpt(of: log, headLines: 3, tailLines: 2)).components(separatedBy: "\n")
        #expect(lines == ["line 1", "line 2", "line 3", ReportReply.cut, "line 999", "line 1000"])

        // Larger than the bytes it reads: the start's cut-off line is left out.
        let big = try #require(ReportReply.excerpt(of: log, headLines: 150, tailLines: 2, headBytes: 20, tailBytes: 20))
            .components(separatedBy: "\n")
        #expect(big.first == "line 1" && big.contains(ReportReply.cut) && big.last == "line 1000")
        #expect(!big.contains("line 3"))
    }

    @Test func aMissingLogHasNoExcerpt() {
        #expect(ReportReply.excerpt(of: URL(fileURLWithPath: "/nonexistent/launch-1.log")) == nil)
    }
}
