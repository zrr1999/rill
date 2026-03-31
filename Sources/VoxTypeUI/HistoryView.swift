import SwiftUI
import VoxTypeCore

public struct HistoryView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(UIStrings.text(.historyDescription, language: model.language))
                    .foregroundStyle(.secondary)
                Group {
                    if model.historyRecords.isEmpty {
                        emptyState
                            .transition(.opacity)
                    } else {
                        recordList
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: model.historyRecords.isEmpty)
            }
            .padding(24)
        }
        .navigationTitle(UIStrings.text(.historyTitle, language: model.language))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(UIStrings.text(.historyEmpty, language: model.language))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var recordList: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(model.historyRecords) { record in
                historyRow(record)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.historyRecords.map(\.id))
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: record.outcome == .completed
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill")
                    .foregroundStyle(record.outcome == .completed ? .green : .red)

                Text(UIStrings.workflowName(record.workflow, language: model.language))
                    .font(.headline)

                if record.isStackRelated {
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

                Text(record.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let text = record.finalText {
                Text(text)
                    .font(.body)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let failure = record.failureMessage {
                HStack(alignment: .top, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                    Button(UIStrings.text(.copy, language: model.language)) {
                        model.copyHistoryFailure(record)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(historyAccessibilityLabel(record))
    }

    private func historyAccessibilityLabel(_ record: HistoryRecord) -> String {
        let status = record.outcome == .completed ? "Completed" : "Failed"
        let workflow = UIStrings.workflowName(record.workflow, language: model.language)
        return "\(status): \(workflow)"
    }
}
