import RillCore

/// Navigation intent only: no preview payload, credential or sending authorization.
public struct RecordComparisonReturn: Sendable, Equatable {
  public let query: String
  public let resultLimit: Int
  public let candidateIDs: [RecordID]
  public let semanticIDs: [RecordID]
  public let selectedID: RecordID?
  public let sourceBundleIdentifier: String?
  public let currentAppOnly: Bool
  public let kind: RecordPayloadKind?
  public let pinnedOnly: Bool
}

extension AppModel {
  public func offerComparisonReturn(
    _ context: RecordComparisonReturn,
    resume: @escaping @MainActor (RecordComparisonReturn) -> Void
  ) {
    comparisonReturn = context
    resumeComparisonAction = resume
  }

  public func resumeComparison() {
    guard let context = comparisonReturn, let action = resumeComparisonAction else { return }
    discardComparisonReturn()
    action(context)
  }

  public func discardComparisonReturn() {
    comparisonReturn = nil
    resumeComparisonAction = nil
  }
}
