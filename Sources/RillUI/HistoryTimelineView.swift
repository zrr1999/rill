import SwiftUI
import RillCore

enum HistoryPreviewPresentation: Equatable {
    static let restrictedCharacterLimit = RunHistoryContentAccess.restrictedPreviewCharacterLimit

    case visible(text: String, lineLimit: Int?)
    case hidden(message: String)

    init?(
        text: String?,
        mode: PrivacyHistoryPreviewMode,
        language: AppLanguage
    ) {
        guard let text else {
            return nil
        }

        switch mode {
        case .full:
            self = .visible(text: text, lineLimit: nil)
        case .restricted:
            self = .visible(
                text: RecordTextFormatting.previewText(
                    text,
                    limit: Self.restrictedCharacterLimit
                ),
                lineLimit: 3
            )
        case .disabled:
            self = .hidden(
                message: L10n.privacyText(
                    PrivacySettingsTextKey.historyPreviewHidden,
                    language: language
                )
            )
        }
    }
}

enum HistoryLanguageModelInputProvenance: Equatable {
    case exact
    case legacyRecognition
}

struct HistoryLanguageModelTracePresentation: Equatable {
    let inputTexts: [String]
    let inputProvenance: HistoryLanguageModelInputProvenance
    let outputText: String?
    let traces: [LanguageModelTrace]

    init?(record: WorkflowResultRecord) {
        guard let source = record.correctionSource else { return nil }
        let exactTraces = source.languageModelTraces ?? []
        if !exactTraces.isEmpty {
            traces = exactTraces
            inputTexts = exactTraces.flatMap { trace in
                trace.messages.map(\.content)
            }
            inputProvenance = .exact
            outputText = exactTraces.last?.responseText
            return
        }
        let exactInputs = source.languageModelInputTexts?
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? []
        if !exactInputs.isEmpty {
            traces = []
            inputTexts = exactInputs
            inputProvenance = .exact
            outputText = record.finalText
            return
        }
        guard record.trigger == .wakeWord || record.workflow.titleKey == .voiceAssistant else {
            return nil
        }
        let legacyInput = source.preMappingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyInput.isEmpty else { return nil }
        traces = []
        inputTexts = [legacyInput]
        inputProvenance = .legacyRecognition
        outputText = record.finalText
    }
}

struct HistoryPreviewContent<VisibleContent: View>: View {
    private let presentation: HistoryPreviewPresentation?
    private let visibleContent: (String, Int?) -> VisibleContent

    init(
        text: String?,
        mode: PrivacyHistoryPreviewMode,
        language: AppLanguage,
        @ViewBuilder visibleContent: @escaping (String, Int?) -> VisibleContent
    ) {
        presentation = HistoryPreviewPresentation(
            text: text,
            mode: mode,
            language: language
        )
        self.visibleContent = visibleContent
    }

    @ViewBuilder
    var body: some View {
        if let presentation {
            switch presentation {
            case .visible(let text, let lineLimit):
                visibleContent(text, lineLimit)
            case .hidden(let message):
                Label(message, systemImage: RillSystemSymbol.eyeSlash.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

public enum RunHistoryScope: String, CaseIterable, Identifiable, Sendable {
    case recentRuns
    case recentResults

    public var id: String { rawValue }
}

enum HistoryViewFocusTarget: Hashable {
    case scopeSummary
    case initialLoadRetry
    case entry(UUID)
}

enum HistoryLoadFailureAction: Sendable, Equatable {
    case retry
    case viewStorageSettings
}

struct HistoryLoadFailurePresentation: Sendable, Equatable {
    let title: String
    let message: String
    let actionTitle: String
    let action: HistoryLoadFailureAction

    static func make(
        persistenceStatus: LocalPersistenceStatus,
        language: AppLanguage
    ) -> HistoryLoadFailurePresentation {
        guard persistenceStatus.isSessionOnly else {
            return HistoryLoadFailurePresentation(
                title: UIStrings.text(.historyLoadFailedTitle, language: language),
                message: UIStrings.text(.historyLoadFailedDescription, language: language),
                actionTitle: UIStrings.text(.historyRetryLoad, language: language),
                action: .retry
            )
        }

        switch language {
        case .english:
            return HistoryLoadFailurePresentation(
                title: "Saved history is unavailable",
                message:
                    "Rill is running session-only, so reopening saved history cannot "
                    + "succeed until persistent storage is available.",
                actionTitle: "View Storage Settings",
                action: .viewStorageSettings
            )
        case .simplifiedChinese:
            return HistoryLoadFailurePresentation(
                title: "已保存的历史记录不可用",
                message:
                    "Rill 当前仅在本次会话中运行；在持久化存储恢复前，"
                    + "重新加载已保存历史不会成功。",
                actionTitle: "查看存储设置",
                action: .viewStorageSettings
            )
        }
    }
}

struct HistoryInitialLoadRetryFocusTransition: Equatable {
    let keyboardFocus: HistoryViewFocusTarget?
    let accessibilityFocus: HistoryViewFocusTarget?
}

enum HistoryInitialLoadRetryFocusPolicy {
    static func transition(
        keyboardFocus: HistoryViewFocusTarget?,
        accessibilityFocus: HistoryViewFocusTarget?
    ) -> HistoryInitialLoadRetryFocusTransition {
        HistoryInitialLoadRetryFocusTransition(
            keyboardFocus: keyboardFocus == .initialLoadRetry ? nil : keyboardFocus,
            accessibilityFocus:
                accessibilityFocus == .initialLoadRetry ? .scopeSummary : accessibilityFocus
        )
    }
}

private struct HistoryNavigationTaskIdentity: Hashable {
    let requestID: UUID?
    let visibleEntryIDs: [UUID]
    let loadState: HistoryLoadState
    let deepLinkState: RunHistoryDeepLinkState
}

/// Receipt-first run timeline, embedded in `StreamView`. The host owns the
/// ScrollView/ScrollViewReader so readiness, live activity and the durable
/// timeline share one scroll position; deep links still scroll and focus the
/// exact entry through the injected proxy.
public struct HistoryTimelineView: View {
    @Bindable private var model: AppModel
    private let proxy: ScrollViewProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var correctionRecord: WorkflowResultRecord?
    @State private var pendingFailedAudioDeletion: FailedAudioRecoveryReceipt?
    @FocusState private var focusedTarget: HistoryViewFocusTarget?
    @AccessibilityFocusState private var accessibilityFocusedTarget: HistoryViewFocusTarget?

    public init(model: AppModel, proxy: ScrollViewProxy) {
        self.model = model
        self.proxy = proxy
    }

    public var body: some View {
        let visibleEntries = entries
        let workflowsByID = Dictionary(
            model.workflows.map { ($0.id, $0.presentation) },
            uniquingKeysWith: { first, _ in first }
        )
        let viewState = HistoryViewState(
            loadState: model.effectiveRunHistoryLoadState,
            hasEntries: !visibleEntries.isEmpty
        )

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UIStrings.text(.historyScopeAll, language: model.language))
                        .font(.headline)
                    Text(UIStrings.text(.historyDescription, language: model.language))
                }
                Spacer(minLength: 12)
                if case .loaded = model.effectiveRunHistoryLoadState {
                    Text(
                        UIStrings.loadedRunCount(
                            visibleEntries.count,
                            language: model.language
                        )
                    )
                    .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityFocused(
                $accessibilityFocusedTarget,
                equals: .scopeSummary
            )

            if let error = model.failedAudioRecoveryError {
                Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if case .expired = model.runHistoryDeepLinkState {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            UIStrings.text(
                                .historyEntryExpiredTitle,
                                language: model.language
                            )
                        )
                        .font(.headline)
                        Text(
                            UIStrings.text(
                                .historyEntryExpiredDescription,
                                language: model.language
                            )
                        )
                        .font(.callout)
                    }
                } icon: {
                    Image(systemName: RillSystemSymbol.clockBadgeExclamationmark.rawValue)
                }
                .foregroundStyle(.orange)
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("history.deep-link.expired")
            }

            if model.runHistoryPaginationFailed {
                HStack(spacing: 10) {
                    Label(
                        UIStrings.text(.historyPaginationFailed, language: model.language),
                        systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    Spacer()
                    if model.localPersistenceStatus.isSessionOnly {
                        Button(
                            LocalPersistenceStatusPresentation.make(
                                status: model.localPersistenceStatus,
                                language: model.language
                            )?.actionTitle
                                ?? SettingsSection.storage.title(language: model.language)
                        ) {
                            model.showSettings(.storage)
                        }
                        .accessibilityIdentifier(
                            "history.pagination.open-storage-settings"
                        )
                    } else if case .failed = model.runHistoryDeepLinkState {
                        Button(
                            UIStrings.text(.historyRetryLoad, language: model.language)
                        ) {
                            model.retryRunHistoryDeepLink()
                        }
                        .accessibilityIdentifier("history.deep-link.retry")
                    }
                }
                .accessibilityIdentifier("history.pagination.error")
            }
            Group {
                switch viewState {
                case .loading:
                    loadingState
                        .transition(.opacity)
                case .failed:
                    loadFailureState
                        .transition(.opacity)
                case .loaded(isEmpty: true):
                    VStack(alignment: .leading, spacing: 16) {
                        emptyState
                        if model.usesPagedRunHistory,
                           model.canLoadNewerRunHistoryPage {
                            paginationControls
                        }
                    }
                    .transition(.opacity)
                case .loaded(isEmpty: false):
                    VStack(alignment: .leading, spacing: 16) {
                        recordList(
                            entries: visibleEntries,
                            workflowsByID: workflowsByID
                        )
                        if model.usesPagedRunHistory {
                            paginationControls
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0),
                value: viewState
            )
        }
        .task(
            id: HistoryNavigationTaskIdentity(
                requestID: model.historyNavigationRequest?.id,
                visibleEntryIDs: visibleEntries.map(\.id),
                loadState: model.effectiveRunHistoryLoadState,
                deepLinkState: model.runHistoryDeepLinkState
            )
        ) {
            await model.resolveRunHistoryDeepLinkIfNeeded()
            guard case .loaded = model.effectiveRunHistoryLoadState,
                  let request = model.historyNavigationRequest,
                  request.scope == model.runHistoryScope,
                  let visibleEntryID = model.visibleRunHistoryEntryID(
                    matching: request.entryID
                  ),
                  visibleEntries.contains(where: { $0.id == visibleEntryID }) else {
                return
            }
            await Task.yield()
            guard model.historyNavigationRequest?.id == request.id else { return }
            // Navigation scroll, not decorative motion: keep the fixed
            // duration easing so entry positioning stays predictable.
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(visibleEntryID, anchor: .center)
            }
            await Task.yield()
            guard model.historyNavigationRequest?.id == request.id else { return }
            focusedTarget = .entry(visibleEntryID)
            accessibilityFocusedTarget = .entry(visibleEntryID)
        }
        .sheet(item: $correctionRecord) { record in
            if let source = record.correctionSource {
                VocabularyCorrectionSheet(model: model, source: source)
            }
        }
        .confirmationDialog(
            L10n.string(
                .historyFailedAudioDeleteConfirmation,
                language: model.language
            ),
            isPresented: Binding(
                get: { pendingFailedAudioDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingFailedAudioDeletion = nil
                    }
                }
            ),
            presenting: pendingFailedAudioDeletion
        ) { receipt in
            Button(
                L10n.string(.historyFailedAudioDelete, language: model.language),
                role: .destructive
            ) {
                pendingFailedAudioDeletion = nil
                model.deleteFailedAudioRecovery(receipt)
            }
            Button(
                L10n.historySettingsText(.cancel, language: model.language),
                role: .cancel
            ) {
                pendingFailedAudioDeletion = nil
            }
        } message: { _ in
            Text(
                L10n.string(
                    .historyFailedAudioDeleteConfirmationDetail,
                    language: model.language
                )
            )
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(UIStrings.text(.historyLoading, language: model.language))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.loading")
    }

    private var loadFailureState: some View {
        let presentation = HistoryLoadFailurePresentation.make(
            persistenceStatus: model.localPersistenceStatus,
            language: model.language
        )
        return VStack(spacing: 12) {
            Image(systemName: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.title3.weight(.semibold))
            Text(presentation.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                performLoadFailureAction(presentation.action)
            } label: {
                Label(
                    presentation.actionTitle,
                    systemImage: presentation.action == .retry
                        ? RillSystemSymbol.arrowClockwise.rawValue
                        : SettingsSection.storage.symbolName
                )
            }
            .buttonStyle(.borderedProminent)
            .focused($focusedTarget, equals: .initialLoadRetry)
            .accessibilityFocused(
                $accessibilityFocusedTarget,
                equals: .initialLoadRetry
            )
            .accessibilityIdentifier(
                presentation.action == .retry
                    ? "history.error.retry"
                    : "history.error.open-storage-settings"
            )
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.error")
    }

    private var paginationControls: some View {
        HStack(spacing: 12) {
            Button {
                model.loadNewerRunHistoryPage()
            } label: {
                Label(
                    UIStrings.text(.historyNewerPage, language: model.language),
                    systemImage: RillSystemSymbol.chevronLeft.rawValue
                )
            }
            .disabled(
                !model.canLoadNewerRunHistoryPage
                    || model.isRunHistoryPageTransitioning
            )
            .accessibilityIdentifier("history.pagination.newer")

            if model.isRunHistoryPageTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("history.pagination.loading")
            }

            Spacer()

            Button {
                model.loadOlderRunHistoryPage()
            } label: {
                Label(
                    UIStrings.text(.historyOlderPage, language: model.language),
                    systemImage: RillSystemSymbol.chevronRight.rawValue
                )
                .labelStyle(.titleAndIcon)
            }
            .disabled(
                !model.canLoadOlderRunHistoryPage
                    || model.isRunHistoryPageTransitioning
            )
            .accessibilityIdentifier("history.pagination.older")
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.pagination")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: RillSystemSymbol.clockArrowCirclepath.rawValue)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(
                UIStrings.text(
                    model.usesPagedRunHistory && model.canLoadNewerRunHistoryPage
                        ? .historyPageEmpty
                        : emptyKey,
                    language: model.language
                )
            )
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func recordList(
        entries: [HistoryTimelineEntry],
        workflowsByID: [UUID: WorkflowPresentation]
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { entry in
                let title = entryTitle(entry, workflowsByID: workflowsByID)
                historyRow(entry, title: title)
                    .id(entry.id)
                    .focusable()
                    .focused($focusedTarget, equals: .entry(entry.id))
                    .accessibilityFocused(
                        $accessibilityFocusedTarget,
                        equals: .entry(entry.id)
                    )
                    .accessibilityIdentifier("history.entry.\(entry.id.uuidString)")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0),
            value: entries.map(\.id)
        )
    }

    private func performLoadFailureAction(_ action: HistoryLoadFailureAction) {
        guard action == .retry else {
            model.showSettings(.storage)
            return
        }
        let transition = HistoryInitialLoadRetryFocusPolicy.transition(
            keyboardFocus: focusedTarget,
            accessibilityFocus: accessibilityFocusedTarget
        )
        // The failure button leaves the hierarchy synchronously when retry
        // enters loading. Move only focus that the button actually owns onto
        // the stable scope picker; mouse activation must preserve any other
        // first responder or VoiceOver position.
        focusedTarget = transition.keyboardFocus
        accessibilityFocusedTarget = transition.accessibilityFocus
        model.retryRunHistoryInitialLoad()
    }

    private func historyRow(_ entry: HistoryTimelineEntry, title: String) -> some View {
        let languageModelTrace = entry.record.flatMap {
            HistoryLanguageModelTracePresentation(record: $0)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entry.status.systemSymbol.rawValue)
                    .foregroundStyle(statusColor(entry.status))

                Text(title)
                    .font(.headline)

                if entry.isRecordRelated || entry.receipt?.trigger == .recordDelivery {
                    Label(
                        UIStrings.text(.historyStackBadge, language: model.language),
                        systemImage: RillSystemSymbol.squareStack3dUp.rawValue
                    )
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(historyAccessibilityLabel(entry, title: title))
            .accessibilityValue(Text(entry.timestamp, style: .relative))

            if let languageModelTrace {
                languageModelTracePreview(languageModelTrace)
            } else {
                historyPreview(
                    entry.record?.finalText,
                    hasProtectedPreview: entry.hasProtectedPreview
                )
            }

            if let record = entry.record {
                if VocabularyCorrectionDraft.isEligible(
                    record: record,
                    privacyPreviewMode: model.privacyPolicySettings.historyPreviewMode
                ) {
                    Button {
                        correctionRecord = record
                    } label: {
                        Label(
                            L10n.string(.vocabularyCorrectionAction, language: model.language),
                            systemImage: RillSystemSymbol.textBadgeCheckmark.rawValue
                        )
                    }
                    .buttonStyle(.borderless)
                }

                if let failure = record.failureMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Label(
                            RunFailurePresentation.text(
                                for: failure,
                                language: model.language
                            ),
                            systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                        )
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            model.selectSidebarSection(.diagnostics)
                        } label: {
                            Label(
                                UIStrings.text(.sidebarDiagnostics, language: model.language),
                                systemImage: SidebarSection.diagnostics.symbolName
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button(UIStrings.text(.copy, language: model.language)) {
                            model.copyHistoryFailure(record)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            if let receipt = entry.receipt {
                runReceiptDetails(receipt)
            } else if entry.runID != nil {
                Label(
                    L10n.historyTimelineText(
                        .executionDetailsUnavailable,
                        language: model.language
                    ),
                    systemImage: RillSystemSymbol.infoCircle.rawValue
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let runID = entry.runID,
               let reason = model.failedAudioRecoveryUnavailableReasonsByRunID[runID] {
                Label(
                    model.failedAudioRecoveryUnavailableMessage(reason),
                    systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if model.failedAudioRecoveryEnabled,
               let receipt = model.failedAudioRecoveryReceipt(for: entry.runID) {
                failedAudioRecoveryControls(receipt)
            }
        }
        .rillCard(.regular, padding: 14)
        .accessibilityElement(children: .contain)
    }

    private func failedAudioRecoveryControls(
        _ receipt: FailedAudioRecoveryReceipt
    ) -> some View {
        let isRetrying = model.retryingFailedAudioRecoveryIDs.contains(receipt.id)
        let anotherRetryIsRunning = !model.retryingFailedAudioRecoveryIDs.isEmpty
            && !isRetrying
        let workflowIsAvailable = model.workflows.contains { $0.id == receipt.workflowID }
        return VStack(alignment: .leading, spacing: 6) {
            if !receipt.status.canRetry {
                Label(
                    L10n.string(
                        .historyFailedAudioOutcomeUnknown,
                        language: model.language
                    ),
                    systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if receipt.status.canRetry {
                    Button {
                        model.retryFailedAudioRecovery(receipt)
                    } label: {
                        if isRetrying {
                            Label(
                                L10n.string(
                                    .historyFailedAudioRetrying,
                                    language: model.language
                                ),
                                systemImage: RillSystemSymbol.arrowTriangle2Circlepath.rawValue
                            )
                        } else {
                            Label(
                                L10n.string(
                                    .historyFailedAudioRetry,
                                    language: model.language
                                ),
                                systemImage: RillSystemSymbol.arrowClockwiseCircle.rawValue
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isRetrying
                            || anotherRetryIsRunning
                            || model.isUpdatingFailedAudioRecovery
                            || !workflowIsAvailable
                    )
                }

                Button(
                    L10n.string(
                        .historyFailedAudioDelete,
                        language: model.language
                    ),
                    role: .destructive
                ) {
                    pendingFailedAudioDeletion = receipt
                }
                .buttonStyle(.borderless)
                .disabled(isRetrying || model.isUpdatingFailedAudioRecovery)
            }

            HStack(spacing: 4) {
                Text(
                    L10n.string(
                        .historyFailedAudioExpires,
                        language: model.language
                    )
                )
                Text(receipt.expiresAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func runReceiptDetails(_ receipt: WorkflowRunReceipt) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Label(
                    L10n.historyRunTrigger(receipt.trigger, language: model.language),
                    systemImage: RillSystemSymbol.boltHorizontalCircle.rawValue
                )
                Text("·")
                    .accessibilityHidden(true)
                Text(localizedTermination(receipt.termination))
                Text("·")
                    .accessibilityHidden(true)
                Text(L10n.historyRunDurationBucket(receipt.duration, language: model.language))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            ForEach(receipt.actionDetails, id: \.actionIndex) { action in
                HStack(spacing: 6) {
                    Text(L10n.historyTimelineAction(action.actionIndex + 1, language: model.language))
                    Text("·")
                        .accessibilityHidden(true)
                    Text(localizedActionResult(action.result))
                    Text("·")
                        .accessibilityHidden(true)
                    Text(L10n.historyRunDurationBucket(action.duration, language: model.language))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if receipt.detailsTruncated {
                Label(
                    L10n.historyTimelineText(
                        .actionDetailsTruncated,
                        language: model.language
                    ),
                    systemImage: RillSystemSymbol.ellipsisCircle.rawValue
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func localizedTermination(_ termination: WorkflowRunTermination) -> String {
        L10n.workflowRunTermination(termination, language: model.language)
    }

    private func localizedActionResult(_ result: WorkflowActionResultCode) -> String {
        L10n.workflowActionResult(result, language: model.language)
    }

    @ViewBuilder
    private func languageModelTracePreview(
        _ trace: HistoryLanguageModelTracePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if trace.traces.isEmpty {
                ForEach(Array(trace.inputTexts.enumerated()), id: \.offset) { index, text in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(languageModelInputLabel(trace, index: index))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        historyPreview(text, hasProtectedPreview: false)
                    }
                }
                if let outputText = trace.outputText {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.historyTimelineText(.llmAnswer, language: model.language))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        historyPreview(outputText, hasProtectedPreview: false)
                    }
                }
            } else {
                ForEach(Array(trace.traces.enumerated()), id: \.offset) { index, item in
                    languageModelTraceStep(item, index: index, count: trace.traces.count)
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.llm-trace")
    }

    @ViewBuilder
    private func languageModelTraceStep(
        _ trace: LanguageModelTrace,
        index: Int,
        count: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(
                count > 1
                    ? L10n.historyTimelineLLMRequestStep(index + 1, language: model.language)
                    : L10n.historyTimelineText(.llmRequest, language: model.language)
            )
            .font(.callout.weight(.semibold))

            LabeledContent(L10n.historyTimelineText(.provider, language: model.language)) {
                Text(trace.providerID).textSelection(.enabled)
            }
            LabeledContent(L10n.historyTimelineText(.model, language: model.language)) {
                Text(trace.modelID).textSelection(.enabled)
            }

            languageModelTraceText(
                L10n.historyTimelineText(.systemPrompt, language: model.language),
                text: trace.systemPrompt
            )
            languageModelTraceText(
                L10n.historyTimelineText(.workflowPrompt, language: model.language),
                text: trace.workflowPrompt
            )
            ForEach(Array(trace.messages.enumerated()), id: \.offset) { messageIndex, message in
                languageModelTraceText(
                    L10n.historyTimelineSentMessage(
                        role: message.role.rawValue,
                        number: messageIndex + 1,
                        language: model.language
                    ),
                    text: message.content
                )
            }
            languageModelTraceText(
                L10n.historyTimelineText(.returnedText, language: model.language),
                text: trace.responseText
            )
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func languageModelTraceText(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            historyPreview(text, hasProtectedPreview: false)
        }
    }

    private func languageModelInputLabel(
        _ trace: HistoryLanguageModelTracePresentation,
        index: Int
    ) -> String {
        if trace.inputProvenance == .legacyRecognition {
            return L10n.historyTimelineText(.recognizedInputLegacy, language: model.language)
        }
        guard trace.inputTexts.count > 1 else {
            return L10n.historyTimelineText(.sentToLLM, language: model.language)
        }
        return L10n.historyTimelineSentToLLMStep(index + 1, language: model.language)
    }

    @ViewBuilder
    private func historyPreview(
        _ text: String?,
        hasProtectedPreview: Bool
    ) -> some View {
        if hasProtectedPreview,
           model.privacyPolicySettings.historyPreviewMode == .disabled {
            Label(
                L10n.privacyText(
                    PrivacySettingsTextKey.historyPreviewHidden,
                    language: model.language
                ),
                systemImage: RillSystemSymbol.eyeSlash.rawValue
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            HistoryPreviewContent(
                text: text,
                mode: model.privacyPolicySettings.historyPreviewMode,
                language: model.language
            ) { text, lineLimit in
                Text(text)
                    .font(.body)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
            }
        }
    }

    private func entryTitle(
        _ entry: HistoryTimelineEntry,
        workflowsByID: [UUID: WorkflowPresentation]
    ) -> String {
        if let record = entry.record {
            return UIStrings.workflowName(record.workflow, language: model.language)
        }
        if let workflowID = entry.workflowID,
           let workflow = workflowsByID[workflowID] {
            return UIStrings.workflowName(workflow, language: model.language)
        }
        if let trigger = entry.receipt?.trigger {
            return L10n.historyRunTrigger(trigger, language: model.language)
        }
        return L10n.historyTimelineText(.workflowRunFallback, language: model.language)
    }

    private func statusColor(_ status: HistoryTimelineStatus) -> Color {
        switch status {
        case .completed: .green
        case .partiallyCompleted: .orange
        case .failed: .red
        case .cancelled, .skipped: .secondary
        }
    }

    private func historyAccessibilityLabel(
        _ entry: HistoryTimelineEntry,
        title: String
    ) -> String {
        L10n.historyRunAccessibilityLabel(
            status: L10n.historyRunStatus(entry.status, language: model.language),
            title: title,
            termination: entry.receipt?.termination,
            language: model.language
        )
    }

    private var entries: [HistoryTimelineEntry] {
        model.displayedRunHistoryEntries
    }

    private var emptyKey: UIStrings.Key { .historyEmpty }
}
