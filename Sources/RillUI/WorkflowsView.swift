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
    @State var pendingWorkflowDeletion: WorkflowDefinition?
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
        .confirmationDialog(
            UIStrings.text(.workflowDeleteConfirmationTitle, language: model.language),
            isPresented: Binding(
                get: { pendingWorkflowDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingWorkflowDeletion = nil
                    }
                }
            ),
            presenting: pendingWorkflowDeletion
        ) { workflow in
            Button(UIStrings.text(.workflowDelete, language: model.language), role: .destructive) {
                pendingWorkflowDeletion = nil
                deleteCustomWorkflow(workflow)
            }
            .accessibilityIdentifier("workflow.delete.confirm")
            Button(L10n.historySettingsText(.cancel, language: model.language), role: .cancel) {
                pendingWorkflowDeletion = nil
            }
            .accessibilityIdentifier("workflow.delete.cancel")
        } message: { _ in
            Text(UIStrings.text(.workflowDeleteConfirmationDetail, language: model.language))
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
                            L10n.workflowText(.workflowOpenFolder, language: model.language),
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
                            L10n.workflowText(.workflowReload, language: model.language),
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
                    Text(L10n.workflowText(.workflowTOMLSourceOfTruthHint, language: model.language))
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
                                        L10n.workflowText(.workflowEditTOML, language: model.language),
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
                            L10n.workflowText(.workflowBuiltinOverrideHint, language: model.language),
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
            return L10n.workflowText(.workflowEditorSubtitleBuiltin, language: model.language)
        }
        if editingWorkflowID != nil {
            return L10n.workflowText(.workflowEditorSubtitleEditing, language: model.language)
        }
        return L10n.workflowText(.workflowEditorSubtitleNew, language: model.language)
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
                title: L10n.workflowText(.workflowEventNodeTitle, language: model.language)
            ) {
                TextField(
                    UIStrings.text(.workflowNameField, language: model.language),
                    text: $draft.name
                )
                .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.workflowText(.workflowTriggerTypeLabel, language: model.language))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Picker(
                        UIStrings.text(.workflowTrigger, language: model.language),
                        selection: $draft.eventType
                    ) {
                        Text(L10n.workflowText(.workflowTriggerHotkey, language: model.language))
                            .tag(WorkflowEditorDraft.EventType.hotkey)
                        Text(L10n.workflowText(.workflowTriggerManual, language: model.language))
                            .tag(WorkflowEditorDraft.EventType.manual)
                        Text(L10n.workflowText(.workflowTriggerMenuBar, language: model.language))
                            .tag(WorkflowEditorDraft.EventType.menuBar)
                        Text(L10n.workflowText(.workflowTriggerWakeWord, language: model.language))
                            .tag(WorkflowEditorDraft.EventType.wakeWord)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if draft.eventType == .wakeWord {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.workflowText(.workflowWakePhrasesLabel, language: model.language))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField(
                            L10n.workflowText(.workflowWakePhrasesPlaceholder, language: model.language),
                            text: $draft.wakePhrasesText,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        Text(L10n.workflowText(.workflowWakePhrasesHint, language: model.language))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !draft.eventType.isVoiceEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UIStrings.text(.workflowSourceCollection, language: model.language))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker(
                            UIStrings.text(.workflowSourceCollection, language: model.language),
                            selection: Binding(
                                get: { draft.sourceCollectionID },
                                set: { draft.sourceCollectionID = $0 }
                            )
                        ) {
                            Text(L10n.workflowText(.workflowAnyCollection, language: model.language)).tag(nil as UUID?)
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
                tint: .teal,
                title: L10n.workflowText(.workflowConditionNodeTitle, language: model.language)
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
                        Text(L10n.workflowText(.workflowNoAdditionalConditions, language: model.language))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Toggle(
                        L10n.workflowText(.workflowExcludePolishItems, language: model.language),
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
                title: L10n.workflowText(.workflowModeOutputNodeTitle, language: model.language)
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
                        L10n.workflowText(.workflowRestoreDefaults, language: model.language)
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
            return L10n.workflowText(.workflowStepNormalizeWhitespace, language: model.language)
        case .llmRewrite:
            return L10n.workflowText(.workflowStepLLMRewrite, language: model.language)
        case .llmAnswer:
            return L10n.workflowText(.workflowStepLLMAnswer, language: model.language)
        case .snippetReplacement:
            return L10n.workflowText(.workflowStepSnippetReplacement, language: model.language)
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
            model.workflowEditorError = L10n.workflowText(
                .workflowNotEditableError,
                language: model.language
            )
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
