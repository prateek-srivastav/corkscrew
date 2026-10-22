import CryptoKit
import Foundation
import IOKit

/// One ID per Mac, so the relay can count Macs and link a sent report to the Mac it came from: the
/// SHA-256 of a salt and the Mac's hardware UUID, as 64 hex digits. The hardware UUID itself never
/// leaves the Mac, and the salt keeps the ID apart from other apps' hashes of it. The same Mac gets
/// the same ID after Clean Up and Uninstall. The README's "Usage counts" says the same: keep the two
/// in step.
public enum DeviceID {
    static let salt = "corkscrew-device-id-v1"
    static let defaultsKey = "DeviceID"

    /// The ID for a hardware UUID: lowercase hex, 64 digits.
    public static func derive(hardwareUUID: String) -> String { derive(hardwareUUID: hardwareUUID, salt: salt) }

    static func derive(hardwareUUID: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + "|" + hardwareUUID.uppercased()).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `value` has the form of an ID (the relay checks the same).
    public static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// This Mac's ID: the one in `defaults`, or a new one, kept there. A random UUID stands in for a
    /// hardware UUID IOKit doesn't give.
    public static func current(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: defaultsKey), isValid(id) { return id }
        let id = derive(hardwareUUID: hardwareUUID ?? UUID().uuidString)
        defaults.set(id, forKey: defaultsKey)
        return id
    }

    /// IOPlatformUUID, as `ioreg -rd1 -c IOPlatformExpertDevice` shows it.
    static var hardwareUUID: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

/// What the app sends the relay's `/device` once a launch while usage counts are on: the Mac's ID
/// and what it is. The relay adds the country.
public struct DevicePing: Sendable, Equatable, Codable {
    public var id: String
    public var model: String
    public var chip: String
    public var memoryGB: Int
    public var osVersion: String
    public var appVersion: String
    public var appBuild: String
    public var isDebug: Bool

    public init(id: String, system: Analytics.System, chip: String = Hardware.chip, memoryGB: Int = Hardware.memoryGB) {
        self.id = id
        model = system.deviceModel
        self.chip = chip
        self.memoryGB = memoryGB
        osVersion = system.osVersion
        appVersion = system.appVersion
        appBuild = system.appBuildNumber
        isDebug = system.isDebug
    }

    /// The ping as JSON, for `relay` (the report relay's root).
    public func request(to relay: URL) throws -> URLRequest { try ProblemReport.post(self, to: relay.appending(path: "device")) }

    /// Sends the ping. Throws unless the relay answers 2xx.
    public func send(to relay: URL) async throws { _ = try await ProblemReport.send(request(to: relay)) }
}
