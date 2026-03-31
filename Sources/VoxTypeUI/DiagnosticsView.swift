import SwiftUI
import VoxTypeCore

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

                if model.deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(UIStrings.text(.diagnosticsManageProviderSettings, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button(UIStrings.text(.diagnosticsOpenSettings, language: model.language)) {
                        model.selectedSidebarSection = .settings
                    }
                } else {
                    Text(UIStrings.text(.deepgramTestHint, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button(UIStrings.deepgramTestButtonTitle(model.deepgramAudioTestState, language: model.language)) {
                        model.toggleDeepgramAudioTest()
                    }
                    .disabled(model.deepgramAudioTestState == .transcribing)

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
            .voxCard()
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
                }

                if model.diagnosticEvents.isEmpty {
                    Text(UIStrings.text(.diagnosticsEmpty, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.diagnosticEvents.prefix(20).enumerated()), id: \.offset) { entry in
                        diagnosticRow(entry.element)
                    }
                }
            }
            .voxCard()
    }

    private func diagnosticRow(_ event: DiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .voxCard(cornerRadius: 10, opacity: 0.2, padding: 10)
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
