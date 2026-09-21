import AppKit
import RillCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowDocumentLibraryView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var pendingDeletion: WorkflowDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.workflowDocument(.labelWorkflows, language: model.language)).font(
                        .title2.bold())
                    Text(
                        L10n.workflowDocument(
                            .labelEditExternally,
                            language: model.language)
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(
                        L10n.workflowDocument(.labelImportTOML, language: model.language),
                        action: importFile)
                    if let directory = model.workflowConfigurationDirectoryURL {
                        Button(
                            L10n.workflowDocument(
                                .labelShowConfigurationFolder, language: model.language)
                        ) {
                            NSWorkspace.shared.selectFile(
                                nil, inFileViewerRootedAtPath: directory.path)
                        }
                    }
                    Button(L10n.workflowDocument(.labelReloadFiles, language: model.language)) {
                        Task { await model.reloadWorkflowFiles() }
                    }
                    Divider()
                    ForEach(model.builtInWorkflows) { workflow in
                        Button(
                            L10n.workflowDocument(.labelNewFrom, language: model.language)
                                + model.localizedWorkflowName(for: workflow)
                        ) {
                            open(workflow, duplicate: true)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel(
                        L10n.workflowDocument(.labelMoreActions, language: model.language))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button(
                    L10n.workflowDocument(.labelNewWorkflow, language: model.language),
                    systemImage: "plus"
                ) {
                    Task {
                        if let url = await model.newWorkflowFile() { openFile(url) }
                    }
                }
                .disabled(model.isLoadingSettings || !model.isWorkflowLibraryAvailable)
            }
            TextField(
                L10n.workflowDocument(.labelSearchWorkflows, language: model.language), text: $query
            ).textFieldStyle(.roundedBorder)
            if let error = model.workflowLibraryError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            List {
                ForEach(
                    model.workflows.filter {
                        query.isEmpty
                            || model.localizedWorkflowName(for: $0)
                                .localizedCaseInsensitiveContains(query)
                    }
                ) { workflow in
                    let isBuiltIn = model.builtInWorkflows.contains { $0.id == workflow.id }
                    HStack(spacing: 12) {
                        Image(systemName: workflow.ui.symbolName).font(.title3).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: RillSpacing.row) {
                                Text(model.localizedWorkflowName(for: workflow)).font(.headline)
                                if isBuiltIn {
                                    Text(L10n.workflowDocument(.labelPreset, language: model.language))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, RillSpacing.row)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.16), in: Capsule())
                                        .overlay {
                                            Capsule().strokeBorder(.blue.opacity(0.35), lineWidth: 1)
                                        }
                                        .fixedSize()
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Text(status(workflow)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            L10n.workflowDocument(.labelEnabled, language: model.language),
                            isOn: Binding(
                                get: { model.isWorkflowEnabled(workflow) },
                                set: { model.setWorkflowEnabled($0, for: workflow.id) }
                            )
                        ).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel(
                                model.localizedWorkflowName(for: workflow) + " "
                                    + L10n.workflowDocument(.labelEnabled, language: model.language)
                            )
                            .disabled(model.invalidWorkflowFileIDs.contains(workflow.id)
                                || model.isUpdatingWorkflowEnabledStates || model.isLoadingSettings)
                        Button(
                            L10n.workflowDocument(
                                workflow.inputKind == .audio ? .labelRun : .labelRunClipboardText,
                                language: model.language), systemImage: "play.fill"
                        ) {
                            if workflow.inputKind == .audio {
                                model.runWorkflow(workflow)
                            } else {
                                if let text = NSPasteboard.general.string(forType: .string) {
                                    model.runWorkflowText(text, workflow: workflow)
                                }
                            }
                        }.disabled(!model.isWorkflowEnabled(workflow) || model.isRunning)
                        Button(L10n.workflowDocument(.labelOpenFile, language: model.language)) {
                            open(workflow)
                        }
                        .accessibilityIdentifier("workflow.document.open.\(workflow.id)")
                        Menu {
                            Button(L10n.workflowDocument(.labelDuplicate, language: model.language))
                            { open(workflow, duplicate: true) }
                            if isBuiltIn {
                                Button(
                                    L10n.workflowDocument(
                                        .labelRestoreDefault, language: model.language)
                                ) { pendingDeletion = workflow }
                            } else {
                                Button(
                                    L10n.workflowDocument(.labelDelete, language: model.language),
                                    role: .destructive
                                ) { pendingDeletion = workflow }
                            }
                        } label: {
                            Image(systemName: "ellipsis").accessibilityLabel(
                                L10n.workflowDocument(
                                    .labelWorkflowActions, language: model.language))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 6)
                }
                ForEach(Array(model.workflowFileIssues.enumerated()), id: \.offset) { _, issue in
                    HStack {
                        Label(issue.filename, systemImage: "doc.badge.ellipsis").foregroundStyle(
                            .orange)
                        Spacer()
                        Button(L10n.workflowDocument(.labelOpenFile, language: model.language)) {
                            if let directory = model.workflowConfigurationDirectoryURL {
                                NSWorkspace.shared.open(
                                    directory.appendingPathComponent(issue.filename))
                            }
                        }
                    }.help(issue.message)
                }
            }.listStyle(.inset(alternatesRowBackgrounds: true))
            if let directory = model.workflowConfigurationDirectoryURL {
                Text(directory.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .task(id: model.isLoadingSettings) {
            if !model.isLoadingSettings { await model.reloadWorkflowFiles() }
        }
        .task(id: model.workflowEditorNavigationRequest?.id) {
            guard let request = model.workflowEditorNavigationRequest,
                let workflow = model.workflows.first(where: { $0.id == request.workflowID })
            else { return }
            open(workflow)
            model.workflowEditorNavigationRequest = nil
        }
        .confirmationDialog(
            L10n.workflowDocument(.labelRemoveThisCustomization, language: model.language),
            isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(
                L10n.workflowDocument(.labelRemove, language: model.language), role: .destructive
            ) {
                guard let workflow = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    if model.builtInWorkflows.contains(where: { $0.id == workflow.id }) {
                        await model.restoreBuiltInWorkflowToDefault(workflow)
                    } else {
                        await model.deleteCustomWorkflow(workflow)
                    }
                    await model.reloadWorkflowFiles()
                }
            }
        }
    }

    private func status(_ workflow: WorkflowDefinition) -> String {
        if model.invalidWorkflowFileIDs.contains(workflow.id) {
            return L10n.workflowDocument(
                .labelInvalidFileNewRunsAreBlocked, language: model.language)
        }
        if let readiness = model.workflowEnablementError(for: workflow) { return readiness }
        let origin = model.workflowFileURLsByID[workflow.id] == nil ? "" : "TOML · "
        return "\(origin)\(workflow.plan.process.allSteps.count) "
            + L10n.workflowDocument(.labelSteps, language: model.language)
            + " · \(workflow.plan.output.actions.count) "
            + L10n.workflowDocument(.labelOutputs, language: model.language)
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
