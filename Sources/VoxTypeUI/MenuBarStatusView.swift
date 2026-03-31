import SwiftUI

public struct MenuBarStatusView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let menuBarWorkflows = model.enabledWorkflows(for: .menuBar)

        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Text(UIStrings.text(.appTitle, language: model.language))
                    .font(.headline)
                Spacer()
                Text(UIStrings.stackPending(model.stackCount, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Quick actions
            Button {
                model.runSelectedWorkflow()
            } label: {
                HStack {
                    Text(model.workflowRunButtonTitle(for: model.selectedWorkflow))
                    Spacer()
                    Text("⌘R").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.canTriggerWorkflow(model.selectedWorkflow))

            Button {
                model.deliverTopOfStack()
            } label: {
                HStack {
                    Text(UIStrings.text(.pasteTopOfStack, language: model.language))
                    Spacer()
                    Text("⌘⇧V").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.canDeliverTopOfStack)

            Divider()

            // Utilities
            Button(UIStrings.text(.clipboardTitle, language: model.language)) {
                model.showClipboardPanel()
            }
            .keyboardShortcut("b", modifiers: .command)
            Button(UIStrings.text(.openWorkflowEditor, language: model.language)) {
                model.openWorkflowEditor()
            }

            // Menu bar workflows
            if !menuBarWorkflows.isEmpty {
                Divider()
                Text(UIStrings.workflowTrigger(.menuBar, language: model.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(menuBarWorkflows) { workflow in
                    Button(model.workflowMenuButtonTitle(for: workflow)) {
                        model.runWorkflow(workflow, initiatedBy: .menuBar)
                    }
                    .disabled(!model.canTriggerWorkflow(workflow))
                }
            }

            Divider()

            Text(UIStrings.text(.commandVHint, language: model.language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260)
    }
}
