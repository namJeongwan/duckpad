import Foundation
import Security

@objc public protocol DuckpadNativeInstallerProtocol {
    func install(_ signedFiles: Data, withReply reply: @escaping (String?, String?) -> Void)
}

public enum NativeInstallerXPC {
    public static let identifier = "com.namjeongwan.duckpad.native-installer"
    public static let maximumFrameBytes = 48 * 1_024 * 1_024

    /// Binds XPC messages to the code identity actually shipped in this app.
    /// Ad-hoc development builds use their exact code hash; Developer ID builds
    /// use the signing identity's designated requirement.
    public static func requirement(for bundle: URL, matchingSignerOf reference: URL? = nil) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw CocoaError(.executableNotLoadable) }
        if let reference {
            var peer: SecStaticCode?
            guard SecStaticCodeCreateWithPath(reference as CFURL, [], &peer) == errSecSuccess, let peer,
                  try team(of: code) == team(of: peer) else { throw CocoaError(.executableNotLoadable) }
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { throw CocoaError(.executableNotLoadable) }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw CocoaError(.executableNotLoadable) }
        return text as String
    }

    private static func team(of code: SecStaticCode) throws -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { throw CocoaError(.executableNotLoadable) }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
