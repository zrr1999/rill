import Foundation

extension L10n {
  enum PresentationKey: String, CaseIterable {
    case details, more, less, copied, editText, moreActions, metadata, builtinReadOnly
    case insertInto, saving, saved, unsavedTitle, unsavedDetail, discard, back
    case configuration, clearSearch, ready, noMatchingRecords, noMatchingRecordsDetail, clearFilters, nameRequired, invalidWorkflowID
  }

  static func presentation(_ key: PresentationKey, language: AppLanguage) -> String {
    catalogString("presentation.\(key.rawValue)", language: language)
  }
}
