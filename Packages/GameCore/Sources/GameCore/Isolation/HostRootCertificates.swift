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

    /// DER data of the roots in the system, admin and user trust domains: the ones Wine reads itself
    /// (`load_root_certs` in crypt32).
    static func load() -> [Data] {
        var result: [Data] = []
        var seen = Set<String>()
        for domain in [SecTrustSettingsDomain.system, .admin, .user] {
            var certificates: CFArray?
            guard SecTrustSettingsCopyCertificates(domain, &certificates) == errSecSuccess,
                  let certificates = certificates as? [SecCertificate] else { continue }
            for certificate in certificates {
                let der = SecCertificateCopyData(certificate) as Data
                if seen.insert(thumbprint(der)).inserted { result.append(der) }
            }
        }
        return result
    }

    /// Wine names each certificate's key by its SHA-1, in upper-case hex.
    static func thumbprint(_ der: Data) -> String {
        Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// The certificates whose keys aren't in the saved registry (`system.reg`, which can lag a running
    /// bottle by a few seconds; importing again is harmless).
    static func missing(_ certificates: [Data], prefix: URL) -> [Data] {
        let text = (try? String(contentsOf: prefix.appending(path: "system.reg"), encoding: .utf8))?.lowercased() ?? ""
        let header = "[" + key.replacingOccurrences(of: #"\"#, with: #"\\"#).lowercased() + #"\\"#
        return certificates.filter { !text.contains(header + thumbprint($0).lowercased() + "]") }
    }

    /// The certificates as a `regedit` file. Each `Blob` is a serialized store element, as Wine and
    /// Windows save them: the SHA-1 property (3), then the certificate itself (32), each with a
    /// header of property ID, 1, and length.
    static func registryFile(_ certificates: [Data]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
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

    /// Imports the Mac's roots the bottle doesn't have yet; returns how many. Waits for a bottle
    /// that wasn't running to stop again, so the launch after it starts its own wineserver in its
    /// own sandbox.
    @discardableResult
    static func importMissing(in context: WineContext, log: URL) async throws -> Int {
        let prefix = context.location.prefix
        let certificates = missing(load(), prefix: prefix)
        guard !certificates.isEmpty else { return 0 }
        let wasRunning = WineServer.isRunning(prefix: prefix, base: context.paths.wineServerDirectory)
        let file = prefix.appending(path: "drive_c/windows/temp/corkscrew-root-certificates.reg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try registryFile(certificates).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let plan = try LaunchPlanner.plan(wineArguments: ["regedit", "/S", #"C:\windows\temp\corkscrew-root-certificates.reg"#], in: context)
        let result = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        guard result.status == 0 else { throw Error.importFailed(status: result.status, log: log.path) }
        if !wasRunning {
            ProcessRunner.waitForSession(environment: plan.environment, wineserver: context.engine.wineserver, timeout: .seconds(30))
        }
        return certificates.count
    }
}
