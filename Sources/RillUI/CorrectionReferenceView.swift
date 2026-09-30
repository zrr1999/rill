import RillCore
import SwiftUI

struct CorrectionReferenceView: View {
  let receipt: CorrectionReferenceReceipt
  let language: AppLanguage

  private func text(_ key: SurfaceText) -> String { L10n.surface(key, language: language) }

  var body: some View {
    DisclosureGroup(text(.correctionReferences)) {
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
      if let summary = receipt.screenSummary {
        Text(text(.screenObservationNotAPersonal)).fontWeight(.medium)
        Text((summary.terms + summary.observations).joined(separator: "\n")).textSelection(.enabled)
        if receipt.imageSummary == .pending {
          Text(text(.thisSummaryArrivedAfterInputs))
            .foregroundStyle(.secondary)
        }
      }
      if !receipt.memoryIDs.isEmpty {
        Text(text(.relatedMemories) + "\(receipt.memoryIDs.count)")
      }
    }.font(.caption)
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
