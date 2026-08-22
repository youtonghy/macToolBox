import Foundation
import Security

final class ToolBoxControlClientIdentityVerifier: @unchecked Sendable {
    let codeSigningRequirement: String

    private let expectedHelperPath: String

    init(expectedHelperURL: URL) throws {
        let expectedURL = expectedHelperURL.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try expectedURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isExecutableKey,
            ])
        } catch {
            throw ToolBoxControlTransportError.expectedHelperMissing(expectedURL.path)
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExecutable == true
        else {
            throw ToolBoxControlTransportError.expectedHelperMissing(expectedURL.path)
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(expectedURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw ToolBoxControlTransportError.invalidExpectedHelper(expectedURL.path)
        }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
        )
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess
        else {
            throw ToolBoxControlTransportError.invalidExpectedHelper(expectedURL.path)
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement
        else {
            throw ToolBoxControlTransportError.codeRequirementUnavailable(expectedURL.path)
        }
        var requirementText: CFString?
        guard SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
              let requirementText
        else {
            throw ToolBoxControlTransportError.codeRequirementUnavailable(expectedURL.path)
        }

        self.expectedHelperPath = expectedURL.resolvingSymlinksInPath().path
        self.codeSigningRequirement = requirementText as String
    }

    func accepts(_ connection: NSXPCConnection) -> Bool {
        accepts(
            processIdentifier: connection.processIdentifier,
            effectiveUserIdentifier: connection.effectiveUserIdentifier
        )
    }

    func accepts(
        processIdentifier: Int32,
        effectiveUserIdentifier: uid_t
    ) -> Bool {
        guard effectiveUserIdentifier == geteuid(),
              processIdentifier > 0
        else { return false }
        return true
    }
}
