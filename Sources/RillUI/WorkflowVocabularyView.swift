import SwiftUI
import RillCore

struct VocabularyCollectionCard: View {
    @Bindable var model: AppModel
    let collection: VocabularyCollection

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var entryKind = VocabularyRuleKind.hotword
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var confirmsCollectionDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The enable toggle and the disclosure control sit side by side
            // instead of nesting the toggle inside a DisclosureGroup label,
            // so their hit areas no longer overlap.
            HStack(spacing: 8) {
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
                        Text(
                            L10n.workflowVocabularyEntryCount(
                                collection.entries.count,
                                language: model.settings.language
                            )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 8)

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: RillSystemSymbol.chevronRight.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(L10n.workflowText(.workflowCollectionEntriesToggle, language: model.settings.language)): \(collection.name)"
                )
            }

            if isExpanded {
                expandedContent
                    .padding(.top, 8)
            }
        }
        .rillCard(.regular, cornerRadius: RillRadius.row, padding: 10)
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
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if collection.entries.isEmpty {
                Text(L10n.workflowText(.workflowCollectionEmptyEntries, language: model.settings.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    .accessibilityLabel(
                        L10n.targetedAccessibilityLabel(
                            .vocabularyDeleteRule,
                            target: entryTitle(entry),
                            language: model.settings.language
                        )
                    )
                    .accessibilityIdentifier(
                        "vocabulary.entry.\(entry.id.uuidString).delete"
                    )
                }
            }

            Picker(
                L10n.workflowText(.workflowEntryKindLabel, language: model.settings.language),
                selection: $entryKind
            ) {
                Text(L10n.vocabularyRuleKind(.hotword, language: model.settings.language))
                    .tag(VocabularyRuleKind.hotword)
                Text(L10n.workflowText(.workflowReplacementKindOption, language: model.settings.language))
                    .tag(VocabularyRuleKind.mapping)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            TextField(
                L10n.workflowText(.workflowPhrasePlaceholder, language: model.settings.language),
                text: $pattern
            )
            .textFieldStyle(.roundedBorder)

            if entryKind == .mapping {
                TextField(
                    L10n.workflowText(.workflowReplacementPlaceholder, language: model.settings.language),
                    text: $replacement
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(L10n.workflowText(.workflowAddEntry, language: model.settings.language)) {
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
                    .accessibilityLabel(
                        "\(L10n.workflowText(.workflowDeleteCollection, language: model.settings.language)): \(collection.name)"
                    )
                    .accessibilityIdentifier(
                        "vocabulary.collection.\(collection.id.uuidString).delete"
                    )
                }
            }
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
