import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var vocabularySection: some View {
    settingsDisclosure(.vocabulary) {
      if let vocabularyRulesError = model.vocabularyRulesError {
        settingsDomainLoadFailure(
          message: vocabularyRulesError,
          retryIdentifier: "settings.vocabulary.retry"
        )
      }

      VStack(alignment: .leading, spacing: 10) {
        Text(
          model.language == .english
            ? "Hotwords and replacements now live in reusable collections attached to workflow Setup."
            : "热词与替换词现在位于可复用词库中，并在工作流 Setup 阶段绑定。"
        )
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach(model.vocabularyCollections) { collection in
          HStack {
            Label(
              collection.name,
              systemImage: collection.enabled
                ? "text.book.closed.fill"
                : "text.book.closed"
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
            model.language == .english
              ? "Manage Collections and Workflow Bindings"
              : "管理词库与工作流绑定",
            systemImage: SidebarSection.workflows.symbolName
          )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.vocabulary.open-workflows")
      }
      .disabled(!model.areVocabularyRulesAvailable)
    }
    .disabled(model.isLoadingSettings)
  }

  func settingsDomainLoadFailure(
    message: String,
    retryIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
        .font(.callout)
        .foregroundStyle(.orange)
      Button(L10n.historySettingsText(.retry, language: model.language)) {
        model.retryUnavailableStoredSettingsDomains()
      }
      .buttonStyle(.bordered)
      .disabled(model.isRetryingUnavailableSettingsDomains)
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
        UIStrings.targetedAccessibilityLabel(
          .vocabularyRule,
          target: vocabularyRuleTitle(rule),
          language: model.language
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
          Text(L10n.vocabularyRuleKind(rule.kind, language: model.language))
            .font(.caption.weight(.semibold))
          if rule.kind == .mapping {
            Text(L10n.vocabularyMatchMode(rule.matchMode, language: model.language))
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
          Text(L10n.string(.vocabularyHotwordBehavior, language: model.language))
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
        UIStrings.targetedAccessibilityLabel(
          .vocabularyDeleteRule,
          target: vocabularyRuleTitle(rule),
          language: model.language
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
      language: model.language
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
