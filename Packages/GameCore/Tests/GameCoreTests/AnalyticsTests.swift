import Foundation
import Testing
@testable import GameCore

struct AnalyticsTests {
    static let system = Analytics.System(isDebug: true, locale: "en", osVersion: "26.1", appVersion: "0.8.0",
                                         appBuildNumber: "11", deviceModel: "Mac16,1")

    /// The key's region picks the host, as Aptabase's SDKs do; without a key nothing is sent.
    @Test func keysPickTheirRegion() {
        #expect(Analytics(key: "A-EU-1234567890", system: Self.system)?.endpoint.absoluteString == "https://eu.aptabase.com/api/v0/events")
        #expect(Analytics(key: "A-US-1234567890", system: Self.system)?.endpoint.absoluteString == "https://us.aptabase.com/api/v0/events")
        #expect(Analytics(key: "A-DEV-1", system: Self.system)?.endpoint.absoluteString == "http://localhost:3000/api/v0/events")
        #expect(Analytics(key: "", system: Self.system) == nil)
        #expect(Analytics(key: "A-XX-1234567890", system: Self.system) == nil)
        // The built-in key, once there, is one the app can use.
        #expect(Analytics.appKey.isEmpty || Analytics(key: Analytics.appKey, system: Self.system) != nil)
    }

    /// One event in Aptabase's format, with the chip and memory added and nothing else.
    @Test func requestHasTheEventAndNoMore() throws {
        let analytics = try #require(Analytics(key: "A-EU-1234567890", system: Self.system))
        let request = try analytics.request("setup_done", props: ["seconds": .int(95), "engine": .string("bundled")],
                                            at: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "App-Key") == "A-EU-1234567890")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let events = try #require(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        #expect(events.count == 1)
        let event = events[0]
        #expect(Set(event.keys) == ["timestamp", "sessionId", "eventName", "systemProps", "props"])
        #expect(event["eventName"] as? String == "setup_done")
        #expect(event["timestamp"] as? String == "2026-10-14T17:46:40Z")
        #expect((event["sessionId"] as? String)?.allSatisfy(\.isNumber) == true)

        let system = try #require(event["systemProps"] as? [String: Any])
        #expect(Set(system.keys) == ["isDebug", "locale", "osName", "osVersion", "appVersion", "appBuildNumber", "sdkVersion", "deviceModel"])
        #expect(system["osName"] as? String == "macOS")
        #expect(system["deviceModel"] as? String == "Mac16,1")

        let props = try #require(event["props"] as? [String: Any])
        #expect(Set(props.keys) == ["chip", "memory_gb", "seconds", "engine"])
        #expect(props["seconds"] as? Int == 95)
        #expect(props["memory_gb"] as? Int == Hardware.memoryGB)
    }

    @Test func osVersionReadsLikeSwVers() {
        #expect(Analytics.System.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)) == "26.1")
        #expect(Analytics.System.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)) == "26.0.1")
    }

    @Test func hardwareIsKnown() {
        #expect(Hardware.model.hasPrefix("Mac"))
        #expect(!Hardware.chip.isEmpty)
        #expect(Hardware.memoryGB >= 8)
    }
}
