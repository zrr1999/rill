import SwiftUI
import RillCore

public struct VocabularyCorrectionSheet: View {
  private enum SaveIssue: Equatable {
    case conflict
    case invalid
    case notReady
    case persistence
  }

  private enum SavedRuleFeedback: Equatable {
    case created
    case reused
  }

  @Environment(\.dismiss) private var dismiss
  @Bindable private var model: AppModel
  private let historyRecordID: UUID?
  private let textCorrectionSubject: RecordTextCorrectionSubject?
  @State private var correctionOperationID = UUID()
  @State private var isSavingText = false
  @State private var isSavingRule = false
  @State private var pendingRule: VocabularyRule?
  @State private var pendingFeedback: SavedRuleFeedback?
  @State private var savedRuleFeedback: SavedRuleFeedback?
  @State private var draft: VocabularyCorrectionDraft
  @State private var saveIssue: SaveIssue?
  @State private var targetCollectionID: UUID?

  public init(model: AppModel, source: RecognitionCorrectionSource, historyRecordID: UUID? = nil, workflowRunID: UUID? = nil) {
    self.init(model: model, source: source, historyRecordID: historyRecordID, subject: workflowRunID.map(RecordTextCorrectionSubject.workflowRun))
  }

  public init(model: AppModel, source: RecognitionCorrectionSource, recordID: RecordID) {
    self.init(model: model, source: source, historyRecordID: nil, subject: .record(recordID))
  }

  private init(model: AppModel, source: RecognitionCorrectionSource, historyRecordID: UUID?, subject: RecordTextCorrectionSubject?) {
    self.historyRecordID = historyRecordID
    self.textCorrectionSubject = subject
    self.model = model
    _draft = State(initialValue: VocabularyCorrectionDraft(source: source))
    _targetCollectionID = State(initialValue: VocabularyCollection.personalID)
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          introduction
          recognitionEditor
          suggestionSection
          if draft.selectedOption != nil {
            scopeSection
          }
          saveIssueSection
        }
        .padding(24)
      }

      Divider()
      actionBar
        .padding(16)
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 600)
    .interactiveDismissDisabled(isSavingText || isSavingRule)
    .onChange(of: model.settings.privacyPolicySettings.historyPreviewMode) { _, mode in
      if mode == .disabled {
        dismiss()
      }
    }
  }

  private var introduction: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.string(.vocabularyCorrectionTitle, language: model.settings.language))
        .font(.title2.bold())
      Text(L10n.string(.vocabularyCorrectionDescription, language: model.settings.language))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var recognitionEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.string(.vocabularyCorrectionOriginalText, language: model.settings.language))
          .font(.headline)
        Text(draft.originalText)
          .textSelection(.enabled)
          .rillCard(.regular, cornerRadius: RillRadius.badge, padding: RillSpacing.dense)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.string(.vocabularyCorrectionCorrectedText, language: model.settings.language))
          .font(.headline)
        TextEditor(text: correctedTextBinding)
          .disabled(isSavingText || isSavingRule || savedRuleFeedback != nil)
          .font(.body)
          .frame(minHeight: 110)
          .padding(6)
          .background(.background, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(.separator, lineWidth: 1)
          }
          .accessibilityLabel(
            L10n.string(.vocabularyCorrectionCorrectedText, language: model.settings.language)
          )
      }
    }
  }

  @ViewBuilder
  private var suggestionSection: some View {
    VStack(alignment: .leading, spacing: RillSpacing.dense) {
      Text(L10n.string(.vocabularyCorrectionSuggestions, language: model.settings.language))
        .font(.headline)

      switch draft.status {
      case .unchanged:
        guidance(
          L10n.string(.vocabularyCorrectionNoChange, language: model.settings.language),
          symbol: RillSystemSymbol.pencil.rawValue
        )
      case .invalid:
        guidance(
          L10n.string(.vocabularyCorrectionUnsupported, language: model.settings.language),
          symbol: RillSystemSymbol.exclamationmarkTriangle.rawValue
        )
        Button(L10n.string(.vocabularyCorrectionOpenSettings, language: model.settings.language)) {
          openVocabularySettings()
        }
      case .optionsAvailable:
        ForEach(draft.options) { option in
          optionRow(option)
        }
      }
    }
  }

  private func optionRow(_ option: VocabularyCorrectionDraft.Option) -> some View {
    Button {
      draft.selectOption(id: option.id)
      targetCollectionID =
        compatibleCollections(for: option.scope.knownConstraints).first?.id
      saveIssue = nil
    } label: {
      HStack(alignment: .top, spacing: RillSpacing.dense) {
        Image(
          systemName: draft.selectedOptionID == option.id
            ? RillSystemSymbol.largecircleFillCircle.rawValue
            : RillSystemSymbol.circle.rawValue
        )
        .foregroundStyle(draft.selectedOptionID == option.id ? Color.accentColor : .secondary)

        VStack(alignment: .leading, spacing: 4) {
          Text(optionTitle(option))
            .font(.body.weight(.medium))
          Text(optionSummary(option))
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .padding(RillSpacing.dense)
      .rillSelection(draft.selectedOptionID == option.id, cornerRadius: RillRadius.row)
    }
    .buttonStyle(RillHoverButtonStyle(kind: .card(cornerRadius: RillRadius.row)))
    .accessibilityLabel("\(optionTitle(option)): \(optionSummary(option))")
    .accessibilityAddTraits(draft.selectedOptionID == option.id ? .isSelected : [])
  }

  private var scopeSection: some View {
    VStack(alignment: .leading, spacing: RillSpacing.dense) {
      Text(L10n.string(.vocabularyCorrectionScopeTitle, language: model.settings.language))
        .font(.headline)
      Text(L10n.string(.vocabularyCorrectionScopeDescription, language: model.settings.language))
        .font(.callout)
        .foregroundStyle(.secondary)

      if let option = draft.selectedOption {
        Text(scopeSummary(option.scope.knownConstraints))
          .font(.callout.monospaced())
          .textSelection(.enabled)

        ForEach(VocabularyCorrectionScopeField.allCases, id: \.self) { field in
          if option.scope.unknownFields.contains(field) {
            Toggle(
              unknownScopeLabel(field),
              isOn: unknownScopeBinding(field)
            )
            .toggleStyle(.checkbox)
          }
        }

        Picker(
          L10n.overlayText(.correctionSaveToCollection, language: model.settings.language),
          selection: $targetCollectionID
        ) {
          Text(
            L10n.overlayText(.correctionCreateScopedCollection, language: model.settings.language)
          )
          .tag(nil as UUID?)
          ForEach(compatibleCollections(for: option.scope.knownConstraints)) {
            collection in
            Text(collection.name).tag(collection.id as UUID?)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("vocabulary.correction.target-collection")
      }
    }
    .rillCard(.subdued, cornerRadius: RillRadius.row, padding: 12)
  }

  @ViewBuilder
  private var saveIssueSection: some View {
    switch saveIssue {
    case .conflict:
      VStack(alignment: .leading, spacing: 8) {
        Label(
          L10n.string(.vocabularyCorrectionConflict, language: model.settings.language),
          systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
        )
        .foregroundStyle(.orange)
        Button(L10n.string(.vocabularyCorrectionOpenSettings, language: model.settings.language)) {
          openVocabularySettings()
        }
      }
    case .invalid:
      VStack(alignment: .leading, spacing: 8) {
        Label(
          L10n.string(.vocabularyCorrectionUnsupported, language: model.settings.language),
          systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
        )
        .foregroundStyle(.secondary)
        Button(L10n.string(.vocabularyCorrectionOpenSettings, language: model.settings.language)) {
          openVocabularySettings()
        }
      }
    case .persistence:
      VStack(alignment: .leading, spacing: 8) {
        Label(
          L10n.resource("vocabulary.ruleSaveFailed").string(for: model.settings.language),
          systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
        )
        .foregroundStyle(.red)
        if let pendingRule, let pendingFeedback {
          Button(L10n.text(.settingsSaveRetry, language: model.settings.language)) {
            finishRuleSave(pendingRule, feedback: pendingFeedback, retry: true)
          }
          .disabled(isSavingRule)
          .accessibilityIdentifier("vocabulary.correction.retry-save")
        }
      }
    case .notReady:
      Label(
        L10n.overlayText(.correctionSettingsLoading, language: model.settings.language),
        systemImage: RillSystemSymbol.clock.rawValue
      )
      .foregroundStyle(.secondary)
    case nil:
      if let savedRuleFeedback {
        Label(
          L10n.resource(
            savedRuleFeedback == .created
              ? "general.vocabularyCorrectionCreated"
              : "general.vocabularyCorrectionReused"
          ).string(for: model.settings.language),
          systemImage: RillSystemSymbol.checkmarkCircle.rawValue
        )
        .foregroundStyle(.green)
        .accessibilityIdentifier("vocabulary.correction.saved")
      }
    }
  }

  private var actionBar: some View {
    HStack {
      Button(L10n.string(.vocabularyCorrectionCancel, language: model.settings.language)) {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .disabled(isSavingText || isSavingRule)

      Spacer()

      if savedRuleFeedback != nil {
        Button(L10n.workspace(.done, language: model.settings.language)) {
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("vocabulary.correction.done")
      } else {
        Button(L10n.string(.vocabularyCorrectionSave, language: model.settings.language)) {
          saveRule()
        }
        .disabled(draft.proposedRule == nil || model.settings.isLoading || isSavingText || isSavingRule)
        .accessibilityIdentifier("vocabulary.correction.remember")
      }

      if textCorrectionSubject != nil {
        Button(L10n.string(.vocabularyCorrectionSaveText, language: model.settings.language)) {
          saveText()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(
          isSavingText || isSavingRule || savedRuleFeedback != nil || model.recordWorkspace.isMutating
            || draft.correctedText == draft.originalText
            || draft.correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityIdentifier("vocabulary.correction.save-text")
      }
    }
  }

  private var correctedTextBinding: Binding<String> {
    Binding(
      get: { draft.correctedText },
      set: { text in
        draft.updateCorrectedText(text)
        correctionOperationID = UUID()
        saveIssue = nil
      }
    )
  }

  private func unknownScopeBinding(_ field: VocabularyCorrectionScopeField) -> Binding<Bool> {
    Binding(
      get: { draft.confirmedAnyScopeFields.contains(field) },
      set: { isConfirmed in
        draft.setAnyScopeConfirmed(isConfirmed, for: field)
        saveIssue = nil
      }
    )
  }

  private func optionTitle(_ option: VocabularyCorrectionDraft.Option) -> String {
    switch option.kind {
    case .mapping:
      return L10n.string(.vocabularyCorrectionMappingOption, language: model.settings.language)
    case .hotword:
      return L10n.string(.vocabularyCorrectionHotwordOption, language: model.settings.language)
    }
  }

  private func optionSummary(_ option: VocabularyCorrectionDraft.Option) -> String {
    switch option.kind {
    case .mapping:
      return "\(option.pattern) → \(option.replacement.isEmpty ? "∅" : option.replacement)"
    case .hotword:
      return option.pattern
    }
  }

  private func scopeSummary(_ scope: VocabularyRuleScope) -> String {
    L10n.vocabularyScopeSummary(
      scope,
      groupName: groupName(scope.recordCollectionID),
      language: model.settings.language
    )
  }

  private func groupName(_ groupID: UUID?) -> String? {
    guard let groupID else { return nil }
    return model.recordWorkspace.snapshot.collections
      .first(where: { $0.id.rawValue == groupID })?.name
      ?? groupID.uuidString
  }

  private func compatibleCollections(
    for scope: VocabularyRuleScope?
  ) -> [VocabularyCollection] {
    guard let scope else { return [] }
    let compatibleIDs = Set(model.vocabulary.vocabularyCollectionIDs(compatibleWith: scope))
    return model.vocabulary.vocabularyCollections.filter { compatibleIDs.contains($0.id) }
  }

  private func unknownScopeLabel(_ field: VocabularyCorrectionScopeField) -> String {
    switch field {
    case .bundleIdentifier:
      return L10n.string(.vocabularyCorrectionUnknownApp, language: model.settings.language)
    case .recordCollectionID:
      return L10n.string(.vocabularyCorrectionUnknownGroup, language: model.settings.language)
    case .locale:
      return L10n.string(.vocabularyCorrectionUnknownLanguage, language: model.settings.language)
    }
  }

  private func guidance(_ text: String, symbol: String) -> some View {
    Label(text, systemImage: symbol)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func saveText() {
    guard let textCorrectionSubject, !isSavingText, !model.isApplicationShuttingDown,
      model.settings.privacyPolicySettings.historyPreviewMode != .disabled
    else { return }
    isSavingText = true
    let text = draft.correctedText
    let operationID = correctionOperationID
    Task { @MainActor in
      let saved = await model.recordWorkspace.saveTextCorrection(
        subject: textCorrectionSubject, text: text, operationID: operationID)
      isSavingText = false
      if saved {
        model.selectSidebarSection(.records)
        dismiss()
      } else {
        saveIssue = .persistence
      }
    }
  }

  private func saveRule() {
    guard !isSavingRule, savedRuleFeedback == nil, let rule = draft.proposedRule else {
      return
    }

    let compatibleIDs = Set(model.vocabulary.vocabularyCollectionIDs(compatibleWith: rule.scope))
    let selectedCollectionID =
      targetCollectionID.flatMap { compatibleIDs.contains($0) ? $0 : nil }
    switch model.vocabulary.saveVocabularyCorrectionRule(rule, to: selectedCollectionID) {
    case .created:
      finishRuleSave(rule, feedback: .created)
    case .reused:
      finishRuleSave(rule, feedback: .reused)
    case .conflict:
      saveIssue = .conflict
    case .invalid:
      saveIssue = .invalid
    case .notReady:
      saveIssue = .notReady
    }
  }

  /// An in-memory rule is not a durable save. Remain on the sheet until
  /// the settings write succeeds, or offer a retry without duplicating it.
  private func finishRuleSave(
    _ rule: VocabularyRule, feedback: SavedRuleFeedback, retry: Bool = false
  ) {
    guard !isSavingRule else { return }
    isSavingRule = true
    saveIssue = nil
    pendingRule = rule
    pendingFeedback = feedback
    if retry { model.retryUnsavedSettingsSave() }
    Task { @MainActor in
      await model.settings.writes.flush()
      isSavingRule = false
      guard !model.isApplicationShuttingDown else { return }
      if model.settings.hasUnsavedWrite(for: AppSettingsCodec.vocabularyLibrarySettingKey) {
        saveIssue = .persistence
        return
      }
      recordMemoryCorrection(rule)
      pendingRule = nil
      pendingFeedback = nil
      savedRuleFeedback = feedback
    }
  }

  private func openVocabularySettings() {
    model.selectSidebarSection(.workflows)
    dismiss()
  }
  private func recordMemoryCorrection(_ rule: VocabularyRule) {
    guard let historyRecordID else { return }
    model.contextMemory?.recordCorrection(
      ConfirmedMemoryCorrection(original: rule.pattern, corrected: rule.replacement), recordID: historyRecordID
    )
  }

}
