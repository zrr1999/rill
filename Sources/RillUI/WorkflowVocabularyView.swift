import SwiftUI
import RillCore

struct VocabularyCollectionCard: View {
    @Bindable var model: AppModel
    let collection: VocabularyCollection

    @State private var isExpanded = false
    @State private var entryKind = VocabularyRuleKind.hotword
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var confirmsCollectionDeletion = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(collection.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(
                            systemName:
                                entry.content.kind == .hotword
                                ? RillSystemSymbol.waveformBadgePlus.rawValue
                                : RillSystemSymbol.arrowTriangle2Circlepath.rawValue
                        )
                        .foregroundStyle(.secondary)
                        Text(entryTitle(entry))
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button(role: .destructive) {
                            model.deleteVocabularyEntry(
                                entry.id,
                                from: collection.id
                            )
                        } label: {
                            Image(systemName: RillSystemSymbol.minusCircle.rawValue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "vocabulary.entry.\(entry.id.uuidString).delete"
                        )
                    }
                }

                Picker("", selection: $entryKind) {
                    Text(L10n.vocabularyRuleKind(.hotword, language: model.language))
                        .tag(VocabularyRuleKind.hotword)
                    Text(L10n.workflowText(.workflowReplacementKindOption, language: model.language))
                        .tag(VocabularyRuleKind.mapping)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                TextField(
                    L10n.workflowText(.workflowPhrasePlaceholder, language: model.language),
                    text: $pattern
                )
                .textFieldStyle(.roundedBorder)

                if entryKind == .mapping {
                    TextField(
                        L10n.workflowText(.workflowReplacementPlaceholder, language: model.language),
                        text: $replacement
                    )
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(L10n.workflowText(.workflowAddEntry, language: model.language)) {
                        model.addVocabularyEntry(
                            to: collection.id,
                            kind: entryKind,
                            pattern: pattern,
                            replacement: replacement
                        )
                        pattern = ""
                        replacement = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Spacer()

                    if collection.id != VocabularyCollection.personalID {
                        Button(role: .destructive) {
                            confirmsCollectionDeletion = true
                        } label: {
                            Image(systemName: RillSystemSymbol.trash.rawValue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "vocabulary.collection.\(collection.id.uuidString).delete"
                        )
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Toggle(
                isOn: Binding(
                    get: { collection.enabled },
                    set: {
                        model.setVocabularyCollectionEnabled(
                            collection.id,
                            isEnabled: $0
                        )
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.name)
                        .font(.caption.weight(.medium))
                    Text("\(collection.entries.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .rillCard(.regular, cornerRadius: 10, padding: 10)
        .alert(
            L10n.workflowText(.workflowDeleteCollectionTitle, language: model.language),
            isPresented: $confirmsCollectionDeletion
        ) {
            Button(L10n.recordText(.cancel, language: model.language), role: .cancel) {}
            Button(UIStrings.text(.clipboardDeleteItem, language: model.language), role: .destructive) {
                model.deleteVocabularyCollection(collection.id)
            }
        } message: {
            Text(L10n.workflowText(.workflowDeleteCollectionDetail, language: model.language))
        }
    }

    private func entryTitle(_ entry: VocabularyEntry) -> String {
        switch entry.content {
        case .hotword(let phrase):
            return phrase
        case .replacement(let pattern, let replacement, _, _):
            return "\(pattern) → \(replacement)"
        }
    }
}

extension WorkflowsView {
    var vocabularyLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.workflowText(.workflowVocabularyCollectionsLabel, language: model.language))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(L10n.workflowText(.workflowVocabularyLibraryHint, language: model.language))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.vocabularyCollections) { collection in
                VocabularyCollectionCard(model: model, collection: collection)
            }

            HStack {
                TextField(
                    L10n.workflowText(.workflowNewCollectionPlaceholder, language: model.language),
                    text: $newVocabularyCollectionName
                )
                .textFieldStyle(.roundedBorder)

                Button {
                    model.createVocabularyCollection(named: newVocabularyCollectionName)
                    newVocabularyCollectionName = ""
                } label: {
                    Image(systemName: RillSystemSymbol.plus.rawValue)
                }
                .buttonStyle(.bordered)
                .disabled(
                    newVocabularyCollectionName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
                .accessibilityIdentifier("vocabulary.collection.add")
            }
        }
    }

    func vocabularyBindingToggle(for collectionID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                draft.vocabularyBindings.contains {
                    $0.collectionID == collectionID
                }
            },
            set: { isEnabled in
                if isEnabled {
                    guard !draft.vocabularyBindings.contains(where: {
                        $0.collectionID == collectionID
                    }) else { return }
                    draft.vocabularyBindings.append(
                        VocabularyCollectionBinding(collectionID: collectionID)
                    )
                } else {
                    draft.vocabularyBindings.removeAll {
                        $0.collectionID == collectionID
                    }
                }
            }
        )
    }

    func vocabularyBindingIndex(for collectionID: UUID) -> Int? {
        draft.vocabularyBindings.firstIndex { $0.collectionID == collectionID }
    }

    @ViewBuilder
    func vocabularyConditionEditor(for collectionID: UUID) -> some View {
        if let index = vocabularyBindingIndex(for: collectionID) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.workflowText(.workflowBindingConditionLabel, language: model.language))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.workflowText(.workflowBundleIDAnyPlaceholder, language: model.language),
                    text: Binding(
                        get: {
                            draft.vocabularyBindings[index].condition.bundleIdentifier ?? ""
                        },
                        set: {
                            draft.vocabularyBindings[index].condition.bundleIdentifier =
                                $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(
                    "workflow.setup.vocabulary.\(collectionID.uuidString).app"
                )

                HStack {
                    TextField(
                        L10n.workflowText(.workflowLanguageAnyPlaceholder, language: model.language),
                        text: Binding(
                            get: { draft.vocabularyBindings[index].condition.locale ?? "" },
                            set: {
                                draft.vocabularyBindings[index].condition.locale =
                                    $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Picker(
                        L10n.workflowText(.workflowRecordCollectionPickerLabel, language: model.language),
                        selection: Binding(
                            get: {
                                draft.vocabularyBindings[index].condition.recordCollectionID
                            },
                            set: {
                                draft.vocabularyBindings[index].condition.recordCollectionID = $0
                            }
                        )
                    ) {
                        Text(L10n.workflowText(.workflowAnyCollection, language: model.language))
                            .tag(nil as UUID?)
                        ForEach(model.recordWorkspace.snapshot.collections) { collection in
                            Text(collection.name).tag(collection.id.rawValue as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    var hotwordCapabilityDescription: String {
        let resolvedRecognizerID =
            selectedWorkflow?.plan.setup.speechRoute?.recognizerID
            ?? "local-speech"
        let supportsHotwords = ["local-speech", "sherpa-onnx.local", "sherpa-onnx.streaming"]
            .contains(resolvedRecognizerID)
        if supportsHotwords {
            return L10n.workflowText(.workflowHotwordSupportedHint, language: model.language)
        }
        return L10n.workflowText(.workflowHotwordSkippedHint, language: model.language)
    }

    func vocabularyCollectionSummary(_ collection: VocabularyCollection) -> String {
        let hotwordCount = collection.entries.reduce(into: 0) { count, entry in
            if case .hotword = entry.content { count += 1 }
        }
        let replacementCount = collection.entries.count - hotwordCount
        return L10n.workflowVocabularySummary(
            hotwordCount: hotwordCount,
            replacementCount: replacementCount,
            language: model.language
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
