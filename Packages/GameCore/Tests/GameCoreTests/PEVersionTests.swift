import Foundation
import Testing
@testable import GameCore

struct PEVersionTests {
    private static func utf16(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }

    /// A version resource's String entry for `FileDescription`, behind 8 bytes standing in for the
    /// headers before it: length, value length (in UTF-16 units, with the 0), type, the key, then
    /// the value at a 32-bit boundary.
    static func versionInfo(description: String) -> [UInt8] {
        let value = utf16(description + "\0")
        var entry: [UInt8] = [0, 0, UInt8(value.count / 2), 0, 1, 0] + utf16("FileDescription\0")
        while entry.count % 4 != 0 { entry.append(0) }
        entry += value
        entry[0] = UInt8(entry.count)
        return Array(repeating: 0, count: 8) + entry
    }

    @Test func readsAProgramsDescription() throws {
        var pe = PEBuilder()
        pe.resources = [16: [(id: 1, data: Self.versionInfo(description: "Red Dead Redemption 2"))]]
        #expect(try PEFile.fileDescription(in: pe.build()) == "Red Dead Redemption 2")
    }

    @Test func noDescriptionWithoutOne() throws {
        #expect(try PEFile.fileDescription(in: PEBuilder().build()) == nil)
        var empty = PEBuilder()
        empty.resources = [16: [(id: 1, data: Self.versionInfo(description: ""))]]
        #expect(try PEFile.fileDescription(in: empty.build()) == nil)
    }
}
