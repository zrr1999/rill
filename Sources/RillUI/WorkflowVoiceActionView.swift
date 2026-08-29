import SwiftUI
import RillCore

extension WorkflowsView {
    @ViewBuilder
    var voiceActionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            workflowPhaseHeader(
                .setup,
                subtitle: L10n.workflowText(.workflowSetupPhaseSubtitle, language: model.language)
            )

            actionStepRow(
                number: 1,
                icon: RillSystemSymbol.micFill.rawValue,
                label: L10n.workflowText(.workflowSpeechRecognitionLabel, language: model.language)
            ) {
                HStack(spacing: 8) {
                    Image(systemName: RillSystemSymbol.laptopcomputer.rawValue)
                        .foregroundStyle(.green)
                    Text(UIStrings.editorRecognizer(.localSpeech, language: model.language))
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(L10n.workflowText(.workflowOnDeviceBadge, language: model.language))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(L10n.workflowText(.workflowSpeechRecognitionHint, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.privacySettingsSpeechRouteHint(.localSpeech, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draftUsesUnavailableLocalSpeech {
                    Label(
                        UIStrings.localSpeechAvailabilityDescription(
                            model.localSpeechAvailability,
                            language: model.language
                        ),
                        systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("workflow.local-speech-unavailable")
                }

                TextField(
                    L10n.string(.workflowLanguageOverride, language: model.language),
                    text: $draft.speechLanguageOverride,
                    prompt: Text(L10n.string(.workflowLanguageAuto, language: model.language))
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)

                Picker(
                    L10n.string(.workflowLocalSpeechModelOverride, language: model.language),
                    selection: $draft.localSpeechModelOverride
                ) {
                    Text(UIStrings.text(.workflowGlobalModelDefault, language: model.language)).tag("")
                    ForEach(model.workflowSelectableLocalSpeechModels, id: \.self) { modelIdentifier in
                        Text(model.localSpeechModelDisplayName(modelIdentifier, includeStatus: true))
                            .tag(modelIdentifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.caption)

                Toggle(
                    L10n.workflowText(.workflowLivePreviewToggle, language: model.language),
                    isOn: $draft.livePreviewEnabled
                )
                .toggleStyle(.checkbox)

                if draft.livePreviewEnabled {
                    Picker(
                        L10n.workflowText(.workflowPreviewLocationLabel, language: model.language),
                        selection: $draft.livePreviewPlacement
                    ) {
                        Text(L10n.workflowText(.workflowPreviewOverlay, language: model.language))
                            .tag(LivePreviewPlacement.overlay)
                        Text(L10n.workflowText(.workflowPreviewCursor, language: model.language))
                            .tag(LivePreviewPlacement.cursor)
                    }
                    .pickerStyle(.segmented)
                    .font(.caption)
                    .accessibilityIdentifier("workflow.live-preview-placement")
                }

                Picker(
                    L10n.workflowText(.workflowStreamingStyleLabel, language: model.language),
                    selection: $draft.streamingProfile
                ) {
                    Text("Realtime").tag("realtime")
                    Text("Agent").tag("agent")
                    Text("Subtitle").tag("subtitle")
                }
                .pickerStyle(.segmented)
                .font(.caption)
            }

            actionStepRow(
                number: 2,
                icon: RillSystemSymbol.textBookClosedFill.rawValue,
                label: L10n.workflowText(.workflowVocabularyCollectionsLabel, language: model.language)
            ) {
                if model.vocabularyCollections.isEmpty {
                    Text(L10n.workflowText(.workflowNoVocabularyCollections, language: model.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.vocabularyCollections) { collection in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(
                                isOn: vocabularyBindingToggle(for: collection.id)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name)
                                        .font(.caption.weight(.medium))
                                    Text(vocabularyCollectionSummary(collection))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier(
                                "workflow.setup.vocabulary.\(collection.id.uuidString)"
                            )

                            if vocabularyBindingIndex(for: collection.id) != nil {
                                vocabularyConditionEditor(for: collection.id)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }

                Label(hotwordCapabilityDescription, systemImage: RillSystemSymbol.infoCircle.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            workflowPhaseHeader(
                .process,
                subtitle: L10n.workflowText(.workflowProcessPhaseSubtitle, language: model.language)
            )

            actionStepRow(
                number: 3,
                icon: RillSystemSymbol.waveform.rawValue,
                label: L10n.workflowText(.workflowRecognizeSpeechLabel, language: model.language)
            ) {
                Text(L10n.workflowText(.workflowRecognizeSpeechHint, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionStepRow(
                number: 4,
                icon: RillSystemSymbol.arrowTriangle2Circlepath.rawValue,
                label: L10n.workflowText(.workflowApplyVocabularyLabel, language: model.language)
            ) {
                Text(L10n.workflowText(.workflowApplyVocabularyHint, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionStepRow(
                number: 5,
                icon: draft.textStyle.systemImage,
                label: L10n.string(.workflowTextStyle, language: model.language)
            ) {
                Picker(
                    L10n.string(.workflowTextStyle, language: model.language),
                    selection: Binding(
                        get: { draft.textStyle },
                        set: { draft.textStyle = $0 }
                    )
                ) {
                    ForEach(VoiceTextStyle.selectableCases) { style in
                        Text(L10n.voiceTextStyleTitle(style, language: model.language)).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text(L10n.voiceTextStyleDescription(draft.textStyle, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !draft.postProcessSteps.isEmpty {
                Text(L10n.string(.workflowAdvancedTextSteps, language: model.language))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }

            ForEach(Array(draft.postProcessSteps.enumerated()), id: \.element.id) { index, step in
                actionStepRow(
                    number: index + 6,
                    icon: postProcessStepSystemSymbol(step.kind).rawValue,
                    label: postProcessStepKindLabel(step.kind)
                ) {
                    if step.kind == .llmRewrite || step.kind == .llmAnswer {
                        TextField(
                            L10n.workflowText(.workflowLLMPromptPlaceholder, language: model.language),
                            text: Binding(
                                get: { draft.postProcessSteps[index].prompt },
                                set: { draft.postProcessSteps[index].prompt = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                        Text(L10n.workflowOpenAIModelHint(model.openAIModel, language: model.language))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        if index > 0 {
                            Button {
                                draft.postProcessSteps.swapAt(index, index - 1)
                            } label: {
                                Image(systemName: RillSystemSymbol.arrowUp.rawValue).font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                UIStrings.targetedAccessibilityLabel(
                                    .workflowMoveStepUp,
                                    target: postProcessStepKindLabel(step.kind),
                                    language: model.language
                                )
                            )
                            .accessibilityIdentifier("workflow.step.\(step.id.uuidString).move-up")
                        }
                        if index < draft.postProcessSteps.count - 1 {
                            Button {
                                draft.postProcessSteps.swapAt(index, index + 1)
                            } label: {
                                Image(systemName: RillSystemSymbol.arrowDown.rawValue).font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                UIStrings.targetedAccessibilityLabel(
                                    .workflowMoveStepDown,
                                    target: postProcessStepKindLabel(step.kind),
                                    language: model.language
                                )
                            )
                            .accessibilityIdentifier("workflow.step.\(step.id.uuidString).move-down")
                        }
                        Button {
                            draft.postProcessSteps.remove(at: index)
                        } label: {
                            Image(systemName: RillSystemSymbol.xmarkCircle.rawValue).font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel(
                            UIStrings.targetedAccessibilityLabel(
                                .workflowRemoveStep,
                                target: postProcessStepKindLabel(step.kind),
                                language: model.language
                            )
                        )
                        .accessibilityIdentifier("workflow.step.\(step.id.uuidString).remove")
                    }
                }
            }

            Menu {
                ForEach(Self.availableStepKinds, id: \.rawValue) { kind in
                    Button(postProcessStepKindLabel(kind)) {
                        draft.postProcessSteps.append(
                            WorkflowEditorDraft.PostProcessStepDraft(kind: kind)
                        )
                    }
                }
            } label: {
                Label(
                    L10n.workflowText(.workflowAddStep, language: model.language),
                    systemImage: RillSystemSymbol.plusCircle.rawValue
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .padding(.leading, 24)

            workflowPhaseHeader(
                .output,
                subtitle: L10n.workflowText(.workflowOutputPhaseSubtitle, language: model.language)
            )

            Text(L10n.workflowText(.workflowOrderedActionsHint, language: model.language))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)

            actionStepRow(
                number: draft.postProcessSteps.count + 6,
                icon: RillSystemSymbol.arrowRightCircle.rawValue,
                label: UIStrings.text(.workflowDestination, language: model.language)
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Picker(
                            UIStrings.text(.workflowDestination, language: model.language),
                            selection: $draft.destination
                        ) {
                            ForEach(WorkflowEditorDraft.DestinationChoice.productionChoices) { destination in
                                Text(
                                    UIStrings.editorDestination(destination, language: model.language)
                                )
                                .tag(destination)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        if draft.destination == .saveToQueue {
                            Picker(
                                UIStrings.text(.workflowTargetGroup, language: model.language),
                                selection: Binding(
                                    get: { draft.targetGroupID },
                                    set: { draft.targetGroupID = $0 }
                                )
                            ) {
                                Text(L10n.workflowText(.workflowDefaultRouting, language: model.language)).tag(nil as UUID?)
                                ForEach(model.recordWorkspace.snapshot.collections) { collection in
                                    Text(collection.name).tag(collection.id.rawValue as UUID?)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    if !UIStrings.externalOutputHint(draft.destination, language: model.language).isEmpty {
                        Text(UIStrings.externalOutputHint(draft.destination, language: model.language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    switch draft.destination {
                    case .sendToWebhook:
                        TextField(
                            UIStrings.externalOutputField(.webhookURL, language: model.language),
                            text: $draft.webhookURL
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        TextField(
                            UIStrings.externalOutputField(.webhookHeadersJSON, language: model.language),
                            text: $draft.webhookHeadersJSON
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    case .runShortcut:
                        TextField(
                            UIStrings.externalOutputField(.shortcutName, language: model.language),
                            text: $draft.shortcutName
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    case .appendToMarkdown:
                        TextField(
                            UIStrings.externalOutputField(.markdownAppendPath, language: model.language),
                            text: $draft.markdownAppendPath
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    case .pasteIntoApp, .copyToClipboard, .saveToQueue, .speakOnly:
                        EmptyView()
                    }
                }
            }

            actionStepRow(
                number: draft.postProcessSteps.count + 7,
                icon: RillSystemSymbol.speakerWave2.rawValue,
                label: L10n.workflowText(.workflowSpeakResultLabel, language: model.language)
            ) {
                if draft.destination == .speakOnly {
                    Text(L10n.workflowText(.workflowSpeakPrimaryHint, language: model.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(
                        L10n.workflowText(.workflowReadAloudToggle, language: model.language),
                        isOn: $draft.speaksResult
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
                if draft.speaksResult || draft.destination == .speakOnly {
                    Picker(
                        L10n.workflowText(.workflowTTSModelLabel, language: model.language),
                        selection: $draft.speechModelID
                    ) {
                        Text(L10n.workflowText(.workflowDefaultTTSModel, language: model.language))
                            .tag("")
                        ForEach(model.workflowSelectableTTSModels, id: \.self) { modelID in
                            Text(modelID).tag(modelID)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workflow.tts.model")

                    Picker(
                        L10n.workflowText(.workflowVoiceLabel, language: model.language),
                        selection: $draft.speechVoice
                    ) {
                        ForEach(Qwen3TTSVoice.allCases, id: \.self) { voice in
                            Text(voice.rawValue).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workflow.tts.voice")
                }
                Text(L10n.workflowText(.workflowTTSSavedHint, language: model.language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var groupEventActionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionStepRow(
                number: 1,
                icon: RillSystemSymbol.boltHorizontalCircle.rawValue,
                label: UIStrings.text(.workflowGroupAction, language: model.language)
            ) {
                Picker(
                    UIStrings.text(.workflowGroupAction, language: model.language),
                    selection: $draft.groupActionKind
                ) {
                    Text(L10n.workflowText(.workflowCreateItem, language: model.language))
                        .tag(RecordCollectionActionKind.createRecord)
                    Text(L10n.workflowText(.workflowEditItem, language: model.language))
                        .tag(RecordCollectionActionKind.editRecord)
                    Text(L10n.workflowText(.workflowRemoveItem, language: model.language))
                        .tag(RecordCollectionActionKind.removeRecord)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if draft.groupActionKind == .editRecord {
                actionStepRow(
                    number: 2,
                    icon: RillSystemSymbol.wandAndStars.rawValue,
                    label: L10n.workflowText(.workflowPromptLabel, language: model.language)
                ) {
                    TextField(
                        L10n.workflowText(.workflowActionPromptPlaceholder, language: model.language),
                        text: $draft.actionPrompt
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
            }
        }
    }
}

private extension WorkflowsView {
    var draftUsesUnavailableLocalSpeech: Bool {
        !model.localSpeechTrustMaterialAvailable
    }
}
