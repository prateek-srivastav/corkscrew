import Foundation
import Security

/// Who signed an app, with the Security framework rather than `codesign`'s output.
///
/// `codesign --verify` only says a signature is intact, which any ad hoc signature is. A release's
/// designated requirement names Corkscrew's certificate (`certificate leaf = H"<SHA-1>"`), so an
/// app that meets the installed app's requirement was signed with the same key.
enum CodeSigning {
    enum Failure: Error, Equatable {
        case unreadable(OSStatus)
        case unsatisfied(OSStatus)
    }

    private static func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure.unreadable(status) }
        return code
    }

    /// The app's designated requirement when it's signed with a certificate; nil when it's ad hoc
    /// (a build from source), whose requirement is its own hash and so matches no other build.
    static func certificateRequirement(of app: URL) throws -> SecRequirement? {
        let code = try staticCode(app)
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess else { throw Failure.unreadable(status) }
        let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard !certificates.isEmpty else { return nil }
        var requirement: SecRequirement?
        let copied = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard copied == errSecSuccess, let requirement else { throw Failure.unreadable(copied) }
        return requirement
    }

    /// A requirement from its text (`identifier "…" and certificate leaf = H"…"`).
    static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw Failure.unreadable(status) }
        return requirement
    }

    /// Throws unless `app`'s signature is valid, covers its nested code, and meets `requirement`.
    static func check(_ app: URL, satisfies requirement: SecRequirement) throws {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(try staticCode(app), flags, requirement)
        guard status == errSecSuccess else { throw Failure.unsatisfied(status) }
    }
}
