import Foundation

extension L10n {
  static func contextMemoryFailure(_ failure: ContextMemoryFailure) -> LocalizedStringResource {
    switch failure {
    case .settingsLoad:
      L10n.resource("Localization.ContextMemory.Context.settings.could.not.be.loaded")
    case .revocation:
      L10n.resource("Localization.ContextMemory.Authorization.revocation.could.not.be.saved")
    case .authorization:
      L10n.resource("Localization.ContextMemory.Context.settings.could.not.be.saved.or.authorized")
    case .storage:
      L10n.resource("Localization.ContextMemory.Memory.storage.is.unavailable")
    case .mutation:
      L10n.resource("Localization.ContextMemory.Memory.could.not.be.changed.Your.draft.is.retained.refresh.and.retry")
    case .correction:
      L10n.resource("Localization.ContextMemory.Correction.could.not.be.linked.to.history")
    case .unavailable:
      L10n.resource("Localization.ContextMemory.Memory.editing.is.unavailable.while.Rill.is.shutting.down")
    }
  }
}
