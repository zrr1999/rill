import SwiftUI
import RillCore

struct WorkflowExplanationSheetRequest: Identifiable, Equatable {
    let workflowID: UUID

    var id: UUID { workflowID }
}

struct WorkflowExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: AppModel
    let workflowID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.workflowExplanationCopy(.sheetTitle, language: model.language))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button(L10n.workflowExplanationCopy(.close, language: model.language)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("workflow-explanation.close")
            }

            Label(
                L10n.workflowExplanationCopy(.previewNotice, language: model.language),
                systemImage: RillSystemSymbol.lockShield.rawValue
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: RillRadius.section))

            ScrollView {
                explanationContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label(
                        L10n.workflowExplanationCopy(.refresh, language: model.language),
                        systemImage: RillSystemSymbol.arrowClockwise.rawValue
                    )
                }
                .disabled(isLoading)
                .accessibilityIdentifier("workflow-explanation.refresh")
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 600)
        .accessibilityIdentifier("workflow-explanation.sheet")
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh()
            } else {
                model.cancelWorkflowExplanation()
            }
        }
    }

    @ViewBuilder
    private var explanationContent: some View {
        switch model.workflowLibrary.workflowExplanationState {
        case .loading(let stateWorkflowID) where stateWorkflowID == workflowID:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.workflowExplanationCopy(.loading, language: model.language))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)
            .accessibilityElement(children: .combine)
        case .loaded(let receipt) where receipt.workflowID == workflowID:
            explanationSections(
                WorkflowExplanationPresentation.make(receipt: receipt, language: model.language)
            )
        case .failed(let stateWorkflowID, let reason) where stateWorkflowID == workflowID:
            failureView(reason)
        default:
            failureView(WorkflowExplanationSelectionState.unavailableFailure(
                workflowExists: model.workflowLibrary.workflows.contains(where: { $0.id == workflowID })
            ))
        }
    }

    private var isLoading: Bool {
        guard case .loading(let stateWorkflowID) = model.workflowLibrary.workflowExplanationState else {
            return false
        }
        return stateWorkflowID == workflowID
    }

    private func refresh() {
        guard let workflow = model.workflowLibrary.workflows.first(where: { $0.id == workflowID }) else {
            model.cancelWorkflowExplanation()
            return
        }
        model.explainWorkflowBeforeRun(workflow)
    }

    private func failureView(_ failure: WorkflowExplanationFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L10n.workflowExplanationFailure(failure, language: model.language),
                systemImage: RillSystemSymbol.exclamationmarkShield.rawValue
            )
            .foregroundStyle(.orange)

            Button(L10n.workflowExplanationCopy(.retry, language: model.language)) {
                refresh()
            }
            .disabled(failure == .workflowUnavailable)
        }
        .padding(.vertical, 20)
        .accessibilityElement(children: .contain)
    }

    private func explanationSections(
        _ presentation: WorkflowExplanationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            statusCard(presentation)

            explanationSection(
                title: L10n.workflowExplanationCopy(.trigger, language: model.language),
                rows: [WorkflowExplanationPresentationRow(title: presentation.trigger, detail: "")]
            )
            explanationSection(
                title: L10n.workflowExplanationCopy(.inputs, language: model.language),
                rows: presentation.inputs
            )
            explanationSection(
                title: L10n.workflowExplanationCopy(.transforms, language: model.language),
                rows: presentation.transforms
            )
            explanationSection(
                title: L10n.workflowExplanationCopy(.outputs, language: model.language),
                rows: presentation.outputs
            )
            explanationSection(
                title: L10n.workflowExplanationCopy(.destinations, language: model.language),
                rows: presentation.destinations.map {
                    WorkflowExplanationPresentationRow(title: $0, detail: "")
                }
            )
            explanationSection(
                title: L10n.workflowExplanationCopy(.privacyConditions, language: model.language),
                rows: presentation.privacyReasons.map {
                    WorkflowExplanationPresentationRow(title: $0, detail: "")
                }
            )
            explanationSection(
                title: L10n.workflowExplanationCopy(.issues, language: model.language),
                rows: presentation.issues.map {
                    WorkflowExplanationPresentationRow(title: $0, detail: "")
                }
            )
        }
    }

    private func statusCard(_ presentation: WorkflowExplanationPresentation) -> some View {
        let style = statusStyle(presentation.status)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon.rawValue)
                .font(.title3)
                .foregroundStyle(style.color)

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.statusTitle)
                    .font(.headline)
                Text(presentation.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.10), in: RoundedRectangle(cornerRadius: RillRadius.section))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workflow-explanation.status")
    }

    private func explanationSection(
        title: String,
        rows: [WorkflowExplanationPresentationRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if rows.isEmpty {
                Text(L10n.workflowExplanationCopy(.none, language: model.language))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.callout.weight(.medium))
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .rillCard(.subdued, cornerRadius: RillRadius.section, padding: 14)
    }

    private func statusStyle(
        _ status: WorkflowExplanationStatus
    ) -> (icon: RillSystemSymbol, color: Color) {
        switch status {
        case .ready:
            (.checkmarkShield, .green)
        case .requiresConfirmation:
            (.questionmarkBubble, .orange)
        case .blocked:
            (.xmarkShield, .red)
        }
    }
}
