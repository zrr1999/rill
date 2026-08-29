import SwiftUI
import RillCore

private enum StreamViewMetrics {
    static let activityPreviewLimit = 6
}

struct RecordPanelShortcutSurfaceVisibility: Sendable, Equatable {
    let streamCard: Bool
    let settingsRecorder: Bool
    let menuShortcutAnnotation: Bool
}

enum RecordPanelShortcutPresentationPolicy {
    static func surfaceVisibility(
        systemClipboardCaptureEnabled: Bool
    ) -> RecordPanelShortcutSurfaceVisibility {
        RecordPanelShortcutSurfaceVisibility(
            streamCard: systemClipboardCaptureEnabled,
            settingsRecorder: systemClipboardCaptureEnabled,
            menuShortcutAnnotation: systemClipboardCaptureEnabled
        )
    }

    static func globalInputReadyDetail(
        systemClipboardCaptureEnabled: Bool
    ) -> UIStrings.Key {
        systemClipboardCaptureEnabled
            ? .voiceSetupGlobalInputReady
            : .voiceSetupGlobalInputVoiceOnlyReady
    }
}

/// The stream home merges the former Dashboard and Run History pages into one
/// Record-stream surface: readiness, live activity and the durable receipt
/// timeline share a single scroll, per docs/ui-direction.md.
public struct StreamView: View {
    @Bindable private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.voiceSetupReadiness.isComplete {
                        voiceSetupCard(model.voiceSetupReadiness)
                    }
                    Text(UIStrings.text(.appSubtitle, language: model.language))
                        .foregroundStyle(.secondary)
                    recordStatusCard
                    if let activityPresentation = streamActivityPresentation {
                        streamActivityCard(activityPresentation)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
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
                    HistoryTimelineView(model: model, proxy: proxy)
                }
                .padding(24)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0),
                    value: model.pendingResolution != nil
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0),
                    value: streamActivityPresentation
                )
            }
        }
        .navigationTitle(UIStrings.text(.sidebarStream, language: model.language))
    }

    @ViewBuilder
    private var recordStatusCard: some View {
        if RecordPanelShortcutPresentationPolicy.surfaceVisibility(
            systemClipboardCaptureEnabled: model.systemClipboardCaptureEnabled
        ).streamCard {
            Button {
                model.showRecordPanel()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UIStrings.text(.deliveryStack, language: model.language))
                        .font(.headline)
                    Text(UIStrings.recordCountSummary(model.recordCount, language: model.language))
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Text(model.recordPreview ?? UIStrings.text(.stackEmpty, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                .rillCard()
            }
            .buttonStyle(RillCardButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(UIStrings.text(.deliveryStack, language: model.language)): "
                    + UIStrings.recordCountSummary(model.recordCount, language: model.language)
            )
            .accessibilityIdentifier("stream.record-panel")
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0),
                value: model.systemClipboardCaptureEnabled
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0),
                value: model.recordCount
            )
        }
    }

    private var streamActivityPresentation: StreamActivityPresentation? {
        StreamActivityPresentation.make(
            isRunning: model.isRunning,
            workflowAudioRunState: model.workflowAudioRunState,
            isAudioProcessingQueueVisible: model.audioProcessingQueueSnapshot?.isVisible ?? false,
            language: model.language
        )
    }

    private func streamActivityCard(_ presentation: StreamActivityPresentation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: presentation.symbol.rawValue)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.subheadline.weight(.medium))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .rillCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title). \(presentation.detail)")
        .accessibilityIdentifier("stream.activity-status")
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
                    L10n.string(.voiceFailureTitle, language: model.language),
                    systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Spacer()

                Button(UIStrings.text(.copy, language: model.language)) {
                    model.copyTextToClipboard(message)
                }
                .buttonStyle(.borderless)
            }

            Text(L10n.string(.voiceFailureGenericSummary, language: model.language))
                .font(.callout.weight(.medium))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(.voiceFailureDetailsLabel, language: model.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rillCard(.prominent)
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
                .accessibilityIdentifier("stream.open-diagnostics")
            }
            if model.eventFeed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: RillSystemSymbol.textBubble.rawValue)
                        .font(.largeTitle)
                        .imageScale(.large)
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
                            .suffix(StreamViewMetrics.activityPreviewLimit)
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
            .rillCard(.subdued, cornerRadius: 10, padding: 10)
    }
}


extension StreamView {
    private func voiceSetupCard(_ readiness: VoiceSetupReadiness) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                UIStrings.text(.voiceSetupTitle, language: model.language),
                systemImage: RillSystemSymbol.checklist.rawValue
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
        .rillCard(.prominent)
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
                symbol: RillSystemSymbol.hourglass.rawValue,
                color: .secondary
            )
        case .available:
            setupRow(
                title: title,
                detail: RecordPanelShortcutPresentationPolicy.globalInputReadyDetail(
                    systemClipboardCaptureEnabled: model.systemClipboardCaptureEnabled
                ),
                symbol: RillSystemSymbol.checkmarkCircleFill.rawValue,
                color: .green
            )
        case .permissionRequired:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputPermissionNeeded,
                symbol: RillSystemSymbol.exclamationmarkCircleFill.rawValue,
                color: .orange,
                actionTitle: UIStrings.text(.requestAccess, language: model.language),
                actionIdentifier: "stream.global-input.request",
                action: model.requestGlobalInputPermission
            )
        case .installationFailed:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputInstallationFailed,
                symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
                color: .red,
                actionTitle: UIStrings.text(.retryGlobalInput, language: model.language),
                actionIdentifier: "stream.global-input.retry",
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
            setupRow(title: title, detail: readyDetail, symbol: RillSystemSymbol.checkmarkCircleFill.rawValue, color: .green)
        } else if !isRequired {
            setupRow(title: title, detail: neededDetail, symbol: RillSystemSymbol.circleDashed.rawValue, color: .secondary)
        } else if state == .unknown {
            setupRow(
                title: title,
                detail: neededDetail,
                symbol: RillSystemSymbol.exclamationmarkCircleFill.rawValue,
                color: .orange,
                actionTitle: UIStrings.text(.requestAccess, language: model.language),
                action: requestAction
            )
        } else {
            setupRow(
                title: title,
                detail: neededDetail,
                symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
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
                symbol: RillSystemSymbol.hourglass.rawValue,
                color: .secondary
            )
        case .localPreparing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                setupRow(
                    title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                    detail: .voiceSetupLocalPreparing,
                    symbol: RillSystemSymbol.arrowDownCircleFill.rawValue,
                    color: .blue
                )
                ProgressView(value: progress, total: 1)
                    .controlSize(.small)
            }
        case .localReady:
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: .voiceSetupLocalReady,
                symbol: RillSystemSymbol.checkmarkCircleFill.rawValue,
                color: .green
            )
        case .localUnavailable(let availability):
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: availability == .architectureUnsupported
                    ? .voiceSetupLocalArchitectureUnsupported
                    : .voiceSetupLocalTrustMaterialUnavailable,
                symbol: RillSystemSymbol.exclamationmarkTriangleFill.rawValue,
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                actionIdentifier: "stream.local-speech.open-settings",
                action: { model.showSettings(.speech) }
            )
        case .localPreviouslyPrepared:
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: .voiceSetupLocalPreviouslyPrepared,
                symbol: RillSystemSymbol.questionmarkCircleFill.rawValue,
                color: .orange,
                actionTitle: UIStrings.text(.localSpeechPrepare, language: model.language),
                action: model.prepareLocalSpeechModel
            )
        case .localNeedsPreparation(let downloadIfNeeded):
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: downloadIfNeeded ? .voiceSetupLocalWillDownload : .voiceSetupLocalNeedsPreparation,
                symbol: RillSystemSymbol.arrowDownCircleFill.rawValue,
                color: .orange,
                actionTitle: UIStrings.text(.localSpeechPrepare, language: model.language),
                action: model.prepareLocalSpeechModel
            )
        case .localPreparationFailed:
            setupRow(
                title: UIStrings.text(.settingsLocalSpeech, language: model.language),
                detail: .voiceSetupLocalFailed,
                symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                actionIdentifier: "stream.local-speech.open-settings",
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
                symbol: RillSystemSymbol.lockCircle.rawValue,
                color: .secondary
            )
        case .unavailable:
            setupRow(
                title: UIStrings.text(.permissions, language: model.language),
                detail: .voiceSetupPrivacyUnavailable,
                symbol: RillSystemSymbol.lockTrianglebadgeExclamationmark.rawValue,
                color: .red,
                actionTitle: UIStrings.text(.openSettings, language: model.language),
                actionIdentifier: "stream.privacy.open-settings",
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
}
