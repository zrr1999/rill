import Foundation
import RillCore
import RillInputMethodContracts
import RillInputMethodIPC

extension AppModel {
  public func installInputMethodFeature(
    privacy: @escaping () throws -> PrivacyPolicySettings,
    install: @escaping (URL?) async throws -> String,
    bridgeDirectory: String = LocalInputMethodChannel.directory
  ) {
    guard let settingsStore else { return }
    let input = InputMethodFeatureModel(
      settings: settingsStore, privacy: privacy,
      confirmRule: { [weak self] phrase, id in
        guard let self else { throw CocoaError(.userCancelled) }
        let outcome = self.saveVocabularyCorrectionRule(
          VocabularyRule(id: id, kind: .hotword, pattern: phrase, replacement: ""))
        let ruleID: UUID
        let ownsRule: Bool
        switch outcome {
        case .created(let id):
          ruleID = id
          ownsRule = true
        case .reused(let existingID):
          ruleID = existingID
          ownsRule = existingID == id
        default: throw CocoaError(.fileWriteUnknown)
        }
        await self.persistenceWrites.flush()
        guard let encoded = try await settingsStore.string(forKey: .vocabularyLibrary),
          let document = try? JSONDecoder().decode(
            VocabularyLibraryDocument.self, from: Data(encoded.utf8)),
          document.collections.contains(where: {
            $0.entries.contains(where: { $0.id == ruleID && $0.enabled })
          })
        else { throw CocoaError(.fileWriteUnknown) }
        return (ruleID, ownsRule)
      },
      revokeRule: { [weak self] id in
        guard let self else { throw CocoaError(.userCancelled) }
        self.deleteVocabularyRule(id)
        await self.persistenceWrites.flush()
        guard let encoded = try await settingsStore.string(forKey: .vocabularyLibrary),
          let document = try? JSONDecoder().decode(
            VocabularyLibraryDocument.self, from: Data(encoded.utf8)),
          !document.collections.contains(where: { $0.entries.contains(where: { $0.id == id }) })
        else { throw CocoaError(.fileWriteUnknown) }
      }, install: install,
      ownedRuleIDs: {
        guard let encoded = try await settingsStore.string(forKey: .vocabularyLibrary) else {
          return []
        }
        let document = try JSONDecoder().decode(
          VocabularyLibraryDocument.self, from: Data(encoded.utf8))
        return Set(document.collections.flatMap { $0.entries.map(\.id) })
      }, bridgeDirectory: bridgeDirectory)
    inputMethod = input
    input.start()
  }
}
