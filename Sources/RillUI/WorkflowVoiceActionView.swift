import SwiftUI
import RillCore

extension WorkflowsView {
    @ViewBuilder
    var voiceActionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            workflowPhaseHeader(
                .setup,
                subtitle: model.language == .english
                    ? "Resolve speech resources and freeze vocabulary for this run."
                    : "解析语音资源，并为本次运行冻结词库快照。"
            )

            actionStepRow(
                number: 1,
                icon: RillSystemSymbol.micFill.rawValue,
                label: model.language == .english ? "Speech Recognition" : "语音识别"
            ) {
                HStack(spacing: 8) {
                    Image(systemName: RillSystemSymbol.laptopcomputer.rawValue)
                        .foregroundStyle(.green)
                    Text(UIStrings.editorRecognizer(.localSpeech, language: model.language))
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(model.language == .english ? "On-device" : "设备端")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(
                    model.language == .english
                        ? "Uses the local engine and model selected in Voice settings unless a model override is set below."
                        : "默认使用语音设置中选择的本地引擎和模型；也可在下方为此工作流指定模型。"
                )
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
                    model.language == .english ? "Live preview" : "实时预览",
                    isOn: $draft.livePreviewEnabled
                )
                .toggleStyle(.checkbox)

                if draft.livePreviewEnabled {
                    Picker(
                        model.language == .english ? "Preview location" : "预览位置",
                        selection: $draft.livePreviewPlacement
                    ) {
                        Text(model.language == .english ? "Overlay" : "浮层")
                            .tag(LivePreviewPlacement.overlay)
                        Text(model.language == .english ? "Cursor" : "光标")
                            .tag(LivePreviewPlacement.cursor)
                    }
                    .pickerStyle(.segmented)
                    .font(.caption)
                    .accessibilityIdentifier("workflow.live-preview-placement")
                }

                Picker(
                    model.language == .english ? "Streaming style" : "流式风格",
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
                label: model.language == .english ? "Vocabulary Collections" : "词库集合"
            ) {
                if model.vocabularyCollections.isEmpty {
                    Text(model.language == .english ? "No collections available." : "暂无可用词库。")
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
                subtitle: model.language == .english
                    ? "Recognize audio, apply vocabulary, then run text transforms in order."
                    : "识别音频、应用词库，再按顺序执行文本处理。"
            )

            actionStepRow(
                number: 3,
                icon: RillSystemSymbol.waveform.rawValue,
                label: model.language == .english ? "Recognize Speech" : "识别语音"
            ) {
                Text(
                    model.language == .english
                        ? "Audio → text using the frozen Setup route and supported hotword hints."
                        : "使用 Setup 中冻结的路由和引擎支持的热词提示，将音频转换为文本。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            actionStepRow(
                number: 4,
                icon: RillSystemSymbol.arrowTriangle2Circlepath.rawValue,
                label: model.language == .english ? "Apply Vocabulary" : "应用替换词"
            ) {
                Text(
                    model.language == .english
                        ? "Apply matching replacement entries before normalization and LLM rewriting."
                        : "在空白规范化和 LLM 改写之前应用匹配的替换词。"
                )
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
                            model.language == .english ? "LLM prompt…" : "LLM 提示词…",
                            text: Binding(
                                get: { draft.postProcessSteps[index].prompt },
                                set: { draft.postProcessSteps[index].prompt = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                        Text(
                            model.language == .english
                                ? "OpenAI model: \(model.openAIModel). Change it in Settings → Speech Engine."
                                : "OpenAI 模型：\(model.openAIModel)。可在“设置 → 语音引擎”中切换。"
                        )
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
                    model.language == .english ? "Add Step" : "添加步骤",
                    systemImage: RillSystemSymbol.plusCircle.rawValue
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .padding(.leading, 24)

            workflowPhaseHeader(
                .output,
                subtitle: model.language == .english
                    ? "Choose a primary destination and optionally add speech playback."
                    : "选择主要输出目标，并可追加语音朗读。"
            )

            Text(
                model.language == .english
                    ? "For fully ordered output.actions, edit the workflow TOML and reload."
                    : "如需自由编排多个 output.actions，可直接编辑工作流 TOML 后重新加载。"
            )
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
                                Text(model.language == .english ? "Default routing" : "默认路由").tag(nil as UUID?)
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
                label: model.language == .english ? "Speak Result" : "朗读结果"
            ) {
                if draft.destination == .speakOnly {
                    Text(
                        model.language == .english
                            ? "Speech is the primary output for this workflow."
                            : "朗读是此工作流的主要输出。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Toggle(
                        model.language == .english
                            ? "Read the final result aloud"
                            : "朗读最终结果",
                        isOn: $draft.speaksResult
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
                if draft.speaksResult || draft.destination == .speakOnly {
                    Picker(
                        model.language == .english ? "Workflow TTS model" : "工作流 TTS 模型",
                        selection: $draft.speechModelID
                    ) {
                        Text(model.language == .english ? "Default enabled model" : "默认已启用模型")
                            .tag("")
                        ForEach(model.workflowSelectableTTSModels, id: \.self) { modelID in
                            Text(modelID).tag(modelID)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workflow.tts.model")

                    Picker(
                        model.language == .english ? "Workflow voice" : "工作流音色",
                        selection: $draft.speechVoice
                    ) {
                        ForEach(Qwen3TTSVoice.allCases, id: \.self) { voice in
                            Text(voice.rawValue).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workflow.tts.voice")
                }
                Text(
                    model.language == .english
                        ? "The TTS model and voice are saved in this workflow. Settings only controls which models are available and resident."
                        : "TTS 模型与音色均保存在此 workflow 中；设置页只控制模型是否可用及是否常驻。"
                )
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
                label: model.language == .english ? "Group Action" : "组动作"
            ) {
                Picker(
                    UIStrings.text(.workflowGroupAction, language: model.language),
                    selection: $draft.groupActionKind
                ) {
                    Text(model.language == .english ? "Create Item" : "创建条目")
                        .tag(RecordCollectionActionKind.createRecord)
                    Text(model.language == .english ? "Edit Item" : "编辑条目")
                        .tag(RecordCollectionActionKind.editRecord)
                    Text(model.language == .english ? "Remove Item" : "移除条目")
                        .tag(RecordCollectionActionKind.removeRecord)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if draft.groupActionKind == .editRecord {
                actionStepRow(
                    number: 2,
                    icon: RillSystemSymbol.wandAndStars.rawValue,
                    label: model.language == .english ? "Prompt" : "提示词"
                ) {
                    TextField(
                        model.language == .english ? "LLM prompt (e.g. polish text)…" : "LLM 提示词（如润色文本）…",
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
