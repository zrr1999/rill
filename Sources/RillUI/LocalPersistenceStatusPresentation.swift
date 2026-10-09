import SwiftUI
import RillCore

struct LocalPersistenceStatusPresentation: Sendable, Equatable {
  let bannerTitle: String
  let bannerMessage: String
  let actionTitle: String?
  let menuTitle: String
  let menuDetail: String

  static func make(
    status: LocalPersistenceStatus,
    language: AppLanguage
  ) -> LocalPersistenceStatusPresentation? {
    switch status {
    case .ready: return nil
    case .readyWithNotice(.alternateDataProtectionKeyRetained):
      return LocalPersistenceStatusPresentation(
        bannerTitle: L10n.catalogString("localPersistence.alternateDataProtectionKeyRetained.bannerTitle", language: language),
        bannerMessage: L10n.catalogString("localPersistence.alternateDataProtectionKeyRetained.bannerMessage", language: language),
        actionTitle: nil,
        menuTitle: L10n.catalogString("localPersistence.alternateDataProtectionKeyRetained.menuTitle", language: language),
        menuDetail: L10n.catalogString("localPersistence.alternateDataProtectionKeyRetained.menuDetail", language: language)
      )
    case .sessionOnly(reason: .persistentStorageUnavailable):
      return LocalPersistenceStatusPresentation(
        bannerTitle: L10n.catalogString("localPersistence.persistentStorageUnavailable.bannerTitle", language: language),
        bannerMessage: L10n.catalogString("localPersistence.persistentStorageUnavailable.bannerMessage", language: language),
        actionTitle: L10n.catalogString("localPersistence.persistentStorageUnavailable.actionTitle", language: language),
        menuTitle: L10n.catalogString("localPersistence.persistentStorageUnavailable.menuTitle", language: language),
        menuDetail: L10n.catalogString("localPersistence.persistentStorageUnavailable.menuDetail", language: language)
      )
    case .sessionOnly(reason: .keychainTemporarilyUnavailable):
      return LocalPersistenceStatusPresentation(
        bannerTitle: L10n.catalogString("localPersistence.keychainTemporarilyUnavailable.bannerTitle", language: language),
        bannerMessage: L10n.catalogString("localPersistence.keychainTemporarilyUnavailable.bannerMessage", language: language),
        actionTitle: L10n.catalogString("localPersistence.keychainTemporarilyUnavailable.actionTitle", language: language),
        menuTitle: L10n.catalogString("localPersistence.keychainTemporarilyUnavailable.menuTitle", language: language),
        menuDetail: L10n.catalogString("localPersistence.keychainTemporarilyUnavailable.menuDetail", language: language)
      )
    }
  }
}

enum LocalPersistenceBannerFocusPolicy {
  /// A newly visible warning must never replace the current first responder.
  static let requestsFocusOnAppearance = false

  /// Focused navigation is allowed only after the user activates the banner
  /// action. The typed settings request then owns the destination focus.
  static let actionDestination = SettingsSection.storage
}

struct LocalPersistenceStatusBanner: View {
  let presentation: LocalPersistenceStatusPresentation
  let openStorageSettings: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: RillSystemSymbol.externaldriveBadgeExclamationmark.rawValue)
        .font(.title3)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(presentation.bannerTitle)
          .font(.callout.weight(.semibold))
        Text(presentation.bannerMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      if let actionTitle = presentation.actionTitle {
        Button(actionTitle, action: openStorageSettings)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("persistence.status.open-storage-settings")
      }
    }
    // Prominent-tier card; the caution semantics are carried by the orange
    // icon rather than a custom tinted fill.
    .rillCard(.prominent, cornerRadius: 10, padding: 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("persistence.status.banner")
  }
}
