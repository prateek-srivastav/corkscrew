import Foundation
import Testing
@testable import GameCore

struct DeviceIDTests {
    static let uuid = "2A5C1E0B-6F3D-4E8A-9B7C-1D2E3F405162"

    /// The same Mac gets the same ID: 64 lowercase hex digits, not the UUID itself.
    @Test func idIsStableHexAndHidesTheUUID() {
        let id = DeviceID.derive(hardwareUUID: Self.uuid)
        #expect(id == DeviceID.derive(hardwareUUID: Self.uuid))
        #expect(id == DeviceID.derive(hardwareUUID: Self.uuid.lowercased()))
        #expect(DeviceID.isValid(id))
        #expect(!id.contains(Self.uuid.lowercased().replacingOccurrences(of: "-", with: "")))
        #expect(id != DeviceID.derive(hardwareUUID: "2A5C1E0B-6F3D-4E8A-9B7C-1D2E3F405163"))
    }

    /// The salt changes the ID, so it isn't a plain hash of the UUID.
    @Test func idIsSalted() {
        #expect(DeviceID.derive(hardwareUUID: Self.uuid) != DeviceID.derive(hardwareUUID: Self.uuid, salt: "other"))
        #expect(DeviceID.derive(hardwareUUID: Self.uuid) != DeviceID.derive(hardwareUUID: Self.uuid, salt: ""))
    }

    @Test func onlyIDsOfTheRightFormAreValid() {
        #expect(!DeviceID.isValid(""))
        #expect(!DeviceID.isValid(String(repeating: "a", count: 63)))
        #expect(!DeviceID.isValid(String(repeating: "A", count: 64)))
        #expect(!DeviceID.isValid(String(repeating: "g", count: 64)))
        #expect(DeviceID.isValid(String(repeating: "0", count: 64)))
    }

    /// This Mac's ID comes from its hardware UUID and is kept; a kept one is used again.
    @Test func currentIDIsKept() throws {
        let suite = "DeviceIDTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = DeviceID.current(defaults: defaults)
        #expect(DeviceID.isValid(id))
        if let uuid = DeviceID.hardwareUUID { #expect(id == DeviceID.derive(hardwareUUID: uuid)) }
        #expect(defaults.string(forKey: DeviceID.defaultsKey) == id)
        #expect(DeviceID.current(defaults: defaults) == id)
    }

    /// The ping goes to /device with the Mac's details and nothing else.
    @Test func pingHasTheDetails() throws {
        let ping = DevicePing(id: DeviceID.derive(hardwareUUID: Self.uuid), system: AnalyticsTests.system, chip: "Apple M4", memoryGB: 16)
        let request = try ping.request(to: URL(string: "https://relay.example/")!)
        #expect(request.url?.absoluteString == "https://relay.example/device")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["id", "model", "chip", "memoryGB", "osVersion", "appVersion", "appBuild", "isDebug"])
        #expect(body["model"] as? String == "Mac16,1")
        #expect(body["memoryGB"] as? Int == 16)
    }

    /// The device ID goes to the relay with a report, but not into the report's text or GitHub link.
    @Test func reportKeepsTheIDOutOfItsText() throws {
        var report = ProblemReport(kind: .crash, title: "Example crashed", summary: "wine: Unhandled", details: ["Corkscrew: 1.0.2"])
        let id = DeviceID.derive(hardwareUUID: Self.uuid)
        report.device = id
        #expect(!report.text.contains(id))
        #expect(!report.issueURL(repository: URL(string: "https://github.com/example/example")!).absoluteString.contains(id))
        let request = try report.request(to: URL(string: "https://relay.example/")!)
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["device"] as? String == id)
    }
}
