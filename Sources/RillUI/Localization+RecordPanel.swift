import Foundation
import RillCore

enum RecordPanelText: CaseIterable {
  case drafts
  case collections
  case panelContent
  case keepOpen
  case keepOpenHelp
  case outputStatus
  case done
  case review
  case previousOutputNeedsConfirmation
  case localContent
  case deliveredButNotSaved
  case confirmInsertion
  case retrySave
  case inserted
  case retryItem
  case moveAndOpen
  case needsAttention
  case closeFloatingWindow
  case draftSources
  case configureDraftSources
  case draftList
  case newDraft
  case newItem
  case draftOptions
  case searchDrafts
  case sendWhenReady
  case doneEditing
  case copy
  case send
  case noMatchingDrafts
  case reviewEdits
  case reviewResults
  case collection
  case allRecords
  case searchAndFilterOptions
  case addToDrafts
}

extension L10n {
  static func recordPanel(_ key: RecordPanelText, language: AppLanguage) -> String {
    switch key {
    case .drafts: return catalogString("recordPanel.drafts", language: language)
    case .collections: return catalogString("recordPanel.collections", language: language)
    case .panelContent: return catalogString("recordPanel.panelContent", language: language)
    case .keepOpen: return catalogString("recordPanel.keepOpen", language: language)
    case .keepOpenHelp: return catalogString("recordPanel.keepOpenHelp", language: language)
    case .outputStatus: return catalogString("recordPanel.outputStatus", language: language)
    case .done: return catalogString("recordPanel.done", language: language)
    case .review: return catalogString("recordPanel.review", language: language)
    case .previousOutputNeedsConfirmation: return catalogString("recordPanel.previousOutputNeedsConfirmation", language: language)
    case .localContent: return catalogString("recordPanel.localContent", language: language)
    case .deliveredButNotSaved: return catalogString("recordPanel.deliveredButNotSaved", language: language)
    case .confirmInsertion: return catalogString("recordPanel.confirmInsertion", language: language)
    case .retrySave: return catalogString("recordPanel.retrySave", language: language)
    case .inserted: return catalogString("recordPanel.inserted", language: language)
    case .retryItem: return catalogString("recordPanel.retryItem", language: language)
    case .moveAndOpen: return catalogString("recordPanel.moveAndOpen", language: language)
    case .needsAttention: return catalogString("recordPanel.needsAttention", language: language)
    case .closeFloatingWindow: return catalogString("recordPanel.closeFloatingWindow", language: language)
    case .draftSources: return catalogString("recordPanel.draftSources", language: language)
    case .configureDraftSources: return catalogString("recordPanel.configureDraftSources", language: language)
    case .draftList: return catalogString("recordPanel.draftList", language: language)
    case .newDraft: return catalogString("recordPanel.newDraft", language: language)
    case .newItem: return catalogString("recordPanel.newItem", language: language)
    case .draftOptions: return catalogString("recordPanel.draftOptions", language: language)
    case .searchDrafts: return catalogString("recordPanel.searchDrafts", language: language)
    case .sendWhenReady: return catalogString("recordPanel.sendWhenReady", language: language)
    case .doneEditing: return catalogString("recordPanel.doneEditing", language: language)
    case .copy: return catalogString("recordPanel.copy", language: language)
    case .send: return catalogString("recordPanel.send", language: language)
    case .noMatchingDrafts: return catalogString("recordPanel.noMatchingDrafts", language: language)
    case .reviewEdits: return catalogString("recordPanel.reviewEdits", language: language)
    case .reviewResults: return catalogString("recordPanel.reviewResults", language: language)
    case .collection: return catalogString("recordPanel.collection", language: language)
    case .allRecords: return catalogString("recordPanel.allRecords", language: language)
    case .searchAndFilterOptions: return catalogString("recordPanel.searchAndFilterOptions", language: language)
    case .addToDrafts: return catalogString("recordPanel.addToDrafts", language: language)
    }
  }

  static func recordPanelCharacterCount(_ count: Int, language: AppLanguage) -> String {
    L10n.pluralString("count.characters", language: language, count)
  }
}
