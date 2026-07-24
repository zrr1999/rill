import SwiftUI
import RillCore

public struct WorkflowsView: View {
    static let availableStepKinds: [PostProcessStepKind] = [
        .normalizeWhitespace,
    ]

    @Bindable var model: AppModel
    @State var draft = WorkflowEditorDraft()
    @State var editingWorkflowID: UUID?
    @State var selectedWorkflowID: UUID?
    @State var presentedWorkflowExplanation: WorkflowExplanationSheetRequest?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            workflowListPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)

            workflowEditorPane
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if draft.name.isEmpty, editingWorkflowID == nil, selectedWorkflowID == nil {
                resetDraft()
            }
        }
        .task(id: model.workflowEditorNavigationRequest?.id) {
            guard let request = model.workflowEditorNavigationRequest else { return }
            if let workflow = model.workflows.first(where: { $0.id == request.workflowID }) {
                beginEditing(workflow)
            }
        }
        .sheet(item: $presentedWorkflowExplanation, onDismiss: {
            model.cancelWorkflowExplanation()
        }) { request in
            WorkflowExplanationSheet(model: model, workflowID: request.workflowID)
        }
        .onDisappear {
            model.cancelWorkflowExplanation()
        }
    }
}

extension WorkflowsView {
    var selectedWorkflow: WorkflowDefinition? {
        guard let selectedWorkflowID else { return nil }
        return model.workflows.first(where: { $0.id == selectedWorkflowID })
    }

    var isInspectingBuiltinWorkflow: Bool {
        guard let selectedWorkflow else { return false }
        return !model.isCustomWorkflow(selectedWorkflow)
    }

    var workflowListPane: some View {
        let localizedWorkflowNames = Dictionary(
            uniqueKeysWithValues: model.workflows.map { ($0.id, model.localizedWorkflowName(for: $0)) }
        )

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UIStrings.text(.workflowsTitle, language: model.language))
                        .font(.title2.weight(.semibold))
                    Text(UIStrings.text(.workflowsDescription, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button {
                    resetDraft()
                } label: {
                    Label(UIStrings.text(.workflowNew, language: model.language), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
            }

            if let workflowLibraryError = model.workflowLibraryError, !workflowLibraryError.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workflowLibraryError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if !model.isWorkflowLibraryAvailable {
                        Button(L10n.historySettingsText(.retry, language: model.language)) {
                            model.retryUnavailableStoredSettingsDomains()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRetryingUnavailableSettingsDomains)
                        .accessibilityIdentifier("workflows.library.retry")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    workflowListSection(
                        title: UIStrings.text(.workflowCustom, language: model.language),
                        emptyTitle: model.isWorkflowLibraryAvailable
                            ? UIStrings.text(.workflowCustomEmpty, language: model.language)
                            : nil,
                        workflows: model.customWorkflows,
                        isCustom: true,
                        localizedWorkflowNames: localizedWorkflowNames
                    )

                    workflowListSection(
                        title: UIStrings.text(.workflowBuiltIn, language: model.language),
                        emptyTitle: nil,
                        workflows: model.builtInWorkflows,
                        isCustom: false,
                        localizedWorkflowNames: localizedWorkflowNames
                    )
                }
            }
        }
        .padding(24)
    }

    var workflowEditorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(editorTitle)
                        .font(.largeTitle.weight(.semibold))

                    Text(editorSubtitle)
                        .foregroundStyle(.secondary)

                    if let selectedWorkflow {
                        Button {
                            guard canExplainSelectedWorkflow else { return }
                            model.explainWorkflowBeforeRun(selectedWorkflow)
                            presentedWorkflowExplanation = WorkflowExplanationSheetRequest(
                                workflowID: selectedWorkflow.id
                            )
                        } label: {
                            Label(
                                UIStrings.workflowExplanationCopy(.button, language: model.language),
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canExplainSelectedWorkflow)
                        .accessibilityIdentifier("workflow-explanation.open")

                        Text(
                            UIStrings.workflowExplanationCopy(
                                canExplainSelectedWorkflow ? .savedVersionNotice : .saveBeforePreview,
                                language: model.language
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(
                            canExplainSelectedWorkflow ? Color.secondary : Color.orange
                        )
                    }

                    if isInspectingBuiltinWorkflow {
                        Label(
                            model.language == .english
                                ? "Built-in workflows stay immutable. Saving here creates a custom copy."
                                : "内置工作流保持只读；在这里保存会生成一个自定义副本。",
                            systemImage: "square.on.square"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                editorSurface
                    .disabled(!model.isWorkflowLibraryAvailable)
            }
            .padding(24)
        }
    }

    var editorTitle: String {
        if let selectedWorkflow {
            return model.localizedWorkflowName(for: selectedWorkflow)
        }
        return UIStrings.text(.workflowNew, language: model.language)
    }

    var editorSubtitle: String {
        if isInspectingBuiltinWorkflow {
            return model.language == .english
                ? "Inspect the preset in the mode editor and save a customized copy if needed."
                : "在模式编辑器里查看这个预设；如需修改，可保存为自定义副本。"
        }
        if editingWorkflowID != nil {
            return model.language == .english
                ? "Edit the selected voice mode, text style, and output destination."
                : "编辑当前语音模式、文字风格和输出位置。"
        }
        return model.language == .english
            ? "Create a reusable voice mode with a text style and output destination."
            : "创建可复用的语音模式，配置文字风格和输出位置。"
    }

    var canExplainSelectedWorkflow: Bool {
        WorkflowExplanationSelectionState.canExplainSavedWorkflow(
            draft: draft,
            selectedWorkflow: selectedWorkflow
        )
    }

    var editorSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorNodeCard(
                icon: "bolt.circle.fill",
                tint: .orange,
                title: model.language == .english ? "Event" : "事件"
            ) {
                TextField(
                    UIStrings.text(.workflowNameField, language: model.language),
                    text: $draft.name
                )
                .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.language == .english ? "Trigger Type" : "触发类型")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Picker(
                        UIStrings.text(.workflowTrigger, language: model.language),
                        selection: $draft.eventType
                    ) {
                        Text(model.language == .english ? "⌨ Hotkey" : "⌨ 快捷键")
                            .tag(WorkflowEditorDraft.EventType.hotkey)
                        Text(model.language == .english ? "👆 Manual" : "👆 手动")
                            .tag(WorkflowEditorDraft.EventType.manual)
                        Text(model.language == .english ? "☰ Menu Bar" : "☰ 菜单栏")
                            .tag(WorkflowEditorDraft.EventType.menuBar)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if !draft.eventType.isVoiceEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.language == .english ? "Source Group" : "来源组")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker(
                            UIStrings.text(.workflowSourceGroup, language: model.language),
                            selection: Binding(
                                get: { draft.sourceGroupID },
                                set: { draft.sourceGroupID = $0 }
                            )
                        ) {
                            Text(model.language == .english ? "Any group" : "任意组").tag(nil as UUID?)
                            ForEach(model.clipboardGroups, id: \.group.id) { summary in
                                Text(summary.group.name).tag(summary.group.id as UUID?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }

            editorNodeConnector()

            editorNodeCard(
                icon: "line.3.horizontal.decrease.circle.fill",
                tint: .cyan,
                title: model.language == .english ? "Condition" : "条件"
            ) {
                if draft.eventType.isVoiceEvent {
                    if draft.destination != .pasteIntoApp {
                        Toggle(
                            UIStrings.text(.workflowExcludeFromCapture, language: model.language),
                            isOn: $draft.excludeFromWorkflowCapture
                        )
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    } else {
                        Text(
                            model.language == .english
                                ? "No additional conditions for this trigger type."
                                : "该触发类型无额外条件。"
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                } else {
                    Toggle(
                        model.language == .english ? "Exclude polish-generated items" : "排除润色生成的条目",
                        isOn: $draft.excludePolishTag
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }

            editorNodeConnector()

            editorNodeCard(
                icon: "play.circle.fill",
                tint: .green,
                title: model.language == .english ? "Mode & Output" : "模式与输出"
            ) {
                if draft.eventType.isVoiceEvent {
                    voiceActionContent
                } else {
                    groupEventActionContent
                }
            }

            if let workflowEditorError = model.workflowEditorError {
                Text(workflowEditorError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 12)
            }

            HStack {
                Button(saveButtonTitle) {
                    saveDraft()
                }
                .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)

                Button(UIStrings.text(.workflowReset, language: model.language)) {
                    if selectedWorkflow != nil {
                        if let selectedWorkflow {
                            beginEditing(selectedWorkflow)
                        } else {
                            resetDraft()
                        }
                    } else {
                        resetDraft()
                    }
                }

                Spacer()
            }
            .padding(.top, 14)
        }
        .rillCard()
    }
}

extension WorkflowsView {
    @ViewBuilder
    var voiceActionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionStepRow(
                number: 1,
                icon: "mic.fill",
                label: model.language == .english ? "Speech Recognition" : "语音识别"
            ) {
                Picker(
                    UIStrings.text(.workflowRecognizer, language: model.language),
                    selection: $draft.recognizer
                ) {
                    ForEach(WorkflowEditorDraft.RecognizerChoice.allCases) { recognizer in
                        Text(UIStrings.editorRecognizer(recognizer, language: model.language)).tag(recognizer)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text(L10n.speechRouteHint(draft.recognizer, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.privacySettingsSpeechRouteHint(draft.recognizer, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draftUsesUnavailableLocalSpeech {
                    Label(
                        UIStrings.localSpeechAvailabilityDescription(
                            model.localSpeechAvailability,
                            language: model.language
                        ),
                        systemImage: "exclamationmark.triangle.fill"
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

                if draft.recognizer != .cloudSpeech {
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
                }

                if draft.recognizer != .localSpeech {
                    TextField(
                        L10n.string(.workflowCloudModelOverride, language: model.language),
                        text: $draft.deepgramModelOverride,
                        prompt: Text(model.deepgramModel)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
            }

            actionStepRow(
                number: 2,
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
                    number: index + 3,
                    icon: postProcessStepSystemSymbol(step.kind).rawValue,
                    label: postProcessStepKindLabel(step.kind)
                ) {
                    if step.kind == .llmRewrite {
                        TextField(
                            model.language == .english ? "LLM prompt…" : "LLM 提示词…",
                            text: Binding(
                                get: { draft.postProcessSteps[index].prompt },
                                set: { draft.postProcessSteps[index].prompt = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }

                    HStack(spacing: 4) {
                        if index > 0 {
                            Button {
                                draft.postProcessSteps.swapAt(index, index - 1)
                            } label: {
                                Image(systemName: "arrow.up").font(.caption2)
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
                                Image(systemName: "arrow.down").font(.caption2)
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
                            Image(systemName: "xmark.circle").font(.caption2)
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
                    systemImage: "plus.circle"
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .padding(.leading, 24)

            actionStepRow(
                number: draft.postProcessSteps.count + 3,
                icon: "arrow.right.circle",
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
                                ForEach(model.clipboardGroups, id: \.group.id) { summary in
                                    Text(summary.group.name).tag(summary.group.id as UUID?)
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
                    case .pasteIntoApp, .copyToClipboard, .saveToQueue:
                        EmptyView()
                    }
                }
            }
        }
    }

    func actionStepRow<Content: View>(
        number: Int,
        icon: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.medium))
                content()
            }
        }
    }

    @ViewBuilder
    var groupEventActionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionStepRow(
                number: 1,
                icon: "bolt.horizontal.circle",
                label: model.language == .english ? "Group Action" : "组动作"
            ) {
                Picker(
                    UIStrings.text(.workflowGroupAction, language: model.language),
                    selection: $draft.groupActionKind
                ) {
                    Text(model.language == .english ? "Create Item" : "创建条目")
                        .tag(ClipboardGroupActionKind.createItem)
                    Text(model.language == .english ? "Edit Item" : "编辑条目")
                        .tag(ClipboardGroupActionKind.editItem)
                    Text(model.language == .english ? "Remove Item" : "移除条目")
                        .tag(ClipboardGroupActionKind.removeItem)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if draft.groupActionKind == .editItem {
                actionStepRow(
                    number: 2,
                    icon: "wand.and.stars",
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

    func editorNodeCard<Content: View>(
        icon: String,
        tint: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.15))
        )
    }

    func editorNodeConnector() -> some View {
        HStack {
            Spacer()
            Rectangle()
                .fill(.quaternary)
                .frame(width: 2, height: 16)
            Spacer()
        }
    }

    func postProcessStepKindLabel(_ kind: PostProcessStepKind) -> String {
        switch kind {
        case .normalizeWhitespace:
            return model.language == .english ? "Normalize Whitespace" : "标准化空白"
        case .llmRewrite:
            return model.language == .english ? "LLM Polish / Rewrite" : "LLM 润色 / 改写"
        case .snippetReplacement:
            return model.language == .english ? "Snippet Replacement" : "片段替换"
        }
    }

    func postProcessStepSystemSymbol(_ kind: PostProcessStepKind) -> RillSystemSymbol {
        switch kind {
        case .normalizeWhitespace: return .textAlignLeft
        case .llmRewrite: return .wandAndStars
        case .snippetReplacement: return .textInsert
        }
    }
}

private extension WorkflowsView {
    var draftUsesUnavailableLocalSpeech: Bool {
        guard !model.localSpeechTrustMaterialAvailable else { return false }
        switch draft.recognizer {
        case .localSpeech:
            return true
        case .automatic:
            return model.preferredSpeechEngine == .local
        case .cloudSpeech:
            return false
        }
    }
}

extension WorkflowsView {
    func workflowListSection(
        title: String,
        emptyTitle: String?,
        workflows: [WorkflowDefinition],
        isCustom: Bool,
        localizedWorkflowNames: [UUID: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if workflows.isEmpty, let emptyTitle {
                Text(emptyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(workflows) { workflow in
                        workflowRow(
                            workflow,
                            isCustom: isCustom,
                            localizedWorkflowNames: localizedWorkflowNames
                        )
                    }
                }
            }
        }
    }

    func workflowRow(
        _ workflow: WorkflowDefinition,
        isCustom: Bool,
        localizedWorkflowNames: [UUID: String]
    ) -> some View {
        let isSelected = selectedWorkflowID == workflow.id
        let conflictingWorkflowNames = (model.workflowConflictIDsByWorkflowID[workflow.id] ?? [])
            .compactMap { localizedWorkflowNames[$0] }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    beginEditing(workflow)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: RillSystemSymbol.resolvedName(workflow.ui.symbolName)
                        )
                            .font(.title3)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(model.localizedWorkflowName(for: workflow))
                                    .font(.headline)
                                    .multilineTextAlignment(.leading)
                                if isSelected {
                                    badge(
                                        UIStrings.text(.workflowSelected, language: model.language),
                                        tint: .accentColor
                                    )
                                }
                            }

                            Text(VoiceWorkflowPresentation(workflow: workflow).detail(language: model.language))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                badge(
                                    isCustom
                                        ? UIStrings.text(.workflowCustom, language: model.language)
                                        : UIStrings.text(.workflowBuiltIn, language: model.language),
                                    tint: isCustom ? .blue : .purple
                                )
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    UIStrings.targetedAccessibilityLabel(
                        .workflowEdit,
                        target: model.localizedWorkflowName(for: workflow),
                        language: model.language
                    )
                )
                .accessibilityValue(
                    Text(workflowRowAccessibilityValue(isSelected: isSelected, isCustom: isCustom))
                )
                .accessibilityIdentifier("workflow.edit.\(workflow.id.uuidString)")

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle(
                        UIStrings.targetedAccessibilityLabel(
                            .workflowEnabled,
                            target: model.localizedWorkflowName(for: workflow),
                            language: model.language
                        ),
                        isOn: enabledBinding(for: workflow)
                    )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
                        .accessibilityIdentifier("workflow.enabled.\(workflow.id.uuidString)")

                    if isCustom {
                        Button(role: .destructive) {
                            model.deleteCustomWorkflow(workflow)
                            if selectedWorkflowID == workflow.id || editingWorkflowID == workflow.id {
                                resetDraft()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
                        .accessibilityLabel(
                            UIStrings.targetedAccessibilityLabel(
                                .workflowDelete,
                                target: model.localizedWorkflowName(for: workflow),
                                language: model.language
                            )
                        )
                        .accessibilityIdentifier("workflow.delete.\(workflow.id.uuidString)")
                    }
                }
            }

            if !conflictingWorkflowNames.isEmpty {
                Label(
                    UIStrings.workflowConflict(
                        trigger: workflow.trigger,
                        names: conflictingWorkflowNames,
                        language: model.language
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.10)
                : Color.secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.16))
        )
    }

    func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    var saveButtonTitle: String {
        if isInspectingBuiltinWorkflow {
            return model.language == .english ? "Save as Custom Copy" : "另存为自定义副本"
        }
        return UIStrings.text(.workflowSave, language: model.language)
    }

    func saveDraft() {
        let currentEditingID = editingWorkflowID
        model.saveWorkflowDraft(draft, editing: currentEditingID)
        guard model.workflowEditorError == nil else { return }

        if let currentEditingID,
           let savedWorkflow = model.customWorkflows.first(where: { $0.id == currentEditingID }) {
            beginEditing(savedWorkflow)
            return
        }

        if let savedWorkflow = model.customWorkflows.first {
            beginEditing(savedWorkflow)
        } else {
            resetDraft()
        }
    }

    func beginEditing(_ workflow: WorkflowDefinition) {
        guard let draft = WorkflowEditorDraft(workflow: workflow) else {
            model.workflowEditorError = model.language == .english
                ? "This workflow cannot be edited in the current editor."
                : "当前编辑器暂不支持编辑这个工作流。"
            return
        }

        selectedWorkflowID = workflow.id
        editingWorkflowID = model.isCustomWorkflow(workflow) ? workflow.id : nil
        model.workflowEditorError = nil
        self.draft = draft
    }

    func resetDraft() {
        presentedWorkflowExplanation = nil
        model.cancelWorkflowExplanation()
        selectedWorkflowID = nil
        editingWorkflowID = nil
        model.workflowEditorError = nil
        draft = model.defaultWorkflowDraft()
    }

    func enabledBinding(for workflow: WorkflowDefinition) -> Binding<Bool> {
        Binding(
            get: { model.isWorkflowEnabled(workflow) },
            set: { isEnabled in
                model.setWorkflowEnabled(isEnabled, for: workflow.id)
            }
        )
    }

    private func workflowRowAccessibilityValue(isSelected: Bool, isCustom: Bool) -> String {
        var values: [String] = []
        if isSelected {
            values.append(UIStrings.text(.workflowSelected, language: model.language))
        }
        values.append(
            UIStrings.text(isCustom ? .workflowCustom : .workflowBuiltIn, language: model.language)
        )
        return values.joined(separator: model.language == .english ? ", " : "，")
    }
}
