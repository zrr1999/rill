import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var vocabularySection: some View {
    settingsDisclosure(.vocabulary) {
      if let vocabularyRulesError = model.vocabulary.error {
        settingsDomainLoadFailure(
          message: vocabularyRulesError,
          retryIdentifier: "settings.vocabulary.retry"
        )
      }

      VStack(alignment: .leading, spacing: RillSpacing.dense) {
        Text(L10n.string(.vocabularyDescription, language: model.settings.language))
          .font(.callout)
          .foregroundStyle(.secondary)
        ForEach(model.vocabulary.vocabularyCollections) { collection in
          VocabularyCollectionCard(model: model, collection: collection)
        }
      }
      .disabled(!model.areVocabularyRulesAvailable)
    }
    .disabled(model.settings.isLoading)
  }

  func settingsDomainLoadFailure(
    message: String,
    retryIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
        .font(.callout)
        .foregroundStyle(.orange)
      Button(L10n.historySettingsText(.retry, language: model.settings.language)) {
        model.retryUnavailableStoredSettingsDomains()
      }
      .buttonStyle(.bordered)
      .disabled(model.settings.isRetryingUnavailableSettingsDomains)
      .accessibilityIdentifier(retryIdentifier)
    }
  }

}
