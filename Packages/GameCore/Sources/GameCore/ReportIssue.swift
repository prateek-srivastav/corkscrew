import Foundation

/// A reported problem's GitHub issue, as the Reports page shows it: open or closed, its labels, and
/// the maintainer's notes (comments from the owner or a collaborator that start with "Note:"). The
/// status comes from these and `docs/fixes.json`, which says the version with the fix.
public struct ReportIssue: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var isOpen: Bool
    public var labels: [String]
    public var notes: [Note]

    public struct Note: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var date: Date
        public var text: String

        public init(id: Int, date: Date, text: String) {
            self.id = id
            self.date = date
            self.text = text
        }
    }

    public init(number: Int, title: String, isOpen: Bool = true, labels: [String] = [], notes: [Note] = []) {
        self.number = number
        self.title = title
        self.isOpen = isOpen
        self.labels = labels
        self.notes = notes
    }

    public enum Status: Equatable, Sendable {
        case received, investigating, needsDetails, notCorkscrew, closed
        case fixed(version: String, availability: Availability)
    }

    /// Where the fix is: in this version, in the newer release, or not released yet.
    public enum Availability: String, Sendable { case installed, update, coming }

    /// Labels the maintainer sets (docs/RELEASING.md lists them). `question` and `upstream` are the
    /// repository's own labels.
    public static let investigatingLabel = "investigating"
    public static let needsDetailsLabel = "question"
    public static let notCorkscrewLabel = "upstream"
    /// The relay puts it on each issue a report opens (relay/src/issue.ts), before and after it
    /// opened them as the GitHub App, so it tells those apart from the maintainer's own issues.
    public static let sentLabel = "crash-report"

    /// Whether Corkscrew's report relay opened the issue: only those can be followed.
    public var isSentFromCorkscrew: Bool { labels.contains(Self.sentLabel) }

    /// A fix in the list wins; then "not Corkscrew's problem", open or closed; then a closed issue;
    /// then the open issue's label.
    public func status(fixes: [ReportFix], installed: String, latest: String?) -> Status {
        if let fix = fixes.first(where: { $0.issue == number }) {
            let availability: Availability = if !EnginePack.isOlder(installed, than: fix.version) { .installed }
                else if let latest, !EnginePack.isOlder(latest, than: fix.version) { .update } else { .coming }
            return .fixed(version: fix.version, availability: availability)
        }
        if labels.contains(Self.notCorkscrewLabel) { return .notCorkscrew }
        if !isOpen { return .closed }
        if labels.contains(Self.needsDetailsLabel) { return .needsDetails }
        if labels.contains(Self.investigatingLabel) { return .investigating }
        return .received
    }

    /// What the user saw or was told: the status and the newest note. A new one is news.
    public struct Signature: Codable, Sendable, Equatable {
        public var state: String
        /// The newest note's id; 0 without notes.
        public var note: Int
    }

    public static func signature(_ status: Status, notes: [Note]) -> Signature {
        let state = switch status {
        case .received: "received"
        case .investigating: "investigating"
        case .needsDetails: "needsDetails"
        case .notCorkscrew: "notCorkscrew"
        case .closed: "closed"
        case .fixed(let version, let availability): "fixed \(version) \(availability.rawValue)"
        }
        return Signature(state: state, note: notes.last?.id ?? 0)
    }
}

// MARK: Reading issues from GitHub

/// Reads report issues from GitHub's public API, without a token: 60 requests an hour for each
/// address, and an answer of 304 Not Modified counts too (checked 2026-10-22). So a check asks once
/// for every issue updated since the last check, and reads comments only for a tracked issue in it.
public enum ReportIssues {
    public static let api = URL(string: "https://api.github.com/repos/Prateek-Srivastav/corkscrew/")!

    /// The issue's page on GitHub.
    public static func page(of number: Int) -> URL {
        URL(string: "https://github.com/Prateek-Srivastav/corkscrew/issues/\(number)")!
    }

    /// An issue number typed by the user: "55", "#55" or the issue's link.
    public static func number(in text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) { return number > 0 ? number : nil }
        guard let url = URL(string: text), url.host()?.lowercased() == "github.com",
              url.path().lowercased().hasPrefix("/prateek-srivastav/corkscrew/issues/") else { return nil }
        return ReportFix.issue(in: url)
    }

    /// One issue with its notes. Nil when there's no such issue, or it's a pull request.
    public static func fetch(_ number: Int, api: URL = api) async throws -> ReportIssue? {
        let (data, response) = try await get(api.appending(path: "issues/\(number)"))
        if response.statusCode == 404 { return nil }
        try check(response)
        let issue = try decoder.decode(GitHubIssue.self, from: data)
        guard issue.pull_request == nil else { return nil }
        return try await read(issue, api: api)
    }

    /// The issues among `numbers` that changed since `since`, with their notes, and the server's
    /// time of the check, the next check's `since`. When more issues changed than one answer holds,
    /// each tracked issue is read on its own.
    public static func updated(_ numbers: Set<Int>, since: Date, api: URL = api) async throws -> (issues: [ReportIssue], checked: Date) {
        var url = api.appending(path: "issues")
        url.append(queryItems: [.init(name: "state", value: "all"), .init(name: "since", value: since.formatted(.iso8601)),
                                .init(name: "per_page", value: String(pageSize))])
        let (data, response) = try await get(url)
        try check(response)
        let checked = (response.value(forHTTPHeaderField: "Date")).flatMap(httpDate.date(from:)) ?? Date()
        let all = try decoder.decode([GitHubIssue].self, from: data)
        guard all.count < pageSize else {
            var issues: [ReportIssue] = []
            for number in numbers.sorted() { if let issue = try await fetch(number, api: api) { issues.append(issue) } }
            return (issues, checked)
        }
        var issues: [ReportIssue] = []
        for issue in all where numbers.contains(issue.number) && issue.pull_request == nil {
            issues.append(try await read(issue, api: api))
        }
        return (issues, checked)
    }

    /// The maintainer's notes among an issue's comments. Anyone can comment on a public issue, so only
    /// the owner's, a member's or a collaborator's count.
    static func notes(in comments: [GitHubComment]) -> [ReportIssue.Note] {
        comments.compactMap { comment in
            guard ["OWNER", "MEMBER", "COLLABORATOR"].contains(comment.author_association),
                  let range = comment.body.range(of: #"^\s*(\*\*)?Note:(\*\*)?\s*"#, options: [.regularExpression, .caseInsensitive])
            else { return nil }
            let text = comment.body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ReportIssue.Note(id: comment.id, date: comment.created_at, text: text)
        }
    }

    private static func read(_ issue: GitHubIssue, api: URL) async throws -> ReportIssue {
        var notes: [ReportIssue.Note] = []
        if issue.comments > 0 {
            var url = api.appending(path: "issues/\(issue.number)/comments")
            url.append(queryItems: [.init(name: "per_page", value: String(pageSize))])
            let (data, response) = try await get(url)
            try check(response)
            notes = Self.notes(in: try decoder.decode([GitHubComment].self, from: data))
        }
        return ReportIssue(number: issue.number, title: issue.title, isOpen: issue.state == "open",
                           labels: issue.labels.map(\.name), notes: notes)
    }

    private static let pageSize = 100

    private static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Out of requests for the hour (403 or 429) or another error: the check waits for the next one.
    private static func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The HTTP `Date` header: "Thu, 22 Oct 2026 10:00:00 GMT".
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// The parts of GitHub's issue and comment JSON that the app reads.
struct GitHubIssue: Decodable {
    struct Label: Decodable { var name: String }
    var number: Int
    var title: String
    var state: String
    var labels: [Label]
    var comments: Int
    struct PullRequest: Decodable {}
    /// Set on pull requests, which the issues list has too.
    var pull_request: PullRequest?
}

struct GitHubComment: Decodable {
    var id: Int
    var body: String
    var author_association: String
    var created_at: Date
}
