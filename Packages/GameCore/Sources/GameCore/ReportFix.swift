import Foundation

/// A sent report's issue, fixed in a release. The list is `docs/fixes.json` on main
/// (`[{"issue": 51, "version": "1.0.2"}]`, the first version with the fix). The app keeps the issue
/// of each report it sent, and tells the person who sent it once they can get that version. A fix
/// for `everyone` is told to every Mac that has it installed, once, with its `title`.
public struct ReportFix: Codable, Sendable, Equatable {
    public var issue: Int
    public var version: String
    /// Told to everyone, not only the sender, once their version has the fix.
    public var everyone: Bool
    /// What the alert names for those who didn't send the report. An `everyone` fix without one is
    /// told to the sender only.
    public var title: String?
    /// What was wrong and what changed, a short line each, for the fix popup.
    public var cause: String?
    public var change: String?

    public init(issue: Int, version: String, everyone: Bool = false, title: String? = nil, cause: String? = nil, change: String? = nil) {
        self.issue = issue
        self.version = version
        self.everyone = everyone
        self.title = title
        self.cause = cause
        self.change = change
    }

    /// A missing `everyone` is false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issue = try c.decode(Int.self, forKey: .issue)
        version = try c.decode(String.self, forKey: .version)
        everyone = try c.decodeIfPresent(Bool.self, forKey: .everyone) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        cause = try c.decodeIfPresent(String.self, forKey: .cause)
        change = try c.decodeIfPresent(String.self, forKey: .change)
    }

    /// `docs/fixes.json` on main, which the app reads when it opens. Older versions read it too, so
    /// add keys; don't rename or remove them, and don't move the file.
    public static let listURL = URL(string: "https://raw.githubusercontent.com/Prateek-Srivastav/corkscrew/main/docs/fixes.json")!

    /// Reads the fix list at `url`, the one on main by default.
    public static func download(from url: URL = listURL) async throws -> [ReportFix] {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try list(from: data)
    }

    /// Entries this version can't read are left out.
    static func list(from data: Data) throws -> [ReportFix] {
        struct Entry: Decodable {
            var fix: ReportFix?
            init(from decoder: Decoder) { fix = try? ReportFix(from: decoder) }
        }
        return try JSONDecoder().decode([Entry].self, from: data).compactMap(\.fix)
    }

    /// The number in a link to a GitHub issue (`…/issues/51`), what the relay answers.
    public static func issue(in url: URL) -> Int? {
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "issues" else { return nil }
        return Int(parts[parts.count - 1])
    }

    /// The fix for the lowest issue to tell about, if the user can get it:
    /// - one of the `sent` issues: in the `installed` version, or in `latest`, the newer release the
    ///   update check found (`needsUpdate`);
    /// - a fix for `everyone`, not `announced` yet: in the installed version only, as nobody asked.
    /// Nil while no fix is released.
    public static func available(sent: some Sequence<Int>, announced: Set<Int> = [], in fixes: [ReportFix],
                                 installed: String, latest: String?) -> (fix: ReportFix, needsUpdate: Bool)? {
        let sent = Set(sent)
        for fix in fixes.sorted(by: { $0.issue < $1.issue }) {
            let isSent = sent.contains(fix.issue)
            guard isSent || (fix.everyone && fix.title != nil && !announced.contains(fix.issue)) else { continue }
            if !EnginePack.isOlder(installed, than: fix.version) { return (fix, false) }
            if isSent, let latest, !EnginePack.isOlder(latest, than: fix.version) { return (fix, true) }
        }
        return nil
    }

    /// The `everyone` fixes the `installed` version already has: what a Mac where Corkscrew wasn't
    /// set up counts as told, since it never had those problems.
    public static func included(in installed: String, of fixes: [ReportFix]) -> [Int] {
        fixes.filter { $0.everyone && !EnginePack.isOlder(installed, than: $0.version) }.map(\.issue)
    }
}
