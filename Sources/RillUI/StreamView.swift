import SwiftUI
import RillCore

/// Current work and recoverable failures precede the durable receipt timeline.
public struct StreamView: View {
    /// Shared card appear/disappear spring for the stream surface.
    private static let cardSpring: Animation = .spring(response: 0.35, dampingFraction: 1.0)

    @Bindable private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
            isAudioProcessingQueueVisible: model.voice.audioProcessingQueueSnapshot?.isVisible ?? false,
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
                    model.showSettings(.diagnostics)
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

}
