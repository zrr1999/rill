import AppKit
import SwiftUI
import RillCore

public struct WorkflowsView: View {
    static let availableStepKinds: [PostProcessStepKind] = [
        .normalizeWhitespace,
        .llmRewrite,
        .llmAnswer,
    ]

    @Bindable var model: AppModel
    @State var draft = WorkflowEditorDraft()
    @State var editingWorkflowID: UUID?
    @State var selectedWorkflowID: UUID?
    @State var presentedWorkflowExplanation: WorkflowExplanationSheetRequest?
    @State var newVocabularyCollectionName = ""
    @State var isSavingDraft = false

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
        .task(id: model.isLoadingSettings) {
            guard !model.isLoadingSettings else { return }
            await model.reloadWorkflowFiles()
            if let editingWorkflowID,
               let workflow = model.workflows.first(where: { $0.id == editingWorkflowID }) {
                beginEditing(workflow)
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

                if let directoryURL = model.workflowConfigurationDirectoryURL {
                    Button {
                        NSWorkspace.shared.open(directoryURL)
                    } label: {
                        Label(
                            model.language == .english ? "Open Folder" : "打开目录",
                            systemImage: RillSystemSymbol.folder.rawValue
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(directoryURL.path)
                    .accessibilityIdentifier("workflows.open-config-directory")

                    Button {
                        Task { @MainActor in
                            await model.reloadWorkflowFiles()
                            if let editingWorkflowID,
                               let workflow = model.workflows.first(where: {
                                   $0.id == editingWorkflowID
                               }) {
                                beginEditing(workflow)
                            }
                        }
                    } label: {
                        Label(
                            model.language == .english ? "Reload" : "重新加载",
                            systemImage: RillSystemSymbol.arrowClockwise.rawValue
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isLoadingSettings)
                    .accessibilityIdentifier("workflows.reload-toml")
                }

                Button {
                    resetDraft()
                } label: {
                    Label(UIStrings.text(.workflowNew, language: model.language), systemImage: RillSystemSymbol.plus.rawValue)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
            }

            if let directoryURL = model.workflowConfigurationDirectoryURL {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model.language == .english
                            ? "TOML files are the source of truth. This window is a visual editor for them."
                            : "TOML 文件是唯一事实来源；此窗口只是它们的可视化编辑器。"
                    )
                    Text(directoryURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("workflows.config-directory")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        workflows: model.userCreatedWorkflows,
                        isCustom: true,
                        localizedWorkflowNames: localizedWorkflowNames
                    )

                    workflowListSection(
                        title: UIStrings.text(.workflowBuiltIn, language: model.language),
                        emptyTitle: nil,
                        workflows: model.editableBuiltInWorkflows,
                        isCustom: false,
                        localizedWorkflowNames: localizedWorkflowNames
                    )

                    Divider()

                    vocabularyLibrarySection
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
                        HStack(spacing: 8) {
                            Button {
                                guard canExplainSelectedWorkflow else { return }
                                model.explainWorkflowBeforeRun(selectedWorkflow)
                                presentedWorkflowExplanation = WorkflowExplanationSheetRequest(
                                    workflowID: selectedWorkflow.id
                                )
                            } label: {
                                Label(
                                    UIStrings.workflowExplanationCopy(.button, language: model.language),
                                    systemImage: RillSystemSymbol.docTextMagnifyingglass.rawValue
                                )
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canExplainSelectedWorkflow)
                            .accessibilityIdentifier("workflow-explanation.open")

                            if let fileURL = model.workflowFileURLsByID[selectedWorkflow.id] {
                                Button {
                                    NSWorkspace.shared.open(fileURL)
                                } label: {
                                    Label(
                                        model.language == .english ? "Edit TOML" : "编辑 TOML",
                                        systemImage: RillSystemSymbol.docText.rawValue
                                    )
                                }
                                .buttonStyle(.bordered)
                                .help(fileURL.path)
                                .accessibilityIdentifier("workflow.open-toml")
                            }
                        }

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
                                ? "Changes are saved as a TOML override for this built-in workflow. Restore Defaults removes the override."
                                : "修改会保存为此内置工作流的 TOML 覆盖；“恢复默认”会移除该覆盖。",
                            systemImage: RillSystemSymbol.arrowTriangle2Circlepath.rawValue
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
                ? "Edit this built-in workflow directly, or restore its bundled defaults later."
                : "直接编辑这个内置工作流；之后也可以恢复到应用内置默认值。"
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
                icon: RillSystemSymbol.boltCircleFill.rawValue,
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
                        Text(model.language == .english ? "◉ Wake Word" : "◉ 唤醒词")
                            .tag(WorkflowEditorDraft.EventType.wakeWord)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if draft.eventType == .wakeWord {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.language == .english ? "Wake phrases" : "唤醒短语")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField(
                            model.language == .english
                                ? "One phrase per line (1–4)"
                                : "每行一个短语（1–4 个）",
                            text: $draft.wakePhrasesText,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        Text(
                            model.language == .english
                                ? "Local listening is off by default. Prepare the selected local Qwen ASR in Voice settings before enabling this workflow."
                                : "本地监听默认关闭；启用此工作流前，请先在语音设置中准备当前本地 Qwen ASR。"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                if !draft.eventType.isVoiceEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.language == .english ? "Source Collection" : "来源记录集")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker(
                            UIStrings.text(.workflowSourceCollection, language: model.language),
                            selection: Binding(
                                get: { draft.sourceCollectionID },
                                set: { draft.sourceCollectionID = $0 }
                            )
                        ) {
                            Text(model.language == .english ? "Any collection" : "任意记录集").tag(nil as UUID?)
                            ForEach(model.recordWorkspace.snapshot.collections) { collection in
                                Text(collection.name).tag(collection.id.rawValue as UUID?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }

            editorNodeConnector()

            editorNodeCard(
                icon: RillSystemSymbol.line3HorizontalDecreaseCircleFill.rawValue,
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
                icon: RillSystemSymbol.playCircleFill.rawValue,
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
                .disabled(
                    isSavingDraft
                        || model.isLoadingSettings
                        || !model.isWorkflowLibraryAvailable
                )

                if isInspectingBuiltinWorkflow, let selectedWorkflow {
                    Button(
                        model.language == .english ? "Restore Defaults" : "恢复默认"
                    ) {
                        restoreBuiltInWorkflow(selectedWorkflow)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isSavingDraft
                            || model.isLoadingSettings
                            || !model.isWorkflowLibraryAvailable
                            || !model.canRestoreBuiltInWorkflow(selectedWorkflow)
                    )
                    .accessibilityIdentifier("workflow.builtin.restore-defaults")
                }

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

    func workflowPhaseHeader(
        _ phase: WorkflowPhaseKind,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phase.rawValue.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, phase == .setup ? 0 : 8)
        .accessibilityIdentifier("workflow.phase.\(phase.rawValue)")
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
        case .llmAnswer:
            return model.language == .english ? "LLM Answer" : "LLM 回答"
        case .snippetReplacement:
            return model.language == .english ? "Snippet Replacement" : "片段替换"
        }
    }

    func postProcessStepSystemSymbol(_ kind: PostProcessStepKind) -> RillSystemSymbol {
        switch kind {
        case .normalizeWhitespace: return .textAlignLeft
        case .llmRewrite: return .wandAndStars
        case .llmAnswer: return .questionmarkBubble
        case .snippetReplacement: return .textInsert
        }
    }
}

extension WorkflowsView {
    var saveButtonTitle: String {
        return UIStrings.text(.workflowSave, language: model.language)
    }

    func saveDraft() {
        guard !isSavingDraft else { return }
        isSavingDraft = true
        let submittedDraft = draft
        let currentEditingID = editingWorkflowID
        Task { @MainActor in
            defer { isSavingDraft = false }
            await model.saveWorkflowDraft(submittedDraft, editing: currentEditingID)
            guard model.workflowEditorError == nil else { return }

            if let currentEditingID,
               let savedWorkflow = model.workflows.first(where: { $0.id == currentEditingID }) {
                beginEditing(savedWorkflow)
                return
            }

            if let savedWorkflow = model.userCreatedWorkflows.first {
                beginEditing(savedWorkflow)
            } else {
                resetDraft()
            }
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
        editingWorkflowID = workflow.id
        model.workflowEditorError = nil
        self.draft = draft
    }

    func restoreBuiltInWorkflow(_ workflow: WorkflowDefinition) {
        guard !isSavingDraft else { return }
        isSavingDraft = true
        Task { @MainActor in
            defer { isSavingDraft = false }
            await model.restoreBuiltInWorkflowToDefault(workflow)
            guard model.workflowEditorError == nil,
                  let restoredWorkflow = model.workflows.first(where: { $0.id == workflow.id }) else {
                return
            }
            beginEditing(restoredWorkflow)
        }
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
}
