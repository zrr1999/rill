import RillCore
import SwiftUI

struct HistoryRunTiming: Identifiable, Equatable {
    let kind: WorkflowProcessStepKind?
    let milliseconds: UInt64?
    let result: WorkflowStepResultCode?

    var id: String { kind?.rawValue ?? "recording" }

    static func items(for entry: HistoryTimelineEntry) -> [Self] {
        let steps: [(WorkflowProcessStepKind, UInt64?, WorkflowStepResultCode)]
        if let receipt = entry.receipt, !receipt.stepDetails.isEmpty {
            steps = receipt.stepDetails.map { ($0.kind, $0.durationMilliseconds, $0.result) }
        } else {
            steps = (entry.record?.correctionSource?.processingSteps ?? [])
                .map { ($0.kind, $0.durationMilliseconds, $0.result) }
        }
        var items: [Self] = []
        if entry.receipt?.recordingDurationMilliseconds != nil || steps.contains(where: { $0.0 == .recognizeSpeech }) {
            items.append(Self(kind: nil, milliseconds: entry.receipt?.recordingDurationMilliseconds, result: nil))
        }
        for kind: WorkflowProcessStepKind in [.recognizeSpeech, .llmRewrite, .llmAnswer] {
            let matching = steps.filter { $0.0 == kind }
            guard !matching.isEmpty else { continue }
            var total: UInt64? = 0
            for (_, duration, _) in matching {
                guard let accumulated = total, let duration else { total = nil; break }
                let sum = accumulated.addingReportingOverflow(duration)
                total = sum.overflow ? nil : sum.partialValue
            }
            let result = matching.first { $0.2 == .failed || $0.2 == .cancelled }?.2
                ?? matching.first { $0.2 == .skipped }?.2 ?? .completed
            items.append(Self(kind: kind, milliseconds: total, result: result))
        }
        return items
    }

    func title(language: AppLanguage) -> String {
        let key: HistoryRunDetailTextKey = switch kind {
        case nil: .recording
        case .recognizeSpeech: .transcription
        case .llmRewrite: .polishing
        default: .languageModel
        }
        return L10n.historyRunDetail(key, language: language)
    }
}

struct HistoryRunTimingView: View {
    let items: [HistoryRunTiming]
    let language: AppLanguage

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                timingItems
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: RillSpacing.compact) {
                timingItems
            }
        }
        .font(.caption)
        .accessibilityIdentifier("history.run-timing")
    }

    private var timingItems: some View {
        ForEach(items) { item in
            HStack(spacing: RillSpacing.compact) {
                Text(item.title(language: language)).foregroundStyle(.secondary)
                Text(L10n.historyMeasuredDuration(item.milliseconds, language: language))
                    .monospacedDigit()
                if let result = item.result, result != .completed {
                    Text(L10n.historyStepResult(result, language: language))
                        .foregroundStyle(result == .failed ? .red : .secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
