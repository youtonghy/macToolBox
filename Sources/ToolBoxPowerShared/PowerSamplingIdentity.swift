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

    enum IdentityError: Error { case invalidSignature }
}
