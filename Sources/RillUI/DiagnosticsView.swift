import SwiftUI
import RillCore

public struct DiagnosticsView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(UIStrings.text(.diagnosticsDescription, language: model.language))
                    .foregroundStyle(.secondary)
                speechCheckSection
                diagnosticsSection
            }
            .padding(24)
        }
        .navigationTitle(UIStrings.text(.diagnosticsTitle, language: model.language))
    }

    private var speechCheckSection: some View {
        VStack(alignment: .leading, spacing: 12) {
                Label(
                    UIStrings.text(.diagnosticsSpeechCheck, language: model.language),
                    systemImage: "waveform.badge.mic"
                )
                .font(.headline)

                Text(UIStrings.text(.diagnosticsSpeechCheckDescription, language: model.language))
                    .foregroundStyle(.secondary)

                switch model.deepgramCredentialAvailability {
                case .loading:
                    ProgressView(UIStrings.text(.voiceSetupLoading, language: model.language))
                case .saving:
                    ProgressView(UIStrings.text(.voiceSetupCloudCredentialSaving, language: model.language))
                case .inaccessible:
                    Text(UIStrings.text(.voiceSetupCloudCredentialUnavailable, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.red)

                    Button(UIStrings.text(.retryCredentialLoad, language: model.language)) {
                        model.retryDeepgramCredentialLoad()
                    }
                case .missing:
                    Text(UIStrings.text(.diagnosticsManageProviderSettings, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button(UIStrings.text(.diagnosticsOpenSettings, language: model.language)) {
                        model.showSettings(.speech)
                    }
                    .accessibilityIdentifier("diagnostics.open-settings")
                case .available:
                    Text(UIStrings.text(.deepgramTestHint, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button(UIStrings.deepgramTestButtonTitle(model.deepgramAudioTestState, language: model.language)) {
                        model.toggleDeepgramAudioTest()
                    }

                    if let error = model.deepgramTestError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else if let transcript = model.deepgramTestTranscript, !transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(UIStrings.text(.deepgramLastTranscript, language: model.language))
                                .font(.subheadline.weight(.medium))
                            Text(transcript)
                                .font(.callout)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text(UIStrings.text(.deepgramNoTranscript, language: model.language))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .rillCard()
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        UIStrings.text(.diagnosticsTimeline, language: model.language),
                        systemImage: "clock.badge.checkmark"
                    )
                    .font(.headline)
                    Spacer()
                    Button(UIStrings.text(.refreshDiagnostics, language: model.language)) {
                        model.refreshDiagnostics()
                    }
                    .disabled(model.diagnosticsLoadState == .loading)
                    .accessibilityIdentifier("diagnostics.timeline.refresh")
                }

                switch Self.timelineContent(
                    loadState: model.diagnosticsLoadState,
                    events: model.diagnosticEvents
                ) {
                case .loading(let entries):
                    ProgressView(UIStrings.text(.diagnosticsLoading, language: model.language))
                        .controlSize(.small)
                        .accessibilityIdentifier("diagnostics.timeline.loading")
                    timelineRows(entries)
                case .failed(let entries):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            UIStrings.text(.diagnosticsLoadFailed, language: model.language),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("diagnostics.timeline.error")

                        Button(UIStrings.text(.diagnosticsRetry, language: model.language)) {
                            model.refreshDiagnostics()
                        }
                        .disabled(model.diagnosticsLoadState == .loading)
                        .accessibilityIdentifier("diagnostics.timeline.retry")
                    }
                    timelineRows(entries)
                case .empty:
                    Text(UIStrings.text(.diagnosticsEmpty, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics.timeline.empty")
                case .events(let entries):
                    timelineRows(entries)
                }
            }
            .rillCard()
    }

    static func timelineEvents(from events: [DiagnosticEvent]) -> [DiagnosticEvent] {
        timelineEntries(from: events).map(\.event)
    }

    static func timelineEntries(from events: [DiagnosticEvent]) -> [DiagnosticTimelineEntry] {
        DiagnosticTimelineEntry.build(from: events, limit: 20)
    }

    static func timelineContent(
        loadState: DiagnosticsLoadState,
        events: [DiagnosticEvent]
    ) -> DiagnosticsTimelineContent {
        DiagnosticsTimelineContent.resolve(loadState: loadState, events: events)
    }

    @ViewBuilder
    private func timelineRows(_ entries: [DiagnosticTimelineEntry]) -> some View {
        ForEach(entries) { entry in
            diagnosticRow(entry)
        }
    }

    private func diagnosticRow(_ entry: DiagnosticTimelineEntry) -> some View {
        let event = entry.event
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(UIStrings.diagnosticLevel(event.level, language: model.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(diagnosticColor(event.level))
                Spacer()
                if event.level == .warning || event.level == .error {
                    Button(UIStrings.text(.copy, language: model.language)) {
                        model.copyDiagnosticEvent(event)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel(entry.copyAccessibilityLabel(language: model.language))
                }
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("[\(UIStrings.subsystem(event.subsystem, language: model.language))] \(event.message)")
                .font(.subheadline)

            Text(metadataSummary(for: event))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .rillCard(cornerRadius: 10, opacity: 0.2, padding: 10)
    }

    private func metadataSummary(for event: DiagnosticEvent) -> String {
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " · ")

        if metadata.isEmpty {
            return event.event
        }

        return "\(event.event) · \(metadata)"
    }

    private func diagnosticColor(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
