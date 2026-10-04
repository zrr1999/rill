import RillCore

enum CorpusArchiveTextKey: String, CaseIterable {
  case title, disclosure, empty, selectAll, selectNone, source, chooseSource
  case microphone, synthetic, publicFixture, split, development, validation
  case cleanupPending, authorize, exported, showInFinder, close, exportSelection, completed, failed, cancelled
}

extension L10n {
  static func corpusArchive(_ key: CorpusArchiveTextKey, language: AppLanguage) -> String {
    catalogString("corpusArchive.\(key.rawValue)", language: language)
  }

}
