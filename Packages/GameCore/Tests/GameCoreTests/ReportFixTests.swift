import Foundation
import Testing
@testable import GameCore

struct ReportFixTests {
    /// The app downloads the list from this path on main, so the file must stay there and read.
    @Test func listURLNamesTheFile() throws {
        let path = try #require(ReportFix.listURL.path.components(separatedBy: "/main/").last)
        let file = TestedGamesTests.repo.appending(path: path)
        _ = try ReportFix.list(from: Data(contentsOf: file))
    }

    /// An entry this version can't read (a mistake, or a newer version's) doesn't hide the others.
    @Test func downloadedListSkipsEntriesItCannotRead() async throws {
        try await withTempDir { root in
            let list = root.appending(path: "fixes.json")
            try list.write("""
            [
              {"issue": 51, "version": "1.0.2"},
              {"issue": "52", "version": "1.0.2"},
              {"issue": 53},
              {"issue": 54, "version": "1.0.2", "everyone": true, "title": "Games didn't start"}
            ]
            """)
            #expect(try await ReportFix.download(from: list) ==
                    [ReportFix(issue: 51, version: "1.0.2"), ReportFix(issue: 54, version: "1.0.2", everyone: true, title: "Games didn't start")])
        }
    }

    /// The relay answers with the issue's page.
    @Test func readsTheIssueNumberFromItsLink() throws {
        let issue = { (link: String) in ReportFix.issue(in: URL(string: link)!) }
        #expect(issue("https://github.com/Prateek-Srivastav/corkscrew/issues/51") == 51)
        #expect(issue("https://github.com/Prateek-Srivastav/corkscrew/pull/51") == nil)
        #expect(issue("https://github.com/Prateek-Srivastav/corkscrew/issues/new") == nil)
        #expect(issue("https://github.com/Prateek-Srivastav/corkscrew/issues") == nil)
    }

    /// A fix shows once the user can get it: in this version, or in the newer release.
    @Test func fixShowsOnceItIsReleased() throws {
        let fixes = [ReportFix(issue: 51, version: "1.0.2"), ReportFix(issue: 60, version: "1.0.10")]

        let here = try #require(ReportFix.available(sent: [51], in: fixes, installed: "1.0.2", latest: nil))
        #expect(here.fix.issue == 51 && !here.needsUpdate)
        let update = try #require(ReportFix.available(sent: [51], in: fixes, installed: "1.0.1", latest: "1.0.3"))
        #expect(update.fix.issue == 51 && update.needsUpdate)

        // Not released yet, or not in the list, or another person's report.
        #expect(ReportFix.available(sent: [51], in: fixes, installed: "1.0.1", latest: nil) == nil)
        #expect(ReportFix.available(sent: [60], in: fixes, installed: "1.0.9", latest: "1.0.9") == nil)
        #expect(ReportFix.available(sent: [70], in: fixes, installed: "2.0", latest: nil) == nil)
        #expect(ReportFix.available(sent: [], in: fixes, installed: "2.0", latest: nil) == nil)

        // The lowest issue first; one not released yet doesn't stop a later one.
        #expect(ReportFix.available(sent: [60, 51], in: fixes, installed: "1.0.10", latest: nil)?.fix.issue == 51)
        #expect(ReportFix.available(sent: [51, 60], in: fixes, installed: "1.0.1", latest: "1.0.10")?.fix.issue == 51)
        #expect(ReportFix.available(sent: [40, 60], in: [ReportFix(issue: 40, version: "2.0")] + fixes,
                                    installed: "1.0.10", latest: nil)?.fix.issue == 60)
    }

    /// A fix for everyone shows once this version has it, also on Macs that didn't send the report.
    @Test func fixForEveryoneShowsInTheVersionThatHasIt() throws {
        let fixes = [ReportFix(issue: 52, version: "1.0.2", everyone: true, title: "Games didn't start")]

        let here = try #require(ReportFix.available(sent: [], in: fixes, installed: "1.0.2", latest: nil))
        #expect(here.fix.issue == 52 && !here.needsUpdate)
        // Told once; not offered as an update to those who didn't send it; no title, sender only.
        #expect(ReportFix.available(sent: [], announced: [52], in: fixes, installed: "1.0.2", latest: nil) == nil)
        #expect(ReportFix.available(sent: [], in: fixes, installed: "1.0.1", latest: "1.0.2") == nil)
        #expect(ReportFix.available(sent: [], in: [ReportFix(issue: 52, version: "1.0.2", everyone: true)],
                                    installed: "1.0.2", latest: nil) == nil)
        // The sender still hears of the update.
        #expect(ReportFix.available(sent: [52], in: fixes, installed: "1.0.1", latest: "1.0.2")?.needsUpdate == true)

        // A Mac where Corkscrew wasn't set up counts the fixes it already has as told.
        let later = ReportFix(issue: 60, version: "1.0.3", everyone: true, title: "Later")
        #expect(ReportFix.included(in: "1.0.2", of: fixes + [later, ReportFix(issue: 51, version: "1.0.1")]) == [52])
    }
}
