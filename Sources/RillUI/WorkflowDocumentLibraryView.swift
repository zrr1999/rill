import AppKit
import RillCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowDocumentLibraryView: View {
    @Bindable var model: AppModel
    @State private var selectedID: UUID?
    @State private var showsCompactList = true
    @State private var pendingDeletion: WorkflowDefinition?
    @State private var explanation: WorkflowExplanationSheetRequest?

    private var selection: WorkflowDefinition? { model.workflowLibrary.workflows.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.workflowLibrary.workflowLibraryError {
                Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding()
            }
            GeometryReader { geometry in
                if geometry.size.width >= 700 {
                    HSplitView {
                        workflowList.frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                        workflowDetail.frame(minWidth: 340, maxWidth: .infinity)
                    }
                } else if showsCompactList || selection == nil {
                    workflowList
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Button { showsCompactList = true } label: {
                                Label(L10n.workflowDocument(.labelWorkflows, language: model.settings.language), systemImage: RillSystemSymbol.chevronLeft.rawValue)
                            }
                            Spacer()
                        }.padding()
                        Divider()
                        workflowDetail
                    }
                }
            }
        }
        .navigationTitle(L10n.workflowDocument(.labelWorkflows, language: model.settings.language))
        .toolbar { ToolbarItemGroup { libraryActions } }
        .task(id: model.settings.isLoading) {
            if !model.settings.isLoading { await model.reloadWorkflowFiles() }
            if selectedID == nil { selectedID = model.workflowLibrary.workflows.first?.id }
        }
        .task(id: model.workflowEditorNavigationRequest?.id) {
            guard let request = model.workflowEditorNavigationRequest else { return }
            selectedID = request.workflowID
            showsCompactList = false
            model.workflowEditorNavigationRequest = nil
        }
        .onChange(of: model.workflowLibrary.workflows.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .sheet(item: $explanation, onDismiss: model.workflowLibrary.cancelWorkflowExplanation) { request in
            WorkflowExplanationSheet(model: model, workflowID: request.workflowID)
        }
        .confirmationDialog(
            L10n.workflowDocument(.labelRemoveThisCustomization, language: model.settings.language),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.workflowDocument(.labelRemove, language: model.settings.language), role: .destructive) {
                guard let workflow = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    if model.workflowLibrary.builtInWorkflows.contains(where: { $0.id == workflow.id }) {
                        await model.restoreBuiltInWorkflowToDefault(workflow)
                    } else { await model.deleteCustomWorkflow(workflow) }
                    await model.reloadWorkflowFiles()
                }
            }
        }
    }

    private var workflowList: some View {
        List(selection: Binding(get: { selectedID }, set: { selectedID = $0; showsCompactList = false })) {
            ForEach(model.workflowLibrary.workflows) { workflow in
                HStack(spacing: RillSpacing.row) {
                    Image(systemName: RillSystemSymbol.resolvedName(workflow.ui.symbolName)).frame(width: 24)
                    VStack(alignment: .leading, spacing: RillSpacing.compact) {
                        Text(model.localizedWorkflowName(for: workflow)).font(.headline)
                        Text(L10n.workflowTrigger(workflow.trigger, metadata: workflow.metadata, language: model.settings.language))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if model.isWorkflowEnabled(workflow) {
                        Image(systemName: RillSystemSymbol.checkmarkCircleFill.rawValue)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.workflowDocument(.labelEnabled, language: model.settings.language))
                    }
                }.padding(.vertical, RillSpacing.row).tag(workflow.id)
            }
            ForEach(Array(model.workflowLibrary.workflowFileIssues.enumerated()), id: \.offset) { _, issue in
                Button {
                    if let directory = model.workflowConfigurationDirectoryURL { openFile(directory.appendingPathComponent(issue.filename)) }
                } label: {
                    Label(issue.filename, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                        .foregroundStyle(.orange)
                }.help(issue.message)
            }
        }.listStyle(.inset(alternatesRowBackgrounds: false))
    }

    @ViewBuilder private var workflowDetail: some View {
        if let workflow = selection {
            ScrollView {
                VStack(alignment: .leading, spacing: RillSpacing.section) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: RillSpacing.row) {
                            Text(model.localizedWorkflowName(for: workflow)).font(.title2.weight(.semibold))
                            if let description = workflow.documentDescription, !description.isEmpty {
                                Text(description).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle(L10n.workflowDocument(.labelEnabled, language: model.settings.language), isOn: Binding(
                            get: { model.isWorkflowEnabled(workflow) },
                            set: { model.setWorkflowEnabled($0, for: workflow.id) }
                        )).toggleStyle(.switch).fixedSize()
                            .disabled(model.workflowLibrary.invalidWorkflowFileIDs.contains(workflow.id) || model.workflowLibrary.isUpdatingWorkflowEnabledStates || model.settings.isLoading)
                    }
                    if let readiness = model.workflowEnablementError(for: workflow) {
                        Label(readiness, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue).foregroundStyle(.orange)
                    }
                    LabeledContent(L10n.workflowExplanationCopy(.trigger, language: model.settings.language)) {
                        Text(L10n.workflowTrigger(workflow.trigger, metadata: workflow.metadata, language: model.settings.language))
                    }
                    VStack(alignment: .leading, spacing: RillSpacing.row) {
                        Text(L10n.workflowExplanationCopy(.transforms, language: model.settings.language)).font(.headline)
                        ForEach(Array(workflow.plan.process.allSteps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). " + WorkflowStepPresentation.stepTitle(step.kind, language: model.settings.language))
                        }
                    }
                    VStack(alignment: .leading, spacing: RillSpacing.row) {
                        Text(L10n.workflowExplanationCopy(.outputs, language: model.settings.language)).font(.headline)
                        ForEach(Array(workflow.plan.output.actions.enumerated()), id: \.offset) { index, action in
                            Text("\(index + 1). " + L10n.actionName(action.id, language: model.settings.language))
                        }
                    }
                    HStack {
                        Button(L10n.workflowDocument(.labelOpenFile, language: model.settings.language)) { open(workflow) }
                            .accessibilityIdentifier("workflow.document.open.\(workflow.id)")
                        Button(L10n.workflowDocument(workflow.inputKind == .audio ? .labelRun : .labelRunClipboardText, language: model.settings.language)) {
                            if workflow.inputKind == .audio { model.runWorkflow(workflow) }
                            else if let text = NSPasteboard.general.string(forType: .string) { model.runWorkflowText(text, workflow: workflow) }
                        }.disabled(!model.isWorkflowEnabled(workflow) || model.voice.isRunning || model.workflowLibrary.invalidWorkflowFileIDs.contains(workflow.id))
                        Menu {
                            Button(L10n.workflowExplanationCopy(.button, language: model.settings.language)) {
                                model.workflowLibrary.explainWorkflowBeforeRun(workflow)
                                explanation = .init(workflowID: workflow.id)
                            }
                            Button(L10n.workflowDocument(.labelDuplicate, language: model.settings.language)) { open(workflow, duplicate: true) }
                            Button(L10n.workflowDocument(model.workflowLibrary.builtInWorkflows.contains(where: { $0.id == workflow.id }) ? .labelRestoreDefault : .labelDelete, language: model.settings.language), role: .destructive) { pendingDeletion = workflow }
                        } label: { Image(systemName: RillSystemSymbol.ellipsisCircle.rawValue) }
                        .help(L10n.workflowDocument(.labelMoreActions, language: model.settings.language))
                    }
                    Text(L10n.workflowDocument(.labelEditExternally, language: model.settings.language)).font(.caption).foregroundStyle(.secondary)
                }.padding(RillSpacing.page).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(L10n.workspace(.selectWorkflow, language: model.settings.language), systemImage: RillSystemSymbol.point3ConnectedTrianglepathDotted.rawValue)
        }
    }

    @ViewBuilder private var libraryActions: some View {
        Button {
            Task { if let url = await model.newWorkflowFile() { openFile(url) } }
        } label: { Label(L10n.workflowDocument(.labelNewWorkflow, language: model.settings.language), systemImage: RillSystemSymbol.plus.rawValue) }
            .disabled(model.settings.isLoading || !model.isWorkflowLibraryAvailable)
        Menu {
            Button(L10n.workflowDocument(.labelImportTOML, language: model.settings.language), action: importFile)
            if let directory = model.workflowConfigurationDirectoryURL {
                Button(L10n.workflowDocument(.labelShowConfigurationFolder, language: model.settings.language)) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) }
            }
            Button(L10n.workflowDocument(.labelReloadFiles, language: model.settings.language)) { Task { await model.reloadWorkflowFiles() } }
            Divider()
            ForEach(model.workflowLibrary.builtInWorkflows) { workflow in
                Button(L10n.workflowDocument(.labelNewFrom, language: model.settings.language) + model.localizedWorkflowName(for: workflow)) { open(workflow, duplicate: true) }
            }
        } label: { Label(L10n.workflowDocument(.labelMoreActions, language: model.settings.language), systemImage: RillSystemSymbol.ellipsisCircle.rawValue) }
    }

    private func open(_ workflow: WorkflowDefinition, duplicate: Bool = false) {
        Task {
            if let url = await model.workflowFileForEditing(workflow, duplicate: duplicate) { openFile(url) }
        }
    }

    private func openFile(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let file = await model.importWorkflowFile(from: url) { openFile(file) }
            }
        }
    }
}
