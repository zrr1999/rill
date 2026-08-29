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
    switch (status, language) {
    case (.ready, _):
      return nil
    case (
      .readyWithNotice(.alternateDataProtectionKeyRetained),
      .english
    ):
      return LocalPersistenceStatusPresentation(
        bannerTitle: "Local storage is protected",
        bannerMessage:
          "Rill found an additional local data protection key and retained both "
          + "keys to avoid deleting data. Saved data remains available and changes "
          + "continue to be saved. No action is required, and no saved data was reset "
          + "or deleted.",
        actionTitle: nil,
        menuTitle: "Additional protection key retained",
        menuDetail: "Local storage remains active; both protected keys were kept for safety."
      )
    case (
      .readyWithNotice(.alternateDataProtectionKeyRetained),
      .simplifiedChinese
    ):
      return LocalPersistenceStatusPresentation(
        bannerTitle: "本地存储已受保护",
        bannerMessage:
          "Rill 发现了另一把本地数据保护密钥。为避免删除数据，两把密钥均已保留；已保存"
          + "的数据仍可使用，后续更改也会继续保存。无需执行任何操作，已有数据未被重置或删除。",
        actionTitle: nil,
        menuTitle: "已保留另一把数据保护密钥",
        menuDetail: "本地存储仍正常工作；为确保数据安全，两把受保护密钥均已保留。"
      )
    case (
      .sessionOnly(reason: .persistentStorageUnavailable),
      .english
    ):
      return LocalPersistenceStatusPresentation(
        bannerTitle: "Local data is session-only",
        bannerMessage:
          "History, records and collections, settings, and other local changes "
          + "from this session will not be saved after Rill quits. Existing saved "
          + "data was not reset or deleted.",
        actionTitle: "View Storage Settings",
        menuTitle: "Session-only storage",
        menuDetail: "History, clipboard, and settings changes are not being saved."
      )
    case (
      .sessionOnly(reason: .persistentStorageUnavailable),
      .simplifiedChinese
    ):
      return LocalPersistenceStatusPresentation(
        bannerTitle: "本地数据仅在本次会话中可用",
        bannerMessage:
          "本次会话中的运行历史、记录与记录集、设置及其他本地更改不会在 Rill "
          + "退出后保存；已有数据未被重置或删除。",
        actionTitle: "查看存储设置",
        menuTitle: "存储仅限本次会话",
        menuDetail: "历史记录、剪贴板和设置更改当前不会保存。"
      )
    case (
      .sessionOnly(reason: .keychainTemporarilyUnavailable),
      .english
    ):
      return LocalPersistenceStatusPresentation(
        bannerTitle: "Unlock your Mac to restore local storage",
        bannerMessage:
          "Rill could not access its local data protection key. This session's "
          + "history, records and collections, settings, and other local changes "
          + "will not be saved. Unlock your Mac, then quit and reopen Rill. "
          + "Existing saved data was not reset or deleted.",
        actionTitle: "View Storage Settings",
        menuTitle: "Local storage is locked",
        menuDetail: "Unlock your Mac, then quit and reopen Rill to restore saving."
      )
    case (
      .sessionOnly(reason: .keychainTemporarilyUnavailable),
      .simplifiedChinese
    ):
      return LocalPersistenceStatusPresentation(
        bannerTitle: "解锁 Mac 以恢复本地存储",
        bannerMessage:
          "Rill 无法访问本地数据保护密钥。本次会话中的运行历史、记录与记录集、设置"
          + "及其他本地更改不会保存。请解锁 Mac，然后退出并重新打开 Rill；已有数据未被"
          + "重置或删除。",
        actionTitle: "查看存储设置",
        menuTitle: "本地存储已锁定",
        menuDetail: "请解锁 Mac，然后退出并重新打开 Rill 以恢复保存。"
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
