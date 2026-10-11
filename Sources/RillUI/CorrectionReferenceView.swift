import RillCore
import SwiftUI

struct CorrectionReferenceView: View {
  let receipt: CorrectionReferenceReceipt
  let memories: [LongTermMemory]
  let workflows: [WorkflowDefinition]
  let previewMode: PrivacyHistoryPreviewMode
  let language: AppLanguage
  let manageMemories: () -> Void
  @State var isExpanded = false

  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

  var body: some View {
    DisclosureGroup(text(.correctionReferences), isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent(text(.preRecordingImage), value: status(receipt.image))
        LabeledContent(text(.imageSummary), value: status(receipt.imageSummary))
        LabeledContent(text(.memorySummary), value: status(receipt.memorySummary))
        if let vocabulary = receipt.vocabulary {
          LabeledContent(text(.vocabulary), value: status(vocabulary.status))
          let counts: [String] = [
            "\(text(.applicable))\(vocabulary.eligibleCount)",
            "\(text(.included))\(vocabulary.includedCount)",
            "\(text(.omittedByBudget))\(vocabulary.omittedCount)",
            "\(vocabulary.encodedByteCount) bytes",
          ]
          Text(counts.joined(separator: " · "))
        }
        Text(text(.sentReferencesAreEvidenceOffered))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if previewMode == .full, let summary = receipt.screenSummary {
          Text(text(.screenObservationNotAPersonal)).fontWeight(.medium)
          Text((summary.terms + summary.observations).joined(separator: "\n")).textSelection(.enabled)
          if receipt.imageSummary == .pending {
            Text(text(.thisSummaryArrivedAfterInputs))
              .foregroundStyle(.secondary)
          }
        }
        if !receipt.memoryIDs.isEmpty {
          Text(text(.relatedMemories) + "\(receipt.memoryIDs.count)")
          if previewMode == .full {
            Text(text(.memoryCurrentContentNotice)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(receipt.memoryIDs.enumerated()), id: \.offset) { _, id in
              VStack(alignment: .leading, spacing: 4) {
                if let memory = memories.first(where: { $0.id == id }) {
                  Text(memory.summary).textSelection(.enabled).accessibilityValue(memory.summary)
                  if !memory.terms.isEmpty {
                    LabeledContent(text(.memoryTerms), value: memory.terms.joined(separator: " · "))
                  }
                  MemoryScopeView(scope: memory.scope, workflows: workflows, language: language)
                } else {
                  Text(text(.memoryCurrentUnavailable)).foregroundStyle(.secondary)
                  Text(id.uuidString).font(.caption.monospaced())
                }
              }
            }
            Button(text(.manageMemories), action: manageMemories)
              .accessibilityIdentifier("history.references.manage-memories")
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.font(.caption).accessibilityIdentifier("history.references")
  }

  private func status(_ value: CorrectionReferenceStatus) -> String {
    switch value {
    case .disabled: text(.off)
    case .unavailable: text(.unavailableSkipped)
    case .timedOut: text(.timedOutSkipped)
    case .failed: text(.failedSkipped)
    case .pending: text(.notReadyAtFreezeOmitted)
    case .ready: text(.prepared)
    case .sent: text(.sentAsReference)
    case .deliveryUnconfirmed: text(.requestFailedDeliveryUnconfirmed)
    case .cancelled: text(.cancelled)
    }
  }
}
