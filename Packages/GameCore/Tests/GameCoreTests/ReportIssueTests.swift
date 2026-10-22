import Foundation
import Testing
@testable import GameCore

struct ReportIssueTests {
    /// Issue #52 as GitHub's API answered on 2026-10-22, cut to fewer fields.
    static let issue52 = """
    {"url": "https://api.github.com/repos/prateek-srivastav/corkscrew/issues/52", "html_url": "https://github.com/prateek-srivastav/corkscrew/issues/52", "id": 5949210973, "number": 52, "title": "SparkingZERO quit with an error", "user": {"login": "prateek-srivastav", "type": "User"}, "labels": [{"name": "bug", "color": "d73a4a"}, {"name": "crash-report", "color": "d93f0b"}], "state": "closed", "locked": false, "comments": 0, "created_at": "2026-10-20T20:34:23Z", "updated_at": "2026-10-20T22:35:51Z", "closed_at": "2026-10-20T22:35:51Z", "author_association": "OWNER", "state_reason": "completed"}
    """

    /// The comment on issue #23, as the API answered.
    static func comment(id: Int = 6241086221, body: String = "Test report from setting up the relay. Closed.", by association: String = "OWNER") -> String {
        """
        {"id": \(id), "html_url": "https://github.com/prateek-srivastav/corkscrew/issues/23#issuecomment-\(id)", "issue_url": "https://api.github.com/repos/prateek-srivastav/corkscrew/issues/23", "body": \(String(data: try! JSONEncoder().encode(body), encoding: .utf8)!), "author_association": "\(association)", "created_at": "2026-10-17T21:07:05Z", "updated_at": "2026-10-17T21:07:05Z"}
        """
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    @Test func readsGitHubsIssue() throws {
        let issue = try Self.decode(GitHubIssue.self, Self.issue52)
        #expect(issue.number == 52 && issue.state == "closed" && issue.comments == 0 && issue.pull_request == nil)
        #expect(issue.labels.map(\.name) == ["bug", "crash-report"])
        // The issues list has pull requests too.
        let pull = try Self.decode(GitHubIssue.self, Self.issue52.replacingOccurrences(
            of: #""state_reason""#, with: #""pull_request": {"url": "u", "merged_at": null}, "state_reason""#))
        #expect(pull.pull_request != nil)
    }

    /// Only the maintainer's comments that start with "Note:" are notes; anyone can comment.
    @Test func notesAreTheMaintainersOnly() throws {
        let comments = try Self.decode([GitHubComment].self, "[" + [
            Self.comment(),
            Self.comment(id: 1, body: "Note: Turn off the VPN, then start the game again."),
            Self.comment(id: 2, body: "**Note:**\nUpdate macOS.", by: "COLLABORATOR"),
            Self.comment(id: 3, body: "Note: click this link", by: "NONE"),
            Self.comment(id: 4, body: "note:   ", by: "OWNER"),
        ].joined(separator: ",") + "]")
        let notes = ReportIssues.notes(in: comments)
        #expect(notes.map(\.id) == [1, 2])
        #expect(notes.map(\.text) == ["Turn off the VPN, then start the game again.", "Update macOS."])
    }

    @Test func statusFollowsLabelsStateAndFixes() {
        func status(_ open: Bool = true, labels: [String] = ["bug", "crash-report"], fixes: [ReportFix] = [],
                    installed: String = "1.0.2", latest: String? = nil) -> ReportIssue.Status {
            ReportIssue(number: 55, title: "Setup crashed", isOpen: open, labels: labels).status(fixes: fixes, installed: installed, latest: latest)
        }
        #expect(status() == .received)
        #expect(status(labels: ["bug", "investigating"]) == .investigating)
        #expect(status(labels: ["question", "investigating"]) == .needsDetails)
        #expect(status(labels: ["upstream"]) == .notCorkscrew)
        #expect(status(false, labels: ["upstream"]) == .notCorkscrew)
        #expect(status(false) == .closed)
        // A fix in the list wins, open or closed, and says where it is.
        let fix = [ReportFix(issue: 55, version: "1.0.3")]
        #expect(status(fixes: fix) == .fixed(version: "1.0.3", availability: .coming))
        #expect(status(false, fixes: fix, latest: "1.0.3") == .fixed(version: "1.0.3", availability: .update))
        #expect(status(false, fixes: fix, installed: "1.0.10") == .fixed(version: "1.0.3", availability: .installed))
        #expect(status(fixes: [ReportFix(issue: 52, version: "1.0.2")]) == .received)
    }

    /// A new status or a new note is news; the same answer again isn't.
    @Test func signatureChangesWithNews() {
        let note = ReportIssue.Note(id: 7, date: .now, text: "Try this.")
        let first = ReportIssue.signature(.received, notes: [])
        #expect(first == ReportIssue.signature(.received, notes: []))
        #expect(first != ReportIssue.signature(.investigating, notes: []))
        #expect(first != ReportIssue.signature(.received, notes: [note]))
        #expect(ReportIssue.signature(.fixed(version: "1.0.3", availability: .coming), notes: [])
                != ReportIssue.signature(.fixed(version: "1.0.3", availability: .update), notes: []))
    }

    @Test func readsTypedIssueNumbers() {
        #expect(ReportIssues.number(in: "55") == 55)
        #expect(ReportIssues.number(in: " #55 ") == 55)
        #expect(ReportIssues.number(in: "https://github.com/Prateek-Srivastav/corkscrew/issues/55") == 55)
        #expect(ReportIssues.number(in: "https://github.com/prateek-srivastav/corkscrew/issues/55#issuecomment-1") == 55)
        #expect(ReportIssues.number(in: "https://github.com/someone/else/issues/55") == nil)
        #expect(ReportIssues.number(in: "https://github.com/Prateek-Srivastav/corkscrew/pull/55") == nil)
        #expect(ReportIssues.number(in: "0") == nil)
        #expect(ReportIssues.number(in: "setup crashed") == nil)
    }

    @Test func onlyRelayIssuesAreSentFromCorkscrew() {
        #expect(ReportIssue(number: 55, title: "", labels: ["bug", "crash-report"]).isSentFromCorkscrew)
        #expect(!ReportIssue(number: 12, title: "", labels: ["bug", "known-issue"]).isSentFromCorkscrew)
        #expect(!ReportIssue(number: 14, title: "", labels: ["bug", "game-report"]).isSentFromCorkscrew)
    }

    @Test func fixListReadsCauseAndChange() throws {
        let fixes = try ReportFix.list(from: Data("""
        [{"issue": 55, "version": "1.0.3", "cause": "Wine's installer engine freed memory twice.", "change": "Corkscrew's Wine has a fix."}]
        """.utf8))
        #expect(fixes.first?.cause == "Wine's installer engine freed memory twice.")
        #expect(fixes.first?.change == "Corkscrew's Wine has a fix.")
    }
}
