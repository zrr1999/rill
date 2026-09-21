import Foundation

public struct FocusPrivacyIdentitySample: Sendable, Equatable {
  public var focus: FocusSnapshot
  public var applicationActivationRevision: UInt64

  public init(focus: FocusSnapshot, applicationActivationRevision: UInt64) {
    self.focus = focus
    self.applicationActivationRevision = applicationActivationRevision
  }

  public var hasVerifiablePrivacyIdentity: Bool {
    focus.processIdentifier != nil || focus.bundleIdentifier?.isEmpty == false
  }

  public func hasSamePrivacyIdentity(as other: FocusPrivacyIdentitySample) -> Bool {
    applicationActivationRevision == other.applicationActivationRevision
      && focus.processIdentifier == other.focus.processIdentifier
      && focus.bundleIdentifier == other.focus.bundleIdentifier
      && focus.applicationName == other.focus.applicationName
      && focus.secureInput == other.focus.secureInput
  }
}
