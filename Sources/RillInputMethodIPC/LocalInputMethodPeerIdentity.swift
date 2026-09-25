import Darwin
import Foundation
import RillInputMethodContracts
import Security

/// Signature work runs off the input method's event thread. Socket identity is checked on
/// both sides of this work and again for each transfer on the established connection.
enum LocalInputMethodPeerIdentity {
  static func token(for descriptor: Int32) -> Data? {
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
      size == MemoryLayout<audit_token_t>.size
    else { return nil }
    return withUnsafeBytes(of: token) { Data($0) }
  }

  static func validate(_ token: Data, host: Bool) -> Bool {
    let defaults = SecCSFlags(rawValue: 0)
    var ownCode: SecCode?
    var anchor: SecRequirement?
    guard SecCodeCopySelf(defaults, &ownCode) == errSecSuccess, let ownCode,
      SecRequirementCreateWithString("anchor apple generic" as CFString, defaults, &anchor)
        == errSecSuccess, let anchor,
      SecCodeCheckValidity(ownCode, defaults, anchor) == errSecSuccess
    else { return false }
    var ownStaticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopyStaticCode(ownCode, defaults, &ownStaticCode) == errSecSuccess,
      let ownStaticCode,
      SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let information = information as? [String: Any],
      let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
      flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0,
      let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
      team.utf8.count == 10,
      team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
    else { return false }
    var peer: SecCode?
    let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, defaults, &peer) == errSecSuccess,
      let peer
    else { return false }
    let identifier = host ? InputMethodPaths.bundleIdentifier : "dev.zrr.Rill"
    let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(rule as CFString, defaults, &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(peer, defaults, requirement) == errSecSuccess
  }
}
