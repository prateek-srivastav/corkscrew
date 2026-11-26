import CryptoKit
import Foundation
import Security

/// The Mac's trusted root certificates, for isolated bottles.
///
/// Wine reads them through the Security framework, which needs securityd: the sandbox denies it
/// (it's also the Keychain's daemon), so inside an isolated bottle Wine trusts only its few built-in
/// Microsoft roots and HTTPS fails ("http error 0" in Steam). The app reads them outside the sandbox
/// and imports the missing ones into the bottle's registry with `regedit`, inside it. Wine keeps
/// Root certificates it didn't import from the host itself, so they stay.
public enum HostRootCertificates {
    static let key = #"Software\Microsoft\SystemCertificates\Root\Certificates"#

    /// Roots no bottle trusts, by thumbprint, though the Mac may still list them. macOS blocks them
    /// with configuration data its own frameworks read, which Wine doesn't: Wine trusts every root in
    /// the Mac's list.
    /// - `emSign ECC Root CA - G3`: the keys of six TLS intermediates under it were recoverable from
    ///   their certificates (October 2026; https://support.apple.com/en-us/149555), so anyone can make
    ///   certificates for any site that chain to it. Apple, Mozilla and Chrome dropped the root.
    static let distrusted: Set = ["3043FA4FF257DCA0C380EE2E58EA78B23FE6BBC1"]

    /// DER data of the roots in the system, admin and user trust domains: the ones Wine reads itself
    /// (`load_root_certs` in crypt32). Without the `distrusted` ones, and without those the Mac's trust
    /// settings deny (which Wine would trust all the same).
    static func load() -> [Data] {
        var result: [Data] = []
        var seen = Set<String>()
        for domain in [SecTrustSettingsDomain.system, .admin, .user] {
            var certificates: CFArray?
            guard SecTrustSettingsCopyCertificates(domain, &certificates) == errSecSuccess,
                  let certificates = certificates as? [SecCertificate] else { continue }
            for certificate in certificates where !isDenied(certificate, in: domain) {
                let der = SecCertificateCopyData(certificate) as Data
                let thumbprint = thumbprint(der)
                if !distrusted.contains(thumbprint), seen.insert(thumbprint).inserted { result.append(der) }
            }
        }
        return result
    }

    /// Whether the domain's trust settings for the certificate say Deny, for any use. A bottle can't
    /// trust a root for some uses only, so it doesn't get it.
    static func isDenied(_ certificate: SecCertificate, in domain: SecTrustSettingsDomain) -> Bool {
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(certificate, domain, &settings) == errSecSuccess,
              let settings = settings as? [[String: Any]] else { return false }
        return settings.contains { ($0[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value == SecTrustSettingsResult.deny.rawValue }
    }

    /// Wine names each certificate's key by its SHA-1, in upper-case hex.
    static func thumbprint(_ der: Data) -> String {
        Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// The certificates whose keys aren't in the saved registry (`system.reg`, which can lag a running
    /// bottle by a few seconds; importing again is harmless).
    static func missing(_ certificates: [Data], prefix: URL) -> [Data] {
        let saved = savedThumbprints(in: (try? Data(contentsOf: prefix.appending(path: "system.reg"))) ?? Data())
        return certificates.filter { !saved.contains(thumbprint($0)) }
    }

    /// The thumbprints (upper-case) of the certificate keys in a saved registry file, in one pass over
    /// its bytes. A text search per certificate took ~10 s for the Mac's ~160 roots in a 4 MB file.
    static func savedThumbprints(in registry: Data) -> Set<String> {
        let header = Array(("[" + key.replacingOccurrences(of: #"\"#, with: #"\\"#) + #"\\"#).lowercased().utf8)
        func lowercased(_ byte: UInt8) -> UInt8 { (0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte }
        var result = Set<String>()
        for line in registry.split(separator: UInt8(ascii: "\n")) {
            guard line.count > header.count, zip(line, header).allSatisfy({ lowercased($0) == $1 }) else { continue }
            let name = line.dropFirst(header.count)
            guard let end = name.firstIndex(of: UInt8(ascii: "]")) else { continue }
            result.insert(String(decoding: name[..<end], as: UTF8.self).uppercased())
        }
        return result
    }

    /// The `distrusted` roots the saved registry has (imported before they were distrusted).
    static func distrustedSaved(prefix: URL) -> [String] {
        let saved = savedThumbprints(in: (try? Data(contentsOf: prefix.appending(path: "system.reg"))) ?? Data())
        return distrusted.filter(saved.contains).sorted()
    }

    /// The certificates as a `regedit` file, and the keys of the `removing` thumbprints deleted. Each
    /// `Blob` is a serialized store element, as Wine and Windows save them: the SHA-1 property (3),
    /// then the certificate itself (32), each with a header of property ID, 1, and length.
    static func registryFile(_ certificates: [Data], removing: [String] = []) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for thumbprint in removing { lines += [#"[-HKEY_LOCAL_MACHINE\\#(key)\\#(thumbprint)]"#, ""] }
        for der in certificates {
            var blob = Data()
            for (property, data) in [(UInt32(3), Data(Insecure.SHA1.hash(data: der))), (UInt32(32), der)] {
                for value in [property, 1, UInt32(data.count)] { withUnsafeBytes(of: value.littleEndian) { blob.append(contentsOf: $0) } }
                blob.append(data)
            }
            let bytes = blob.map { String(format: "%02x", $0) }
            let rows = stride(from: 0, to: bytes.count, by: 24).map { bytes[$0 ..< min($0 + 24, bytes.count)].joined(separator: ",") }
            lines += [#"[HKEY_LOCAL_MACHINE\\#(key)\\#(thumbprint(der))]"#, #""Blob"=hex:"# + rows.joined(separator: ",\\\r\n  "), ""]
        }
        return lines.joined(separator: "\r\n")
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case importFailed(status: Int32, log: String)
        public var description: String {
            switch self {
            case .importFailed(let status, let log):
                "couldn't give the isolated bottle the Mac's root certificates (regedit exited \(status)); see \(log)"
            }
        }
    }

    /// Imports the file `writeImport` made.
    static let importCommand = ["regedit", "/S", #"C:\windows\temp\corkscrew-root-certificates.reg"#]

    /// Where `writeImport` puts its file; delete it once `importCommand` has run.
    static func importFile(prefix: URL) -> URL {
        prefix.appending(path: "drive_c/windows/temp/corkscrew-root-certificates.reg")
    }

    /// Writes the Mac's roots the bottle doesn't have yet, and deletes the `distrusted` ones it has,
    /// as a `regedit` file for `importCommand`; returns how many changes (no file when none).
    static func writeImport(prefix: URL) throws -> Int {
        let certificates = missing(load(), prefix: prefix)
        let removing = distrustedSaved(prefix: prefix)
        guard !certificates.isEmpty || !removing.isEmpty else { return 0 }
        let file = importFile(prefix: prefix)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try registryFile(certificates, removing: removing).write(to: file, atomically: true, encoding: .utf8)
        return certificates.count + removing.count
    }

    /// Imports the Mac's roots the bottle doesn't have yet; returns how many. Waits for a bottle
    /// that wasn't running to stop again, so the launch after it starts its own wineserver in its
    /// own sandbox. New bottles have them from `BottleStore.create`; this catches older bottles and
    /// roots the Mac got since.
    @discardableResult
    static func importMissing(in context: WineContext, log: URL) async throws -> Int {
        let prefix = context.location.prefix
        let count = try writeImport(prefix: prefix)
        guard count > 0 else { return 0 }
        defer { try? FileManager.default.removeItem(at: importFile(prefix: prefix)) }
        let wasRunning = WineServer.isRunning(prefix: prefix, base: context.paths.wineServerDirectory)
        let plan = try LaunchPlanner.plan(wineArguments: importCommand, in: context)
        let result = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        guard result.status == 0 else { throw Error.importFailed(status: result.status, log: log.path) }
        if !wasRunning {
            ProcessRunner.waitForSession(environment: plan.environment, wineserver: context.engine.wineserver, timeout: .seconds(30))
        }
        return count
    }
}
