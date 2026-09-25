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
    case transcriptOnly
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
            inputProvenance = source.references == nil ? .exact : .transcriptOnly
            outputText = exactTraces.last?.responseText
            return
        }
        let exactInputs = source.languageModelInputTexts?
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? []
        if !exactInputs.isEmpty {
            traces = []
            inputTexts = exactInputs
            inputProvenance = source.references == nil ? .exact : .transcriptOnly
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
                title: L10n.text(.historyLoadFailedTitle, language: language),
                message: L10n.text(.historyLoadFailedDescription, language: language),
                actionTitle: L10n.text(.historyRetryLoad, language: language),
                action: .retry
            )
        }

        return HistoryLoadFailurePresentation(
            title: L10n.text(.historyLoadSessionOnlyTitle, language: language),
            message: L10n.text(.historyLoadSessionOnlyDescription, language: language),
            actionTitle: L10n.text(.historyLoadSessionOnlyViewStorage, language: language),
            action: .viewStorageSettings
        )
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
    @State private var expandedEntryIDs: Set<UUID> = []
    @State private var expandedEntryID: UUID?
    @State private var correctionRecord: WorkflowResultRecord?
    @State private var pendingFailedAudioDeletion: FailedAudioRecoveryReceipt?
    @FocusState private var focusedTarget: HistoryViewFocusTarget?
    @AccessibilityFocusState private var accessibilityFocusedTarget: HistoryViewFocusTarget?

    /// Shared minimum height for the loading/failure/empty placeholders so
    /// state switches do not resize the timeline.
    private static let stateMinHeight: CGFloat = 240

    public init(model: AppModel, proxy: ScrollViewProxy) {
        self.init(model: model, proxy: proxy, expandedEntryID: nil)
    }

    init(model: AppModel, proxy: ScrollViewProxy, expandedEntryID: UUID?) {
        self.model = model
        self.proxy = proxy
        _expandedEntryIDs = State(initialValue: expandedEntryID.map { [$0] } ?? [])
        _expandedEntryID = State(initialValue: expandedEntryID)
    }

    public var body: some View {
        let visibleEntries = entries
        let workflowsByID = Dictionary(
            model.workflowLibrary.workflows.map { ($0.id, $0.presentation) },
            uniquingKeysWith: { first, _ in first }
        )
        let viewState = HistoryViewState(
            loadState: model.history.effectiveRunHistoryLoadState,
            hasEntries: !visibleEntries.isEmpty
        )

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(.historyScopeAll, language: model.settings.language))
                        .font(.headline)
                    Text(L10n.text(.historyDescription, language: model.settings.language))
                }
                Spacer(minLength: 12)
                if case .loaded = model.history.effectiveRunHistoryLoadState {
                    Text(
                        L10n.loadedRunCount(
                            visibleEntries.count,
                            language: model.settings.language
                        )
                    )
                    .font(.caption)
                    .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityFocused(
                $accessibilityFocusedTarget,
                equals: .scopeSummary
            )

            if let error = model.voice.failedAudioRecoveryError {
                Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if case .expired = model.history.runHistoryDeepLinkState {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            L10n.text(
                                .historyEntryExpiredTitle,
                                language: model.settings.language
                            )
                        )
                        .font(.headline)
                        Text(
                            L10n.text(
                                .historyEntryExpiredDescription,
                                language: model.settings.language
                            )
                        )
                        .font(.callout)
                    }
                } icon: {
                    Image(systemName: RillSystemSymbol.clockBadgeExclamationmark.rawValue)
                }
                .foregroundStyle(.orange)
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: RillRadius.section))
                .accessibilityIdentifier("history.deep-link.expired")
            }

            if model.history.runHistoryPaginationFailed {
                HStack(spacing: 10) {
                    Label(
                        L10n.text(.historyPaginationFailed, language: model.settings.language),
                        systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    Spacer()
                    if model.localPersistenceStatus.isSessionOnly {
                        Button(
                            LocalPersistenceStatusPresentation.make(
                                status: model.localPersistenceStatus,
                                language: model.settings.language
                            )?.actionTitle
                                ?? SettingsSection.storage.title(language: model.settings.language)
                        ) {
                            model.showSettings(.storage)
                        }
                        .accessibilityIdentifier(
                            "history.pagination.open-storage-settings"
                        )
                    } else if case .failed = model.history.runHistoryDeepLinkState {
                        Button(
                            L10n.text(.historyRetryLoad, language: model.settings.language)
                        ) {
                            model.history.retryRunHistoryDeepLink()
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
                        if model.history.usesPagedRunHistory,
                           model.history.canLoadNewerRunHistoryPage {
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
                        if model.history.usesPagedRunHistory {
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
                requestID: model.history.historyNavigationRequest?.id,
                visibleEntryIDs: visibleEntries.map(\.id),
                loadState: model.history.effectiveRunHistoryLoadState,
                deepLinkState: model.history.runHistoryDeepLinkState
            )
        ) {
            await model.history.resolveRunHistoryDeepLinkIfNeeded()
            guard case .loaded = model.history.effectiveRunHistoryLoadState,
                  let request = model.history.historyNavigationRequest,
                  request.scope == model.history.runHistoryScope,
                  let visibleEntryID = model.history.visibleRunHistoryEntryID(
                    matching: request.entryID
                  ),
                  visibleEntries.contains(where: { $0.id == visibleEntryID }) else {
                return
            }
            await Task.yield()
            guard model.history.historyNavigationRequest?.id == request.id else { return }
            // Navigation scroll, not decorative motion: keep the fixed
            // duration easing so entry positioning stays predictable.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                proxy.scrollTo(visibleEntryID, anchor: .center)
            }
            await Task.yield()
            guard model.history.historyNavigationRequest?.id == request.id else { return }
            expandedEntryID = visibleEntryID
            focusedTarget = .entry(visibleEntryID)
            accessibilityFocusedTarget = .entry(visibleEntryID)
        }
        .sheet(item: $correctionRecord) { record in
            if let source = record.correctionSource {
                VocabularyCorrectionSheet(model: model, source: source, historyRecordID: record.id, workflowRunID: record.runID)
            }
        }
        .confirmationDialog(
            L10n.string(
                .historyFailedAudioDeleteConfirmation,
                language: model.settings.language
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
                L10n.string(.historyFailedAudioDelete, language: model.settings.language),
                role: .destructive
            ) {
                pendingFailedAudioDeletion = nil
                model.deleteFailedAudioRecovery(receipt)
            }
            Button(
                L10n.historySettingsText(.cancel, language: model.settings.language),
                role: .cancel
            ) {
                pendingFailedAudioDeletion = nil
            }
        } message: { _ in
            Text(
                L10n.string(
                    .historyFailedAudioDeleteConfirmationDetail,
                    language: model.settings.language
                )
            )
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.text(.historyLoading, language: model.settings.language))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: Self.stateMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.loading")
    }

    private var loadFailureState: some View {
        let presentation = HistoryLoadFailurePresentation.make(
            persistenceStatus: model.localPersistenceStatus,
            language: model.settings.language
        )
        return VStack(spacing: 12) {
            Image(systemName: RillSystemSymbol.exclamationmarkTriangleFill.rawValue)
                .font(.largeTitle)
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
        .frame(maxWidth: .infinity, minHeight: Self.stateMinHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.error")
    }

    private var paginationControls: some View {
        HStack(spacing: 12) {
            Button {
                model.history.loadNewerRunHistoryPage()
            } label: {
                Label(
                    L10n.text(.historyNewerPage, language: model.settings.language),
                    systemImage: RillSystemSymbol.chevronLeft.rawValue
                )
            }
            .disabled(
                !model.history.canLoadNewerRunHistoryPage
                    || model.history.isRunHistoryPageTransitioning
            )
            .accessibilityIdentifier("history.pagination.newer")

            if model.history.isRunHistoryPageTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("history.pagination.loading")
            }

            Spacer()

            Button {
                model.history.loadOlderRunHistoryPage()
            } label: {
                Label(
                    L10n.text(.historyOlderPage, language: model.settings.language),
                    systemImage: RillSystemSymbol.chevronRight.rawValue
                )
            }
            .disabled(
                !model.history.canLoadOlderRunHistoryPage
                    || model.history.isRunHistoryPageTransitioning
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
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(
                L10n.text(
                    model.history.usesPagedRunHistory && model.history.canLoadNewerRunHistoryPage
                        ? .historyPageEmpty
                        : emptyKey,
                    language: model.settings.language
                )
            )
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: Self.stateMinHeight)
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
                    .transition(.opacity)
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
        VStack(alignment: .leading, spacing: RillSpacing.row) {
            Button {
                expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
            } label: {
                HStack(alignment: .top, spacing: RillSpacing.row) {
                    Image(systemName: entry.status.systemSymbol.rawValue).foregroundStyle(statusColor(entry.status))
                    VStack(alignment: .leading, spacing: RillSpacing.compact) {
                        HStack(spacing: RillSpacing.row) {
                            Text(title).font(.headline)
                            if entry.isRecordRelated || entry.receipt?.trigger == .recordDelivery {
                                Label(L10n.text(.historyStackBadge, language: model.settings.language),
                                      systemImage: RillSystemSymbol.squareStack3dUp.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if expandedEntryID != entry.id,
                           case .visible(let preview, _) = HistoryPreviewPresentation(text: entry.record?.finalText, mode: model.privacyPolicySettings.historyPreviewMode, language: model.settings.language) {
                            Text(preview).lineLimit(2).font(.body).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: RillSpacing.row)
                    VStack(alignment: .trailing, spacing: RillSpacing.compact) {
                        Text(entry.timestamp, style: .relative)
                        Text(L10n.historyRunStatus(entry.status, language: model.settings.language))
                    }.font(.caption).foregroundStyle(.secondary)
                    Image(systemName: RillSystemSymbol.chevronRight.rawValue)
                        .rotationEffect(.degrees(expandedEntryID == entry.id ? 90 : 0))
                        .foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedTarget, equals: .entry(entry.id))
            .accessibilityFocused($accessibilityFocusedTarget, equals: .entry(entry.id))
            .accessibilityIdentifier("history.entry.\(entry.id.uuidString)")
            .accessibilityLabel(historyAccessibilityLabel(entry, title: title))
            .accessibilityValue(Text(entry.timestamp, style: .relative))
            .accessibilityHint(expandedEntryID == entry.id
                ? L10n.historyRunDetail(.collapseDetails, language: model.settings.language)
                : L10n.workspace(.showDetails, language: model.settings.language))
            if expandedEntryID == entry.id { historyDetail(entry) }
            Divider()
        }.padding(.vertical, RillSpacing.row)
    }

    private func historyDetail(_ entry: HistoryTimelineEntry) -> some View {
        let languageModelTrace = entry.record.flatMap {
            HistoryLanguageModelTracePresentation(record: $0)
        }
        let textSteps = entry.record?.correctionSource?.processingSteps ?? []
        return VStack(alignment: .leading, spacing: 8) {
            historyPreview(
                entry.record?.finalText,
                hasProtectedPreview: entry.hasProtectedPreview
            )
            let recovery = HistoryRecoveryPresentation(receipt: entry.receipt)
            if let message = recovery.message(language: model.settings.language) {
                Text(message).font(.callout)
                    .foregroundStyle(recovery.outputState == nil ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("history.recovery-status")
            }
            if model.privacyPolicySettings.historyPreviewMode == .full, let record = entry.record {
                HStack {
                    if let text = record.finalText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        RillCopyButton(title: L10n.recoveryCopyTitle(original: false, language: model.settings.language), language: model.settings.language) {
                            model.copyTextToClipboard(text)
                        }
                    }
                    if let original = record.correctionSource?.processingSteps?.first(where: { $0.kind == .recognizeSpeech })?.outputText
                        ?? record.correctionSource?.preMappingText,
                       !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       original != record.finalText {
                        RillCopyButton(title: L10n.recoveryCopyTitle(original: true, language: model.settings.language), language: model.settings.language) {
                            model.copyTextToClipboard(original)
                        }
                    }
                }.buttonStyle(.borderless)
            }
            if let receipt = entry.receipt, !receipt.actionDetails.isEmpty {
                Text(WorkflowActionResultCode.allCases.filter { result in
                        receipt.actionDetails.contains { $0.result == result }
                    }.map { localizedActionResult($0) }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let timings = HistoryRunTiming.items(for: entry)
            if !timings.isEmpty {
                HistoryRunTimingView(items: timings, language: model.settings.language)
            }

            if let references = entry.record?.correctionSource?.references {
                CorrectionReferenceView(receipt: references, language: model.settings.language)
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
                            L10n.string(.vocabularyCorrectionAction, language: model.settings.language),
                            systemImage: RillSystemSymbol.textBadgeCheckmark.rawValue
                        )
                    }
                    .buttonStyle(.borderless)
                }

                if let failure = record.failureMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Label(
                            RunFailurePresentation.historyText(
                                for: failure,
                                language: model.settings.language
                            ),
                            systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                        )
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            expandedEntryIDs.insert(entry.id)
                        } label: {
                            Label(
                                L10n.text(.sidebarDiagnostics, language: model.settings.language),
                                systemImage: SidebarSection.diagnostics.symbolName
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("history.diagnostics.\(entry.id.uuidString)")
                        RillCopyButton(
                            title: L10n.historyTimelineText(.copyFailureDetails, language: model.settings.language),
                            language: model.settings.language
                        ) {
                            model.copyHistoryFailure(record)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .help(
                            L10n.historyTimelineText(
                                .copyFailureDetails,
                                language: model.settings.language
                            )
                        )
                    }
                }
            }

            if entry.runID != nil || entry.record?.failureMessage != nil || languageModelTrace != nil || !textSteps.isEmpty {
                DisclosureGroup(
                    L10n.historyRunDetail(.details, language: model.settings.language),
                    isExpanded: Binding(
                        get: { expandedEntryIDs.contains(entry.id) },
                        set: { expanded in
                            if expanded { expandedEntryIDs.insert(entry.id) }
                            else { expandedEntryIDs.remove(entry.id) }
                        }
                    )
                ) {
                    if expandedEntryIDs.contains(entry.id) {
                        VStack(alignment: .leading, spacing: 12) {
                            if let receipt = entry.receipt {
                                runReceiptDetails(receipt)
                            }
                            if let runID = entry.runID {
                                HistoryRunDiagnosticsView(model: model, runID: runID)
                            } else {
                                Text(L10n.historyRunDetail(.legacyDiagnostics, language: model.settings.language))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("history.run-diagnostics.legacy")
                            }
                            if !textSteps.isEmpty {
                                DisclosureGroup(L10n.historyRunDetail(.textResults, language: model.settings.language)) {
                                    HistoryTextStepsView(
                                        steps: textSteps,
                                        previewMode: model.privacyPolicySettings.historyPreviewMode,
                                        language: model.settings.language
                                    )
                                }
                            }
                            if let languageModelTrace {
                                DisclosureGroup(L10n.historyTimelineText(.llmRequest, language: model.settings.language)) {
                                    languageModelTracePreview(languageModelTrace)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("history.details.\(entry.id.uuidString)")
            }

            if let runID = entry.runID,
               let reason = model.voice.failedAudioRecoveryUnavailableReasonsByRunID[runID] {
                Label(
                    model.failedAudioRecoveryUnavailableMessage(reason),
                    systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if model.voice.failedAudioRecoveryEnabled,
               let receipt = model.failedAudioRecoveryReceipt(for: entry.runID) {
                failedAudioRecoveryControls(receipt)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func failedAudioRecoveryControls(
        _ receipt: FailedAudioRecoveryReceipt
    ) -> some View {
        let isRetrying = model.voice.retryingFailedAudioRecoveryIDs.contains(receipt.id)
        let anotherRetryIsRunning = !model.voice.retryingFailedAudioRecoveryIDs.isEmpty
            && !isRetrying
        let workflowIsAvailable = model.workflowLibrary.workflows.contains { $0.id == receipt.workflowID }
        return VStack(alignment: .leading, spacing: 6) {
            if !receipt.status.canRetry {
                Label(
                    L10n.string(
                        .historyFailedAudioOutcomeUnknown,
                        language: model.settings.language
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
                                    language: model.settings.language
                                ),
                                systemImage: RillSystemSymbol.arrowTriangle2Circlepath.rawValue
                            )
                        } else {
                            Label(
                                L10n.string(
                                    .historyFailedAudioRetry,
                                    language: model.settings.language
                                ),
                                systemImage: RillSystemSymbol.arrowClockwiseCircle.rawValue
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isRetrying
                            || anotherRetryIsRunning
                            || model.voice.isUpdatingFailedAudioRecovery
                            || !workflowIsAvailable
                    )
                }

                Button(
                    L10n.string(
                        .historyFailedAudioDelete,
                        language: model.settings.language
                    ),
                    role: .destructive
                ) {
                    pendingFailedAudioDeletion = receipt
                }
                .buttonStyle(.borderless)
                .disabled(isRetrying || model.voice.isUpdatingFailedAudioRecovery)
            }

            HStack(spacing: 4) {
                Text(
                    L10n.string(
                        .historyFailedAudioExpires,
                        language: model.settings.language
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
        VStack(alignment: .leading, spacing: RillSpacing.compact) {
            Label(L10n.historyRunTrigger(receipt.trigger, language: model.settings.language),
                  systemImage: RillSystemSymbol.boltHorizontalCircle.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            if case let .skipped(reason) = receipt.termination {
                Text(L10n.workflowRunSkipReason(reason, language: model.settings.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(receipt.stepDetails, id: \.stepIndex) { step in
                HStack(spacing: 6) {
                    Text("\(step.stepIndex + 1). " + WorkflowStepPresentation.stepTitle(step.kind, language: model.settings.language))
                    Text("·")
                    Text(L10n.historyStepResult(step.result, language: model.settings.language))
                    Text("·")
                    Text(L10n.historyMeasuredDuration(step.durationMilliseconds, language: model.settings.language))
                }.font(.caption).foregroundStyle(.secondary)
            }

            ForEach(receipt.actionDetails, id: \.actionIndex) { action in
                HStack(spacing: 6) {
                    Text(L10n.historyTimelineAction(action.actionIndex + 1, language: model.settings.language))
                    Text("·")
                        .accessibilityHidden(true)
                    Text(localizedActionResult(action.result))
                    Text("·")
                        .accessibilityHidden(true)
                    Text(L10n.historyMeasuredDuration(action.durationMilliseconds, language: model.settings.language))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if receipt.detailsTruncated {
                Label(
                    L10n.historyTimelineText(
                        .actionDetailsTruncated,
                        language: model.settings.language
                    ),
                    systemImage: RillSystemSymbol.ellipsisCircle.rawValue
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func localizedActionResult(_ result: WorkflowActionResultCode) -> String {
        L10n.workflowActionResult(result, language: model.settings.language)
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
                        Text(L10n.historyTimelineText(.llmAnswer, language: model.settings.language))
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
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: RillRadius.row))
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
                    ? L10n.historyTimelineLLMRequestStep(index + 1, language: model.settings.language)
                    : L10n.historyTimelineText(.llmRequest, language: model.settings.language)
            )
            .font(.callout.weight(.semibold))

            LabeledContent(L10n.historyTimelineText(.provider, language: model.settings.language)) {
                Text(trace.providerID).textSelection(.enabled)
            }
            LabeledContent(L10n.historyTimelineText(.model, language: model.settings.language)) {
                Text(trace.modelID).textSelection(.enabled)
            }
            Text(HistoryTextStepPresentation.tokenUsage(trace.tokenUsage, language: model.settings.language))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            languageModelTraceText(
                L10n.historyTimelineText(.systemPrompt, language: model.settings.language),
                text: trace.systemPrompt
            )
            languageModelTraceText(
                L10n.historyTimelineText(.workflowPrompt, language: model.settings.language),
                text: trace.workflowPrompt
            )
            ForEach(Array(trace.messages.enumerated()), id: \.offset) { messageIndex, message in
                languageModelTraceText(
                    L10n.historyTimelineSentMessage(
                        role: L10n.historyTimelineMessageRole(
                            message.role,
                            language: model.settings.language
                        ),
                        number: messageIndex + 1,
                        language: model.settings.language
                    ),
                    text: message.content
                )
            }
            languageModelTraceText(
                L10n.historyTimelineText(.returnedText, language: model.settings.language),
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
        if trace.inputProvenance == .transcriptOnly {
            return model.settings.language == .simplifiedChinese ? "发送的语音正文（参考另列，原图不保存）" : "Speech text sent (references listed separately; image not retained)"
        }
        if trace.inputProvenance == .legacyRecognition {
            return L10n.historyTimelineText(.recognizedInputLegacy, language: model.settings.language)
        }
        guard trace.inputTexts.count > 1 else {
            return L10n.historyTimelineText(.sentToLLM, language: model.settings.language)
        }
        return L10n.historyTimelineSentToLLMStep(index + 1, language: model.settings.language)
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
                    language: model.settings.language
                ),
                systemImage: RillSystemSymbol.eyeSlash.rawValue
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            HistoryPreviewContent(
                text: text,
                mode: model.privacyPolicySettings.historyPreviewMode,
                language: model.settings.language
            ) { text, lineLimit in
                RillTextPreview(text: text, permitsExpansion: lineLimit == nil, language: model.settings.language)
            }
        }
    }

    private func entryTitle(
        _ entry: HistoryTimelineEntry,
        workflowsByID: [UUID: WorkflowPresentation]
    ) -> String {
        if let record = entry.record {
            return L10n.workflowName(record.workflow, language: model.settings.language)
        }
        if let workflowID = entry.workflowID,
           let workflow = workflowsByID[workflowID] {
            return L10n.workflowName(workflow, language: model.settings.language)
        }
        if let trigger = entry.receipt?.trigger {
            return L10n.historyRunTrigger(trigger, language: model.settings.language)
        }
        return L10n.historyTimelineText(.workflowRunFallback, language: model.settings.language)
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
            status: L10n.historyRunStatus(entry.status, language: model.settings.language),
            title: title,
            termination: entry.receipt?.termination,
            language: model.settings.language
        )
    }

    private var entries: [HistoryTimelineEntry] {
        model.history.displayedRunHistoryEntries
    }

    private var emptyKey: L10n.InterfaceKey { .historyEmpty }
}
