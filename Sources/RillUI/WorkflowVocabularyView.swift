import SwiftUI
import RillCore

struct VocabularyCollectionCard: View {
  @Bindable var model: AppModel
  let collection: VocabularyCollection

  @State private var isExpanded = true
  @State private var editingEntry: VocabularyEntry?
  @State private var isAddingEntry = false
  @State private var confirmsCollectionDeletion = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Toggle(
          collection.name,
          isOn: Binding(
            get: { collection.enabled },
            set: { model.vocabulary.setVocabularyCollectionEnabled(collection.id, isEnabled: $0) }
          )
        )
        .toggleStyle(.checkbox)
        Spacer()
        Button {
          isExpanded.toggle()
        } label: {
          Label(
            L10n.workflowVocabularyEntryCount(collection.entries.count, language: model.settings.language),
            systemImage: isExpanded ? "chevron.down" : "chevron.right"
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(L10n.workflowText(.workflowCollectionEntriesToggle, language: model.settings.language)): \(collection.name)"
        )
        if collection.id != VocabularyCollection.personalID {
          Button(role: .destructive) {
            confirmsCollectionDeletion = true
          } label: {
            Image(systemName: RillSystemSymbol.trash.rawValue)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            "\(L10n.workflowText(.workflowDeleteCollection, language: model.settings.language)): \(collection.name)"
          )
          .accessibilityIdentifier("vocabulary.collection.\(collection.id.uuidString).delete")
        }
      }

      if isExpanded {
        scopeSummary
        ForEach(collection.entries) { entry in
          HStack {
            Toggle(
              entryTitle(entry),
              isOn: Binding(
                get: { entry.enabled },
                set: { model.vocabulary.setVocabularyRuleEnabled(entry.id, isEnabled: $0) }
              )
            )
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("vocabulary.entry.\(entry.id.uuidString).enabled")
            Spacer()
            Button {
              isAddingEntry = false
              editingEntry = entry
            } label: {
              Image(systemName: "pencil")
            }
            .accessibilityLabel("\(text(.vocabularyEditRule)): \(entryTitle(entry))")
            .accessibilityIdentifier("vocabulary.entry.\(entry.id.uuidString).edit")
            Button(role: .destructive) {
              model.vocabulary.deleteVocabularyEntry(entry.id, from: collection.id)
            } label: {
              Image(systemName: RillSystemSymbol.trash.rawValue)
            }
            .accessibilityLabel(
              L10n.targetedAccessibilityLabel(
                .vocabularyDeleteRule, target: entryTitle(entry), language: model.settings.language
              )
            )
            .accessibilityIdentifier("vocabulary.entry.\(entry.id.uuidString).delete")
          }
        }
        Button(text(.vocabularyAddRule)) {
          isAddingEntry = true
          editingEntry = VocabularyEntry(content: .hotword(phrase: ""))
        }
        .accessibilityIdentifier("vocabulary.collection.\(collection.id.uuidString).add")
      }
    }
    .rillCard(.regular, cornerRadius: RillRadius.row, padding: RillSpacing.dense)
    .alert(
      L10n.workflowText(.workflowDeleteCollectionTitle, language: model.settings.language),
      isPresented: $confirmsCollectionDeletion
    ) {
      Button(L10n.recordText(.cancel, language: model.settings.language), role: .cancel) {}
      Button(L10n.text(.clipboardDeleteItem, language: model.settings.language), role: .destructive) {
        model.deleteVocabularyCollection(collection.id)
      }
    } message: {
      Text(L10n.workflowText(.workflowDeleteCollectionDetail, language: model.settings.language))
    }
    .sheet(item: $editingEntry) { entry in
      let isNew = isAddingEntry
      VocabularyEntryEditor(
        entry: entry, isNew: isNew, language: model.settings.language,
        save: { proposed in
          if !isNew {
            return model.vocabulary.updateVocabularyEntry(proposed, in: collection.id)
          }
          return model.vocabulary.addVocabularyEntry(proposed, to: collection.id)
        }
      )
    }
  }

  private var scopeSummary: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(model.vocabulary.vocabularyCollectionBindings.filter { $0.collectionID == collection.id }) { binding in
        let scope = VocabularyRuleScope(
          bundleIdentifier: binding.condition.bundleIdentifier,
          recordCollectionID: binding.condition.recordCollectionID,
          locale: binding.condition.locale
        )
        Text(
          L10n.vocabularyScopeSummary(
            scope,
            groupName: model.recordWorkspace.snapshot.collections.first {
              $0.id.rawValue == scope.recordCollectionID
            }?.name,
            language: model.settings.language
          ))
      }
      Text(text(.vocabularyWorkflowBindings))
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func text(_ key: L10n.Key) -> String {
    L10n.string(key, language: model.settings.language)
  }

  private func entryTitle(_ entry: VocabularyEntry) -> String {
    let rule = entry.legacyRule()
    return rule.kind == .mapping ? "\(rule.pattern) → \(rule.replacement)" : rule.pattern
  }
}

private struct VocabularyEntryEditor: View {
  let entry: VocabularyEntry
  let isNew: Bool
  let language: AppLanguage
  let save: (VocabularyEntry) -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var rule: VocabularyRule
  @State private var sample = ""
  @State private var saveFailed = false

  init(entry: VocabularyEntry, isNew: Bool, language: AppLanguage, save: @escaping (VocabularyEntry) -> Bool) {
    self.entry = entry
    self.isNew = isNew
    self.language = language
    self.save = save
    _rule = State(initialValue: entry.legacyRule())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(text(isNew ? .vocabularyAddRule : .vocabularyEditRule)).font(.headline)
      Form {
        Picker(text(.vocabularyKind), selection: $rule.kind) {
          ForEach([VocabularyRuleKind.hotword, .mapping], id: \.self) { kind in
            Text(L10n.vocabularyRuleKind(kind, language: language)).tag(kind)
          }
        }
        TextField(text(.vocabularyPattern), text: $rule.pattern)
          .accessibilityIdentifier("vocabulary.editor.pattern")
        if rule.kind == .mapping {
          TextField(text(.vocabularyReplacement), text: $rule.replacement)
          Picker(text(.vocabularyMatchMode), selection: $rule.matchMode) {
            ForEach([VocabularyMatchMode.exactPhrase, .wordBoundary, .regex], id: \.self) { mode in
              Text(L10n.vocabularyMatchMode(mode, language: language)).tag(mode)
            }
          }
          Toggle(text(.vocabularyCaseSensitive), isOn: $rule.caseSensitive)
          TextField(text(.vocabularyPriority), value: $rule.priority, format: .number)
          if rule.matchMode == .regex {
            Text(text(.vocabularyRegexPreviewNote))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            TextField(text(.vocabularyPreviewInput), text: $sample, axis: .vertical)
              .lineLimit(2...5)
            LabeledContent(text(.vocabularyPreviewResult)) {
              Text(preview.text).textSelection(.enabled)
            }
          }
        } else {
          Text(text(.vocabularyHotwordBehavior))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if !isValid {
        Text(text(.vocabularyInvalidRule)).foregroundStyle(.orange)
      }
      if saveFailed {
        Text(text(.vocabularyEditFailed)).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button(text(.vocabularyCorrectionCancel), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(text(.vocabularyCorrectionSave)) {
          if save(VocabularyEntry(rule: normalizedRule)) { dismiss() } else { saveFailed = true }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
        .accessibilityIdentifier("vocabulary.editor.save")
      }
    }
    .padding(20)
    .frame(minWidth: 480, idealWidth: 560)
  }

  private var normalizedRule: VocabularyRule {
    var result = rule
    result.pattern = result.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    result.replacement = result.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    // Preview represents an enabled rule; editing never changes its stored enabled state.
    result.enabled = true
    return result
  }

  private var preview: VocabularyApplicationResult {
    VocabularyRuleApplicator.apply(text: rule.matchMode == .regex ? "" : sample, rules: [normalizedRule], context: .init())
  }

  private var isValid: Bool {
    !normalizedRule.pattern.isEmpty && (rule.kind == .hotword || preview.issues.isEmpty)
  }

  private func text(_ key: L10n.Key) -> String { L10n.string(key, language: language) }
}
