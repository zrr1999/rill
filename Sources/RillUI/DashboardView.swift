import SwiftUI
import RillCore

private enum DashboardViewMetrics {
    static let summaryCardHeight: CGFloat = 168
    static let recentRunsPreviewLimit = 2
    static let recentRunLineLimit = 3
    static let activityPreviewLimit = 6
}

struct ClipboardPanelShortcutSurfaceVisibility: Sendable, Equatable {
    let dashboardCard: Bool
    let settingsRecorder: Bool
    let menuShortcutAnnotation: Bool
}

enum ClipboardPanelShortcutPresentationPolicy {
    static func surfaceVisibility(
        clipboardCaptureEnabled: Bool
    ) -> ClipboardPanelShortcutSurfaceVisibility {
        ClipboardPanelShortcutSurfaceVisibility(
            dashboardCard: clipboardCaptureEnabled,
            settingsRecorder: clipboardCaptureEnabled,
            menuShortcutAnnotation: clipboardCaptureEnabled
        )
    }

    static func globalInputReadyDetail(
        clipboardCaptureEnabled: Bool
    ) -> UIStrings.Key {
        clipboardCaptureEnabled
            ? .voiceSetupGlobalInputReady
            : .voiceSetupGlobalInputVoiceOnlyReady
    }
}

public struct DashboardView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.voiceSetupReadiness.isComplete {
                    voiceSetupCard(model.voiceSetupReadiness)
                }
                Text(UIStrings.text(.appSubtitle, language: model.language))
                    .foregroundStyle(.secondary)
                statusCards
                if let failureMessage = latestFailureMessage {
                    voiceFailureBanner(message: failureMessage)
                }
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
    }

    private func voiceSetupCard(_ readiness: VoiceSetupReadiness) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                UIStrings.text(.voiceSetupTitle, language: model.language),
                systemImage: "checklist"
            )
            .font(.headline)

            Text(UIStrings.text(.voiceSetupDescription, language: model.language))
                .font(.callout)
                .foregroundStyle(.secondary)

            setupPermissionRows(readiness)
            providerSetupRows(readiness.provider)
            privacySetupRows(readiness)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rillCard(opacity: 0.45)
    }

    @ViewBuilder
    private func setupPermissionRows(_ readiness: VoiceSetupReadiness) -> some View {
        globalInputSetupRow(readiness.globalInput)

        permissionSetupRow(
            title: UIStrings.text(.microphone, language: model.language),
            state: readiness.microphone,
            isRequired: true,
            readyDetail: .voiceSetupMicrophoneReady,
            neededDetail: .voiceSetupMicrophoneNeeded,
            requestAction: model.requestMicrophonePermission,
            openSettingsAction: model.openMicrophoneSettings
        )

        permissionSetupRow(
            title: UIStrings.text(.accessibility, language: model.language),
            state: readiness.accessibility,
            isRequired: readiness.accessibilityRequired,
            readyDetail: .voiceSetupAccessibilityReady,
            neededDetail: readiness.accessibilityRequired
                ? .voiceSetupAccessibilityNeeded
                : .voiceSetupAccessibilityOptional,
            requestAction: model.requestAccessibilityPermission,
            openSettingsAction: model.openAccessibilitySettings
        )
    }

    @ViewBuilder
    private func globalInputSetupRow(_ capability: GlobalInputCapability) -> some View {
        let title = UIStrings.text(.globalInput, language: model.language)
        switch capability {
        case .checking:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputChecking,
                symbol: "hourglass",
                color: .secondary
            )
        case .available:
            setupRow(
                title: title,
                detail: ClipboardPanelShortcutPresentationPolicy.globalInputReadyDetail(
                    clipboardCaptureEnabled: model.clipboardCaptureEnabled
                ),
                symbol: "checkmark.circle.fill",
                color: .green
            )
        case .permissionRequired:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputPermissionNeeded,
                symbol: "exclamationmark.circle.fill",
                color: .orange,
                actionTitle: UIStrings.text(.requestAccess, language: model.language),
                actionIdentifier: "dashboard.global-input.request",
                action: model.requestGlobalInputPermission
            )
        case .installationFailed:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputInstallationFailed,
                symbol: "xmark.circle.fill",
                color: .red,
                actionTitle: UIStrings.text(.retryGlobalInput, language: model.language),
                actionIdentifier: "dashboard.global-input.retry",
                action: model.retryGlobalInputInstallation
            )
        }
    }

    @ViewBuilder
    private func permissionSetupRow(
        title: String,
        state: PermissionState,
        isRequired: Bool,
        readyDetail: UIStrings.Key,
        neededDetail: UIStrings.Key,
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) -> some View {
        if state == .granted {
            setupRow(title: title, detail: readyDetail, symbol: "checkmark.circle.fill", color: .green)
        } else if !isRequired {
            setupRow(title: title, detail: neededDetail, symbol: "circle.dashed", color: .secondary)
        } else if state == .unknown {
            setupRow(
                title: title,
                detail: neededDetail,
                symbol: "exclamationmark.circle.fill",
                color: .orange,
                actionTitle: UIStrings.text(.requestAccess, language: model.language),
                action: requestAction
            )
        } else {
            setupRow(
                title: title,
                detail: neededDetail,
                symbol: "xmark.circle.fill",
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                action: openSettingsAction
            )
        }
    }

    @ViewBuilder
    private func providerSetupRows(_ state: VoiceSetupProviderReadiness) -> some View {
        switch state {
        case .loading:
            setupRow(
                title: UIStrings.text(.settingsSpeechEngine, language: model.language),
                detail: .voiceSetupLoading,
                symbol: "hourglass",
                color: .secondary
            )
        case .localPreparing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                setupRow(
                    title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                    detail: .voiceSetupLocalPreparing,
                    symbol: "arrow.down.circle.fill",
                    color: .blue
                )
                ProgressView(value: progress, total: 1)
                    .controlSize(.small)
            }
        case .localReady:
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: .voiceSetupLocalReady,
                symbol: "checkmark.circle.fill",
                color: .green
            )
        case .localUnavailable(let availability):
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: availability == .architectureUnsupported
                    ? .voiceSetupLocalArchitectureUnsupported
                    : .voiceSetupLocalTrustMaterialUnavailable,
                symbol: "exclamationmark.triangle.fill",
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                actionIdentifier: "dashboard.local-speech.open-settings",
                action: { model.showSettings(.speech) }
            )
        case .localPreviouslyPrepared:
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: .voiceSetupLocalPreviouslyPrepared,
                symbol: "questionmark.circle.fill",
                color: .orange,
                actionTitle: UIStrings.text(.localSpeechPrepare, language: model.language),
                action: model.prepareLocalSpeechModel
            )
        case .localNeedsPreparation(let downloadIfNeeded):
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: downloadIfNeeded ? .voiceSetupLocalWillDownload : .voiceSetupLocalNeedsPreparation,
                symbol: "arrow.down.circle.fill",
                color: .orange,
                actionTitle: UIStrings.text(.localSpeechPrepare, language: model.language),
                action: model.prepareLocalSpeechModel
            )
        case .localPreparationFailed:
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: .voiceSetupLocalFailed,
                symbol: "xmark.circle.fill",
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                actionIdentifier: "dashboard.local-speech.open-settings",
                action: { model.showSettings(.speech) }
            )
        }
    }

    @ViewBuilder
    private func privacySetupRows(_ readiness: VoiceSetupReadiness) -> some View {
        switch readiness.privacy {
        case .loading:
            setupRow(
                title: UIStrings.text(.permissions, language: model.language),
                detail: .voiceSetupPrivacyLoading,
                symbol: "lock.circle",
                color: .secondary
            )
        case .unavailable:
            setupRow(
                title: UIStrings.text(.permissions, language: model.language),
                detail: .voiceSetupPrivacyUnavailable,
                symbol: "lock.trianglebadge.exclamationmark",
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                actionIdentifier: "dashboard.privacy.open-settings",
                action: { model.showSettings(.privacy) }
            )
        case .available:
            EmptyView()
        }
    }

    private func setupRow(
        title: String,
        detail: UIStrings.Key,
        symbol: String,
        color: Color,
        actionTitle: String? = nil,
        actionIdentifier: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(UIStrings.text(detail, language: model.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier(actionIdentifier ?? "")
            }
        }
    }

    private var statusCards: some View {
        HStack(alignment: .top, spacing: 16) {
            if ClipboardPanelShortcutPresentationPolicy.surfaceVisibility(
                clipboardCaptureEnabled: model.clipboardCaptureEnabled
            ).dashboardCard {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(UIStrings.text(.deliveryStack, language: model.language)): "
                        + UIStrings.stackCountSummary(model.stackCount, language: model.language)
                )
                .accessibilityIdentifier("dashboard.clipboard-panel")
            }

            Button {
                model.showRunHistory()
            } label: {
                recentRunsCard
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                UIStrings.recentRunsAccessibilityLabel(
                    count: recentRunEntries.count,
                    language: model.language
                )
            )
            .accessibilityHint(
                UIStrings.recentRunsAccessibilityHint(language: model.language)
            )
            .accessibilityIdentifier("dashboard.recent-runs")
        }
        .animation(.easeInOut(duration: 0.2), value: model.clipboardCaptureEnabled)
        .animation(.easeInOut(duration: 0.2), value: model.stackCount)
        .animation(.easeInOut(duration: 0.2), value: recentRunEntries.map(\.id))
    }

    private func statusCard(title: String, primary: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(primary)
                .font(.body.weight(.medium))
                .lineLimit(2)
            Text(secondary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: DashboardViewMetrics.summaryCardHeight, alignment: .topLeading)
        .rillCard(opacity: 0.35)
    }

    private var recentRunsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UIStrings.text(.historyScopeAll, language: model.language))
                .font(.headline)

            if recentRunEntries.isEmpty {
                Text(UIStrings.text(.historyEmpty, language: model.language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(
                        Array(recentRunEntries.prefix(DashboardViewMetrics.recentRunsPreviewLimit))
                    ) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                Label(
                                    GlobalSearchText.status(
                                        entry.status,
                                        language: model.language
                                    ),
                                    systemImage: entry.status.systemSymbol.rawValue
                                )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(recentRunTitle(entry))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            if let finalText = entry.record?.finalText {
                                HistoryPreviewContent(
                                    text: finalText,
                                    mode: model.privacyPolicySettings.historyPreviewMode,
                                    language: model.language
                                ) { text, privacyLineLimit in
                                    Text(ClipboardTextFormatting.previewText(text, limit: 260))
                                        .font(.body.weight(.medium))
                                        .lineLimit(
                                            min(
                                                privacyLineLimit
                                                    ?? DashboardViewMetrics.recentRunLineLimit,
                                                DashboardViewMetrics.recentRunLineLimit
                                            )
                                        )
                                        .truncationMode(.tail)
                                }
                            } else if let failureMessage = entry.record?.failureMessage {
                                Text(failureMessage)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(DashboardViewMetrics.recentRunLineLimit)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: DashboardViewMetrics.summaryCardHeight, alignment: .topLeading)
        .rillCard(opacity: 0.35)
    }

    private var recentRunEntries: [HistoryTimelineEntry] {
        HistoryTimelineBuilder.allRuns(
            records: model.recentVoiceHistoryRecords,
            receipts: Array(model.workflowRunReceiptsByRunID.values)
        )
    }

    private func recentRunTitle(_ entry: HistoryTimelineEntry) -> String {
        if let record = entry.record {
            return UIStrings.workflowName(record.workflow, language: model.language)
        }
        if let workflowID = entry.workflowID,
           let workflow = model.workflows.first(where: { $0.id == workflowID }) {
            return UIStrings.workflowName(workflow.presentation, language: model.language)
        }
        return GlobalSearchText.genericRun(language: model.language)
    }

    private var latestFailureMessage: String? {
        guard let message = model.lastFailure?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        return message
    }

    private func voiceFailureBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(
                    UIStrings.text(.sidebarDiagnostics, language: model.language),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Spacer()

                Button(UIStrings.text(.copy, language: model.language)) {
                    model.copyTextToClipboard(message)
                }
                .buttonStyle(.borderless)
            }

            Text(failureSummary(for: message))
                .font(.callout.weight(.medium))

            VStack(alignment: .leading, spacing: 4) {
                Text(UIStrings.text(.diagnosticsTimeline, language: model.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rillCard(opacity: 0.45)
    }

    private func failureSummary(for message: String) -> String {
        return UIStrings.text(.historyDescription, language: model.language)
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(UIStrings.text(.eventFeed, language: model.language))
                    .font(.headline)
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
                .controlSize(.small)
                .accessibilityIdentifier("dashboard.open-diagnostics")
            }
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
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(
                        model.eventFeed
                            .suffix(DashboardViewMetrics.activityPreviewLimit)
                            .reversed()
                    ) { entry in
                        eventFeedRow(entry)
                    }
                }
            }
        }
    }

    private func eventFeedRow(_ entry: EventFeedEntry) -> some View {
        let presentation = entry.presentation(
            for: model.language,
            historyPreviewMode: model.privacyPolicySettings.historyPreviewMode
        )
        return Text(presentation.text)
            .lineLimit(presentation.lineLimit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .rillCard(cornerRadius: 10, opacity: 0.2, padding: 10)
    }
}
