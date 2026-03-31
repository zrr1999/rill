import SwiftUI
import VoxTypeCore

public struct WorkflowsView: View {
    private static let supportedTriggers: [TriggerBinding] = [.manual, .hotkey, .menuBar]

    @Bindable private var model: AppModel
    @State private var draft = WorkflowEditorDraft()
    @State private var editingWorkflowID: UUID?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                editorSection
                librarySection
            }
            .padding(24)
        }
        .onAppear {
            if draft.name.isEmpty, editingWorkflowID == nil {
                draft = model.defaultWorkflowDraft()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(UIStrings.text(.workflowsTitle, language: model.language))
                    .font(.largeTitle.weight(.semibold))
                Text(UIStrings.text(.workflowsDescription, language: model.language))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(UIStrings.text(.workflowNew, language: model.language)) {
                resetDraft()
            }
        }
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
                Text(UIStrings.text(.workflowEditor, language: model.language))
                    .font(.headline)

                TextField(
                    UIStrings.text(.workflowNameField, language: model.language),
                    text: $draft.name
                )
                .textFieldStyle(.roundedBorder)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(UIStrings.text(.workflowRecognizer, language: model.language))
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $draft.recognizer) {
                            ForEach(WorkflowEditorDraft.RecognizerChoice.allCases) { recognizer in
                                Text(UIStrings.editorRecognizer(recognizer, language: model.language)).tag(recognizer)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(UIStrings.text(.workflowDestination, language: model.language))
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $draft.destination) {
                            ForEach(WorkflowEditorDraft.DestinationChoice.allCases) { destination in
                                Text(UIStrings.editorDestination(destination, language: model.language)).tag(destination)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(UIStrings.text(.workflowTrigger, language: model.language))
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $draft.trigger) {
                            ForEach(Self.supportedTriggers, id: \.rawValue) { trigger in
                                Text(UIStrings.workflowTrigger(trigger, language: model.language)).tag(trigger)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Toggle(UIStrings.text(.workflowNormalizeWhitespace, language: model.language), isOn: $draft.normalizeWhitespace)
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if draft.destination != .pasteIntoApp {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(
                            UIStrings.text(.workflowExcludeFromCapture, language: model.language),
                            isOn: $draft.excludeFromWorkflowCapture
                        )
                        .toggleStyle(.checkbox)

                        Text(UIStrings.text(.workflowExcludeFromCaptureHint, language: model.language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.recognizer == .localSpeech {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(UIStrings.text(.workflowLocalModel, language: model.language))
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $draft.whisperKitModelOverride) {
                            Text(UIStrings.text(.workflowGlobalModelDefault, language: model.language)).tag("")
                            ForEach(model.workflowSelectableWhisperKitModels, id: \.self) { modelIdentifier in
                                Text(model.whisperKitModelDisplayName(modelIdentifier, includeStatus: true))
                                    .tag(modelIdentifier)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                if let workflowEditorError = model.workflowEditorError {
                    Text(workflowEditorError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button(UIStrings.text(.workflowSave, language: model.language)) {
                        model.saveWorkflowDraft(draft, editing: editingWorkflowID)
                        if model.workflowEditorError == nil {
                            resetDraft()
                        }
                    }

                    Button(UIStrings.text(.workflowReset, language: model.language)) {
                        resetDraft()
                    }
                }
            }
            .voxCard()
    }

    private var librarySection: some View {
        let localizedWorkflowNames = Dictionary(
            uniqueKeysWithValues: model.workflows.map { ($0.id, model.localizedWorkflowName(for: $0)) }
        )

        return VStack(alignment: .leading, spacing: 16) {
            Text(UIStrings.text(.workflowLibrary, language: model.language))
                .font(.headline)

            if let workflowLibraryError = model.workflowLibraryError, !workflowLibraryError.isEmpty {
                Text(workflowLibraryError)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if model.customWorkflows.isEmpty {
                Text(UIStrings.text(.workflowCustomEmpty, language: model.language))
                    .foregroundStyle(.secondary)
            } else {
                workflowGroup(
                    title: UIStrings.text(.workflowCustom, language: model.language),
                    workflows: model.customWorkflows,
                    isCustom: true,
                    localizedWorkflowNames: localizedWorkflowNames
                )
            }

            workflowGroup(
                title: UIStrings.text(.workflowBuiltIn, language: model.language),
                workflows: model.builtInWorkflows,
                isCustom: false,
                localizedWorkflowNames: localizedWorkflowNames
            )
        }
    }

    private func workflowGroup(
        title: String,
        workflows: [WorkflowDefinition],
        isCustom: Bool,
        localizedWorkflowNames: [UUID: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(workflows) { workflow in
                    workflowCard(
                        workflow,
                        isCustom: isCustom,
                        localizedWorkflowNames: localizedWorkflowNames
                    )
                }
            }
        }
    }

    private func workflowCard(
        _ workflow: WorkflowDefinition,
        isCustom: Bool,
        localizedWorkflowNames: [UUID: String]
    ) -> some View {
        let conflictingWorkflowNames = (model.workflowConflictIDsByWorkflowID[workflow.id] ?? [])
            .compactMap { localizedWorkflowNames[$0] }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: workflow.ui.symbolName)
                    .font(.title3)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.localizedWorkflowName(for: workflow))
                        .font(.headline)
                    Text(UIStrings.workflowDetail(workflow, language: model.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    badge(isCustom ? .workflowCustom : .workflowBuiltIn)
                    if model.selectedWorkflowID == workflow.id {
                        badge(.workflowSelected)
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

            HStack {
                Button(UIStrings.text(.workflowUse, language: model.language)) {
                    model.selectedWorkflowID = workflow.id
                }
                .disabled(!model.isWorkflowEnabled(workflow))

                if isCustom {
                    Button(UIStrings.text(.workflowEdit, language: model.language)) {
                        beginEditing(workflow)
                    }

                    Button(role: .destructive) {
                        model.deleteCustomWorkflow(workflow)
                        if editingWorkflowID == workflow.id {
                            resetDraft()
                        }
                    } label: {
                        Text(UIStrings.text(.workflowDelete, language: model.language))
                    }
                }

                Spacer()

                Toggle(
                    UIStrings.text(.workflowEnabled, language: model.language),
                    isOn: enabledBinding(for: workflow)
                )
                .toggleStyle(.switch)
            }
        }
        .voxCard()
    }

    private func badge(_ key: UIStrings.Key) -> some View {
        Text(UIStrings.text(key, language: model.language))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(.blue)
    }

    private func beginEditing(_ workflow: WorkflowDefinition) {
        guard let draft = WorkflowEditorDraft(workflow: workflow) else {
            model.workflowEditorError = model.language == .english
                ? "This workflow cannot be edited in the current editor."
                : "当前编辑器暂不支持编辑这个工作流。"
            return
        }

        editingWorkflowID = workflow.id
        model.workflowEditorError = nil
        self.draft = draft
    }

    private func resetDraft() {
        editingWorkflowID = nil
        model.workflowEditorError = nil
        draft = model.defaultWorkflowDraft()
    }

    private func enabledBinding(for workflow: WorkflowDefinition) -> Binding<Bool> {
        Binding(
            get: { model.isWorkflowEnabled(workflow) },
            set: { isEnabled in
                model.setWorkflowEnabled(isEnabled, for: workflow.id)
            }
        )
    }
}
