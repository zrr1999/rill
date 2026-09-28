import Foundation
import RillCore

public struct EventFeedEntry: Identifiable, Equatable, Sendable {
  private struct PrivacyProtectedContent: Equatable, Sendable {
    let body: LocalizedText
    let fullPrefix: LocalizedText
    let summaryPrefix: LocalizedText
    let hiddenSummary: LocalizedText
  }

  public let id: UUID
  public let english: String
  public let simplifiedChinese: String
  private let privacyProtectedContent: PrivacyProtectedContent?

  public init(id: UUID = UUID(), english: String, simplifiedChinese: String) {
    self.id = id
    self.english = english
    self.simplifiedChinese = simplifiedChinese
    self.privacyProtectedContent = nil
  }

  init(
    id: UUID = UUID(),
    privacyProtectedBody: LocalizedText,
    fullPrefix: LocalizedText,
    summaryPrefix: LocalizedText,
    hiddenSummary: LocalizedText
  ) {
    self.id = id
    // Keep the legacy mode-unaware surface content-free. Body-bearing
    // activity must opt in to the privacy-aware presentation below.
    self.english = hiddenSummary.english
    self.simplifiedChinese = hiddenSummary.simplifiedChinese
    self.privacyProtectedContent = PrivacyProtectedContent(
      body: privacyProtectedBody,
      fullPrefix: fullPrefix,
      summaryPrefix: summaryPrefix,
      hiddenSummary: hiddenSummary
    )
  }

  public func text(for language: AppLanguage) -> String {
    switch language {
    case .english:
      return english
    case .simplifiedChinese:
      return simplifiedChinese
    }
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

    let body = content.body.string(for: language)
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
