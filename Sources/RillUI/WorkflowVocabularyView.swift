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
                    Text(model.language == .english ? "Hotword" : "热词")
                        .tag(VocabularyRuleKind.hotword)
                    Text(model.language == .english ? "Replacement" : "替换词")
                        .tag(VocabularyRuleKind.mapping)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                TextField(
                    model.language == .english ? "Phrase" : "原词",
                    text: $pattern
                )
                .textFieldStyle(.roundedBorder)

                if entryKind == .mapping {
                    TextField(
                        model.language == .english ? "Replacement" : "替换为",
                        text: $replacement
                    )
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(model.language == .english ? "Add Entry" : "添加词条") {
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
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .alert(
            model.language == .english ? "Delete collection?" : "删除词库？",
            isPresented: $confirmsCollectionDeletion
        ) {
            Button(model.language == .english ? "Cancel" : "取消", role: .cancel) {}
            Button(model.language == .english ? "Delete" : "删除", role: .destructive) {
                model.deleteVocabularyCollection(collection.id)
            }
        } message: {
            Text(
                model.language == .english
                    ? "The collection and its workflow bindings will be removed."
                    : "该词库及其工作流绑定都会被移除。"
            )
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
            Text(model.language == .english ? "Vocabulary Collections" : "词库集合")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(
                model.language == .english
                    ? "Reusable hotwords and replacements attached in workflow Setup."
                    : "在工作流 Setup 中复用的热词与替换词集合。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(model.vocabularyCollections) { collection in
                VocabularyCollectionCard(model: model, collection: collection)
            }

            HStack {
                TextField(
                    model.language == .english ? "New collection" : "新词库名称",
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
                Text(model.language == .english ? "Applies when (all fields match)" : "生效条件（字段之间为 AND）")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(
                    model.language == .english ? "App bundle ID · any" : "App Bundle ID · 任意",
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
                        model.language == .english ? "Language · any" : "语言 · 任意",
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
                        model.language == .english ? "Record collection" : "记录集",
                        selection: Binding(
                            get: {
                                draft.vocabularyBindings[index].condition.recordCollectionID
                            },
                            set: {
                                draft.vocabularyBindings[index].condition.recordCollectionID = $0
                            }
                        )
                    ) {
                        Text(model.language == .english ? "Any collection" : "任意记录集")
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
            return model.language == .english
                ? "Recognition hotwords are supported by the current engine; replacements run after recognition."
                : "当前识别引擎支持热词；替换词会在识别后执行。"
        }
        return model.language == .english
            ? "The current engine skips recognition hotwords; replacements still run after recognition."
            : "当前识别引擎会跳过识别热词；替换词仍会在识别后执行。"
    }

    func vocabularyCollectionSummary(_ collection: VocabularyCollection) -> String {
        let hotwordCount = collection.entries.reduce(into: 0) { count, entry in
            if case .hotword = entry.content { count += 1 }
        }
        let replacementCount = collection.entries.count - hotwordCount
        if model.language == .english {
            return "\(hotwordCount) hotwords · \(replacementCount) replacements"
        }
        return "\(hotwordCount) 个热词 · \(replacementCount) 个替换词"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
