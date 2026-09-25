import SwiftUI
import RillCore

public struct VocabularyCorrectionSheet: View {
    private enum SaveIssue: Equatable {
        case conflict
        case invalid
        case notReady
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable private var model: AppModel
    private let historyRecordID: UUID?
    @State private var draft: VocabularyCorrectionDraft
    @State private var saveIssue: SaveIssue?
    @State private var targetCollectionID: UUID?

    public init(model: AppModel, source: RecognitionCorrectionSource, historyRecordID: UUID? = nil) {
        self.historyRecordID = historyRecordID
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
        .onChange(of: model.privacyPolicySettings.historyPreviewMode) { _, mode in
            if mode == .disabled {
                dismiss()
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(.vocabularyCorrectionTitle, language: model.language))
                .font(.title2.bold())
            Text(L10n.string(.vocabularyCorrectionDescription, language: model.language))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recognitionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(.vocabularyCorrectionOriginalText, language: model.language))
                    .font(.headline)
                Text(draft.originalText)
                    .textSelection(.enabled)
                    .rillCard(.regular, cornerRadius: RillRadius.badge, padding: 10)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(.vocabularyCorrectionCorrectedText, language: model.language))
                    .font(.headline)
                TextEditor(text: correctedTextBinding)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .accessibilityLabel(
                        L10n.string(.vocabularyCorrectionCorrectedText, language: model.language)
                    )
            }
        }
    }

    @ViewBuilder
    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string(.vocabularyCorrectionSuggestions, language: model.language))
                .font(.headline)

            switch draft.status {
            case .unchanged:
                guidance(
                    L10n.string(.vocabularyCorrectionNoChange, language: model.language),
                    symbol: RillSystemSymbol.pencil.rawValue
                )
            case .invalid:
                guidance(
                    L10n.string(.vocabularyCorrectionUnsupported, language: model.language),
                    symbol: RillSystemSymbol.exclamationmarkTriangle.rawValue
                )
                Button(L10n.string(.vocabularyCorrectionOpenSettings, language: model.language)) {
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
            HStack(alignment: .top, spacing: 10) {
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
            .padding(10)
            .rillSelection(draft.selectedOptionID == option.id, cornerRadius: RillRadius.row)
        }
        .buttonStyle(RillCardButtonStyle(cornerRadius: RillRadius.row))
        .accessibilityLabel("\(optionTitle(option)): \(optionSummary(option))")
        .accessibilityAddTraits(draft.selectedOptionID == option.id ? .isSelected : [])
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string(.vocabularyCorrectionScopeTitle, language: model.language))
                .font(.headline)
            Text(L10n.string(.vocabularyCorrectionScopeDescription, language: model.language))
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
                    L10n.overlayText(.correctionSaveToCollection, language: model.language),
                    selection: $targetCollectionID
                ) {
                    Text(
                        L10n.overlayText(.correctionCreateScopedCollection, language: model.language)
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
                    L10n.string(.vocabularyCorrectionConflict, language: model.language),
                    systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                )
                .foregroundStyle(.orange)
                Button(L10n.string(.vocabularyCorrectionOpenSettings, language: model.language)) {
                    openVocabularySettings()
                }
            }
        case .invalid:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    L10n.string(.vocabularyCorrectionUnsupported, language: model.language),
                    systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                )
                .foregroundStyle(.secondary)
                Button(L10n.string(.vocabularyCorrectionOpenSettings, language: model.language)) {
                    openVocabularySettings()
                }
            }
        case .notReady:
            Label(
                L10n.overlayText(.correctionSettingsLoading, language: model.language),
                systemImage: RillSystemSymbol.clock.rawValue
            )
            .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private var actionBar: some View {
        HStack {
            Button(L10n.string(.vocabularyCorrectionCancel, language: model.language)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(L10n.string(.vocabularyCorrectionSave, language: model.language)) {
                saveRule()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(draft.proposedRule == nil || model.settings.isLoading)
        }
    }

    private var correctedTextBinding: Binding<String> {
        Binding(
            get: { draft.correctedText },
            set: { text in
                draft.updateCorrectedText(text)
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
            return L10n.string(.vocabularyCorrectionMappingOption, language: model.language)
        case .hotword:
            return L10n.string(.vocabularyCorrectionHotwordOption, language: model.language)
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
            language: model.language
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
        let compatibleIDs = Set(model.vocabularyCollectionIDs(compatibleWith: scope))
        return model.vocabulary.vocabularyCollections.filter { compatibleIDs.contains($0.id) }
    }

    private func unknownScopeLabel(_ field: VocabularyCorrectionScopeField) -> String {
        switch field {
        case .bundleIdentifier:
            return L10n.string(.vocabularyCorrectionUnknownApp, language: model.language)
        case .recordCollectionID:
            return L10n.string(.vocabularyCorrectionUnknownGroup, language: model.language)
        case .locale:
            return L10n.string(.vocabularyCorrectionUnknownLanguage, language: model.language)
        }
    }

    private func guidance(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveRule() {
        guard let rule = draft.proposedRule else {
            saveIssue = .invalid
            return
        }

        let compatibleIDs = Set(model.vocabularyCollectionIDs(compatibleWith: rule.scope))
        let selectedCollectionID =
            targetCollectionID.flatMap { compatibleIDs.contains($0) ? $0 : nil }
        switch model.saveVocabularyCorrectionRule(rule, to: selectedCollectionID) {
        case .created:
            recordMemoryCorrection(rule)
            model.append(
                english: L10n.string(.vocabularyCorrectionCreated, language: .english),
                simplifiedChinese: L10n.string(.vocabularyCorrectionCreated, language: .simplifiedChinese)
            )
            dismiss()
        case .reused:
            recordMemoryCorrection(rule)
            model.append(
                english: L10n.string(.vocabularyCorrectionReused, language: .english),
                simplifiedChinese: L10n.string(.vocabularyCorrectionReused, language: .simplifiedChinese)
            )
            dismiss()
        case .conflict:
            saveIssue = .conflict
        case .invalid:
            saveIssue = .invalid
        case .notReady:
            saveIssue = .notReady
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
