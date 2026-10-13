import Foundation
import RillCore

public struct EventFeedEntry: Identifiable, Equatable, Sendable {
  private struct PrivacyProtectedContent: Equatable, Sendable {
    let body: String
    let fullPrefix: LocalizedStringResource
    let summaryPrefix: LocalizedStringResource
    let hiddenSummary: LocalizedStringResource
  }

  public let id: UUID
  private let message: LocalizedStringResource
  private let privacyProtectedContent: PrivacyProtectedContent?

  public init(id: UUID = UUID(), _ message: LocalizedStringResource) {
    self.id = id
    self.message = message
    self.privacyProtectedContent = nil
  }

  public var english: String { text(for: .english) }
  public var simplifiedChinese: String { text(for: .simplifiedChinese) }

  init(
    id: UUID = UUID(),
    privacyProtectedBody: String,
    fullPrefix: LocalizedStringResource,
    summaryPrefix: LocalizedStringResource,
    hiddenSummary: LocalizedStringResource
  ) {
    self.id = id
    // Only privacy-aware presentation may reveal the body.
    self.message = hiddenSummary
    self.privacyProtectedContent = PrivacyProtectedContent(
      body: privacyProtectedBody,
      fullPrefix: fullPrefix,
      summaryPrefix: summaryPrefix,
      hiddenSummary: hiddenSummary
    )
  }

  public func text(for language: AppLanguage) -> String {
    message.string(for: language)
  }

  func presentation(
    for language: AppLanguage,
    historyPreviewMode: PrivacyHistoryPreviewMode
  ) -> EventFeedPresentation {
    guard let content = privacyProtectedContent else {
      let text = text(for: language)
      return EventFeedPresentation(
        text: text,
        accessibilityLabel: text,
        lineLimit: nil
      )
    }

    let body = content.body
    guard
      let preview = HistoryPreviewPresentation(
        text: body,
        mode: historyPreviewMode,
        language: language
      )
    else {
      let text = content.hiddenSummary.string(for: language)
      return EventFeedPresentation(
        text: text,
        accessibilityLabel: text,
        lineLimit: nil
      )
    }

    let text: String
    let lineLimit: Int?
    switch preview {
    case .visible(let visibleBody, let previewLineLimit):
      let prefix =
        historyPreviewMode == .full
        ? content.fullPrefix.string(for: language)
        : content.summaryPrefix.string(for: language)
      text = prefix + visibleBody
      lineLimit = previewLineLimit
    case .hidden(let message):
      text = content.hiddenSummary.string(for: language) + " " + message
      lineLimit = nil
    }

    return EventFeedPresentation(
      text: text,
      accessibilityLabel: text,
      lineLimit: lineLimit
    )
  }
}

struct EventFeedPresentation: Equatable, Sendable {
  let text: String
  let accessibilityLabel: String
  let lineLimit: Int?
}
