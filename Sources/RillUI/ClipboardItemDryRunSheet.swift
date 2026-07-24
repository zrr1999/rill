import SwiftUI
import RillCore
import RillRuntime

struct ClipboardItemDryRunSheetRequest: Identifiable, Equatable {
    let id: UUID
    let itemID: UUID
    let initialOperation: ClipboardItemDryRunOperation

    init(
        id: UUID = UUID(),
        itemID: UUID,
        initialOperation: ClipboardItemDryRunOperation = .use
    ) {
        self.id = id
        self.itemID = itemID
        self.initialOperation = initialOperation
    }
}

struct ClipboardItemDryRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: AppModel
    let request: ClipboardItemDryRunSheetRequest

    @State private var operation: ClipboardItemDryRunOperation
    @State private var workflowID: UUID?
    @State private var loadState = ClipboardItemDryRunLoadState.idle
    @State private var activeRequestID: UUID
    @State private var acceptedRequestID: UUID?
    @State private var loadCoordinator = ClipboardItemDryRunLoadCoordinator()

    init(model: AppModel, request: ClipboardItemDryRunSheetRequest) {
        self.model = model
        self.request = request
        let initialRequestID = UUID()
        _operation = State(initialValue: request.initialOperation)
        _activeRequestID = State(initialValue: initialRequestID)
        _acceptedRequestID = State(initialValue: initialRequestID)
        let sourceWorkflowID = model.clipboardItems
            .first(where: { $0.id == request.itemID })?
            .workflowID
        let eligibleIDs = model.workflows.filter {
            model.isWorkflowEnabled($0) && WorkflowExecutionPolicy.issue(for: $0) == nil
        }.map(\.id)
        _workflowID = State(
            initialValue: sourceWorkflowID.flatMap { eligibleIDs.contains($0) ? $0 : nil }
                ?? eligibleIDs.first
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notices
            selectors

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    refresh(clearResult: false)
                } label: {
                    Label(
                        UIStrings.clipboardItemDryRunCopy(.refresh, language: model.language),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isLoading)
                .accessibilityIdentifier("clipboard-dry-run.refresh")
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 600, idealHeight: 760)
        .task(id: activeRequestID) {
            await submitCurrentRequest()
        }
        .onChange(of: operation) { _, _ in
            ensureWorkflowSelection()
            refresh(clearResult: true)
        }
        .onChange(of: workflowID) { _, _ in
            guard operation != .use else { return }
            refresh(clearResult: true)
        }
        .onChange(of: currentItem?.version) { _, _ in
            refresh(clearResult: true)
        }
        .onChange(of: currentItem?.contentKind) { _, _ in
            normalizeOperationForCurrentItem()
            refresh(clearResult: true)
        }
        .onChange(of: eligibleWorkflowIDs) { _, _ in
            ensureWorkflowSelection()
            refresh(clearResult: true)
        }
        .onChange(of: model.workflows) { _, _ in
            refresh(clearResult: true)
        }
        .onChange(of: model.privacyPolicySettings) { _, _ in
            refresh(clearResult: true)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refresh(clearResult: true)
            } else {
                cancelLoading()
            }
        }
        .onDisappear {
            cancelLoading()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(UIStrings.clipboardItemDryRunCopy(.sheetTitle, language: model.language))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("clipboard-dry-run.sheet")

            Spacer()

            Button(UIStrings.clipboardItemDryRunCopy(.close, language: model.language)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("clipboard-dry-run.close")
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            notice(
                UIStrings.clipboardItemDryRunCopy(.previewNotice, language: model.language),
                systemImage: "eye.trianglebadge.exclamationmark",
                tint: .blue
            )
            notice(
                UIStrings.clipboardItemDryRunCopy(.runtimeNotice, language: model.language),
                systemImage: "lock.shield",
                tint: .secondary
            )
        }
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }

    private var selectors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                UIStrings.clipboardItemDryRunCopy(.operation, language: model.language),
                selection: $operation
            ) {
                ForEach(availableOperations, id: \.self) { candidate in
                    Text(UIStrings.clipboardItemDryRunOperation(candidate, language: model.language))
                        .tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("clipboard-dry-run.operation")

            if operation != .use {
                Picker(
                    UIStrings.clipboardItemDryRunCopy(.workflow, language: model.language),
                    selection: $workflowID
                ) {
                    if eligibleWorkflows.isEmpty {
                        Text(UIStrings.clipboardItemDryRunCopy(.noWorkflow, language: model.language))
                            .tag(Optional<UUID>.none)
                    } else {
                        ForEach(eligibleWorkflows) { workflow in
                            Text(model.localizedWorkflowName(for: workflow))
                                .tag(Optional(workflow.id))
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(eligibleWorkflows.isEmpty)
                .accessibilityIdentifier("clipboard-dry-run.workflow")
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            EmptyView()
        case .loading(let requestID) where requestID == activeRequestID:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(UIStrings.clipboardItemDryRunCopy(.loading, language: model.language))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("clipboard-dry-run.loading")
        case .loaded(let requestID, let prepared) where requestID == activeRequestID:
            sections(
                ClipboardItemDryRunPresentation.make(
                    receipt: prepared.receipt,
                    language: model.language
                )
            )
        case .failed(let requestID, let failure) where requestID == activeRequestID:
            failureView(failure)
        default:
            failureView(.invalidReceipt)
        }
    }

    private func sections(_ presentation: ClipboardItemDryRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard(presentation)
            section(
                title: UIStrings.clipboardItemDryRunCopy(.reads, language: model.language),
                rows: presentation.reads
            )
            section(
                title: UIStrings.clipboardItemDryRunCopy(.transforms, language: model.language),
                rows: presentation.transforms
            )
            section(
                title: UIStrings.clipboardItemDryRunCopy(.effects, language: model.language),
                rows: presentation.effects
            )
            section(
                title: UIStrings.clipboardItemDryRunCopy(.destinations, language: model.language),
                rows: presentation.destinations
            )
            section(
                title: UIStrings.clipboardItemDryRunCopy(.replacement, language: model.language),
                rows: presentation.replacement
            )
            section(
                title: UIStrings.clipboardItemDryRunCopy(.privacyConditions, language: model.language),
                rows: presentation.privacyConditions
            )
            section(
                title: UIStrings.clipboardItemDryRunCopy(.issues, language: model.language),
                rows: presentation.issues
            )
        }
    }

    private func statusCard(_ presentation: ClipboardItemDryRunPresentation) -> some View {
        let style = statusStyle(presentation.status)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon.rawValue)
                .font(.title3)
                .foregroundStyle(style.color)
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.statusTitle).font(.headline)
                Text(presentation.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clipboard-dry-run.status")
    }

    private func section(
        title: String,
        rows: [ClipboardItemDryRunPresentationRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(UIStrings.clipboardItemDryRunCopy(.none, language: model.language))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(.callout.weight(.medium))
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureView(_ failure: ClipboardItemDryRunFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(failureText(failure), systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
            Button(UIStrings.clipboardItemDryRunCopy(.retry, language: model.language)) {
                refresh(clearResult: true)
            }
            .disabled(failure == .itemUnavailable || failure == .workflowUnavailable)
        }
        .padding(.vertical, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard-dry-run.failure")
    }

    private var currentItem: ClipboardHistoryItem? {
        model.clipboardItems.first(where: { $0.id == request.itemID })
    }

    private var eligibleWorkflows: [WorkflowDefinition] {
        model.workflows.filter {
            model.isWorkflowEnabled($0) && WorkflowExecutionPolicy.issue(for: $0) == nil
        }
    }

    private var eligibleWorkflowIDs: [UUID] {
        eligibleWorkflows.map(\.id)
    }

    private var selectedWorkflow: WorkflowDefinition? {
        guard operation != .use, let workflowID else { return nil }
        return eligibleWorkflows.first(where: { $0.id == workflowID })
    }

    private var availableOperations: [ClipboardItemDryRunOperation] {
        guard currentItem?.contentKind == .text else { return [.use] }
        return [.use, .replay, .replace]
    }

    private var isLoading: Bool {
        guard case .loading(let requestID) = loadState else { return false }
        return requestID == activeRequestID
    }

    @MainActor
    private func submitCurrentRequest() async {
        guard acceptedRequestID == activeRequestID else { return }
        guard scenePhase == .active else {
            loadState = .idle
            return
        }
        guard let item = currentItem else {
            loadState = .failed(requestID: activeRequestID, .itemUnavailable)
            return
        }
        let workflow = selectedWorkflow
        let request = ClipboardItemDryRunLoadRequest(
            id: activeRequestID,
            itemID: item.id,
            expectedItemVersion: item.version,
            operation: operation,
            workflowID: workflow?.id
        )
        loadState = .loading(requestID: request.id)
        let preview = model.previewClipboardItemAction
        await loadCoordinator.submit(
            request,
            load: {
                try await preview(request.itemID, request.operation, workflow)
            },
            deliver: { outcome in
                apply(outcome, request: request, workflow: workflow)
            }
        )
    }

    @MainActor
    private func apply(
        _ outcome: ClipboardItemDryRunLoadOutcome,
        request: ClipboardItemDryRunLoadRequest,
        workflow: WorkflowDefinition?
    ) {
        guard acceptedRequestID == request.id,
              activeRequestID == request.id else { return }
        guard let item = currentItem else {
            loadState = .failed(requestID: request.id, .itemUnavailable)
            return
        }
        guard item.version == request.expectedItemVersion else {
            loadState = .failed(requestID: request.id, .itemChanged)
            return
        }
        if let workflow {
            guard eligibleWorkflows.contains(workflow) else {
                loadState = .failed(requestID: request.id, .workflowUnavailable)
                return
            }
        }

        switch outcome {
        case .loaded(let requestID, let prepared):
            guard requestID == request.id,
                  ClipboardItemDryRunCorrelation.validates(
                      prepared,
                      request: request,
                      currentItem: item
                  ) else {
                loadState = .failed(requestID: request.id, .invalidReceipt)
                return
            }
            loadState = .loaded(requestID: request.id, prepared)
        case .failed(let requestID, let failure):
            guard requestID == request.id else { return }
            loadState = .failed(requestID: request.id, failure)
        }
    }

    private func ensureWorkflowSelection() {
        guard operation != .use else { return }
        if let workflowID, eligibleWorkflowIDs.contains(workflowID) { return }
        workflowID = eligibleWorkflowIDs.first
    }

    private func normalizeOperationForCurrentItem() {
        guard availableOperations.contains(operation) else {
            operation = .use
            return
        }
    }

    private func refresh(clearResult: Bool) {
        guard scenePhase == .active else {
            cancelLoading()
            return
        }
        let nextRequestID = UUID()
        acceptedRequestID = nextRequestID
        activeRequestID = nextRequestID
        if clearResult {
            loadState = .idle
        } else {
            loadState = .loading(requestID: nextRequestID)
        }
    }

    private func cancelLoading() {
        let cancellingRequestID = acceptedRequestID
        acceptedRequestID = nil
        loadState = .idle
        if let cancellingRequestID {
            Task {
                await loadCoordinator.cancel(requestID: cancellingRequestID)
            }
        }
    }

    private func failureText(_ failure: ClipboardItemDryRunFailure) -> String {
        let copy: ClipboardItemDryRunCopy = switch failure {
        case .itemUnavailable: .itemUnavailable
        case .itemChanged: .itemChanged
        case .workflowUnavailable: .workflowUnavailable
        case .providerUnavailable: .providerUnavailable
        case .invalidReceipt: .invalidReceipt
        }
        return UIStrings.clipboardItemDryRunCopy(copy, language: model.language)
    }

    private func statusStyle(
        _ status: ClipboardItemDryRunStatus
    ) -> (icon: RillSystemSymbol, color: Color) {
        switch status {
        case .ready: (.checkmarkShield, .green)
        case .requiresConfirmation: (.questionmarkBubble, .orange)
        case .blocked: (.xmarkShield, .red)
        case .skipped: (.forwardEnd, .secondary)
        }
    }
}
