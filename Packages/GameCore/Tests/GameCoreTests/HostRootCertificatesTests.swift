import Foundation
import Testing
@testable import GameCore

struct HostRootCertificatesTests {
    @Test func readsTheMacsRoots() {
        let roots = HostRootCertificates.load()
        #expect(roots.count > 100, "macOS ships well over a hundred system roots")
        #expect(Set(roots.map(HostRootCertificates.thumbprint)).count == roots.count, "no duplicates")
    }

    /// The same layout as the roots Wine imports itself (see a standard bottle's system.reg).
    @Test func writesWinesSerializedBlobs() throws {
        let der = Data((0 ..< 30).map { UInt8($0) })
        let thumbprint = HostRootCertificates.thumbprint(der)
        #expect(thumbprint.count == 40 && thumbprint == thumbprint.uppercased())
        let file = HostRootCertificates.registryFile([der])
        #expect(file.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        #expect(file.contains(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\SystemCertificates\Root\Certificates\"# + thumbprint + "]"))
        let hex = try #require(file.components(separatedBy: #""Blob"=hex:"#).last)
            .replacingOccurrences(of: ",\\\r\n  ", with: ",").trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = hex.split(separator: ",").compactMap { UInt8($0, radix: 16) }
        let sha1 = stride(from: 0, to: 40, by: 2).map { UInt8(thumbprint.dropFirst($0).prefix(2), radix: 16)! }
        #expect(bytes == [3, 0, 0, 0, 1, 0, 0, 0, 20, 0, 0, 0] + sha1 + [32, 0, 0, 0, 1, 0, 0, 0, 30, 0, 0, 0] + Array(der))
    }

    @Test func importsOnlyWhatTheRegistryLacks() throws {
        try withTempDir { prefix in
            let known = Data([1, 2, 3])
            let new = Data([4, 5, 6])
            let header = #"[Software\\Microsoft\\SystemCertificates\\Root\\Certificates\\"#
            try Data((header + HostRootCertificates.thumbprint(known) + "] 1791375674\n\"Blob\"=hex:00\n").utf8)
                .write(to: prefix.appending(path: "system.reg"))
            #expect(HostRootCertificates.missing([known, new], prefix: prefix) == [new])
            #expect(HostRootCertificates.missing([new], prefix: prefix.appending(path: "nowhere")) == [new], "no registry yet: import all")
        }
    }
}
