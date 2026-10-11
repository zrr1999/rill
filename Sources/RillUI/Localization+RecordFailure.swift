import Foundation
import RillCore
import RillRecords

extension L10n {
  static func recordStoreFailure(_ error: Error) -> LocalizedStringResource {
    guard let error = error as? RecordStoreError else {
      return resource("record.error.system", defaultValue: "Records could not be updated. Details: \(error.localizedDescription)")
    }
    switch error {
    case .collectionUnavailable: return resource("record.error.collectionUnavailable")
    case .recordUnavailable: return resource("record.error.recordUnavailable")
    case .membershipUnavailable: return resource("record.error.membershipUnavailable")
    case .membershipChanged: return resource("record.error.membershipChanged")
    case .membershipAlreadyInUse: return resource("record.error.membershipAlreadyInUse")
    case .manualSelectionRequired: return resource("record.error.manualSelectionRequired")
    case .membershipLimitReached: return resource("record.error.membershipLimitReached")
    case .routeCollectionLimitReached: return resource("record.error.routeCollectionLimitReached")
    case .recordLimitReached: return resource("record.error.recordLimitReached")
    case .payloadLimitReached: return resource("record.error.payloadLimitReached")
    case .totalPayloadLimitReached: return resource("record.error.totalPayloadLimitReached")
    case .collectionLimitReached: return resource("record.error.collectionLimitReached")
    case .routeLimitReached: return resource("record.error.routeLimitReached")
    case .invalidGraph: return resource("record.error.invalidGraph")
    case .invalidTextCorrection: return resource("record.error.invalidTextCorrection")
    case .invalidDeliveryReceipt: return resource("record.error.invalidDeliveryReceipt")
    case .persistenceUnavailable: return resource("record.error.persistenceUnavailable")
    }
  }
}
