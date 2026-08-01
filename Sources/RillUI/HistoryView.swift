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
                text: ClipboardTextFormatting.previewText(
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
                Label(message, systemImage: "eye.slash")
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

public struct HistoryView: View {
    private static let topAnchorID = "history.top"

    @Bindable private var model: AppModel
    @State private var correctionRecord: HistoryRecord?
    @State private var pendingFailedAudioDeletion: FailedAudioRecoveryReceipt?
    @FocusState private var focusedTarget: HistoryViewFocusTarget?
    @AccessibilityFocusState private var accessibilityFocusedTarget: HistoryViewFocusTarget?

    public init(model: AppModel) {
        self.model = model
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

        ScrollViewReader { proxy in
            ScrollView {
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
                        Label(error, systemImage: "exclamationmark.triangle")
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
                            Image(systemName: "clock.badge.exclamationmark")
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
                                systemImage: "exclamationmark.triangle"
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
                    .animation(.easeInOut(duration: 0.3), value: viewState)
                }
                .id(Self.topAnchorID)
                .padding(24)
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(visibleEntryID, anchor: .center)
                }
                await Task.yield()
                guard model.historyNavigationRequest?.id == request.id else { return }
                focusedTarget = .entry(visibleEntryID)
                accessibilityFocusedTarget = .entry(visibleEntryID)
            }
        }
        .navigationTitle(UIStrings.text(.historyTitle, language: model.language))
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
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
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
                    systemImage: "chevron.left"
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
                    systemImage: "chevron.right"
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
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
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
            Button {
                model.selectSidebarSection(.dashboard)
            } label: {
                Label(
                    UIStrings.text(.historyOpenDashboard, language: model.language),
                    systemImage: SidebarSection.dashboard.symbolName
                )
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("history.empty.openDashboard")
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
        .animation(.easeInOut(duration: 0.2), value: entries.map(\.id))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entry.status.systemSymbol.rawValue)
                    .foregroundStyle(statusColor(entry.status))

                Text(title)
                    .font(.headline)

                if entry.isStackRelated || entry.receipt?.trigger == .stackDelivery {
                    Label(
                        UIStrings.text(.historyStackBadge, language: model.language),
                        systemImage: "square.stack.3d.up"
                    )
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1), in: Capsule())
                    .foregroundStyle(.blue)
                }

                Spacer()

                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(historyAccessibilityLabel(entry, title: title))
            .accessibilityValue(Text(entry.timestamp, style: .relative))

            historyPreview(
                entry.record?.finalText,
                hasProtectedPreview: entry.hasProtectedPreview
            )

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
                            systemImage: "text.badge.checkmark"
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
                            systemImage: "exclamationmark.triangle"
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
                    model.language == .english
                        ? "Execution details are unavailable for this older run."
                        : "这条较早的运行没有可用的执行详情。",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let runID = entry.runID,
               let reason = model.failedAudioRecoveryUnavailableReasonsByRunID[runID] {
                Label(
                    model.failedAudioRecoveryUnavailableMessage(reason),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if model.failedAudioRecoveryEnabled,
               let receipt = model.failedAudioRecoveryReceipt(for: entry.runID) {
                failedAudioRecoveryControls(receipt)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
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
                    systemImage: "exclamationmark.triangle.fill"
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
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        } else {
                            Label(
                                L10n.string(
                                    .historyFailedAudioRetry,
                                    language: model.language
                                ),
                                systemImage: "arrow.clockwise.circle"
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
                Label(localizedTrigger(receipt.trigger), systemImage: "bolt.horizontal.circle")
                Text("·")
                    .accessibilityHidden(true)
                Text(localizedTermination(receipt.termination))
                Text("·")
                    .accessibilityHidden(true)
                Text(localizedDuration(receipt.duration))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            ForEach(receipt.actionDetails, id: \.actionIndex) { action in
                HStack(spacing: 6) {
                    Text(
                        model.language == .english
                            ? "Action \(action.actionIndex + 1)"
                            : "动作 \(action.actionIndex + 1)"
                    )
                    Text("·")
                        .accessibilityHidden(true)
                    Text(localizedActionResult(action.result))
                    Text("·")
                        .accessibilityHidden(true)
                    Text(localizedDuration(action.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if receipt.detailsTruncated {
                Label(
                    model.language == .english
                        ? "Additional action details were omitted."
                        : "其余动作详情已省略。",
                    systemImage: "ellipsis.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func localizedTrigger(_ trigger: WorkflowRunTriggerKind) -> String {
        switch (model.language, trigger) {
        case (.english, .manual): "Manual"
        case (.simplifiedChinese, .manual): "手动"
        case (.english, .menuBar): "Menu bar"
        case (.simplifiedChinese, .menuBar): "菜单栏"
        case (.english, .hotkey): "Hotkey"
        case (.simplifiedChinese, .hotkey): "快捷键"
        case (.english, .wakeWord): "Wake word"
        case (.simplifiedChinese, .wakeWord): "唤醒词"
        case (.english, .clipboardGroupEvent): "Clipboard event"
        case (.simplifiedChinese, .clipboardGroupEvent): "剪贴板事件"
        case (.english, .stackDelivery): "Stack delivery"
        case (.simplifiedChinese, .stackDelivery): "堆栈投递"
        case (.english, .clipboardUse): "Clipboard paste"
        case (.simplifiedChinese, .clipboardUse): "剪贴板粘贴"
        case (.english, .clipboardReplay): "Clipboard replay"
        case (.simplifiedChinese, .clipboardReplay): "剪贴板重放"
        case (.english, .failedAudioRecovery): "Audio recovery"
        case (.simplifiedChinese, .failedAudioRecovery): "录音恢复"
        }
    }

    private func localizedTermination(_ termination: WorkflowRunTermination) -> String {
        L10n.workflowRunTermination(termination, language: model.language)
    }

    private func localizedDuration(_ duration: WorkflowRunDurationBucket) -> String {
        switch (model.language, duration) {
        case (.english, .under250ms): "under 250 ms"
        case (.simplifiedChinese, .under250ms): "少于 250 毫秒"
        case (.english, .ms250To999): "250–999 ms"
        case (.simplifiedChinese, .ms250To999): "250–999 毫秒"
        case (.english, .s1To4): "1–4 s"
        case (.simplifiedChinese, .s1To4): "1–4 秒"
        case (.english, .s5To14): "5–14 s"
        case (.simplifiedChinese, .s5To14): "5–14 秒"
        case (.english, .s15To59): "15–59 s"
        case (.simplifiedChinese, .s15To59): "15–59 秒"
        case (.english, .m1Plus): "1 min or more"
        case (.simplifiedChinese, .m1Plus): "1 分钟以上"
        case (.english, .unavailable): "duration unavailable"
        case (.simplifiedChinese, .unavailable): "耗时不可用"
        }
    }

    private func localizedActionResult(_ result: WorkflowActionResultCode) -> String {
        L10n.workflowActionResult(result, language: model.language)
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
                systemImage: "eye.slash"
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
            return localizedTrigger(trigger)
        }
        return model.language == .english ? "Workflow run" : "工作流运行"
    }

    private func statusColor(_ status: HistoryTimelineStatus) -> Color {
        switch status {
        case .completed: .green
        case .partiallyCompleted: .orange
        case .failed: .red
        case .cancelled, .skipped: .gray
        }
    }

    private func localizedStatus(_ status: HistoryTimelineStatus) -> String {
        switch (model.language, status) {
        case (.english, .completed): "Completed"
        case (.simplifiedChinese, .completed): "已完成"
        case (.english, .partiallyCompleted): "Partially completed"
        case (.simplifiedChinese, .partiallyCompleted): "部分完成"
        case (.english, .failed): "Failed"
        case (.simplifiedChinese, .failed): "失败"
        case (.english, .cancelled): "Cancelled"
        case (.simplifiedChinese, .cancelled): "已取消"
        case (.english, .skipped): "Skipped"
        case (.simplifiedChinese, .skipped): "已跳过"
        }
    }

    private func historyAccessibilityLabel(
        _ entry: HistoryTimelineEntry,
        title: String
    ) -> String {
        L10n.historyRunAccessibilityLabel(
            status: localizedStatus(entry.status),
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
