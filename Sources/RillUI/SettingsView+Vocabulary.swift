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

      VStack(alignment: .leading, spacing: 10) {
        Text(L10n.settingsText(.settingsVocabularyMovedNotice, language: model.settings.language))
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach(model.vocabulary.vocabularyCollections) { collection in
          HStack {
            Label(
              collection.name,
              systemImage: collection.enabled
                ? RillSystemSymbol.textBookClosedFill.rawValue
                : RillSystemSymbol.textBookClosed.rawValue
            )
            Spacer()
            Text("\(collection.entries.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }

        Button {
          model.selectSidebarSection(.workflows)
        } label: {
          Label(
            L10n.settingsText(
              .settingsManageVocabularyCollections,
              language: model.settings.language
            ),
            systemImage: SidebarSection.workflows.symbolName
          )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.vocabulary.open-workflows")
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

  var vocabularyRuleKinds: [VocabularyRuleKind] {
    [.hotword, .mapping]
  }

  var vocabularyMatchModes: [VocabularyMatchMode] {
    [.exactPhrase, .wordBoundary, .regex]
  }

  var vocabularyGroupChoices: [RecordCollection] {
    model.recordWorkspace.snapshot.collections
  }

  func vocabularyRuleRow(_ rule: VocabularyRule) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        L10n.targetedAccessibilityLabel(
          .vocabularyRule,
          target: vocabularyRuleTitle(rule),
          language: model.settings.language
        ),
        isOn: Binding(
          get: { rule.enabled },
          set: { model.setVocabularyRuleEnabled(rule.id, isEnabled: $0) }
        )
      )
      .labelsHidden()
      .accessibilityIdentifier("vocabulary.rule.\(rule.id.uuidString).enabled")

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(L10n.vocabularyRuleKind(rule.kind, language: model.settings.language))
            .font(.caption.weight(.semibold))
          if rule.kind == .mapping {
            Text(L10n.vocabularyMatchMode(rule.matchMode, language: model.settings.language))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(vocabularyRuleTitle(rule))
          .font(.subheadline.weight(.medium))

        Text(vocabularyScopeSummary(rule.scope))
          .font(.caption)
          .foregroundStyle(.secondary)

        if rule.kind == .hotword {
          Text(L10n.string(.vocabularyHotwordBehavior, language: model.settings.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Button(role: .destructive) {
        model.deleteVocabularyRule(rule.id)
      } label: {
        Image(systemName: RillSystemSymbol.trash.rawValue)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        L10n.targetedAccessibilityLabel(
          .vocabularyDeleteRule,
          target: vocabularyRuleTitle(rule),
          language: model.settings.language
        )
      )
      .accessibilityIdentifier("vocabulary.rule.\(rule.id.uuidString).delete")
    }
  }

  func vocabularyRuleTitle(_ rule: VocabularyRule) -> String {
    if rule.kind == .mapping, !rule.replacement.isEmpty {
      return "\(rule.pattern) → \(rule.replacement)"
    }
    return rule.pattern
  }

  func vocabularyScopeSummary(_ scope: VocabularyRuleScope) -> String {
    L10n.vocabularyScopeSummary(
      scope,
      groupName: vocabularyGroupName(scope.recordCollectionID),
      language: model.settings.language
    )
  }

  func vocabularyGroupName(_ groupID: UUID?) -> String? {
    guard let groupID else { return nil }
    return vocabularyGroupChoices.first(where: { $0.id.rawValue == groupID })?.name
  }

  func addVocabularyRule() {
    model.addVocabularyRule(
      kind: vocabularyKind,
      pattern: vocabularyPattern,
      replacement: vocabularyKind == .mapping ? vocabularyReplacement : "",
      matchMode: vocabularyMatchMode,
      caseSensitive: vocabularyCaseSensitive,
      scope: VocabularyRuleScope(
        bundleIdentifier: trimmedOptional(vocabularyBundleIdentifier),
        recordCollectionID: vocabularyGroupID,
        locale: trimmedOptional(vocabularyLocale)
      ),
      priority: vocabularyPriority
    )
    vocabularyPattern = ""
    vocabularyReplacement = ""
    vocabularyPriority = 0
  }

  func trimmedOptional(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

}
