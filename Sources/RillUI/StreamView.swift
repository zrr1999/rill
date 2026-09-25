import SwiftUI
import RillCore

/// The stream home merges the former Dashboard and Run History pages into one
/// Record-stream surface: readiness, live activity and the durable receipt
/// timeline share a single scroll, per docs/ui-direction.md.
public struct StreamView: View {
    /// Shared card appear/disappear spring for the stream surface.
    private static let cardSpring: Animation = .spring(response: 0.35, dampingFraction: 1.0)

    @State private var isEventFeedExpanded = false
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
                    if let pending = model.voice.pendingResolution {
                        CandidatePanelView(
                            candidateCase: pending,
                            language: model.settings.language,
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
                    if let failureMessage = latestFailureMessage {
                        voiceFailureBanner(message: failureMessage)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
                    if let activityPresentation = streamActivityPresentation {
                        streamActivityCard(activityPresentation)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
                    HistoryTimelineView(model: model, proxy: proxy)
                    eventFeed
                }
                .padding(RillSpacing.page)
                .animation(
                    reduceMotion ? nil : Self.cardSpring,
                    value: model.voice.pendingResolution != nil
                )
                .animation(
                    reduceMotion ? nil : Self.cardSpring,
                    value: streamActivityPresentation
                )
                .animation(
                    reduceMotion ? nil : Self.cardSpring,
                    value: latestFailureMessage != nil
                )
            }
        }
        .navigationTitle(L10n.text(.sidebarStream, language: model.settings.language))
    }

    private var streamActivityPresentation: StreamActivityPresentation? {
        StreamActivityPresentation.make(
            isRunning: model.voice.isRunning,
            workflowAudioRunState: model.voice.workflowAudioRunState,
            isAudioProcessingQueueVisible: model.audioProcessingQueueSnapshot?.isVisible ?? false,
            language: model.settings.language,
            activeStage: model.voice.activeStage
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
                    L10n.string(.voiceFailureTitle, language: model.settings.language),
                    systemImage: RillSystemSymbol.exclamationmarkTriangleFill.rawValue
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Spacer()

                RillCopyButton(
                    title: L10n.historyTimelineText(.copyFailureDetails, language: model.settings.language),
                    language: model.settings.language
                ) {
                    model.copyTextToClipboard(message)
                }
                .buttonStyle(.borderless)
            }

            Button(model.permissionSnapshot.microphone == .denied
                || (model.voiceSetupReadiness.accessibilityRequired && model.permissionSnapshot.accessibility == .denied)
                ? L10n.text(.openSettings, language: model.settings.language)
                : L10n.presentation(.details, language: model.settings.language)) {
                if model.permissionSnapshot.microphone == .denied {
                    model.openMicrophoneSettings()
                } else if model.voiceSetupReadiness.accessibilityRequired && model.permissionSnapshot.accessibility == .denied {
                    model.openAccessibilitySettings()
                } else if let entry = model.history.displayedRunHistoryEntries.first(where: {
                    $0.status == .failed && $0.record?.failureMessage == message
                }) {
                    model.showHistoryEntry(entry.id)
                } else {
                    model.selectSidebarSection(.diagnostics)
                }
            }
            .buttonStyle(.borderedProminent)

            Text(L10n.string(.voiceFailureGenericSummary, language: model.settings.language))
                .font(.callout.weight(.medium))

            DisclosureGroup(L10n.string(.voiceFailureDetailsLabel, language: model.settings.language)) {
                Text(L10n.string(.voiceFailureDetailsLabel, language: model.settings.language))
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
        DisclosureGroup(isExpanded: $isEventFeedExpanded) {
            if model.history.eventFeed.isEmpty {
                Text(L10n.text(.eventFeedEmpty, language: model.settings.language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.history.eventFeed) { entry in
                        eventFeedRow(entry)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text(.eventFeed, language: model.settings.language))
                    .font(.headline)
                Spacer()
                Button {
                    model.selectSidebarSection(.diagnostics)
                } label: {
                    Label(
                        L10n.text(.sidebarDiagnostics, language: model.settings.language),
                        systemImage: SidebarSection.diagnostics.symbolName
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("stream.open-diagnostics")
            }
            Text("\(model.history.eventFeed.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func eventFeedRow(_ entry: EventFeedEntry) -> some View {
        let presentation = entry.presentation(
            for: model.settings.language,
            historyPreviewMode: model.privacyPolicySettings.historyPreviewMode
        )
        return Text(presentation.text)
            .lineLimit(presentation.lineLimit)
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .rillCard(.subdued, cornerRadius: RillRadius.row, padding: RillSpacing.row)
    }
}


extension StreamView {
    private func voiceSetupCard(_ readiness: VoiceSetupReadiness) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                L10n.text(.voiceSetupTitle, language: model.settings.language),
                systemImage: RillSystemSymbol.checklist.rawValue
            )
            .font(.headline)

            Text(L10n.text(.voiceSetupDescription, language: model.settings.language))
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
            title: L10n.text(.microphone, language: model.settings.language),
            state: readiness.microphone,
            isRequired: true,
            readyDetail: .voiceSetupMicrophoneReady,
            neededDetail: .voiceSetupMicrophoneNeeded,
            requestAction: model.requestMicrophonePermission,
            openSettingsAction: model.openMicrophoneSettings
        )

        permissionSetupRow(
            title: L10n.text(.accessibility, language: model.settings.language),
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
        let title = L10n.text(.globalInput, language: model.settings.language)
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
                detail: .voiceSetupGlobalInputReady,
                symbol: RillSystemSymbol.checkmarkCircleFill.rawValue,
                color: .green
            )
        case .permissionRequired:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputPermissionNeeded,
                symbol: RillSystemSymbol.exclamationmarkCircleFill.rawValue,
                color: .orange,
                actionTitle: L10n.text(.requestAccess, language: model.settings.language),
                actionIdentifier: "stream.global-input.request",
                action: model.requestGlobalInputPermission
            )
        case .installationFailed:
            setupRow(
                title: title,
                detail: .voiceSetupGlobalInputInstallationFailed,
                symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
                color: .red,
                actionTitle: L10n.text(.retryGlobalInput, language: model.settings.language),
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
        readyDetail: L10n.InterfaceKey,
        neededDetail: L10n.InterfaceKey,
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
                actionTitle: L10n.text(.requestAccess, language: model.settings.language),
                action: requestAction
            )
        } else {
            setupRow(
                title: title,
                detail: neededDetail,
                symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
                color: .red,
                actionTitle: L10n.text(.openSettings, language: model.settings.language),
                action: openSettingsAction
            )
        }
    }

    @ViewBuilder
    private func providerSetupRows(_ state: VoiceSetupProviderReadiness) -> some View {
        switch state {
        case .loading:
            setupRow(
                title: L10n.text(.settingsSpeechEngine, language: model.settings.language),
                detail: .voiceSetupLoading,
                symbol: RillSystemSymbol.hourglass.rawValue,
                color: .secondary
            )
        case .localPreparing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                setupRow(
                    title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
                    detail: .voiceSetupLocalPreparing,
                    symbol: RillSystemSymbol.arrowDownCircleFill.rawValue,
                    color: .blue
                )
                ProgressView(value: progress, total: 1)
                    .controlSize(.small)
            }
        case .localReady:
            setupRow(
                title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
                detail: .voiceSetupLocalReady,
                symbol: RillSystemSymbol.checkmarkCircleFill.rawValue,
                color: .green
            )
        case .localUnavailable(let availability):
            setupRow(
                title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
                detail: availability == .architectureUnsupported
                    ? .voiceSetupLocalArchitectureUnsupported
                    : .voiceSetupLocalTrustMaterialUnavailable,
                symbol: RillSystemSymbol.exclamationmarkTriangleFill.rawValue,
                color: .red,
                actionTitle: L10n.text(.openSettings, language: model.settings.language),
                actionIdentifier: "stream.local-speech.open-settings",
                action: { model.showSettings(.speech) }
            )
        case .localPreviouslyPrepared:
            setupRow(
                title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
                detail: .voiceSetupLocalPreviouslyPrepared,
                symbol: RillSystemSymbol.questionmarkCircleFill.rawValue,
                color: .orange,
                actionTitle: L10n.text(.localSpeechPrepare, language: model.settings.language),
                action: model.prepareLocalSpeechModel
            )
        case .localNeedsPreparation(let downloadIfNeeded):
            setupRow(
                title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
                detail: downloadIfNeeded ? .voiceSetupLocalWillDownload : .voiceSetupLocalNeedsPreparation,
                symbol: RillSystemSymbol.arrowDownCircleFill.rawValue,
                color: .orange,
                actionTitle: L10n.text(.localSpeechPrepare, language: model.settings.language),
                action: model.prepareLocalSpeechModel
            )
        case .localPreparationFailed:
            setupRow(
                title: L10n.text(.settingsLocalSpeech, language: model.settings.language),
                detail: .voiceSetupLocalFailed,
                symbol: RillSystemSymbol.xmarkCircleFill.rawValue,
                color: .red,
                actionTitle: L10n.text(.openSettings, language: model.settings.language),
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
                title: L10n.text(.permissions, language: model.settings.language),
                detail: .voiceSetupPrivacyLoading,
                symbol: RillSystemSymbol.lockCircle.rawValue,
                color: .secondary
            )
        case .unavailable:
            setupRow(
                title: L10n.text(.permissions, language: model.settings.language),
                detail: .voiceSetupPrivacyUnavailable,
                symbol: RillSystemSymbol.lockTrianglebadgeExclamationmark.rawValue,
                color: .red,
                actionTitle: L10n.text(.openSettings, language: model.settings.language),
                actionIdentifier: "stream.privacy.open-settings",
                action: { model.showSettings(.privacy) }
            )
        case .available:
            EmptyView()
        }
    }

    private func setupRow(
        title: String,
        detail: L10n.InterfaceKey,
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
                Text(L10n.text(detail, language: model.settings.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let actionTitle, let action {
                // Only stamp an identifier when one is provided; an empty
                // identifier is worse than none for accessibility queries.
                if let actionIdentifier {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(actionIdentifier)
                } else {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}
