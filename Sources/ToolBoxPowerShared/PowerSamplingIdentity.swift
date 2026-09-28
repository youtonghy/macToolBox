import Foundation
import Security

enum PowerSamplingIdentity {
    // Pin to the bundled peer's designated requirement, including its cdhash for
    // ad-hoc builds. NSXPC checks the actual sender on every message (no PID race).
    static func requirement(for url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { throw IdentityError.invalidSignature }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { throw IdentityError.invalidSignature }
        return text as String
    }

    /// The cdhash of code signed without a Team ID. ServiceManagement pins such
    /// daemons to this hash in their launch constraint, so every rebuild or
    /// update needs a fresh registration. Nil for team-signed or unsigned code.
    static func pinnedCDHash(for url: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoTeamIdentifier as String] == nil,
              let hash = values[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    enum IdentityError: Error { case invalidSignature }
}
