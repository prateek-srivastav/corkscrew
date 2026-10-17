import Foundation

/// Anonymous usage counts, sent to Aptabase (aptabase.com) in its event format: the app's first
/// launch and a finished setup (`scripts/install.sh` counts installs the same way). Each count has
/// the app and macOS versions, the Mac model, chip and memory, and the language; Aptabase reads the
/// country from the connection and doesn't keep the IP address. No account, user or program names,
/// files, and no ID that lasts (Aptabase's visitor hash changes every day). The README's "Usage
/// counts" says the same: keep the two in step.
public struct Analytics: Sendable {
    /// The Aptabase app key, the same as `ANALYTICS_KEY` in install.sh. Public: every copy of the app
    /// has it. Empty: nothing is sent.
    public static let appKey = "A-US-8232382106"

    /// A prop's value; Aptabase takes strings, numbers and booleans.
    public enum Value: Encodable, Sendable, Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    /// What every count carries besides its name and props (Aptabase's `systemProps`).
    public struct System: Encodable, Sendable, Equatable {
        public var isDebug: Bool
        public var locale: String
        public var osName = "macOS"
        public var osVersion: String
        public var appVersion: String
        public var appBuildNumber: String
        public var sdkVersion = "corkscrew-app"
        public var deviceModel: String

        public init(isDebug: Bool, locale: String, osVersion: String, appVersion: String, appBuildNumber: String, deviceModel: String) {
            self.isDebug = isDebug
            self.locale = locale
            self.osVersion = osVersion
            self.appVersion = appVersion
            self.appBuildNumber = appBuildNumber
            self.deviceModel = deviceModel
        }

        public static func current(bundle: Bundle = .main, isDebug: Bool) -> System {
            System(isDebug: isDebug,
                   locale: Locale.current.language.languageCode?.identifier ?? "",
                   osVersion: osVersion(ProcessInfo.processInfo.operatingSystemVersion),
                   appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                   appBuildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                   deviceModel: Hardware.model)
        }

        /// As `sw_vers -productVersion` writes it (install.sh sends that): 26.1, 26.0.1.
        static func osVersion(_ version: OperatingSystemVersion) -> String {
            "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion == 0 ? "" : ".\(version.patchVersion)")
        }
    }

    struct Event: Encodable {
        var timestamp: Date
        var sessionId: String
        var eventName: String
        var systemProps: System
        var props: [String: Value]
    }

    public let key: String
    public let endpoint: URL
    public let system: System
    /// One for each run of the app, in the SDK's form (seconds, then 8 random digits).
    let session = String(Int(Date().timeIntervalSince1970) * 100_000_000 + Int.random(in: 0..<100_000_000))

    /// Nil for an empty key or one from an unknown region: then nothing is sent.
    public init?(key: String, system: System) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0] == "A", let host = Self.hosts[String(parts[1])] else { return nil }
        self.key = key
        self.endpoint = URL(string: "\(host)/api/v0/events")!
        self.system = system
    }

    /// Aptabase's regions, as its SDKs read them from the key (A-EU-…); DEV is a local server for tests.
    static let hosts = ["EU": "https://eu.aptabase.com", "US": "https://us.aptabase.com", "DEV": "http://localhost:3000"]

    /// The Mac's chip and memory go with every count; `props` add to them.
    public func request(_ name: String, props: [String: Value] = [:], at date: Date = .now) throws -> URLRequest {
        let event = Event(timestamp: date, sessionId: session, eventName: name, systemProps: system,
                          props: ["chip": .string(Hardware.chip), "memory_gb": .int(Hardware.memoryGB)].merging(props) { $1 })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "App-Key")
        request.httpBody = try encoder.encode([event])
        return request
    }

    /// Sends one count and returns whether Aptabase took it. A count that fails is dropped.
    @discardableResult
    public func send(_ name: String, props: [String: Value] = [:]) async -> Bool {
        guard let request = try? request(name, props: props),
              let (_, response) = try? await Self.urlSession.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }

    /// No cookies or cache on disk.
    private static let urlSession = URLSession(configuration: .ephemeral)
}

/// The Mac itself, for usage counts and reports.
public enum Hardware {
    /// `hw.model`, e.g. Mac16,1.
    public static var model: String { sysctl("hw.model") ?? "" }
    /// e.g. Apple M4 Pro.
    public static var chip: String { sysctl("machdep.cpu.brand_string") ?? "" }
    public static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
