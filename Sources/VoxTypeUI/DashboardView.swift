import SwiftUI
import VoxTypeCore

public struct DashboardView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(UIStrings.text(.appSubtitle, language: model.language))
                    .foregroundStyle(.secondary)
                workflowPicker
                controls
                statusCards
                if let pending = model.pendingResolution {
                    CandidatePanelView(
                        candidateCase: pending,
                        language: model.language,
                        onApply: { selections in
                            model.acceptResolution(selections: selections)
                        },
                        onDismiss: {
                            model.dismissResolution()
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
                eventFeed
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.25), value: model.pendingResolution != nil)
        }
        .navigationTitle(UIStrings.text(.appTitle, language: model.language))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.runSelectedWorkflow()
                } label: {
                    Label(model.workflowRunButtonTitle(for: model.selectedWorkflow), systemImage: "play.fill")
                }
                .disabled(!model.canRunSelectedWorkflow)

                Button {
                    model.deliverTopOfStack()
                } label: {
                    Label(UIStrings.text(.pasteTopOfStack, language: model.language), systemImage: "doc.on.clipboard")
                }
                .disabled(!model.canDeliverTopOfStack)
            }
        }
    }

    private var workflowPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(UIStrings.text(.workflow, language: model.language))
                    .font(.headline)
                Spacer()
                Button(UIStrings.text(.openWorkflowEditor, language: model.language)) {
                    model.openWorkflowEditor()
                }
            }
            Picker(UIStrings.text(.workflow, language: model.language), selection: $model.selectedWorkflowID) {
                ForEach(model.workflows) { workflow in
                    Text(model.localizedWorkflowName(for: workflow)).tag(workflow.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isRunning)

            if let selectedWorkflow = model.selectedWorkflow {
                Text(UIStrings.workflowDetail(selectedWorkflow, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(model.workflowRunButtonTitle(for: model.selectedWorkflow)) {
                model.runSelectedWorkflow()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canRunSelectedWorkflow)

            Button(UIStrings.text(.pasteTopOfStack, language: model.language)) {
                model.deliverTopOfStack()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!model.canDeliverTopOfStack)
        }
    }

    private var statusCards: some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                model.showClipboardPanel()
            } label: {
                statusCard(
                    title: UIStrings.text(.deliveryStack, language: model.language),
                    primary: UIStrings.stackCountSummary(model.stackCount, language: model.language),
                    secondary: model.stackPreview ?? UIStrings.text(.stackEmpty, language: model.language)
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Delivery Stack: \(model.stackCount) items")

            statusCard(
                title: UIStrings.text(.latestOutput, language: model.language),
                primary: model.lastCompletedText ?? UIStrings.text(.noCompletedOutput, language: model.language),
                secondary: model.lastFailure ?? UIStrings.text(.noRecentFailure, language: model.language)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Latest Output: \(model.lastCompletedText ?? "None")")
        }
        .animation(.easeInOut(duration: 0.2), value: model.stackCount)
        .animation(.easeInOut(duration: 0.2), value: model.lastCompletedText)
    }

    private func statusCard(title: String, primary: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(primary)
                .font(.body.weight(.medium))
            Text(secondary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .voxCard(opacity: 0.35)
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UIStrings.text(.eventFeed, language: model.language))
                .font(.headline)
            if model.eventFeed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(UIStrings.text(.eventFeedEmpty, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.eventFeed) { entry in
                            Text(entry.text(for: model.language))
                                .voxCard(cornerRadius: 10, opacity: 0.2, padding: 10)
                        }
                    }
                }
            }
        }
    }
}
